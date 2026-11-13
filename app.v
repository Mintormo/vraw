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
	dev          &raw.Developer = unsafe { nil } // открытый кадр; хендл LibRaw закрыт после загрузки (path, full_size)
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
	save_threads []Worker // хендлы фоновых сохранений (workers.v): wait_all после app.run()
	// Подготовка сырья в фоне (prep_worker): не больше одного воркера.
	// Запрос во время работы только меняет настройки - prep_done сверит
	// их с применёнными и запустит ещё один проход.
	file_gen     int  // номер открытого файла: результат старого файла отбрасывается
	lens_dirty   bool // raw_linear устарел - нужна коррекция объектива из dev_linear
	prep_running bool
	prep_threads []Worker
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
	lens_lb &vgui.Label    = unsafe { nil } // профиль объектива под чекбоксом (panel_ui.v)
	prof_cb &vgui.ComboBox = unsafe { nil } // «Профиль» (profile.v)
	hist_lb &vgui.ListBox  = unsafe { nil }
	hist_clear &vgui.Button = unsafe { nil } // «Очистить историю» (history.v)
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
	strip_rating  &vgui.Rating   = unsafe { nil } // звёзды открытого кадра над лентой (rating.v)
	strip_toggle  &vgui.Button   = unsafe { nil }
	strip_open    bool           = true
	thumb_gen     int
	thumb_stop    &StopFlag = unsafe { nil }
	thumb_threads []Worker
	thumb_done    fn (ThumbResult) = unsafe { nil }
	heads_done    fn (HeadsResult) = unsafe { nil }
	// Воркер миниатюр видимой части ленты (strip_thumbs): его остановка и
	// заказанные кадры
	thumb_win_stop &StopFlag = unsafe { nil }
	thumb_req      map[int]bool
	reveal_procs  []&os.Process // запущенные xdg-open (reveal_nix.c.v)
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
	load_threads []Worker
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
	// Многоугольник фильтра (masks.v): контур рисуется (щелчки ставят
	// вершины), курсор над холстом (буфер) - резинка к нему, выделенная
	// вершина (Delete удаляет; -1 - нет)
	poly_open  bool
	poly_hover bool
	poly_hx    f32
	poly_hy    f32
	poly_vsel  int = -1
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
	// Точечный цвет (pcolor_ui.v): пипетка, выделенная точка, раздел
	pc_pick bool
	pc_sel  int = -1
	pc_ui   &PcUi = unsafe { nil }
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
	// Маска фокуса (focus.v) - вид, не правка; буферы превью, фрагмента 1:1
	// и левого кадра сравнения (свои размеры - без перевыделения)
	focus_show bool
	focus_pv   FocusBufs
	focus_dt   FocusBufs
	focus_pair FocusBufs
	m_focus    &vgui.MenuItem = unsafe { nil }
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
	ba_threads   []Worker
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
	pair_threads []Worker
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
		jpeg_pixels(st, mut cv.pixels)
		st.hist_r, st.hist_g, st.hist_b = render_histogram(mut st, mut hist, cv.pixels)
		update_curve_histogram(mut st)
		show_clip_marks(mut st, mut hist)
		if st.focus_show {
			mark_focus(mut cv.pixels, cv.width, cv.height, 1, mut st.focus_pv)
		}
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
		if st.focus_show { // маска фокуса (focus.v) - поверх, как клип
			mark_focus(mut cv.pixels, st.gw, st.gh, 1, mut st.focus_pv)
		}
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
fn prep_worker(done &Done, job PrepJob, mut app vgui.App, on_done fn (PrepResult)) {
	defer {
		done.set()
	}
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
	wd := &Done{}
	track(mut st.prep_threads, spawn prep_worker(wd, job, mut app, st.prep_done), wd)
}

// wait_prep дожидается фонового воркера.
// Нужна перед синхронной подготовкой и на выходе (до освобождения базы
// lensfun). Результат дождавшегося воркера уже в очереди
// app.post - его отбросит проверка file_gen/prep_running в prep_done.
fn wait_prep(mut st State) {
	wait_all(mut st.prep_threads)
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
fn save_worker(done &Done, job SaveJob, mut app vgui.App, on_done fn (SaveOutcome, string)) {
	defer {
		done.set()
	}
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

// slider_row собирает стандартный ряд панели: подпись, ползунок, поле
// значения справа от ползунка (vgui.NumberField, value_field.v: щелчок -
// ввод числа, протяжка - правка) и кнопка сброса этого параметра. set_value сам вызывает on_change ползунка, поэтому кнопкам
// достаточно выставить значение. Ширины колонок подписи/значения общие на
// всю панель - считаются в main через column_width, чтобы колонки рядов
// были выровнены.
fn slider_row(mut st State, lb &vgui.Label, mut sl vgui.Slider, vf &vgui.NumberField, def f32, lw f32, vw f32) &vgui.HBox {
	mut b := reset_button(i18n.tr('Сбросить'))
	b.on_click = fn [mut sl, def] () {
		sl.set_value(def)
	}
	mut row := vgui.create_hbox_fill()
	row.set_spacing(6)
	row.add(lb, min: lw)
	row.add(sl, flex: 1)
	row.add(vf, min: vw) // значение: щелчок - ввод числа, протяжка - правка (value_field.v)
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
	// Число в поле значения (value_field.v): значение ползунка -> число
	// в поле и обратно; nil - число и есть значение
	to_num   fn (f32) f32 = unsafe { nil }
	from_num fn (f32) f32 = unsafe { nil }
}

// EditSlider - собранный ползунок: подпись, ползунок, поле значения
struct EditSlider {
mut:
	lb   &vgui.Label       = unsafe { nil }
	sl   &vgui.Slider      = unsafe { nil }
	vf   &vgui.NumberField = unsafe { nil }
	def  f32
	conv NumConv // число в поле значения (value_field.v)
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
	mut sl := vgui.slider_horizontal(cfg.min, cfg.max, cfg.def)
	if cfg.digits == 0 {
		sl.step = 1
	}
	conv := NumConv{
		digits: cfg.digits
		to:     cfg.to_num
		from:   cfg.from_num
	}
	text := fn [cfg] (v f32) string {
		return slider_text(cfg, v)
	}
	mut vf := value_field(mut sl, conv, text)
	// Колесо мыши - прокрутке панели: курсор, проезжая по ползунку, не
	// должен менять настройку кадра
	sl.wheel = false
	key := if cfg.hname.len > 0 { cfg.hname } else { cfg.label }
	sl.on_change = fn [mut st, mut vf, mut sl, cfg, key, conv] (v f32) {
		cfg.set(mut st.edit, v)
		show_value(mut vf, conv, v)
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
		lb:   lb
		sl:   sl
		vf:   vf
		def:  cfg.def
		conv: conv
	}
}

// edit_row - стандартный ряд панели (slider_row) для ползунка edit_slider
fn edit_row(mut st State, mut s EditSlider, lw f32, vw f32) &vgui.HBox {
	return slider_row(mut st, s.lb, mut s.sl, s.vf, s.def, lw, vw)
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
		title.text = i18n.tr('Откройте или перетащите сюда RAW-файл или папку')
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
	// Иконка окна (панель задач, Alt+Tab) вшита в бинарник - файл рядом
	// не нужен; исходники и все размеры - assets/icon/
	win.set_icon_data($embed_file('assets/icon/vraw-256.png').to_bytes())
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
		// Пипетка точечного цвета (pcolor_ui.v): щелчок - новая точка
		if st.pc_pick && ev.kind == .pointer_down && ev.button == 1 && ev.in_image {
			pc_pick_at(mut st, ev.x, ev.y)
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
	// Секции панели правки (panel_ui.v): ползунки и чекбоксы, ряды секций
	lens_items, nr_items := lens_nr_rows(mut st, mut app, lbl_w, val_w)
	mut lens_cb := st.lens_cb
	mut lens_lb := st.lens_lb
	tone_items0, shadow_items, eq_items := tone_rows(mut st, lbl_w, val_w)
	curve_items := curve_rows(mut st, mut cv, mut hist)
	hsl_items := hsl_rows(mut st, lbl_w, val_w)
	sharp_items := sharp_rows(mut st, mut app, lbl_w, val_w)
	haze_items := haze_rows(mut st, lbl_w, val_w)
	fx_items := fx_rows(mut st, lbl_w, val_w)
	// Баланс белого: режим, пипетка, температура, оттенок (wb_ui.v)
	wb_rows := build_wb_section(mut st, lbl_w, val_w)
	// Кадрирование и поворот (crop.v)
	crop_rows := build_crop_section(mut st, lbl_w, val_w)
	// Градиентные фильтры (masks.v)
	mask_rows := build_mask_section(mut st, lbl_w, val_w)
	// Удаление пятен (spots_ui.v)
	spot_rows := build_spot_section(mut st, lbl_w, val_w)
	// Точечный цвет (pcolor_ui.v)
	pc_rows := build_pc_section(mut st, lbl_w, val_w)

	// История правок (panel_ui.v)
	history_items := history_rows(mut st, mut app, win, mut cv, mut hist)
	// Ctrl+Z / Ctrl+Shift+Z - пункты меню «Правка» (сочетания обрабатывает
	// меню); Ctrl+Y - дополнительно, горячей клавишей окна
	undo := fn [mut st, mut cv, mut hist, mut app] () {
		goto_history(mut st, st.hist_pos - 1, mut cv, mut hist, mut app)
	}
	redo := fn [mut st, mut cv, mut hist, mut app] () {
		goto_history(mut st, st.hist_pos + 1, mut cv, mut hist, mut app)
	}
	win.bind_hotkey('Ctrl+Y', redo)

	// ── Открытие файла: кнопка, аргумент, лента (file_ui.v) ──
	open_file := build_open(mut st, mut app, mut cv, mut hist, mut nm, mut lens_cb, mut lens_lb, mut
		placeholder)

	// ── Лента кадров папки (browser.v) ──
	build_strip(mut st, mut app, win, open_file)

	// ── Файл: открыть файл или папку, экспорт, тон (file_ui.v) ──
	fa := file_actions(mut st, mut app, win, mut cv, mut hist, mut nm, mut lens_cb, mut lens_lb, mut
		placeholder, open_file)
	open_file_dialog := fa.open_file_dialog
	open_folder := fa.open_folder
	open_folder_dialog := fa.open_folder_dialog
	delete_rejected := fa.delete_rejected
	mut m_export := build_export(mut st, mut app, win, mut nm)
	reset_tone, auto_tone_fn := tone_actions(mut st, mut app, mut cv, mut hist, mut nm)

	// ── Меню вверху окна (menu_ui.v) ──
	mut bar := build_menu(mut st, mut app, win, mut cv, mut hist, mut nm, MenuActions{
		open_file:          open_file
		open_file_dialog:   open_file_dialog
		open_folder:        open_folder
		open_folder_dialog: open_folder_dialog
		delete_rejected:    delete_rejected
		undo:               undo
		redo:               redo
		reset_tone:         reset_tone
		auto_tone:          auto_tone_fn
		m_export:           m_export
	})

	// Правая панель: гистограмма и секции (panel_ui.v)
	build_panel(mut st, mut ph, mut hist, auto_tone_fn, PanelItems{
		lens: lens_items
		crop: crop_rows
		wb: wb_rows
		tone: tone_items0
		haze: haze_items
		shadows: shadow_items
		eq: eq_items
		curves: curve_items
		hsl: hsl_items
		pcolor: pc_rows
		masks: mask_rows
		spots: spot_rows
		nr: nr_items
		sharp: sharp_items
		fx: fx_items
		history: history_items
	}, lbl_w, val_w)


	// Раскладка окна (file_ui.v)
	build_layout(mut st, mut app, mut win, mut cv, mut placeholder, ph, theme, mut nm, mut bar, ui_k,
		open_file, open_folder)

	// Без кадра доступно только открытие (avail.v)
	sync_avail(mut st)
	// Путь к RAW можно передать аргументом: vraw файл.CR3
	if os.args.len > 1 && os.exists(os.args[1]) {
		open_file(os.args[1])
	}

	app.run()

	shutdown_app(mut st)
}
