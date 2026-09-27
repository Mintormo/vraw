module main

// Сайдкар - файл правок рядом с RAW: IMG_0991.CR3.vraw.json.
// RAW не меняется никогда; в сайдкаре - текущие настройки кадра и вся
// история правок (с позицией, куда откатились). Пишется автоматически
// после каждой правки и перехода по истории (sync_sidecar), читается при
// открытии файла - настройки и история восстанавливаются.
//
// Формат - JSON со своими структурами (Side*), а не EditState как есть:
// в файл идут только исходные настройки (точки кривых, а не таблицы
// tc_*/curve - они производные), фиксированные массивы - обычными
// списками, у полей - понятные имена. Версия формата - в поле version.
import os
import json2
import vgui
import pipeline

const sidecar_ext = '.vraw.json'
const sidecar_version = 1

struct SidePoint {
	x f32
	y f32
}

// SideState - настройки кадра в файле (EditState без производных полей)
struct SideState {
	exposure      f32
	shadows       f32
	contrast      f32
	saturation    f32
	eq            []f32 // 5 полос тон-эквалайзера, EV
	sh_shadows    f32
	sh_highlights f32
	hsl_hue       []f32 // по 8 диапазонов
	hsl_sat       []f32
	hsl_lum       []f32
	curves        [][]SidePoint // точки кривых RGB, R, G, B
	highlight     int
	lens_corr     bool
	use_curve     bool
	nr            []f32 // импульсный, яркостный, цветовой, ореолы
}

struct SideEntry {
	name  string
	key   string
	state SideState
}

struct SideFile {
mut:
	app     string
	version int
	// Текущие настройки (= history[current].state) - отдельно, чтобы
	// пакетной обработке и копированию настроек не разбирать историю
	state   SideState
	current int
	history []SideEntry
}

fn sidecar_path(raw_path string) string {
	return raw_path + sidecar_ext
}

fn side_points(pts []vgui.CurvePoint) []SidePoint {
	return pts.map(SidePoint{it.x, it.y})
}

fn side_state(e EditState) SideState {
	p := e.params
	return SideState{
		exposure:      p.exposure
		shadows:       p.shadows
		contrast:      p.contrast
		saturation:    p.saturation
		eq:            p.eq[..]
		sh_shadows:    p.sh_shadows
		sh_highlights: p.sh_highlights
		hsl_hue:       p.hsl_hue[..]
		hsl_sat:       p.hsl_sat[..]
		hsl_lum:       p.hsl_lum[..]
		curves:        e.curve_pts.map(side_points(it))
		highlight:     e.highlight
		lens_corr:     e.lens_corr
		use_curve:     e.use_curve
		nr:            e.nr[..]
	}
}

// edit_state - обратно в EditState с проверкой: неверные размеры
// массивов (испорченный или чужой файл) - ошибка, а не выход за границы.
// Производные поля (params.curve, tc_*) заполняет with_derived.
fn edit_state(s SideState) !EditState {
	if s.eq.len != 5 || s.hsl_hue.len != 8 || s.hsl_sat.len != 8 || s.hsl_lum.len != 8
		|| s.nr.len != 4 || s.curves.len != 4 {
		return error('неверный размер массивов настроек')
	}
	mut e := EditState{
		params:    pipeline.Params{
			exposure:      s.exposure
			shadows:       s.shadows
			contrast:      s.contrast
			saturation:    s.saturation
			sh_shadows:    s.sh_shadows
			sh_highlights: s.sh_highlights
		}
		highlight: s.highlight
		lens_corr: s.lens_corr
		use_curve: s.use_curve
	}
	for i in 0 .. 5 {
		e.params.eq[i] = s.eq[i]
	}
	for i in 0 .. 8 {
		e.params.hsl_hue[i] = s.hsl_hue[i]
		e.params.hsl_sat[i] = s.hsl_sat[i]
		e.params.hsl_lum[i] = s.hsl_lum[i]
	}
	for i in 0 .. 4 {
		e.nr[i] = s.nr[i]
	}
	for c in s.curves {
		if c.len < 2 {
			return error('в кривой меньше двух точек')
		}
		e.curve_pts << c.map(vgui.CurvePoint{it.x, it.y})
	}
	return e
}

// encode_sidecar - история State как JSON-документ сайдкара
fn encode_sidecar(st &State) string {
	mut f := SideFile{
		app:     'vraw'
		version: sidecar_version
		state:   side_state(st.history[st.hist_pos].state)
		current: st.hist_pos
	}
	for h in st.history {
		f.history << SideEntry{
			name:  h.name
			key:   h.key
			state: side_state(h.state)
		}
	}
	return json2.encode(f, prettify: true, indent_string: '  ')
}

// LoadedSidecar - прочитанный сайдкар: снимки ещё без производных полей
struct LoadedSidecar {
	history []HistEntry
	current int
}

fn decode_sidecar(text string) !LoadedSidecar {
	f := json2.decode[SideFile](text) or { return error('не JSON сайдкара vraw') }
	if f.app != 'vraw' {
		return error('не сайдкар vraw')
	}
	if f.version > sidecar_version {
		return error('версия ${f.version} новее программы')
	}
	if f.history.len == 0 || f.current < 0 || f.current >= f.history.len {
		return error('пустая или испорченная история')
	}
	mut hs := []HistEntry{}
	for h in f.history {
		hs << HistEntry{
			name:  h.name
			key:   h.key
			state: edit_state(h.state)!
		}
	}
	return LoadedSidecar{
		history: hs
		current: f.current
	}
}

// load_sidecar читает сайдкар; пустая история - файла нет, ошибка -
// файл есть, но прочитать нельзя (перезапишется при следующей правке).
fn load_sidecar(path string) !LoadedSidecar {
	if !os.exists(path) {
		return LoadedSidecar{}
	}
	text := os.read_file(path)!
	return decode_sidecar(text)!
}

// sync_sidecar записывает историю в сайдкар (после правки или перехода).
// Только что открытый файл без правок сайдкар не создаёт; если сайдкар
// уже есть - он обновляется всегда (откат к «Открыт файл» тоже правка
// состояния). Запись атомарная: временный файл + переименование, чтобы
// сбой посреди записи не оставил обрезанный JSON. Ошибка записи
// (папка только для чтения) показывается один раз на файл.
fn sync_sidecar(mut st State) {
	if st.side_path.len == 0 || st.history.len == 0 {
		return
	}
	if st.history.len == 1 && !os.exists(st.side_path) {
		return
	}
	tmp := st.side_path + '.tmp'
	os.write_file(tmp, encode_sidecar(st)) or {
		sidecar_error(mut st, err)
		return
	}
	os.mv(tmp, st.side_path) or {
		os.rm(tmp) or {}
		sidecar_error(mut st, err)
		return
	}
	mark_edited(mut st) // отметка «изменён» на миниатюре ленты
}

fn sidecar_error(mut st State, err IError) {
	if st.side_err {
		return
	}
	st.side_err = true
	if !isnil(st.nm) {
		mut nm := st.nm
		nm.show_warning('Правки не сохранены рядом с RAW: ${err.msg()}')
	}
}

// with_derived заполняет производные поля снимка: камерную кривую
// кадра (при use_curve) и таблицы кривых из точек. Нужна снимкам из
// файла - иначе сравнение с живым st.edit (record) всегда давало бы
// «изменилось».
fn with_derived(e EditState, cam_curve []f32) EditState {
	mut d := e.clone()
	d.params.curve = if e.use_curve { cam_curve.clone() } else { []f32{} }
	d.params.tc_rgb = tone_lut(e.curve_pts[0])
	d.params.tc_r = tone_lut(e.curve_pts[1])
	d.params.tc_g = tone_lut(e.curve_pts[2])
	d.params.tc_b = tone_lut(e.curve_pts[3])
	return d
}
