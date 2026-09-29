module main

// vraw - проявка RAW с собственным пайплайном.
//
// LibRaw используется только как источник сырья: демозаика + камерный ББ,
// линейные 16-битные данные (см. raw.Developer.develop). Вся тональная
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
import ai

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
	hl_developed int = -1 // режим пересветов последней проявки (не проявлять зря)
	// true = пакетная установка виджетов (откат истории, сброс, новый файл):
	// on_change только пишут настройки - без пересчётов и записей в историю
	suppress bool
	meta         raw.Meta // метаданные открытого кадра (для профиля объектива)
	// База lensfun - загружается один раз за запуск (~115 мс), профили
	// кадров (corr) ссылаются на неё; nil - база не загрузилась
	lens_db      &lens.Database  = unsafe { nil }
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
	nm      &vgui.NotificationManager = unsafe { nil }
	// Сайдкар правок (sidecar.v): путь (пусто - не писать), ошибка записи
	// уже показана (не повторять на каждую правку)
	side_path string
	side_err  bool
	// Браузер папки (browser.v): кадры папки открытого файла, текущий,
	// лента и полоса над ней, фоновый воркер миниатюр
	folder        string
	frames        []Frame
	frame_idx     int = -1
	viewer        &vgui.VBox     = unsafe { nil } // область просмотра (пересобирается)
	view_area     &vgui.VBox     = unsafe { nil } // снимок на выбранном фоне
	view_stack    &vgui.Stack    = unsafe { nil } // холст превью + заглушка
	vsplit        &vgui.Splitter = unsafe { nil } // просмотр | лента
	hsplit        &vgui.Splitter = unsafe { nil } // просмотр | панель
	strip_box     &vgui.VBox     = unsafe { nil } // полоса + лента
	strip         &vgui.ListBox  = unsafe { nil }
	strip_bar     &vgui.HBox     = unsafe { nil }
	strip_info    &vgui.Label    = unsafe { nil }
	strip_toggle  &vgui.Button   = unsafe { nil }
	strip_open    bool           = true
	thumb_gen     int
	thumb_stop    &StopFlag = unsafe { nil }
	thumb_threads []thread
	thumb_done    fn (ThumbResult) = unsafe { nil }
	// Фоновая загрузка кадра (loader.v): идёт ли, флаг отмены, потоки,
	// предупреждение о сайдкаре для показа по окончании
	loading      bool
	load_stop    &StopFlag = unsafe { nil }
	load_threads []thread
	load_msg     string
	on_load_pv   fn (LoadPreview) = unsafe { nil }
	on_load_done fn (LoadResult)  = unsafe { nil }
	// Настройки между запусками (settings.v) и меню, которое их отражает
	settings Settings
	m_strip  &vgui.MenuItem = unsafe { nil }
	m_bg     []&vgui.MenuItem
	holder   &Placeholder = unsafe { nil } // заглушка области снимка
	// Тема (themes.v): палитра vraw, пункты меню, виджеты со своими
	// цветами - их перекрашивает paint_ui при смене темы
	pal              Palette
	m_theme          []&vgui.MenuItem
	right            &vgui.VBox = unsafe { nil }
	hint_labels      []&vgui.Label
	secondary_labels []&vgui.Label
	hsl_labels       []&vgui.Label
	tips     []&vgui.Tooltip // подсказки кнопок-значков (icon_button)
	// AI-шумодав (ai_nr.v): где лежат модели и ORT, кэши моделей по id
	// (модель грузится при первом прогоне), результат модели по raw_linear,
	// номер сырья и модель, из которых он посчитан; raw_gen
	// растёт с каждым новым raw_linear. raw_pending - идёт подготовка с
	// коррекцией объектива (raw_linear вот-вот сменится). ai_prev - идущий
	// прогон превью (nil - нет), ai_wanted - нажата
	// кнопка, ai_restart - прогон превью отменён сменой сырья.
	ai_places   ai.Places
	ai_caches   map[string]&ai.Cache
	ai_linear   []u16
	ai_raw_gen  int
	ai_lin_model string
	ai_warned   string // «кадр/модель», о чьей недоступности уже сказали
	raw_gen     int
	raw_pending bool
	ai_applied  f32 // сила AI в последней подготовке сырья
	ai_prev     &AiCtl = unsafe { nil }
	ai_wanted   bool
	ai_restart  bool
	ai_threads  []thread
	ai_ui       &AiUi = unsafe { nil }
	ai_done     fn (AiResult) = unsafe { nil }
	ai_progress fn (&AiCtl, int, int, f64) = unsafe { nil }
	// Окно настроек (settings_ui.v) и скачивание моделей: идущее (nil -
	// нет), его потоки и приёмники в главном потоке
	sui           &SettingsUi = unsafe { nil }
	open_settings fn ()       = unsafe { nil }
	dl            &DlCtl      = unsafe { nil }
	del_armed     string // id модели, чьё «Удалить» ждёт подтверждения
	dl_threads    []thread
	dl_progress   fn (&DlCtl, i64) = unsafe { nil }
	dl_done       fn (DlResult)    = unsafe { nil }
	// Экспорт (export_ui.v): идущий (nil - нет), его диалог и приёмник
	// прогресса в главном потоке
	exp          &ExportCtl = unsafe { nil }
	eui          &ExportUi  = unsafe { nil }
	exp_progress fn (&ExportCtl, ExportStage, int, int, f64) = unsafe { nil }
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

// load_preview перепроявляет открытый RAW в линейное 16-битное превью
// (LibRaw, ~0.1 с, в главном потоке) - смена режима пересветов - и
// запускает подготовку сырья: при async - в фоне, иначе сразу (смена
// размера - холст и буферы должны совпасть до первого apply). Открытие
// файла идёт другим путём - фоновой загрузкой (loader.v).
fn load_preview(mut st State, mut cv vgui.Canvas, mut hist vgui.Canvas, mut nm vgui.NotificationManager, mut app vgui.App, async bool) {
	if isnil(st.dev) {
		return
	}
	mut img := st.dev.develop(half: true, highlight: st.edit.highlight) or {
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
		// При перепроявке того же файла (смена режима пересветов) размер
		// не меняется - зум и панораму не сбрасываем
		set_canvas_size(mut cv, st.pw, st.ph)
	}

	if async && !resized {
		request_prep(mut st, mut app, true)
	} else {
		take_prep(mut st, prep_compute(make_prep_job(mut st)))
		apply_pipeline(mut st, mut cv, mut hist)
		ai_check(mut st, mut app)
	}
}

// PrepJob - снимок для подготовки сырья: коррекция объектива (только при
// redo_lens - src это выход LibRaw), импульсы, шумодав, ореолы, маска
// «Тени/Света». src - собственная копия буфера. corr - профиль из общей
// базы lensfun (st.lens_db живёт до выхода, после wait_prep), только
// чтение; воркер одновременно работает только один.
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
	ai_src    []u16  // результат модели по тому же сырью (копия) или пусто
	ai_s      f32    // сила AI 0..100 (0 - без AI)
}

struct PrepResult {
	gen        int
	raw_linear []u16 // после коррекции объектива; пусто, если коррекция не пересчитывалась
	linear     []u16
	mask       []u16
	nr         [4]f32
	ai_s       f32
}

// make_prep_job снимает параметры подготовки с State (главный поток)
fn make_prep_job(mut st State) PrepJob {
	redo := st.lens_dirty
	st.lens_dirty = false
	if redo {
		st.raw_pending = true
	}
	// Новое сырьё (коррекция объектива) - старый результат модели к нему
	// не подходит: без AI, модель пересчитает ai_check после take_prep
	ai_s := if redo { f32(0) } else { ai_effective(st) }
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
		ai_src:    if ai_s > 0 { st.ai_linear.clone() } else { []u16{} }
		ai_s:      ai_s
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
	// AI-шумодав: смешение с готовым результатом модели по силе (ai_nr.v)
	if job.ai_s > 0 && job.ai_src.len == job.src.len {
		ai.blend(buf, job.ai_src, job.ai_s / 100)
	}
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
		ai_s:       job.ai_s
	}
}

// take_prep принимает результат подготовки в State (главный поток).
// Буферы передаются без копирования: воркер их больше не трогает.
fn take_prep(mut st State, res PrepResult) {
	if res.raw_linear.len > 0 {
		st.raw_linear = res.raw_linear
		st.raw_pending = false
		raw_changed(mut st) // результат модели устарел (ai_check перезапустит)
	}
	st.linear = res.linear
	st.mask = res.mask
	st.nr_applied = res.nr
	st.ai_applied = res.ai_s
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
// Нужна перед синхронной подготовкой и на выходе (до освобождения базы
// lensfun). Результат дождавшегося воркера уже в очереди
// app.post - его отбросит проверка file_gen/prep_running в prep_done.
fn wait_prep(mut st State) {
	for t in st.prep_threads {
		t.wait()
	}
	st.prep_threads.clear()
	st.prep_running = false
}

// SaveJob - всё, что нужно фоновому потоку сохранения, копиями по значению.
// Поток НЕ делит с GUI LibRaw-хендл: пока он работает, пользователь может
// открыть другой файл (st.dev сменится), поэтому воркер открывает свой.
// Профиль объектива ищет в общей базе lensfun (db, только чтение).
struct SaveJob {
	src       string
	dst       string
	db        &lens.Database = unsafe { nil } // общая база lensfun (только чтение)
	edit      EditState // настройки кадра с производными полями - как в окне
	quality   int
	ai_cache  &ai.Cache  = unsafe { nil } // модель AI-шумодава (общая, при edit.ai > 0)
	ctl       &ExportCtl = unsafe { nil } // отмена и прогресс
	on_stage  fn (&ExportCtl, ExportStage, int, int, f64) = unsafe { nil } // прогресс - в главный поток
}

// SaveOutcome - итог сохранения: вид уведомления
enum SaveOutcome {
	saved
	failed
	cancelled
}

// report доставляет результат из фонового потока в главный:
// app.post() - единственный потокобезопасный вход vgui, замыкание
// выполнится в потоке App между событиями и рендером. ok выбирает
// вид уведомления (успех/ошибка) на принимающей стороне.
fn report(mut app vgui.App, on_done fn (SaveOutcome, string), res SaveOutcome, msg string) {
	app.post(fn [on_done, res, msg] () {
		on_done(res, msg)
	})
}

// save_worker выполняется в spawn: полная проявка и запись JPEG без единого
// обращения к vgui или общему состоянию - кроме app.post() (потокобезопасен
// по контракту vgui). Результат - уведомление через report.
fn save_worker(job SaveJob, mut app vgui.App, on_done fn (SaveOutcome, string)) {
	sw := time.new_stopwatch()
	progress := export_progress_fn(mut app, job.ctl, job.on_stage)
	img := develop_full(job.src, job.edit, job.db,
		ai_cache: job.ai_cache
		progress: progress
	) or {
		if err is ExportCancelled {
			report(mut app, on_done, .cancelled, 'Экспорт отменён')
		} else {
			report(mut app, on_done, .failed, 'Ошибка проявки: ${err.msg()}')
		}
		return
	}
	if !progress(.write, 0, 0) {
		report(mut app, on_done, .cancelled, 'Экспорт отменён')
		return
	}
	stbi.stbi_write_jpg(job.dst, img.width, img.height, 3, img.rgb.data, job.quality) or {
		report(mut app, on_done, .failed, 'Не удалось сохранить: ${err}')
		return
	}
	size_mb := f64(os.file_size(job.dst)) / 1024 / 1024
	sec := f64(sw.elapsed().milliseconds()) / 1000.0
	report(mut app, on_done, .saved, 'Сохранено: ${job.dst} (${img.width}x${img.height}, ${size_mb:.1f} МБ, качество ${job.quality}, ${sec:.1f} с)')
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

// show_lens - подпись и доступность чекбокса «Коррекция объектива» по
// найденному профилю (после загрузки кадра, load_done)
fn show_lens(st &State, mut lens_cb vgui.CheckBox, mut lens_lb vgui.Label) {
	if isnil(st.corr) {
		lens_lb.text = 'профиль объектива не найден'
		lens_cb.enabled = false
	} else {
		lens_lb.text = st.corr.lens_name
		lens_cb.enabled = true
	}
}

// icon_button - плоская кнопка со значком Lucide (встроен в vgui) и
// всплывающей подсказкой. Подсказка - отдельный виджет vgui.Tooltip:
// копится в st.tips, в окно добавляется после корневого контейнера
// (рисуется поверх всего). Button.tooltip в vgui не рисуется.
fn icon_button(mut st State, icon string, tip string) &vgui.Button {
	mut b := vgui.button('')
	b.icon_name = icon
	b.icon_size = 15
	b.style = .flat
	if tip.len > 0 {
		mut t := vgui.tooltip(tip)
		t.attach(b)
		st.tips << t
	}
	return b
}

// reset_button - сброс одного параметра: значок «вернуть назад»
fn reset_button(mut st State, tip string) &vgui.Button {
	return icon_button(mut st, 'rotate-ccw', tip)
}

// slider_row собирает стандартный ряд панели: подпись, ползунок, значение
// справа от ползунка и кнопка сброса этого параметра. set_value сам вызывает
// on_change ползунка, поэтому кнопке достаточно вернуть значение по умолчанию.
// Ширины колонок подписи/значения общие на всю панель - считаются в main
// через column_width, чтобы колонки рядов были выровнены.
fn slider_row(mut st State, lb &vgui.Label, mut sl vgui.Slider, vl &vgui.Label, def f32, lw f32, vw f32) &vgui.HBox {
	mut b := reset_button(mut st, 'Сбросить')
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
fn edit_row(mut st State, mut s EditSlider, lw f32, vw f32) &vgui.HBox {
	return slider_row(mut st, s.lb, mut s.sl, s.vl, s.def, lw, vw)
}

// Цвет холста до первого кадра (он скрыт заглушкой) и запасной фон
// области снимка. Цвета интерфейса - из палитры темы (themes.v).
const viewer_bg = vgui.Color{22, 22, 24, 255}

// Placeholder - заглушка области просмотра, пока кадр не открыт: мягкий
// радиальный градиент в цветах темы приложения и по центру значок диафрагмы
// с подсказкой. Градиент - Canvas с растяжкой (stretch), пассивный: без
// зума, панорамы и событий. Текст - по режиму (set_placeholder_text).
@[heap]
struct Placeholder {
mut:
	stack &vgui.Stack  = unsafe { nil }
	bg    &vgui.Canvas = unsafe { nil }
	icon  &vgui.Icon   = unsafe { nil }
	title &vgui.Label  = unsafe { nil }
	hint  &vgui.Label  = unsafe { nil }
	fmts  &vgui.Label  = unsafe { nil }
	edge  vgui.Color // цвет края градиента - им же поле вокруг заглушки
}

fn make_placeholder(th vgui.Theme) &Placeholder {
	mut bg := vgui.canvas(960, 720)
	bg.stretch = true
	bg.enabled = false
	bg.set_wheel_zoom(false)
	bg.set_pan_buttons(0)

	mut ic := vgui.icon('aperture')
	ic.set_size(64)
	mut title := vgui.label('')
	title.align = .center
	title.font_size = 20
	mut hint := vgui.label('')
	hint.align = .center
	mut fmts := vgui.label('CR3 · CR2 · NEF · ARW · DNG · RAF · ORF · RW2')
	fmts.align = .center

	mut col := vgui.create_vbox_fill()
	col.set_spacing(6)
	col.add_fixed(ic, 76)
	col.add_fixed(title, 32)
	col.add_fixed(hint, 22)
	col.add_fixed(fmts, 22)
	mut center := vgui.create_centered(560, 170)
	center.set_child(col)

	mut stack := &vgui.Stack{}
	stack.add(bg)
	stack.add(center)
	mut ph := &Placeholder{
		stack: stack
		bg:    bg
		icon:  ic
		title: title
		hint:  hint
		fmts:  fmts
	}
	paint_placeholder(mut ph, th)
	set_placeholder_text(mut ph, false)
	return ph
}

// paint_placeholder - заглушка в цветах темы приложения: градиент от
// theme.bg по краям к theme.surface в центре, текст - цветами текста
// темы (заголовок - основной, подсказка - вторичный, значок и форматы -
// подсказочный). От выбранного фона вокруг снимка не зависит: он - только
// под снимком (sync_view_bg).
fn paint_placeholder(mut ph Placeholder, th vgui.Theme) {
	mut bg := ph.bg
	gw := bg.width
	gh := bg.height
	edge := th.bg
	mid := th.surface
	ph.edge = edge
	unsafe {
		mut p := &u8(bg.pixels.data)
		mut seed := u32(12345)
		for y in 0 .. gh {
			for x in 0 .. gw {
				dx := (f32(x) - gw / 2) / (gw / 2)
				dy := (f32(y) - gh / 2) / (gh / 2)
				r := math.sqrtf(dx * dx + dy * dy) / 1.4142
				t := r * r * (3 - 2 * r) // smoothstep: мягкий спад к краям
				// Дизер ±0.5: на гладком градиенте иначе видны ступени
				seed = seed * 1664525 + 1013904223
				n := f32(seed >> 8) / 16777216.0
				p[0] = clamp_u8(f32(mid.r) + (f32(edge.r) - f32(mid.r)) * t + n)
				p[1] = clamp_u8(f32(mid.g) + (f32(edge.g) - f32(mid.g)) * t + n)
				p[2] = clamp_u8(f32(mid.b) + (f32(edge.b) - f32(mid.b)) * t + n)
				p[3] = 255
				p += 4
			}
		}
	}
	bg.mark_dirty()
	mut ic := ph.icon
	mut title := ph.title
	mut hint := ph.hint
	mut fmts := ph.fmts
	ic.set_color(th.text_hint)
	title.color = th.text_primary
	hint.color = th.text_secondary
	fmts.color = th.text_hint
}

fn clamp_u8(v f32) u8 {
	return if v <= 0 { u8(0) } else if v >= 255 { u8(255) } else { u8(v) }
}

// set_placeholder_text - что предложить: открыть файл/папку или (папка
// открыта, кадр не выбран) выбрать кадр в ленте
fn set_placeholder_text(mut ph Placeholder, folder bool) {
	mut title := ph.title
	mut hint := ph.hint
	if folder {
		title.text = 'Выберите кадр'
		hint.text = 'Двойной щелчок по миниатюре в ленте'
	} else {
		title.text = 'Откройте RAW-файл или папку'
		hint.text = 'Меню «Файл»: Ctrl+O - файл, Ctrl+Shift+O - папка'
	}
}

// set_viewer_bg - фон вокруг снимка (меню «Вид»): отметка в меню (ровно
// один пункт), область снимка, запомнить в настройках
fn set_viewer_bg(mut st State, idx int) {
	for j in 0 .. st.m_bg.len {
		mut m := st.m_bg[j]
		m.checked = j == idx
	}
	st.settings.viewer_bg = bg_keys[idx]
	sync_view_bg(mut st)
	save_settings(st.settings)
	sync_settings_ui(mut st)
}

// sync_view_bg - фон области снимка: выбранный в меню - когда виден
// снимок; пока заглушка - цвет края её градиента (фон темы), чтобы
// вокруг заглушки не было рамки другого цвета
fn sync_view_bg(mut st State) {
	if isnil(st.view_area) {
		return
	}
	mut va := st.view_area
	shown := !isnil(st.holder) && !st.holder.stack.visible
	va.set_bg(if shown {
		bg_colors[bg_index(st.settings.viewer_bg)]
	} else if !isnil(st.holder) {
		st.holder.edge
	} else {
		viewer_bg
	})
}

// show_viewer убирает заглушку и показывает холст превью (кадр открыт)
fn show_viewer(mut cv vgui.Canvas, mut placeholder vgui.Stack) {
	placeholder.visible = false
	cv.visible = true
}

// show_placeholder - обратно: кадр закрыт (открыта папка)
fn show_placeholder(mut cv vgui.Canvas, mut placeholder vgui.Stack) {
	cv.visible = false
	placeholder.visible = true
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
// Тот же сплайн, которым рисует редактор кривых (vgui.curve_lut).
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
	ed.curve_color = st.pal.hue(curve_colors[st.curve_ch])
	ed.clear_ghosts()
	for c in 0 .. 4 {
		if c != st.curve_ch && !vgui.curve_is_identity(st.edit.curve_pts[c]) {
			col := st.pal.hue(curve_colors[c])
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
	// Настройки прошлого запуска: тема, фон вокруг снимка, лента
	settings := load_settings()
	// Тема приложения (меняется в меню «Вид - Тема»); из неё же -
	// палитра vraw и цвета заглушки
	theme := theme_by_key(settings.theme)
	mut app := vgui.create_app(theme: theme)!
	// Тема приложения: окно без своей темы получит её в add_window
	// Размер по умолчанию - золотое сечение: 1440 / 890 ~ 1.618
	mut win := vgui.create_window(title: 'vraw - проявка RAW', width: 1440, height: 890)!

	// Колонки панели ползунков: не константы «с запасом», а фактическая
	// ширина самых длинных строк. Первый список - все подписи рядов,
	// второй - самые длинные варианты значений (режимы пересветов и
	// крайние числа ползунков). Новая подпись длиннее нынешних просто
	// расширит колонку - наездов на ползунок не будет.
	lbl_w := column_width(mut win, ['Пересветы', 'Экспозиция', 'Тени',
		'Контраст', 'Насыщенность', 'Света', 'Чёрные', 'Средние', 'Белые',
		'Импульсный', 'Яркостный', 'Цветовой', 'Ореолы', 'Оранжевый', 'Фиолетовый', 'Пурпурный', 'Сила'], 8)
	val_w := column_width(mut win, ['без клипа', 'смешение', 'восстан. 9',
		'-4.00', '100'], 8)

	mut st := &State{}
	st.settings = settings
	st.pal = make_palette(theme)
	// База lensfun - один раз за запуск: дальше поиск профиля - доли мс
	st.lens_db = lens.load_db() or { unsafe { nil } }
	// AI-шумодав: модели и ONNX Runtime - в папке программы; загрузка
	// (~1.5 с) - при первом прогоне
	st.ai_places = ai.places(app_dir())
	st.edit = neutral_edit()

	// Холст превью скрыт до открытия файла - на его месте заглушка
	mut cv := vgui.canvas(4, 3)
	cv.fill(viewer_bg)
	cv.visible = false
	st.strip_open = st.settings.strip_open
	mut ph := make_placeholder(theme)
	st.holder = ph
	mut placeholder := ph.stack

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
	st.nm = nm

	// Приём результата фоновой подготовки сырья (главный поток, из
	// app.post). Результат старого файла или уже дождавшегося воркера
	// (wait_prep сбросил prep_running) отбрасывается.
	// Результат старого кадра (переключились, пока воркер считал) не
	// применяется, но воркер освобождается: новому кадру может быть нужна
	// своя подготовка (шумодав из сайдкара), а профиль объектива
	// прежнего кадра теперь можно освободить.
	st.prep_done = fn [mut st, mut cv, mut hist, mut app] (res PrepResult) {
		if !st.prep_running {
			return
		}
		wait_prep(mut st) // воркер уже отдал результат - join мгновенный
		if res.gen == st.file_gen {
			take_prep(mut st, res)
			apply_pipeline(mut st, mut cv, mut hist)
		}
		if st.dev_linear.len > 0 && (st.lens_dirty || prep_stale(st)) {
			// Пока воркер считал, настройки снова поменялись (или это
			// был старый кадр)
			request_prep(mut st, mut app, false)
		}
		// Новое сырьё - AI (если включён) пересчитается по нему
		ai_check(mut st, mut app)
	}
	// AI-шумодав (ai_nr.v): прогресс и итог прогона - в главном потоке
	st.ai_progress = fn [mut st] (ctl &AiCtl, done int, total int, eta f64) {
		mut c := unsafe { ctl }
		c.done = done
		c.total = total
		c.eta = eta
		if st.ai_prev == ctl {
			sync_ai_ui(mut st)
		}
	}
	st.ai_done = fn [mut st, mut app] (res AiResult) {
		ai_take(mut st, mut app, res)
	}
	// Скачивание моделей (settings_ui.v): прогресс и итог
	st.dl_progress = fn [mut st] (ctl &DlCtl, done i64) {
		mut c := unsafe { ctl }
		c.done = done
		if st.dl == ctl {
			sync_settings_ui(mut st)
		}
	}
	st.dl_done = fn [mut st] (res DlResult) {
		dl_take(mut st, res)
	}
	st.open_settings = fn [mut st, mut app, win] () {
		show_settings(mut st, mut app, win)
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
		if prep_stale(st) {
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
	st.secondary_labels << lens_lb

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
	mut b_autoexp := icon_button(mut st, 'wand-sparkles', 'Авто-экспозиция')
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
		eq_rows << edit_row(mut st, mut s, lbl_w, val_w)
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
	mut curve_reset := reset_button(mut st, 'Сбросить кривую канала')
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
	st.hint_labels << curve_hint
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
			st.hsl_labels << lb // цвет диапазона, под тему - paint_ui
			rows << SectionRow{edit_row(mut st, mut s, lbl_w, val_w), 26}
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
	// Одиночный щелчок (и стрелки) только выделяет запись; переход -
	// двойным щелчком или Enter (on_dbl_click зовётся на оба)
	hist_lb.on_dbl_click = fn [mut st, mut cv, mut hist, mut nm, mut app] (idx int, text string) {
		goto_history(mut st, idx, mut cv, mut hist, mut nm, mut app)
	}
	st.hist_lb = hist_lb
	mut hist_hint := vgui.label('Двойной щелчок - перейти, Ctrl+Z / Ctrl+Shift+Z')
	st.hint_labels << hist_hint
	hist_hint.font_size = 12
	// Ctrl+Z / Ctrl+Shift+Z - пункты меню «Правка» (сочетания обрабатывает
	// меню); Ctrl+Y - дополнительно, горячей клавишей окна
	undo := fn [mut st, mut cv, mut hist, mut nm, mut app] () {
		goto_history(mut st, st.hist_pos - 1, mut cv, mut hist, mut nm, mut app)
	}
	redo := fn [mut st, mut cv, mut hist, mut nm, mut app] () {
		goto_history(mut st, st.hist_pos + 1, mut cv, mut hist, mut nm, mut app)
	}
	win.bind_hotkey('Ctrl+Y', redo)

	// ── Открытие файла (кнопка, аргумент, лента) ──
	// Быстрая часть - здесь, в главном потоке: файл, настройки и история
	// из сайдкара, лента. Проявка, коррекция и камерная кривая - в фоне
	// (load_worker), кадр сразу виден по встроенному превью камеры.
	open_file := fn [mut st, mut cv, mut nm, mut app, mut lens_cb, mut lens_lb] (path_arg string) {
		// Полный путь: по нему лента ищет кадр и узнаёт смену папки
		path := os.real_path(path_arg)
		mut nd := raw.open(path) or {
			nm.show_error('Ошибка: ${err.msg()}')
			return
		}
		// Незаконченная загрузка прежнего кадра отменяется; её dev/corr
		// освободит on_load_done, увидев старый file_gen
		if !isnil(st.load_stop) {
			mut ls := st.load_stop
			ls.stop = true
		}
		if !isnil(st.dev) {
			st.dev.close()
			st.dev = unsafe { nil }
		}
		// Профиль - из общей базы: фоновая подготовка может ещё держать
		// указатель, освобождать нечего, просто забываем
		st.corr = unsafe { nil }
		st.file_gen++
		st.loading = true
		ai_forget(mut st)
		st.raw_pending = false
		st.dev_linear = []u16{}
		st.raw_linear = []u16{}
		st.linear = []u16{}
		st.mask = []u16{}
		st.curve = []f32{}
		st.lens_dirty = false
		lens_lb.text = 'поиск профиля объектива...'
		lens_cb.enabled = false
		// Правки и история из сайдкара (производные поля снимков - по
		// камерной кривой - заполнит on_load_done)
		st.side_path = sidecar_path(path)
		st.side_err = false
		st.load_msg = ''
		side := load_sidecar(st.side_path) or {
			st.load_msg = '${os.file_name(path)}: правки не прочитаны (${err.msg()})'
			LoadedSidecar{}
		}
		if side.history.len > 0 {
			set_edit(mut st, side.history[side.current].state)
			st.history = side.history.clone()
			st.hist_pos = side.current
			st.hist_ms = 0
			refresh_history(mut st)
		} else {
			set_edit(mut st, neutral_edit())
			start_history(mut st)
		}
		show_frame(mut st, path, mut app)
		stop := &StopFlag{}
		st.load_stop = stop
		// Холст с картинкой - превью впишется в него (зум сохранится, если
		// кадр того же размера); пустой холст (4x3) - по размеру превью
		has_img := cv.width * cv.height > 12
		job := LoadJob{
			gen:       st.file_gen
			dev:       nd
			db:        st.lens_db
			highlight: st.edit.highlight
			lens_corr: st.edit.lens_corr
			tw:        if has_img { cv.width } else { 0 }
			th:        if has_img { cv.height } else { 0 }
			stop:      stop
		}
		st.load_threads << spawn load_worker(job, mut app, st.on_load_pv, st.on_load_done)
	}

	// Быстрое превью загрузки: на холст (и гистограмму), пока кадр
	// проявляется
	st.on_load_pv = fn [mut st, mut cv, mut hist, mut placeholder] (pv LoadPreview) {
		if pv.gen != st.file_gen || !st.loading {
			return
		}
		if pv.w != cv.width || pv.h != cv.height {
			set_canvas_size(mut cv, pv.w, pv.h)
		}
		cv.pixels = pv.pix
		cv.mark_dirty()
		render_histogram(mut hist, cv.pixels)
		show_viewer(mut cv, mut placeholder)
		sync_view_bg(mut st)
	}

	// Итог загрузки: хендлы и буферы - в State, затем досчитать то, что
	// изменили за время загрузки (как restore_edit), и apply
	st.on_load_done = fn [mut st, mut cv, mut hist, mut nm, mut app, mut lens_cb, mut lens_lb, mut crv_cb, mut placeholder] (res LoadResult) {
		if res.gen != st.file_gen {
			free_load(res) // отменённая загрузка прежнего кадра
			return
		}
		st.loading = false
		if res.err.len > 0 {
			free_load(res)
			nm.show_error(res.err)
			return
		}
		st.dev = res.dev
		st.meta = res.meta
		st.corr = res.corr
		show_lens(st, mut lens_cb, mut lens_lb)
		st.hl_developed = res.highlight
		if res.w != cv.width || res.h != cv.height {
			set_canvas_size(mut cv, res.w, res.h)
		}
		st.pw = res.w
		st.ph = res.h
		st.dev_linear = res.dev_linear
		st.raw_linear = res.raw_linear
		st.linear = res.linear
		st.mask = res.mask
		st.nr_applied = [f32(0), 0, 0, 0]!
		st.ai_applied = 0
		st.lens_dirty = false
		st.raw_pending = false
		st.curve = res.curve
		crv_cb.enabled = st.curve.len > 0
		// Производные поля снимков - по камерной кривой этого кадра
		st.edit = with_derived(st.edit, st.curve)
		st.history = st.history.map(HistEntry{
			name:  it.name
			key:   it.key
			state: with_derived(it.state, st.curve)
		})
		show_viewer(mut cv, mut placeholder)
		sync_view_bg(mut st)
		// Что поменяли за время загрузки (и шумодав из сайдкара)
		if st.edit.highlight != st.hl_developed {
			load_preview(mut st, mut cv, mut hist, mut nm, mut app, true)
		} else if st.edit.lens_corr != res.lens_corr {
			request_prep(mut st, mut app, true)
		} else if prep_stale(st) {
			request_prep(mut st, mut app, false)
		}
		apply_pipeline(mut st, mut cv, mut hist)
		// AI из сайдкара - прогон модели по превью (с прогрессом в секции)
		ai_check(mut st, mut app)
		if st.load_msg.len > 0 {
			nm.show_warning(st.load_msg)
		}
	}

	// ── Лента кадров папки (browser.v) ──
	// Переход к кадру: правки текущего уже в его сайдкаре (пишется после
	// каждой правки), следующий открывается со своими. Не открылся -
	// выделение возвращается на текущий.
	goto_frame := fn [mut st, open_file] (idx int) {
		if idx < 0 || idx >= st.frames.len || idx == st.frame_idx {
			return
		}
		open_file(st.frames[idx].path)
		sync_strip(mut st)
	}
	st.thumb_done = fn [mut st] (res ThumbResult) {
		take_thumb(mut st, res)
	}
	mut strip := vgui.list_box_h(strip_item_width(strip_pane_h))
	strip.pad = strip_pad
	// Одиночный щелчок (и стрелки при фокусе на ленте) только выделяет
	// миниатюру; открыть кадр - двойным щелчком или Enter
	strip.on_dbl_click = fn [goto_frame] (idx int, text string) {
		goto_frame(idx)
	}
	st.strip = strip
	mut strip_info := vgui.label('')
	st.secondary_labels << strip_info
	st.strip_info = strip_info
	mut strip_toggle := vgui.button('Скрыть ленту')
	strip_toggle.style = .outline
	strip_toggle.on_click = fn [mut st] () {
		set_strip_open(mut st, !st.strip_open)
	}
	st.strip_toggle = strip_toggle
	mut strip_bar := vgui.create_hbox_fill()
	strip_bar.set_spacing(8)
	strip_bar.add(strip_info, 1)
	strip_bar.add_fixed(strip_toggle, 130)
	st.strip_bar = strip_bar
	// ←/→, Home/End - соседний, первый, последний кадр (если фокус не у
	// ползунка: его стрелки двигают значение)
	win.bind_hotkey('Left', fn [mut st, goto_frame] () {
		goto_frame(st.frame_idx - 1)
	})
	win.bind_hotkey('Right', fn [mut st, goto_frame] () {
		goto_frame(st.frame_idx + 1)
	})
	win.bind_hotkey('Home', fn [goto_frame] () {
		goto_frame(0)
	})
	win.bind_hotkey('End', fn [mut st, goto_frame] () {
		goto_frame(st.frames.len - 1)
	})

	// ── Файл: открыть файл или папку, экспорт (меню «Файл») ──
	open_file_dialog := fn [mut app, win, open_file] () {
		path := vgui.native_open_file_dialog(win, mut app, vgui.NativeFileDialogConfig{
			filter_names:    ['RAW-файлы', 'Все файлы']
			filter_patterns: [raw_patterns, '*']
		})
		if path.len > 0 {
			open_file(path)
		}
	}

	// close_file - в области просмотра нет кадра (открыта папка без
	// выбора): загрузка отменяется, LibRaw закрывается, история пуста
	// (правки некуда писать - record без истории молчит), вместо снимка -
	// заглушка. Результаты фоновых воркеров отбросятся по file_gen.
	close_file := fn [mut st, mut cv, mut hist, mut lens_cb, mut lens_lb, mut placeholder] () {
		if !isnil(st.load_stop) {
			mut ls := st.load_stop
			ls.stop = true
		}
		st.loading = false
		if !isnil(st.dev) {
			st.dev.close()
			st.dev = unsafe { nil }
		}
		st.corr = unsafe { nil }
		st.file_gen++
		ai_forget(mut st)
		st.raw_pending = false
		st.dev_linear = []u16{}
		st.raw_linear = []u16{}
		st.linear = []u16{}
		st.mask = []u16{}
		st.curve = []f32{}
		st.side_path = ''
		set_edit(mut st, neutral_edit())
		st.history = []HistEntry{}
		st.hist_pos = 0
		refresh_history(mut st)
		st.frame_idx = -1
		lens_lb.text = ''
		lens_cb.enabled = false
		hist.fill(vgui.Color{16, 16, 18, 255})
		hist.mark_dirty()
		show_placeholder(mut cv, mut placeholder)
		sync_view_bg(mut st)
	}

	// Открыть папку: все RAW - в ленте, в области просмотра ничего
	// (заглушка «Выберите кадр»); кадр открывается двойным щелчком
	open_folder := fn [mut st, mut app, mut nm, close_file] (dir string) {
		close_file()
		load_folder(mut st, os.real_path(dir), '', mut app)
		sync_strip(mut st)
		mut ph := st.holder
		set_placeholder_text(mut ph, st.frames.len > 0)
		if st.frames.len == 0 {
			nm.show_warning('В папке нет RAW-файлов')
		}
	}
	open_folder_dialog := fn [mut app, win, open_folder] () {
		dir := vgui.native_select_folder_dialog(win, mut app, vgui.NativeFileDialogConfig{})
		if dir.len > 0 {
			open_folder(dir)
		}
	}

	// Экспорт - в фоновом потоке (полный кадр с коррекцией ~3.5 с, окно
	// не должно замирать), ход - в диалоге экспорта (export_ui.v). Пока
	// экспорт идёт, пункт меню не запускает второй, а снова открывает
	// диалог; ползунки остаются живыми. Прогресс и результат воркер
	// доставляет через app.post() - цикл vgui спит как обычно.
	mut m_export := vgui.menu_action('Экспорт JPEG...')
	m_export.shortcut = 'Ctrl+E'
	st.exp_progress = fn [mut st] (ctl &ExportCtl, stage ExportStage, done int, total int, eta f64) {
		mut c := unsafe { ctl }
		if stage != c.stage {
			c.done = 0
			c.total = 0
			c.eta = -1
		}
		c.stage = stage
		if total > 0 {
			c.done = done
			c.total = total
			c.eta = eta
		}
		if st.exp == ctl {
			sync_export_ui(mut st)
		}
	}
	save_done := fn [mut st, mut nm] (res SaveOutcome, msg string) {
		st.exp = unsafe { nil }
		// Итог - в открытом диалоге, иначе тостом
		if !export_finished(mut st, res, msg) {
			match res {
				.saved { nm.show_success(msg) }
				.failed { nm.show_error(msg) }
				.cancelled { nm.show_warning(msg) }
			}
		}
		sync_settings_ui(mut st)
	}
	m_export.on_click = fn [mut st, mut nm, mut app, win, save_done] () {
		if !isnil(st.exp) {
			show_export(mut st, mut app, win)
			return
		}
		if st.loading {
			nm.show_warning('Кадр ещё загружается')
			return
		}
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
		mut ai_cache := &ai.Cache(unsafe { nil })
		mut ai_secs := 0.0
		if st.edit.ai > 0 {
			// Модель кадра (которой считано превью) - без неё не проявить
			ai_cache = ai_cache_for(mut st, st.edit.ai_model) or {
				nm.show_error('Экспорт с AI-шумодавом: ${err.msg()}')
				return
			}
			ai_secs = ai_estimate(st, st.edit.ai_model, true)
		}
		ctl := &ExportCtl{
			src:     st.dev.path
			dst:     path
			plan:    export_plan(st.edit, ai_secs)
			started: time.now().unix_milli()
		}
		// Снимок всего нужного по значению: воркер не трогает st после спавна
		job := SaveJob{
			src:      st.dev.path
			dst:      path
			db:       st.lens_db
			edit:     st.edit.clone()
			quality:  st.settings.jpeg_quality
			ai_cache: ai_cache
			ctl:      ctl
			on_stage: st.exp_progress
		}
		st.exp = ctl
		show_export(mut st, mut app, win)
		export_started(mut st)
		// Пока идёт экспорт, модели не удалить (модель может быть в работе)
		sync_settings_ui(mut st)
		st.save_threads << spawn save_worker(job, mut app, save_done)
	}

	// «Сброс» тональный: пересветы, коррекция объектива, камерная кривая
	// и шумодав остаются как есть. Это обычная правка - запись в истории,
	// отменяется Ctrl+Z. Пункт меню «Правка - Сбросить тон».
	reset_tone := fn [mut st, mut cv, mut hist, mut nm, mut app] () {
		mut e := st.edit.clone()
		e.params = pipeline.Params{}
		e.curve_pts = neutral_edit().curve_pts
		restore_edit(mut st, e, mut cv, mut hist, mut nm, mut app)
		record(mut st, 'reset', 'Сброс', false)
	}

	// ── Меню вверху окна ──
	// Сочетания клавиш пунктов обрабатывает само меню (MenuBar)
	mut bar := vgui.menu_bar()
	mut m_open := vgui.menu_action('Открыть файл...')
	m_open.shortcut = 'Ctrl+O'
	m_open.on_click = open_file_dialog
	mut m_open_dir := vgui.menu_action('Открыть папку...')
	m_open_dir.shortcut = 'Ctrl+Shift+O'
	m_open_dir.on_click = open_folder_dialog
	mut m_quit := vgui.menu_action('Выход')
	m_quit.shortcut = 'Ctrl+Q'
	m_quit.on_click = fn [mut app] () {
		app.quit()
	}
	bar.add_menu('Файл', [m_open, m_open_dir, vgui.menu_separator(), m_export,
		vgui.menu_separator(), m_quit])

	mut m_undo := vgui.menu_action('Отменить')
	m_undo.shortcut = 'Ctrl+Z'
	m_undo.on_click = undo
	mut m_redo := vgui.menu_action('Вернуть')
	m_redo.shortcut = 'Ctrl+Shift+Z'
	m_redo.on_click = redo
	mut m_reset := vgui.menu_action('Сбросить тон')
	m_reset.shortcut = 'Ctrl+Shift+R'
	m_reset.on_click = reset_tone
	mut m_settings := vgui.menu_action('Настройки...')
	m_settings.shortcut = 'Ctrl+P'
	m_settings.on_click = fn [mut st] () {
		st.open_settings()
	}
	bar.add_menu('Правка', [m_undo, m_redo, vgui.menu_separator(), m_reset,
		vgui.menu_separator(), m_settings])

	mut m_fit := vgui.menu_action('Вписать')
	m_fit.shortcut = 'Ctrl+0'
	m_fit.on_click = fn [mut cv] () {
		cv.fit_to_view()
	}
	mut m_z50 := vgui.menu_action('50%')
	m_z50.on_click = fn [mut cv] () {
		cv.set_zoom(0.5)
	}
	mut m_z100 := vgui.menu_action('100% (1:1)')
	m_z100.shortcut = 'Ctrl+1'
	m_z100.on_click = fn [mut cv] () {
		cv.set_zoom(1.0)
	}
	mut m_z200 := vgui.menu_action('200%')
	m_z200.on_click = fn [mut cv] () {
		cv.set_zoom(2.0)
	}
	mut m_strip := vgui.menu_checkbox('Лента кадров', st.strip_open)
	m_strip.on_toggle = fn [mut st] (v bool) {
		set_strip_open(mut st, v)
	}
	st.m_strip = m_strip
	// Фон вокруг снимка: пункты-флажки, работают как переключатель
	// (отмечен ровно один - set_viewer_bg)
	mut m_bg := vgui.menu_submenu('Фон вокруг снимка')
	for i in 0 .. bg_keys.len {
		mut it := vgui.menu_checkbox(bg_names[i], bg_keys[i] == st.settings.viewer_bg)
		it.on_toggle = fn [mut st, i] (v bool) {
			set_viewer_bg(mut st, i)
		}
		st.m_bg << it
		m_bg.add(it)
	}
	// Тема оформления: все темы vgui, пункты-флажки как переключатель
	mut m_themes := vgui.menu_submenu('Тема')
	for i in 0 .. theme_keys.len {
		mut it := vgui.menu_checkbox(theme_names[i], theme_keys[i] == st.settings.theme)
		it.on_toggle = fn [mut st, mut app, i] (v bool) {
			apply_theme(mut st, mut app, i)
		}
		st.m_theme << it
		m_themes.add(it)
	}
	bar.add_menu('Вид', [m_fit, m_z50, m_z100, m_z200, vgui.menu_separator(), m_strip,
		m_bg, m_themes])

	mut hl_row := edit_row(mut st, mut hl, lbl_w, val_w)
	// Ряд экспозиции - как slider_row, но с дополнительной кнопкой «Авто»
	// между значением и сбросом.
	mut b_expreset := reset_button(mut st, 'Сбросить')
	b_expreset.on_click = fn [mut exp_sl] () {
		exp_sl.set_value(0.0)
	}
	mut exp_row := vgui.create_hbox_fill()
	exp_row.set_spacing(6)
	exp_row.add_fixed(exp.lb, lbl_w)
	exp_row.add(exp_sl, 1)
	exp_row.add_fixed(exp.vl, val_w)
	exp_row.add_fixed(b_autoexp, 26)
	exp_row.add_fixed(b_expreset, 26)
	mut sh_row := edit_row(mut st, mut sh, lbl_w, val_w)
	mut con_row := edit_row(mut st, mut con, lbl_w, val_w)
	mut sat_row := edit_row(mut st, mut sat, lbl_w, val_w)
	mut hlt_row := edit_row(mut st, mut hlt, lbl_w, val_w)
	mut sht_row := edit_row(mut st, mut sht, lbl_w, val_w)
	mut imp_row := edit_row(mut st, mut imp, lbl_w, val_w)
	mut nrl_row := edit_row(mut st, mut nrl, lbl_w, val_w)
	mut nrc_row := edit_row(mut st, mut nrc, lbl_w, val_w)
	mut df_row := edit_row(mut st, mut df, lbl_w, val_w)
	// AI-шумодав - блок над классическими ползунками (ai_nr.v). Сила -
	// обычная настройка кадра (история, сайдкар): смешение с результатом
	// модели в подготовке сырья, мгновенно - модель не пересчитывается.
	mut ai_str := edit_slider(mut st, SliderCfg{
		label:  'Сила'
		hname:  'AI-шумодав: сила'
		min:    1
		max:    100
		def:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return if e.ai > 0 { e.ai } else { 100 }
		}
		set:    fn (mut e EditState, v f32) {
			e.ai = v
		}
		fx:     prep_fx
	})
	ai_block := build_ai_block(mut st, mut app, mut ai_str, lbl_w, val_w)
	mut ai_caption := vgui.label('Нейросеть')
	ai_caption.font_style = .bold
	mut classic_caption := vgui.label('Классический')
	classic_caption.font_style = .bold
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
		SectionRow{ai_caption, 16},
		SectionRow{ai_block, ai_block_h},
		SectionRow{vgui.separator(), 9},
		SectionRow{classic_caption, 16},
		SectionRow{imp_row, 26},
		SectionRow{nrl_row, 26},
		SectionRow{nrc_row, 26},
		SectionRow{df_row, 26},
	]))
	// История - последней секцией, открыта: 8 строк списка и подсказка
	acc.add_section_expanded('История', section([
		SectionRow{hist_lb, 8 * 22 + 8},
		SectionRow{hist_hint, 16},
	]))

	mut scroll := vgui.scroll_box(0)
	scroll.sb_width = 8
	scroll.add(acc)

	// Правая панель - свой фон и внутренние отступы: гистограмма сверху,
	// инструменты в прокрутке. Открытие, экспорт, масштаб и «Сбросить
	// тон» - в меню вверху окна.
	mut right := vgui.create_vbox_fill()
	right.set_spacing(6)
	right.set_padding(10)
	st.right = right
	right.add_fixed(hist, 120)
	right.add(scroll, 1)

	// Область снимка: фон, выбранный в меню «Вид», картинка с отступом от
	// краёв. Холст и заглушка лежат друг на друге в Stack, видим один.
	mut view_stack := &vgui.Stack{}
	view_stack.add(cv)
	view_stack.add(placeholder)
	mut view_area := vgui.create_vbox_fill()
	view_area.set_padding(16)
	view_area.set_bg(ph.edge) // выбранный фон - когда виден снимок (sync_view_bg)
	view_area.add(view_stack, 1)
	st.view_area = view_area
	st.view_stack = view_stack
	// Область просмотра - снимок и под ним лента кадров папки
	// (layout_strip, когда открыт файл или папка)
	mut viewer := vgui.create_vbox_fill()
	viewer.add(view_area, 1)
	st.viewer = viewer
	// Высота ленты - вертикальным сплиттером; после перетаскивания ячейки
	// подстраиваются под новую высоту
	mut vsplit := vgui.splitter_vertical()
	vsplit.bar_size = 3
	vsplit.min_first = 200
	vsplit.min_second = strip_bar_h + 80 + 2 * strip_box_pad
	// Стартовая высота ленты ~strip_pane_h при высоте окна 946 (минус меню)
	vsplit.ratio = 1 - strip_pane_h / (946 - 28)
	vsplit.on_resize = fn [mut st] (r f32) {
		fit_strip_items(mut st)
	}
	st.vsplit = vsplit
	// Панель ленты: полоса и лента на тёмном фоне с полями
	mut strip_box := vgui.create_vbox_fill()
	strip_box.set_spacing(4)
	strip_box.set_padding(strip_box_pad)
	st.strip_box = strip_box

	// Просмотр | панель инструментов - горизонтальный сплиттер: ширину
	// панели можно менять (по умолчанию 440 при ширине окна 1280)
	mut top := vgui.splitter_horizontal()
	top.bar_size = 3
	top.min_first = 400
	top.min_second = 360
	top.ratio = (1280 - 3 - 440) / f32(1280 - 3)
	top.set_first(viewer)
	top.set_second(right)
	// Ширина просмотра изменилась - текущий кадр ленты снова по центру
	top.on_resize = fn [mut st] (r f32) {
		center_strip(mut st)
	}
	st.hsplit = top

	// Корень: меню вверху, под ним рабочая область
	mut root := vgui.create_vbox_fill()
	root.add_fixed(bar, 28)
	root.add(top, 1)
	win.add_widget(root)
	// Менеджер уведомлений - после корневого контейнера: рисуется поверх
	// всего окна, события получает первым (Window обходит виджеты с конца).
	// Свои цвета vraw по палитре темы (фоны панелей, разделители, подписи)
	paint_ui(mut st, theme)
	// Всплывающие подсказки кнопок-значков - поверх рабочей области
	for t in st.tips {
		win.add_widget(t)
	}
	win.add_widget(nm)
	app.add_window(win)

	// Путь к RAW можно передать аргументом: vraw файл.CR3
	if os.args.len > 1 && os.exists(os.args[1]) {
		open_file(os.args[1])
	}

	app.run()

	// Прогон AI по превью - отменить (вернётся после текущей плитки)
	if !isnil(st.ai_prev) {
		mut c := st.ai_prev
		c.cancel = true
	}
	for t in st.ai_threads {
		t.wait()
	}
	// Скачивание - отменить (недокачанный .part удалится сам)
	if !isnil(st.dl) {
		mut c := st.dl
		c.cancel = true
	}
	for t in st.dl_threads {
		t.wait()
	}
	// Не обрывать записывающийся JPEG, если окно закрыли во время сохранения
	// (экспорт с AI доработает до конца - это минуты, но файл важнее)
	for t in st.save_threads {
		t.wait()
	}
	if !isnil(st.dev) {
		st.dev.close()
	}
	wait_prep(mut st) // воркер пользуется профилем из st.lens_db
	wait_thumbs(mut st)
	wait_loads(mut st)
	// Потоки сохранения уже дождались выше (повторный wait того же потока
	// роняет программу: «V thread join failed»); база lensfun, которой они
	// пользуются, освобождается только после них
	st.save_threads.clear()
	if !isnil(st.lens_db) {
		st.lens_db.free()
	}
	for _, c in st.ai_caches {
		mut cc := unsafe { c }
		cc.free()
	}
}
