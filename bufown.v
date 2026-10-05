module main

// Владение большими буферами кадра (сырьё превью, маска, результат AI,
// JPEG камеры): данные - вне сборщика мусора (bigbuf), освобождаются
// системе, когда их больше никто не держит.
//
// Зачем: сборщик V (Boehm) освобождённую память системе не отдаёт и
// держит прошлые пики. Листание 12 кадров туда-обратно - процесс рос до
// ~1 ГБ, а с кэшем кадров (framecache.v, до 1.5 ГБ) - до ~2.6 ГБ, и эта
// память оставалась у процесса даже после выключения кэша.
//
// Как: реестр «адрес данных -> число держателей». Массивы V - значения
// (копия массива делит те же данные), поэтому держателем считается не
// переменная, а тот, кто взял ссылку: поле State, запись кэша кадров,
// итог воркера в пути (LoadResult, PrepResult, AiResult), задание воркера
// (PrepJob.src/ai_src, AiJob.src - пока воркер читает). Правила:
//   own_new / own_clone - новый буфер, у вызывающего одна ссылка;
//   share(a)            - ещё один держатель тех же данных;
//   drop(mut a)         - держатель отпускает (массив становится пустым);
//                         последний - данные системе (munmap);
//   перенос (st.linear = res.linear) - без share/drop: ссылка переходит.
// Массив не из реестра (обычный массив сборщика, пустой) share и drop
// пропускают - старый код и тесты работают как раньше. Реестр под
// мьютексом: воркеры выделяют и отпускают буферы в своих потоках.
import sync
import bigbuf

__global own_mu = sync.new_mutex()
__global own_refs = map[u64]int{}

// own_new - n нулей вне сборщика, у вызывающего одна ссылка
fn own_new[T](n int) []T {
	mut a := []T{}
	$if T is u16 {
		a = bigbuf.new_u16(n)
	} $else $if T is u8 {
		a = bigbuf.new_u8(n)
	} $else $if T is f32 {
		a = bigbuf.new_f32(n)
	}
	if a.len > 0 {
		own_mu.@lock()
		own_refs[u64(a.data)] = 1
		own_mu.unlock()
	}
	return a
}

// own_clone - копия src вне сборщика (одна ссылка)
fn own_clone[T](src []T) []T {
	mut a := own_new[T](src.len)
	if src.len > 0 {
		unsafe { vmemcpy(a.data, src.data, src.len * int(sizeof(T))) }
	}
	return a
}

// share - ещё один держатель тех же данных (возвращает тот же массив)
fn share[T](a []T) []T {
	if a.len > 0 {
		own_mu.@lock()
		k := u64(a.data)
		if k in own_refs {
			own_refs[k]++
		}
		own_mu.unlock()
	}
	return a
}

// drop - держатель отпускает буфер; последний - данные системе. Массив
// становится пустым.
fn drop[T](mut a []T) {
	if a.len == 0 {
		a = []T{}
		return
	}
	k := u64(a.data)
	own_mu.@lock()
	mut last := false
	if k in own_refs {
		own_refs[k]--
		if own_refs[k] <= 0 {
			own_refs.delete(k)
			last = true
		}
	}
	own_mu.unlock()
	if last {
		bigbuf.free(mut a)
	}
	a = []T{}
}
