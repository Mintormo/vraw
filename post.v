module main

// Доставка результатов фоновых потоков в главный поток (app.post) без
// создания замыканий.
//
// Почему не просто app.post(fn [res] () { on_done(res) }) - две особенности
// V (0.5.x), из-за которых каждое такое замыкание держало буферы до выхода
// (утечка ~140-200 МБ на каждое открытие кадра):
// 1. Замыкание V не освобождает никогда - вместе со всем, что оно захватило.
// 2. Каждое созданное замыкание V записывает в глобальную таблицу
//    (g_closure.live, ClosureLiveInfo{ctx, owns_data bool, ...}); семь байт
//    выравнивания после bool не обнуляются - в них мусор со стека потока,
//    и консервативный сборщик принимает его за указатель: буфер, на
//    который этот мусор когда-то указывал, живёт до выхода. Опасно любое
//    замыкание, созданное после работы с буферами, - и в воркере, и в
//    главном потоке.
// Поэтому в повторяющихся местах (результаты воркеров, прогресс,
// перетаскивание, 1:1) замыкания не создаём: результат и приёмник лежат в
// Mailbox (куча), в очереди посылок - указатель на него и обобщённая
// функция доставки (обычная функция), app.post получает функцию без
// захватов (тоже не замыкание). Приёмники on_done - замыкания, созданные
// один раз при запуске (st.on_load_done и т.п.), их передача - копия
// указателя. Подробнее - PROJECT.md, «Замыкания и память».
import sync
import vgui

// Parcel - посылка: функция доставки и ящик с результатом
struct Parcel {
	deliver fn (voidptr) = unsafe { nil }
	box     voidptr
}

__global parcel_mu = sync.new_mutex()
__global parcel_queue = []Parcel{}

// Mailbox - результат воркера и его приёмник (главный поток)
@[heap]
struct Mailbox[T] {
mut:
	val     T
	on_done fn (T) = unsafe { nil }
}

// deliver_mailbox - выдать результат приёмнику, ящик опустошить (буферы
// результата держит только приёмник)
fn deliver_mailbox[T](p voidptr) {
	mut b := unsafe { &Mailbox[T](p) }
	v := b.val
	f := b.on_done
	b.val = T{}
	b.on_done = unsafe { nil }
	f(v)
}

// post_result - доставить результат val в главный поток: on_done(val)
// выполнится там между событиями и рендером. Годится для любого потока,
// замыканий не создаёт.
fn post_result[T](mut app vgui.App, on_done fn (T), val T) {
	b := &Mailbox[T]{
		val:     val
		on_done: on_done
	}
	parcel_mu.lock()
	parcel_queue << Parcel{
		deliver: deliver_mailbox[T]
		box:     voidptr(b)
	}
	parcel_mu.unlock()
	app.post(drain_parcels)
}

// drain_parcels - главный поток: доставить всё, что накопилось (одна
// посылка - один app.post; лишние вызовы находят очередь пустой)
fn drain_parcels() {
	parcel_mu.lock()
	items := parcel_queue.clone()
	// Затереть указатели и в хвосте массива (за len): консервативный
	// сборщик видит и их - доставленные ящики держались бы до перезаписи
	unsafe { vmemset(parcel_queue.data, 0, parcel_queue.cap * int(sizeof(Parcel))) }
	parcel_queue.clear()
	parcel_mu.unlock()
	for p in items {
		p.deliver(p.box)
	}
}

// SaveOutcome - итог сохранения: вид уведомления
enum SaveOutcome {
	saved
	failed
	cancelled
}

// Report - итог сохранения для report: приёмник, вид и текст
struct Report {
	on_done fn (SaveOutcome, string) = unsafe { nil }
	res     SaveOutcome
	msg     string
}

fn deliver_report(r Report) {
	r.on_done(r.res, r.msg)
}

// report доставляет итог сохранения из фонового потока в главный; res
// выбирает вид уведомления (успех/ошибка) на принимающей стороне.
fn report(mut app vgui.App, on_done fn (SaveOutcome, string), res SaveOutcome, msg string) {
	post_result(mut app, deliver_report, Report{
		on_done: on_done
		res:     res
		msg:     msg
	})
}
