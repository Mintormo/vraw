module main

// Настройки программы между запусками: settings.json рядом с программой
// (не путать с сайдкаром - там правки кадра): тема, цвет области вокруг
// снимка, видимость ленты кадров, модель AI-шумодава, формат экспорта,
// качество JPEG и AI при экспорте. Пишутся при изменении. vraw переносим: настройки, модели (models/) и ONNX Runtime
// (onnxruntime/) - всё в папке программы (app_dir).
import os
import json2
import vgui
import ai
import lens
import imgio
import i18n

struct Settings {
mut:
	viewer_bg  string = 'dark' // ключ из bg_keys
	strip_open bool   = true
	theme      string = 'dark' // ключ из theme_keys (themes.v)
	// язык интерфейса (код из i18n.langs; '' - как в системе); меняется
	// после перезапуска
	lang     string
	ai_model   string = ai.default_model // модель для новых прогонов AI
	// Кэш кадров в памяти (framecache.v): отрицание - в старом
	// settings.json поля нет, кэш по умолчанию включён; предел, МБ (0 -
	// frame_cache_mb_default)
	no_frame_cache bool
	frame_cache_mb int
	// формат экспорта (ключ imgio.Format.key) - последний выбранный
	export_format string = 'jpeg'
	// качество JPEG при экспорте (jpeg_q_min..100)
	jpeg_quality int = jpeg_q_default
	// true - экспорт без AI-шумодава, даже если он включён у кадра.
	// Отрицание нарочно: в settings.json старой версии поля нет, json2
	// даст false - AI при экспорте остаётся включённым
	export_no_ai bool
	// EXIF в готовом файле (imgio/exif.v): отрицание по той же причине -
	// в старом settings.json поля нет, EXIF по умолчанию пишется;
	// копирайт - в каждый файл (пусто - тега нет)
	export_no_exif bool
	exif_copyright string
	// окно «Экспорт» (export_setup.v) - последний выбор: папка ('raw' -
	// рядом с RAW, 'dir' - export_dir), шаблон имени, файл уже есть
	// ('number' - добавить номер, 'overwrite'), размер на выход
	// (export_size: '' как есть, 'long' по длинной стороне, 'fit' вписать
	// в Ш×В, 'pct' в процентах; кадр не увеличивается)
	export_dir_mode string = 'raw'
	export_dir      string
	export_name     string = name_tmpl_default
	export_exists   string = 'number'
	export_size     string
	export_long     int = 2048
	export_w        int = 1920
	export_h        int = 1080
	export_pct      int = 50
	// резкость на выход (ключ export_sharp_keys, '' - нет): только когда
	// кадр уменьшается
	export_sharp string
	// нагрузка экспорта (batch.v, load_keys): кадров одновременно и
	// приоритет потоков
	export_load string = 'normal'
	// группы настроек в окне «Копировать настройки» и «Сохранить пресет»
	// (presets.v) - последний выбор; нет в файле - все
	copy_groups []string = default_copy_groups.clone()
	// кадрирование (crop.v): последняя выбранная пропорция - по умолчанию
	// для кадра без рамки; сетка поверх рамки
	crop_aspect string
	crop_grid   string = 'thirds'
	// отбор (rating.v): после пометки открытого кадра - к следующему
	auto_advance bool
	// раскладка окна (panel.v): панель инструментов и лента кадров скрыты
	// целиком (отрицание - в старом settings.json полей нет, всё видно),
	// панель слева; разделы панели - порядок (ключи panel_sections) и
	// скрытые
	no_panel     bool
	no_strip     bool
	panel_left   bool
	strip_top    bool // лента кадров над снимком
	// полноэкранный режим: панель и лента видны (свои, не как в окне;
	// по умолчанию - один снимок)
	fs_panel bool
	fs_strip bool
	panel_order  []string = panel_default_order()
	panel_hidden []string
	// ширина панели инструментов, px (перетащенная; 0 - по умолчанию)
	panel_w int
	// свои горячие клавиши (hotkeys.v): «ключ=сочетание», пусто после «=» -
	// снято; нет записи - по умолчанию
	hotkeys []string
}

// export_fmt - формат экспорта из настроек (неизвестный - JPEG)
fn (s &Settings) export_fmt() imgio.Format {
	return imgio.format_by_key(s.export_format) or { imgio.Format.jpeg }
}

const jpeg_q_min = 50
const jpeg_q_default = 92

// Фон области просмотра вокруг снимка (меню «Вид - Фон вокруг снимка»).
// Серый - средний (18% серого в sRGB ~ 118): нейтральная оценка яркости.
const bg_keys = ['black', 'dark', 'gray', 'white']
const bg_names = ['Чёрный', 'Тёмно-серый', 'Серый', 'Белый']
const bg_colors = [vgui.Color{0, 0, 0, 255}, vgui.Color{22, 22, 24, 255},
	vgui.Color{118, 118, 118, 255}, vgui.Color{255, 255, 255, 255}]

fn bg_index(key string) int {
	i := bg_keys.index(key)
	return if i < 0 { 1 } else { i }
}

// app_dir - папка программы: рядом с бинарником лежат настройки, модели
// и ONNX Runtime
fn app_dir() string {
	return os.dir(os.executable())
}

// load_lens_db - база lensfun: портабельная сборка носит её в папке
// программы (lensfun/), иначе - системная с обновлениями пользователя.
// Базы нет - nil (коррекция объектива недоступна).
fn load_lens_db() &lens.Database {
	dir := os.join_path(app_dir(), 'lensfun')
	if os.is_dir(dir) {
		if db := lens.load_db_dir(dir) {
			return db
		}
	}
	return lens.load_db() or { unsafe { nil } }
}

fn settings_path() string {
	return os.join_path(app_dir(), 'settings.json')
}

// load_settings - настройки из файла; нет файла или он испорчен -
// значения по умолчанию
fn load_settings() Settings {
	text := os.read_file(settings_path()) or { return Settings{} }
	s := json2.decode[Settings](text) or { return Settings{} }
	return settings_from(s)
}

// settings_from - прочитанные настройки с проверкой значений (чужое или
// устаревшее - по умолчанию). Новое поле Settings - добавлять и сюда,
// иначе оно не переживёт перезапуск (тест test_settings_roundtrip).
fn settings_from(s Settings) Settings {
	return Settings{
		viewer_bg:  bg_keys[bg_index(s.viewer_bg)]
		strip_open: s.strip_open
		theme:      theme_keys[theme_index(s.theme)]
		lang:       if i18n.known(s.lang) { s.lang } else { '' }
		ai_model:   if _ := ai.find_model_info(s.ai_model) { s.ai_model } else { ai.default_model }
		export_format: s.export_fmt().key()
		export_no_ai:  s.export_no_ai
		export_no_exif: s.export_no_exif
		exif_copyright: s.exif_copyright.trim_space()
		export_dir_mode: if s.export_dir_mode == 'dir' && s.export_dir != '' { 'dir' } else { 'raw' }
		export_dir:      s.export_dir
		export_name:     name_tmpl_migrate(s.export_name)
		export_exists:   if s.export_exists == 'overwrite' { 'overwrite' } else { 'number' }
		export_size:     if s.export_size in export_size_keys { s.export_size } else { '' }
		export_long:     clamp_px(s.export_long, 2048)
		export_w:        clamp_px(s.export_w, 1920)
		export_h:        clamp_px(s.export_h, 1080)
		export_pct:      if s.export_pct >= 1 && s.export_pct <= 100 { s.export_pct } else { 50 }
		export_sharp:    if s.export_sharp in export_sharp_keys { s.export_sharp } else { '' }
		export_load:     if s.export_load in load_keys { s.export_load } else { 'normal' }
		copy_groups:   if known_groups(s.copy_groups).len > 0 {
			known_groups(s.copy_groups)
		} else {
			default_copy_groups.clone()
		}
		crop_aspect: if s.crop_aspect in crop_aspects { s.crop_aspect } else { '' }
		crop_grid:   if s.crop_grid in crop_grids { s.crop_grid } else { 'thirds' }
		auto_advance: s.auto_advance
		no_panel:     s.no_panel
		no_strip:     s.no_strip
		panel_left:   s.panel_left
		strip_top:    s.strip_top
		fs_panel:     s.fs_panel
		fs_strip:     s.fs_strip
		panel_order:  panel_order_from(s.panel_order)
		panel_hidden: panel_hidden_from(s.panel_hidden)
		hotkeys:      s.hotkeys.filter(it.contains('='))
		panel_w:      if s.panel_w >= int(panel_min_w) && s.panel_w <= 10000 { s.panel_w } else { 0 }
		no_frame_cache: s.no_frame_cache
		frame_cache_mb: if s.frame_cache_mb in frame_cache_mbs { s.frame_cache_mb } else { 0 }
		// нет в файле (настройки старой версии) или вне диапазона - по умолчанию
		jpeg_quality: if s.jpeg_quality >= jpeg_q_min && s.jpeg_quality <= 100 {
			s.jpeg_quality
		} else {
			jpeg_q_default
		}
	}
}

// save_settings - ошибка записи не критична (молча: настройки просто не
// запомнятся)
fn save_settings(s Settings) {
	path := settings_path()
	os.mkdir_all(os.dir(path)) or { return }
	os.write_file(path, json2.encode(s, prettify: true, indent_string: '  ')) or {}
}
