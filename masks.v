module main

// Градиентные фильтры (pipeline/local.v): секция «Градиентные фильтры»,
// ручки на холсте, показ маски заливкой.
//
// Фильтры кадра - в EditState (params.masks: история, сайдкар, вставка
// настроек), точки - в долях кадра до поворота и кадрирования: фильтр
// «приклеен» к снимку. Выделенный фильтр (st.mask_sel, не правка) - его
// ползунки в секции и ручки на холсте: линейный - точки начала (полное
// действие) и конца перехода, середина - перенос; радиальный - центр
// (перенос) и концы полуосей (размер и поворот). Каждое отпускание ручки -
// запись в истории. Esc - снять выделение (ручки исчезают). Заливка маски
// (O, «Вид - Маска фильтра») - красным поверх снимка, вес выделенного.
//
// Холст показывает буфер gw x gh после геометрии; отображение его пикселя
// в кадр - view_map (то же, что получает пайплайн), обратное - для ручек.
import math
import vgui
import pipeline
import i18n

const mask_handle_px = f32(9) // радиус захвата ручки на экране
const mask_line = vgui.Color{255, 255, 255, 230}
const mask_soft = vgui.Color{255, 255, 255, 110}
const mask_dark = vgui.Color{0, 0, 0, 170}
const mask_pin = vgui.Color{255, 214, 10, 255}
// Метки частей выделенного фильтра - по операции: добавить, вычесть,
// пересечь
const part_colors = [vgui.Color{90, 210, 120, 255}, vgui.Color{240, 90, 90, 255},
	vgui.Color{90, 170, 250, 255}]
// Заливка маски: красный с непрозрачностью по весу (до mask_fill_a)
const mask_fill_a = f32(0.55)

enum MaskDragKind {
	none
	a    // линейный: начало перехода
	b    // линейный: конец перехода
	move // перенос: середина линейного, центр радиального
	axis // радиальный: конец полуоси (sign - какой конец, ry - вторая ось)
}

struct MaskDrag {
mut:
	kind  MaskDragKind
	ry    bool // радиальный: ось ry (иначе rx)
	sign  f64  // конец оси: +1 / -1
	start pipeline.MaskPart // форма до перетаскивания (основа или часть)
	px    f64 // точка нажатия в единицах кадра (view_map)
	py    f64
	moved bool
}

// MaskUi - виджеты секции (sync_mask_ui выставляет их из st.edit)
@[heap]
struct MaskUi {
mut:
	sel_cb   &vgui.ComboBox = unsafe { nil } // выбор фильтра: 0 - не выбран
	// Части: выбор формы (0 - основа), удаление части, новая часть,
	// операция выделенной части
	form_cb  &vgui.ComboBox = unsafe { nil }
	pdel_btn &vgui.Button   = unsafe { nil }
	padd_cb  &vgui.ComboBox = unsafe { nil }
	op_cb    &vgui.ComboBox = unsafe { nil }
	brush_sl []&vgui.Slider // настройки кисти (включены, когда выделена кисть)
	auto_cb  &vgui.CheckBox = unsafe { nil } // автомаска кисти
	on_btn   &vgui.Button   = unsafe { nil }
	del_btn  &vgui.Button   = unsafe { nil }
	done_btn &vgui.Button   = unsafe { nil }
	show_cb  &vgui.CheckBox = unsafe { nil }
	inv_cb   &vgui.CheckBox = unsafe { nil }
	sliders  []&vgui.Slider // правки выделенного (без фильтра - выключены)
	feather  &vgui.Slider = unsafe { nil } // только у радиального
	// Ограничение диапазоном: режим, ползунки яркости и цвета (включены по
	// режиму), пипетка цвета
	range_cb &vgui.ComboBox = unsafe { nil }
	lum_sl   []&vgui.Slider
	col_sl   []&vgui.Slider
	pick_btn &vgui.Button   = unsafe { nil }
	m_show   &vgui.MenuItem = unsafe { nil }
	name_in  &vgui.TextInput = unsafe { nil } // имя выделенного (Enter)
	// Аккордеон панели и индекс секции «Градиентные фильтры»: раскрытая
	// секция показывает метки фильтров и без выделения
	acc     &vgui.Accordion = unsafe { nil }
	acc_idx int = -1
	// Настройки выделенной формы - свой контейнер, пересобирается по виду
	// (у vgui VBox/HBox нет visible): кисть - размер, мягкость, сила,
	// автомаска; радиальная - размер, поворот, растушёвка, снаружи;
	// линейная и без выделения - пусто
	shape_box   &vgui.VBox = unsafe { nil }
	brush_rows  []&vgui.Widget
	radial_rows []&vgui.Widget
	shape_shown int = -2 // показанный набор: -1 - пусто, 0 - кисть, 1 - радиальная
}

// ── Отображение холст <-> кадр ──

// view_map - пиксель буфера холста (gw x gh) -> кадр (pipeline.mask_map)
fn view_map(st &State) pipeline.MaskMap {
	return pipeline.mask_map(st.edit.geom, st.pw, st.ph, !st.crop_mode, st.gw, st.gh)
}

// with_lmap - параметры с отображением фильтров под буфер (копия: в
// st.edit отображение не пишется - оно не правка)
fn with_lmap(p pipeline.Params, mm pipeline.MaskMap) pipeline.Params {
	if p.masks.len == 0 {
		return p
	}
	mut q := p
	q.lmap = mm
	return q
}

// view_params - параметры превью (буфер холста gw x gh)
fn view_params(st &State, p pipeline.Params) pipeline.Params {
	if p.masks.len == 0 || st.pw <= 0 || st.ph <= 0 {
		return p
	}
	return with_lmap(p, view_map(st))
}

// buf_to_m - точка холста (пиксели буфера, непрерывно) -> единицы кадра
fn buf_to_m(mm pipeline.MaskMap, bx f64, by f64) (f64, f64) {
	i := bx - 0.5
	j := by - 0.5
	return mm.a * i + mm.b * j + mm.c, mm.d * i + mm.e * j + mm.f
}

// m_to_buf - обратно (отображение аффинное, невырожденное)
fn m_to_buf(mm pipeline.MaskMap, x f64, y f64) (f64, f64) {
	det := mm.a * mm.e - mm.b * mm.d
	if math.abs(det) < 1e-18 {
		return 0, 0
	}
	dx := x - mm.c
	dy := y - mm.f
	return (mm.e * dx - mm.b * dy) / det + 0.5, (-mm.d * dx + mm.a * dy) / det + 0.5
}

// MaskPts - точки фильтра в единицах кадра: линейный - a, b, середина;
// радиальный - центр (a) и концы полуосей (u - ось rx, v - ось ry)
struct MaskPts {
	ax f64
	ay f64
	bx f64
	by f64
	ux f64 // радиальный: вектор полуоси rx
	uy f64
	vx f64 // полуоси ry
	vy f64
}

fn mask_pts(m pipeline.MaskPart, ar f64) MaskPts {
	a := f64(m.angle) * math.pi / 180
	cs := math.cos(a)
	sn := math.sin(a)
	return MaskPts{
		ax: f64(m.ax) * ar
		ay: f64(m.ay)
		bx: f64(m.bx) * ar
		by: f64(m.by)
		ux: f64(m.rx) * cs
		uy: f64(m.rx) * sn
		vx: -f64(m.ry) * sn
		vy: f64(m.ry) * cs
	}
}

// ── Выделение и правки ──

fn mask_valid(st &State) bool {
	return st.mask_sel >= 0 && st.mask_sel < st.edit.params.masks.len
}

// mask_active - ручки на холсте: есть выделенный фильтр, кадр проявлен,
// не кадрирование и не JPEG камеры
fn mask_active(st &State) bool {
	return mask_valid(st) && mask_canvas(st)
}

// mask_canvas - на холсте можно показывать фильтры: кадр проявлен, не
// кадрирование и не JPEG камеры
fn mask_canvas(st &State) bool {
	return !st.crop_mode && st.linear.len > 0 && !jpeg_active(st) && !isnil(st.cv)
}

// mask_pins_only - фильтр не выделен, но секция «Градиентные фильтры»
// раскрыта: на снимке метки всех фильтров, щелчок по метке выделяет
fn mask_pins_only(st &State) bool {
	if mask_valid(st) || st.edit.params.masks.len == 0 || !mask_canvas(st)
		|| isnil(st.mask_ui) {
		return false
	}
	u := st.mask_ui
	return !isnil(u.acc) && u.acc.is_expanded(u.acc_idx)
}

// kind_name - вид фильтра для списка: «Линейный», «Радиальный», «Кисть»
fn kind_name(k pipeline.MaskKind) string {
	return match k {
		.radial { i18n.tr('Радиальный') }
		.brush { i18n.tr('Кисть') }
		.linear { i18n.tr('Линейный') }
	}
}

// mask_name - строка списка фильтров: имя (или вид), число частей,
// «выкл»
fn mask_name(m pipeline.Mask, i int) string {
	kind := if m.name != '' { m.name } else { kind_name(m.kind) }
	off := if m.on { '' } else { i18n.tr('  (выкл)') }
	parts := if m.parts.len > 0 { ' +${m.parts.len}' } else { '' }
	return '${i + 1}. ${kind}${parts}${off}'
}

// select_mask - выделить фильтр idx (-1 - снять выделение)
fn select_mask(mut st State, idx int) {
	st.mask_sel = if idx >= 0 && idx < st.edit.params.masks.len { idx } else { -1 }
	if st.mask_sel >= 0 && st.spot_mode {
		set_spot_mode(mut st, false)
	}
	st.mask_part = -1
	st.mask_drag = MaskDrag{}
	if st.mask_pick {
		set_mask_pick(mut st, false)
	}
	sync_mask_ui(mut st)
	if st.mask_show && !isnil(st.tone_fx) {
		st.tone_fx() // заливка - другого фильтра
	}
	mask_redraw(st)
}

// mask_redraw - перерисовать оверлей холста (ручки, метки, круг кисти):
// только область холста в окне, без перезаливки текстуры снимка
// (mark_dirty - полный буфер превью в видеокарту на каждое движение мыши)
fn mask_redraw(st &State) {
	if isnil(st.cv) {
		return
	}
	if isnil(st.win) {
		mut cv := st.cv
		cv.mark_dirty()
		return
	}
	mut w := st.win
	w.invalidate(st.cv.bounds)
}

// mask_changed - правка фильтров: пересчёт и запись в истории
fn mask_changed(mut st State, key string, name string) {
	sync_mask_ui(mut st)
	if !isnil(st.tone_fx) {
		st.tone_fx()
	}
	record(mut st, key, name, false)
	mask_redraw(st)
}

// default_shape - новая форма по виду холста: линейная - переход с 10%
// до 50% высоты кадра на экране (небо), радиальная - эллипс по центру.
// Часть (part) - в стороне от основы, чтобы метки не совпали с ручками:
// линейная - снизу вверх (с 90% до 60%), радиальная - центр на 62%
fn default_shape(st &State, kind pipeline.MaskKind, part bool) pipeline.MaskPart {
	mm := view_map(st)
	w := f64(st.gw)
	h := f64(st.gh)
	mut m := pipeline.MaskPart{
		kind: kind
	}
	if kind == .linear {
		ax, ay := buf_to_m(mm, w / 2, h * if part { 0.9 } else { 0.1 })
		bx, by := buf_to_m(mm, w / 2, h * if part { 0.6 } else { 0.5 })
		m.ax = f32(ax / mm.ar)
		m.ay = f32(ay)
		m.bx = f32(bx / mm.ar)
		m.by = f32(by)
	} else {
		yc := h * if part { 0.62 } else { 0.5 }
		cx, cy := buf_to_m(mm, w / 2, yc)
		ux, uy := buf_to_m(mm, w / 2 + w * 0.25, yc)
		vx, vy := buf_to_m(mm, w / 2, yc + h * 0.3)
		m.ax = f32(cx / mm.ar)
		m.ay = f32(cy)
		m.rx = f32(math.hypot(ux - cx, uy - cy))
		m.ry = f32(math.hypot(vx - cx, vy - cy))
		m.angle = f32(math.atan2(uy - cy, ux - cx) * 180 / math.pi)
	}
	return m
}

// add_mask - новый фильтр по виду холста (default_shape)
fn add_mask(mut st State, kind pipeline.MaskKind) {
	if st.linear.len == 0 || st.gw <= 0 {
		return
	}
	if st.crop_mode {
		set_crop_mode(mut st, false)
	}
	mut m := pipeline.Mask{
		kind: kind
	}
	if kind != .brush {
		m.set_shape(-1, default_shape(st, kind, false))
	}
	if st.spot_mode {
		set_spot_mode(mut st, false)
	}
	st.edit.params.masks << m
	st.mask_sel = st.edit.params.masks.len - 1
	st.mask_part = -1
	name := match kind {
		.radial { i18n.tr('радиальный') }
		.brush { i18n.tr('кисть') }
		.linear { i18n.tr('линейный') }
	}
	mask_changed(mut st, 'mask_add', i18n.trf('Фильтр: добавлен {0}', '${name}'))
}

// ── Части фильтра (сложение масок) ──

const mask_ops = ['Добавить', 'Вычесть', 'Пересечь']

// PartAdd - пункт «Новая часть»: подпись, вид и операция
struct PartAdd {
	label string
	kind  pipeline.MaskKind
	op    pipeline.MaskOp
}

// Пункты «Новая часть» (0 - подсказка, не действие)
const part_adds = [
	PartAdd{'Новая часть', .linear, .add},
	PartAdd{'Вычесть: радиальную', .radial, .subtract},
	PartAdd{'Вычесть: линейную', .linear, .subtract},
	PartAdd{'Вычесть: кистью (ластик)', .brush, .subtract},
	PartAdd{'Добавить: радиальную', .radial, .add},
	PartAdd{'Добавить: линейную', .linear, .add},
	PartAdd{'Добавить: кистью', .brush, .add},
	PartAdd{'Пересечь: радиальной', .radial, .intersect},
	PartAdd{'Пересечь: линейной', .linear, .intersect},
]

fn op_index(op pipeline.MaskOp) int {
	return match op {
		.add { 0 }
		.subtract { 1 }
		.intersect { 2 }
	}
}

fn op_of(i int) pipeline.MaskOp {
	return match i {
		0 { pipeline.MaskOp.add }
		2 { pipeline.MaskOp.intersect }
		else { pipeline.MaskOp.subtract }
	}
}

fn kind_word(k pipeline.MaskKind) string {
	return match k {
		.radial { i18n.tr('радиальная') }
		.brush { i18n.tr('кисть') }
		.linear { i18n.tr('линейная') }
	}
}

// shape_names - пункты выбора формы выделенного фильтра
fn shape_names(m pipeline.Mask) []string {
	mut names := [i18n.trf('Основа: {0}', '${kind_word(m.kind)}')]
	for i, pt in m.parts {
		names << '${i + 1}. ${i18n.tr(mask_ops[op_index(pt.op)])}: ${kind_word(pt.kind)}'
	}
	return names
}

// shape_label - выделенная форма для истории: «Фильтр 2» или «Фильтр 2,
// часть 1»
fn shape_label(st &State) string {
	if st.mask_part < 0 {
		return i18n.trf('Фильтр {0}', '${st.mask_sel + 1}')
	}
	return i18n.trf('Фильтр {0}, часть {1}', '${st.mask_sel + 1}', '${st.mask_part + 1}')
}

// select_part - выделить форму выделенного фильтра (-1 - основа)
fn select_part(mut st State, idx int) {
	if !mask_valid(st) {
		return
	}
	n := st.edit.params.masks[st.mask_sel].parts.len
	st.mask_part = if idx >= 0 && idx < n { idx } else { -1 }
	st.mask_drag = MaskDrag{}
	sync_mask_ui(mut st)
	mask_redraw(st)
}

// add_part - новая часть выделенного фильтра (по виду холста) и её выделение
fn add_part(mut st State, kind pipeline.MaskKind, op pipeline.MaskOp) {
	if !mask_valid(st) || st.gw <= 0 {
		return
	}
	mut s := if kind == .brush {
		pipeline.MaskPart{
			kind: .brush
		}
	} else {
		default_shape(st, kind, true)
	}
	s.op = op
	mut m := st.edit.params.masks[st.mask_sel].copy()
	m.parts << s
	st.edit.params.masks[st.mask_sel] = m
	st.mask_part = m.parts.len - 1
	mask_changed(mut st, 'mask_part', '${shape_label(st)}: ${i18n.tr(mask_ops[op_index(op)]).to_lower()} ${kind_word(kind)}')
}

// delete_part - удалить выделенную часть (основу удаляет delete_mask)
fn delete_part(mut st State) {
	if !mask_valid(st) || st.mask_part < 0 {
		return
	}
	label := shape_label(st)
	mut m := st.edit.params.masks[st.mask_sel].copy()
	if st.mask_part >= m.parts.len {
		return
	}
	m.parts.delete(st.mask_part)
	st.edit.params.masks[st.mask_sel] = m
	st.mask_part = -1
	mask_changed(mut st, 'mask_part_del', i18n.trf('{0}: удалена', '${label}'))
}

// set_part_op - операция выделенной части
fn set_part_op(mut st State, op pipeline.MaskOp) {
	if !mask_valid(st) || st.mask_part < 0
		|| st.mask_part >= st.edit.params.masks[st.mask_sel].parts.len {
		return
	}
	if st.edit.params.masks[st.mask_sel].parts[st.mask_part].op == op {
		return
	}
	mut m := st.edit.params.masks[st.mask_sel].copy()
	m.parts[st.mask_part].op = op
	st.edit.params.masks[st.mask_sel] = m
	mask_changed(mut st, 'mask_part_op', '${shape_label(st)}: ${i18n.tr(mask_ops[op_index(op)]).to_lower()}')
}

fn delete_mask(mut st State) {
	if !mask_valid(st) {
		return
	}
	st.edit.params.masks.delete(st.mask_sel)
	if st.mask_sel >= st.edit.params.masks.len {
		st.mask_sel = st.edit.params.masks.len - 1
	}
	st.mask_part = -1
	mask_changed(mut st, 'mask_del', i18n.tr('Фильтр: удалён'))
}

// mask_name_max - длина имени фильтра, символов
const mask_name_max = 40

// clean_mask_name - имя фильтра без переводов строк и пробелов по краям,
// не длиннее mask_name_max
fn clean_mask_name(s string) string {
	mut r := s.replace_each(['\r', ' ', '\n', ' ', '\t', ' ']).trim_space().runes()
	if r.len > mask_name_max {
		r = r[..mask_name_max].clone()
	}
	return r.string().trim_space()
}

// rename_mask - имя выделенного фильтра (пусто - снова по виду)
fn rename_mask(mut st State, text string) {
	if !mask_valid(st) {
		return
	}
	i := st.mask_sel
	name := clean_mask_name(text)
	if name == st.edit.params.masks[i].name {
		sync_mask_ui(mut st)
		return
	}
	st.edit.params.masks[i].name = name
	what := if name == '' { i18n.tr('имя по виду') } else { i18n.trf('имя «{0}»', '${name}') }
	mask_changed(mut st, 'mask_name', i18n.trf('Фильтр {0}: {1}', '${i + 1}', '${what}'))
}

fn toggle_mask(mut st State) {
	if !mask_valid(st) {
		return
	}
	i := st.mask_sel
	st.edit.params.masks[i].on = !st.edit.params.masks[i].on
	mask_changed(mut st, 'mask_on', i18n.trf('Фильтр {0}: {1}', '${i + 1}', '${on_off(st.edit.params.masks[i].on)}'))
}

// set_mask_show - заливка маски выделенного фильтра (вид, не правка)
fn set_mask_show(mut st State, on bool) {
	st.mask_show = on
	sync_mask_show_ui(mut st)
	if !isnil(st.tone_fx) {
		st.tone_fx()
	}
}

// sync_mask_show_ui - флажок секции («Скрыть маску») и пункт меню по
// st.mask_show
fn sync_mask_show_ui(mut st State) {
	if !isnil(st.mask_ui) {
		mut u := st.mask_ui
		if !isnil(u.show_cb) {
			u.show_cb.set_checked(!st.mask_show)
		}
		if !isnil(u.m_show) {
			u.m_show.checked = st.mask_show
		}
	}
}

// mask_paint - заливка маски выделенного фильтра поверх снимка (RGBA
// буфер холста gw x gh, после гистограммы - она по снимку)
fn mask_paint(st &State, mut pix []u8) {
	if !st.mask_show || !mask_active(st) || pix.len != st.gw * st.gh * 4 {
		return
	}
	if st.glin.len != st.gw * st.gh * 3 {
		return
	}
	// Вес с ограничением диапазоном - тем же проходом, что снимок (дымка, ББ)
	haze := if st.edit.params.haze != 0 && st.haze.d.len == st.gw * st.gh {
		&st.haze
	} else {
		unsafe { &pipeline.HazeMap(nil) }
	}
	wt := pipeline.mask_view(unsafe { &u16(st.glin.data) }, haze, st.gw, st.gh, view_params(st,
		st.edit.params), st.mask_sel)
	pipeline.mask_fill(wt, mut pix, 4, st.gw, st.gh, mask_fill_a)
}

// ── Ручки на холсте ──

// MaskHandle - ручка выделенного фильтра на экране
struct MaskHandle {
	kind MaskDragKind
	ry   bool
	sign f64
	x    f32
	y    f32
}

// m_to_screen - точка кадра -> экран холста
fn m_to_screen(st &State, mm pipeline.MaskMap, x f64, y f64) (f32, f32) {
	bx, by := m_to_buf(mm, x, y)
	return st.cv.buf_to_screen(f32(bx), f32(by))
}

fn mask_handles(st &State, mm pipeline.MaskMap) []MaskHandle {
	m := st.edit.params.masks[st.mask_sel].shape(st.mask_part)
	mut hs := []MaskHandle{}
	if m.kind == .brush {
		return hs // кисть рисуется, ручек нет
	}
	p := mask_pts(m, mm.ar)
	if m.kind == .linear {
		ax, ay := m_to_screen(st, mm, p.ax, p.ay)
		bx, by := m_to_screen(st, mm, p.bx, p.by)
		hs << MaskHandle{.a, false, 0, ax, ay}
		hs << MaskHandle{.b, false, 0, bx, by}
		hs << MaskHandle{.move, false, 0, (ax + bx) / 2, (ay + by) / 2}
		return hs
	}
	for s in [1.0, -1.0] {
		ux, uy := m_to_screen(st, mm, p.ax + s * p.ux, p.ay + s * p.uy)
		hs << MaskHandle{.axis, false, s, ux, uy}
		vx, vy := m_to_screen(st, mm, p.ax + s * p.vx, p.ay + s * p.vy)
		hs << MaskHandle{.axis, true, s, vx, vy}
	}
	cx, cy := m_to_screen(st, mm, p.ax, p.ay)
	hs << MaskHandle{.move, false, 0, cx, cy}
	return hs
}

// mask_hit - ручка под курсором (экран) или none
fn mask_hit(st &State, mm pipeline.MaskMap, sx f32, sy f32) MaskHandle {
	for h in mask_handles(st, mm) {
		if math.abs(h.x - sx) <= mask_handle_px && math.abs(h.y - sy) <= mask_handle_px {
			return h
		}
	}
	return MaskHandle{}
}

// shape_anchor - точка метки формы в единицах кадра: центр радиальной,
// начало линейной, начало первого мазка кисти; false - пустая кисть
fn shape_anchor(o pipeline.MaskPart, ar f64) (f64, f64, bool) {
	if o.kind == .brush {
		if o.strokes.len == 0 || o.strokes[0].pts.len < 2 {
			return 0, 0, false
		}
		return f64(o.strokes[0].pts[0]) * ar, f64(o.strokes[0].pts[1]), true
	}
	return f64(o.ax) * ar, f64(o.ay), true
}

// brush_selected - выделенная форма - кисть (холст рисует)
fn brush_selected(st &State) bool {
	return mask_active(st) && st.edit.params.masks[st.mask_sel].shape(st.mask_part).kind == .brush
}

// shape_pin_hit - метка невыделенной формы выделенного фильтра под
// курсором: -1 - основа, иначе часть; -2 - нет
fn shape_pin_hit(st &State, mm pipeline.MaskMap, sx f32, sy f32) int {
	m := st.edit.params.masks[st.mask_sel]
	for k in -1 .. m.parts.len {
		if k == st.mask_part {
			continue
		}
		ox, oy, ok := shape_anchor(m.shape(k), mm.ar)
		if !ok {
			continue
		}
		qx, qy := m_to_screen(st, mm, ox, oy)
		if math.abs(qx - sx) <= mask_handle_px && math.abs(qy - sy) <= mask_handle_px {
			return k
		}
	}
	return -2
}

// pin_hit - метка невыделенного фильтра под курсором (щелчок выделяет)
fn pin_hit(st &State, mm pipeline.MaskMap, sx f32, sy f32) int {
	for i, m in st.edit.params.masks {
		if i == st.mask_sel {
			continue
		}
		ox, oy, ok := shape_anchor(m.shape(-1), mm.ar)
		if !ok {
			continue
		}
		qx, qy := m_to_screen(st, mm, ox, oy)
		if math.abs(qx - sx) <= mask_handle_px && math.abs(qy - sy) <= mask_handle_px {
			return i
		}
	}
	return -1
}

// mask_input - мышь на холсте при выделенном фильтре; true - обработано
fn mask_input(mut st State, ev &vgui.CanvasInputEvent) bool {
	if mask_pins_only(st) {
		return pins_input(mut st, ev)
	}
	if !mask_active(st) {
		return false
	}
	cv := st.cv
	mm := view_map(st)
	sx, sy := cv.buf_to_screen(ev.fx, ev.fy)
	match ev.kind {
		.hover {
			if st.mask_pick {
				return false
			}
			brush := brush_selected(st)
			if brush {
				// Круг кисти под курсором (mask_overlay)
				st.brush_hover = true
				st.brush_hx = ev.fx
				st.brush_hy = ev.fy
				mask_redraw(st)
			}
			// Курсор фильтра - событие забрано: иначе шторка до/после
			// (ba_input) поставит поверх свой
			h := mask_hit(st, mm, sx, sy)
			if h.kind != .none {
				vgui.set_cursor(if h.kind == .move {
					vgui.sdl_system_cursor_sizeall
				} else {
					vgui.sdl_system_cursor_crosshair
				})
				return true
			} else if shape_pin_hit(st, mm, sx, sy) > -2 || pin_hit(st, mm, sx, sy) >= 0 {
				vgui.set_cursor(vgui.sdl_system_cursor_hand)
				return true
			} else if brush {
				vgui.set_cursor(vgui.sdl_system_cursor_crosshair)
				return true
			}
			return false
		}
		.leave {
			// Курсор фильтра за холстом не остаётся
			vgui.set_cursor(vgui.sdl_system_cursor_default)
			if st.brush_hover {
				st.brush_hover = false
				mask_redraw(st)
			}
			return false
		}
		.pointer_down {
			if ev.button != 1 {
				return false
			}
			if st.mask_pick {
				if ev.in_image {
					mask_pick_at(mut st, ev.x, ev.y)
				}
				return true
			}
			h := mask_hit(st, mm, sx, sy)
			if h.kind == .none {
				sp := shape_pin_hit(st, mm, sx, sy)
				if sp > -2 {
					select_part(mut st, sp)
					return true
				}
				pin := pin_hit(st, mm, sx, sy)
				if pin >= 0 {
					select_mask(mut st, pin)
					return true
				}
				if brush_selected(st) {
					brush_begin(mut st, mm, ev.fx, ev.fy)
					return true
				}
				return false
			}
			qx, qy := buf_to_m(mm, ev.fx, ev.fy)
			st.mask_drag = MaskDrag{
				kind:  h.kind
				ry:    h.ry
				sign:  h.sign
				start: st.edit.params.masks[st.mask_sel].shape(st.mask_part)
				px:    qx
				py:    qy
			}
			return true
		}
		.pointer_move {
			if st.brush_paint {
				st.brush_hx = ev.fx
				st.brush_hy = ev.fy
				brush_extend(mut st, mm, ev.fx, ev.fy)
				return true
			}
			d := st.mask_drag
			if d.kind == .none {
				return false
			}
			x, y := buf_to_m(mm, ev.fx, ev.fy)
			st.edit.params.masks[st.mask_sel].set_shape(st.mask_part, drag_mask(d, x, y, mm.ar))
			st.mask_drag.moved = true
			defer_fx(mut st, st.tone_fx)
			return true
		}
		.pointer_up {
			if st.brush_paint {
				st.brush_paint = false
				mask_changed(mut st, 'mask_stroke', i18n.trf('{0}: мазок', '${shape_label(st)}'))
				return true
			}
			d := st.mask_drag
			st.mask_drag = MaskDrag{}
			if d.kind == .none {
				return false
			}
			if d.moved {
				name := match d.kind {
					.move { i18n.tr('перенос') }
					.axis { i18n.tr('размер') }
					else { i18n.tr('переход') }
				}
				mask_changed(mut st, 'mask_shape', '${shape_label(st)}: ${name}')
			}
			return true
		}
		else {}
	}
	return false
}

// pins_input - мышь на холсте, когда видны только метки фильтров:
// указатель-рука над меткой, щелчок выделяет фильтр
fn pins_input(mut st State, ev &vgui.CanvasInputEvent) bool {
	cv := st.cv
	mm := view_map(st)
	sx, sy := cv.buf_to_screen(ev.fx, ev.fy)
	match ev.kind {
		.hover {
			if pin_hit(st, mm, sx, sy) >= 0 {
				vgui.set_cursor(vgui.sdl_system_cursor_hand)
				return true
			}
		}
		.leave {
			vgui.set_cursor(vgui.sdl_system_cursor_default)
		}
		.pointer_down {
			if ev.button == 1 {
				pin := pin_hit(st, mm, sx, sy)
				if pin >= 0 {
					select_mask(mut st, pin)
					return true
				}
			}
		}
		else {}
	}
	return false
}

// draw_pins - метки фильтров (кроме выделенного): кружок в начале основы
fn draw_pins(mut ctx vgui.RenderContext, st &State, mm pipeline.MaskMap) {
	for i, o in st.edit.params.masks {
		if i == st.mask_sel {
			continue
		}
		ox, oy, ok := shape_anchor(o.shape(-1), mm.ar)
		if !ok {
			continue
		}
		qx, qy := m_to_screen(st, mm, ox, oy)
		ctx.fill_circle(qx, qy, 5.5, mask_dark)
		ctx.draw_circle(qx, qy, 4, mask_line)
	}
}

// ── Кисть ──

// brush_radius - радиус кисти в долях высоты кадра по ползунку «Размер»
// (1..100 -> до четверти высоты; квадрат - мелкие размеры точнее)
fn brush_radius(st &State) f32 {
	k := st.brush_size / 100
	return 0.003 + 0.25 * k * k
}

// brush_color - цвет под центром кисти для автомаски: среднее пятна 5x5
// сырья холста (glin - тот же буфер, что видит рендер, до ББ и дымки)
fn brush_color(st &State, fx f32, fy f32) []f32 {
	mut sum := [f64(0), 0, 0]
	mut n := 0
	if st.glin.len == st.gw * st.gh * 3 {
		cx := int(fx)
		cy := int(fy)
		for y in cy - 2 .. cy + 3 {
			for x in cx - 2 .. cx + 3 {
				if x < 0 || y < 0 || x >= st.gw || y >= st.gh {
					continue
				}
				i := (y * st.gw + x) * 3
				for c in 0 .. 3 {
					sum[c] += f64(st.glin[i + c])
				}
				n++
			}
		}
	}
	if n == 0 {
		return [f32(0), 0, 0]
	}
	return [f32(sum[0] / n), f32(sum[1] / n), f32(sum[2] / n)]
}

// brush_begin - новый мазок выделенной кисти в точке (fx, fy) буфера
fn brush_begin(mut st State, mm pipeline.MaskMap, fx f32, fy f32) {
	x, y := buf_to_m(mm, fx, fy)
	mut sh := st.edit.params.masks[st.mask_sel].shape(st.mask_part)
	sh.strokes << pipeline.Stroke{
		pts:     [f32(x / mm.ar), f32(y)]
		radius:  brush_radius(st)
		feather: st.brush_feather
		flow:    st.brush_flow / 100
		cols:    brush_color(st, fx, fy)
	}
	st.edit.params.masks[st.mask_sel].set_shape(st.mask_part, sh)
	st.brush_paint = true
	defer_fx(mut st, st.tone_fx)
}

// brush_extend - продолжить мазок до (fx, fy): точка добавляется, если
// курсор ушёл дальше четверти радиуса (покрытие - по расстоянию до
// ломаной, путь и так гладкий; меньше точек - быстрее растеризация)
fn brush_extend(mut st State, mm pipeline.MaskMap, fx f32, fy f32) {
	x, y := buf_to_m(mm, fx, fy)
	nx := f32(x / mm.ar)
	ny := f32(y)
	mut sh := st.edit.params.masks[st.mask_sel].shape(st.mask_part)
	if sh.strokes.len == 0 {
		return
	}
	k := sh.strokes.len - 1
	n := sh.strokes[k].pts.len
	dx := (nx - sh.strokes[k].pts[n - 2]) * f32(mm.ar)
	dy := ny - sh.strokes[k].pts[n - 1]
	step := sh.strokes[k].radius * 0.25
	if dx * dx + dy * dy < step * step {
		mask_redraw(st)
		return
	}
	sh.strokes[k].pts << nx
	sh.strokes[k].pts << ny
	if sh.strokes[k].cols.len == n / 2 * 3 {
		sh.strokes[k].cols << brush_color(st, fx, fy)
	}
	st.edit.params.masks[st.mask_sel].set_shape(st.mask_part, sh)
	defer_fx(mut st, st.tone_fx)
}

// drag_mask - форма после перетаскивания ручки в точку (x, y) кадра
fn drag_mask(d MaskDrag, x f64, y f64, ar f64) pipeline.MaskPart {
	mut m := d.start
	match d.kind {
		.a {
			m.ax = f32(x / ar)
			m.ay = f32(y)
		}
		.b {
			m.bx = f32(x / ar)
			m.by = f32(y)
		}
		.move {
			dx := (x - d.px) / ar
			dy := y - d.py
			m.ax = f32(f64(d.start.ax) + dx)
			m.ay = f32(f64(d.start.ay) + dy)
			m.bx = f32(f64(d.start.bx) + dx)
			m.by = f32(f64(d.start.by) + dy)
		}
		.axis {
			// Конец полуоси: длина - до курсора, поворот - по направлению
			cx := f64(d.start.ax) * ar
			cy := f64(d.start.ay)
			vx := d.sign * (x - cx)
			vy := d.sign * (y - cy)
			r := f32(math.max(0.005, math.hypot(vx, vy)))
			mut deg := math.atan2(vy, vx) * 180 / math.pi
			if d.ry {
				m.ry = r
				deg -= 90
			} else {
				m.rx = r
			}
			for deg > 180 {
				deg -= 360
			}
			for deg <= -180 {
				deg += 360
			}
			m.angle = f32(deg)
		}
		.none {}
	}
	return m
}

// mask_overlay - ручки выделенного фильтра и метки остальных (поверх
// снимка, без пересчёта)
fn mask_overlay(mut st State, mut ctx vgui.RenderContext) {
	pins_only := mask_pins_only(st)
	if !pins_only && !mask_active(st) {
		return
	}
	cv := st.cv
	if cv.width != st.gw || cv.height != st.gh {
		return // превью ещё не пересчитано
	}
	mm := view_map(st)
	if pins_only {
		ix0, iy0 := cv.buf_to_screen(0, 0)
		ix1, iy1 := cv.buf_to_screen(f32(st.gw), f32(st.gh))
		ctx.push_clip(vgui.Rect{ix0, iy0, ix1 - ix0, iy1 - iy0})
		draw_pins(mut ctx, st, mm)
		ctx.pop_clip()
		return
	}
	full := st.edit.params.masks[st.mask_sel]
	m := full.shape(st.mask_part)
	p := mask_pts(m, mm.ar)
	ix0, iy0 := cv.buf_to_screen(0, 0)
	ix1, iy1 := cv.buf_to_screen(f32(st.gw), f32(st.gh))
	ctx.push_clip(vgui.Rect{ix0, iy0, ix1 - ix0, iy1 - iy0})
	if m.kind == .brush {
		// Круг кисти под курсором: размер и граница мягкости (путей мазков
		// не рисуем - мешают смотреть; покрытие видно на снимке и заливкой)
		// Только пока мышь над снимком: leave приходит не всегда (уход на
		// панель), поэтому - по hovered холста и положению мыши
		mx := ctx.mouse_x
		my := ctx.mouse_y
		over := cv.hovered && mx >= ix0 && mx < ix1 && my >= iy0 && my < iy1
		if st.brush_paint || (st.brush_hover && over) {
			cx, cy := cv.buf_to_screen(st.brush_hx, st.brush_hy)
			bx, by := buf_to_m(mm, st.brush_hx, st.brush_hy)
			ex, ey := m_to_screen(st, mm, bx + f64(brush_radius(st)), by)
			r := f32(math.hypot(ex - cx, ey - cy))
			ctx.draw_circle(cx, cy, r + 1, mask_dark)
			ctx.draw_circle(cx, cy, r, mask_line)
			ri := r * (1 - st.brush_feather / 100)
			if ri > 2 {
				ctx.draw_circle(cx, cy, ri, mask_soft)
			}
		}
	} else if m.kind == .linear {
		ax, ay := m_to_screen(st, mm, p.ax, p.ay)
		bx, by := m_to_screen(st, mm, p.bx, p.by)
		// Линии поперёк перехода через a и b - на всю ширину снимка
		dx := bx - ax
		dy := by - ay
		l := f32(math.sqrt(dx * dx + dy * dy))
		if l > 0.5 {
			nx := -dy / l
			ny := dx / l
			span := (ix1 - ix0) + (iy1 - iy0)
			for k, pt in [[ax, ay], [bx, by], [(ax + bx) / 2, (ay + by) / 2]] {
				c := if k == 0 { mask_line } else { mask_soft }
				x0 := pt[0] - nx * span
				y0 := pt[1] - ny * span
				x1 := pt[0] + nx * span
				y1 := pt[1] + ny * span
				if k < 2 {
					ctx.draw_line_thick(x0, y0 + 1, x1, y1 + 1, 1, mask_dark)
				}
				ctx.draw_line_thick(x0, y0, x1, y1, if k == 0 { 2 } else { 1 }, c)
			}
		}
		ctx.draw_line(ax, ay, bx, by, mask_soft)
	} else {
		// Край эллипса и граница полного действия (растушёвка)
		inner := 1 - math.max(0.01, math.min(1.0, f64(m.feather) / 100))
		draw_ellipse(mut ctx, st, mm, p, 1.0, mask_line, true)
		if inner > 0.02 {
			draw_ellipse(mut ctx, st, mm, p, inner, mask_soft, false)
		}
	}
	for h in mask_handles(st, mm) {
		r := if h.kind == .move { f32(6) } else { f32(5) }
		ctx.fill_circle(h.x, h.y, r + 1.5, mask_dark)
		ctx.fill_circle(h.x, h.y, r, if h.kind == .move { mask_pin } else { mask_line })
	}
	// Остальные формы выделенного фильтра - тонкий контур и метка цвета
	// операции (основа - белая); щелчок по метке выделяет форму
	for k in -1 .. full.parts.len {
		if k == st.mask_part {
			continue
		}
		o := full.shape(k)
		c := if k < 0 { mask_line } else { part_colors[op_index(o.op)] }
		ca := vgui.Color{c.r, c.g, c.b, 150}
		op := mask_pts(o, mm.ar)
		match o.kind {
			.radial {
				draw_ellipse(mut ctx, st, mm, op, 1.0, ca, false)
			}
			.brush {} // только метка
			.linear {
				ax, ay := m_to_screen(st, mm, op.ax, op.ay)
				bx, by := m_to_screen(st, mm, op.bx, op.by)
				ctx.draw_line(ax, ay, bx, by, ca)
			}
		}
		ox, oy, ok := shape_anchor(o, mm.ar)
		if !ok {
			continue
		}
		qx, qy := m_to_screen(st, mm, ox, oy)
		ctx.fill_circle(qx, qy, 6, mask_dark)
		ctx.fill_circle(qx, qy, 4.5, c)
	}
	// Метки остальных фильтров - щелчок выделяет
	draw_pins(mut ctx, st, mm)
	ctx.pop_clip()
}

// draw_ellipse - эллипс фильтра (масштаб k от полуосей) ломаной на экране
fn draw_ellipse(mut ctx vgui.RenderContext, st &State, mm pipeline.MaskMap, p MaskPts, k f64, c vgui.Color, outline bool) {
	n := 72
	mut qx := f32(0)
	mut qy := f32(0)
	for i in 0 .. n + 1 {
		t := 2 * math.pi * f64(i) / f64(n)
		x := p.ax + k * (math.cos(t) * p.ux + math.sin(t) * p.vx)
		y := p.ay + k * (math.cos(t) * p.uy + math.sin(t) * p.vy)
		sx, sy := m_to_screen(st, mm, x, y)
		if i > 0 {
			if outline {
				ctx.draw_line(qx, qy + 1, sx, sy + 1, mask_dark)
			}
			ctx.draw_line_thick(qx, qy, sx, sy, if outline { 2 } else { 1 }, c)
		}
		qx = sx
		qy = sy
	}
}

// ── Секция панели ──

// sync_mask_ui - список фильтров, выделение и ползунки по st.edit
fn sync_mask_ui(mut st State) {
	if st.mask_sel >= st.edit.params.masks.len {
		st.mask_sel = st.edit.params.masks.len - 1
	}
	if isnil(st.mask_ui) {
		return
	}
	mut u := st.mask_ui
	valid := mask_valid(st)
	if !valid || st.mask_part >= st.edit.params.masks[st.mask_sel].parts.len {
		st.mask_part = -1
	}
	part := valid && st.mask_part >= 0
	if !isnil(u.form_cb) {
		mut fcb := u.form_cb
		was0 := st.suppress
		st.suppress = true
		fcb.set_items(if valid { shape_names(st.edit.params.masks[st.mask_sel]) } else { [i18n.tr('Основа')] })
		fcb.set_selected(st.mask_part + 1)
		st.suppress = was0
		fcb.enabled = valid
	}
	if !isnil(u.pdel_btn) {
		u.pdel_btn.enabled = part
	}
	if !isnil(u.padd_cb) {
		mut acb := u.padd_cb
		was0 := st.suppress
		st.suppress = true
		acb.set_selected(0)
		st.suppress = was0
		acb.enabled = valid
	}
	if !isnil(u.op_cb) {
		mut ocb := u.op_cb
		was0 := st.suppress
		st.suppress = true
		ocb.set_selected(if part {
			op_index(st.edit.params.masks[st.mask_sel].parts[st.mask_part].op)
		} else {
			0
		})
		st.suppress = was0
		ocb.enabled = part
	}
	if !isnil(u.sel_cb) {
		mut cb := u.sel_cb
		mut names := [if st.edit.params.masks.len == 0 {
			i18n.tr('Фильтров нет')
		} else {
			i18n.tr('Выберите фильтр')
		}]
		for i, m in st.edit.params.masks {
			names << mask_name(m, i)
		}
		was := st.suppress
		st.suppress = true
		cb.set_items(names)
		cb.set_selected(st.mask_sel + 1)
		st.suppress = was
		cb.enabled = st.edit.params.masks.len > 0
	}
	// Ползунки выделенного - по снимку (их get читает st.mask_sel)
	was := st.suppress
	st.suppress = true
	for b in st.binds {
		if b.sl in u.sliders {
			mut sl := b.sl
			sl.set_value(b.get(&st.edit))
		}
	}
	st.suppress = was
	for mut sl in u.sliders {
		set_slider_enabled(st, mut sl, valid)
	}
	// Ограничение диапазоном: режим и ползунки по нему
	ri := if valid { range_index(st.edit.params.masks[st.mask_sel]) } else { 0 }
	if !isnil(u.range_cb) {
		mut rcb := u.range_cb
		was2 := st.suppress
		st.suppress = true
		rcb.set_selected(ri)
		st.suppress = was2
		rcb.enabled = valid
	}
	for mut sl in u.lum_sl {
		set_slider_enabled(st, mut sl, valid && ri & 1 != 0)
	}
	for mut sl in u.col_sl {
		set_slider_enabled(st, mut sl, valid && ri & 2 != 0)
	}
	if !isnil(u.pick_btn) {
		u.pick_btn.enabled = valid
	}
	if !valid && st.mask_pick {
		set_mask_pick(mut st, false)
	}
	// Настройки кисти - когда выделена кисть
	brush := valid && st.edit.params.masks[st.mask_sel].shape(st.mask_part).kind == .brush
	for mut bsl in u.brush_sl {
		set_slider_enabled(st, mut bsl, brush)
	}
	if !isnil(u.auto_cb) {
		u.auto_cb.enabled = brush
		was1 := st.suppress
		st.suppress = true
		u.auto_cb.set_checked(brush && st.edit.params.masks[st.mask_sel].shape(st.mask_part).auto)
		st.suppress = was1
	}
	// Настройки формы: ряды по её виду
	want := if !valid {
		-1
	} else {
		match st.edit.params.masks[st.mask_sel].shape(st.mask_part).kind {
			.brush { 0 }
			.radial { 1 }
			.linear { -1 }
		}
	}
	if !isnil(u.shape_box) && want != u.shape_shown {
		mut sb := u.shape_box
		sb.clear()
		rows := if want == 0 {
			u.brush_rows
		} else if want == 1 {
			u.radial_rows
		} else {
			[]&vgui.Widget{}
		}
		for r in rows {
			sb.add(r)
		}
		u.shape_shown = want
	}
	// Растушёвка и действие снаружи - у выделенной формы (радиальной)
	sh := if valid { st.edit.params.masks[st.mask_sel].shape(st.mask_part) } else { pipeline.MaskPart{} }
	radial := valid && sh.kind == .radial
	if !isnil(u.feather) {
		u.feather.enabled = radial
	}
	if !isnil(u.inv_cb) {
		u.inv_cb.enabled = radial
		u.inv_cb.set_checked(radial && sh.invert)
	}
	if !isnil(u.on_btn) {
		u.on_btn.enabled = valid
	}
	if !isnil(u.del_btn) {
		u.del_btn.enabled = valid
	}
	// Заливка - только у выделенного фильтра: без него флажку нечего прятать
	if !isnil(u.show_cb) {
		u.show_cb.enabled = valid
	}
	if !isnil(u.done_btn) {
		u.done_btn.enabled = valid
	}
	// Имя: поле в фокусе (человек печатает) не трогаем
	if !isnil(u.name_in) {
		mut ni := u.name_in
		ni.enabled = valid
		ni.placeholder = i18n.trf('По виду: «{0}»', if valid {
			kind_name(st.edit.params.masks[st.mask_sel].kind)
		} else {
			i18n.tr('Линейный')
		})
		if !ni.focused {
			ni.set_text(if valid { st.edit.params.masks[st.mask_sel].name } else { '' })
		}
	}
	if !isnil(u.on_btn) {
		on := valid && st.edit.params.masks[st.mask_sel].on
		u.on_btn.icon_name = if on || !valid { 'eye' } else { 'eye-off' }
	}
}

// MaskField - поле правки фильтра для ползунка секции
enum MaskField {
	exposure
	contrast
	clarity
	sharpness
	highlights
	shadows
	saturation
	temp
	tint
	grow
	size
	angle
	feather
	lum_lo
	lum_hi
	lum_soft
	hue
	hue_w
}

// mask_get - значение поля; растушёвка - у формы part (-1 - основа)
fn mask_get(m pipeline.Mask, f MaskField, part int) f32 {
	return match f {
		.exposure { m.exposure }
		.contrast { m.contrast }
		.clarity { m.clarity }
		.sharpness { m.sharpness }
		.highlights { m.highlights }
		.shadows { m.shadows }
		.saturation { m.saturation }
		.temp { m.temp }
		.tint { m.tint }
		.grow { m.grow }
		.size { f32(math.max(m.shape(part).rx, m.shape(part).ry)) * 100 }
		.angle { ellipse_angle(m.shape(part).angle) }
		.feather { m.shape(part).feather }
		.lum_lo { m.lum_lo }
		.lum_hi { m.lum_hi }
		.lum_soft { m.lum_soft }
		.hue { m.hue }
		.hue_w { m.hue_w }
	}
}

fn mask_set(mut m pipeline.Mask, f MaskField, v f32, part int) {
	match f {
		.exposure { m.exposure = v }
		.contrast { m.contrast = v }
		.clarity { m.clarity = v }
		.sharpness { m.sharpness = v }
		.highlights { m.highlights = v }
		.shadows { m.shadows = v }
		.saturation { m.saturation = v }
		.temp { m.temp = v }
		.tint { m.tint = v }
		.grow { m.grow = v }
		.size {
			// Большая полуось - v% высоты кадра, пропорции эллипса те же
			mut sh := m.shape(part)
			big := math.max(sh.rx, sh.ry)
			if big > 1e-6 && v > 0 {
				k := v / 100 / big
				sh.rx *= k
				sh.ry *= k
				m.set_shape(part, sh)
			}
		}
		.angle {
			mut sh := m.shape(part)
			sh.angle = v
			m.set_shape(part, sh)
		}
		.feather {
			mut sh := m.shape(part)
			sh.feather = v
			m.set_shape(part, sh)
		}
		.lum_lo { m.lum_lo = v }
		.lum_hi { m.lum_hi = v }
		.lum_soft { m.lum_soft = v }
		.hue { m.hue = v }
		.hue_w { m.hue_w = v }
	}
}

// ellipse_angle - поворот эллипса в -90..90 (поворот на 180° - тот же
// эллипс)
fn ellipse_angle(a f32) f32 {
	mut r := f32(math.fmod(f64(a), 180))
	if r > 90 {
		r -= 180
	} else if r <= -90 {
		r += 180
	}
	return r
}

// mask_slider - ползунок правки выделенного фильтра (edit_slider: история,
// откат); без выделения - выключен
fn mask_slider(mut st State, spec MaskSliderSpec) EditSlider {
	f := spec.f
	def := spec.def
	s := edit_slider(mut st, SliderCfg{
		label:  spec.label
		hname:  i18n.trf('Фильтр: {0}', '${spec.label.to_lower()}')
		min:    spec.min
		max:    spec.max
		def:    def
		digits: spec.digits
		signed: spec.signed
		show:   spec.show
		get:    fn [mut st, f, def] (e &EditState) f32 {
			i := st.mask_sel
			return if i >= 0 && i < e.params.masks.len {
				mask_get(e.params.masks[i], f, st.mask_part)
			} else {
				def
			}
		}
		set:    fn [mut st, f] (mut e EditState, v f32) {
			i := st.mask_sel
			if i >= 0 && i < e.params.masks.len {
				mask_set(mut e.params.masks[i], f, v, st.mask_part)
			}
		}
		fx:     fn [mut st] () {
			st.tone_fx()
		}
	})
	if !isnil(st.mask_ui) {
		mut u := st.mask_ui
		u.sliders << s.sl
		match f {
			.feather { u.feather = s.sl }
			.lum_lo, .lum_hi, .lum_soft { u.lum_sl << s.sl }
			.hue, .hue_w { u.col_sl << s.sl }
			else {}
		}
	}
	return s
}

fn build_mask_section(mut st State, lbl_w f32, val_w f32) []SectionRow {
	mut u := &MaskUi{}
	st.mask_ui = u

	mut add_l := vgui.button(i18n.tr('Линейный'))
	add_l.icon_name = 'square-split-vertical'
	add_l.style = .outline
	add_l.on_click = fn [mut st] () {
		add_mask(mut st, .linear)
	}
	mut add_r := vgui.button(i18n.tr('Радиальный'))
	add_r.icon_name = 'circle-dashed'
	add_r.style = .outline
	add_r.on_click = fn [mut st] () {
		add_mask(mut st, .radial)
	}
	mut add_b := vgui.button(i18n.tr('Кисть'))
	add_b.icon_name = 'brush'
	add_b.style = .outline
	add_b.on_click = fn [mut st] () {
		add_mask(mut st, .brush)
	}
	mut add_row := vgui.create_hbox_fill()
	add_row.set_spacing(6)
	add_row.add(add_l, flex: 1)
	add_row.add(add_r, flex: 1)
	add_row.add(add_b, flex: 1)

	mut on_b := icon_button('eye', i18n.tr('Включить / выключить фильтр'))
	on_b.on_click = fn [mut st] () {
		toggle_mask(mut st)
	}
	u.on_btn = on_b
	mut del_b := icon_button('trash-2', i18n.tr('Удалить фильтр'))
	del_b.on_click = fn [mut st] () {
		delete_mask(mut st)
	}
	u.del_btn = del_b
	// Выбор фильтра (метки на снимке тоже выделяют щелчком)
	mut sel_cb := vgui.combo_box()
	sel_cb.on_change = fn [mut st] (idx int, text string) {
		if st.suppress || idx - 1 == st.mask_sel {
			return
		}
		select_mask(mut st, idx - 1)
	}
	u.sel_cb = sel_cb
	mut sel_row := vgui.create_hbox_fill()
	sel_row.set_spacing(6)
	sel_row.add(vgui.label(i18n.tr('Фильтр')), min: lbl_w)
	sel_row.add(sel_cb, flex: 1)
	sel_row.add(on_b)
	sel_row.add(del_b)
	// Имя фильтра в списке: Enter - применить, пусто - по виду
	mut name_in := vgui.text_input(i18n.tr('По виду: «Линейный»'))
	name_in.max_len = mask_name_max
	name_in.on_submit = fn [mut st] (s string) {
		rename_mask(mut st, s)
	}
	u.name_in = name_in
	name_in.tooltip = i18n.tr('Имя фильтра в списке: введите и нажмите Enter')
	mut name_row := vgui.create_hbox_fill()
	name_row.set_spacing(6)
	name_row.add(vgui.label(i18n.tr('Имя')), min: lbl_w)
	name_row.add(name_in, flex: 1)

	mut done_b := icon_button('check', i18n.tr('Готово: снять выделение (Esc)'))
	done_b.on_click = fn [mut st] () {
		select_mask(mut st, -1)
	}
	u.done_btn = done_b
	// Маска видна по умолчанию, флажок её прячет
	mut show_cb := vgui.checkbox(i18n.tr('Скрыть маску'))
	show_cb.checked = !st.mask_show
	st.hk_texts << fn [st, mut show_cb] () {
		show_cb.text = i18n.trf('Скрыть маску{0}', '${hk_paren(st, 'view.mask')}')
	}
	show_cb.on_change = fn [mut st] (v bool) {
		if v == st.mask_show {
			set_mask_show(mut st, !v)
		}
	}
	u.show_cb = show_cb
	mut tools := vgui.create_hbox_fill()
	tools.set_spacing(6)
	tools.add(show_cb, flex: 1)
	tools.add(done_b)

	// Части фильтра: выбор формы (метки частей на снимке тоже выделяют),
	// удаление части, новая часть, операция выделенной части
	mut form_cb := vgui.combo_box()
	form_cb.on_change = fn [mut st] (idx int, text string) {
		if st.suppress || idx - 1 == st.mask_part {
			return
		}
		select_part(mut st, idx - 1)
	}
	u.form_cb = form_cb
	mut pdel_b := icon_button('trash-2', i18n.tr('Удалить часть'))
	pdel_b.on_click = fn [mut st] () {
		delete_part(mut st)
	}
	u.pdel_btn = pdel_b
	mut form_row := vgui.create_hbox_fill()
	form_row.set_spacing(6)
	form_row.add(vgui.label(i18n.tr('Форма')), min: lbl_w)
	form_row.add(form_cb, flex: 1)
	form_row.add(pdel_b)
	mut padd_cb := vgui.combo_box()
	padd_cb.set_items(part_adds.map(i18n.tr(it.label)))
	padd_cb.on_change = fn [mut st] (idx int, text string) {
		if st.suppress || idx <= 0 || idx >= part_adds.len {
			return
		}
		add_part(mut st, part_adds[idx].kind, part_adds[idx].op)
	}
	u.padd_cb = padd_cb
	mut op_cb := vgui.combo_box()
	op_cb.set_items(i18n.tr_all(mask_ops))
	op_cb.on_change = fn [mut st] (idx int, text string) {
		if st.suppress {
			return
		}
		set_part_op(mut st, op_of(idx))
	}
	u.op_cb = op_cb
	mut part_row := vgui.create_hbox_fill()
	part_row.set_spacing(6)
	part_row.add(padd_cb, flex: 3)
	part_row.add(op_cb, flex: 2)

	mut rows := [SectionRow{add_row}, SectionRow{sel_row}, SectionRow{name_row}, SectionRow{form_row},
		SectionRow{part_row}, SectionRow{tools}]
	// Настройки выделенной формы (shape_box, ряды - по её виду). Кисть:
	// размер, растушёвка, сила - для новых мазков (не правка)
	mut sbox := vgui.create_vbox_fill()
	sbox.set_spacing(6)
	u.shape_box = sbox
	rows << SectionRow{sbox}
	for i, lbl in [i18n.tr('Размер'), i18n.tr('Мягкость'), i18n.tr('Сила')] {
		u.brush_rows << brush_slider(mut st, lbl, i, lbl_w, val_w)
	}
	// Автомаска выделенной кисти - правка (история): все её мазки красят
	// только похожий цвет (цвета под кистью записаны у каждого мазка)
	mut auto_cb := vgui.checkbox(i18n.tr('Автомаска: только похожий цвет'))
	auto_cb.on_change = fn [mut st] (v bool) {
		if st.suppress || !mask_valid(st) {
			return
		}
		mut sh := st.edit.params.masks[st.mask_sel].shape(st.mask_part)
		if sh.kind != .brush || sh.auto == v {
			return
		}
		sh.auto = v
		mut m := st.edit.params.masks[st.mask_sel].copy()
		m.set_shape(st.mask_part, sh)
		st.edit.params.masks[st.mask_sel] = m
		mask_changed(mut st, 'mask_auto', i18n.trf('{0}: автомаска {1}', '${shape_label(st)}', '${on_off(v)}'))
	}
	u.auto_cb = auto_cb
	u.brush_rows << auto_cb
	// Радиальная: размер (большая полуось, % высоты кадра) и поворот -
	// то же, что ручки на снимке
	mut rs := mask_slider(mut st, MaskSliderSpec{
		label:  i18n.tr('Размер')
		f:      .size
		min:    1
		max:    150
		def:    35
		signed: false
	})
	u.radial_rows << edit_row(mut st, mut rs, lbl_w, val_w)
	mut ra := mask_slider(mut st, MaskSliderSpec{
		label: i18n.tr('Поворот')
		f:     .angle
		min:   -90
		max:   90
	})
	u.radial_rows << edit_row(mut st, mut ra, lbl_w, val_w)
	for spec in [
		MaskSliderSpec{
			label:  i18n.tr('Экспозиция')
			f:      .exposure
			min:    -4
			max:    4
			digits: 2
		},
		MaskSliderSpec{
			label: i18n.tr('Контраст')
			f:     .contrast
		},
		MaskSliderSpec{
			label: i18n.tr('Чёткость')
			f:     .clarity
		},
		MaskSliderSpec{
			label: i18n.tr('Резкость')
			f:     .sharpness
		},
		MaskSliderSpec{
			label: i18n.tr('Света')
			f:     .highlights
		},
		MaskSliderSpec{
			label: i18n.tr('Тени')
			f:     .shadows
		},
		MaskSliderSpec{
			label: i18n.tr('Насыщенность')
			f:     .saturation
		},
		MaskSliderSpec{
			label: i18n.tr('Температура')
			f:     .temp
		},
		MaskSliderSpec{
			label: i18n.trc('ББ', 'Оттенок')
			f:     .tint
		},
	] {
		mut s := mask_slider(mut st, spec)
		rows << SectionRow{edit_row(mut st, mut s, lbl_w, val_w)}
	}
	rows << SectionRow{vgui.separator()}
	// Расширить / сузить - вся форма фильтра (минус - сузить)
	mut gr := mask_slider(mut st, MaskSliderSpec{
		label: i18n.tr('Расширить')
		f:     .grow
	})
	rows << SectionRow{edit_row(mut st, mut gr, lbl_w, val_w)}
	mut fe := mask_slider(mut st, MaskSliderSpec{
		label:  i18n.tr('Растушёвка')
		f:      .feather
		min:    0
		def:    50
		signed: false
	})
	u.radial_rows << edit_row(mut st, mut fe, lbl_w, val_w)
	mut inv_cb := vgui.checkbox(i18n.tr('Действие снаружи эллипса'))
	// (растушёвка и «снаружи» - у выделенной формы: основы или части)
	inv_cb.on_change = fn [mut st] (v bool) {
		if st.suppress || !mask_valid(st) {
			return
		}
		mut sh := st.edit.params.masks[st.mask_sel].shape(st.mask_part)
		if sh.invert == v {
			return
		}
		sh.invert = v
		mut m := st.edit.params.masks[st.mask_sel].copy()
		m.set_shape(st.mask_part, sh)
		st.edit.params.masks[st.mask_sel] = m
		mask_changed(mut st, 'mask_inv', i18n.trf('{0}: снаружи {1}', '${shape_label(st)}', '${on_off(v)}'))
	}
	u.inv_cb = inv_cb
	u.radial_rows << inv_cb
	rows << SectionRow{vgui.separator()}
	rows << build_range_rows(mut st, lbl_w, val_w)
	mut hint := vgui.label(i18n.tr('Точки на снимке: перенос, переход, размер и поворот'))
	hint.font_size = 12
	st.hint_labels << hint
	rows << SectionRow{hint}
	mut hint3 := vgui.label(i18n.tr('Кисть: левая кнопка рисует, ластик - «Вычесть: кистью»'))
	hint3.font_size = 12
	st.hint_labels << hint3
	rows << SectionRow{hint3}
	mut hint2 := vgui.label(i18n.tr('Метки частей: зелёная добавляет, красная вычитает, синяя пересекает'))
	hint2.font_size = 12
	st.hint_labels << hint2
	rows << SectionRow{hint2}
	sync_mask_ui(mut st)
	return rows
}

// brush_slider - ряд настройки кисти: 0 - размер, 1 - мягкость
// (растушёвка мазка), 2 - сила (State.brush_*; не правка кадра - без истории)
fn brush_slider(mut st State, label string, which int, lbl_w f32, val_w f32) &vgui.HBox {
	def := [f32(35), 50, 100][which]
	cur := [st.brush_size, st.brush_feather, st.brush_flow][which]
	lb := vgui.label(label)
	mut sl := vgui.slider_horizontal(if which == 1 { f32(0) } else { f32(1) }, 100, cur)
	sl.step = 1
	sl.wheel = false
	conv := NumConv{
		digits: 0
	}
	mut vf := value_field(mut sl, conv, unsafe { nil })
	sl.on_change = fn [mut st, mut vf, which, conv] (v f32) {
		match which {
			0 { st.brush_size = v }
			1 { st.brush_feather = v }
			else { st.brush_flow = v }
		}
		show_value(mut vf, conv, v)
		mask_redraw(st) // круг кисти
	}
	if !isnil(st.mask_ui) {
		mut u := st.mask_ui
		u.brush_sl << sl
	}
	return slider_row(mut st, lb, mut sl, vf, def, lbl_w, val_w)
}

struct MaskSliderSpec {
	label  string
	f      MaskField
	min    f32 = -100
	max    f32 = 100
	def    f32
	digits int
	signed bool            = true
	show   fn (f32) string = unsafe { nil }
}

// ── Ограничение диапазоном ──

// Режимы ограничения: индекс = яркость + 2·цвет
const range_modes = ['Нет', 'Яркость', 'Цвет', 'Яркость и цвет']

fn range_index(m pipeline.Mask) int {
	return (if m.lum_on { 1 } else { 0 }) + (if m.col_on { 2 } else { 0 })
}

// hue_name - оттенок (градусы) с названием - для истории («цвет 233° синий»)
fn hue_name(deg f32) string {
	h := int(math.round(deg)) % 360
	name := match true {
		h < 15 || h >= 345 { i18n.tr('красный') }
		h < 45 { i18n.tr('оранжевый') }
		h < 70 { i18n.tr('жёлтый') }
		h < 160 { i18n.tr('зелёный') }
		h < 200 { i18n.tr('голубой') }
		h < 255 { i18n.tr('синий') }
		h < 290 { i18n.tr('фиолетовый') }
		else { i18n.tr('пурпурный') }
	}
	return '${h}° ${name}'
}

fn build_range_rows(mut st State, lbl_w f32, val_w f32) []SectionRow {
	mut u := st.mask_ui
	mut rcb := vgui.combo_box()
	rcb.set_items(i18n.tr_all(range_modes))
	rcb.set_selected(0)
	rcb.on_change = fn [mut st] (idx int, text string) {
		if st.suppress || !mask_valid(st) || idx < 0 || idx >= range_modes.len {
			return
		}
		i := st.mask_sel
		m := st.edit.params.masks[i]
		if range_index(m) == idx {
			return
		}
		st.edit.params.masks[i].lum_on = idx & 1 != 0
		st.edit.params.masks[i].col_on = idx & 2 != 0
		// Диапазон подбирают по заливке - показать её
		if idx != 0 && !st.mask_show {
			st.mask_show = true
			sync_mask_show_ui(mut st)
		}
		mask_changed(mut st, 'mask_range', i18n.trf('Фильтр {0}: ограничение - {1}', '${i + 1}', i18n.tr(range_modes[idx]).to_lower()))
	}
	u.range_cb = rcb
	mut pick := icon_button('pipette', i18n.tr('Пипетка цвета: щёлкните по цвету на снимке'))
	pick.on_click = fn [mut st] () {
		set_mask_pick(mut st, !st.mask_pick && mask_active(st))
	}
	u.pick_btn = pick
	mut r_row := vgui.create_hbox_fill()
	r_row.set_spacing(6)
	r_row.add(vgui.label(i18n.tr('Диапазон')), min: lbl_w)
	r_row.add(rcb, flex: 1)
	r_row.add(pick)
	mut rows := [SectionRow{r_row}]
	for spec in [
		MaskSliderSpec{
			label:  i18n.tr('Яркость от')
			f:      .lum_lo
			min:    0
			signed: false
		},
		MaskSliderSpec{
			label:  i18n.tr('Яркость до')
			f:      .lum_hi
			min:    0
			def:    100
			signed: false
		},
		MaskSliderSpec{
			label:  i18n.tr('Мягкость')
			f:      .lum_soft
			min:    0
			max:    50
			def:    10
			signed: false
		},
	] {
		mut s := mask_slider(mut st, spec)
		rows << SectionRow{edit_row(mut st, mut s, lbl_w, val_w)}
	}
	// Цвет - оттенок в градусах (в истории - с названием)
	mut hue := mask_slider(mut st, MaskSliderSpec{
		label:  i18n.tr('Цвет')
		f:      .hue
		min:    0
		max:    359
		signed: false
		show:   fn (v f32) string {
			return '${int(math.round(v))}°'
		}
	})
	rows << SectionRow{edit_row(mut st, mut hue, lbl_w, val_w)}
	mut hw := mask_slider(mut st, MaskSliderSpec{
		label:  i18n.tr('Ширина')
		f:      .hue_w
		min:    5
		max:    90
		def:    30
		signed: false
		show:   fn (v f32) string {
			return '±${int(math.round(v))}°'
		}
	})
	rows << SectionRow{edit_row(mut st, mut hw, lbl_w, val_w)}
	return rows
}

// set_mask_pick - режим пипетки цвета фильтра (кнопка подсвечена, на
// снимке - кружок)
fn set_mask_pick(mut st State, on bool) {
	st.mask_pick = on
	if !isnil(st.mask_ui) && !isnil(st.mask_ui.pick_btn) {
		mut b := st.mask_ui.pick_btn
		b.style = if on { vgui.ButtonStyle.accent } else { vgui.ButtonStyle.flat }
	}
	if !isnil(st.cv) {
		mut cv := st.cv
		cv.brush_radius = if on { mask_pick_r } else { 0 }
	}
}

const mask_pick_r = 4

// mask_pick_at - пипетка: оттенок пятна превью (как его видит фильтр) -
// в «Цвет», ограничение по цвету включается
fn mask_pick_at(mut st State, x int, y int) {
	set_mask_pick(mut st, false)
	if !mask_valid(st) || st.glin.len != st.gw * st.gh * 3 {
		return
	}
	mut sr := 0.0
	mut sg := 0.0
	mut sb := 0.0
	mut n := 0
	for yy in y - mask_pick_r .. y + mask_pick_r + 1 {
		for xx in x - mask_pick_r .. x + mask_pick_r + 1 {
			if xx < 0 || yy < 0 || xx >= st.gw || yy >= st.gh {
				continue
			}
			i := (yy * st.gw + xx) * 3
			sr += f64(st.glin[i])
			sg += f64(st.glin[i + 1])
			sb += f64(st.glin[i + 2])
			n++
		}
	}
	if n == 0 {
		return
	}
	pr := pipeline.probe(f32(sr / n), f32(sg / n), f32(sb / n), &st.edit.params)
	if pr.sat < 0.05 {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_warning(i18n.tr('Пипетка: место почти серое - у него нет цвета'))
		}
		return
	}
	i := st.mask_sel
	st.edit.params.masks[i].hue = f32(int(math.round(pr.hue)) % 360)
	st.edit.params.masks[i].col_on = true
	if !st.mask_show {
		st.mask_show = true
		sync_mask_show_ui(mut st)
	}
	mask_changed(mut st, 'mask_hue', i18n.trf('Фильтр {0}: цвет {1}', '${i + 1}', '${hue_name(st.edit.params.masks[i].hue)}'))
}
