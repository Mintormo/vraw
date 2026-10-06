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
import math
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
	// Удаление дымки (в старых файлах нет: сила 0 - выключено, глубина
	// при нулевой силе 0 читается как 25 - по умолчанию)
	haze       f32
	haze_depth f32
	// Сочность (в старых файлах нет - 0)
	vibrance f32
	// Резкость по каналам и Capture-резкость (в старых файлах нет: по
	// люме, сила 0; радиус 0 читается как 0.75, порог при нулевой силе -
	// как 10)
	sharp_rgb   bool
	dc_amount   f32
	dc_radius   f32
	dc_contrast f32
	// Кадрирование и поворот (в старых файлах нет: без поворота, рамка
	// пуста - весь кадр, свободная пропорция; нули своей пропорции и
	// размеров читаются как 3:2, 1920 x 1080 и 2048)
	rot90         int
	flip_h        bool
	flip_v        bool
	angle         f32
	crop          []f32 // x0, y0, x1, y1 в долях; пусто - весь кадр
	crop_aspect   string
	crop_aw       int
	crop_ah       int
	crop_portrait bool
	// Поля размера на выход (size_mode, size_w...) из сайдкаров 30.09.2026
	// json2 при чтении пропускает: размер теперь - настройка экспорта
	// Градиентные фильтры (в старых файлах нет - пусто)
	masks []SideMask
}

// SideMask - градиентный фильтр в файле (pipeline.Mask): вид строкой
// ('linear' / 'radial'), точки - доли кадра до поворота и кадрирования
struct SideMask {
	kind       string
	on         bool
	ax         f32
	ay         f32
	bx         f32
	by         f32
	rx         f32
	ry         f32
	angle      f32
	feather    f32
	invert     bool
	exposure   f32
	contrast   f32
	highlights f32
	shadows    f32
	saturation f32
	temp       f32
	tint       f32
}

fn side_mask(m pipeline.Mask) SideMask {
	return SideMask{
		kind:       if m.kind == .radial { 'radial' } else { 'linear' }
		on:         m.on
		ax:         m.ax
		ay:         m.ay
		bx:         m.bx
		by:         m.by
		rx:         m.rx
		ry:         m.ry
		angle:      m.angle
		feather:    m.feather
		invert:     m.invert
		exposure:   m.exposure
		contrast:   m.contrast
		highlights: m.highlights
		shadows:    m.shadows
		saturation: m.saturation
		temp:       m.temp
		tint:       m.tint
	}
}

// mask_of - фильтр из файла; значения правок - в пределах ползунков
fn mask_of(s SideMask) pipeline.Mask {
	c := fn (v f32, lim f32) f32 {
		return if v < -lim { -lim } else if v > lim { lim } else { v }
	}
	return pipeline.Mask{
		kind:       if s.kind == 'radial' { pipeline.MaskKind.radial } else { pipeline.MaskKind.linear }
		on:         s.on
		ax:         s.ax
		ay:         s.ay
		bx:         s.bx
		by:         s.by
		rx:         c(s.rx, 10)
		ry:         c(s.ry, 10)
		angle:      s.angle
		feather:    c(s.feather, 100)
		invert:     s.invert
		exposure:   c(s.exposure, 4)
		contrast:   c(s.contrast, 100)
		highlights: c(s.highlights, 100)
		shadows:    c(s.shadows, 100)
		saturation: c(s.saturation, 100)
		temp:       c(s.temp, 100)
		tint:       c(s.tint, 100)
	}
}

// validate - размеры массивов (испорченный или чужой файл - ошибка, а не
// выход за границы при применении)
fn (s SideState) validate() ! {
	if s.eq.len != 5 || s.hsl_hue.len != 8 || s.hsl_sat.len != 8 || s.hsl_lum.len != 8
		|| s.nr.len != 4 || s.curves.len != 4 || (s.crop.len != 0 && s.crop.len != 4) {
		return error('неверный размер массивов настроек')
	}
	// С допуском: доли у края кадра - 1 ± погрешность f32
	if s.crop.len == 4 && !(s.crop[0] >= -0.001 && s.crop[0] < s.crop[2] && s.crop[2] <= 1.001
		&& s.crop[1] >= -0.001 && s.crop[1] < s.crop[3] && s.crop[3] <= 1.001) {
		return error('неверная рамка кадрирования')
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
// Рейтинг, флажок и позиция - в начале документа (json2 пишет поля по
// порядку): ленте при открытии папки хватает первых строк файла
// (read_side_head), разбирать историю не нужно.
struct SideFile {
mut:
	app     string = 'vraw'
	version int    = sidecar_version
	rating  int // звёзды 0..5 (отбор, вне истории правок)
	flag    int // 1 - отобран, -1 - отклонён, 0 - нет
	current int
	state   SideState
	history []SideEntry
}

// Mark - пометка отбора кадра: звёзды и флажок. Не правка (в историю не
// идёт), но живёт в том же сайдкаре.
struct Mark {
	rating int // 0..5
	flag   int // 1 - отобран, -1 - отклонён, 0 - нет
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
		haze:          p.haze
		haze_depth:    p.haze_depth
		vibrance:      p.vibrance
		sharp_rgb:     p.sharp.rgb
		dc_amount:     p.sharp.dc_amount
		dc_radius:     p.sharp.dc_radius
		dc_contrast:   p.sharp.dc_contrast
		rot90:         e.geom.rot90
		flip_h:        e.geom.flip_h
		flip_v:        e.geom.flip_v
		angle:         e.geom.angle
		crop:          [e.geom.x0, e.geom.y0, e.geom.x1, e.geom.y1]
		crop_aspect:   e.crop_aspect
		crop_aw:       e.crop_aw
		crop_ah:       e.crop_ah
		crop_portrait: e.crop_portrait
		masks:         p.masks.map(side_mask(it))
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
			vibrance:      s.vibrance
			sh_shadows:    s.sh_shadows
			sh_highlights: s.sh_highlights
			haze:          s.haze
			haze_depth:    if s.haze_depth > 0 || s.haze != 0 { s.haze_depth } else { f32(25) }
			masks:         s.masks.map(mask_of(it))
			sharp:         pipeline.Sharpen{
				amount:      s.sharp_amount
				radius:      if s.sharp_radius > 0 { s.sharp_radius } else { f32(1.0) }
				detail:      s.sharp_detail
				masking:     s.sharp_masking
				rgb:         s.sharp_rgb
				dc_amount:   s.dc_amount
				dc_radius:   if s.dc_radius > 0 { s.dc_radius } else { f32(0.75) }
				dc_contrast: if s.dc_contrast > 0 || s.dc_amount > 0 {
					s.dc_contrast
				} else {
					f32(10)
				}
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
		geom:      pipeline.Geom{
			rot90:  ((s.rot90 % 4) + 4) % 4
			flip_h: s.flip_h
			flip_v: s.flip_v
			angle:  if math.abs(s.angle) <= pipeline.geom_angle_max { s.angle } else { f32(0) }
			x0:     if s.crop.len == 4 { clamp01f(s.crop[0]) } else { f32(0) }
			y0:     if s.crop.len == 4 { clamp01f(s.crop[1]) } else { f32(0) }
			x1:     if s.crop.len == 4 { clamp01f(s.crop[2]) } else { f32(1) }
			y1:     if s.crop.len == 4 { clamp01f(s.crop[3]) } else { f32(1) }
		}
		crop_aspect:   if s.crop_aspect in crop_aspects { s.crop_aspect } else { '' }
		crop_aw:       if s.crop_aw > 0 { s.crop_aw } else { 3 }
		crop_ah:       if s.crop_ah > 0 { s.crop_ah } else { 2 }
		crop_portrait: s.crop_portrait
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
	return encode_history(st.history, st.hist_pos, st.mark)
}

// encode_history - история и текущая позиция как JSON-документ сайдкара
// (и для кадра, который не открыт: вставка настроек, presets.v)
fn encode_history(history []HistEntry, pos int, mark Mark) string {
	mut f := SideFile{
		rating:  mark.rating
		flag:    mark.flag
		state:   side_state(history[pos].state)
		current: pos
	}
	for h in history {
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
	mark    Mark
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
		mark:    clamp_mark(f.rating, f.flag)
	}
}

// clamp_mark - пометка из файла в допустимых пределах
fn clamp_mark(rating int, flag int) Mark {
	return Mark{
		rating: if rating < 0 { 0 } else if rating > 5 { 5 } else { rating }
		flag:   if flag > 0 { 1 } else if flag < 0 { -1 } else { 0 }
	}
}

// SideHead - начало сайдкара для ленты: пометка и есть ли правки
// (current > 0 - настройки отличаются от «Открыт файл»)
struct SideHead {
	mark   Mark
	edited bool
}

// SideMarks - то же полным разбором (сайдкары до 03.10.2026: «current»
// стоял после настроек); остальные поля json2 пропускает
struct SideMarks {
	app     string
	rating  int
	flag    int
	current int
}

// head_int - целое значение ключа «"key": N» в начале JSON
fn head_int(head string, key string) ?int {
	k := '"${key}":'
	i := head.index(k) or { return none }
	mut j := i + k.len
	for j < head.len && head[j] == ` ` {
		j++
	}
	mut e := j
	if e < head.len && head[e] == `-` {
		e++
	}
	for e < head.len && head[e] >= `0` && head[e] <= `9` {
		e++
	}
	if e == j || (e == j + 1 && head[j] == `-`) || e >= head.len {
		return none // число могло оборваться на краю прочитанного
	}
	return head[j..e].int()
}

// read_side_head - пометка и признак правок кадра по его сайдкару:
// первые полкилобайта (~20 мкс), у старого файла - полный разбор
// (~0.6 мс на 100 КБ). Нет файла или он испорчен - без пометки и правок.
fn read_side_head(raw_path string) SideHead {
	path := sidecar_path(raw_path)
	mut f := os.open(path) or { return SideHead{} }
	mut buf := []u8{len: 512}
	n := f.read(mut buf) or { 0 }
	f.close()
	head := buf[..n].bytestr()
	if head.contains('"app": "vraw"') {
		if cur := head_int(head, 'current') {
			return SideHead{
				mark:   clamp_mark(head_int(head, 'rating') or { 0 }, head_int(head, 'flag') or { 0 })
				edited: cur > 0
			}
		}
	}
	text := os.read_file(path) or { return SideHead{} }
	m := json2.decode[SideMarks](text) or { return SideHead{} }
	if m.app != 'vraw' {
		return SideHead{}
	}
	return SideHead{
		mark:   clamp_mark(m.rating, m.flag)
		edited: m.current > 0
	}
}

// write_mark - пометка кадра, который не открыт: в его сайдкар (нет
// сайдкара - новый с одной записью «Открыт файл»); испорченный сайдкар
// не перезаписывается
fn write_mark(raw_path string, mark Mark) ! {
	side := sidecar_path(raw_path)
	loaded := load_sidecar(side) or { return error('сайдкар не прочитан (${err.msg()})') }
	if loaded.history.len == 0 {
		if mark == Mark{} {
			return // сайдкара нет и пометки нет - писать нечего
		}
		write_atomic(side, encode_history([HistEntry{
			name:  'Открыт файл'
			state: neutral_edit()
		}], 0, mark))!
		return
	}
	if loaded.mark == mark {
		return
	}
	write_atomic(side, encode_history(loaded.history, loaded.current, mark))!
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

// sync_sidecar записывает историю и пометку в сайдкар (после правки,
// перехода или пометки). Только что открытый файл без правок и пометки
// сайдкар не создаёт; если сайдкар
// уже есть - он обновляется всегда (откат к «Открыт файл» тоже правка
// состояния). Запись атомарная: временный файл + переименование, чтобы
// сбой посреди записи не оставил обрезанный JSON. Ошибка записи
// (папка только для чтения) показывается один раз на файл.
fn sync_sidecar(mut st State) {
	if st.side_path.len == 0 || st.history.len == 0 {
		return
	}
	// Без правок и пометки сайдкар не создаётся
	if st.history.len == 1 && st.mark == Mark{} && !os.exists(st.side_path) {
		return
	}
	write_atomic(st.side_path, encode_sidecar(st)) or {
		sidecar_error(mut st, err)
		return
	}
	mark_edited(mut st) // отметка «изменён» на миниатюре ленты (при правках)
	sync_thumb(mut st) // кадрирование и поворот - на миниатюре
}

// write_atomic - запись через временный файл и переименование: сбой
// посреди записи не оставит обрезанный файл
fn write_atomic(path string, text string) ! {
	tmp := path + '.tmp'
	os.write_file(tmp, text)!
	os.mv(tmp, path) or {
		os.rm(tmp) or {}
		return err
	}
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

fn clamp01f(v f32) f32 {
	return if v < 0 { 0 } else if v > 1 { 1 } else { v }
}

// with_derived заполняет производные поля снимка: камерную кривую
// кадра (при use_curve), силу коррекции виньетирования, таблицы кривых из
// точек и матрицу баланса белого по цвету камеры кадра. Нужна снимкам из файла - иначе
// сравнение с живым st.edit (record) всегда давало бы «изменилось».
fn with_derived(e EditState, look CamLook, cam pipeline.CamColor) EditState {
	mut d := e.clone()
	d.params.curve = if e.use_curve { look.curve.clone() } else { []f32{} }
	d.params.cam_sat = if e.use_curve && look.curve.len > 0 { look.sat } else { f32(1) }
	d.params.cam_hue = if e.use_curve && look.curve.len > 0 { look.hue.clone() } else { []f32{} }
	d.params.cam_hsat = if e.use_curve && look.curve.len > 0 { look.hsat.clone() } else { []f32{} }
	d.vign = look.vign
	d.lens_zoom = look.zoom
	d.params.tc_rgb = tone_lut(e.curve_pts[0])
	d.params.tc_r = tone_lut(e.curve_pts[1])
	d.params.tc_g = tone_lut(e.curve_pts[2])
	d.params.tc_b = tone_lut(e.curve_pts[3])
	wb_derive(mut d, cam)
	return d
}
