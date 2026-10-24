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
import imgio
import vgui
import raw
import lens
import pipeline
import i18n

const raw_patterns = 'CR3;CR2;CRW;NEF;ARW;DNG;RAF;ORF;RW2;cr3;cr2;crw;nef;arw;dng;raf;orf;rw2'

struct State {
mut:
	dev          &raw.Developer = unsafe { nil }
	dev_linear   []u16 // превью прямо из LibRaw, без коррекции объектива
	raw_linear   []u16 // превью после коррекции объектива, ДО шумодава
	linear       []u16 // линейное 16-битное RGB-превью (half-size), сырьё пайплайна
	mask         []u16 // маска окрестности превью: «Тени/Света» и вес Clarity (pipeline.luma_masks)
	pw           int   // размеры превью
	ph           int
	edit         EditState // все настройки правки кадра (history.v)
	// true = пакетная установка виджетов (откат истории, сброс, новый файл):
	// on_change только пишут настройки - без пересчётов и записей в историю
	suppress bool
	meta         raw.Meta // метаданные открытого кадра (для профиля объектива)
	// База lensfun - загружается один раз за запуск (~115 мс), профили
	// кадров (corr) ссылаются на неё; nil - база не загрузилась
	lens_db      &lens.Database  = unsafe { nil }
	corr         &lens.Corrector = unsafe { nil } // профиль lensfun или nil
	look         CamLook // «как JPEG» кадра (кривая и насыщенность), пусто - нет превью
	nr_applied   [4]f32 = [f32(-1), -1, -1, -1]! // значения последней подготовки сырья
	dc_applied   [3]f32 = [f32(-1), -1, -1]! // Capture-резкость последней подготовки (dc_key)
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
	// Гистограмма на экране (histogram.v; themes.v перерисовывает её при
	// смене темы): холст и состояние вида - счётчики, зона, перетаскивание
	hist_cv &vgui.Canvas = unsafe { nil }
	hv      HistView
	// Ползунок эквалайзера ведёт перетаскивание зоны гистограммы:
	// edit_slider пишет значение и откладывает пересчёт, без истории
	hist_drag bool
	// История правок (history.v): записи, текущая, время последней записи
	// для склейки шагов (0 - не склеивать), особое название следующей записи
	history    []HistEntry
	hist_pos   int
	hist_ms    i64
	// Виджеты, которые выставляет откат истории (set_edit)
	binds   []SliderBind
	lens_cb &vgui.CheckBox = unsafe { nil }
	prof_cb &vgui.ComboBox = unsafe { nil } // «Профиль» (profile.v)
	hist_lb &vgui.ListBox  = unsafe { nil }
	nm      &vgui.NotificationManager = unsafe { nil }
	// Сайдкар правок (sidecar.v): путь (пусто - не писать), ошибка записи
	// уже показана (не повторять на каждую правку)
	side_path string
	raw_path  string // открытый RAW (полный путь) - для фрагмента 1:1 (detail_ui.v)
	side_err  bool
	// Браузер папки (browser.v): кадры папки открытого файла, текущий,
	// лента и полоса над ней, фоновый воркер миниатюр
	folder        string
	frames        []Frame
	cells         []&StripCell // запас ячеек ленты (browser.v, strip_cell)
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
	thumb_seq     int // номер последнего расчёта миниатюр (ThumbResult.seq)
	// Миниатюра открытого кадра из его превью (browser.v, update_live_thumb)
	// и номер файла, к которому она относится
	live_thumb []u8
	live_gen   int
	// Отбор (rating.v): пометка открытого кадра (в его сайдкаре), фильтр
	// ленты и кадры, прошедшие его (строки ленты), список фильтра на
	// полосе; переход к кадру (goto_frame из main) - для «Переходить к
	// следующему» после пометки
	mark       Mark
	filter     string = 'all'
	shown      []int
	filter_cb  &vgui.ComboBox = unsafe { nil }
	goto_frame fn (int) = unsafe { nil }
	// Приложение - для фоновых потоков, запускаемых из обработчиков
	// (refresh_thumb); vgui трогают только через app.post
	app &vgui.App = unsafe { nil }
	// Пересчёт по ходу перетаскивания уже поставлен (defer_fx): какой и
	// приёмник app.post (создан один раз - post.v)
	fx_pending bool
	fx_next    fn () = unsafe { nil }
	fx_post    fn () = unsafe { nil }
	// Фоновая загрузка кадра (loader.v): идёт ли, флаг отмены, потоки,
	// предупреждение о сайдкаре для показа по окончании
	loading      bool
	load_stop    &StopFlag = unsafe { nil }
	load_threads []thread
	load_msg     string
	on_load_done fn (LoadResult) = unsafe { nil }
	load_ov      &LoadOverlay    = unsafe { nil } // оверлей «Обработка» (loading.v)
	// Предзагрузка соседа (prefetch.v): куда листали (+1/-1), идёт ли, её
	// поколение, флаг отмены, путь; открытый кадр ждёт её итога (pf_wait -
	// путь, pf_nd - хендл LibRaw из open_file); приёмник итога
	nav_dir    int = 1
	pf_running bool
	pf_gen     int
	pf_stop    &StopFlag = unsafe { nil }
	pf_path    string
	pf_wait    string
	pf_nd      &raw.Developer = unsafe { nil }
	pf_done    fn (PfResult)  = unsafe { nil }
	// Настройки между запусками (settings.v) и меню, которое их отражает
	settings Settings
	m_strip  &vgui.MenuItem = unsafe { nil }
	m_panel  &vgui.MenuItem = unsafe { nil }
	m_left   &vgui.MenuItem = unsafe { nil }
	m_top    &vgui.MenuItem = unsafe { nil }
	m_full   &vgui.MenuItem = unsafe { nil }
	// Полноэкранный режим (panel.v): окно на весь экран без меню, панели
	// и ленты; в настройки не пишется
	fullscreen bool
	win        &vgui.Window = unsafe { nil }
	// Раскладка окна (panel.v): корень (меню + рабочая область), меню,
	// аккордеон панели, виджеты разделов и их раскрытость (по индексу
	// panel_sections), показанные разделы по порядку секций
	root       &vgui.VBox      = unsafe { nil }
	menu       &vgui.MenuBar   = unsafe { nil }
	acc        &vgui.Accordion = unsafe { nil }
	sec_w      []&vgui.Widget
	// ряды slider_row по ползунку: выключается ряд целиком (set_slider_enabled)
	slider_rows map[voidptr]&vgui.HBox
	sec_open   []bool
	panel_keys []string
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
	bw_cb            &vgui.CheckBox = unsafe { nil } // «Чёрно-белое» (bw_ui.v)
	// Горячие клавиши (hotkeys.v): действия-пункты меню и обновление
	// подписей со вписанными сочетаниями (замыкания - один раз в main)
	hk       []HotItem
	hk_texts []fn ()
	grade_wheels     []&GradeWheel // круги раздела «Цветокоррекция» (grade_ui.v)
	// raw_pending - идёт подготовка с коррекцией объектива (raw_linear
	// вот-вот сменится)
	raw_pending bool
	// Окно настроек (settings_ui.v): создаётся один раз, открывается
	// open_settings
	sui           &SettingsUi = unsafe { nil }
	open_settings fn ()       = unsafe { nil }
	// Открыть файл и папку - для меню недавних (recent.v)
	open_path        fn (string)     = unsafe { nil }
	open_dir         fn (string)     = unsafe { nil }
	m_recent_files   &vgui.MenuItem = unsafe { nil }
	m_recent_dirs    &vgui.MenuItem = unsafe { nil }
	// Экспорт (export_ui.v): идущий (nil - нет), его диалог и приёмник
	// прогресса в главном потоке
	exp          &ExportCtl = unsafe { nil }
	eui          &ExportUi  = unsafe { nil }
	exp_progress fn (&ExportCtl, ExportStage, int, int) = unsafe { nil }
	// Окно «Экспорт» перед запуском (export_setup.v) и запуск экспорта в
	// файл (путь и формат - из окна)
	xs        &ExportSetupUi = unsafe { nil }
	export_go fn (string, imgio.Format) = unsafe { nil }
	// Пакетный экспорт (batch.v): запуск по путям кадров и приёмник
	// начала очередного кадра в главном потоке
	export_batch fn ([]string) = unsafe { nil }
	exp_event    fn (&ExportCtl, BatchEvent) = unsafe { nil }
	// Баланс белого (wb_ui.v): цвет камеры кадра и его ББ «как снято»,
	// виджеты секции, режим пипетки; холст и тональный пересчёт - для
	// обработчиков секции
	cam         pipeline.CamColor
	shot_temp   f32
	shot_tint   f32
	wb_cb       &vgui.ComboBox = unsafe { nil }
	wb_pick_btn &vgui.Button   = unsafe { nil }
	wb_temp_sl  &vgui.Slider   = unsafe { nil }
	wb_tint_sl  &vgui.Slider   = unsafe { nil }
	wb_pick     bool
	cv          &vgui.Canvas = unsafe { nil }
	// Настоящий 1:1 - фрагмент полного кадра поверх превью (detail_ui.v)
	dt       &DetailCtl = unsafe { nil }
	dt_check fn ()          = unsafe { nil } // detail_check через app.post
	dt_done  fn (DetailRes) = unsafe { nil } // итог detail_worker
	tone_fx     fn () = unsafe { nil }
	// Удаление дымки: карта кадра по st.linear (считается при первой
	// надобности, сбрасывается с каждым новым linear), показ карты вместо
	// снимка (флажок, вид - не правка)
	haze      pipeline.HazeMap
	haze_show bool
	// Показ работы резкости вместо снимка (вид, не правка): флажок «маска
	// краёв» и временный показ с Alt при перетаскивании ползунка резкости
	// (sharp_drag - его режим, off - нет)
	sharp_show   bool
	sharp_drag   pipeline.SharpView
	sharp_rgb_cb &vgui.CheckBox = unsafe { nil }
	// Кадрирование и поворот (crop.v). Геометрия превью - glin/gmask
	// (gw x gh) из linear/mask: пересчёт, когда меняется сырьё (lin_gen),
	// геометрия или режим (geom_key). В режиме кадрирования - весь
	// повёрнутый кадр, рамка поверх холста.
	glin        []u16
	gmask       []u16
	gw          int
	gh          int
	lin_gen     int
	geom_key    GeomKey
	crop_mode   bool
	horizon     bool // инструмент «линия горизонта»
	// Инструмент «перспектива по двум линиям» (crop.v): включён, первая
	// линия (x0, y0, x1, y1 в пикселях R превью; пусто - ещё нет)
	persp_tool  bool
	persp_l1    []f64
	persp_v1    []f64 // та же линия в пикселях V (снимок без перспективы)
	crop_drag   CropDrag
	crop_before EditState // настройки при входе в режим (Esc)
	crop_ui     &CropUi = unsafe { nil }
	// Градиентные фильтры (masks.v): выделенный фильтр (-1 - нет; не
	// правка), заливка маски, перетаскивание ручки, виджеты секции
	mask_sel   int = -1
	mask_part  int = -1 // форма выделенного фильтра: -1 - основа, иначе часть
	mask_show  bool = true // заливка маски выделенного фильтра (по умолчанию видна)
	mask_drag  MaskDrag
	mask_pick  bool // пипетка цвета фильтра (ограничение диапазоном)
	// Кисть фильтра (masks.v): размер 1..100 (радиус - до четверти высоты
	// кадра), растушёвка и сила, % - настройки инструмента, не правка;
	// мазок в процессе и курсор над холстом (буфер холста)
	brush_size    f32 = 35
	brush_feather f32 = 50
	brush_flow    f32 = 100
	brush_paint   bool
	brush_hover   bool
	brush_hx      f32
	brush_hy      f32
	mask_ui    &MaskUi = unsafe { nil }
	// Удаление пятен (spots_ui.v): режим инструмента, выделенное пятно (-1 -
	// нет; не правка), перетаскивание, курсор над холстом (буфер холста);
	// настройки новых пятен (размер 1..100, растушёвка, непрозрачность,
	// режим); показ пыли (вид) и его усиление
	spot_mode    bool
	spot_sel     int = -1
	spot_drag    SpotDrag
	spot_hover   bool
	spot_hx      f32
	spot_hy      f32
	spot_size    f32 = 35
	spot_feather f32 = 20
	spot_opacity f32 = 100
	spot_kind    pipeline.SpotMode
	spot_ui      &SpotUi = unsafe { nil }
	dust_show    bool
	dust_amt     f32 = 50
	// Копирование настроек и пресеты (presets.v): буфер настроек и его
	// группы (пусто - ничего не скопировано), пункт «Вставить настройки»,
	// меню (номер пункта «Пресеты» в нём), вставка в кадры (paste_settings
	// с холстами и тостами) и окно групп (true - сохранение пресета)
	clip         EditState
	clip_groups  []string
	m_paste      &vgui.MenuItem = unsafe { nil }
	// Доступность (avail.v): пункты меню с условиями, пункты пресетов
	// (меню пересобирается), панель правки активна (без кадра - нет)
	avail         []AvailItem
	m_presets     []&vgui.MenuItem
	m_preset_save &vgui.MenuItem = unsafe { nil }
	panel_live    bool = true
	bar          &vgui.MenuBar  = unsafe { nil }
	presets_menu int = -1
	paste_fn     fn (EditState, []string, string) = unsafe { nil }
	show_groups  fn (bool)       = unsafe { nil }
	// импорт (системный диалог выбора файлов) и экспорт пресета
	// (Preset{} - всех в папку); создаются в main - им нужны окно и App
	import_presets fn ()       = unsafe { nil }
	export_presets fn (Preset) = unsafe { nil }
	show_presets   fn ()       = unsafe { nil } // окно управления
	groups_ui    &GroupsUi       = unsafe { nil }
	presets_ui   &PresetsUi      = unsafe { nil }
	// Показ пересветов и провалов (clipping.v) - вид, не правка; пункт меню
	clip_hi    bool
	clip_lo    bool
	m_clipwarn &vgui.MenuItem = unsafe { nil }
	// До/после (compare.v) - вид, не правка: удержание «\», шторка и её
	// положение (доля ширины), перетаскивание линии; буферы «до» (кэш по
	// ba_key) и «после» (для шторки без пересчёта); пункт меню шторки.
	// Щелчок по снимку - 100%: где нажали (буфер превью)
	ba_hold    bool
	ba_split   bool
	ba_pos     f32 = 0.5
	ba_drag    bool
	ba_key     BaKey
	ba_before  []u8
	ba_after   []u8
	m_split    &vgui.MenuItem = unsafe { nil }
	// «До» - запись истории ba_ref (подпись под историей - ba_lb); её
	// сырьё, если подготовка не та, что сейчас (ba_lin/ba_mask превью,
	// после геометрии - ba_glin/ba_gmask, карта дымки; ключ подготовки,
	// номер сырья, фоновый воркер - compare.v)
	ba_ref       int
	ba_lb        &vgui.Label = unsafe { nil }
	ba_lin       []u16
	ba_mask      []u16
	ba_glin      []u16
	ba_gmask     []u16
	ba_gkey      GeomKey
	ba_haze      pipeline.HazeMap
	ba_raw_key   string
	ba_want      string
	ba_gen       int
	ba_running   bool
	ba_threads   []thread
	ba_prep_done fn (PrepResult) = unsafe { nil }
	// Бок о бок: холст «до» слева, ряд холстов, пункт меню, последний
	// связанный вид
	ba_sbs   bool
	cv_b     &vgui.Canvas = unsafe { nil }
	cmp_row  &vgui.HBox   = unsafe { nil }
	m_sbs    &vgui.MenuItem = unsafe { nil }
	sbs_last ViewState
	// Сравнение двух кадров (pair.v): левый кадр (путь, RGBA без подсветки
	// клипа), номер проявки и её отмена, потоки, приёмник, пункт меню
	pair_on      bool
	pair_path    string
	pair_img     []u8
	pair_w       int
	pair_h       int
	pair_gen     int
	pair_busy    bool
	pair_flag    &StopFlag = unsafe { nil }
	pair_threads []thread
	pair_done    fn (PairResult) = unsafe { nil }
	m_pair       &vgui.MenuItem  = unsafe { nil }
	// «Вид - JPEG камеры» (camjpeg.v): показ, JPEG кадра (RGBA pw x ph
	// до геометрии; пусто - нет), пункт меню
	jpeg_show bool
	cam_view  []u8
	m_jpeg    &vgui.MenuItem = unsafe { nil }
	fcache    []&FrameCache // кэш сырья кадров (framecache.v)
	click_down bool
	click_x    f32
	click_y    f32
}

// Превью - половинного размера (LibRaw half-size): радиус резкости задан
// в пикселях полного кадра
const preview_scale = f32(0.5)

// cam_color - цвет камеры кадра для баланса белого
fn cam_color(c raw.ColorData) pipeline.CamColor {
	return pipeline.CamColor{
		shot:    c.cam_mul
		rgb_cam: c.rgb_cam
		cam_xyz: c.cam_xyz
	}
}

// GeomKey - от чего зависит геометрия превью (glin)
struct GeomKey {
	lin_gen int
	geom    pipeline.Geom
	crop    bool
	valid   bool
	spots   string // пятна (pipeline.spot_key): правят сырьё до геометрии
}

// ensure_geom - геометрия превью (glin, gmask) по текущему сырью и
// настройкам; холст - под её размер (смена размера вписывает заново)
fn ensure_geom(mut st State, mut cv vgui.Canvas) {
	key := GeomKey{
		lin_gen: st.lin_gen
		geom:    st.edit.geom
		crop:    !st.crop_mode
		valid:   true
		spots:   pipeline.spot_key(st.edit.spots)
	}
	if key != st.geom_key || st.glin.len == 0 {
		st.geom_key = key
		st.gw, st.gh = geom_stage(st.linear, st.mask, st.pw, st.ph, st.edit.spots, key, mut
			st.glin, mut st.gmask)
		st.haze = pipeline.HazeMap{}
	}
	if cv.width != st.gw || cv.height != st.gh {
		set_canvas_size(mut cv, st.gw, st.gh)
	}
}

// geom_stage - сырьё и маска превью после пятен и геометрии: прежние
// glin/gmask отпускаются, новые - свои буферы (bufown.v); если пятен нет и
// геометрия ничего не меняет - те же массивы, без копии (-48 МБ на превью
// 24 Мп): glin/gmask, как и linear/mask, только читаются. Маска пятнами не
// правится (она гладкая - пыль в ней почти не видна). Возвращает размер.
fn geom_stage(linear []u16, mask []u16, pw int, ph int, spots []pipeline.Spot, key GeomKey, mut glin []u16, mut gmask []u16) (int, int) {
	drop(mut glin)
	drop(mut gmask)
	mut lin := healed(linear, pw, ph, spots)
	if key.geom.is_noop(key.crop) {
		// Перенос ссылки (bufown.v): lin дальше не нужен
		unsafe {
			glin = lin
		}
		gmask = share(mask)
		return pw, ph
	}
	ow, oh := key.geom.out_size(pw, ph, key.crop)
	glin = own_new[u16](ow * oh * 3)
	gw, gh := pipeline.geom_apply_into(unsafe { &u16(lin.data) }, pw, ph, 3, key.geom,
		key.crop, mut glin)
	drop(mut lin)
	if mask.len == pw * ph * pipeline.mask_ch {
		gmask = own_new[u16](ow * oh * pipeline.mask_ch)
		pipeline.geom_apply_into(unsafe { &u16(mask.data) }, pw, ph, pipeline.mask_ch, key.geom,
			key.crop, mut gmask)
	}
	return gw, gh
}

// apply_pipeline прогоняет превью через пайплайн в холст и обновляет
// гистограмму. Вызывается при отпускании тонального ползунка и на каждое
// одиночное изменение (колесо, клавиши, сброс), поэтому никаких
// уведомлений отсюда - только картинка.
// defer_fx - пересчёт по ходу перетаскивания (живой ползунок, поворот
// мышью): не на каждое движение, а один на пачку событий - app.post
// выполняется после всех накопившихся событий. Пересчёт с
// поворотом ~0.25 с: прямой вызов на каждое движение копил очередь
// (десятки секунд догонять после отпускания). Окончательный пересчёт
// (отпускание) - прямой, он и снимает отложенный.
fn defer_fx(mut st State, fx fn ()) {
	if isnil(st.app) {
		fx()
		return
	}
	if st.fx_pending {
		return
	}
	st.fx_pending = true
	st.fx_next = fx
	mut app := st.app
	app.post(st.fx_post)
}

// run_deferred_fx - отложенный пересчёт (приёмник app.post из defer_fx)
fn run_deferred_fx(mut st State) {
	if st.fx_pending {
		st.fx_pending = false
		fx := st.fx_next
		st.fx_next = unsafe { nil }
		fx()
	}
}

fn apply_pipeline(mut st State, mut cv vgui.Canvas, mut hist vgui.Canvas) {
	st.fx_pending = false // отложенный пересчёт (defer_fx) уже не нужен
	if st.suppress || st.linear.len == 0 {
		return
	}
	// «После» шторки до/после пишет ba_apply в конце; показ резкости
	// выходит раньше - старый буфер не должен вернуться на холст
	st.ba_after = []u8{}
	ensure_geom(mut st, mut cv)
	npix := st.gw * st.gh
	if (st.edit.params.haze != 0 || st.haze_show) && st.haze.d.len != npix {
		st.haze = pipeline.haze_map(unsafe { &u16(st.glin.data) }, st.gw, st.gh)
	}
	if st.dust_show {
		// Показ пыли (spots_ui.v) - карта вместо снимка, гистограмма -
		// прежняя, без подсветки и до/после
		pipeline.dust_view(unsafe { &u16(st.glin.data) }, st.gw, st.gh, st.dust_amt, mut
			cv.pixels, 4)
		cv.mark_dirty()
		detail_refresh(mut st)
		return
	}
	if st.haze_show {
		pipeline.haze_view(&st.haze, st.edit.params.haze_depth, mut cv.pixels, 4)
	} else {
		view := if st.sharp_drag != .off {
			st.sharp_drag
		} else if st.sharp_show {
			pipeline.SharpView.mask
		} else {
			pipeline.SharpView.off
		}
		mask := if st.gmask.len == npix * pipeline.mask_ch {
			unsafe { &u16(st.gmask.data) }
		} else {
			unsafe { &u16(nil) }
		}
		pipeline.apply_image_view(unsafe { &u16(st.glin.data) }, mask, &st.haze, st.gw,
			st.gh, view_params(st, st.edit.params), preview_scale, view, mut cv.pixels, 4)
	}
	// Показ работы резкости - вид поверх снимка: гистограмма остаётся
	// снимка (последняя посчитанная), подсветки клипа нет
	if st.sharp_show || st.sharp_drag != .off {
		cv.mark_dirty()
		detail_refresh(mut st)
		return
	}
	// JPEG камеры (camjpeg.v) - вместо проявки, гистограмма - по нему
	if jpeg_active(st) {
		cv.pixels = jpeg_pixels(st)
		st.hist_r, st.hist_g, st.hist_b = render_histogram(mut st, mut hist, cv.pixels)
		update_curve_histogram(mut st)
		show_clip_marks(mut st, mut hist)
		cv.mark_dirty()
		detail_refresh(mut st)
		return
	}
	// В режиме кадрирования гистограмма - только по рамке (без того, что
	// будет отрезано, и без пустых углов поворота)
	st.hist_r, st.hist_g, st.hist_b = render_histogram(mut st, mut hist, if st.crop_mode {
		box_pixels(st, cv.pixels, cv.width, cv.height)
	} else {
		cv.pixels
	})
	update_curve_histogram(mut st)
	// Пересветы и провалы (clipping.v): треугольники по гистограмме
	// результата, подсветка - поверх уже посчитанной гистограммы
	show_clip_marks(mut st, mut hist)
	if !st.haze_show {
		// Миниатюра в ленте - по чистому результату, до подсветок (browser.v);
		// в кадрировании превью без обрезки - не подходит
		if !st.crop_mode {
			update_live_thumb(mut st, cv.pixels, cv.width, cv.height)
		}
		// в RAW-виде пересветы - по сырью (histogram.v)
		mark_clipping_src(mut cv.pixels, st.clip_hi, st.clip_lo, raw_clip_src(mut st,
			npix))
		mask_paint(st, mut cv.pixels) // заливка маски фильтра (masks.v)
	}
	sync_crop_total(mut st)
	// До/после (compare.v): гистограмма и подсветка - у «после»
	ba_apply(mut st, mut cv)
	cv.mark_dirty()
	detail_refresh(mut st)
}

// PrepJob - снимок для подготовки сырья: коррекция объектива (только при
// redo_lens - src это выход LibRaw), импульсы, шумодав, ореолы, маска
// «Тени/Света». src - со своей ссылкой (bufown.v: share при
// создании задания), prep_compute её отпускает. corr - профиль из общей
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
	vign      f32    // сила коррекции виньетирования (CamLook.vign)
	zoom      f32 = 1 // кадр «как у камеры» (CamLook.zoom)
	man       lens.Manual // ручная коррекция (после профиля, и без него)
	nr        [4]f32 // импульсный, яркостный, цветовой, ореолы
	dc        pipeline.Sharpen // Capture-резкость (поля dc_*)
}

struct PrepResult {
mut:
	gen        int
	raw_linear []u16 // после коррекции объектива; пусто, если коррекция не пересчитывалась
	linear     []u16
	mask       []u16
	nr         [4]f32
	dc         pipeline.Sharpen
}

// make_prep_job снимает параметры подготовки с State (главный поток)
fn make_prep_job(mut st State) PrepJob {
	redo := st.lens_dirty
	st.lens_dirty = false
	if redo {
		st.raw_pending = true
	}
	return PrepJob{
		gen:       st.file_gen
		src:       share(if redo { st.dev_linear } else { st.raw_linear })
		w:         st.pw
		h:         st.ph
		redo_lens: redo
		corr:      if st.edit.lens_corr { st.corr } else { unsafe { nil } }
		focal:     st.meta.focal
		aperture:  st.meta.aperture
		vign:      st.look.vign
		zoom:      st.look.zoom
		man:       st.edit.lman
		nr:        st.edit.nr
		dc:        st.edit.params.sharp
	}
}

// dc_key - настройки Capture-резкости, от которых зависит подготовленное
// сырьё (при выключенной радиус и порог не важны)
fn dc_key(s pipeline.Sharpen) [3]f32 {
	if s.dc_amount <= 0 {
		return [f32(0), 0, 0]!
	}
	return [s.dc_amount, s.dc_radius, s.dc_contrast]!
}

// prep_compute - сама подготовка сырья, без обращений к State и vgui:
// выполняется и в фоне (prep_worker), и напрямую (открытие файла).
// Коррекция объектива ~0.6 с, импульсы ~1 с, шумодав ~1 с, ореолы ~0.5 с,
// Capture-резкость ~0.6 с,
// маска ~0.35 с на превью.
// Вход job.src только читается - это буфер State. Шаг,
// который ничего не меняет, копии не делает: без коррекции объектива
// raw_linear - тот же массив, что dev_linear, без шумодава и
// Capture-резкости linear - тот же, что raw_linear (-36 МБ на каждый
// совпадающий слой превью 24 Мп). Править буферы State на месте нельзя.
//
// Владение (bufown.v): задание держит src - здесь он
// отпускается; у итога на каждое поле своя ссылка (совпадающие слои -
// share), промежуточное, не попавшее в итог, отпускается.
fn prep_compute(job PrepJob) PrepResult {
	mut jsrc := unsafe { job.src }
	defer {
		drop(mut jsrc)
	}
	// Сырьё после объектива (точка возврата для следующего пересчёта
	// шумодава): коррекция - на своей копии
	mut lensed := share(job.src)
	if job.redo_lens && (!isnil(job.corr) || job.man.active()) {
		drop(mut lensed)
		lensed = own_clone(job.src)
		rb := unsafe { &u16(lensed.data) }
		lens_full(rb, job.w, job.h, job.corr, job.focal, job.aperture, job.vign, job.zoom,
			job.man)
	}
	// Шумодав - на своей копии сырья
	use_nr := job.nr[0] > 0 || job.nr[1] > 0 || job.nr[2] > 0 || job.nr[3] > 0
	mut cur := if use_nr { own_clone(lensed) } else { share(lensed) }
	buf := unsafe { &u16(cur.data) }
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
	// Capture-резкость - после шумодава (не усиливать шум), в свой буфер
	mut lin := []u16{}
	if job.dc.dc_amount > 0 {
		lin = own_new[u16](cur.len)
		pipeline.deconvolve_into(buf, job.w, job.h, job.dc, preview_scale, mut lin)
	} else {
		lin = share(cur)
	}
	// Маска окрестности («Тени/Света», Clarity) зависит только от сырья
	// (после коррекции объектива и шумодава!), поэтому считается здесь, а
	// не на каждый ползунок.
	mut mask := own_new[u16](job.w * job.h * pipeline.mask_ch)
	pipeline.luma_masks_into(buf, job.w, job.h, mut mask)
	drop(mut cur)
	if !job.redo_lens {
		drop(mut lensed)
	}
	return PrepResult{
		gen:        job.gen
		raw_linear: lensed
		linear:     lin
		mask:       mask
		nr:         job.nr
		dc:         job.dc
	}
}

// take_prep принимает результат подготовки в State (главный поток).
// Буферы передаются без копирования: воркер их больше не трогает.
fn take_prep(mut st State, res PrepResult) {
	// Ссылки итога переходят в State, прежние буферы отпускаются
	if res.raw_linear.len > 0 {
		drop(mut st.raw_linear)
		st.raw_linear = res.raw_linear
		st.raw_pending = false
	}
	drop(mut st.linear)
	drop(mut st.mask)
	st.linear = res.linear
	st.mask = res.mask
	st.lin_gen++
	st.haze = pipeline.HazeMap{}
	st.nr_applied = res.nr
	st.dc_applied = dc_key(res.dc)
}

// prep_stale - подготовленное сырьё не соответствует настройкам шумодава
// (и Capture-резкости)
fn prep_stale(st &State) bool {
	return st.nr_applied != st.edit.nr || st.dc_applied != dc_key(st.edit.params.sharp)
}

// drop_prep - итог подготовки не нужен: отпустить его буферы
fn drop_prep(res PrepResult) {
	mut r := res
	drop(mut r.raw_linear)
	drop(mut r.linear)
	drop(mut r.mask)
}

// prep_worker выполняется в spawn; результат уходит в главный поток
// через app.post() (единственный потокобезопасный вход vgui).
fn prep_worker(job PrepJob, mut app vgui.App, on_done fn (PrepResult)) {
	res := prep_compute(job)
	post_result(mut app, on_done, res)
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
	format    imgio.Format
	quality   int  // JPEG
	size      ExportSize // размер на выход
	load      LoadLevel  // нагрузка: приоритет потока экспорта
	settings  Settings   // EXIF и копирайт (write_image)
	ctl       &ExportCtl = unsafe { nil } // отмена и прогресс
	on_stage  fn (&ExportCtl, ExportStage, int, int) = unsafe { nil } // прогресс - в главный поток
}

// save_worker выполняется в spawn: полная проявка и запись файла без единого
// обращения к vgui или общему состоянию - кроме app.post() (потокобезопасен
// по контракту vgui). Результат - уведомление через report.
fn save_worker(job SaveJob, mut app vgui.App, on_done fn (SaveOutcome, string)) {
	sw := time.new_stopwatch()
	apply_load(job.load)
	mut progress := ExportPoster{
		app:         app
		ctl:         job.ctl
		on_progress: job.on_stage
	}
	mut img := develop_full(job.src, job.edit, job.db,
		progress: StageProgress(progress)
		size:     job.size
		bits16:   job.settings.export_bits16(job.format)
		demosaic: job.settings.demosaic_qual()
	) or {
		if err is ExportCancelled {
			report(mut app, on_done, .cancelled, i18n.tr('Экспорт отменён'))
		} else {
			report(mut app, on_done, .failed, i18n.trf('Ошибка проявки: {0}', '${err.msg()}'))
		}
		return
	}
	defer {
		img.free()
	}
	if !progress.stage(.write, 0, 0) {
		report(mut app, on_done, .cancelled, i18n.tr('Экспорт отменён'))
		return
	}
	write_image(job.dst, job.format, img, job.quality, &job.settings) or {
		report(mut app, on_done, .failed, i18n.trf('Не удалось сохранить: {0}', '${err}'))
		return
	}
	size_mb := f64(os.file_size(job.dst)) / 1024 / 1024
	sec := f64(sw.elapsed().milliseconds()) / 1000.0
	q := if job.format == .jpeg {
		i18n.trf(', качество {0}', '${job.quality}')
	} else if img.bits16 {
		i18n.tr(', 16 бит')
	} else {
		''
	}
	report(mut app, on_done, .saved, i18n.trf('Сохранено: {0} ({1}, {2}x{3}, {4} МБ{5}, {6} с)', '${job.dst}', '${job.format.name()}', '${img.width}', '${img.height}', '${size_mb:.1f}', '${q}', '${sec:.1f}'))
}

// Подпись профиля объектива, пока снимок не выбран
const lens_no_info = 'Информации нет'

// show_lens - подпись и доступность чекбокса «Коррекция объектива» по
// найденному профилю (после загрузки кадра, load_done)
fn show_lens(st &State, mut lens_cb vgui.CheckBox, mut lens_lb vgui.Label) {
	if isnil(st.corr) {
		lens_lb.text = i18n.tr('профиль объектива не найден')
		lens_cb.enabled = false
	} else {
		lens_lb.text = st.corr.lens_name
		lens_cb.enabled = true
	}
}

// icon_button - плоская кнопка со значком Lucide (встроен в vgui) и
// всплывающей подсказкой Button.tooltip (её рисует сама кнопка).
// update_title - заголовок окна: «IMG_0817.CR3 - vraw», без кадра - «vraw»
// (длинное тире в заголовках vgui нельзя)
fn update_title(mut st State) {
	if isnil(st.win) {
		return
	}
	mut w := st.win
	w.set_title(if st.raw_path == '' { 'vraw' } else { '${os.file_name(st.raw_path)} - vraw' })
}

fn icon_button(icon string, tip string) &vgui.Button {
	mut b := vgui.button('')
	b.icon_name = icon
	b.icon_size = 15
	b.style = .flat
	b.tooltip = tip
	return b
}

// reset_button - сброс одного параметра: значок «вернуть назад»
fn reset_button(tip string) &vgui.Button {
	return icon_button('rotate-ccw', tip)
}

// slider_row собирает стандартный ряд панели: подпись, ползунок, значение
// справа от ползунка, кнопка ввода точного значения (numedit.v, conv -
// перевод числа в поле в значение ползунка) и кнопка сброса этого
// параметра. set_value сам вызывает on_change ползунка, поэтому кнопкам
// достаточно выставить значение. Ширины колонок подписи/значения общие на
// всю панель - считаются в main через column_width, чтобы колонки рядов
// были выровнены.
fn slider_row(mut st State, lb &vgui.Label, mut sl vgui.Slider, vl &vgui.Label, def f32, lw f32, vw f32, conv NumConv) &vgui.HBox {
	mut b := reset_button(i18n.tr('Сбросить'))
	b.on_click = fn [mut sl, def] () {
		sl.set_value(def)
	}
	cell, eb := value_cell(mut st, mut sl, vl, conv)
	mut row := vgui.create_hbox_fill()
	row.set_spacing(6)
	row.add(lb, min: lw)
	row.add(sl, flex: 1)
	row.add(cell, min: vw)
	row.add(eb)
	row.add(b)
	st.slider_rows[voidptr(sl)] = row
	return row
}

// set_slider_enabled - ползунок панели активен или нет. Ряд slider_row
// гасится целиком (подпись, значение, сброс): отключённый контейнер vgui
// гасит всё поддерево.
fn set_slider_enabled(st &State, mut sl vgui.Slider, on bool) {
	if row := st.slider_rows[voidptr(sl)] {
		set_enabled(row, on)
	} else {
		sl.enabled = on
	}
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
	show   fn (f32) string         = unsafe { nil } // своя подпись значения
	get    fn (&EditState) f32     = unsafe { nil } // значение в снимке (откат)
	set    fn (mut e EditState, v f32) = unsafe { nil } // запись значения в st.edit
	fx     fn ()                   = unsafe { nil } // пересчёт после завершённой правки
	// Показ с Alt при перетаскивании (ползунки резкости): вместо снимка -
	// маска краёв или добавка резкости, пока зажат Alt; off - нет
	drag_view pipeline.SharpView
	// live: пересчёт и по ходу перетаскивания (угол поворота - видно
	// горизонт), запись в истории - по отпусканию
	live bool
	// Ввод числом (numedit.v): значение ползунка -> число в поле и
	// обратно; nil - число и есть значение
	to_num   fn (f32) f32 = unsafe { nil }
	from_num fn (f32) f32 = unsafe { nil }
}

// EditSlider - собранный ползунок: подпись, ползунок, значение
struct EditSlider {
mut:
	lb  &vgui.Label  = unsafe { nil }
	sl  &vgui.Slider = unsafe { nil }
	vl   &vgui.Label  = unsafe { nil }
	def  f32
	conv NumConv // ввод точного значения (numedit.v)
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
// (по отпусканию): при перетаскивании on_change пишет только
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
	// Колесо мыши - прокрутке панели: курсор, проезжая по ползунку, не
	// должен менять настройку кадра
	sl.wheel = false
	key := if cfg.hname.len > 0 { cfg.hname } else { cfg.label }
	sl.on_change = fn [mut st, mut vl, mut sl, cfg, key] (v f32) {
		cfg.set(mut st.edit, v)
		vl.text = slider_text(cfg, v)
		if sl.dragging && !st.suppress && cfg.drag_view != .off {
			// Alt зажат - показ работы резкости сразу, по ходу драга
			alt := vgui.key_mods() & vgui.sdl_kmod_alt != 0
			if alt || st.sharp_drag != .off {
				st.sharp_drag = if alt { cfg.drag_view } else { pipeline.SharpView.off }
				defer_fx(mut st, cfg.fx)
			}
		}
		if sl.dragging && !st.suppress && cfg.live {
			defer_fx(mut st, cfg.fx)
		}
		// Тянут зону гистограммы (histogram.v): живой пересчёт, история -
		// по отпусканию (on_release)
		if st.hist_drag && !st.suppress {
			defer_fx(mut st, cfg.fx)
			return
		}
		if st.suppress || sl.dragging {
			return
		}
		cfg.fx()
		record(mut st, key, '${key} ${slider_hist_text(cfg, v)}', true)
	}
	sl.on_release = fn [mut st, cfg, key] (v f32) {
		st.sharp_drag = .off
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
		vl:   vl
		def:  cfg.def
		conv: NumConv{
			digits: cfg.digits
			to:     cfg.to_num
			from:   cfg.from_num
		}
	}
}

// edit_row - стандартный ряд панели (slider_row) для ползунка edit_slider
fn edit_row(mut st State, mut s EditSlider, lw f32, vw f32) &vgui.HBox {
	return slider_row(mut st, s.lb, mut s.sl, s.vl, s.def, lw, vw, s.conv)
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
	// подсказка открытия с текущими сочетаниями (hotkeys.v, hk_texts)
	open_hint string = i18n.tr('Меню «Файл»: Ctrl+O - файл, Ctrl+Shift+O - папка')
}

fn make_placeholder(th vgui.Theme) &Placeholder {
	mut bg := vgui.canvas(960, 720)
	bg.stretch = true
	bg.passive = true
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
	col.add(ic, align: .center) // фиксированный поперёк - иначе к левому краю
	col.add(title)
	col.add(hint)
	col.add(fmts)
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
		title.text = i18n.tr('Выберите кадр')
		hint.text = i18n.tr('Двойной щелчок по миниатюре в ленте')
	} else {
		title.text = i18n.tr('Откройте RAW-файл или папку')
		hint.text = ph.open_hint
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
	// Поле вокруг снимка - выбранный фон; вокруг заглушки и оверлея
	// загрузки - фон темы (край их градиента)
	shown := !isnil(st.holder) && !st.holder.stack.visible && !load_shown(st)
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

// SectionRow - ряд секции аккордеона (высота - его собственная, measure)
struct SectionRow {
	w &vgui.Widget
}

// icon_slot - пустое место шириной кнопки-значка (icon_button): ряды без
// кнопки сброса держат общую с соседями колонку
const icon_slot_w = f32(15) + 2 * vgui.measure_pad_y

fn icon_slot() &vgui.Label {
	return vgui.label('')
}

// section собирает содержимое секции аккордеона: VBox из рядов
// естественной высоты с отступами (fit_content аккордеона берёт её
// из measure).
fn section(rows []SectionRow) &vgui.VBox {
	mut v := vgui.create_vbox_fill()
	v.set_spacing(6)
	v.set_padding(8)
	for r in rows {
		v.add(r.w)
	}
	return v
}

fn main() {
	// Настройки прошлого запуска: тема, фон вокруг снимка, лента
	settings := load_settings()
	// Язык - до всего, что пишет текст (окно, State с подписями, потоки)
	i18n.set(if settings.lang != '' { settings.lang } else { system_lang() })
	// Каталог перевода у vraw и vgui общий (vgui.i18n): здесь vgui
	// добавляет в него свои строки (диалоги, кнопки)
	vgui.set_locale(i18n.current())
	// Тема приложения (меняется в меню «Вид - Тема»); из неё же -
	// палитра vraw и цвета заглушки
	theme := theme_by_key(settings.theme)
	mut app := vgui.create_app(theme: theme)!
	// Тема приложения: окно без своей темы получит её в add_window
	// Размер по умолчанию - золотое сечение: 1440 / 890 ~ 1.618
	mut win := vgui.create_window(title: 'vraw', width: 1440, height: 890)!
	// Масштаб интерфейса прошлого запуска (uiscale.v): окно на экране
	// того же размера, внутри - крупнее или мельче
	ui_k := f32(ui_scale_pct(settings.ui_scale)) / 100
	set_window_scale(mut win, ui_k)

	// Колонки панели ползунков: не константы «с запасом», а фактическая
	// ширина самых длинных строк. Первый список - все подписи рядов,
	// второй - самые длинные варианты значений (крайние числа
	// ползунков). Новая подпись длиннее нынешних просто
	// расширит колонку - наездов на ползунок не будет.
	lbl_w := column_width(mut win, [i18n.tr('Экспозиция'), i18n.tr('Тени'),
		i18n.tr('Контраст'), i18n.tr('Сочность'), i18n.tr('Насыщенность'), i18n.tr('Света'), i18n.tr('Чёрные'), i18n.tr('Средние'), i18n.tr('Белые'),
		i18n.tr('Импульсный'), i18n.tr('Яркостный'), i18n.tr('Цветовой'), i18n.tr('Ореолы'), i18n.tr('Оранжевый'), i18n.tr('Фиолетовый'), i18n.tr('Пурпурный'), i18n.tr('Сила'),
		i18n.tr('Режим'), i18n.tr('Температура'), i18n.tr('Оттенок'), i18n.trc('ББ', 'Оттенок'), i18n.tr('Глубина'), i18n.tr('Величина'), i18n.tr('Радиус'), i18n.tr('Порог'), i18n.tr('Маска краёв'),
		i18n.tr('Смешение'), i18n.tr('Баланс'), i18n.tr('Дисторсия'), i18n.tr('ХА: красный'), i18n.tr('ХА: синий'), i18n.tr('Виньетка')], 8)
	val_w := column_width(mut win, ['-4.00', '100', '12000 K', '-150', '3.00 px', '360°'], 8)

	mut st := &State{}
	st.settings = settings
	st.dt = &DetailCtl{}
	// Приёмники повторяющихся app.post и воркера 1:1 - один раз за запуск:
	// замыкание, созданное по ходу работы, может навсегда удержать чужой
	// буфер (post.v)
	st.fx_post = fn [mut st] () {
		run_deferred_fx(mut st)
	}
	st.dt_check = fn [mut st] () {
		detail_check(mut st)
	}
	st.dt_done = fn [mut st] (res DetailRes) {
		detail_done(mut st, res)
	}
	st.pal = make_palette(theme)
	// База lensfun - один раз за запуск: дальше поиск профиля - доли мс
	st.lens_db = load_lens_db()
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
	hist.fill(st.pal.hist[0])
	st.hist_cv = hist
	// Треугольники в верхних углах (clipping.v): левый - провалы, правый -
	// пересветы; щелчок включает/выключает показ своего края. Зоны
	// эквалайзера - наведение и перетаскивание (histogram.v)
	hist.take_keys = false
	hist.on_input = fn [mut st] (ev &vgui.CanvasInputEvent) {
		hist_input(mut st, ev)
	}
	hist.tooltip = if st.settings.hist_raw { hist_tip_raw() } else { hist_tip_default() }

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
			drop_prep(res)
			return
		}
		wait_prep(mut st) // воркер уже отдал результат - join мгновенный
		if res.gen == st.file_gen {
			take_prep(mut st, res)
			apply_pipeline(mut st, mut cv, mut hist)
		} else {
			drop_prep(res) // подготовка прежнего кадра
		}
		if st.dev_linear.len > 0 && (st.lens_dirty || prep_stale(st)) {
			// Пока воркер считал, настройки снова поменялись (или это
			// был старый кадр)
			request_prep(mut st, mut app, false)
		}
	}
	st.open_settings = fn [mut st, mut app, win] () {
		show_settings(mut st, mut app, win)
	}

	// ── Ползунки и чекбоксы правки ──
	// Все настройки кадра живут в st.edit (снимок для истории). Ползунки
	// собирает edit_slider; fx - пересчёт по виду настройки: тон -
	// apply_pipeline (~60 мс), подготовка сырья - фоновый request_prep.
	tone_fx := fn [mut st, mut cv, mut hist] () {
		apply_pipeline(mut st, mut cv, mut hist)
	}
	st.tone_fx = tone_fx
	st.cv = cv
	// Пипетка баланса белого (wb_ui.v): щелчок левой кнопкой по снимку.
	// Панорама - средней и правой кнопками, левая холсту не нужна.
	// Холсту нужна только мышь: клавиши в фокусе не забирает - иначе после
	// щелчка по снимку не работали бы меню (J) и ←/→ ленты
	cv.take_keys = false
	// Миникарта при увеличении (vgui Canvas.navigator), «Вид - Миникарта»
	cv.navigator = !st.settings.no_navigator
	// Рамка кадрирования, ручки и сетка - поверх снимка, без пересчёта
	cv.on_overlay = fn [mut st] (mut ctx vgui.RenderContext) {
		crop_overlay(mut st, mut ctx)
		mask_overlay(mut st, mut ctx) // ручки градиентного фильтра
		spot_overlay(mut st, mut ctx) // круги пятен (spots_ui.v)
		ba_overlay(mut st, mut ctx) // шторка до/после
		pair_overlay(st, mut ctx) // подпись открытого при сравнении кадров
		jpeg_overlay(st, mut ctx) // подпись «JPEG камеры»
		info_overlay(st, mut ctx) // сведения о съёмке (shotinfo.v)
		sbs_sync(mut st, false) // бок о бок: зум и прокрутка - холсту «до»
		detail_watch(mut st) // настоящий 1:1: изменился вид - фрагмент
	}
	cv.on_input = fn [mut st] (ev &vgui.CanvasInputEvent) {
		// Режим кадрирования (crop.v): рамка, ручки, линия горизонта
		if crop_input(mut st, ev) {
			return
		}
		// Режим удаления пятен (spots_ui.v): щелчок - пятно, круги тянутся
		if spot_input(mut st, ev) {
			return
		}
		// Ручки выделенного градиентного фильтра (masks.v)
		if mask_input(mut st, ev) {
			return
		}
		// Наведение, не забранное инструментом, - обычная стрелка (курсор
		// снятого с выделения фильтра не остаётся); шторка ставит свой ниже
		if ev.kind == .hover {
			vgui.set_cursor(vgui.sdl_system_cursor_default)
		}
		if st.wb_pick && ev.kind == .pointer_down && ev.button == 1 && ev.in_image {
			wb_pick_at(mut st, ev.x, ev.y)
			return
		}
		// Линия шторки до/после, иначе щелчок - 100% / вписать (compare.v)
		if ba_input(mut st, ev) {
			return
		}
		mut c := st.cv
		zoom_click(mut st, mut c, ev)
	}
	// Бок о бок (compare.v): холст «до» слева - тот же зум и прокрутка,
	// что у основного (sbs_sync), щелчок - 100% / вписать
	mut cv_b := vgui.canvas(4, 3)
	cv_b.fill(viewer_bg)
	cv_b.take_keys = false
	cv_b.on_overlay = fn [mut st] (mut ctx vgui.RenderContext) {
		if st.pair_on {
			pair_overlay_b(st, mut ctx)
		} else {
			ba_overlay_b(st, mut ctx)
		}
		sbs_sync(mut st, true)
	}
	cv_b.on_input = fn [mut st, mut cv_b] (ev &vgui.CanvasInputEvent) {
		// Сравнение кадров (pair.v): холст левого кадра
		if pair_input(mut st, ev) {
			return
		}
		zoom_click(mut st, mut cv_b, ev)
	}
	st.cv_b = cv_b
	st.pair_done = fn [mut st] (res PairResult) {
		pair_take(mut st, res)
	}
	st.ba_prep_done = fn [mut st] (res PrepResult) {
		ba_prep_take(mut st, res)
	}
	// Шумодав и ореолы - подготовка сырья (~1 с на превью, в фоне): LibRaw
	// и коррекция объектива не перезапускаются - сырьё в raw_linear.
	// Отпускание на уже применённом значении ничего не пересчитывает.
	prep_fx := fn [mut st, mut app] () {
		if prep_stale(st) {
			request_prep(mut st, mut app, false)
		}
	}
	// Коррекция объектива (lensfun): применяется к линейному сырью до
	// пайплайна. Переключение пересчитывает сырьё из dev_linear (без
	// LibRaw) в фоне, ~0.6 с + шумодав - окно не замирает.
	// Подпись под чекбоксом - найденный профиль.
	mut lens_cb := vgui.checkbox(i18n.tr('Коррекция объектива'))
	lens_cb.checked = true
	lens_cb.on_change = fn [mut st, mut app] (v bool) {
		st.edit.lens_corr = v
		request_prep(mut st, mut app, true)
		record(mut st, 'lens', i18n.trf('Коррекция объектива: {0}', '${on_off(v)}'), false)
	}
	st.lens_cb = lens_cb
	mut lens_lb := vgui.label(i18n.tr(lens_no_info))
	st.secondary_labels << lens_lb

	// «Как JPEG камеры»: тональная кривая и множитель насыщенности,
	// подогнанные под встроенный JPEG (CamLook). Без них нейтральная
	// проявка - чистая гамма 2.2, темнее и блёклее камерного JPEG. Кривая
	// сидит в flut, насыщенность - множитель, поэтому переключение -
	// мгновенное (обычный apply, перепроявка не нужна). Ползунок
	// «Насыщенность» - относительно камерной (1.00 - как у камеры).
	// Профиль проявки (profile.v): нейтральный, как JPEG камеры, стили
	prof_row := profile_row(mut st, lbl_w)

	// Шумодав и ореолы: в «Сброс» не входят (подготовка сырья, не тон)
	mut imp := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Импульсный')
		hname:  i18n.tr('Импульсный шум')
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
		label:  i18n.tr('Яркостный')
		hname:  i18n.tr('Шумодав: яркостный')
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
		label:  i18n.tr('Цветовой')
		hname:  i18n.tr('Шумодав: цветовой')
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
		label:  i18n.tr('Ореолы')
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
		label: i18n.tr('Экспозиция')
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
	mut sh := edit_slider(mut st, SliderCfg{
		label: i18n.tr('Тени')
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
		label: i18n.tr('Контраст')
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
	// Чёткость (Clarity, pipeline/clarity.v) - локальный контраст средних
	// деталей; минус смягчает
	mut clr := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Чёткость')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.params.clarity
		}
		set:    fn (mut e EditState, v f32) {
			e.params.clarity = v
		}
		fx:     tone_fx
	})
	// Текстура (pipeline/texture.v) - средняя детализация: листва, кора,
	// ткань; минус смягчает (кожа)
	mut txr := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Текстура')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.params.texture
		}
		set:    fn (mut e EditState, v f32) {
			e.params.texture = v
		}
		fx:     tone_fx
	})
	// Сочность - бережная насыщенность (pipeline.vibrance_pixel): блёклые
	// цвета сильнее насыщенных, тона кожи защищены
	mut vib := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Сочность')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.params.vibrance
		}
		set:    fn (mut e EditState, v f32) {
			e.params.vibrance = v
		}
		fx:     tone_fx
	})
	mut sat := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Насыщенность')
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
		label:  i18n.tr('Света')
		hname:  i18n.tr('Тени/Света: света')
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
		label:  i18n.tr('Тени')
		hname:  i18n.tr('Тени/Света: тени')
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
	eq_names := [i18n.tr('Чёрные'), i18n.tr('Тени'), i18n.tr('Средние'), i18n.tr('Света'), i18n.tr('Белые')]
	mut eq_rows := []&vgui.HBox{}
	for i in 0 .. 5 {
		mut s := edit_slider(mut st, SliderCfg{
			label: eq_names[i]
			hname: i18n.trf('Эквалайзер: {0}', '${eq_names[i]}')
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
		// зоны гистограммы ведут эти ползунки (histogram.v)
		st.hv.eq_sl << s.sl
		st.hv.eq_txt << eq_names[i]
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
		record(mut st, 'curve${st.curve_ch}', i18n.trf('Кривая {0}', '${curve_names[st.curve_ch]}'), false)
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
		ch_row.add(b, flex: 1)
	}
	mut curve_reset := reset_button(i18n.tr('Сбросить кривую канала'))
	curve_reset.on_click = fn [mut st, mut cv, mut hist] () {
		st.edit.curve_pts[st.curve_ch] = identity_curve()
		curves_to_params(mut st)
		sync_curve_editor(mut st)
		apply_pipeline(mut st, mut cv, mut hist)
		record(mut st, 'curve${st.curve_ch}', i18n.trf('Кривая {0}: сброс', '${curve_names[st.curve_ch]}'),
			false)
	}
	ch_row.add(curve_reset)
	mut curve_hint := vgui.label(i18n.tr('Щелчок - точка, правая кнопка - удалить, двойной - сброс'))
	st.hint_labels << curve_hint
	curve_hint.font_size = 12
	sync_curve_editor(mut st)

	// ── HSL: вкладки «Оттенок / Насыщенность / Яркость», 8 диапазонов ──
	mut hsl_tabs := vgui.tab_box()
	for m in 0 .. 3 {
		mut rows := []SectionRow{}
		for i in 0 .. 8 {
			mut s := edit_slider(mut st, SliderCfg{
				label:  i18n.tr(hsl_names[i])
				hname:  'HSL ${i18n.tr(hsl_modes[m]).to_lower()}: ${i18n.tr(hsl_names[i])}'
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
			rows << SectionRow{edit_row(mut st, mut s, lbl_w, val_w)}
		}
		hsl_tabs.add_tab(i18n.tr(hsl_modes[m]), section(rows))
	}

	// ── Резкость: unsharp mask по люме (pipeline/sharpen.v) - последний
	// шаг пайплайна, тональный пересчёт по отпусканию. Радиус - в
	// пикселях полного кадра (на превью половинного размера - вдвое меньше)
	mut sh_amount := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Величина')
		hname:  i18n.tr('Резкость: величина')
		max:    150
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sharp.amount
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.amount = v
		}
		fx:     tone_fx
		drag_view: .detail
	})
	mut sh_radius := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Радиус')
		hname:  i18n.tr('Резкость: радиус')
		min:    0.5
		max:    3
		def:    1
		signed: false
		show:   fn (v f32) string {
			return '${v:.2f} px'
		}
		get:    fn (e &EditState) f32 {
			return e.params.sharp.radius
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.radius = v
		}
		fx:     tone_fx
		drag_view: .detail
	})
	mut sh_detail := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Порог')
		hname:  i18n.tr('Резкость: порог')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sharp.detail
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.detail = v
		}
		fx:     tone_fx
		drag_view: .detail
	})
	mut sh_mask := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Маска краёв')
		hname:  i18n.tr('Резкость: маска краёв')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sharp.masking
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.masking = v
		}
		fx:     tone_fx
		drag_view: .mask
	})
	// По каналам RGB - правка кадра (история, сайдкар)
	mut sh_rgb_cb := vgui.checkbox(i18n.tr('По каналам RGB'))
	sh_rgb_cb.on_change = fn [mut st, tone_fx] (v bool) {
		st.edit.params.sharp.rgb = v
		tone_fx()
		record(mut st, 'sharp_rgb', i18n.trf('Резкость по каналам RGB: {0}', '${on_off(v)}'), false)
	}
	st.sharp_rgb_cb = sh_rgb_cb
	// Маска краёв вместо снимка - вид, не правка (в историю не пишется)
	mut sh_show_cb := vgui.checkbox(i18n.tr('Показать маску краёв'))
	sh_show_cb.on_change = fn [mut st, tone_fx] (v bool) {
		st.sharp_show = v
		tone_fx()
	}
	mut sharp_hint := vgui.label(i18n.tr('Оценивать в 100%. Alt при перетаскивании - маска или детали'))
	st.hint_labels << sharp_hint
	sharp_hint.font_size = 12
	// ── Capture-резкость: деконволюция Ричардсона-Люси по линейному сырью
	// (pipeline/deconv.v) - подготовка сырья, как шумодав: пересчёт в фоне
	// по отпусканию (prep_fx)
	mut dc_amount := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Сила')
		hname:  i18n.tr('Capture-резкость: сила')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sharp.dc_amount
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.dc_amount = v
		}
		fx:     prep_fx
	})
	mut dc_radius := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Радиус')
		hname:  i18n.tr('Capture-резкость: радиус')
		min:    0.4
		max:    1.5
		def:    0.75
		signed: false
		show:   fn (v f32) string {
			return '${v:.2f} px'
		}
		get:    fn (e &EditState) f32 {
			return e.params.sharp.dc_radius
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.dc_radius = v
		}
		fx:     prep_fx
	})
	mut dc_contrast := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Порог')
		hname:  i18n.tr('Capture-резкость: порог')
		max:    100
		def:    10
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sharp.dc_contrast
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.dc_contrast = v
		}
		fx:     prep_fx
	})
	mut usm_caption := vgui.label(i18n.tr('Нерезкое маскирование'))
	usm_caption.font_style = .bold
	mut dc_caption := vgui.label(i18n.tr('Capture-резкость (деконволюция)'))
	dc_caption.font_style = .bold
	mut dc_hint := vgui.label(i18n.tr('Возвращает резкость оптики; порог бережёт ровное и шум'))
	st.hint_labels << dc_hint
	dc_hint.font_size = 12
	// ── Удаление дымки (как в RawTherapee): тёмный канал, pipeline/dehaze.v.
	// Карта дымки - по сырью кадра, сила и глубина - живые (apply)
	mut hz_str := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Сила')
		hname:  i18n.tr('Дымка: сила')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.params.haze
		}
		set:    fn (mut e EditState, v f32) {
			e.params.haze = v
		}
		fx:     tone_fx
	})
	mut hz_depth := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Глубина')
		hname:  i18n.tr('Дымка: глубина')
		max:    100
		def:    25
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.haze_depth
		}
		set:    fn (mut e EditState, v f32) {
			e.params.haze_depth = v
		}
		fx:     tone_fx
	})
	// Карта глубины вместо снимка - вид, не правка (в историю не пишется)
	mut hz_map_cb := vgui.checkbox(i18n.tr('Показать карту глубины'))
	hz_map_cb.on_change = fn [mut st, tone_fx] (v bool) {
		st.haze_show = v
		tone_fx()
	}
	mut hz_hint := vgui.label(i18n.tr('Минус - добавить дымку; глубина - насколько близко к камере'))
	st.hint_labels << hz_hint
	hz_hint.font_size = 12

	// ── Эффекты (pipeline/effects.v): виньетка после кадрирования и
	// плёночное зерно - по тону в конце проявки, живые (apply)
	mut vig_caption := vgui.label(i18n.tr('Виньетка'))
	vig_caption.font_style = .bold
	mut grain_caption := vgui.label(i18n.tr('Зерно'))
	grain_caption.font_style = .bold
	mut vig_amt := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Величина')
		hname:  i18n.tr('Виньетка')
		min:    -100
		max:    100
		def:    0
		digits: 0
		signed: true
		get:    fn (e &EditState) f32 {
			return e.params.fx.vig_amount
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.vig_amount = v
		}
		fx:     tone_fx
	})
	mut vig_mid := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Средняя точка')
		hname:  i18n.tr('Виньетка: средняя точка')
		min:    0
		max:    100
		def:    50
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.fx.vig_mid
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.vig_mid = v
		}
		fx:     tone_fx
	})
	mut vig_rnd := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Округлость')
		hname:  i18n.tr('Виньетка: округлость')
		min:    -100
		max:    100
		def:    0
		digits: 0
		signed: true
		get:    fn (e &EditState) f32 {
			return e.params.fx.vig_round
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.vig_round = v
		}
		fx:     tone_fx
	})
	mut vig_fth := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Растушёвка')
		hname:  i18n.tr('Виньетка: растушёвка')
		min:    0
		max:    100
		def:    50
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.fx.vig_feather
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.vig_feather = v
		}
		fx:     tone_fx
	})
	mut grn_amt := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Величина')
		hname:  i18n.tr('Зерно')
		min:    0
		max:    100
		def:    0
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.fx.grain
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.grain = v
		}
		fx:     tone_fx
	})
	mut grn_size := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Размер')
		hname:  i18n.tr('Зерно: размер')
		min:    0
		max:    100
		def:    25
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.fx.grain_size
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.grain_size = v
		}
		fx:     tone_fx
	})
	mut grn_rough := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Грубость')
		hname:  i18n.tr('Зерно: грубость')
		min:    0
		max:    100
		def:    50
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.fx.grain_rough
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.grain_rough = v
		}
		fx:     tone_fx
	})
	mut fx_hint := vgui.label(i18n.tr('Минус - тёмные края, плюс - светлые; зерно точно видно на 1:1'))
	st.hint_labels << fx_hint
	fx_hint.font_size = 12

	// Баланс белого: режим, пипетка, температура, оттенок (wb_ui.v)
	wb_rows := build_wb_section(mut st, lbl_w, val_w)
	// Кадрирование и поворот (crop.v)
	crop_rows := build_crop_section(mut st, lbl_w, val_w)
	// Градиентные фильтры (masks.v)
	mask_rows := build_mask_section(mut st, lbl_w, val_w)
	// Удаление пятен (spots_ui.v)
	spot_rows := build_spot_section(mut st, lbl_w, val_w)

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
	hist_lb.on_dbl_click = fn [mut st, mut cv, mut hist, mut app] (idx int, text string) {
		goto_history(mut st, idx, mut cv, mut hist, mut app)
	}
	st.hist_lb = hist_lb
	// «До» для сравнения (compare.v) - выделенная запись: подпись, кнопка
	// и сброс к первой записи
	mut ba_lb := vgui.label(i18n.tr('До: первая запись'))
	st.secondary_labels << ba_lb
	st.ba_lb = ba_lb
	mut b_ba := icon_button('git-compare', i18n.tr('Выделенная запись - «до» для сравнения'))
	st.hk_texts << fn [st, mut b_ba] () {
		keys := [hk_key(st, 'view.split'), hk_key(st, 'view.sbs')]
		mut t := i18n.tr('Выделенная запись - «до» для сравнения')
		if keys[0].len > 0 || keys[1].len > 0 {
			mut parts := []string{}
			if keys[0].len > 0 {
				parts << i18n.trf('шторка {0}', '${keys[0]}')
			}
			if keys[1].len > 0 {
				parts << i18n.trf('бок о бок {0}', '${keys[1]}')
			}
			t += ' (${parts.join(', ')})'
		}
		b_ba.tooltip = t
	}
	b_ba.on_click = fn [mut st] () {
		if isnil(st.hist_lb) {
			return
		}
		set_ba_ref(mut st, st.hist_lb.selected)
	}
	mut b_ba0 := reset_button(i18n.tr('«До» - первая запись'))
	b_ba0.on_click = fn [mut st] () {
		set_ba_ref(mut st, 0)
	}
	mut ba_row := vgui.create_hbox_fill()
	ba_row.set_spacing(6)
	ba_row.add(ba_lb, flex: 1)
	ba_row.add(b_ba)
	ba_row.add(b_ba0)
	mut hist_hint := vgui.label(i18n.tr('Двойной щелчок - перейти'))
	st.hint_labels << hist_hint
	hist_hint.font_size = 12
	st.hk_texts << fn [st, mut hist_hint] () {
		keys := [hk_key(st, 'edit.undo'), hk_key(st, 'edit.redo')].filter(it.len > 0)
		hist_hint.text = i18n.tr('Двойной щелчок - перейти') + if keys.len > 0 {
			', ${keys.join(' / ')}'
		} else {
			''
		}
	}
	// Ctrl+Z / Ctrl+Shift+Z - пункты меню «Правка» (сочетания обрабатывает
	// меню); Ctrl+Y - дополнительно, горячей клавишей окна
	undo := fn [mut st, mut cv, mut hist, mut app] () {
		goto_history(mut st, st.hist_pos - 1, mut cv, mut hist, mut app)
	}
	redo := fn [mut st, mut cv, mut hist, mut app] () {
		goto_history(mut st, st.hist_pos + 1, mut cv, mut hist, mut app)
	}
	win.bind_hotkey('Ctrl+Y', redo)

	// ── Открытие файла (кнопка, аргумент, лента) ──
	// Быстрая часть - здесь, в главном потоке: файл, настройки и история
	// из сайдкара, лента. Проявка, коррекция и камерная кривая - в фоне
	// (load_worker), на месте снимка - оверлей «Обработка» (loading.v).
	open_file := fn [mut st, mut nm, mut app, mut lens_cb, mut lens_lb] (path_arg string) {
		// Полный путь: по нему лента ищет кадр и узнаёт смену папки
		path := os.real_path(path_arg)
		mut nd := raw.open(path) or {
			nm.show_error(i18n.trf('Ошибка: {0}', '${err.msg()}'))
			return
		}
		add_recent(mut st, path, false)
		// Открывают левый кадр сравнения - левым станет уходящий (pair.v)
		pair_before_open(mut st, path)
		// Предзагрузка соседа (prefetch.v): открывают его - её итог и
		// будет загрузкой, другой кадр - отменить
		adopt := prefetch_adopt(mut st, path, nd)
		if !adopt {
			prefetch_cancel(mut st)
		}
		// Сырьё уходящего кадра - в кэш (framecache.v): вернутся к нему -
		// без загрузки
		frame_store(mut st)
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
		detail_reset(mut st)
		ba_forget(mut st)
		st.loading = true
		st.raw_pending = false
		drop(mut st.dev_linear)
		drop(mut st.raw_linear)
		drop(mut st.linear)
		drop(mut st.mask)
		st.lin_gen++
		drop(mut st.glin)
		drop(mut st.gmask)
		crop_leave(mut st)
		spot_leave(mut st)
		st.mask_sel = -1
		st.mask_part = -1
		st.mask_drag = MaskDrag{}
		st.haze = pipeline.HazeMap{}
		st.look = CamLook{}
		drop(mut st.cam_view)
		st.lens_dirty = false
		lens_lb.text = i18n.tr('поиск профиля объектива...')
		lens_cb.enabled = false
		// Цвет камеры - сразу (есть после open): ББ снимков и ползунков
		set_cam_color(mut st, cam_color(nd.color()))
		set_wb_pick(mut st, false)
		// Правки и история из сайдкара (производные поля снимков - по
		// камерной кривой - заполнит on_load_done)
		st.side_path = sidecar_path(path)
		st.raw_path = path
		update_title(mut st)
		st.side_err = false
		st.load_msg = ''
		side := load_sidecar(st.side_path) or {
			st.load_msg = i18n.trf('{0}: правки не прочитаны ({1})', '${os.file_name(path)}', '${err.msg()}')
			LoadedSidecar{}
		}
		st.mark = side.mark
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
		sync_avail(mut st)
		if adopt {
			show_loading(mut st, true) // итог - из prefetch_take
			return
		}
		// Кадр в кэше - сразу итог загрузки, без воркера
		if res := frame_take(mut st, path, nd) {
			st.on_load_done(res)
			return
		}
		load_start(mut st, nd)
	}

	// Итог загрузки: хендлы и буферы - в State, затем досчитать то, что
	// изменили за время загрузки (как restore_edit), и apply
	st.on_load_done = fn [mut st, mut cv, mut hist, mut nm, mut app, mut lens_cb, mut lens_lb, mut placeholder] (res LoadResult) {
		if res.gen != st.file_gen {
			free_load(res) // отменённая загрузка прежнего кадра
			return
		}
		st.loading = false
		show_loading(mut st, false)
		if res.err.len > 0 {
			free_load(res)
			lens_lb.text = i18n.tr(lens_no_info)
			show_placeholder(mut cv, mut placeholder)
			sync_view_bg(mut st)
			sync_avail(mut st)
			nm.show_error(res.err)
			return
		}
		st.dev = res.dev
		st.meta = res.meta
		st.corr = res.corr
		show_lens(st, mut lens_cb, mut lens_lb)
		// Холст - под размер кадра после геометрии (ensure_geom в apply)
		st.pw = res.w
		st.ph = res.h
		// Ссылки итога переходят в State (bufown.v)
		drop(mut st.dev_linear)
		drop(mut st.raw_linear)
		drop(mut st.linear)
		drop(mut st.mask)
		st.dev_linear = res.dev_linear
		st.raw_linear = res.raw_linear
		st.linear = res.linear
		st.mask = res.mask
		st.lin_gen++
		st.haze = pipeline.HazeMap{}
		// Что уже сделано с linear: у загрузки - ничего (dc_key пустой
		// резкости - нули), у кадра из кэша - как было
		st.nr_applied = res.nr_applied
		st.dc_applied = res.dc_applied
		st.lens_dirty = false
		st.raw_pending = false
		st.look = res.look
		drop(mut st.cam_view)
		st.cam_view = res.cam_view
		// Производные поля снимков - по камерной кривой этого кадра
		st.edit = with_derived(st.edit, st.look, st.cam)
		st.history = st.history.map(HistEntry{
			name:  it.name
			key:   it.key
			state: with_derived(it.state, st.look, st.cam)
		})
		show_viewer(mut cv, mut placeholder)
		sync_view_bg(mut st)
		// Что поменяли за время загрузки (и шумодав из сайдкара)
		if st.edit.lens_corr != res.lens_corr || st.edit.lman != res.man {
			request_prep(mut st, mut app, true)
		} else if prep_stale(st) {
			request_prep(mut st, mut app, false)
		}
		apply_pipeline(mut st, mut cv, mut hist)
		if st.load_msg.len > 0 {
			nm.show_warning(st.load_msg)
		}
		sync_avail(mut st)
		// Сосед в ленте - заранее, в фоне (prefetch.v)
		prefetch_next(mut st)
	}
	st.pf_done = fn [mut st] (r PfResult) {
		prefetch_take(mut st, r)
	}

	// ── Лента кадров папки (browser.v) ──
	// Переход к кадру: правки текущего уже в его сайдкаре (пишется после
	// каждой правки), следующий открывается со своими. Не открылся -
	// выделение возвращается на текущий.
	goto_frame := fn [mut st, open_file] (idx int) {
		if idx < 0 || idx >= st.frames.len || idx == st.frame_idx {
			return
		}
		// Куда листают - туда и предзагрузка (prefetch.v)
		if st.frame_idx >= 0 {
			st.nav_dir = if idx > st.frame_idx { 1 } else { -1 }
		}
		open_file(st.frames[idx].path)
		sync_strip(mut st)
	}
	st.goto_frame = goto_frame
	st.thumb_done = fn [mut st] (res ThumbResult) {
		take_thumb(mut st, res)
	}
	st.app = app
	mut strip := vgui.list_box_h(strip_item_width(strip_pane_h))
	strip.pad = strip_pad
	// Колесо крутит ленту по наведению, без фокуса (vgui ListBox), и на
	// краю не уходит дальше; щелчок колеса - один кадр (fit_strip_items)
	strip.scroll_x_speed = strip.item_width
	// Одиночный щелчок (и стрелки при фокусе на ленте) только выделяет
	// миниатюру; открыть кадр - двойным щелчком или Enter
	// Строка ленты - не номер кадра: с фильтром строк меньше (rating.v)
	strip.on_dbl_click = fn [mut st, goto_frame] (row int, text string) {
		goto_frame(frame_of_row(st, row))
	}
	// Ctrl/Shift+щелчок - несколько кадров: в них вставляются настройки
	// (presets.v); число выделенных - в подписи над лентой
	strip.multi_select = true
	strip.on_select = fn [mut st] (idx int, text string) {
		strip_info_text(mut st)
		pair_select(mut st, idx) // при сравнении - этот кадр слева
		sync_avail(mut st) // отбор, вставка, сравнение - по выделенным
	}
	st.strip = strip
	mut strip_info := vgui.label('')
	st.secondary_labels << strip_info
	st.strip_info = strip_info
	// Кнопки полосы - значки; значок и подсказку свернуть/развернуть
	// ставит layout_strip
	mut strip_refresh := icon_button('refresh-cw', i18n.tr('Обновить ленту'))
	strip_refresh.on_click = fn [mut st] () {
		refresh_folder(mut st)
	}
	mut strip_toggle := icon_button('panel-bottom-close', i18n.tr('Свернуть ленту'))
	strip_toggle.on_click = fn [mut st] () {
		set_strip_open(mut st, !st.strip_open)
	}
	st.strip_toggle = strip_toggle
	// Фильтр ленты по пометкам отбора (rating.v)
	mut filter_cb := vgui.combo_box()
	filter_cb.set_items(i18n.tr_all(filter_names))
	filter_cb.set_selected(0)
	filter_cb.on_change = fn [mut st] (i int, _ string) {
		if i >= 0 && i < filter_keys.len && filter_keys[i] != st.filter {
			set_filter(mut st, filter_keys[i])
		}
	}
	st.filter_cb = filter_cb
	mut strip_bar := vgui.create_hbox_fill()
	strip_bar.set_spacing(8)
	strip_bar.add(strip_info, flex: 1)
	strip_bar.add(filter_cb)
	strip_bar.add(strip_refresh)
	strip_bar.add(strip_toggle)
	st.strip_bar = strip_bar
	// ←/→, Home/End - соседний, первый, последний кадр (если фокус не у
	// ползунка: его стрелки двигают значение)
	// Кадрирование: Enter - применить, Esc - отменить правки режима
	win.bind_hotkey('Enter', fn [mut st] () {
		if st.crop_mode {
			set_crop_mode(mut st, false)
		} else if st.spot_mode {
			set_spot_mode(mut st, false)
		}
	})
	// Удаление пятен: Delete / Backspace - выделенное пятно (в полях ввода
	// клавиши забирает поле - сюда не доходят)
	for k in ['Delete', 'Backspace'] {
		win.bind_hotkey(k, fn [mut st] () {
			if st.spot_mode && spot_valid(st) {
				delete_spot(mut st)
			}
		})
	}
	win.bind_hotkey('Escape', fn [mut st] () {
		if st.horizon {
			st.horizon = false
			st.crop_drag = CropDrag{}
			sync_crop_ui(mut st)
		} else if st.crop_mode {
			crop_cancel(mut st)
		} else if st.spot_mode {
			// Пятна: снять выделение, второй Esc - выйти из режима
			if spot_valid(st) {
				select_spot(mut st, -1)
			} else {
				set_spot_mode(mut st, false)
			}
		} else if st.mask_pick {
			set_mask_pick(mut st, false) // пипетка цвета фильтра - отмена
		} else if st.mask_sel >= 0 {
			select_mask(mut st, -1) // градиентный фильтр: снять выделение
		} else if st.fullscreen {
			set_fullscreen(mut st, false)
		}
	})
	// Соседи - среди кадров фильтра ленты
	win.bind_hotkey('Left', fn [mut st, goto_frame] () {
		goto_frame(next_shown(st, st.frame_idx, -1))
	})
	win.bind_hotkey('Right', fn [mut st, goto_frame] () {
		goto_frame(next_shown(st, st.frame_idx, 1))
	})
	win.bind_hotkey('Home', fn [mut st, goto_frame] () {
		goto_frame(frame_of_row(st, 0))
	})
	win.bind_hotkey('End', fn [mut st, goto_frame] () {
		goto_frame(frame_of_row(st, st.shown.len - 1))
	})

	// ── Файл: открыть файл или папку, экспорт (меню «Файл») ──
	open_file_dialog := fn [mut app, win, open_file] () {
		path := vgui.native_open_file_dialog(win, mut app, vgui.NativeFileDialogConfig{
			filter_names:    [i18n.tr('RAW-файлы'), i18n.tr('Все файлы')]
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
		set_pair(mut st, false)
		prefetch_cancel(mut st)
		frame_store(mut st)
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
		detail_reset(mut st)
		ba_forget(mut st)
		st.raw_pending = false
		drop(mut st.dev_linear)
		drop(mut st.raw_linear)
		drop(mut st.linear)
		drop(mut st.mask)
		st.lin_gen++
		drop(mut st.glin)
		drop(mut st.gmask)
		crop_leave(mut st)
		spot_leave(mut st)
		st.mask_sel = -1
		st.mask_part = -1
		st.mask_drag = MaskDrag{}
		st.haze = pipeline.HazeMap{}
		st.look = CamLook{}
		drop(mut st.cam_view)
		st.side_path = ''
		st.raw_path = ''
		update_title(mut st)
		st.mark = Mark{}
		set_cam_color(mut st, pipeline.CamColor{})
		set_wb_pick(mut st, false)
		set_edit(mut st, neutral_edit())
		st.history = []HistEntry{}
		st.hist_pos = 0
		refresh_history(mut st)
		st.frame_idx = -1
		lens_lb.text = i18n.tr(lens_no_info)
		lens_cb.enabled = false
		clear_histogram(mut st, mut hist)
		show_loading(mut st, false)
		show_placeholder(mut cv, mut placeholder)
		sync_view_bg(mut st)
		sync_avail(mut st)
	}

	// Открыть папку: все RAW - в ленте, в области просмотра ничего
	// (заглушка «Выберите кадр»); кадр открывается двойным щелчком
	open_folder := fn [mut st, mut app, mut nm, close_file] (dir string) {
		close_file()
		load_folder(mut st, os.real_path(dir), '', mut app)
		add_recent(mut st, os.real_path(dir), true)
		sync_strip(mut st)
		mut ph := st.holder
		set_placeholder_text(mut ph, st.frames.len > 0)
		if st.frames.len == 0 {
			nm.show_warning(i18n.tr('В папке нет RAW-файлов'))
		}
	}
	// Удалить отклонённые (rating.v): RAW и сайдкары - в корзину (вернуть
	// можно файловым менеджером), лента - заново; открытый кадр ушёл -
	// открывается ближайший оставшийся. Файлы читают воркеры (миниатюры,
	// предзагрузка, экспорт) - на Windows открытый файл не удалить, поэтому
	// во время экспорта нельзя, остальное останавливается.
	delete_rejected := fn [mut st, mut app, mut nm, close_file, open_file, win] () {
		if st.folder == '' {
			return
		}
		if !isnil(st.exp) {
			nm.show_warning(i18n.tr('Дождитесь конца экспорта'))
			return
		}
		gone := rejected_paths(st.frames)
		if gone.len == 0 {
			nm.show_info(i18n.tr('Отклонённых кадров в папке нет'))
			return
		}
		answer := vgui.message_box(win, mut app, vgui.MessageBoxConfig{
			title:          i18n.tr('Удалить отклонённые')
			message:        i18n.trf('Переместить в корзину отклонённые кадры ({0})? RAW-файлы и их правки можно будет вернуть из корзины.',
				'${gone.len}')
			kind:           .warning
			buttons:        [i18n.tr('В корзину'), i18n.tr('Отмена')]
			default_button: 1
			cancel_button:  1
		})
		if answer != 0 {
			return
		}
		cur := st.raw_path
		mut next := cur
		if cur in gone {
			next = after_trash(st.frames, st.frame_idx, gone)
			close_file()
		}
		prefetch_cancel(mut st)
		stop_thumbs(mut st)
		wait_thumbs(mut st)
		for p in gone {
			frame_drop(mut st, p)
		}
		n, errs := trash_frames(gone)
		load_folder(mut st, st.folder, next, mut app)
		if next != '' && next != st.raw_path {
			open_file(next)
		} else {
			show_frame(mut st, next, mut app)
		}
		if st.frames.len == 0 {
			mut ph := st.holder
			set_placeholder_text(mut ph, false)
		}
		if errs.len > 0 {
			nm.show_error(i18n.trf('Не всё удалось переместить в корзину: {0}', errs.join('; ')))
		}
		if n > 0 {
			nm.show_success(i18n.trf('В корзине: {0}', '${n} ${i18n.pl(n, 'кадр|кадра|кадров')}'))
		}
	}
	open_folder_dialog := fn [mut app, win, open_folder] () {
		dir := vgui.native_select_folder_dialog(win, mut app, vgui.NativeFileDialogConfig{})
		if dir.len > 0 {
			open_folder(dir)
		}
	}

	// Экспорт (JPEG, PNG, TIFF, BMP, QOI, GIF - imgio) - в фоновом потоке
	// (полный кадр с коррекцией ~3.5 с, окно не должно замирать), ход - в
	// диалоге экспорта (export_ui.v). Пока
	// экспорт идёт, пункт меню не запускает второй, а снова открывает
	// диалог; ползунки остаются живыми. Прогресс и результат воркер
	// доставляет через app.post() - цикл vgui спит как обычно.
	mut m_export := vgui.menu_action(i18n.tr('Экспорт...'))
	m_export.shortcut = 'Ctrl+E'
	st.exp_progress = fn [mut st] (ctl &ExportCtl, stage ExportStage, done int, total int) {
		mut c := unsafe { ctl }
		if stage != c.stage {
			c.done = 0
			c.total = 0
		}
		c.stage = stage
		if total > 0 {
			c.done = done
			c.total = total
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
	// «Файл - Экспорт...»: идёт экспорт - его диалог прогресса, иначе
	// окно «Экспорт» (export_setup.v), оно и запускает start_export
	m_export.on_click = fn [mut st, mut nm, mut app, win] () {
		if !isnil(st.exp) {
			show_export(mut st, mut app, win)
			return
		}
		if st.loading {
			nm.show_warning(i18n.tr('Кадр ещё загружается'))
			return
		}
		if isnil(st.dev) && st.frames.len == 0 {
			nm.show_warning(i18n.tr('Сначала откройте RAW-файл или папку'))
			return
		}
		show_export_setup(mut st, mut app, win)
	}
	st.export_go = fn [mut st, mut app, win, save_done] (path string, fmt imgio.Format) {
		if !isnil(st.exp) || isnil(st.dev) {
			return
		}
		edit := st.edit.clone()
		ctl := &ExportCtl{
			src:     st.dev.path
			dst:     path
			fmt:     fmt
			plan:    export_plan(edit, fmt)
			started: time.now().unix_milli()
		}
		// Снимок всего нужного по значению: воркер не трогает st после спавна
		job := SaveJob{
			src:      st.dev.path
			dst:      path
			db:       st.lens_db
			edit:     edit
			format:   fmt
			quality:  st.settings.jpeg_quality
			size:     st.settings.export_size_opts()
			load:     load_level(st.settings.export_load)
			settings: st.settings
			ctl:      ctl
			on_stage: st.exp_progress
		}
		st.exp = ctl
		show_export(mut st, mut app, win)
		export_started(mut st)
		st.save_threads << spawn save_worker(job, mut app, save_done)
	}
	st.exp_event = fn [mut st] (ctl &ExportCtl, ev BatchEvent) {
		batch_event(mut st, ctl, ev)
	}
	// Пакетный экспорт: настройки кадров - здесь (сайдкары),
	// проявка - в фоне по очереди (batch_worker)
	st.export_batch = fn [mut st, mut nm, mut app, win, save_done] (paths []string) {
		if !isnil(st.exp) || paths.len == 0 {
			return
		}
		fmt := st.settings.export_fmt()
		items, bad := batch_items(st, paths)
		if bad.len > 0 {
			nm.show_warning(i18n.trf('Правки не прочитаны, кадр без них: {0}', '${bad.join(', ')}'))
		}
		ctl := &ExportCtl{
			src:     items[0].src
			fmt:     fmt
			n:       items.len
			load:    st.settings.export_load
			started: time.now().unix_milli()
		}
		job := BatchJob{
			items:     items
			settings:  st.settings
			format:    fmt
			db:        st.lens_db
			ctl:       ctl
			on_event:  st.exp_event
		}
		st.exp = ctl
		show_export(mut st, mut app, win)
		export_started(mut st)
		sync_settings_ui(mut st)
		st.save_threads << spawn batch_worker(job, mut app, save_done)
	}

	// «Сброс» тональный: коррекция объектива, камерная кривая
	// и шумодав остаются как есть. Это обычная правка - запись в истории,
	// отменяется Ctrl+Z. Пункт меню «Правка - Сбросить тон».
	reset_tone := fn [mut st, mut cv, mut hist, mut app] () {
		mut e := st.edit.clone()
		// Баланс белого (в EditState, не в params), резкость и эффекты -
		// не тон, «Сброс» их не трогает, как шумодав
		e.params = pipeline.Params{
			sharp: st.edit.params.sharp
			fx:    st.edit.params.fx
		}
		e.curve_pts = neutral_edit().curve_pts
		restore_edit(mut st, e, mut cv, mut hist, mut app)
		record(mut st, 'reset', i18n.tr('Сброс'), false)
	}
	// «Автотон» (autotone.v): экспозиция, контраст, «Тени/Света», чёрные и
	// белые по гистограмме кадра - одной записью истории, отменяется Ctrl+Z.
	// Кнопка в секции «Экспозиция и тон» и «Правка - Автотон».
	auto_tone_fn := fn [mut st, mut cv, mut hist, mut nm, mut app] () {
		if st.linear.len == 0 {
			nm.show_warning(i18n.tr('Сначала откройте RAW-файл'))
			return
		}
		// По кадру после кадрирования (glin), до первого apply - по всему
		t := if st.glin.len == st.gw * st.gh * 3 && st.glin.len > 0 {
			auto_tone(st.glin, st.gmask, st.gw * st.gh, st.edit.params)
		} else {
			auto_tone(st.linear, st.mask, st.pw * st.ph, st.edit.params)
		}
		mut e := st.edit.clone()
		e.params = t.put(e.params)
		restore_edit(mut st, e, mut cv, mut hist, mut app)
		record(mut st, 'autotone', i18n.tr('Автотон'), false)
	}

	// ── Меню вверху окна ──
	// Сочетания клавиш пунктов обрабатывает само меню (MenuBar)
	mut bar := vgui.menu_bar()
	mut m_open := vgui.menu_action(i18n.tr('Открыть файл...'))
	m_open.shortcut = 'Ctrl+O'
	m_open.on_click = open_file_dialog
	mut m_open_dir := vgui.menu_action(i18n.tr('Открыть папку...'))
	m_open_dir.shortcut = 'Ctrl+Shift+O'
	m_open_dir.on_click = open_folder_dialog
	mut m_quit := vgui.menu_action(i18n.tr('Выход'))
	m_quit.shortcut = 'Ctrl+Q'
	m_quit.on_click = fn [mut app] () {
		app.quit()
	}
	// Недавние (recent.v): пункты подменю собирает rebuild_recent_menus
	m_recent_files := vgui.menu_submenu(i18n.tr('Недавние файлы'))
	m_recent_dirs := vgui.menu_submenu(i18n.tr('Недавние папки'))
	st.m_recent_files = m_recent_files
	st.m_recent_dirs = m_recent_dirs
	st.open_path = open_file
	st.open_dir = open_folder
	rebuild_recent_menus(mut st)
	bar.add_menu(i18n.tr('Файл'), [m_open, m_open_dir, m_recent_files, m_recent_dirs,
		vgui.menu_separator(), m_export, vgui.menu_separator(), m_quit])
	// Горячие клавиши - настраиваемые (hotkeys.v): ключи постоянные, по
	// умолчанию - сочетания, заданные пунктам выше
	hk_add(mut st, 'file.open', 'Файл', mut m_open)
	hk_add(mut st, 'file.open_dir', 'Файл', mut m_open_dir)
	hk_add(mut st, 'file.export', 'Файл', mut m_export)
	hk_add(mut st, 'file.quit', 'Файл', mut m_quit)
	avail_add(mut st, .export, [m_export])

	mut m_undo := vgui.menu_action(i18n.tr('Отменить'))
	m_undo.shortcut = 'Ctrl+Z'
	m_undo.on_click = undo
	mut m_redo := vgui.menu_action(i18n.tr('Вернуть'))
	m_redo.shortcut = 'Ctrl+Shift+Z'
	m_redo.on_click = redo
	mut m_reset := vgui.menu_action(i18n.tr('Сбросить тон'))
	m_reset.shortcut = 'Ctrl+Shift+R'
	m_reset.on_click = reset_tone
	mut m_autotone := vgui.menu_action(i18n.tr('Автотон'))
	m_autotone.shortcut = 'Ctrl+U'
	m_autotone.on_click = auto_tone_fn
	mut m_settings := vgui.menu_action(i18n.tr('Настройки...'))
	m_settings.shortcut = 'Ctrl+P'
	m_settings.on_click = fn [mut st] () {
		st.open_settings()
	}
	// Копирование настроек и пресеты (presets.v): окно групп, вставка в
	// открытый кадр или в выделенные в ленте
	st.paste_fn = fn [mut st, mut cv, mut hist, mut nm, mut app] (src EditState, groups []string, name string) {
		paste_settings(mut st, src, groups, name, mut cv, mut hist, mut nm, mut app)
	}
	st.show_groups = fn [mut st, mut app, win] (preset bool) {
		show_groups(mut st, mut app, win, preset)
	}
	mut m_copy := vgui.menu_action(i18n.tr('Копировать настройки...'))
	m_copy.shortcut = 'Ctrl+Shift+C'
	m_copy.on_click = fn [mut st] () {
		st.show_groups(false)
	}
	mut m_paste := vgui.menu_action(i18n.tr('Вставить настройки'))
	m_paste.shortcut = 'Ctrl+Shift+V'
	m_paste.on_click = fn [mut st] () {
		if st.clip_groups.len > 0 {
			st.paste_fn(st.clip, st.clip_groups, i18n.tr('Вставка настроек'))
		}
	}
	st.m_paste = m_paste
	// Режим кадрирования (crop.v): R, как в Lightroom
	mut m_crop := vgui.menu_checkbox(i18n.tr('Кадрирование'), false)
	m_crop.shortcut = 'R'
	m_crop.on_toggle = fn [mut st] (v bool) {
		set_crop_mode(mut st, v)
	}
	st.crop_ui.m_crop = m_crop
	// Выделить все кадры ленты (для вставки настроек и экспорта)
	mut m_all := vgui.menu_action(i18n.tr('Выделить все кадры'))
	m_all.shortcut = 'Ctrl+A'
	m_all.on_click = fn [mut st] () {
		select_all_frames(mut st)
	}
	// Пипетка баланса белого (wb_ui.v) - как кнопка в разделе «Баланс белого»
	mut m_pick := vgui.menu_action(i18n.tr('Пипетка баланса белого'))
	m_pick.shortcut = 'W'
	m_pick.on_click = fn [mut st] () {
		set_wb_pick(mut st, !st.wb_pick && st.linear.len > 0)
	}
	// Удаление пятен (spots_ui.v): Q, как в Lightroom
	mut m_spots := vgui.menu_checkbox(i18n.tr('Удаление пятен'), false)
	m_spots.shortcut = 'Q'
	m_spots.on_toggle = fn [mut st] (v bool) {
		set_spot_mode(mut st, v)
	}
	if !isnil(st.spot_ui) {
		mut su := st.spot_ui
		su.m_spots = m_spots
	}
	bar.add_menu(i18n.tr('Правка'), [m_undo, m_redo, vgui.menu_separator(), m_copy, m_paste,
		m_all, vgui.menu_separator(), m_crop, m_spots, m_pick, m_autotone, m_reset, vgui.menu_separator(),
		m_settings])
	hk_add(mut st, 'edit.undo', 'Правка', mut m_undo)
	hk_add(mut st, 'edit.redo', 'Правка', mut m_redo)
	hk_add(mut st, 'edit.copy', 'Правка', mut m_copy)
	hk_add(mut st, 'edit.paste', 'Правка', mut m_paste)
	hk_add(mut st, 'edit.select_all', 'Правка', mut m_all)
	hk_add(mut st, 'edit.crop', 'Правка', mut m_crop)
	hk_add(mut st, 'edit.spots', 'Правка', mut m_spots)
	hk_add(mut st, 'edit.wb_pick', 'Правка', mut m_pick)
	hk_add(mut st, 'edit.autotone', 'Правка', mut m_autotone)
	hk_add(mut st, 'edit.reset_tone', 'Правка', mut m_reset)
	hk_add(mut st, 'edit.settings', 'Правка', mut m_settings)
	avail_add(mut st, .undo, [m_undo])
	avail_add(mut st, .redo, [m_redo])
	avail_add(mut st, .frame, [m_copy, m_reset])
	avail_add(mut st, .paste, [m_paste])
	avail_add(mut st, .frames, [m_all])
	avail_add(mut st, .pixels, [m_crop, m_spots, m_pick, m_autotone])

	mut m_fit := vgui.menu_action(i18n.tr('Вписать'))
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
	// Увеличение 100% и обратно (щелчок по снимку - то же в точку щелчка)
	mut m_zoom := vgui.menu_action(i18n.tr('100% / вписать'))
	m_zoom.shortcut = 'Z'
	m_zoom.on_click = fn [mut st] () {
		toggle_zoom_center(mut st)
	}
	win.bind_hotkey('Space', fn [mut st] () {
		toggle_zoom_center(mut st)
	})
	// До/после (compare.v): шторка - Y, весь снимок «до» - пока зажата «\»
	mut m_split := vgui.menu_checkbox(i18n.tr('До/после: шторка'), false)
	m_split.shortcut = 'Y'
	m_split.on_toggle = fn [mut st] (v bool) {
		set_ba_split(mut st, v)
	}
	st.m_split = m_split
	mut m_sbs := vgui.menu_checkbox(i18n.tr('До/после: бок о бок'), false)
	m_sbs.shortcut = 'Shift+Y'
	m_sbs.on_toggle = fn [mut st] (v bool) {
		set_ba_sbs(mut st, v)
	}
	st.m_sbs = m_sbs
	// Сравнение двух кадров (pair.v): C, как в Lightroom
	mut m_pair := vgui.menu_checkbox(i18n.tr('Сравнить с выделенным'), false)
	m_pair.shortcut = 'C'
	m_pair.on_toggle = fn [mut st] (v bool) {
		set_pair(mut st, v)
	}
	st.m_pair = m_pair
	mut m_swap := vgui.menu_action(i18n.tr('Сравнение: поменять местами'))
	m_swap.shortcut = 'Shift+C'
	m_swap.on_click = fn [mut st] () {
		pair_swap(mut st)
	}
	// JPEG камеры вместо проявки (camjpeg.v)
	mut m_jpeg := vgui.menu_checkbox(i18n.tr('JPEG камеры'), false)
	m_jpeg.shortcut = 'K'
	m_jpeg.on_toggle = fn [mut st] (v bool) {
		set_jpeg_show(mut st, v)
	}
	st.m_jpeg = m_jpeg
	// Раскладка окна (panel.v): лента и панель скрываются целиком (F6/F8,
	// как в Lightroom), панель - справа или слева
	mut m_strip := vgui.menu_checkbox(i18n.tr('Лента кадров'), !st.settings.no_strip)
	m_strip.shortcut = 'F6'
	m_strip.on_toggle = fn [mut st] (v bool) {
		set_strip_visible(mut st, v)
	}
	st.m_strip = m_strip
	// Обновить ленту: файлы, скопированные в папку во время работы
	mut m_refresh := vgui.menu_action(i18n.tr('Обновить ленту'))
	m_refresh.shortcut = 'F5'
	m_refresh.on_click = fn [mut st] () {
		refresh_folder(mut st)
	}
	mut m_panel := vgui.menu_checkbox(i18n.tr('Панель инструментов'), !st.settings.no_panel)
	m_panel.shortcut = 'F8'
	m_panel.on_toggle = fn [mut st] (v bool) {
		set_panel_visible(mut st, v)
	}
	st.m_panel = m_panel
	mut m_left := vgui.menu_checkbox(i18n.tr('Панель слева'), st.settings.panel_left)
	m_left.on_toggle = fn [mut st] (v bool) {
		set_panel_left(mut st, v)
	}
	st.m_left = m_left
	// Полноэкранный режим: F, выход - F или Esc (как в Lightroom)
	mut m_full := vgui.menu_checkbox(i18n.tr('Полноэкранный режим'), false)
	m_full.shortcut = 'F'
	m_full.on_toggle = fn [mut st] (v bool) {
		set_fullscreen(mut st, v)
	}
	st.m_full = m_full
	mut m_top := vgui.menu_checkbox(i18n.tr('Лента сверху'), st.settings.strip_top)
	m_top.on_toggle = fn [mut st] (v bool) {
		set_strip_top(mut st, v)
	}
	st.m_top = m_top
	// Пересветы и провалы (clipping.v): J - оба сразу, как в Lightroom
	mut m_clipwarn := vgui.menu_checkbox(i18n.tr('Пересветы и провалы'), false)
	m_clipwarn.shortcut = 'J'
	m_clipwarn.on_toggle = fn [mut st] (v bool) {
		set_clip_warn(mut st, v, v)
	}
	st.m_clipwarn = m_clipwarn
	// Заливка маски выделенного градиентного фильтра (masks.v)
	mut m_mask := vgui.menu_checkbox(i18n.tr('Маска фильтра'), st.mask_show)
	m_mask.shortcut = 'O'
	m_mask.on_toggle = fn [mut st] (v bool) {
		set_mask_show(mut st, v)
	}
	st.mask_ui.m_show = m_mask
	// Миникарта при увеличении (vgui): весь снимок и рамка видимого,
	// щелчок по ней - вид туда
	mut m_nav := vgui.menu_checkbox(i18n.tr('Миникарта'), !st.settings.no_navigator)
	m_nav.shortcut = 'N'
	m_nav.on_toggle = fn [mut st, mut cv] (v bool) {
		st.settings.no_navigator = !v
		save_settings(st.settings)
		cv.navigator = v
		cv.mark_dirty()
	}
	// Сведения о съёмке поверх снимка (shotinfo.v), как I в Lightroom
	mut m_info := vgui.menu_checkbox(i18n.tr('Сведения о съёмке'), !st.settings.no_info)
	m_info.shortcut = 'I'
	m_info.on_toggle = fn [mut st] (v bool) {
		set_show_info(mut st, v)
	}
	// Фон вокруг снимка: пункты-флажки, работают как переключатель
	// (отмечен ровно один - set_viewer_bg)
	mut m_bg := vgui.menu_submenu(i18n.tr('Фон вокруг снимка'))
	for i in 0 .. bg_keys.len {
		mut it := vgui.menu_checkbox(i18n.tr(bg_names[i]), bg_keys[i] == st.settings.viewer_bg)
		it.on_toggle = fn [mut st, i] (v bool) {
			set_viewer_bg(mut st, i)
		}
		st.m_bg << it
		m_bg.add(it)
	}
	// Тема оформления: все темы vgui, пункты-флажки как переключатель
	mut m_themes := vgui.menu_submenu(i18n.tr('Тема'))
	for i in 0 .. theme_keys.len {
		mut it := vgui.menu_checkbox(i18n.tr(theme_names[i]), theme_keys[i] == st.settings.theme)
		it.on_toggle = fn [mut st, mut app, i] (v bool) {
			apply_theme(mut st, mut app, i)
		}
		st.m_theme << it
		m_themes.add(it)
	}
	// Вид гистограммы (histogram.v)
	m_hist, hist_items := hist_menu(mut st)
	bar.add_menu(i18n.tr('Вид'), [m_fit, m_z50, m_z100, m_z200, m_zoom, vgui.menu_separator(), m_split,
		m_sbs, m_pair, m_swap, m_jpeg, m_clipwarn, m_hist, m_mask, m_info, m_nav, vgui.menu_separator(), m_full, m_strip, m_refresh, m_top, m_panel, m_left, m_bg, m_themes])
	view_ids := ['view.fit', 'view.z50', 'view.z100', 'view.z200', 'view.zoom', 'view.split',
		'view.sbs', 'view.pair', 'view.swap', 'view.jpeg', 'view.clipwarn', 'view.mask', 'view.info', 'view.nav', 'view.full',
		'view.strip', 'view.refresh', 'view.top', 'view.panel', 'view.left']
	view_items := [m_fit, m_z50, m_z100, m_z200, m_zoom, m_split, m_sbs, m_pair, m_swap, m_jpeg,
		m_clipwarn, m_mask, m_info, m_nav, m_full, m_strip, m_refresh, m_top, m_panel, m_left]
	for i, id in view_ids {
		mut it := view_items[i]
		hk_add(mut st, id, 'Вид', mut it)
	}
	for i, id in ['view.hist_raw', 'view.hist_log', 'view.hist_luma'] {
		mut it := hist_items[i]
		hk_add(mut st, id, 'Вид', mut it)
	}
	avail_add(mut st, .frame, [m_fit, m_z50, m_z100, m_z200, m_zoom, m_split, m_sbs, m_jpeg,
		m_clipwarn])

	// «Отбор» (rating.v): звёзды и флажки - клавишами, как в Lightroom;
	// действуют на выделенные в ленте кадры, без выделения - на открытый
	mut pick_items := []&vgui.MenuItem{}
	for r in 0 .. 6 {
		mut it := vgui.menu_action(if r == 0 {
			i18n.tr('Без звёзд')
		} else {
			'${r} ${i18n.pl(r, 'звезда|звезды|звёзд')}'
		})
		it.shortcut = '${r}'
		it.on_click = fn [mut st, r] () {
			set_rating(mut st, r)
		}
		pick_items << it
	}
	pick_items << vgui.menu_separator()
	flag_names := [i18n.tr('Отобран'), i18n.tr('Отклонён'), i18n.tr('Снять флажок')]
	flag_keys := ['P', 'X', 'U']
	flag_vals := [1, -1, 0]
	for k in 0 .. 3 {
		mut it := vgui.menu_action(flag_names[k])
		it.shortcut = flag_keys[k]
		f := flag_vals[k]
		it.on_click = fn [mut st, f] () {
			set_flag(mut st, f)
		}
		pick_items << it
	}
	pick_items << vgui.menu_separator()
	mut m_advance := vgui.menu_checkbox(i18n.tr('Переходить к следующему кадру'), st.settings.auto_advance)
	m_advance.on_toggle = fn [mut st] (v bool) {
		st.settings.auto_advance = v
		save_settings(st.settings)
	}
	avail_add(mut st, .target, pick_items.filter(it.kind != .separator))
	pick_items << m_advance
	pick_items << vgui.menu_separator()
	// Как в Lightroom: Ctrl+Backspace
	mut m_del_rej := vgui.menu_action(i18n.tr('Удалить отклонённые...'))
	m_del_rej.shortcut = 'Ctrl+Backspace'
	m_del_rej.on_click = fn [delete_rejected] () {
		delete_rejected()
	}
	pick_items << m_del_rej
	avail_add(mut st, .frames, [m_del_rej])
	bar.add_menu(i18n.tr('Отбор'), pick_items)
	pick_ids := ['pick.rate0', 'pick.rate1', 'pick.rate2', 'pick.rate3', 'pick.rate4',
		'pick.rate5', '', 'pick.flag_pick', 'pick.flag_reject', 'pick.flag_none', '',
		'pick.advance', '', 'pick.del_rejected']
	for i, id in pick_ids {
		if id.len > 0 {
			mut it := pick_items[i]
			hk_add(mut st, id, 'Отбор', mut it)
		}
	}

	// «Пресеты» - список пересобирается при сохранении (rebuild_presets_menu)
	st.bar = bar
	st.import_presets = fn [mut st, mut app, win, mut nm] () {
		files := vgui.native_open_files_dialog(win, mut app, vgui.NativeFileDialogConfig{
			filter_names:    [i18n.tr('Пресеты vraw'), i18n.tr('Все файлы')]
			filter_patterns: ['json', '*']
		})
		if files.len == 0 {
			return
		}
		mut names := []string{}
		mut failed := []string{}
		for f in files {
			names << import_preset(f, presets_dir()) or {
				failed << '${os.file_name(f)}: ${err.msg()}'
				continue
			}
		}
		rebuild_presets_menu(mut st)
		if failed.len > 0 {
			nm.show_error(i18n.trf('Не импортировано {0} из {1}: {2}', '${failed.len}', '${files.len}', '${failed[0]}'))
		} else if names.len == 1 {
			nm.show_success(i18n.trf('Пресет «{0}» импортирован', '${names[0]}'))
		} else {
			nm.show_success(i18n.trf('Импортировано пресетов: {0}', '${names.len}'))
		}
	}
	st.export_presets = fn [mut app, win, mut nm] (p Preset) {
		if p.path.len > 0 {
			dst := vgui.native_save_file_dialog(win, mut app, vgui.NativeFileDialogConfig{
				default_name:    '${p.name}.json'
				filter_names:    [i18n.tr('Пресеты vraw')]
				filter_patterns: ['json']
			})
			if dst.len == 0 {
				return
			}
			path := if dst.to_lower().ends_with('.json') { dst } else { dst + '.json' }
			export_preset(p, path) or {
				nm.show_error(i18n.trf('Пресет не экспортирован: {0}', '${err.msg()}'))
				return
			}
			nm.show_success(i18n.trf('Пресет «{0}» сохранён: {1}', '${p.name}', '${os.file_name(path)}'))
			return
		}
		all := list_presets(presets_dir())
		dir := vgui.native_select_folder_dialog(win, mut app, vgui.NativeFileDialogConfig{})
		if dir.len == 0 {
			return
		}
		n := export_presets(all, dir) or {
			nm.show_error(i18n.trf('Пресеты не экспортированы: {0}', '${err.msg()}'))
			return
		}
		nm.show_success(i18n.trf('Экспортировано пресетов: {0} в {1}', '${n}', '${os.file_name(dir)}'))
	}
	st.show_presets = fn [mut st, mut app, win] () {
		show_presets(mut st, mut app, win)
	}
	st.presets_menu = bar.entries.len
	bar.add_menu(i18n.tr('Пресеты'), []&vgui.MenuItem{})
	rebuild_presets_menu(mut st)
	avail_add(mut st, .pair, [m_pair])
	avail_add(mut st, .swap, [m_swap])
	avail_add(mut st, .mask, [m_mask])

	mut exp_row := edit_row(mut st, mut exp, lbl_w, val_w)
	// Ряд «Автотон» - кнопка по своей ширине, слева
	mut b_autotone := vgui.button(i18n.tr('Автотон'))
	b_autotone.icon_name = 'wand-sparkles'
	b_autotone.icon_size = 15
	b_autotone.on_click = auto_tone_fn
	b_autotone.tooltip = i18n.tr('Экспозиция, контраст, тени/света, чёрные и белые по гистограмме')
	st.hk_texts << fn [st, mut b_autotone] () {
		b_autotone.tooltip = i18n.tr('Экспозиция, контраст, тени/света, чёрные и белые по гистограмме') +
			hk_paren(st, 'edit.autotone')
	}
	st.hk_texts << fn [mut st, mut ph] () {
		ko := hk_key(st, 'file.open')
		kd := hk_key(st, 'file.open_dir')
		mut parts := []string{}
		if ko.len > 0 {
			parts << i18n.trf('{0} - файл', '${ko}')
		}
		if kd.len > 0 {
			parts << i18n.trf('{0} - папка', '${kd}')
		}
		ph.open_hint = if parts.len > 0 {
			i18n.trf('Меню «Файл»: {0}', '${parts.join(', ')}')
		} else {
			i18n.tr('Меню «Файл» - открыть файл или папку')
		}
		set_placeholder_text(mut ph, st.frames.len > 0)
	}
	// Подписи по сочетаниям - все действия уже зарегистрированы
	hk_refresh(mut st)
	mut at_row := vgui.create_hbox_fill()
	at_row.add(b_autotone)
	at_row.add(vgui.label(''), flex: 1)
	mut sh_row := edit_row(mut st, mut sh, lbl_w, val_w)
	mut con_row := edit_row(mut st, mut con, lbl_w, val_w)
	mut clr_row := edit_row(mut st, mut clr, lbl_w, val_w)
	mut txr_row := edit_row(mut st, mut txr, lbl_w, val_w)
	mut vib_row := edit_row(mut st, mut vib, lbl_w, val_w)
	mut sat_row := edit_row(mut st, mut sat, lbl_w, val_w)
	mut hlt_row := edit_row(mut st, mut hlt, lbl_w, val_w)
	mut sht_row := edit_row(mut st, mut sht, lbl_w, val_w)
	mut imp_row := edit_row(mut st, mut imp, lbl_w, val_w)
	mut nrl_row := edit_row(mut st, mut nrl, lbl_w, val_w)
	mut nrc_row := edit_row(mut st, mut nrc, lbl_w, val_w)
	mut df_row := edit_row(mut st, mut df, lbl_w, val_w)
	mut sha_row := edit_row(mut st, mut sh_amount, lbl_w, val_w)
	mut shr_row := edit_row(mut st, mut sh_radius, lbl_w, val_w)
	mut shd_row := edit_row(mut st, mut sh_detail, lbl_w, val_w)
	mut shm_row := edit_row(mut st, mut sh_mask, lbl_w, val_w)
	mut dca_row := edit_row(mut st, mut dc_amount, lbl_w, val_w)
	mut dcr_row := edit_row(mut st, mut dc_radius, lbl_w, val_w)
	mut dcc_row := edit_row(mut st, mut dc_contrast, lbl_w, val_w)
	mut hzs_row := edit_row(mut st, mut hz_str, lbl_w, val_w)
	mut hzd_row := edit_row(mut st, mut hz_depth, lbl_w, val_w)
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
	mut lens_rows := [SectionRow{lens_cb}, SectionRow{lens_lb}]
	lens_rows << lens_manual_rows(mut st, lbl_w, val_w)
	lens_rows << SectionRow{vgui.separator()}
	lens_rows << SectionRow{prof_row}
	panel_add(mut st, 'lens', section(lens_rows))
	panel_add(mut st, 'crop', section(crop_rows))
	panel_add(mut st, 'wb', section(wb_rows))
	panel_add(mut st, 'tone', section([
		SectionRow{at_row},
		SectionRow{exp_row},
		SectionRow{sh_row},
		SectionRow{con_row},
		SectionRow{txr_row},
		SectionRow{clr_row},
		SectionRow{vib_row},
		SectionRow{sat_row},
	]))
	panel_add(mut st, 'haze', section([
		SectionRow{hzs_row},
		SectionRow{hzd_row},
		SectionRow{hz_map_cb},
		SectionRow{hz_hint},
	]))
	panel_add(mut st, 'shadows', section([
		SectionRow{hlt_row},
		SectionRow{sht_row},
	]))
	mut eq_items := []SectionRow{}
	for row in eq_rows {
		eq_items << SectionRow{row}
	}
	panel_add(mut st, 'eq', section(eq_items))
	panel_add(mut st, 'curves', section([
		SectionRow{ch_row},
		SectionRow{ed},
		SectionRow{curve_hint},
	]))
	// Высота вкладок: заголовок TabBox + 8 рядов с отступами секции
	panel_add(mut st, 'hsl', section([
		SectionRow{hsl_tabs},
	]))
	panel_add(mut st, 'bw', bw_section(mut st, lbl_w, val_w))
	panel_add(mut st, 'grade', grade_section(mut st, lbl_w, val_w))
	panel_add(mut st, 'masks', section(mask_rows))
	panel_add(mut st, 'spots', section(spot_rows))
	// Раскрытая секция «Градиентные фильтры» показывает метки всех
	// фильтров на снимке (индекс секции - layout_panel)
	acc.on_change = fn [mut st] (idx int, open bool) {
		if !isnil(st.mask_ui) && idx == st.mask_ui.acc_idx {
			mask_redraw(st)
		}
	}
	panel_add(mut st, 'nr', section([
		SectionRow{imp_row},
		SectionRow{nrl_row},
		SectionRow{nrc_row},
		SectionRow{df_row},
	]))
	panel_add(mut st, 'sharp', section([
		SectionRow{dc_caption},
		SectionRow{dca_row},
		SectionRow{dcr_row},
		SectionRow{dcc_row},
		SectionRow{dc_hint},
		SectionRow{vgui.separator()},
		SectionRow{usm_caption},
		SectionRow{sha_row},
		SectionRow{shr_row},
		SectionRow{shd_row},
		SectionRow{shm_row},
		SectionRow{sh_rgb_cb},
		SectionRow{sh_show_cb},
		SectionRow{sharp_hint},
	]))
	panel_add(mut st, 'fx', section([
		SectionRow{vig_caption},
		SectionRow{edit_row(mut st, mut vig_amt, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut vig_mid, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut vig_rnd, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut vig_fth, lbl_w, val_w)},
		SectionRow{vgui.separator()},
		SectionRow{grain_caption},
		SectionRow{edit_row(mut st, mut grn_amt, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut grn_size, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut grn_rough, lbl_w, val_w)},
		SectionRow{fx_hint},
	]))
	// История - последней секцией (по умолчанию): 8 строк списка и подсказка
	panel_add(mut st, 'history', section([
		SectionRow{hist_lb},
		SectionRow{ba_row},
		SectionRow{hist_hint},
	]))

	// Секции - по настройкам: порядок и скрытые разделы (panel.v)
	st.acc = acc
	layout_panel(mut st)

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
	right.add(hist)
	right.add(scroll, flex: 1)

	// Область снимка: фон, выбранный в меню «Вид», картинка с отступом от
	// краёв. Холст и заглушка лежат друг на друге в Stack, видим один.
	// Холст - в ряду: «бок о бок» добавляет слева холст «до» (set_ba_sbs)
	mut cmp_row := vgui.create_hbox_fill()
	cmp_row.set_spacing(sbs_gap)
	cmp_row.add(cv, flex: 1)
	st.cmp_row = cmp_row
	mut view_stack := &vgui.Stack{}
	view_stack.add(cmp_row)
	view_stack.add(placeholder)
	mut load_ov := make_load_overlay(theme)
	st.load_ov = load_ov
	view_stack.add(load_ov.stack)
	mut view_area := vgui.create_vbox_fill()
	view_area.set_padding(view_pad)
	view_area.set_bg(ph.edge) // выбранный фон - когда виден снимок (sync_view_bg)
	view_area.add(view_stack, flex: 1)
	st.view_area = view_area
	st.view_stack = view_stack
	// Область просмотра - снимок и под ним лента кадров папки
	// (layout_strip, когда открыт файл или папка)
	mut viewer := vgui.create_vbox_fill()
	viewer.add(view_area, flex: 1)
	st.viewer = viewer
	// Высота ленты - вертикальным сплиттером; после перетаскивания ячейки
	// подстраиваются под новую высоту
	mut vsplit := vgui.splitter_vertical()
	vsplit.bar_size = 3
	// Мин. высоты и порядок половин - layout_strip (лента снизу или сверху)
	// (при масштабе интерфейса - той же логической высоты, uiscale.v)
	vsplit.ratio = scaled_strip_ratio(strip_start_ratio(st.settings.strip_top), st.settings.strip_top,
		ui_k)
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
	// панели можно менять (по умолчанию 440 при ширине окна 1280); панель
	// справа или слева, или скрыта - layout_work (panel.v)
	mut top := vgui.splitter_horizontal()
	top.bar_size = 3
	// Ширину панели перетащили - запомнить в пикселях (при изменении окна
	// она держится - Splitter.keep); текущий кадр ленты снова по центру
	top.on_resize = fn [mut st] (r f32) {
		panel_dragged(mut st)
		center_strip(mut st)
	}
	st.hsplit = top

	// Корень: меню вверху, под ним рабочая область
	mut root := vgui.create_vbox_fill()
	st.root = root
	st.menu = bar
	st.win = win
	update_title(mut st)
	// Сочетания меню - и в полноэкранном режиме, где полоса скрыта
	bar.keys_when_hidden = true
	layout_work(mut st)
	win.add_widget(root)
	// Менеджер уведомлений - после корневого контейнера: рисуется поверх
	// всего окна, события получает первым (Window обходит виджеты с конца).
	// Свои цвета vraw по палитре темы (фоны панелей, разделители, подписи)
	paint_ui(mut st, theme)
	win.add_widget(nm)
	// Удержание «\» (до/после) и буквы в русской раскладке (compare.v)
	win.add_widget(&KeyWatch{
		st: st
	})
	app.add_window(win)

	// Без кадра доступно только открытие (avail.v)
	sync_avail(mut st)
	// Путь к RAW можно передать аргументом: vraw файл.CR3
	if os.args.len > 1 && os.exists(os.args[1]) {
		open_file(os.args[1])
	}

	app.run()

	// Не обрывать записывающийся файл, если окно закрыли во время сохранения
	for t in st.save_threads {
		t.wait()
	}
	if !isnil(st.dev) {
		st.dev.close()
	}
	wait_prep(mut st) // воркер пользуется профилем из st.lens_db
	wait_details(mut st) // и фрагмент 1:1 - тоже
	wait_ba(mut st) // и сырьё «до»
	wait_pair(mut st) // и левый кадр сравнения
	wait_thumbs(mut st)
	wait_loads(mut st)
	// Потоки сохранения уже дождались выше (повторный wait того же потока
	// роняет программу: «V thread join failed»); база lensfun, которой они
	// пользуются, освобождается только после них
	st.save_threads.clear()
	if !isnil(st.lens_db) {
		st.lens_db.free()
	}
}
