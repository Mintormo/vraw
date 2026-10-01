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
import imgio

struct Settings {
mut:
	viewer_bg  string = 'dark' // ключ из bg_keys
	strip_open bool   = true
	theme      string = 'dark' // ключ из theme_keys (themes.v)
	ai_model   string = ai.default_model // модель для новых прогонов AI
	// формат экспорта (ключ imgio.Format.key) - последний выбранный
	export_format string = 'jpeg'
	// качество JPEG при экспорте (jpeg_q_min..100)
	jpeg_quality int = jpeg_q_default
	// true - экспорт без AI-шумодава, даже если он включён у кадра.
	// Отрицание нарочно: в settings.json старой версии поля нет, json2
	// даст false - AI при экспорте остаётся включённым
	export_no_ai bool
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

fn settings_path() string {
	return os.join_path(app_dir(), 'settings.json')
}

// load_settings - настройки из файла; нет файла или он испорчен -
// значения по умолчанию
fn load_settings() Settings {
	text := os.read_file(settings_path()) or { return Settings{} }
	s := json2.decode[Settings](text) or { return Settings{} }
	return Settings{
		viewer_bg:  bg_keys[bg_index(s.viewer_bg)]
		strip_open: s.strip_open
		theme:      theme_keys[theme_index(s.theme)]
		ai_model:   if _ := ai.find_model_info(s.ai_model) { s.ai_model } else { ai.default_model }
		export_format: s.export_fmt().key()
		export_no_ai:  s.export_no_ai
		export_dir_mode: if s.export_dir_mode == 'dir' && s.export_dir != '' { 'dir' } else { 'raw' }
		export_dir:      s.export_dir
		export_name:     if s.export_name.trim_space() != '' { s.export_name } else { name_tmpl_default }
		export_exists:   if s.export_exists == 'overwrite' { 'overwrite' } else { 'number' }
		export_size:     if s.export_size in export_size_keys { s.export_size } else { '' }
		export_long:     clamp_px(s.export_long, 2048)
		export_w:        clamp_px(s.export_w, 1920)
		export_h:        clamp_px(s.export_h, 1080)
		export_pct:      if s.export_pct >= 1 && s.export_pct <= 100 { s.export_pct } else { 50 }
		export_load:     if s.export_load in load_keys { s.export_load } else { 'normal' }
		copy_groups:   if known_groups(s.copy_groups).len > 0 {
			known_groups(s.copy_groups)
		} else {
			default_copy_groups.clone()
		}
		crop_aspect: if s.crop_aspect in crop_aspects { s.crop_aspect } else { '' }
		crop_grid:   if s.crop_grid in crop_grids { s.crop_grid } else { 'thirds' }
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
