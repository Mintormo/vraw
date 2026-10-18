module main

// Кэш результата AI-шумодава на диске (18.10.2026): прогон по полному
// кадру - ~10-16 минут, а результат (ai_full, линейный RGB u16, ~144 МБ на
// 24 Мп) читается с диска за доли секунды. Лежит рядом со снимком, в
// подпапке .vraw-cache папки с RAW: <папка>/.vraw-cache/<имя RAW>.vrai (просьба
// Игоря) - съёмку переносят папкой, кэш едет с ней. Один файл на кадр:
// пересчёт (другой объектив) его перезаписывает. Подходит ли файл -
// по ключу ai_cache_key: RAW (размер, время изменения - путь не входит,
// папку можно переносить), коррекция объектива, от которой зависит сырьё
// модели, и модель. Выключается в «Настройки - Общие» (no_ai_cache).
//
// Формат: строка ai_cache_magic, строка ключа (сверяется при чтении),
// «ширина высота» по 8 цифр, затем данные u16 подряд (порядок байтов
// машины: x86 и ARM обе little-endian). Пишется во временный файл и
// переименовывается: оборванная запись не оставит битого кэша.
import os
import ai

const ai_cache_magic = 'VRAI1\n'
const ai_cache_ext = '.vrai'

// ai_cache_path - файл кэша кадра: <папка RAW>/.vraw-cache/<имя>.vrai
fn ai_cache_path(raw_path string) string {
	return os.join_path(os.dir(raw_path), '.vraw-cache', os.file_name(raw_path) + ai_cache_ext)
}

// ai_cache_key - от чего зависит результат модели открытого кадра ('' -
// файла нет); те же настройки объектива, что берёт прогон (ai_check)
fn ai_cache_key(st &State) string {
	fst := os.stat(st.raw_path) or { return '' }
	use_prof := st.edit.lens_corr && !isnil(st.corr)
	return '${fst.size}|${fst.mtime}|${use_prof}|${st.look.vign}|${st.look.zoom}|${st.edit.lman.key()}|${ai.model.id}'
}

fn ai_cache_head(key string, fw int, fh int) string {
	return '${ai_cache_magic}${key}\n${fw:08} ${fh:08}\n'
}

// ai_cache_write - записать результат (во временный файл, потом на место)
fn ai_cache_write(path string, key string, full []u16, fw int, fh int) ! {
	if full.len != fw * fh * 3 || full.len == 0 {
		return error('размер результата')
	}
	os.mkdir_all(os.dir(path))!
	tmp := path + '.tmp'
	mut f := os.create(tmp)!
	f.write_string(ai_cache_head(key, fw, fh)) or {
		f.close()
		os.rm(tmp) or {}
		return err
	}
	n := unsafe { f.write_ptr(full.data, full.len * 2) }
	f.close()
	if n != full.len * 2 {
		os.rm(tmp) or {}
		return error('запись прервана (диск полон?)')
	}
	os.mv(tmp, path)!
}

// ai_cache_read - прочитать результат по ключу: (буфер вне сборщика -
// своя ссылка, bufown.v; ширина, высота). Чужой ключ, обрезанный файл -
// ошибка.
fn ai_cache_read(path string, key string) !([]u16, int, int) {
	mut f := os.open(path)!
	defer {
		f.close()
	}
	want := ai_cache_magic + key + '\n'
	mut head := []u8{len: want.len + 18}
	if f.read_into_ptr(head.data, head.len)! != head.len || head[..want.len].bytestr() != want {
		return error('не тот файл кэша')
	}
	dims := head[want.len..].bytestr().trim_space().split(' ')
	if dims.len != 2 {
		return error('испорченный кэш')
	}
	fw := dims[0].int()
	fh := dims[1].int()
	if fw <= 0 || fh <= 0 || fw > 100000 || fh > 100000 {
		return error('испорченный кэш')
	}
	mut full := own_new[u16](fw * fh * 3)
	total := full.len * 2
	mut got := 0
	for got < total {
		n := f.read_into_ptr(unsafe { &u8(full.data) + got }, total - got) or { 0 }
		if n <= 0 {
			break
		}
		got += n
	}
	if got != total {
		drop(mut full)
		return error('обрезанный кэш')
	}
	return full, fw, fh
}

// ai_cache_save - запись результата в фоне (spawn): своя ссылка на full
// (share - отпускается здесь). Ошибка записи (папка только для чтения,
// карта памяти, диск полон) молчит: кэш - ускорение, без него всё работает.
fn ai_cache_save(path string, key string, full []u16, fw int, fh int) {
	mut buf := unsafe { full }
	defer {
		drop(mut buf)
	}
	ai_cache_write(path, key, full, fw, fh) or {}
}
