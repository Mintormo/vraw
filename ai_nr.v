module main

// AI-шумодав в окне: нейросеть (модуль ai: SCUNet) по кнопке, в фоне, с
// прогрессом и отменой. Секция «Шумодав и ореолы», блок сверху.
//
// Как устроено:
// - Модель и ONNX Runtime идут вместе с vraw (папки рядом с программой,
//   их кладёт сборка). Нет их - кнопки неактивны, подсказка - почему.
//   Кадр с AI помнит модель (edit.ai_model) - для сайдкара; модель одна
//   (ai.model; кадр со старой моделью - до 17.10.2026 их было три -
//   пересчитывается этой), один ai.Cache (st.ai_cache).
// - Модель считает превью (raw_linear - после коррекции объектива, до
//   импульсов и вейвлета) один раз (~4 мин);
//   результат - st.ai_linear, модель результата - st.ai_lin_model.
// - Настройка кадра - edit.ai (сила 1..100, 0 - выключен): в истории и
//   сайдкаре. Подготовка сырья смешивает raw_linear с ai_linear по силе
//   (ai.blend - мгновенно), дальше как обычно: импульсы, вейвлет, ореолы.
//   Поэтому ползунок силы - без пересчёта модели. Сброс выбрасывает
//   результат: повторное включение или откат к AI - новый прогон.
// - Модель запускается ТОЛЬКО кнопкой (просьба Игоря 02.10.2026: прогон
//   долгий, сам по каждому поводу он мешал). raw_linear сменился
//   (объектив, другой кадр, откат истории) - ai_linear устарел
//   (raw_gen): превью идёт без AI, блок показывает «Пересчитать AI» и
//   сброс, один раз - тост. Экспорт с AI считает модель сам.
// - Экспорт с AI считает модель на полном кадре (~16 мин) в save_worker; его прогресс - в диалоге экспорта (export_ui.v).
import time
import vgui
import ai
import i18n

// AiCtl - один прогон модели по превью. cancel пишет главный
// поток, читает воркер между плитками без синхронизации (опоздание на
// одну плитку безвредно, как ThumbStop). t1/n1 - время и номер первой
// готовой плитки (пишет только воркер) - для оценки оставшегося
// времени без учёта загрузки модели и проявки. done/total/eta пишет
// главный поток (on_progress) - для показа.
@[heap]
struct AiCtl {
mut:
	cancel bool
	t1     i64 // мс первой готовой плитки, 0 - ещё не было
	n1     int
	done   int
	total  int
	eta    f64 = -1 // секунд до конца, < 0 - ещё неизвестно
}

// AiJob - прогон превью: копия raw_linear и её номер
struct AiJob {
	gen     int // file_gen кадра
	raw_gen int
	model   string // id модели
	src     []u16 // своя ссылка (bufown.v), ai_worker отпускает
	w       int
	h       int
	cache   &ai.Cache = unsafe { nil }
	ctl     &AiCtl    = unsafe { nil }
}

struct AiResult {
mut:
	ctl       &AiCtl = unsafe { nil } // чей это прогон
	gen       int
	raw_gen   int
	model     string
	out       []u16
	err       string
	cancelled bool
	secs      f64
}

// AiUi - виджеты блока: четыре состояния в Stack (видно одно) - кнопка,
// прогресс, применён (сила и сброс - выключение AI), устарел (AI включён,
// результата под текущее сырьё нет: «Пересчитать AI» и сброс). Каждое состояние - VBox в
// своём Stack: у VBox нет публичного visible, у Stack есть.
@[heap]
struct AiUi {
mut:
	idle      &vgui.Stack       = unsafe { nil }
	running   &vgui.Stack       = unsafe { nil }
	applied   &vgui.Stack       = unsafe { nil }
	start     &vgui.Button      = unsafe { nil }
	hint      &vgui.Label       = unsafe { nil }
	bar       &vgui.ProgressBar = unsafe { nil }
	pct       &vgui.Label       = unsafe { nil }
	status    &vgui.Label       = unsafe { nil }
	stale     &vgui.Stack       = unsafe { nil }
	redo      &vgui.Button      = unsafe { nil }
	redo_hint &vgui.Label       = unsafe { nil }
	strength  &vgui.Slider      = unsafe { nil }
	ok_label  &vgui.Label       = unsafe { nil }
	ok_icon   &vgui.Icon        = unsafe { nil }
	run_icon  &vgui.Icon        = unsafe { nil }
}

// model_cache - кэш модели (создаётся при первой надобности); ошибка -
// понятный текст, чего не хватает
fn model_cache(mut st State) !&ai.Cache {
	if !isnil(st.ai_cache) {
		return st.ai_cache
	}
	lib := ai.runtime_lib(st.ai_places)
	if lib == '' || !ai.model.installed(st.ai_places) {
		return error(ai_missing_text())
	}
	st.ai_cache = ai.new_cache(ai.model.path(st.ai_places), lib)
	return st.ai_cache
}

// ai_usable - модель и ONNX Runtime лежат рядом с программой
fn ai_usable(st &State) bool {
	return ai.runtime_lib(st.ai_places) != '' && ai.model.installed(st.ai_places)
}

// ai_missing_text - почему AI недоступен (файлы идут вместе с vraw)
fn ai_missing_text() string {
	return i18n.tr('нет файлов шумодава рядом с программой (папки models и onnxruntime)')
}

// ai_estimate - оценка времени прогона модели, секунд: превью (открытый
// кадр, без него - типичные 24 Мп) или полный кадр (вдвое больше по сторонам)
fn ai_estimate(st &State, full bool) f64 {
	w := if st.pw > 0 { st.pw } else { 3000 }
	h := if st.ph > 0 { st.ph } else { 2000 }
	k := if full { 2 } else { 1 }
	return f64(ai.tile_count(w * k, h * k)) * ai.model.tile_secs
}

// fmt_dur - «40 с» / «4 мин»
fn fmt_dur(sec f64) string {
	return if sec < 60 { i18n.trf('{0} с', '${int(sec + 0.5)}') } else { i18n.trf('{0} мин', '${int(sec / 60 + 0.5)}') }
}

// ai_ready - ai_linear посчитан по текущему raw_linear и нужной моделью
fn ai_ready(st &State) bool {
	return st.ai_linear.len > 0 && st.ai_linear.len == st.raw_linear.len
		&& st.ai_raw_gen == st.raw_gen && st.ai_lin_model == ai.model.id
}

// ai_effective - сила AI, с которой сейчас надо готовить сырьё (0 - без AI:
// выключен или результата ещё нет)
fn ai_effective(st &State) f32 {
	return if st.edit.ai > 0 && ai_ready(st) { st.edit.ai } else { 0 }
}

// prep_stale - подготовленное сырьё не соответствует настройкам шумодава
// (и Capture-резкости)
fn prep_stale(st &State) bool {
	return st.nr_applied != st.edit.nr || st.ai_applied != ai_effective(st)
		|| st.dc_applied != dc_key(st.edit.params.sharp)
}

// raw_changed - в State новый raw_linear (коррекция объектива, другой
// кадр): результат модели больше не годится, идущий прогон превью - тоже
fn raw_changed(mut st State) {
	st.raw_gen++
	drop(mut st.ai_linear)
	if !isnil(st.ai_prev) {
		mut c := st.ai_prev
		c.cancel = true
		st.ai_prev = unsafe { nil }
		st.ai_restart = true // отменили не по просьбе пользователя
	}
}

// ai_check - запустить прогон превью, если его просили кнопкой
// (ai_wanted), а результата нет. Сам модель не запускает: AI кадра без
// результата (сайдкар, новое сырьё) - превью без AI и тост один раз на
// сырьё. Зовётся везде, где могло появиться сырьё или смениться настройка:
// готовая подготовка, конец загрузки кадра, откат истории, кнопка.
fn ai_check(mut st State, mut app vgui.App) {
	if !isnil(st.ai_prev) {
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
	if st.loading || st.raw_linear.len == 0 || st.lens_dirty || st.raw_pending {
		sync_ai_ui(mut st)
		return
	}
	if !st.ai_wanted {
		ai_tell_stale(mut st)
		sync_ai_ui(mut st)
		return
	}
	id := ai.model.id
	cache := model_cache(mut st) or {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_error(i18n.trf('AI-шумодав: {0}', '${err.msg()}'))
		}
		st.ai_wanted = false
		sync_ai_ui(mut st)
		return
	}
	ctl := &AiCtl{}
	st.ai_prev = ctl
	st.ai_restart = false
	job := AiJob{
		gen:     st.file_gen
		raw_gen: st.raw_gen
		model:   id
		src:     share(st.raw_linear) // только чтение: модель пишет в свой буфер
		w:       st.pw
		h:       st.ph
		cache:   cache
		ctl:     ctl
	}
	st.ai_threads << spawn ai_worker(job, mut app, st.ai_progress, st.ai_done)
	sync_ai_ui(mut st)
}

// ai_tell_stale - AI кадра включён, а результата под текущее сырьё нет:
// сказать тостом (секция может быть свёрнута), один раз на сырьё
fn ai_tell_stale(mut st State) {
	if st.edit.ai <= 0 || isnil(st.nm) {
		return
	}
	key := '${st.file_gen}/${st.raw_gen}'
	if st.ai_told == key {
		return
	}
	st.ai_told = key
	mut nm := st.nm
	nm.show_info(i18n.tr('AI-шумодав: превью пока без него - «Пересчитать AI» в секции «Шумодав и ореолы» (экспорт посчитает сам)'))
}

// AiPoster - прогресс ai.denoise (в потоке воркера): в главный поток
// через post_result (без замыканий - post.v), false - отмена
struct AiPoster {
mut:
	app         &vgui.App = unsafe { nil }
	ctl         &AiCtl    = unsafe { nil }
	on_progress fn (&AiCtl, int, int, f64) = unsafe { nil }
}

// AiTick - одно сообщение о прогрессе прогона превью
struct AiTick {
	on_progress fn (&AiCtl, int, int, f64) = unsafe { nil }
	ctl         &AiCtl = unsafe { nil }
	done        int
	total       int
	eta         f64
}

fn deliver_ai_tick(t AiTick) {
	t.on_progress(t.ctl, t.done, t.total, t.eta)
}

fn (mut p AiPoster) step(done int, total int) bool {
	mut c := p.ctl
	now := time.now().unix_milli()
	mut eta := f64(-1)
	if c.t1 == 0 {
		c.t1 = now
		c.n1 = done
	} else if done > c.n1 {
		eta = f64(now - c.t1) / 1000 / f64(done - c.n1) * f64(total - done)
	}
	mut app := p.app
	post_result(mut app, deliver_ai_tick, AiTick{
		on_progress: p.on_progress
		ctl:         p.ctl
		done:        done
		total:       total
		eta:         eta
	})
	return !c.cancel
}

// ai_worker - прогон модели по превью в spawn; без State и vgui, кроме
// app.post (потокобезопасен по контракту vgui)
fn ai_worker(job AiJob, mut app vgui.App, on_progress fn (&AiCtl, int, int, f64), on_done fn (AiResult)) {
	sw := time.new_stopwatch()
	mut jsrc := unsafe { job.src }
	defer {
		drop(mut jsrc)
	}
	mut res := AiResult{
		ctl:     job.ctl
		gen:     job.gen
		raw_gen: job.raw_gen
		model:   job.model
	}
	mut cache := unsafe { job.cache }
	if model := cache.get() {
		mut progress := AiPoster{
			app:         app
			ctl:         job.ctl
			on_progress: on_progress
		}
		mut out := own_new[u16](job.w * job.h * 3)
		if _ := ai.denoise_into(model, unsafe { &u16(job.src.data) }, job.w, job.h, mut out, mut
			progress)
		{
			res = AiResult{
				...res
				out: out
			}
		} else {
			drop(mut out)
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
	post_result(mut app, on_done, res)
}

// ai_take - итог прогона превью (главный поток, из app.post)
fn ai_take(mut st State, mut app vgui.App, res AiResult) {
	// Результат модели (bufown.v) - в State или отпускается
	mut r := res
	if st.ai_prev != res.ctl {
		drop(mut r.out)
		// Прогон, отменённый сменой сырья или кадра: если нужен - уже
		// перезапускается (или будет запущен ai_check)
		if st.ai_restart && res.gen == st.file_gen {
			ai_check(mut st, mut app)
		}
		return
	}
	st.ai_prev = unsafe { nil }
	if res.cancelled || res.err.len > 0 {
		drop(mut r.out)
	}
	if res.cancelled {
		// Отменил пользователь: AI кадра (если был включён) не трогаем -
		// сам он больше не запустится, блок покажет «Пересчитать AI»
		st.ai_wanted = false
		sync_ai_ui(mut st)
		return
	}
	if res.err.len > 0 {
		st.ai_wanted = false
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_error(i18n.trf('AI-шумодав: {0}', '${res.err}'))
		}
		sync_ai_ui(mut st)
		return
	}
	if res.gen != st.file_gen || res.raw_gen != st.raw_gen || res.model != ai.model.id {
		drop(mut r.out)
		ai_check(mut st, mut app)
		return
	}
	drop(mut st.ai_linear)
	st.ai_linear = res.out
	st.ai_raw_gen = res.raw_gen
	st.ai_lin_model = res.model
	if st.ai_wanted {
		ai_turn_on(mut st, mut app)
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_success(i18n.trf('AI-шумодав готов ({0} с)', '${res.secs:.0f}'))
		}
	} else if prep_stale(st) {
		request_prep(mut st, mut app, false)
	}
	sync_ai_ui(mut st)
}

// ai_turn_on - результат есть, включить AI в настройках кадра (сила 100)
// и записать в историю. Пересчёт уже включённого AI («Пересчитать AI») -
// сила и история те же, только подготовка сырья с новым результатом.
fn ai_turn_on(mut st State, mut app vgui.App) {
	st.ai_wanted = false
	if st.edit.ai > 0 {
		request_prep(mut st, mut app, false)
		sync_ai_ui(mut st)
		return
	}
	if !isnil(st.ai_ui) && !isnil(st.ai_ui.strength) {
		st.suppress = true
		mut sl := st.ai_ui.strength
		sl.set_value(100)
		st.suppress = false
	}
	st.edit.ai = 100
	st.edit.ai_model = st.ai_lin_model
	request_prep(mut st, mut app, false)
	record(mut st, 'ai', i18n.tr('AI-шумодав'), false)
	sync_ai_ui(mut st)
}

// ai_turn_off - сброс AI (кнопка ↺ в строке «Сила» или у «Пересчитать AI»):
// выключить и выбросить результат модели - следующее «Убрать шум (AI)»
// считает заново (так просил Игорь: сброс - это сброс, без кэша). Откат
// истории к записи с AI - превью без AI до «Пересчитать AI».
fn ai_turn_off(mut st State, mut app vgui.App) {
	st.edit.ai = 0
	st.edit.ai_model = ''
	drop(mut st.ai_linear)
	request_prep(mut st, mut app, false)
	record(mut st, 'ai', i18n.tr('AI-шумодав: выкл'), false)
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
	drop(mut st.ai_linear)
	st.ai_applied = 0
	st.raw_gen++
	sync_ai_ui(mut st)
}

// fmt_eta - «осталось ~25 с» / «~3 мин»
fn fmt_eta(sec f64) string {
	if sec < 0 {
		return i18n.tr('оценка времени...')
	}
	if sec < 60 {
		return i18n.trf('осталось ~{0} с', '${int(sec + 0.5)}')
	}
	return i18n.trf('осталось ~{0} мин', '${int(sec / 60 + 0.5)}')
}

// sync_ai_ui - какое состояние блока показать. Приоритет - идущий прогон
// превью, затем «применён» / кнопка. Экспорт с AI - в своём диалоге.
fn sync_ai_ui(mut st State) {
	// Кнопки «Удалить» в настройках гаснут на время прогона
	sync_settings_ui(mut st)
	if isnil(st.ai_ui) {
		return
	}
	mut u := st.ai_ui
	ctl := st.ai_prev
	running := !isnil(ctl)
	applied := !running && st.edit.ai > 0 && ai_ready(st)
	stale := !running && st.edit.ai > 0 && !applied
	u.running.visible = running
	u.applied.visible = applied
	u.stale.visible = stale
	u.idle.visible = !running && !applied && !stale
	if running {
		what := i18n.tr('Превью')
		if ctl.total == 0 {
			u.bar.set_value(0)
			u.pct.text = ''
			u.status.text = i18n.trf('{0} · загрузка модели...', '${what}')
		} else {
			u.bar.set_value(f32(ctl.done) / f32(ctl.total))
			u.pct.text = '${ctl.done * 100 / ctl.total}%'
			u.status.text = '${what} · ${fmt_eta(ctl.eta)}'
		}
	}
	if applied {
		mut l := u.ok_label
		l.text = i18n.trf('AI-шумодав применён · {0}', ai.model.title)
	}
	// Нет файлов модели - кнопки неактивны, подсказка - почему
	usable := ai_usable(st)
	if stale {
		mut rb := u.redo
		mut rh := u.redo_hint
		rb.enabled = usable && !isnil(st.dev) && !st.loading
		rh.text = if usable {
			i18n.trf('{0} · превью пока без AI, пересчёт ~{1}', ai.model.title, '${fmt_dur(ai_estimate(st, false))}')
		} else {
			i18n.trf('AI недоступен: {0}', ai_missing_text())
		}
	}
	mut b := u.start
	mut hint := u.hint
	b.enabled = usable && !isnil(st.dev) && !st.loading
	hint.text = if usable {
		i18n.trf('{0} · превью ~{1}, экспорт ~{2}', ai.model.title, '${fmt_dur(ai_estimate(st, false))}', '${fmt_dur(ai_estimate(st, true))}')
	} else {
		i18n.trf('AI недоступен: {0}', ai_missing_text())
	}
}

// build_ai_block - блок AI-шумодава в секции «Шумодав и ореолы»: Stack
// четырёх состояний одной высоты (ai_block_h), видно одно (sync_ai_ui).
// strength - ползунок силы (edit_slider, fx - подготовка сырья).
fn build_ai_block(mut st State, mut app vgui.App, mut strength EditSlider, lw f32, vw f32) &vgui.Stack {
	mut u := &AiUi{}
	st.ai_ui = u
	// Кнопка запуска и подсказка
	mut start := vgui.button(i18n.tr('Убрать шум (AI)'))
	start.icon_name = 'sparkles'
	start.icon_size = 15
	start.style = .accent
	start.on_click = fn [mut st, mut app] () {
		ai_start(mut st, mut app)
	}
	u.start = start
	// Высоты рядов слоёв - их собственные (measure): Label сам учитывает
	// свой внутренний отступ
	mut hint := vgui.label('')
	st.hint_labels << hint
	u.hint = hint
	mut idle := vgui.create_vbox_fill()
	idle.set_spacing(ai_row_gap)
	idle.add(start)
	idle.add(hint)
	u.idle = layer(idle)

	// Прогресс: полоса, проценты, отмена; под ними - что и сколько осталось
	mut bar := vgui.progress_bar_linear()
	bar.thickness = 6
	u.bar = bar
	mut pct := value_label('')
	u.pct = pct
	mut cancel := icon_button('circle-x', i18n.tr('Отменить'))
	cancel.on_click = fn [mut st] () {
		ctl := st.ai_prev
		if !isnil(ctl) {
			mut c := unsafe { ctl }
			c.cancel = true
			if !isnil(st.ai_ui) {
				mut s := st.ai_ui.status
				s.text = i18n.tr('Отмена...')
			}
		}
	}
	mut run_icon := vgui.icon('sparkles')
	run_icon.set_size(15)
	u.run_icon = run_icon
	mut prow := vgui.create_hbox_fill()
	prow.set_spacing(6)
	prow.add(run_icon)
	prow.add(bar, flex: 1)
	prow.add(pct, min: vw)
	prow.add(cancel)
	mut status := vgui.label('')
	st.secondary_labels << status
	u.status = status
	mut running := vgui.create_vbox_fill()
	running.set_spacing(ai_row_gap)
	running.add(prow)
	running.add(status)
	u.running = layer(running)
	u.running.visible = false

	// Применён: сила (ползунок настройки кадра) и сброс. Сброс здесь -
	// не «сила по умолчанию», а выключение AI: как у классических
	// ползунков, где сброс = 0 = шумодава нет (сила 100 и так по умолчанию,
	// обычный сброс ничего бы не делал). Результат модели выбрасывается.
	mut off := reset_button(i18n.tr('Сбросить AI-шумодав'))
	off.on_click = fn [mut st, mut app] () {
		if st.edit.ai > 0 {
			ai_turn_off(mut st, mut app)
		}
	}
	mut srow := vgui.create_hbox_fill()
	srow.set_spacing(6)
	srow.add(strength.lb, min: lw)
	srow.add(strength.sl, flex: 1)
	srow.add(strength.vl, min: vw)
	srow.add(off)
	u.strength = strength.sl
	mut ok_icon := vgui.icon('circle-check')
	ok_icon.set_size(14)
	u.ok_icon = ok_icon
	mut ok_lb := vgui.label(i18n.tr('AI-шумодав применён'))
	st.secondary_labels << ok_lb
	u.ok_label = ok_lb
	mut orow := vgui.create_hbox_fill()
	orow.set_spacing(4)
	orow.add(ok_icon)
	orow.add(ok_lb, flex: 1)
	mut applied := vgui.create_vbox_fill()
	applied.set_spacing(ai_row_gap)
	applied.add(srow)
	applied.add(orow)
	u.applied = layer(applied)
	u.applied.visible = false

	// Устарел: AI кадра включён, результата под текущее сырьё нет -
	// пересчёт по кнопке (сам не запускается) или выключение
	mut redo := vgui.button(i18n.tr('Пересчитать AI'))
	redo.icon_name = 'refresh-cw'
	redo.icon_size = 15
	redo.style = .accent
	redo.on_click = fn [mut st, mut app] () {
		ai_start(mut st, mut app)
	}
	u.redo = redo
	mut off2 := reset_button(i18n.tr('Сбросить AI-шумодав'))
	off2.on_click = fn [mut st, mut app] () {
		if st.edit.ai > 0 {
			ai_turn_off(mut st, mut app)
		}
	}
	mut rrow := vgui.create_hbox_fill()
	rrow.set_spacing(6)
	rrow.add(redo, flex: 1)
	rrow.add(off2)
	mut redo_hint := vgui.label('')
	st.hint_labels << redo_hint
	u.redo_hint = redo_hint
	mut stale := vgui.create_vbox_fill()
	stale.set_spacing(ai_row_gap)
	stale.add(rrow)
	stale.add(redo_hint)
	u.stale = layer(stale)
	u.stale.visible = false

	mut stack := &vgui.Stack{}
	stack.add(u.idle)
	stack.add(u.running)
	stack.add(u.applied)
	stack.add(u.stale)
	sync_ai_ui(mut st)
	return stack
}

// ai_start - кнопка «Убрать шум (AI)» / «Пересчитать AI»: прогон превью
fn ai_start(mut st State, mut app vgui.App) {
	if !ai_usable(st) || isnil(st.dev) || st.loading {
		return
	}
	st.ai_wanted = true
	ai_check(mut st, mut app)
}

// layer - слой Stack с одним виджетом (его можно скрыть)
fn layer(w &vgui.Widget) &vgui.Stack {
	mut s := &vgui.Stack{}
	s.add(w)
	return s
}

const ai_row_gap = f32(6)

// paint_ai - цвета значков блока по теме (paint_ui)
fn paint_ai(mut st State, th vgui.Theme) {
	if isnil(st.ai_ui) {
		return
	}
	mut u := st.ai_ui
	u.ok_icon.set_color(th.success)
	u.run_icon.set_color(th.accent)
}
