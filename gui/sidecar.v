module main

// Сайдкар в GUI: IMG_0991.CR3.vraw.json рядом с RAW. RAW не меняется
// никогда; в сайдкаре - текущие настройки кадра, вся история правок (с
// позицией, куда откатились) и камерная кривая, с которой показан кадр.
// Пишется автоматически после каждой правки и перехода по истории
// (sync_sidecar), читается при открытии файла - настройки и история
// восстанавливаются.
//
// Формат и чтение/запись JSON - общий модуль develop (им же проявляет
// CLI); здесь - перевод между EditState GUI и develop.Settings.
import os
import vgui
import pipeline
import develop

fn sidecar_path(raw_path string) string {
	return develop.sidecar_path(raw_path)
}

fn dev_points(pts []vgui.CurvePoint) []develop.Point {
	return pts.map(develop.Point{it.x, it.y})
}

// side_state - настройки снимка в формате файла (без производных полей)
fn side_state(e EditState) develop.Settings {
	p := e.params
	return develop.Settings{
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
		curves:        e.curve_pts.map(dev_points(it))
		highlight:     e.highlight
		lens_corr:     e.lens_corr
		use_curve:     e.use_curve
		nr:            e.nr[..]
	}
}

// edit_state - обратно в EditState с проверкой размеров массивов
// (испорченный или чужой файл - ошибка, а не выход за границы).
// Производные поля (params.curve, tc_*) заполняет with_derived.
fn edit_state(s develop.Settings) !EditState {
	s.validate()!
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
		e.curve_pts << c.map(vgui.CurvePoint{it.x, it.y})
	}
	return e
}

// encode_sidecar - история State как JSON-документ сайдкара; камерная
// кривая кадра - чтобы CLI проявил ровно так, как кадр показан в окне
fn encode_sidecar(st &State) string {
	mut f := develop.File{
		state:        side_state(st.history[st.hist_pos].state)
		current:      st.hist_pos
		camera_curve: st.curve.clone()
	}
	for h in st.history {
		f.history << develop.Entry{
			name:  h.name
			key:   h.key
			state: side_state(h.state)
		}
	}
	return develop.encode(f)
}

// LoadedSidecar - прочитанный сайдкар: снимки ещё без производных полей
struct LoadedSidecar {
	history []HistEntry
	current int
}

fn decode_sidecar(text string) !LoadedSidecar {
	f := develop.decode(text)!
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
