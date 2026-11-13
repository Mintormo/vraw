module main

// Хендлы фоновых потоков. Поток V без wait() после завершения держит свои
// ресурсы (стек, отображения памяти; опыт: 2000 потоков - +16 ГБ
// виртуальной памяти, +28 МБ RSS, 4000 отображений) до wait(). Поэтому
// каждый воркер при выходе отмечает Done, а при запуске следующего потока
// того же вида (track) уже закончившиеся соединяются - список держит
// только работающие потоки и последний закончившийся. На выходе
// программы - wait_all. Повторный wait() того же потока роняет программу
// («V thread join failed»): поток после wait из списка уходит.
import sync.stdatomic

// Done - флаг «воркер закончил», ставится в самом конце воркера
// (defer), после отправки результата
@[heap]
struct Done {
mut:
	v u64
}

fn (d &Done) mark() {
	stdatomic.store_u64(&d.v, 1)
}

fn (d &Done) is_set() bool {
	return stdatomic.load_u64(&d.v) != 0
}

struct Worker {
	t    thread
	done &Done = unsafe { nil }
}

// track - соединить закончившиеся потоки и добавить новый t
fn track(mut ws []Worker, t thread, done &Done) {
	reap(mut ws)
	ws << Worker{
		t:    t
		done: done
	}
}

// reap - соединить потоки, отметившие Done (wait почти мгновенный: воркер
// уже на выходе), и убрать их из списка
fn reap(mut ws []Worker) {
	for i := ws.len - 1; i >= 0; i-- {
		if ws[i].done.is_set() {
			ws[i].t.wait()
			ws.delete(i)
		}
	}
}

// wait_all - дождаться всех потоков списка
fn wait_all(mut ws []Worker) {
	for w in ws {
		w.t.wait()
	}
	ws.clear()
}
