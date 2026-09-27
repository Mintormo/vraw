module main

// vraw-gui - проявка RAW с собственным пайплайном.
//
// LibRaw используется только как источник сырья: демозаика + камерный ББ,
// линейные 16-битные данные (см. raw.DevParams.linear16). Вся тональная
// работа - модуль pipeline: экспозиция, тени, тон-эквалайзер, контраст,
// насыщенность. Пайплайн построен на таблицах, поэтому любой ползунок
// применяется к превью вживую, без перепроявки LibRaw.
//
// Превью показывается в vgui.Canvas (зум колесом, панорама средней/правой
// кнопкой). Панель управления справа, как в проявщиках; сверху - RGB-гистограмма
// результата (каналы смешиваются аддитивно: R+G - жёлтый, все три - серый).
import os
import math
import time
import stbi
import vgui
import raw
import lens
import pipeline

const raw_patterns = 'CR3;CR2;CRW;NEF;ARW;DNG;RAF;ORF;RW2;cr3;cr2;crw;nef;arw;dng;raf;orf;rw2'

struct State {
mut:
	dev          &raw.Developer = unsafe { nil }
	dev_linear   []u16 // превью прямо из LibRaw, без коррекции объектива
	raw_linear   []u16 // превью после коррекции объектива, ДО шумодава
	linear       []u16 // линейное 16-битное RGB-превью (half-size), сырьё пайплайна
	mask         []u16 // размытая люма превью - маска «Тени/Света» (pipeline.blur_luma)
	pw           int   // размеры превью
	ph           int
	edit         EditState // все настройки правки кадра (history.v)
	quality      int = 92
	hl_developed int = -1 // режим пересветов последней проявки (не проявлять зря)
	// true = пакетная установка виджетов (откат истории, сброс, новый файл):
	// on_change только пишут настройки - без пересчётов и записей в историю
	suppress bool
	meta         raw.Meta // метаданные открытого кадра (для профиля объектива)
	corr         &lens.Corrector = unsafe { nil } // профиль lensfun или nil
	curve        []f32 // камерная кривая кадра (match_curve), пустая - нет превью
	nr_applied   [4]f32 = [f32(-1), -1, -1, -1]! // значения последней подготовки сырья
	save_threads []thread // хендлы фоновых сохранений: wait после app.run()
	// Подготовка сырья в фоне (prep_worker): не больше одного воркера.
	// Запрос во время работы только меняет настройки - prep_done сверит
	// их с применёнными и запустит ещё один проход.
	file_gen     int  // номер открытого файла: результат старого файла отбрасывается
	lens_dirty   bool // raw_linear устарел - нужна коррекция объектива из dev_linear
	prep_running bool
	prep_threads []thread
	prep_done    fn (PrepResult) = unsafe { nil } // приём результата в главном потоке
	// Тональные кривые: точки - в edit.curve_pts, редактор показывает
	// выбранный канал (curve_ch), остальные - призраками
	curve_ch  int
	curve_ed  &vgui.CurveEditor = unsafe { nil }
	curve_btns []&vgui.Button // кнопки RGB/R/G/B, активная - стиль accent
	// Последние гистограммы результата (render_histogram) - фон редактора кривых
	hist_r []u32
	hist_g []u32
	hist_b []u32
	// История правок (history.v): записи, текущая, время последней записи
	// для склейки шагов (0 - не склеивать), особое название следующей записи
	history    []HistEntry
	hist_pos   int
	hist_ms    i64
	hist_label string
	// Виджеты, которые выставляет откат истории (set_edit)
	binds   []SliderBind
	lens_cb &vgui.CheckBox = unsafe { nil }
	crv_cb  &vgui.CheckBox = unsafe { nil }
	hist_lb &vgui.ListBox  = unsafe { nil }
}

// highlight_name - подпись режима пересветов LibRaw (аналог dcraw -H)
fn highlight_name(h int) string {
	return match h {
		0 { 'клип' }
		1 { 'без клипа' }
		2 { 'смешение' }
		else { 'восстан. ${h}' }
	}
}

// apply_pipeline прогоняет превью через пайплайн в холст и обновляет
// гистограмму. Вызывается при отпускании тонального ползунка и на каждое
// одиночное изменение (колесо, клавиши, сброс), поэтому никаких
// уведомлений отсюда - только картинка.
fn apply_pipeline(mut st State, mut cv vgui.Canvas, mut hist vgui.Canvas) {
	if st.suppress || st.linear.len == 0 {
		return
	}
	npix := st.pw * st.ph
	pipeline.apply(unsafe { &u16(st.linear.data) }, unsafe { &u16(st.mask.data) }, npix, st.edit.params, mut cv.pixels, 4)
	cv.mark_dirty()
	st.hist_r, st.hist_g, st.hist_b = render_histogram(mut hist, cv.pixels)
	update_curve_histogram(mut st)
}

// load_preview проявляет открытый RAW в линейное 16-битное превью
// (LibRaw, ~0.1 с, в главном потоке) и запускает подготовку сырья:
// при async - в фоне (смена пересветов), иначе сразу (открытие файла -
// камерной кривой нужна готовая картинка; смена размера - холст и
// буферы должны совпасть до первого apply).
fn load_preview(mut st State, mut cv vgui.Canvas, mut hist vgui.Canvas, mut nm vgui.NotificationManager, mut app vgui.App, async bool) {
	if isnil(st.dev) {
		return
	}
	mut img := st.dev.develop(half: true, linear16: true, highlight: st.edit.highlight) or {
		nm.show_error('Ошибка проявки: ${err.msg()}')
		return
	}
	st.hl_developed = st.edit.highlight
	resized := img.width != st.pw || img.height != st.ph
	if resized || !async {
		// Воркер считает буфер старого размера - дождаться до смены pw/ph
		wait_prep(mut st)
	}
	st.pw = img.width
	st.ph = img.height
	n := img.width * img.height * 3
	st.dev_linear = []u16{len: n}
	unsafe { vmemcpy(st.dev_linear.data, img.data_u16(), n * 2) }
	img.free()
	st.lens_dirty = true

	if resized {
		// Холст под новый размер: тот же приём, что в Canvas.load_from_surface.
		// При перепроявке того же файла (смена режима пересветов) размер
		// не меняется - зум и панораму не сбрасываем.
		cv.width = st.pw
		cv.height = st.ph
		cv.pixels = []u8{len: st.pw * st.ph * 4}
		cv.destroy_texture()
		cv.dirty = true
		cv.fit_to_view()
	}

	if async && !resized {
		request_prep(mut st, mut app, true)
	} else {
		take_prep(mut st, prep_compute(make_prep_job(mut st)))
		apply_pipeline(mut st, mut cv, mut hist)
	}
}

// PrepJob - снимок для подготовки сырья: коррекция объектива (только при
// redo_lens - src это выход LibRaw), импульсы, шумодав, ореолы, маска
// «Тени/Света». src - собственная копия буфера. corr общий с GUI: его
// освобождение (открытие другого файла, выход) сначала ждёт воркер
// (wait_prep), а воркер одновременно работает только один.
struct PrepJob {
	gen       int
	src       []u16
	w         int
	h         int
	redo_lens bool
	corr      &lens.Corrector = unsafe { nil } // nil - без коррекции
	focal     f32
	aperture  f32
	nr        [4]f32 // импульсный, яркостный, цветовой, ореолы
}

struct PrepResult {
	gen        int
	raw_linear []u16 // после коррекции объектива; пусто, если коррекция не пересчитывалась
	linear     []u16
	mask       []u16
	nr         [4]f32
}

// make_prep_job снимает параметры подготовки с State (главный поток)
fn make_prep_job(mut st State) PrepJob {
	redo := st.lens_dirty
	st.lens_dirty = false
	return PrepJob{
		gen:       st.file_gen
		src:       if redo { st.dev_linear.clone() } else { st.raw_linear.clone() }
		w:         st.pw
		h:         st.ph
		redo_lens: redo
		corr:      if st.edit.lens_corr { st.corr } else { unsafe { nil } }
		focal:     st.meta.focal
		aperture:  st.meta.aperture
		nr:        st.edit.nr
	}
}

// prep_compute - сама подготовка сырья, без обращений к State и vgui:
// выполняется и в фоне (prep_worker), и напрямую (открытие файла).
// Коррекция объектива ~0.6 с, импульсы ~1 с, шумодав ~1 с, ореолы ~0.5 с,
// маска ~0.35 с на превью.
fn prep_compute(job PrepJob) PrepResult {
	buf := unsafe { &u16(job.src.data) }
	if job.redo_lens && !isnil(job.corr) {
		job.corr.vignetting(buf, job.w, job.h, job.focal, job.aperture)
		// Дисторсия + TCA - строго после виньетирования (ремап двигает пиксели)
		job.corr.geometry(buf, job.w, job.h, job.focal)
	}
	// raw_linear - точка возврата для следующего пересчёта шумодава
	raw_linear := if job.redo_lens { job.src.clone() } else { []u16{} }
	// Импульсы - до шумодава: вейвлет размазал бы выброс по уровням
	if job.nr[0] > 0 {
		pipeline.impulse(buf, job.w, job.h, job.nr[0])
	}
	if job.nr[1] > 0 || job.nr[2] > 0 {
		pipeline.denoise(buf, job.w, job.h, job.nr[1], job.nr[2])
	}
	if job.nr[3] > 0 {
		pipeline.defringe(buf, job.w, job.h, job.nr[3])
	}
	// Маска «Тени/Света» зависит только от сырья (после коррекции
	// объектива и шумодава!), поэтому считается здесь, а не на каждый ползунок.
	mask := pipeline.blur_luma(buf, job.w, job.h)
	return PrepResult{
		gen:        job.gen
		raw_linear: raw_linear
		linear:     job.src
		mask:       mask
		nr:         job.nr
	}
}

// take_prep принимает результат подготовки в State (главный поток).
// Буферы передаются без копирования: воркер их больше не трогает.
fn take_prep(mut st State, res PrepResult) {
	if res.raw_linear.len > 0 {
		st.raw_linear = res.raw_linear
	}
	st.linear = res.linear
	st.mask = res.mask
	st.nr_applied = res.nr
}

// prep_worker выполняется в spawn; результат уходит в главный поток
// через app.post() (единственный потокобезопасный вход vgui).
fn prep_worker(job PrepJob, mut app vgui.App, on_done fn (PrepResult)) {
	res := prep_compute(job)
	app.post(fn [on_done, res] () {
		on_done(res)
	})
}

// request_prep запускает подготовку сырья в фоне (коррекция объектива,
// шумодав, ореолы) - окно не замирает. redo_lens - нужна коррекция
// объектива заново (из dev_linear). Если воркер уже работает, запрос
// откладывается: prep_done увидит изменившиеся настройки и запустит
// один проход с последними значениями.
fn request_prep(mut st State, mut app vgui.App, redo_lens bool) {
	if redo_lens {
		st.lens_dirty = true
	}
	if st.dev_linear.len == 0 {
		return
	}
	if st.prep_running {
		return
	}
	st.prep_running = true
	job := make_prep_job(mut st)
	st.prep_threads << spawn prep_worker(job, mut app, st.prep_done)
}

// wait_prep дожидается фонового воркера.
// Нужна перед освобождением st.corr (воркер им пользуется) и перед
// синхронной подготовкой. Результат дождавшегося воркера уже в очереди
// app.post - его отбросит проверка file_gen/prep_running в prep_done.
fn wait_prep(mut st State) {
	for t in st.prep_threads {
		t.wait()
	}
	st.prep_threads.clear()
	st.prep_running = false
}

// SaveJob - всё, что нужно фоновому потоку сохранения, копиями по значению.
// Поток НЕ делит с GUI ни LibRaw-хендл, ни Corrector: пока он работает,
// пользователь может открыть другой файл (st.dev/st.corr сменятся или
// освободятся), поэтому воркер открывает свои.
struct SaveJob {
	src        string
	dst        string
	highlight  int
	lens_corr  bool
	nr_impulse f32
	nr_luma    f32
	nr_chroma  f32
	defringe   f32
	params     pipeline.Params
	quality    int
}

// report доставляет результат из фонового потока в главный:
// app.post() - единственный потокобезопасный вход vgui, замыкание
// выполнится в потоке App между событиями и рендером. ok выбирает
// вид уведомления (успех/ошибка) на принимающей стороне.
fn report(mut app vgui.App, on_done fn (bool, string), ok bool, msg string) {
	app.post(fn [on_done, ok, msg] () {
		on_done(ok, msg)
	})
}

// save_worker выполняется в spawn: полная проявка и запись JPEG без единого
// обращения к vgui или общему состоянию - кроме app.post() (потокобезопасен
// по контракту vgui). Результат - уведомление через report.
fn save_worker(job SaveJob, mut app vgui.App, on_done fn (bool, string)) {
	sw := time.new_stopwatch()
	mut d := raw.open(job.src) or {
		report(mut app, on_done, false, 'Ошибка проявки: ${err.msg()}')
		return
	}
	defer {
		d.close()
	}
	mut img := d.develop(linear16: true, highlight: job.highlight) or {
		report(mut app, on_done, false, 'Ошибка проявки: ${err.msg()}')
		return
	}
	w := img.width
	h := img.height
	if job.lens_corr {
		m := d.meta()
		mut c := lens.find(m.cam_make, m.cam_model, m.lens) or { unsafe { nil } }
		if !isnil(c) {
			c.vignetting(img.data_u16(), w, h, m.focal, m.aperture)
			c.geometry(img.data_u16(), w, h, m.focal)
			c.free()
		}
	}
	if job.nr_impulse > 0 {
		pipeline.impulse(img.data_u16(), w, h, job.nr_impulse)
	}
	if job.nr_luma > 0 || job.nr_chroma > 0 {
		pipeline.denoise(img.data_u16(), w, h, job.nr_luma, job.nr_chroma)
	}
	if job.defringe > 0 {
		pipeline.defringe(img.data_u16(), w, h, job.defringe)
	}
	mask := pipeline.blur_luma(img.data_u16(), w, h)
	mut rgb := []u8{len: w * h * 3}
	pipeline.apply(img.data_u16(), unsafe { &u16(mask.data) }, w * h, job.params, mut rgb, 3)
	img.free()
	stbi.stbi_write_jpg(job.dst, w, h, 3, rgb.data, job.quality) or {
		report(mut app, on_done, false, 'Не удалось сохранить: ${err}')
		return
	}
	size_mb := f64(os.file_size(job.dst)) / 1024 / 1024
	sec := f64(sw.elapsed().milliseconds()) / 1000.0
	report(mut app, on_done, true, 'Сохранено: ${job.dst} (${w}x${h}, ${size_mb:.1f} МБ, качество ${job.quality}, ${sec:.1f} с)')
}

// render_histogram считает и рисует RGB-гистограмму по 8-битному результату
// (RGBA-буфер холста). Сэмплируется каждый второй пиксель - на форму
// гистограммы это не влияет, а стоимость вдвое ниже.
fn render_histogram(mut hist vgui.Canvas, pixels []u8) ([]u32, []u32, []u32) {
	mut hr := []u32{len: 256}
	mut hg := []u32{len: 256}
	mut hb := []u32{len: 256}
	unsafe {
		mut s := &u8(pixels.data)
		pr := &u32(hr.data)
		pg := &u32(hg.data)
		pb := &u32(hb.data)
		for _ in 0 .. pixels.len / 8 {
			pr[s[0]]++
			pg[s[1]]++
			pb[s[2]]++
			s += 8
		}
	}
	mut mx := u32(1)
	for i in 0 .. 256 {
		if hr[i] > mx {
			mx = hr[i]
		}
		if hg[i] > mx {
			mx = hg[i]
		}
		if hb[i] > mx {
			mx = hb[i]
		}
	}
	w := hist.width // 256: колонка = бин
	h := hist.height
	unsafe {
		mut p := &u8(hist.pixels.data)
		for x in 0 .. w {
			th_r := int(u64(hr[x]) * u64(h) / u64(mx))
			th_g := int(u64(hg[x]) * u64(h) / u64(mx))
			th_b := int(u64(hb[x]) * u64(h) / u64(mx))
			for y in 0 .. h {
				up := h - y // высота столбца, накрывающего строку y
				mut d := p + (y * w + x) * 4
				d[0] = if th_r >= up { u8(224) } else { u8(16) }
				d[1] = if th_g >= up { u8(214) } else { u8(16) }
				d[2] = if th_b >= up { u8(234) } else { u8(18) }
				d[3] = 255
			}
		}
	}
	hist.mark_dirty()
	return hr, hg, hb
}

// auto_exposure_ev подбирает экспозицию по линейному превью: медиана
// люмы приводится к среднему серому (18% линейно - это ~0.46 после
// гаммы 2.2, середина тонов). Вариант «дотянуть света до 1% клипа»
// (авто-яркость dcraw) отвергнут: на контровом свете (тёмная комната,
// яркое окно) света уже клипнуты и он даёт 0 EV - см. IMG_0631.
fn auto_exposure_ev(linear []u16, npix int) f32 {
	if npix == 0 {
		return 0
	}
	mut hist := []u32{len: 65536}
	unsafe {
		mut s := &u16(linear.data)
		ph := &u32(hist.data)
		for _ in 0 .. npix {
			// Целочисленная BT.709-люма - как в пайплайне
			y := (54 * u32(s[0]) + 183 * u32(s[1]) + 19 * u32(s[2])) >> 8
			ph[y]++
			s += 3
		}
	}
	half := u64(npix) / 2
	mut acc := u64(0)
	mut med := 0
	for i in 0 .. 65536 {
		acc += u64(hist[i])
		if acc >= half {
			med = i
			break
		}
	}
	if med < 1 {
		med = 1 // защита от log2(inf) на полностью чёрном кадре
	}
	mut ev := f32(math.log2(0.18 * 65535.0 / f64(med)))
	// В пределы ползунка экспозиции
	if ev < -4 {
		ev = -4
	}
	if ev > 4 {
		ev = 4
	}
	return ev
}

// setup_curve строит камерную кривую только что открытого файла: встроенный
// JPEG камеры + гистограммное сопоставление с нейтральной проявкой
// (pipeline.match_curve, приём «Автоопределение тоновой кривой» RT).
// Вызывается ПОСЛЕ load_preview (нужно линейное превью) и только при
// открытии файла: кривая - статичное свойство кадра, смена пересветов
// или коррекции объектива её практически не меняет.
fn setup_curve(mut st State, mut crv_cb vgui.CheckBox, mut cv vgui.Canvas, mut hist vgui.Canvas) {
	st.curve = []f32{}
	st.edit.params.curve = []f32{}
	if st.linear.len == 0 {
		crv_cb.enabled = false
		return
	}
	tj := st.dev.thumb() or {
		crv_cb.enabled = false
		return
	}
	mut timg := stbi.load_from_memory(tj.data, tj.len, desired_channels: 3) or {
		crv_cb.enabled = false
		return
	}
	st.curve = pipeline.match_curve(unsafe { &u16(st.linear.data) }, st.pw * st.ph, timg.data,
		timg.width * timg.height)
	timg.free()
	crv_cb.enabled = true
	if st.edit.use_curve {
		st.edit.params.curve = st.curve.clone()
		apply_pipeline(mut st, mut cv, mut hist)
	}
}

// setup_corrector ищет профиль lensfun для только что открытого файла
// и обновляет чекбокс коррекции: имя профиля в подписи-пояснении,
// недоступность чекбокса, если профиля нет.
fn setup_corrector(mut st State, mut lens_cb vgui.CheckBox, mut lens_lb vgui.Label) {
	if !isnil(st.corr) {
		st.corr.free()
		st.corr = unsafe { nil }
	}
	st.meta = st.dev.meta()
	if c := lens.find(st.meta.cam_make, st.meta.cam_model, st.meta.lens) {
		st.corr = c
		lens_lb.text = c.lens_name
		lens_cb.enabled = true
	} else {
		lens_lb.text = 'профиль объектива не найден'
		lens_cb.enabled = false
	}
}

// slider_row собирает стандартный ряд панели: подпись, ползунок, значение
// справа от ползунка и кнопка сброса этого параметра. set_value сам вызывает
// on_change ползунка, поэтому кнопке достаточно вернуть значение по умолчанию.
// Ширины колонок подписи/значения общие на всю панель - считаются в main
// через column_width, чтобы колонки рядов были выровнены.
fn slider_row(lb &vgui.Label, mut sl vgui.Slider, vl &vgui.Label, def f32, lw f32, vw f32) &vgui.HBox {
	mut b := vgui.button('×')
	b.style = .outline
	b.on_click = fn [mut sl, def] () {
		sl.set_value(def)
	}
	mut row := vgui.create_hbox_fill()
	row.set_spacing(6)
	row.add_fixed(lb, lw)
	row.add(sl, 1)
	row.add_fixed(vl, vw)
	row.add_fixed(b, 26)
	return row
}

// column_width - ширина колонки панели: максимум по строкам-кандидатам,
// измеренным реальным шрифтом окна (win.measure_text работает сразу после
// create_window, до первого кадра), плюс небольшой запас до соседа.
fn column_width(mut win vgui.Window, texts []string, slack f32) f32 {
	mut w := f32(0)
	for t in texts {
		tw := win.measure_text(t).x
		if tw > w {
			w = tw
		}
	}
	return w + slack
}

// value_label - подпись текущего значения справа от ползунка,
// прижата к правому краю (к кнопке сброса).
fn value_label(text string) &vgui.Label {
	mut l := vgui.label(text)
	l.align = .right
	return l
}

// SliderCfg - описание ползунка настройки кадра для edit_slider
struct SliderCfg {
	label  string // подпись ряда
	hname  string // название в истории (пусто - как подпись); оно же ключ склейки
	min    f32
	max    f32
	def    f32
	digits int  = 2    // знаков после запятой в значении; 0 - целые, step 1
	signed bool = true // в истории со знаком: «Экспозиция +0.70»
	show   fn (f32) string         = unsafe { nil } // своя подпись значения (пересветы)
	get    fn (&EditState) f32     = unsafe { nil } // значение в снимке (откат)
	set    fn (mut e EditState, v f32) = unsafe { nil } // запись значения в st.edit
	fx     fn ()                   = unsafe { nil } // пересчёт после завершённой правки
}

// EditSlider - собранный ползунок: подпись, ползунок, значение
struct EditSlider {
mut:
	lb  &vgui.Label  = unsafe { nil }
	sl  &vgui.Slider = unsafe { nil }
	vl  &vgui.Label  = unsafe { nil }
	def f32
}

fn slider_text(cfg SliderCfg, v f32) string {
	if !isnil(cfg.show) {
		return cfg.show(v)
	}
	return if cfg.digits == 0 { '${int(v)}' } else { '${v:.2f}' }
}

fn slider_hist_text(cfg SliderCfg, v f32) string {
	if !isnil(cfg.show) {
		return cfg.show(v)
	}
	return if cfg.signed { fmt_signed(v, cfg.digits) } else { slider_text(cfg, v) }
}

// edit_slider собирает ползунок настройки кадра по единому паттерну
// (паттерн «Пересветов»): при перетаскивании on_change пишет только
// значение (cfg.set -> st.edit) и подпись, пересчёт cfg.fx и запись в
// историю - в on_release. Одиночные on_change (колесо, клавиши, «×»)
// пересчитывают сразу и пишут в историю со склейкой шагов. Под
// st.suppress (откат, сброс, новый файл) - только значение и подпись.
// Ползунок регистрируется в st.binds: откат выставит его по снимку.
fn edit_slider(mut st State, cfg SliderCfg) EditSlider {
	lb := vgui.label(cfg.label)
	mut vl := value_label(slider_text(cfg, cfg.def))
	mut sl := vgui.slider_horizontal(cfg.min, cfg.max, cfg.def)
	if cfg.digits == 0 {
		sl.step = 1
	}
	key := if cfg.hname.len > 0 { cfg.hname } else { cfg.label }
	sl.on_change = fn [mut st, mut vl, mut sl, cfg, key] (v f32) {
		cfg.set(mut st.edit, v)
		vl.text = slider_text(cfg, v)
		if st.suppress || sl.dragging {
			return
		}
		cfg.fx()
		record(mut st, key, '${key} ${slider_hist_text(cfg, v)}', true)
	}
	sl.on_release = fn [mut st, cfg, key] (v f32) {
		cfg.fx()
		record(mut st, key, '${key} ${slider_hist_text(cfg, v)}', false)
	}
	st.binds << SliderBind{
		sl:  sl
		get: cfg.get
	}
	return EditSlider{
		lb:  lb
		sl:  sl
		vl:  vl
		def: cfg.def
	}
}

// edit_row - стандартный ряд панели (slider_row) для ползунка edit_slider
fn edit_row(mut s EditSlider, lw f32, vw f32) &vgui.HBox {
	return slider_row(s.lb, mut s.sl, s.vl, s.def, lw, vw)
}

// Цвета оформления (тёмная тема): область просмотра темнее панели
// инструментов - фото на тёмно-сером нейтральном фоне, как в проявщиках.
const viewer_bg = vgui.Color{22, 22, 24, 255}
const panel_bg = vgui.Color{37, 37, 38, 255}
const divider_color = vgui.Color{58, 58, 62, 255}

// make_placeholder - заглушка области просмотра, пока файл не открыт:
// мягкий радиальный градиент (центр светлее) и по центру значок
// диафрагмы с подсказкой. Градиент - Canvas с растяжкой (stretch),
// пассивный: без зума, панорамы и событий.
fn make_placeholder() &vgui.Stack {
	gw, gh := 960, 720
	mut bg := vgui.canvas(gw, gh)
	bg.stretch = true
	bg.enabled = false
	bg.set_wheel_zoom(false)
	bg.set_pan_buttons(0)
	unsafe {
		mut p := &u8(bg.pixels.data)
		mut seed := u32(12345)
		for y in 0 .. gh {
			for x in 0 .. gw {
				dx := (f32(x) - gw / 2) / (gw / 2)
				dy := (f32(y) - gh / 2) / (gh / 2)
				r := math.sqrtf(dx * dx + dy * dy) / 1.4142
				t := r * r * (3 - 2 * r) // smoothstep: мягкий спад к краям
				v := 36 - (36 - f32(viewer_bg.r)) * t
				// Дизер ±0.5: на тёмном гладком градиенте иначе видны ступени
				seed = seed * 1664525 + 1013904223
				n := f32(seed >> 8) / 16777216.0 - 0.5
				c := u8(v + n + 0.5)
				p[0] = c
				p[1] = c
				p[2] = u8(f32(c) + 2 * (1 - t)) // чуть холоднее в центре
				p[3] = 255
				p += 4
			}
		}
	}

	mut ic := vgui.icon('aperture')
	ic.set_size(64)
	ic.set_color(vgui.Color{92, 94, 100, 255})
	mut title := vgui.label('Откройте RAW-файл')
	title.align = .center
	title.font_size = 20
	title.color = vgui.Color{176, 176, 182, 255}
	mut hint := vgui.label('Кнопка «Открыть RAW...» на панели справа')
	hint.align = .center
	hint.color = vgui.Color{120, 120, 126, 255}
	mut fmts := vgui.label('CR3 · CR2 · NEF · ARW · DNG · RAF · ORF · RW2')
	fmts.align = .center
	fmts.color = vgui.Color{92, 92, 98, 255}

	mut col := vgui.create_vbox_fill()
	col.set_spacing(6)
	col.add_fixed(ic, 76)
	col.add_fixed(title, 32)
	col.add_fixed(hint, 22)
	col.add_fixed(fmts, 22)
	mut center := vgui.create_centered(420, 170)
	center.set_child(col)

	mut ph := &vgui.Stack{}
	ph.add(bg)
	ph.add(center)
	return ph
}

// show_viewer убирает заглушку и показывает холст превью (файл открыт)
fn show_viewer(mut cv vgui.Canvas, mut placeholder vgui.Stack) {
	placeholder.visible = false
	cv.visible = true
}

// ── Тональные кривые ──

const curve_names = ['RGB', 'R', 'G', 'B']
const curve_colors = [vgui.Color{225, 225, 228, 255}, vgui.Color{235, 85, 85, 255},
	vgui.Color{90, 200, 100, 255}, vgui.Color{90, 140, 245, 255}]

fn identity_curve() []vgui.CurvePoint {
	return [vgui.CurvePoint{0, 0}, vgui.CurvePoint{1, 1}]
}

// tone_lut - кривая редактора (0..1) как таблица пайплайна: 256 узлов тон
// 0..255 -> тон 0..255; тождественная - пустой массив (кривой нет).
fn tone_lut(pts []vgui.CurvePoint) []f32 {
	if vgui.curve_is_identity(pts) {
		return []f32{}
	}
	mut l := vgui.curve_lut(pts, 256)
	for i in 0 .. 256 {
		l[i] *= 255.0
	}
	return l
}

// curves_to_params переносит точки всех четырёх кривых в Params
fn curves_to_params(mut st State) {
	st.edit.params.tc_rgb = tone_lut(st.edit.curve_pts[0])
	st.edit.params.tc_r = tone_lut(st.edit.curve_pts[1])
	st.edit.params.tc_g = tone_lut(st.edit.curve_pts[2])
	st.edit.params.tc_b = tone_lut(st.edit.curve_pts[3])
}

// sync_curve_editor показывает в редакторе кривую выбранного канала его
// цветом, изменённые кривые остальных каналов - полупрозрачными призраками.
fn sync_curve_editor(mut st State) {
	if isnil(st.curve_ed) {
		return
	}
	mut ed := st.curve_ed
	ed.set_points(st.edit.curve_pts[st.curve_ch])
	ed.curve_color = curve_colors[st.curve_ch]
	ed.clear_ghosts()
	for c in 0 .. 4 {
		if c != st.curve_ch && !vgui.curve_is_identity(st.edit.curve_pts[c]) {
			col := curve_colors[c]
			ed.add_ghost(st.edit.curve_pts[c], vgui.Color{col.r, col.g, col.b, 110})
		}
	}
	update_curve_histogram(mut st)
}

// update_curve_histogram - фон редактора: гистограмма результата по
// выбранному каналу (для RGB - среднее трёх), нормированная по максимуму.
fn update_curve_histogram(mut st State) {
	if isnil(st.curve_ed) || st.hist_r.len != 256 {
		return
	}
	mut h := []f32{len: 256}
	mut mx := f32(1)
	for i in 0 .. 256 {
		v := match st.curve_ch {
			1 { f32(st.hist_r[i]) }
			2 { f32(st.hist_g[i]) }
			3 { f32(st.hist_b[i]) }
			else { f32(st.hist_r[i] + st.hist_g[i] + st.hist_b[i]) / 3 }
		}
		h[i] = v
		if v > mx {
			mx = v
		}
	}
	for i in 0 .. 256 {
		h[i] /= mx
	}
	mut ed := st.curve_ed
	ed.histogram = h
}

// ── HSL ──

const hsl_names = ['Красный', 'Оранжевый', 'Жёлтый', 'Зелёный', 'Голубой', 'Синий',
	'Фиолетовый', 'Пурпурный']
const hsl_label_colors = [vgui.Color{235, 105, 105, 255}, vgui.Color{238, 158, 80, 255},
	vgui.Color{228, 206, 86, 255}, vgui.Color{112, 196, 102, 255},
	vgui.Color{92, 204, 214, 255}, vgui.Color{104, 142, 238, 255},
	vgui.Color{160, 116, 234, 255}, vgui.Color{220, 104, 206, 255}]
const hsl_modes = ['Оттенок', 'Насыщенность', 'Яркость']

// SectionRow - ряд секции аккордеона: виджет и его фиксированная высота
struct SectionRow {
	w &vgui.Widget
	h f32
}

// section собирает содержимое секции аккордеона: VBox из фиксированных
// рядов (fit_content считает высоту секции по их сумме) с отступами.
fn section(rows []SectionRow) &vgui.VBox {
	mut v := vgui.create_vbox_fill()
	v.set_spacing(6)
	v.set_padding(8)
	for r in rows {
		v.add_fixed(r.w, r.h)
	}
	return v
}

fn main() {
	mut app := vgui.create_app(theme: vgui.dark_theme())!
	// Тема приложения: окно без своей темы получит её в add_window
	mut win := vgui.create_window(title: 'vraw - проявка RAW', width: 1280, height: 946)!

	// Колонки панели ползунков: не константы «с запасом», а фактическая
	// ширина самых длинных строк. Первый список - все подписи рядов,
	// второй - самые длинные варианты значений (режимы пересветов и
	// крайние числа ползунков). Новая подпись длиннее нынешних просто
	// расширит колонку - наездов на ползунок не будет.
	lbl_w := column_width(mut win, ['Пересветы', 'Экспозиция', 'Тени',
		'Контраст', 'Насыщенность', 'Света', 'Чёрные', 'Средние', 'Белые',
		'Импульсный', 'Яркостный', 'Цветовой', 'Ореолы', 'Качество JPEG',
		'Оранжевый', 'Фиолетовый', 'Пурпурный'], 8)
	val_w := column_width(mut win, ['без клипа', 'смешение', 'восстан. 9',
		'-4.00', '100'], 8)

	mut st := &State{}
	st.edit = neutral_edit()

	// Холст превью скрыт до открытия файла - на его месте заглушка
	mut cv := vgui.canvas(4, 3)
	cv.fill(viewer_bg)
	cv.visible = false
	mut placeholder := make_placeholder()

	// Гистограмма: буфер 256 колонок (колонка = бин), растягивается на виджет.
	// Зум и панораму отключаем - это индикатор, а не изображение.
	mut hist := vgui.canvas(256, 100)
	hist.stretch = true
	hist.set_wheel_zoom(false)
	hist.set_pan_buttons(0)
	hist.fill(vgui.Color{16, 16, 18, 255})

	// Уведомления (тосты) вместо статусной строки: начало/окончание
	// обработки, ошибки. NotificationManager добавляется напрямую в окно
	// ПОСЛЕ корневого контейнера - рисуется поверх, события получает первым.
	// Левый нижний угол - над превью, панель управления не перекрывается.
	mut nm := vgui.notification_manager_at(.top_left)

	// Приём результата фоновой подготовки сырья (главный поток, из
	// app.post). Результат старого файла или уже дождавшегося воркера
	// (wait_prep сбросил prep_running) отбрасывается.
	st.prep_done = fn [mut st, mut cv, mut hist, mut app] (res PrepResult) {
		if res.gen != st.file_gen || !st.prep_running {
			return
		}
		wait_prep(mut st) // воркер уже отдал результат - join мгновенный
		take_prep(mut st, res)
		apply_pipeline(mut st, mut cv, mut hist)
		if st.lens_dirty || st.nr_applied != st.edit.nr {
			// Пока воркер считал, настройки снова поменялись
			request_prep(mut st, mut app, false)
		}
	}

	// ── Ползунки и чекбоксы правки ──
	// Все настройки кадра живут в st.edit (снимок для истории). Ползунки
	// собирает edit_slider; fx - пересчёт по виду настройки: тон -
	// apply_pipeline (~60 мс), подготовка сырья - фоновый request_prep,
	// пересветы - перепроявка превью.
	tone_fx := fn [mut st, mut cv, mut hist] () {
		apply_pipeline(mut st, mut cv, mut hist)
	}
	// Шумодав и ореолы - подготовка сырья (~1 с на превью, в фоне): LibRaw
	// и коррекция объектива не перезапускаются - сырьё в raw_linear.
	// Отпускание на уже применённом значении ничего не пересчитывает.
	prep_fx := fn [mut st, mut app] () {
		if st.nr_applied != st.edit.nr {
			request_prep(mut st, mut app, false)
		}
	}
	// Пересветы - параметр LibRaw, не пайплайна: перепроявка превью
	// (~0.1 с в главном потоке, коррекция и шумодав - в фоне), зум
	// сохраняется. На том же режиме не перепроявляется.
	hl_fx := fn [mut st, mut cv, mut hist, mut nm, mut app] () {
		if st.edit.highlight != st.hl_developed {
			load_preview(mut st, mut cv, mut hist, mut nm, mut app, true)
		}
	}

	// Коррекция объектива (lensfun): применяется к линейному сырью до
	// пайплайна. Переключение пересчитывает сырьё из dev_linear (без
	// LibRaw) в фоне, ~0.6 с + шумодав - окно не замирает.
	// Подпись под чекбоксом - найденный профиль.
	mut lens_cb := vgui.checkbox('Коррекция объектива')
	lens_cb.checked = true
	lens_cb.on_change = fn [mut st, mut app] (v bool) {
		st.edit.lens_corr = v
		request_prep(mut st, mut app, true)
		record(mut st, 'lens', 'Коррекция объектива: ${on_off(v)}', false)
	}
	st.lens_cb = lens_cb
	mut lens_lb := vgui.label('')
	lens_lb.color = vgui.Color{150, 150, 150, 255}

	// Камерная кривая: тональная кривая, подогнанная под встроенный JPEG
	// камеры (как «Автоопределение тоновой кривой» в RawTherapee). Без неё
	// нейтральная проявка - чистая гамма 2.2, заметно темнее камерного
	// JPEG в средних тонах. Кривая сидит в flut, поэтому переключение -
	// мгновенное (обычный apply, перепроявка не нужна).
	mut crv_cb := vgui.checkbox('Камерная кривая (как JPEG)')
	crv_cb.checked = true
	crv_cb.on_change = fn [mut st, mut cv, mut hist] (v bool) {
		st.edit.use_curve = v
		st.edit.params.curve = if v { st.curve.clone() } else { []f32{} }
		apply_pipeline(mut st, mut cv, mut hist)
		record(mut st, 'camcurve', 'Камерная кривая: ${on_off(v)}', false)
	}
	st.crv_cb = crv_cb

	mut hl := edit_slider(mut st, SliderCfg{
		label:  'Пересветы'
		hname:  'Пересветы:'
		max:    9
		digits: 0
		show:   fn (v f32) string {
			return highlight_name(int(v))
		}
		get:    fn (e &EditState) f32 {
			return e.highlight
		}
		set:    fn (mut e EditState, v f32) {
			e.highlight = int(v)
		}
		fx:     hl_fx
	})

	// Шумодав и ореолы: в «Сброс» не входят (подготовка сырья, не тон)
	mut imp := edit_slider(mut st, SliderCfg{
		label:  'Импульсный'
		hname:  'Импульсный шум'
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.nr[0]
		}
		set:    fn (mut e EditState, v f32) {
			e.nr[0] = v
		}
		fx:     prep_fx
	})
	mut nrl := edit_slider(mut st, SliderCfg{
		label:  'Яркостный'
		hname:  'Шумодав: яркостный'
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.nr[1]
		}
		set:    fn (mut e EditState, v f32) {
			e.nr[1] = v
		}
		fx:     prep_fx
	})
	mut nrc := edit_slider(mut st, SliderCfg{
		label:  'Цветовой'
		hname:  'Шумодав: цветовой'
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.nr[2]
		}
		set:    fn (mut e EditState, v f32) {
			e.nr[2] = v
		}
		fx:     prep_fx
	})
	mut df := edit_slider(mut st, SliderCfg{
		label:  'Ореолы'
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.nr[3]
		}
		set:    fn (mut e EditState, v f32) {
			e.nr[3] = v
		}
		fx:     prep_fx
	})

	// Тональные ползунки: пайплайн (~60 мс на превью) - по отпусканию,
	// чтобы драг не подтормаживал; при перетаскивании только подпись.
	mut exp := edit_slider(mut st, SliderCfg{
		label: 'Экспозиция'
		min:   -4
		max:   4
		get:   fn (e &EditState) f32 {
			return e.params.exposure
		}
		set:   fn (mut e EditState, v f32) {
			e.params.exposure = v
		}
		fx:    tone_fx
	})
	// «Авто» - экспозиция по гистограмме превью. set_value сам вызовет
	// on_change ползунка: параметры, подпись, пайплайн и запись в историю
	// (под своим названием - hist_label) обновятся штатно.
	mut exp_sl := exp.sl
	mut b_autoexp := vgui.button('Авто')
	b_autoexp.style = .outline
	b_autoexp.on_click = fn [mut st, mut exp_sl] () {
		if st.linear.len == 0 {
			return
		}
		ev := auto_exposure_ev(st.linear, st.pw * st.ph)
		st.hist_label = 'Авто-экспозиция ${fmt_signed(ev, 2)}'
		exp_sl.set_value(ev)
		st.hist_label = ''
	}

	mut sh := edit_slider(mut st, SliderCfg{
		label: 'Тени'
		min:   -4
		max:   4
		get:   fn (e &EditState) f32 {
			return e.params.shadows
		}
		set:   fn (mut e EditState, v f32) {
			e.params.shadows = v
		}
		fx:    tone_fx
	})
	mut con := edit_slider(mut st, SliderCfg{
		label: 'Контраст'
		min:   -4
		max:   4
		get:   fn (e &EditState) f32 {
			return e.params.contrast
		}
		set:   fn (mut e EditState, v f32) {
			e.params.contrast = v
		}
		fx:    tone_fx
	})
	mut sat := edit_slider(mut st, SliderCfg{
		label:  'Насыщенность'
		max:    4
		def:    1
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.saturation
		}
		set:    fn (mut e EditState, v f32) {
			e.params.saturation = v
		}
		fx:     tone_fx
	})

	// «Тени/Света» как в RawTherapee: маска по РАЗМЫТОЙ люме (blur_luma),
	// поэтому подъём теней сохраняет локальный контраст и не даёт плоской
	// картинки, а приглушение светов не серит мелкие блики.
	mut hlt := edit_slider(mut st, SliderCfg{
		label:  'Света'
		hname:  'Тени/Света: света'
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sh_highlights
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sh_highlights = v
		}
		fx:     tone_fx
	})
	mut sht := edit_slider(mut st, SliderCfg{
		label:  'Тени'
		hname:  'Тени/Света: тени'
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sh_shadows
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sh_shadows = v
		}
		fx:     tone_fx
	})

	// Тон-эквалайзер: пять полос по яркости
	eq_names := ['Чёрные', 'Тени', 'Средние', 'Света', 'Белые']
	mut eq_rows := []&vgui.HBox{}
	for i in 0 .. 5 {
		mut s := edit_slider(mut st, SliderCfg{
			label: eq_names[i]
			hname: 'Эквалайзер: ${eq_names[i]}'
			min:   -4
			max:   4
			get:   fn [i] (e &EditState) f32 {
				return e.params.eq[i]
			}
			set:   fn [i] (mut e EditState, v f32) {
				e.params.eq[i] = v
			}
			fx:    tone_fx
		})
		eq_rows << edit_row(mut s, lbl_w, val_w)
	}

	// ── Кривые: кнопки каналов, редактор, подсказка ──
	// Картинка пересчитывается при отпускании точки (on_release), как и
	// у ползунков; кривые других каналов видны в редакторе призраками.
	mut ed := vgui.curve_editor()
	st.curve_ed = ed
	ed.on_release = fn [mut st, mut cv, mut hist, mut ed] () {
		st.edit.curve_pts[st.curve_ch] = ed.points.clone()
		curves_to_params(mut st)
		apply_pipeline(mut st, mut cv, mut hist)
		record(mut st, 'curve${st.curve_ch}', 'Кривая ${curve_names[st.curve_ch]}', false)
	}
	// Обработчик ставится на только что созданную кнопку. НЕ через
	// `mut b := массив[c]; b.on_click = fn ...` - это ошибка компилятора V:
	// замыкание, присвоенное так в цикле, указывает на чужой контекст
	// (кнопки молча не работали). Стили - по индексу st.curve_btns[j].
	mut ch_row := vgui.create_hbox_fill()
	ch_row.set_spacing(6)
	for c in 0 .. 4 {
		mut b := vgui.button(curve_names[c])
		b.style = if c == 0 { vgui.ButtonStyle.accent } else { vgui.ButtonStyle.outline }
		b.on_click = fn [mut st, c] () {
			st.curve_ch = c
			for j in 0 .. st.curve_btns.len {
				st.curve_btns[j].style = if j == c {
					vgui.ButtonStyle.accent
				} else {
					vgui.ButtonStyle.outline
				}
			}
			sync_curve_editor(mut st)
		}
		st.curve_btns << b
		ch_row.add(b, 1)
	}
	mut curve_reset := vgui.button('×')
	curve_reset.style = .outline
	curve_reset.on_click = fn [mut st, mut cv, mut hist] () {
		st.edit.curve_pts[st.curve_ch] = identity_curve()
		curves_to_params(mut st)
		sync_curve_editor(mut st)
		apply_pipeline(mut st, mut cv, mut hist)
		record(mut st, 'curve${st.curve_ch}', 'Кривая ${curve_names[st.curve_ch]}: сброс',
			false)
	}
	ch_row.add_fixed(curve_reset, 26)
	mut curve_hint := vgui.label('Щелчок - точка, правая кнопка - удалить, двойной - сброс')
	curve_hint.color = vgui.Color{130, 130, 136, 255}
	curve_hint.font_size = 12
	sync_curve_editor(mut st)

	// ── HSL: вкладки «Оттенок / Насыщенность / Яркость», 8 диапазонов ──
	mut hsl_tabs := vgui.tab_box()
	for m in 0 .. 3 {
		mut rows := []SectionRow{}
		for i in 0 .. 8 {
			mut s := edit_slider(mut st, SliderCfg{
				label:  hsl_names[i]
				hname:  'HSL ${hsl_modes[m].to_lower()}: ${hsl_names[i]}'
				min:    -100
				max:    100
				digits: 0
				get:    fn [m, i] (e &EditState) f32 {
					return match m {
						0 { e.params.hsl_hue[i] }
						1 { e.params.hsl_sat[i] }
						else { e.params.hsl_lum[i] }
					}
				}
				set:    fn [m, i] (mut e EditState, v f32) {
					match m {
						0 { e.params.hsl_hue[i] = v }
						1 { e.params.hsl_sat[i] = v }
						else { e.params.hsl_lum[i] = v }
					}
				}
				fx:     tone_fx
			})
			mut lb := s.lb
			lb.color = hsl_label_colors[i]
			rows << SectionRow{edit_row(mut s, lbl_w, val_w), 26}
		}
		hsl_tabs.add_tab(hsl_modes[m], section(rows))
	}

	// ── История правок: список, текущая запись выделена ──
	// Щелчок (или стрелки в списке) - откат к записи, более поздняя -
	// возврат вперёд; новая правка после отката отрезает «будущее».
	mut hist_lb := vgui.list_box()
	hist_lb.item_height = 22
	// Одна колонка без заголовка: строки - цветные подписи (отменённые
	// правки серые), а ячейки-виджеты вертикальный список рисует только
	// по колонкам
	hist_lb.add_column('', 360)
	hist_lb.show_header = false // add_column включает заголовок
	hist_lb.on_select = fn [mut st, mut cv, mut hist, mut nm, mut app] (idx int, text string) {
		goto_history(mut st, idx, mut cv, mut hist, mut nm, mut app)
	}
	st.hist_lb = hist_lb
	mut hist_hint := vgui.label('Ctrl+Z - отменить, Ctrl+Shift+Z - вернуть')
	hist_hint.color = vgui.Color{130, 130, 136, 255}
	hist_hint.font_size = 12
	win.bind_hotkey('Ctrl+Z', fn [mut st, mut cv, mut hist, mut nm, mut app] () {
		goto_history(mut st, st.hist_pos - 1, mut cv, mut hist, mut nm, mut app)
	})
	redo := fn [mut st, mut cv, mut hist, mut nm, mut app] () {
		goto_history(mut st, st.hist_pos + 1, mut cv, mut hist, mut nm, mut app)
	}
	win.bind_hotkey('Ctrl+Shift+Z', redo)
	win.bind_hotkey('Ctrl+Y', redo)

	mut q_lb := vgui.label('Качество JPEG')
	mut q_vl := value_label('92')
	mut q_sl := vgui.slider_horizontal(50, 100, 92)
	q_sl.step = 1
	q_sl.on_change = fn [mut st, mut q_vl] (v f32) {
		st.quality = int(v)
		q_vl.text = '${int(v)}'
	}

	// ── Кнопки ──
	// Открытие файла (кнопка и аргумент командной строки): новый кадр -
	// нейтральные настройки и новая история с записью «Открыт файл».
	open_file := fn [mut st, mut cv, mut hist, mut nm, mut app, mut lens_cb, mut lens_lb, mut crv_cb, mut placeholder] (path string) {
		mut nd := raw.open(path) or {
			nm.show_error('Ошибка: ${err.msg()}')
			return
		}
		if !isnil(st.dev) {
			st.dev.close()
		}
		// Воркер пользуется st.corr - дождаться до его освобождения;
		// его результат (старый кадр) отбросится по file_gen
		wait_prep(mut st)
		st.file_gen++
		st.dev = nd
		setup_corrector(mut st, mut lens_cb, mut lens_lb)
		st.curve = []f32{} // камерная кривая старого кадра не нужна
		set_edit(mut st, neutral_edit())
		load_preview(mut st, mut cv, mut hist, mut nm, mut app, false)
		setup_curve(mut st, mut crv_cb, mut cv, mut hist)
		show_viewer(mut cv, mut placeholder)
		start_history(mut st)
		nm.show_info('${os.file_name(path)}: превью ${st.pw}x${st.ph}')
	}

	mut b_open := vgui.button('Открыть RAW...')
	b_open.on_click = fn [mut app, win, open_file] () {
		path := vgui.native_open_file_dialog(win, mut app, vgui.NativeFileDialogConfig{
			filter_names:    ['RAW-файлы', 'Все файлы']
			filter_patterns: [raw_patterns, '*']
		})
		if path.len > 0 {
			open_file(path)
		}
	}

	// Сохранение - в фоновом потоке (полный кадр с коррекцией ~3.5 с,
	// окно не должно замирать). Кнопка на это время гаснет - и защита
	// от двойного запуска (disabled-кнопка событий не получает);
	// ползунки остаются живыми. Результат воркер доставляет через
	// app.post() - цикл vgui спит как обычно и просыпается ровно один раз.
	mut b_save := vgui.button('Сохранить JPEG...')
	save_done := fn [mut nm, mut b_save] (ok bool, msg string) {
		if ok {
			nm.show_success(msg)
		} else {
			nm.show_error(msg)
		}
		b_save.enabled = true
	}
	b_save.on_click = fn [mut st, mut nm, mut app, win, mut b_save, save_done] () {
		if isnil(st.dev) {
			nm.show_warning('Сначала откройте RAW-файл')
			return
		}
		default_name := os.file_name(st.dev.path).all_before_last('.') + '.jpg'
		path := vgui.native_save_file_dialog(win, mut app, vgui.NativeFileDialogConfig{
			default_name:    default_name
			filter_names:    ['JPEG']
			filter_patterns: ['jpg;jpeg']
		})
		if path.len == 0 {
			return
		}
		// Снимок всего нужного по значению: воркер не трогает st после спавна
		job := SaveJob{
			src:        st.dev.path
			dst:        path
			highlight:  st.edit.highlight
			lens_corr:  st.edit.lens_corr && !isnil(st.corr)
			nr_impulse: st.edit.nr[0]
			nr_luma:    st.edit.nr[1]
			nr_chroma:  st.edit.nr[2]
			defringe:   st.edit.nr[3]
			params:     st.edit.params
			quality:    st.quality
		}
		b_save.enabled = false
		nm.show_info('Проявляю в полном размере (в фоне)...')
		st.save_threads << spawn save_worker(job, mut app, save_done)
	}

	// «Сброс» тональный: пересветы, коррекция объектива, камерная кривая
	// и шумодав остаются как есть. Это обычная правка - запись в истории,
	// отменяется Ctrl+Z.
	mut b_reset := vgui.button('Сброс')
	b_reset.style = .outline
	b_reset.on_click = fn [mut st, mut cv, mut hist, mut nm, mut app] () {
		mut e := st.edit.clone()
		e.params = pipeline.Params{}
		e.curve_pts = neutral_edit().curve_pts
		restore_edit(mut st, e, mut cv, mut hist, mut nm, mut app)
		record(mut st, 'reset', 'Сброс', false)
	}

	mut b_fit := vgui.button('Вписать')
	b_fit.style = .outline
	b_fit.on_click = fn [mut cv] () {
		cv.fit_to_view()
	}
	mut b_100 := vgui.button('1:1')
	b_100.style = .outline
	b_100.on_click = fn [mut cv] () {
		cv.set_zoom(1.0)
	}

	// ── Компоновка: превью слева, панель управления справа ──
	mut files_row := vgui.create_hbox_fill()
	files_row.set_spacing(6)
	files_row.add(b_open, 1)
	files_row.add(b_save, 1)

	mut view_row := vgui.create_hbox_fill()
	view_row.set_spacing(6)
	view_row.add(b_fit, 1)
	view_row.add(b_100, 1)
	view_row.add(b_reset, 1)

	mut hl_row := edit_row(mut hl, lbl_w, val_w)
	// Ряд экспозиции - как slider_row, но с дополнительной кнопкой «Авто»
	// между значением и сбросом.
	mut b_expreset := vgui.button('×')
	b_expreset.style = .outline
	b_expreset.on_click = fn [mut exp_sl] () {
		exp_sl.set_value(0.0)
	}
	mut exp_row := vgui.create_hbox_fill()
	exp_row.set_spacing(6)
	exp_row.add_fixed(exp.lb, lbl_w)
	exp_row.add(exp_sl, 1)
	exp_row.add_fixed(exp.vl, val_w)
	exp_row.add_fixed(b_autoexp, 52)
	exp_row.add_fixed(b_expreset, 26)
	mut sh_row := edit_row(mut sh, lbl_w, val_w)
	mut con_row := edit_row(mut con, lbl_w, val_w)
	mut sat_row := edit_row(mut sat, lbl_w, val_w)
	mut hlt_row := edit_row(mut hlt, lbl_w, val_w)
	mut sht_row := edit_row(mut sht, lbl_w, val_w)
	mut imp_row := edit_row(mut imp, lbl_w, val_w)
	mut nrl_row := edit_row(mut nrl, lbl_w, val_w)
	mut nrc_row := edit_row(mut nrc, lbl_w, val_w)
	mut df_row := edit_row(mut df, lbl_w, val_w)
	mut q_row := slider_row(q_lb, mut q_sl, q_vl, 92.0, lbl_w, val_w)

	// Гистограмма и кнопки файлов закреплены сверху, кнопки вида - снизу;
	// всё остальное (чекбоксы и ползунки) прокручивается в ScrollBox
	// с тонким ползунком. Высота контента считается автоматически
	// (scroll_box(0) суммирует add_fixed внутреннего VBox).
	// Инструменты сгруппированы в аккордеон: секции открываются
	// независимо (multi), каждая высотой по содержимому (fit_content) -
	// аккордеон целиком прокручивается в ScrollBox.
	mut acc := vgui.accordion_multi()
	acc.fit_content = true
	acc.spacing = 4
	acc.header_height = 30
	acc.add_section_expanded('Коррекция', section([
		SectionRow{lens_cb, 26},
		SectionRow{lens_lb, 16},
		SectionRow{crv_cb, 26},
		SectionRow{hl_row, 26},
	]))
	acc.add_section_expanded('Экспозиция и тон', section([
		SectionRow{exp_row, 26},
		SectionRow{sh_row, 26},
		SectionRow{con_row, 26},
		SectionRow{sat_row, 26},
	]))
	acc.add_section('Тени/Света', section([
		SectionRow{hlt_row, 26},
		SectionRow{sht_row, 26},
	]))
	mut eq_items := []SectionRow{}
	for row in eq_rows {
		eq_items << SectionRow{row, 26}
	}
	acc.add_section('Тон-эквалайзер (EV)', section(eq_items))
	acc.add_section('Кривые', section([
		SectionRow{ch_row, 28},
		SectionRow{ed, 300},
		SectionRow{curve_hint, 16},
	]))
	// Высота вкладок: заголовок TabBox + 8 рядов с отступами секции
	acc.add_section('HSL', section([
		SectionRow{hsl_tabs, 32 + 8 * 26 + 7 * 6 + 16},
	]))
	acc.add_section('Шумодав и ореолы', section([
		SectionRow{imp_row, 26},
		SectionRow{nrl_row, 26},
		SectionRow{nrc_row, 26},
		SectionRow{df_row, 26},
	]))
	acc.add_section('Экспорт', section([
		SectionRow{q_row, 26},
	]))
	// История - последней секцией, открыта: 8 строк списка и подсказка
	acc.add_section_expanded('История', section([
		SectionRow{hist_lb, 8 * 22 + 8},
		SectionRow{hist_hint, 16},
	]))

	mut scroll := vgui.scroll_box(0)
	scroll.sb_width = 8
	scroll.add(acc)

	// Правая панель - свой фон и внутренние отступы; от области
	// просмотра её отделяет тонкая вертикальная линия.
	mut right := vgui.create_vbox_fill()
	right.set_spacing(6)
	right.set_padding(10)
	right.set_bg(panel_bg)
	right.add_fixed(hist, 120)
	right.add_fixed(files_row, 34)
	right.add(scroll, 1)
	right.add_fixed(view_row, 30)

	// Область просмотра: тёмный нейтральный фон, картинка с отступом от
	// краёв. Холст и заглушка лежат друг на друге в Stack, видим один.
	mut view_stack := &vgui.Stack{}
	view_stack.add(cv)
	view_stack.add(placeholder)
	mut viewer := vgui.create_vbox_fill()
	viewer.set_padding(16)
	viewer.set_bg(viewer_bg)
	viewer.add(view_stack, 1)

	mut divider := vgui.vseparator()
	divider.color = divider_color

	mut top := vgui.create_hbox_fill()
	top.set_spacing(0)
	top.add(viewer, 1)
	top.add_fixed(divider, 1)
	top.add_fixed(right, 440)

	win.add_widget(top)
	// Менеджер уведомлений - после корневого контейнера: рисуется поверх
	// всего окна, события получает первым (Window обходит виджеты с конца).
	win.add_widget(nm)
	app.add_window(win)

	// Путь к RAW можно передать аргументом: vraw-gui файл.CR3
	if os.args.len > 1 && os.exists(os.args[1]) {
		open_file(os.args[1])
	}

	app.run()

	// Не обрывать записывающийся JPEG, если окно закрыли во время сохранения
	for t in st.save_threads {
		t.wait()
	}
	if !isnil(st.dev) {
		st.dev.close()
	}
	wait_prep(mut st) // воркер пользуется st.corr
	if !isnil(st.corr) {
		st.corr.free()
	}
}
