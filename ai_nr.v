module main

// AI-шумодав в окне: нейросеть (модуль ai, NAFNet-SIDD) по кнопке, в
// фоне, с прогрессом и отменой. Секция «Шумодав и ореолы», блок сверху.
//
// Как устроено:
// - Модель считает превью (raw_linear - после коррекции объектива, до
//   импульсов и вейвлета) один раз, ~40 с; результат - st.ai_linear.
// - Настройка кадра - edit.ai (сила 1..100, 0 - выключен): в истории и
//   сайдкаре. Подготовка сырья смешивает raw_linear с ai_linear по силе
//   (ai.blend - мгновенно), дальше как обычно: импульсы, вейвлет, ореолы.
//   Поэтому ползунок силы - без пересчёта модели. Сброс выбрасывает
//   результат: повторное включение или откат к AI - новый прогон.
// - raw_linear сменился (объектив, пересветы, другой кадр) - ai_linear
//   устарел (raw_gen); если AI включён, прогон перезапускается сам.
// - Экспорт с AI считает модель на полном кадре (~2.5 мин) в save_worker;
//   его прогресс - в этом же блоке, пока не идёт прогон превью.
import time
import vgui
import ai

// AiCtl - один прогон модели (превью или экспорт). cancel пишет главный
// поток, читает воркер между плитками без синхронизации (опоздание на
// одну плитку безвредно, как ThumbStop). t1/n1 - время и номер первой
// готовой плитки (пишет только воркер) - для оценки оставшегося
// времени без учёта загрузки модели и проявки. done/total/eta пишет
// главный поток (on_progress) - для показа.
@[heap]
struct AiCtl {
mut:
	cancel bool
	export bool // true - экспорт полного кадра, false - превью
	t1     i64  // мс первой готовой плитки, 0 - ещё не было
	n1     int
	done   int
	total  int
	eta    f64 = -1 // секунд до конца, < 0 - ещё неизвестно
}

// AiJob - прогон превью: копия raw_linear и её номер
struct AiJob {
	gen     int // file_gen кадра
	raw_gen int
	src     []u16
	w       int
	h       int
	cache   &ai.Cache = unsafe { nil }
	ctl     &AiCtl    = unsafe { nil }
}

struct AiResult {
	ctl       &AiCtl = unsafe { nil } // чей это прогон
	gen       int
	raw_gen   int
	out       []u16
	err       string
	cancelled bool
	secs      f64
}

// AiUi - виджеты блока: три состояния в Stack (видно одно) - кнопка,
// прогресс, применён (сила и сброс - выключение AI). Каждое состояние - VBox в
// своём Stack: у VBox нет публичного visible, у Stack есть.
@[heap]
struct AiUi {
mut:
	idle     &vgui.Stack       = unsafe { nil }
	running  &vgui.Stack       = unsafe { nil }
	applied  &vgui.Stack       = unsafe { nil }
	start    &vgui.Button      = unsafe { nil }
	hint     &vgui.Label       = unsafe { nil }
	bar      &vgui.ProgressBar = unsafe { nil }
	pct      &vgui.Label       = unsafe { nil }
	status   &vgui.Label       = unsafe { nil }
	strength &vgui.Slider      = unsafe { nil }
	ok_icon  &vgui.Icon        = unsafe { nil }
	run_icon &vgui.Icon        = unsafe { nil }
}

// ai_ready - ai_linear посчитан по текущему raw_linear
fn ai_ready(st &State) bool {
	return st.ai_linear.len > 0 && st.ai_linear.len == st.raw_linear.len
		&& st.ai_raw_gen == st.raw_gen
}

// ai_effective - сила AI, с которой сейчас надо готовить сырьё (0 - без AI:
// выключен или результата ещё нет)
fn ai_effective(st &State) f32 {
	return if st.edit.ai > 0 && ai_ready(st) { st.edit.ai } else { 0 }
}

// prep_stale - подготовленное сырьё не соответствует настройкам шумодава
fn prep_stale(st &State) bool {
	return st.nr_applied != st.edit.nr || st.ai_applied != ai_effective(st)
}

// raw_changed - в State новый raw_linear (коррекция объектива, другой
// кадр): результат модели больше не годится, идущий прогон превью - тоже
fn raw_changed(mut st State) {
	st.raw_gen++
	st.ai_linear = []u16{}
	if !isnil(st.ai_prev) {
		mut c := st.ai_prev
		c.cancel = true
		st.ai_prev = unsafe { nil }
		st.ai_restart = true // отменили не по просьбе пользователя
	}
}

// ai_check - запустить прогон превью, если он нужен (кнопка нажата или AI
// включён в настройках кадра), а результата нет. Зовётся везде, где могло
// появиться сырьё или смениться настройка: готовая подготовка, конец
// загрузки кадра, откат истории, кнопка.
fn ai_check(mut st State, mut app vgui.App) {
	need := st.ai_wanted || st.edit.ai > 0
	if !need || !isnil(st.ai_prev) {
		sync_ai_ui(mut st)
		return
	}
	if ai_ready(st) {
		if st.ai_wanted {
			ai_turn_on(mut st, mut app)
		}
		sync_ai_ui(mut st)
		return
	}
	// Сырьё ещё не готово или вот-вот сменится - позовут снова
	if st.loading || st.raw_linear.len == 0 || st.lens_dirty || st.raw_pending
		|| isnil(st.ai_cache) {
		sync_ai_ui(mut st)
		return
	}
	ctl := &AiCtl{}
	st.ai_prev = ctl
	st.ai_restart = false
	job := AiJob{
		gen:     st.file_gen
		raw_gen: st.raw_gen
		src:     st.raw_linear.clone()
		w:       st.pw
		h:       st.ph
		cache:   st.ai_cache
		ctl:     ctl
	}
	st.ai_threads << spawn ai_worker(job, mut app, st.ai_progress, st.ai_done)
	// Запуск без кнопки (AI из сайдкара, новое сырьё после смены объектива
	// или пересветов) - секция может быть свёрнута: сказать тостом
	if !st.ai_wanted && !isnil(st.nm) {
		mut nm := st.nm
		nm.show_info('AI-шумодав: пересчёт превью (~40 с, прогресс - в секции «Шумодав и ореолы»)')
	}
	sync_ai_ui(mut st)
}

// ai_progress_fn - обратный вызов для ai.denoise (в потоке воркера):
// прогресс - в главный поток через app.post, возврат false - отмена
fn ai_progress_fn(mut app vgui.App, ctl &AiCtl, on_progress fn (&AiCtl, int, int, f64)) fn (int, int) bool {
	return fn [mut app, ctl, on_progress] (done int, total int) bool {
		mut c := unsafe { ctl }
		now := time.now().unix_milli()
		mut eta := f64(-1)
		if c.t1 == 0 {
			c.t1 = now
			c.n1 = done
		} else if done > c.n1 {
			eta = f64(now - c.t1) / 1000 / f64(done - c.n1) * f64(total - done)
		}
		app.post(fn [on_progress, ctl, done, total, eta] () {
			on_progress(ctl, done, total, eta)
		})
		return !c.cancel
	}
}

// ai_worker - прогон модели по превью в spawn; без State и vgui, кроме
// app.post (потокобезопасен по контракту vgui)
fn ai_worker(job AiJob, mut app vgui.App, on_progress fn (&AiCtl, int, int, f64), on_done fn (AiResult)) {
	sw := time.new_stopwatch()
	mut res := AiResult{
		ctl:     job.ctl
		gen:     job.gen
		raw_gen: job.raw_gen
	}
	mut cache := unsafe { job.cache }
	if model := cache.get() {
		progress := ai_progress_fn(mut app, job.ctl, on_progress)
		if out := ai.denoise(model, unsafe { &u16(job.src.data) }, job.w, job.h, progress) {
			res = AiResult{
				...res
				out: out
			}
		} else {
			res = AiResult{
				...res
				err:       err.msg()
				cancelled: err is ai.Cancelled
			}
		}
	} else {
		res = AiResult{
			...res
			err: err.msg()
		}
	}
	res = AiResult{
		...res
		secs: f64(sw.elapsed().milliseconds()) / 1000
	}
	app.post(fn [on_done, res] () {
		on_done(res)
	})
}

// ai_take - итог прогона превью (главный поток, из app.post)
fn ai_take(mut st State, mut app vgui.App, res AiResult) {
	if st.ai_prev != res.ctl {
		// Прогон, отменённый сменой сырья или кадра: если нужен - уже
		// перезапускается (или будет запущен ai_check)
		if st.ai_restart && res.gen == st.file_gen {
			ai_check(mut st, mut app)
		}
		return
	}
	st.ai_prev = unsafe { nil }
	if res.cancelled {
		// Отменил пользователь: и кнопку, и включённый AI (пересчёт после
		// смены объектива) - выключаем, чтобы он не запустился снова
		st.ai_wanted = false
		if st.edit.ai > 0 {
			ai_turn_off(mut st, mut app)
		}
		sync_ai_ui(mut st)
		return
	}
	if res.err.len > 0 {
		st.ai_wanted = false
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_error('AI-шумодав: ${res.err}')
		}
		sync_ai_ui(mut st)
		return
	}
	if res.gen != st.file_gen || res.raw_gen != st.raw_gen {
		ai_check(mut st, mut app)
		return
	}
	st.ai_linear = res.out
	st.ai_raw_gen = res.raw_gen
	if st.ai_wanted {
		ai_turn_on(mut st, mut app)
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_success('AI-шумодав готов (${res.secs:.0f} с)')
		}
	} else if prep_stale(st) {
		request_prep(mut st, mut app, false) // AI был включён - пересчёт после смены сырья
	}
	sync_ai_ui(mut st)
}

// ai_turn_on - результат есть, включить AI в настройках кадра (сила 100)
// и записать в историю
fn ai_turn_on(mut st State, mut app vgui.App) {
	st.ai_wanted = false
	if !isnil(st.ai_ui) && !isnil(st.ai_ui.strength) {
		st.suppress = true
		mut sl := st.ai_ui.strength
		sl.set_value(100)
		st.suppress = false
	}
	st.edit.ai = 100
	request_prep(mut st, mut app, false)
	record(mut st, 'ai', 'AI-шумодав', false)
	sync_ai_ui(mut st)
}

// ai_turn_off - сброс AI (кнопка ↺ в строке «Сила», отмена пересчёта):
// выключить и выбросить результат модели - следующее «Убрать шум (AI)»
// считает заново (так просил Игорь: сброс - это сброс, без кэша). Откат
// истории к записи с AI пересчитает модель через ai_check.
fn ai_turn_off(mut st State, mut app vgui.App) {
	st.edit.ai = 0
	st.ai_linear = []u16{}
	request_prep(mut st, mut app, false)
	record(mut st, 'ai', 'AI-шумодав: выкл', false)
	sync_ai_ui(mut st)
}

// ai_forget - кадр закрыт или открыт другой: отменить прогон превью,
// забыть результат
fn ai_forget(mut st State) {
	if !isnil(st.ai_prev) {
		mut c := st.ai_prev
		c.cancel = true
		st.ai_prev = unsafe { nil }
	}
	st.ai_wanted = false
	st.ai_restart = false
	st.ai_linear = []u16{}
	st.ai_applied = 0
	st.raw_gen++
	sync_ai_ui(mut st)
}

// fmt_eta - «осталось ~25 с» / «~3 мин»
fn fmt_eta(sec f64) string {
	if sec < 0 {
		return 'оценка времени...'
	}
	if sec < 60 {
		return 'осталось ~${int(sec + 0.5)} с'
	}
	return 'осталось ~${int(sec / 60 + 0.5)} мин'
}

// sync_ai_ui - какое состояние блока показать. Приоритет - идущий прогон
// превью, затем экспорт с AI, затем «применён» / кнопка.
fn sync_ai_ui(mut st State) {
	if isnil(st.ai_ui) {
		return
	}
	mut u := st.ai_ui
	ctl := if !isnil(st.ai_prev) { st.ai_prev } else { st.ai_exp }
	running := !isnil(ctl)
	applied := !running && st.edit.ai > 0 && ai_ready(st)
	u.running.visible = running
	u.applied.visible = applied
	u.idle.visible = !running && !applied
	if running {
		what := if ctl.export { 'Экспорт: полный кадр' } else { 'Превью' }
		if ctl.total == 0 {
			u.bar.set_value(0)
			u.pct.text = ''
			u.status.text = '${what} · загрузка модели...'
		} else {
			u.bar.set_value(f32(ctl.done) / f32(ctl.total))
			u.pct.text = '${ctl.done * 100 / ctl.total}%'
			u.status.text = '${what} · ${fmt_eta(ctl.eta)}'
		}
	}
	mut b := u.start
	b.enabled = !isnil(st.ai_cache) && st.ai_cache.path != '' && !isnil(st.dev) && !st.loading
}

// build_ai_block - блок AI-шумодава в секции «Шумодав и ореолы»: Stack
// трёх состояний одной высоты (ai_block_h), видно одно (sync_ai_ui).
// strength - ползунок силы (edit_slider, fx - подготовка сырья).
fn build_ai_block(mut st State, mut app vgui.App, mut strength EditSlider, lw f32, vw f32) &vgui.Stack {
	mut u := &AiUi{}
	st.ai_ui = u
	model_ok := !isnil(st.ai_cache) && st.ai_cache.path != ''

	// Кнопка запуска и подсказка
	mut start := vgui.button('Убрать шум (AI)')
	start.icon_name = 'sparkles'
	start.icon_size = 15
	start.style = .accent
	start.on_click = fn [mut st, mut app] () {
		if isnil(st.dev) || st.loading {
			return
		}
		st.ai_wanted = true
		ai_check(mut st, mut app)
	}
	u.start = start
	hint_text := if model_ok {
		'NAFNet-SIDD · превью ~40 с, экспорт ~3 мин'
	} else {
		'Нет модели ${ai.model_name} в ~/.local/share/vraw/models'
	}
	mut hint := vgui.label(hint_text)
	st.hint_labels << hint
	u.hint = hint
	mut idle := vgui.create_vbox_fill()
	idle.set_spacing(ai_row_gap)
	idle.add_fixed(start, ai_row_h)
	idle.add_fixed(hint, ai_note_h)
	u.idle = layer(idle)

	// Прогресс: полоса, проценты, отмена; под ними - что и сколько осталось
	mut bar := vgui.progress_bar_linear()
	bar.thickness = 6
	u.bar = bar
	mut pct := value_label('')
	u.pct = pct
	mut cancel := icon_button(mut st, 'circle-x', 'Отменить')
	cancel.on_click = fn [mut st] () {
		ctl := if !isnil(st.ai_prev) { st.ai_prev } else { st.ai_exp }
		if !isnil(ctl) {
			mut c := unsafe { ctl }
			c.cancel = true
			if !isnil(st.ai_ui) {
				mut s := st.ai_ui.status
				s.text = 'Отмена...'
			}
		}
	}
	mut run_icon := vgui.icon('sparkles')
	run_icon.set_size(15)
	u.run_icon = run_icon
	mut prow := vgui.create_hbox_fill()
	prow.set_spacing(6)
	prow.add_fixed(run_icon, 20)
	prow.add(bar, 1)
	prow.add_fixed(pct, vw)
	prow.add_fixed(cancel, 26)
	mut status := vgui.label('')
	st.secondary_labels << status
	u.status = status
	mut running := vgui.create_vbox_fill()
	running.set_spacing(ai_row_gap)
	running.add_fixed(prow, ai_row_h)
	running.add_fixed(status, ai_note_h)
	u.running = layer(running)
	u.running.visible = false

	// Применён: сила (ползунок настройки кадра) и сброс. Сброс здесь -
	// не «сила по умолчанию», а выключение AI: как у классических
	// ползунков, где сброс = 0 = шумодава нет (сила 100 и так по умолчанию,
	// обычный сброс ничего бы не делал). Результат модели выбрасывается.
	mut off := reset_button(mut st, 'Сбросить AI-шумодав')
	off.on_click = fn [mut st, mut app] () {
		if st.edit.ai > 0 {
			ai_turn_off(mut st, mut app)
		}
	}
	mut srow := vgui.create_hbox_fill()
	srow.set_spacing(6)
	srow.add_fixed(strength.lb, lw)
	srow.add(strength.sl, 1)
	srow.add_fixed(strength.vl, vw)
	srow.add_fixed(off, 26)
	u.strength = strength.sl
	mut ok_icon := vgui.icon('circle-check')
	ok_icon.set_size(14)
	u.ok_icon = ok_icon
	mut ok_lb := vgui.label('AI-шумодав применён · NAFNet-SIDD')
	st.secondary_labels << ok_lb
	mut orow := vgui.create_hbox_fill()
	orow.set_spacing(4)
	orow.add_fixed(ok_icon, 18)
	orow.add(ok_lb, 1)
	mut applied := vgui.create_vbox_fill()
	applied.set_spacing(ai_row_gap)
	applied.add_fixed(srow, ai_row_h)
	applied.add_fixed(orow, ai_note_h)
	u.applied = layer(applied)
	u.applied.visible = false

	mut stack := &vgui.Stack{}
	stack.add(u.idle)
	stack.add(u.running)
	stack.add(u.applied)
	sync_ai_ui(mut st)
	return stack
}

// layer - слой Stack с одним виджетом (его можно скрыть)
fn layer(w &vgui.Widget) &vgui.Stack {
	mut s := &vgui.Stack{}
	s.add(w)
	return s
}

const ai_row_h = f32(28)
const ai_note_h = f32(16)
const ai_row_gap = f32(6)
const ai_block_h = ai_row_h + ai_row_gap + ai_note_h

// paint_ai - цвета значков блока по теме (paint_ui)
fn paint_ai(mut st State, th vgui.Theme) {
	if isnil(st.ai_ui) {
		return
	}
	mut u := st.ai_ui
	u.ok_icon.set_color(th.success)
	u.run_icon.set_color(th.accent)
}
