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
	raw_linear   []u16 // превью после LibRaw и коррекции объектива, ДО шумодава
	linear       []u16 // линейное 16-битное RGB-превью (half-size), сырьё пайплайна
	mask         []u16 // размытая люма превью - маска «Тени/Света» (pipeline.blur_luma)
	pw           int   // размеры превью
	ph           int
	params       pipeline.Params
	quality      int = 92
	highlight    int // режим пересветов LibRaw (0..9), меняется - нужна перепроявка
	hl_developed int = -1 // режим пересветов последней проявки (не проявлять зря)
	suppress     bool     // true = не применять пайплайн (пакетный сброс ползунков)
	meta         raw.Meta // метаданные открытого кадра (для профиля объектива)
	corr         &lens.Corrector = unsafe { nil } // профиль lensfun или nil
	lens_corr    bool            = true           // чекбокс «Коррекция объектива» включён
	curve        []f32 // камерная кривая кадра (match_curve), пустая - нет превью
	use_curve    bool = true // чекбокс «Камерная кривая» включён
	nr_impulse   f32 // подавление импульсного шума 0..100
	nr_luma      f32 // шумодав: яркостный 0..100
	nr_chroma    f32 // шумодав: цветовой 0..100
	defringe     f32 // подавление ореолов 0..100
	nr_applied   [4]f32 = [f32(-1), -1, -1, -1]! // значения последней подготовки сырья
	save_threads []thread // хендлы фоновых сохранений: wait после app.run()
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
// гистограмму. Вызывается на каждое движение любого ползунка, поэтому
// никаких уведомлений отсюда - только картинка.
fn apply_pipeline(mut st State, mut cv vgui.Canvas, mut hist vgui.Canvas) {
	if st.suppress || st.linear.len == 0 {
		return
	}
	npix := st.pw * st.ph
	pipeline.apply(&u16(st.linear.data), &u16(st.mask.data), npix, st.params, mut cv.pixels, 4)
	cv.mark_dirty()
	render_histogram(mut hist, cv.pixels)
}

// load_preview проявляет открытый RAW в линейное 16-битное превью
// (единственный вызов LibRaw на файл) и применяет пайплайн.
fn load_preview(mut st State, mut cv vgui.Canvas, mut hist vgui.Canvas, mut nm vgui.NotificationManager) {
	if isnil(st.dev) {
		return
	}
	mut img := st.dev.develop(half: true, linear16: true, highlight: st.highlight) or {
		nm.show_error('Ошибка проявки: ${err.msg()}')
		return
	}
	st.hl_developed = st.highlight
	resized := img.width != st.pw || img.height != st.ph
	st.pw = img.width
	st.ph = img.height
	n := img.width * img.height * 3
	st.raw_linear = []u16{len: n}
	unsafe { vmemcpy(st.raw_linear.data, img.data_u16(), n * 2) }
	img.free()

	// Коррекция объектива - статичное свойство кадра, поэтому применяется
	// один раз к сырью, а не в пайплайне: ползунки остаются живыми.
	if st.lens_corr && !isnil(st.corr) {
		st.corr.vignetting(&u16(st.raw_linear.data), st.pw, st.ph, st.meta.focal, st.meta.aperture)
		// Дисторсия + TCA - строго после виньетирования (ремап двигает пиксели)
		st.corr.geometry(&u16(st.raw_linear.data), st.pw, st.ph, st.meta.focal)
	}

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

	prepare_linear(mut st, mut cv, mut hist)
}

// prepare_linear готовит рабочее сырьё пайплайна из raw_linear: шумодав и
// подавление ореолов (~1 с и ~0.5 с на превью при ненулевой силе), затем
// маска «Тени/Света». Отдельно от load_preview, чтобы смена их ползунков
// не гоняла LibRaw и коррекцию объектива заново.
fn prepare_linear(mut st State, mut cv vgui.Canvas, mut hist vgui.Canvas) {
	if st.raw_linear.len == 0 {
		return
	}
	st.linear = st.raw_linear.clone()
	// Импульсы - до шумодава: вейвлет размазал бы выброс по уровням
	if st.nr_impulse > 0 {
		pipeline.impulse(&u16(st.linear.data), st.pw, st.ph, st.nr_impulse)
	}
	if st.nr_luma > 0 || st.nr_chroma > 0 {
		pipeline.denoise(&u16(st.linear.data), st.pw, st.ph, st.nr_luma, st.nr_chroma)
	}
	if st.defringe > 0 {
		pipeline.defringe(&u16(st.linear.data), st.pw, st.ph, st.defringe)
	}
	st.nr_applied = [st.nr_impulse, st.nr_luma, st.nr_chroma, st.defringe]!

	// Маска «Тени/Света» зависит только от сырья (после коррекции
	// объектива и шумодава!), поэтому считается здесь, а не на каждый ползунок.
	st.mask = pipeline.blur_luma(&u16(st.linear.data), st.pw, st.ph)

	apply_pipeline(mut st, mut cv, mut hist)
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
	pipeline.apply(img.data_u16(), &u16(mask.data), w * h, job.params, mut rgb, 3)
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
fn render_histogram(mut hist vgui.Canvas, pixels []u8) {
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
	st.params.curve = []f32{}
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
	st.curve = pipeline.match_curve(&u16(st.linear.data), st.pw * st.ph, timg.data,
		timg.width * timg.height)
	timg.free()
	crv_cb.enabled = true
	if st.use_curve {
		st.params.curve = st.curve.clone()
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

fn main() {
	mut app := vgui.create_app(theme: vgui.dark_theme())!
	mut win := vgui.create_window(title: 'vraw - проявка RAW', width: 1280, height: 946)!

	// Колонки панели ползунков: не константы «с запасом», а фактическая
	// ширина самых длинных строк. Первый список - все подписи рядов,
	// второй - самые длинные варианты значений (режимы пересветов и
	// крайние числа ползунков). Новая подпись длиннее нынешних просто
	// расширит колонку - наездов на ползунок не будет.
	lbl_w := column_width(mut win, ['Пересветы', 'Экспозиция', 'Тени',
		'Контраст', 'Насыщенность', 'Света', 'Чёрные', 'Средние', 'Белые',
		'Импульсный', 'Яркостный', 'Цветовой', 'Ореолы', 'Качество JPEG'], 8)
	val_w := column_width(mut win, ['без клипа', 'смешение', 'восстан. 9',
		'-4.00', '100'], 8)

	mut st := &State{}

	mut cv := vgui.canvas(4, 3)
	cv.fill(vgui.Color{24, 24, 26, 255})

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

	// ── Ползунки пайплайна ──
	// set_value вызывает on_change, поэтому сброс - это просто установка
	// значений; st.suppress не даёт пайплайну запуститься 9 раз подряд.
	mut reset_sliders := []&vgui.Slider{}
	mut reset_defaults := []f32{}

	// Коррекция объектива (lensfun): применяется к линейному сырью до
	// пайплайна, поэтому переключение = перепроявка превью (~0.1 с),
	// как у пересветов. Подпись под чекбоксом - найденный профиль.
	mut lens_cb := vgui.checkbox('Коррекция объектива')
	lens_cb.checked = true
	lens_cb.on_change = fn [mut st, mut cv, mut hist, mut nm] (v bool) {
		st.lens_corr = v
		load_preview(mut st, mut cv, mut hist, mut nm)
	}
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
		st.use_curve = v
		st.params.curve = if v { st.curve.clone() } else { []f32{} }
		apply_pipeline(mut st, mut cv, mut hist)
	}

	// Пересветы - параметр LibRaw, не пайплайна: смена значения
	// перепроявляет превью (~0.1 с), зум при этом сохраняется.
	// Перепроявка дорогая, поэтому во время перетаскивания обновляется
	// только подпись, проявка - в on_release. Одиночные on_change
	// (колесо, клавиши, кнопка сброса) проявляют сразу - они редкие.
	mut hl_lb := vgui.label('Пересветы')
	mut hl_vl := value_label('клип')
	mut hl_sl := vgui.slider_horizontal(0, 9, 0)
	hl_sl.step = 1
	hl_sl.on_change = fn [mut st, mut cv, mut hist, mut nm, mut hl_vl, mut hl_sl] (v f32) {
		st.highlight = int(v)
		hl_vl.text = highlight_name(int(v))
		if hl_sl.dragging {
			// Проявка дорогая - при перетаскивании только подпись,
			// перепроявка в on_release
			return
		}
		load_preview(mut st, mut cv, mut hist, mut nm)
	}
	hl_sl.on_release = fn [mut st, mut cv, mut hist, mut nm] (v f32) {
		if st.highlight == st.hl_developed {
			return
		}
		load_preview(mut st, mut cv, mut hist, mut nm)
	}

	// Шумодав и ореолы - подготовка сырья (prepare_linear, ~1 с на превью),
	// не тональный пайплайн: во время перетаскивания обновляется только
	// подпись, пересчёт - при отпускании (как у пересветов). LibRaw и
	// коррекция объектива при этом не перезапускаются - сырьё в raw_linear.
	mut imp_lb := vgui.label('Импульсный')
	mut imp_vl := value_label('0')
	mut imp_sl := vgui.slider_horizontal(0, 100, 0)
	imp_sl.step = 1
	imp_sl.on_change = fn [mut st, mut cv, mut hist, mut imp_vl, mut imp_sl] (v f32) {
		st.nr_impulse = v
		imp_vl.text = '${int(v)}'
		if imp_sl.dragging {
			// Пересчёт ~1 с - при перетаскивании только подпись
			return
		}
		prepare_linear(mut st, mut cv, mut hist)
	}
	mut nrl_lb := vgui.label('Яркостный')
	mut nrl_vl := value_label('0')
	mut nrl_sl := vgui.slider_horizontal(0, 100, 0)
	nrl_sl.step = 1
	nrl_sl.on_change = fn [mut st, mut cv, mut hist, mut nrl_vl, mut nrl_sl] (v f32) {
		st.nr_luma = v
		nrl_vl.text = '${int(v)}'
		if nrl_sl.dragging {
			return
		}
		prepare_linear(mut st, mut cv, mut hist)
	}
	mut nrc_lb := vgui.label('Цветовой')
	mut nrc_vl := value_label('0')
	mut nrc_sl := vgui.slider_horizontal(0, 100, 0)
	nrc_sl.step = 1
	nrc_sl.on_change = fn [mut st, mut cv, mut hist, mut nrc_vl, mut nrc_sl] (v f32) {
		st.nr_chroma = v
		nrc_vl.text = '${int(v)}'
		if nrc_sl.dragging {
			return
		}
		prepare_linear(mut st, mut cv, mut hist)
	}
	mut df_lb := vgui.label('Ореолы')
	mut df_vl := value_label('0')
	mut df_sl := vgui.slider_horizontal(0, 100, 0)
	df_sl.step = 1
	df_sl.on_change = fn [mut st, mut cv, mut hist, mut df_vl, mut df_sl] (v f32) {
		st.defringe = v
		df_vl.text = '${int(v)}'
		if df_sl.dragging {
			return
		}
		prepare_linear(mut st, mut cv, mut hist)
	}
	nr_release := fn [mut st, mut cv, mut hist] (v f32) {
		if st.nr_applied == [st.nr_impulse, st.nr_luma, st.nr_chroma, st.defringe]! {
			return
		}
		prepare_linear(mut st, mut cv, mut hist)
	}
	imp_sl.on_release = nr_release
	nrl_sl.on_release = nr_release
	nrc_sl.on_release = nr_release
	df_sl.on_release = nr_release

	mut exp_lb := vgui.label('Экспозиция')
	mut exp_vl := value_label('0.00')
	mut exp_sl := vgui.slider_horizontal(-4.0, 4.0, 0.0)
	exp_sl.on_change = fn [mut st, mut cv, mut hist, mut exp_vl] (v f32) {
		st.params.exposure = v
		exp_vl.text = '${v:.2f}'
		apply_pipeline(mut st, mut cv, mut hist)
	}
	reset_sliders << exp_sl
	reset_defaults << 0.0

	// «Авто» - экспозиция по гистограмме превью. set_value сам вызовет
	// on_change ползунка: параметры, подпись и пайплайн обновятся штатно.
	mut b_autoexp := vgui.button('Авто')
	b_autoexp.style = .outline
	b_autoexp.on_click = fn [mut st, mut exp_sl] () {
		if st.linear.len == 0 {
			return
		}
		exp_sl.set_value(auto_exposure_ev(st.linear, st.pw * st.ph))
	}

	mut sh_lb := vgui.label('Тени')
	mut sh_vl := value_label('0.00')
	mut sh_sl := vgui.slider_horizontal(-4.0, 4.0, 0.0)
	sh_sl.on_change = fn [mut st, mut cv, mut hist, mut sh_vl] (v f32) {
		st.params.shadows = v
		sh_vl.text = '${v:.2f}'
		apply_pipeline(mut st, mut cv, mut hist)
	}
	reset_sliders << sh_sl
	reset_defaults << 0.0

	mut con_lb := vgui.label('Контраст')
	mut con_vl := value_label('0.00')
	mut con_sl := vgui.slider_horizontal(-4.0, 4.0, 0.0)
	con_sl.on_change = fn [mut st, mut cv, mut hist, mut con_vl] (v f32) {
		st.params.contrast = v
		con_vl.text = '${v:.2f}'
		apply_pipeline(mut st, mut cv, mut hist)
	}
	reset_sliders << con_sl
	reset_defaults << 0.0

	mut sat_lb := vgui.label('Насыщенность')
	mut sat_vl := value_label('1.00')
	mut sat_sl := vgui.slider_horizontal(0.0, 4.0, 1.0)
	sat_sl.on_change = fn [mut st, mut cv, mut hist, mut sat_vl] (v f32) {
		st.params.saturation = v
		sat_vl.text = '${v:.2f}'
		apply_pipeline(mut st, mut cv, mut hist)
	}
	reset_sliders << sat_sl
	reset_defaults << 1.0

	// «Тени/Света» как в RawTherapee: маска по РАЗМЫТОЙ люме (blur_luma),
	// поэтому подъём теней сохраняет локальный контраст и не даёт плоской
	// картинки, а приглушение светов не серит мелкие блики.
	mut shl_title := vgui.label('Тени/Света')
	shl_title.color = vgui.Color{150, 150, 150, 255}

	mut hlt_lb := vgui.label('Света')
	mut hlt_vl := value_label('0')
	mut hlt_sl := vgui.slider_horizontal(0, 100, 0)
	hlt_sl.step = 1
	hlt_sl.on_change = fn [mut st, mut cv, mut hist, mut hlt_vl] (v f32) {
		st.params.sh_highlights = v
		hlt_vl.text = '${int(v)}'
		apply_pipeline(mut st, mut cv, mut hist)
	}
	reset_sliders << hlt_sl
	reset_defaults << 0.0

	mut sht_lb := vgui.label('Тени')
	mut sht_vl := value_label('0')
	mut sht_sl := vgui.slider_horizontal(0, 100, 0)
	sht_sl.step = 1
	sht_sl.on_change = fn [mut st, mut cv, mut hist, mut sht_vl] (v f32) {
		st.params.sh_shadows = v
		sht_vl.text = '${int(v)}'
		apply_pipeline(mut st, mut cv, mut hist)
	}
	reset_sliders << sht_sl
	reset_defaults << 0.0

	// Тон-эквалайзер: пять полос по яркости
	mut eq_title := vgui.label('Тон-эквалайзер (EV)')
	eq_title.color = vgui.Color{150, 150, 150, 255}
	eq_names := ['Чёрные', 'Тени', 'Средние', 'Света', 'Белые']
	mut eq_rows := []&vgui.HBox{}
	for i in 0 .. 5 {
		lb := vgui.label(eq_names[i])
		mut vl := value_label('0.00')
		mut sl := vgui.slider_horizontal(-4.0, 4.0, 0.0)
		sl.on_change = fn [mut st, mut cv, mut hist, mut vl, i] (v f32) {
			st.params.eq[i] = v
			vl.text = '${v:.2f}'
			apply_pipeline(mut st, mut cv, mut hist)
		}
		reset_sliders << sl
		reset_defaults << 0.0
		eq_rows << slider_row(lb, mut sl, vl, 0.0, lbl_w, val_w)
	}

	mut q_lb := vgui.label('Качество JPEG')
	mut q_vl := value_label('92')
	mut q_sl := vgui.slider_horizontal(50, 100, 92)
	q_sl.step = 1
	q_sl.on_change = fn [mut st, mut q_vl] (v f32) {
		st.quality = int(v)
		q_vl.text = '${int(v)}'
	}

	// ── Кнопки ──
	mut b_open := vgui.button('Открыть RAW...')
	b_open.on_click = fn [mut st, mut cv, mut hist, mut nm, mut app, mut lens_cb, mut lens_lb, mut crv_cb, win, reset_sliders, reset_defaults] () {
		path := vgui.native_open_file_dialog(win, mut app, vgui.NativeFileDialogConfig{
			filter_names:    ['RAW-файлы', 'Все файлы']
			filter_patterns: [raw_patterns, '*']
		})
		if path.len == 0 {
			return
		}
		mut nd := raw.open(path) or {
			nm.show_error('Ошибка: ${err.msg()}')
			return
		}
		if !isnil(st.dev) {
			st.dev.close()
		}
		st.dev = nd
		setup_corrector(mut st, mut lens_cb, mut lens_lb)
		// Новый файл - нейтральные параметры
		st.suppress = true
		st.params = pipeline.Params{}
		for i in 0 .. reset_sliders.len {
			mut sl := reset_sliders[i]
			sl.set_value(reset_defaults[i])
		}
		st.suppress = false
		load_preview(mut st, mut cv, mut hist, mut nm)
		setup_curve(mut st, mut crv_cb, mut cv, mut hist)
		nm.show_info('${os.file_name(path)}: превью ${st.pw}x${st.ph}')
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
			highlight:  st.highlight
			lens_corr:  st.lens_corr && !isnil(st.corr)
			nr_impulse: st.nr_impulse
			nr_luma:    st.nr_luma
			nr_chroma:  st.nr_chroma
			defringe:   st.defringe
			params:     st.params
			quality:    st.quality
		}
		b_save.enabled = false
		nm.show_info('Проявляю в полном размере (в фоне)...')
		st.save_threads << spawn save_worker(job, mut app, save_done)
	}

	mut b_reset := vgui.button('Сброс')
	b_reset.style = .outline
	b_reset.on_click = fn [mut st, mut cv, mut hist, reset_sliders, reset_defaults] () {
		st.suppress = true
		st.params = pipeline.Params{}
		// «Сброс» тональный: камерная кривая, как и коррекция объектива,
		// остаётся в положении своего чекбокса
		if st.use_curve {
			st.params.curve = st.curve.clone()
		}
		for i in 0 .. reset_sliders.len {
			mut sl := reset_sliders[i]
			sl.set_value(reset_defaults[i])
		}
		st.suppress = false
		apply_pipeline(mut st, mut cv, mut hist)
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

	mut hl_row := slider_row(hl_lb, mut hl_sl, hl_vl, 0.0, lbl_w, val_w)
	// Ряд экспозиции - как slider_row, но с дополнительной кнопкой «Авто»
	// между значением и сбросом.
	mut b_expreset := vgui.button('×')
	b_expreset.style = .outline
	b_expreset.on_click = fn [mut exp_sl] () {
		exp_sl.set_value(0.0)
	}
	mut exp_row := vgui.create_hbox_fill()
	exp_row.set_spacing(6)
	exp_row.add_fixed(exp_lb, lbl_w)
	exp_row.add(exp_sl, 1)
	exp_row.add_fixed(exp_vl, val_w)
	exp_row.add_fixed(b_autoexp, 52)
	exp_row.add_fixed(b_expreset, 26)
	mut sh_row := slider_row(sh_lb, mut sh_sl, sh_vl, 0.0, lbl_w, val_w)
	mut con_row := slider_row(con_lb, mut con_sl, con_vl, 0.0, lbl_w, val_w)
	mut sat_row := slider_row(sat_lb, mut sat_sl, sat_vl, 1.0, lbl_w, val_w)
	mut hlt_row := slider_row(hlt_lb, mut hlt_sl, hlt_vl, 0.0, lbl_w, val_w)
	mut sht_row := slider_row(sht_lb, mut sht_sl, sht_vl, 0.0, lbl_w, val_w)
	mut nr_title := vgui.label('Шумодав и ореолы')
	nr_title.color = vgui.Color{150, 150, 150, 255}
	mut imp_row := slider_row(imp_lb, mut imp_sl, imp_vl, 0.0, lbl_w, val_w)
	mut nrl_row := slider_row(nrl_lb, mut nrl_sl, nrl_vl, 0.0, lbl_w, val_w)
	mut nrc_row := slider_row(nrc_lb, mut nrc_sl, nrc_vl, 0.0, lbl_w, val_w)
	mut df_row := slider_row(df_lb, mut df_sl, df_vl, 0.0, lbl_w, val_w)
	mut q_row := slider_row(q_lb, mut q_sl, q_vl, 92.0, lbl_w, val_w)

	// Гистограмма и кнопки файлов закреплены сверху, кнопки вида - снизу;
	// всё остальное (чекбоксы и ползунки) прокручивается в ScrollBox
	// с тонким ползунком. Высота контента считается автоматически
	// (scroll_box(0) суммирует add_fixed внутреннего VBox).
	mut controls := vgui.create_vbox_fill()
	controls.set_spacing(6)
	controls.add_fixed(lens_cb, 26)
	controls.add_fixed(lens_lb, 16)
	controls.add_fixed(crv_cb, 26)
	controls.add_fixed(hl_row, 26)
	controls.add_fixed(exp_row, 26)
	controls.add_fixed(sh_row, 26)
	controls.add_fixed(con_row, 26)
	controls.add_fixed(sat_row, 26)
	controls.add_fixed(shl_title, 20)
	controls.add_fixed(hlt_row, 26)
	controls.add_fixed(sht_row, 26)
	controls.add_fixed(eq_title, 20)
	for mut row in eq_rows {
		controls.add_fixed(row, 26)
	}
	controls.add_fixed(nr_title, 20)
	controls.add_fixed(imp_row, 26)
	controls.add_fixed(nrl_row, 26)
	controls.add_fixed(nrc_row, 26)
	controls.add_fixed(df_row, 26)
	controls.add_fixed(q_row, 26)

	mut scroll := vgui.scroll_box(0)
	scroll.sb_width = 8
	scroll.add(controls)

	mut right := vgui.create_vbox_fill()
	right.set_spacing(6)
	right.add_fixed(hist, 120)
	right.add_fixed(files_row, 34)
	right.add(scroll, 1)
	right.add_fixed(view_row, 30)
	right.add_fixed(vgui.create_spacer(), 6) // отступ от нижнего края окна

	mut top := vgui.create_hbox_fill()
	top.set_spacing(8)
	top.add(cv, 1)
	top.add_fixed(right, 420)

	win.add_widget(top)
	// Менеджер уведомлений - после корневого контейнера: рисуется поверх
	// всего окна, события получает первым (Window обходит виджеты с конца).
	win.add_widget(nm)
	app.add_window(win)

	// Путь к RAW можно передать аргументом: vraw-gui файл.CR3
	if os.args.len > 1 && os.exists(os.args[1]) {
		if mut nd := raw.open(os.args[1]) {
			st.dev = nd
			setup_corrector(mut st, mut lens_cb, mut lens_lb)
			load_preview(mut st, mut cv, mut hist, mut nm)
			setup_curve(mut st, mut crv_cb, mut cv, mut hist)
			nm.show_info('${os.file_name(os.args[1])}: превью ${st.pw}x${st.ph}')
		} else {
			nm.show_error('Ошибка: не удалось открыть ${os.args[1]}')
		}
	} else {
		nm.show_info('Откройте RAW-файл (CR3 и другие форматы LibRaw)')
	}

	app.run()

	// Не обрывать записывающийся JPEG, если окно закрыли во время сохранения
	for t in st.save_threads {
		t.wait()
	}
	if !isnil(st.dev) {
		st.dev.close()
	}
	if !isnil(st.corr) {
		st.corr.free()
	}
}
