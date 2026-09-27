module develop

// Сайдкар - файл правок рядом с RAW: IMG_0991.CR3.vraw.json. Общий для
// GUI (пишет после каждой правки, читает при открытии) и CLI (проявляет
// по нему). Формат - JSON (json2, с отступами): текущие настройки кадра
// (state), вся история правок (history, позиция current) и камерная
// кривая, с которой GUI показывал кадр (camera_curve).
import os
import json2

pub const sidecar_ext = '.vraw.json'
pub const sidecar_version = 1

pub fn sidecar_path(raw_path string) string {
	return raw_path + sidecar_ext
}

// Point - опорная точка тональной кривой (0..1)
pub struct Point {
pub:
	x f32
	y f32
}

// Settings - настройки кадра в файле: только исходные значения (точки
// кривых, а не таблицы - они производные), массивы - списками. Имена
// полей - это ключи JSON, менять нельзя (старые сайдкары).
pub struct Settings {
pub mut:
	exposure      f32
	shadows       f32
	contrast      f32
	saturation    f32 = 1
	eq            []f32 = []f32{len: 5} // 5 полос тон-эквалайзера, EV
	sh_shadows    f32
	sh_highlights f32
	hsl_hue       []f32   = []f32{len: 8} // по 8 диапазонов
	hsl_sat       []f32   = []f32{len: 8}
	hsl_lum       []f32   = []f32{len: 8}
	// Точки кривых RGB, R, G, B. Без значения по умолчанию: `[][]Point{len:
	// 4, init: ...}` в поле ломает C-кодоген V внутри json2 - нейтральные
	// настройки со всеми четырьмя диагоналями даёт neutral()
	curves        [][]Point
	highlight     int
	lens_corr     bool  = true
	use_curve     bool  = true
	nr            []f32 = []f32{len: 4} // импульсный, яркостный, цветовой, ореолы
}

// neutral - нейтральные настройки (как у только что открытого кадра)
pub fn neutral() Settings {
	return Settings{
		curves: [identity_points(), identity_points(), identity_points(), identity_points()]
	}
}

pub fn identity_points() []Point {
	return [Point{0, 0}, Point{1, 1}]
}

// validate - размеры массивов (испорченный или чужой файл - ошибка, а не
// выход за границы при применении)
pub fn (s Settings) validate() ! {
	if s.eq.len != 5 || s.hsl_hue.len != 8 || s.hsl_sat.len != 8 || s.hsl_lum.len != 8
		|| s.nr.len != 4 || s.curves.len != 4 {
		return error('неверный размер массивов настроек')
	}
	for c in s.curves {
		if c.len < 2 {
			return error('в кривой меньше двух точек')
		}
	}
}

pub struct Entry {
pub:
	name  string
	key   string
	state Settings
}

pub struct File {
pub mut:
	app     string = 'vraw'
	version int    = sidecar_version
	// Текущие настройки (= history[current].state) - отдельно, чтобы CLI,
	// пакетной обработке и копированию настроек не разбирать историю
	state   Settings
	current int
	history []Entry
	// Камерная кривая (256 узлов тон -> тон), с которой GUI показывал кадр;
	// пусто - нет (старый сайдкар, кадр без встроенного JPEG) - CLI
	// посчитает её сам (camera_curve)
	camera_curve []f32
}

pub fn encode(f File) string {
	return json2.encode(f, prettify: true, indent_string: '  ')
}

// decode - сайдкар из JSON с проверкой: чужой файл, новая версия,
// испорченная история или массивы - ошибка
pub fn decode(text string) !File {
	f := json2.decode[File](text) or { return error('не JSON сайдкара vraw') }
	if f.app != 'vraw' {
		return error('не сайдкар vraw')
	}
	if f.version > sidecar_version {
		return error('версия ${f.version} новее программы')
	}
	if f.history.len == 0 || f.current < 0 || f.current >= f.history.len {
		return error('пустая или испорченная история')
	}
	for h in f.history {
		h.state.validate()!
	}
	f.state.validate()!
	if f.camera_curve.len != 0 && f.camera_curve.len != 256 {
		return error('неверный размер камерной кривой')
	}
	return f
}

// load - сайдкар по пути; ошибка - нет файла или его не прочитать
pub fn load(path string) !File {
	return decode(os.read_file(path)!)!
}
