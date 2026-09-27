module main

// Настройки программы между запусками: ~/.config/vraw/settings.json
// (не путать с сайдкаром - там правки кадра). Сейчас: цвет области
// вокруг снимка и видимость ленты кадров. Пишутся при изменении.
import os
import json2
import vgui

struct Settings {
mut:
	viewer_bg  string = 'dark' // ключ из bg_keys
	strip_open bool   = true
}

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

fn settings_path() string {
	return os.join_path(os.config_dir() or { os.home_dir() }, 'vraw', 'settings.json')
}

// load_settings - настройки из файла; нет файла или он испорчен -
// значения по умолчанию
fn load_settings() Settings {
	text := os.read_file(settings_path()) or { return Settings{} }
	s := json2.decode[Settings](text) or { return Settings{} }
	return Settings{
		viewer_bg:  bg_keys[bg_index(s.viewer_bg)]
		strip_open: s.strip_open
	}
}

// save_settings - ошибка записи не критична (молча: настройки просто не
// запомнятся)
fn save_settings(s Settings) {
	path := settings_path()
	os.mkdir_all(os.dir(path)) or { return }
	os.write_file(path, json2.encode(s, prettify: true, indent_string: '  ')) or {}
}
