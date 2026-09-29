module main

// Сайдкар: IMG_0991.CR3.vraw.json рядом с RAW. RAW не меняется никогда;
// в сайдкаре - текущие настройки кадра и вся история правок (с позицией,
// куда откатились). Пишется автоматически после каждой правки и перехода
// по истории (sync_sidecar), читается при открытии файла - настройки и
// история восстанавливаются.
//
// Формат - JSON (json2, отступ 2 пробела): SideFile с настройками кадра
// в «файловом» виде (SideState - только исходные значения, массивы
// списками); здесь же перевод SideState <-> EditState.
import os
import json2
import vgui
import pipeline

const sidecar_ext = '.vraw.json'
const sidecar_version = 1

fn sidecar_path(raw_path string) string {
	return raw_path + sidecar_ext
}

// SideState - настройки кадра в файле: только исходные значения (точки
// кривых, а не таблицы - они производные), массивы - списками. Имена
// полей - это ключи JSON, менять нельзя (старые сайдкары). Значений по
// умолчанию нет: в файл пишется всё, а `[][]T{len: 4, init: ...}` в поле
// ломает C-кодоген V внутри json2.
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
	curves        [][]vgui.CurvePoint // точки кривых RGB, R, G, B
	highlight     int
	lens_corr     bool
	use_curve     bool
	nr            []f32 // импульсный, яркостный, цветовой, ореолы
	ai            f32   // AI-шумодав 0..100 (в старых файлах нет - 0)
	ai_model      string // модель AI (id из ai.models)
	// Баланс белого и резкость (в старых файлах нет: '' - «как снято»,
	// нули - резкость выключена, радиус 0 читается как 1)
	wb_mode       string
	wb_temp       f32
	wb_tint       f32
	sharp_amount  f32
	sharp_radius  f32
	sharp_detail  f32
	sharp_masking f32
}

// validate - размеры массивов (испорченный или чужой файл - ошибка, а не
// выход за границы при применении)
fn (s SideState) validate() ! {
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

struct SideEntry {
	name  string
	key   string
	state SideState
}

// SideFile - документ сайдкара. state (= history[current].state) -
// отдельно, чтобы будущей пакетной обработке и копированию настроек не
// разбирать историю. Поле camera_curve из старых сайдкаров (его читал
// убранный консольный vraw) json2 при чтении пропускает.
struct SideFile {
mut:
	app     string = 'vraw'
	version int    = sidecar_version
	state   SideState
	current int
	history []SideEntry
}

// side_state - настройки снимка в формате файла (без производных полей)
fn side_state(e EditState) SideState {
	p := e.params
	return SideState{
		exposure:      p.exposure
		shadows:       p.shadows
		contrast:      p.contrast
		saturation:    p.saturation
		eq:            p.eq[..].clone()
		sh_shadows:    p.sh_shadows
		sh_highlights: p.sh_highlights
		hsl_hue:       p.hsl_hue[..].clone()
		hsl_sat:       p.hsl_sat[..].clone()
		hsl_lum:       p.hsl_lum[..].clone()
		curves:        e.curve_pts.map(it.clone())
		highlight:     e.highlight
		lens_corr:     e.lens_corr
		use_curve:     e.use_curve
		nr:            e.nr[..].clone()
		ai:            e.ai
		ai_model:      e.ai_model
		wb_mode:       e.wb_mode
		wb_temp:       e.wb_temp
		wb_tint:       e.wb_tint
		sharp_amount:  p.sharp.amount
		sharp_radius:  p.sharp.radius
		sharp_detail:  p.sharp.detail
		sharp_masking: p.sharp.masking
	}
}

// edit_state - обратно в EditState с проверкой размеров массивов.
// Производные поля (params.curve, tc_*, wb) заполняет with_derived.
fn edit_state(s SideState) !EditState {
	s.validate()!
	mut e := EditState{
		params:    pipeline.Params{
			exposure:      s.exposure
			shadows:       s.shadows
			contrast:      s.contrast
			saturation:    s.saturation
			sh_shadows:    s.sh_shadows
			sh_highlights: s.sh_highlights
			sharp:         pipeline.Sharpen{
				amount:  s.sharp_amount
				radius:  if s.sharp_radius > 0 { s.sharp_radius } else { f32(1.0) }
				detail:  s.sharp_detail
				masking: s.sharp_masking
			}
		}
		highlight: s.highlight
		lens_corr: s.lens_corr
		use_curve: s.use_curve
		ai:        s.ai
		ai_model:  s.ai_model
		wb_mode:   s.wb_mode
		wb_temp:   s.wb_temp
		wb_tint:   s.wb_tint
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
		e.curve_pts << c.clone()
	}
	return e
}

// encode_sidecar - история State как JSON-документ сайдкара
fn encode_sidecar(st &State) string {
	mut f := SideFile{
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

// decode_sidecar - сайдкар из JSON с проверкой: чужой файл, новая
// версия, испорченная история или массивы - ошибка
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
// кадра (при use_curve), таблицы кривых из точек и матрицу баланса
// белого по цвету камеры кадра. Нужна снимкам из файла - иначе
// сравнение с живым st.edit (record) всегда давало бы «изменилось».
fn with_derived(e EditState, cam_curve []f32, cam pipeline.CamColor) EditState {
	mut d := e.clone()
	d.params.curve = if e.use_curve { cam_curve.clone() } else { []f32{} }
	d.params.tc_rgb = tone_lut(e.curve_pts[0])
	d.params.tc_r = tone_lut(e.curve_pts[1])
	d.params.tc_g = tone_lut(e.curve_pts[2])
	d.params.tc_b = tone_lut(e.curve_pts[3])
	wb_derive(mut d, cam)
	return d
}
