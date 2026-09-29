module main

// Настройки программы между запусками: settings.json рядом с программой
// (не путать с сайдкаром - там правки кадра): тема, цвет области вокруг
// снимка, видимость ленты кадров, модель AI-шумодава, качество JPEG
// экспорта. Пишутся при
// изменении. vraw переносим: настройки, модели (models/) и ONNX Runtime
// (onnxruntime/) - всё в папке программы (app_dir).
import os
import json2
import vgui
import ai

struct Settings {
mut:
	viewer_bg  string = 'dark' // ключ из bg_keys
	strip_open bool   = true
	theme      string = 'dark' // ключ из theme_keys (themes.v)
	ai_model   string = ai.default_model // модель для новых прогонов AI
	// качество JPEG при экспорте (jpeg_q_min..100)
	jpeg_quality int = jpeg_q_default
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
