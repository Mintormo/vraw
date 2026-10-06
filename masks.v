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

const mask_handle_px = f32(9) // радиус захвата ручки на экране
const mask_line = vgui.Color{255, 255, 255, 230}
const mask_soft = vgui.Color{255, 255, 255, 110}
const mask_dark = vgui.Color{0, 0, 0, 170}
const mask_pin = vgui.Color{255, 214, 10, 255}
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
	start pipeline.Mask
	px    f64 // точка нажатия в единицах кадра (view_map)
	py    f64
	moved bool
}

// MaskUi - виджеты секции (sync_mask_ui выставляет их из st.edit)
@[heap]
struct MaskUi {
mut:
	sel_cb   &vgui.ComboBox = unsafe { nil } // выбор фильтра: 0 - не выбран
	on_btn   &vgui.Button   = unsafe { nil }
	del_btn  &vgui.Button   = unsafe { nil }
	done_btn &vgui.Button   = unsafe { nil }
	show_cb  &vgui.CheckBox = unsafe { nil }
	inv_cb   &vgui.CheckBox = unsafe { nil }
	sliders  []&vgui.Slider // правки выделенного (без фильтра - выключены)
	feather  &vgui.Slider   = unsafe { nil } // только у радиального
	m_show   &vgui.MenuItem = unsafe { nil }
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

fn mask_pts(m pipeline.Mask, ar f64) MaskPts {
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
	return mask_valid(st) && !st.crop_mode && st.linear.len > 0 && !jpeg_active(st)
		&& !isnil(st.cv)
}

fn mask_name(m pipeline.Mask, i int) string {
	kind := if m.kind == .radial { 'Радиальный' } else { 'Линейный' }
	off := if m.on { '' } else { '  (выкл)' }
	return '${i + 1}. ${kind}${off}'
}

// select_mask - выделить фильтр idx (-1 - снять выделение)
fn select_mask(mut st State, idx int) {
	st.mask_sel = if idx >= 0 && idx < st.edit.params.masks.len { idx } else { -1 }
	st.mask_drag = MaskDrag{}
	sync_mask_ui(mut st)
	if st.mask_show && !isnil(st.tone_fx) {
		st.tone_fx() // заливка - другого фильтра
	}
	mask_redraw(st)
}

fn mask_redraw(st &State) {
	if !isnil(st.cv) {
		mut cv := st.cv
		cv.mark_dirty()
	}
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

// add_mask - новый фильтр по виду холста: линейный - переход с 10% до
// 50% высоты кадра на экране (небо), радиальный - эллипс по центру
fn add_mask(mut st State, kind pipeline.MaskKind) {
	if st.linear.len == 0 || st.gw <= 0 {
		return
	}
	if st.crop_mode {
		set_crop_mode(mut st, false)
	}
	mm := view_map(st)
	w := f64(st.gw)
	h := f64(st.gh)
	mut m := pipeline.Mask{
		kind: kind
	}
	if kind == .linear {
		ax, ay := buf_to_m(mm, w / 2, h * 0.1)
		bx, by := buf_to_m(mm, w / 2, h * 0.5)
		m.ax = f32(ax / mm.ar)
		m.ay = f32(ay)
		m.bx = f32(bx / mm.ar)
		m.by = f32(by)
	} else {
		cx, cy := buf_to_m(mm, w / 2, h / 2)
		ux, uy := buf_to_m(mm, w / 2 + w * 0.25, h / 2)
		vx, vy := buf_to_m(mm, w / 2, h / 2 + h * 0.3)
		m.ax = f32(cx / mm.ar)
		m.ay = f32(cy)
		m.rx = f32(math.hypot(ux - cx, uy - cy))
		m.ry = f32(math.hypot(vx - cx, vy - cy))
		m.angle = f32(math.atan2(uy - cy, ux - cx) * 180 / math.pi)
	}
	st.edit.params.masks << m
	st.mask_sel = st.edit.params.masks.len - 1
	name := if kind == .radial { 'радиальный' } else { 'линейный' }
	mask_changed(mut st, 'mask_add', 'Фильтр: добавлен ${name}')
}

fn delete_mask(mut st State) {
	if !mask_valid(st) {
		return
	}
	st.edit.params.masks.delete(st.mask_sel)
	if st.mask_sel >= st.edit.params.masks.len {
		st.mask_sel = st.edit.params.masks.len - 1
	}
	mask_changed(mut st, 'mask_del', 'Фильтр: удалён')
}

fn toggle_mask(mut st State) {
	if !mask_valid(st) {
		return
	}
	i := st.mask_sel
	st.edit.params.masks[i].on = !st.edit.params.masks[i].on
	mask_changed(mut st, 'mask_on', 'Фильтр ${i + 1}: ${on_off(st.edit.params.masks[i].on)}')
}

// set_mask_show - заливка маски выделенного фильтра (вид, не правка)
fn set_mask_show(mut st State, on bool) {
	st.mask_show = on
	if !isnil(st.mask_ui) {
		mut u := st.mask_ui
		if !isnil(u.show_cb) {
			u.show_cb.set_checked(on)
		}
		if !isnil(u.m_show) {
			u.m_show.checked = on
		}
	}
	if !isnil(st.tone_fx) {
		st.tone_fx()
	}
}

// mask_paint - заливка маски выделенного фильтра поверх снимка (RGBA
// буфер холста gw x gh, после гистограммы - она по снимку)
fn mask_paint(st &State, mut pix []u8) {
	if !st.mask_show || !mask_active(st) || pix.len != st.gw * st.gh * 4 {
		return
	}
	wt := pipeline.mask_weights(st.edit.params.masks[st.mask_sel], view_map(st), st.gw,
		st.gh)
	for i, w in wt {
		if w == 0 {
			continue
		}
		a := f32(w) * (mask_fill_a / 255)
		r := f32(pix[i * 4])
		pix[i * 4] = u8(r + (255 - r) * a)
		pix[i * 4 + 1] = u8(f32(pix[i * 4 + 1]) * (1 - a))
		pix[i * 4 + 2] = u8(f32(pix[i * 4 + 2]) * (1 - a))
	}
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
	m := st.edit.params.masks[st.mask_sel]
	p := mask_pts(m, mm.ar)
	mut hs := []MaskHandle{}
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

// pin_hit - метка невыделенного фильтра под курсором (щелчок выделяет)
fn pin_hit(st &State, mm pipeline.MaskMap, sx f32, sy f32) int {
	for i, m in st.edit.params.masks {
		if i == st.mask_sel {
			continue
		}
		qx, qy := m_to_screen(st, mm, f64(m.ax) * mm.ar, f64(m.ay))
		if math.abs(qx - sx) <= mask_handle_px && math.abs(qy - sy) <= mask_handle_px {
			return i
		}
	}
	return -1
}

// mask_input - мышь на холсте при выделенном фильтре; true - обработано
fn mask_input(mut st State, ev &vgui.CanvasInputEvent) bool {
	if !mask_active(st) {
		return false
	}
	cv := st.cv
	mm := view_map(st)
	sx, sy := cv.buf_to_screen(ev.fx, ev.fy)
	match ev.kind {
		.hover {
			h := mask_hit(st, mm, sx, sy)
			if h.kind != .none {
				vgui.set_cursor(if h.kind == .move {
					vgui.sdl_system_cursor_sizeall
				} else {
					vgui.sdl_system_cursor_crosshair
				})
			} else if pin_hit(st, mm, sx, sy) >= 0 {
				vgui.set_cursor(vgui.sdl_system_cursor_hand)
			} else {
				vgui.set_cursor(vgui.sdl_system_cursor_default)
			}
			return false
		}
		.pointer_down {
			if ev.button != 1 {
				return false
			}
			h := mask_hit(st, mm, sx, sy)
			if h.kind == .none {
				pin := pin_hit(st, mm, sx, sy)
				if pin >= 0 {
					select_mask(mut st, pin)
					return true
				}
				return false
			}
			qx, qy := buf_to_m(mm, ev.fx, ev.fy)
			st.mask_drag = MaskDrag{
				kind:  h.kind
				ry:    h.ry
				sign:  h.sign
				start: st.edit.params.masks[st.mask_sel]
				px:    qx
				py:    qy
			}
			return true
		}
		.pointer_move {
			d := st.mask_drag
			if d.kind == .none {
				return false
			}
			x, y := buf_to_m(mm, ev.fx, ev.fy)
			st.edit.params.masks[st.mask_sel] = drag_mask(d, x, y, mm.ar)
			st.mask_drag.moved = true
			defer_fx(mut st, st.tone_fx)
			return true
		}
		.pointer_up {
			d := st.mask_drag
			st.mask_drag = MaskDrag{}
			if d.kind == .none {
				return false
			}
			if d.moved {
				name := match d.kind {
					.move { 'перенос' }
					.axis { 'размер' }
					else { 'переход' }
				}
				mask_changed(mut st, 'mask_shape', 'Фильтр ${st.mask_sel + 1}: ${name}')
			}
			return true
		}
		else {}
	}
	return false
}

// drag_mask - фильтр после перетаскивания ручки в точку (x, y) кадра
fn drag_mask(d MaskDrag, x f64, y f64, ar f64) pipeline.Mask {
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
	if !mask_active(st) {
		return
	}
	cv := st.cv
	if cv.width != st.gw || cv.height != st.gh {
		return // превью ещё не пересчитано
	}
	mm := view_map(st)
	m := st.edit.params.masks[st.mask_sel]
	p := mask_pts(m, mm.ar)
	ix0, iy0 := cv.buf_to_screen(0, 0)
	ix1, iy1 := cv.buf_to_screen(f32(st.gw), f32(st.gh))
	ctx.push_clip(vgui.Rect{ix0, iy0, ix1 - ix0, iy1 - iy0})
	if m.kind == .linear {
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
	// Метки остальных фильтров - щелчок выделяет
	for i, o in st.edit.params.masks {
		if i == st.mask_sel {
			continue
		}
		qx, qy := m_to_screen(st, mm, f64(o.ax) * mm.ar, f64(o.ay))
		ctx.fill_circle(qx, qy, 5.5, mask_dark)
		ctx.draw_circle(qx, qy, 4, mask_line)
	}
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
	if !isnil(u.sel_cb) {
		mut cb := u.sel_cb
		mut names := [if st.edit.params.masks.len == 0 {
			'Фильтров нет'
		} else {
			'Не выбран'
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
		sl.enabled = valid
	}
	radial := valid && st.edit.params.masks[st.mask_sel].kind == .radial
	if !isnil(u.feather) {
		u.feather.enabled = radial
	}
	if !isnil(u.inv_cb) {
		u.inv_cb.enabled = radial
		u.inv_cb.set_checked(radial && st.edit.params.masks[st.mask_sel].invert)
	}
	if !isnil(u.on_btn) {
		u.on_btn.enabled = valid
	}
	if !isnil(u.del_btn) {
		u.del_btn.enabled = valid
	}
	if !isnil(u.done_btn) {
		u.done_btn.enabled = valid
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
	highlights
	shadows
	saturation
	temp
	tint
	feather
}

fn mask_get(m pipeline.Mask, f MaskField) f32 {
	return match f {
		.exposure { m.exposure }
		.contrast { m.contrast }
		.highlights { m.highlights }
		.shadows { m.shadows }
		.saturation { m.saturation }
		.temp { m.temp }
		.tint { m.tint }
		.feather { m.feather }
	}
}

fn mask_set(mut m pipeline.Mask, f MaskField, v f32) {
	match f {
		.exposure { m.exposure = v }
		.contrast { m.contrast = v }
		.highlights { m.highlights = v }
		.shadows { m.shadows = v }
		.saturation { m.saturation = v }
		.temp { m.temp = v }
		.tint { m.tint = v }
		.feather { m.feather = v }
	}
}

// mask_slider - ползунок правки выделенного фильтра (edit_slider: история,
// откат); без выделения - выключен
fn mask_slider(mut st State, label string, f MaskField, min f32, max f32, def f32, digits int) EditSlider {
	s := edit_slider(mut st, SliderCfg{
		label:  label
		hname:  'Фильтр: ${label.to_lower()}'
		min:    min
		max:    max
		def:    def
		digits: digits
		signed: f != .feather
		get:    fn [mut st, f, def] (e &EditState) f32 {
			i := st.mask_sel
			return if i >= 0 && i < e.params.masks.len {
				mask_get(e.params.masks[i], f)
			} else {
				def
			}
		}
		set:    fn [mut st, f] (mut e EditState, v f32) {
			i := st.mask_sel
			if i >= 0 && i < e.params.masks.len {
				mask_set(mut e.params.masks[i], f, v)
			}
		}
		fx:     fn [mut st] () {
			st.tone_fx()
		}
	})
	if !isnil(st.mask_ui) {
		mut u := st.mask_ui
		u.sliders << s.sl
		if f == .feather {
			u.feather = s.sl
		}
	}
	return s
}

fn build_mask_section(mut st State, lbl_w f32, val_w f32) []SectionRow {
	mut u := &MaskUi{}
	st.mask_ui = u

	mut add_l := vgui.button('Линейный')
	add_l.icon_name = 'square-split-vertical'
	add_l.style = .outline
	add_l.on_click = fn [mut st] () {
		add_mask(mut st, .linear)
	}
	mut add_r := vgui.button('Радиальный')
	add_r.icon_name = 'circle-dashed'
	add_r.style = .outline
	add_r.on_click = fn [mut st] () {
		add_mask(mut st, .radial)
	}
	mut add_row := vgui.create_hbox_fill()
	add_row.set_spacing(6)
	add_row.add(add_l, flex: 1)
	add_row.add(add_r, flex: 1)

	mut on_b := icon_button(mut st, 'eye', 'Включить / выключить фильтр')
	on_b.on_click = fn [mut st] () {
		toggle_mask(mut st)
	}
	u.on_btn = on_b
	mut del_b := icon_button(mut st, 'trash-2', 'Удалить фильтр')
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
	sel_row.add(vgui.label('Фильтр'), min: lbl_w)
	sel_row.add(sel_cb, flex: 1)
	sel_row.add(on_b)
	sel_row.add(del_b)

	mut done_b := icon_button(mut st, 'check', 'Готово: снять выделение (Esc)')
	done_b.on_click = fn [mut st] () {
		select_mask(mut st, -1)
	}
	u.done_btn = done_b
	mut show_cb := vgui.checkbox('Показать маску (O)')
	show_cb.on_change = fn [mut st] (v bool) {
		if v != st.mask_show {
			set_mask_show(mut st, v)
		}
	}
	u.show_cb = show_cb
	mut tools := vgui.create_hbox_fill()
	tools.set_spacing(6)
	tools.add(show_cb, flex: 1)
	tools.add(done_b)

	mut rows := [SectionRow{add_row}, SectionRow{sel_row}, SectionRow{tools}]
	for spec in [
		MaskSliderSpec{'Экспозиция', .exposure, -4, 4, 2},
		MaskSliderSpec{'Контраст', .contrast, -100, 100, 0},
		MaskSliderSpec{'Света', .highlights, -100, 100, 0},
		MaskSliderSpec{'Тени', .shadows, -100, 100, 0},
		MaskSliderSpec{'Насыщенность', .saturation, -100, 100, 0},
		MaskSliderSpec{'Температура', .temp, -100, 100, 0},
		MaskSliderSpec{'Оттенок', .tint, -100, 100, 0},
	] {
		mut s := mask_slider(mut st, spec.label, spec.f, spec.min, spec.max, 0, spec.digits)
		rows << SectionRow{edit_row(mut st, mut s, lbl_w, val_w)}
	}
	rows << SectionRow{vgui.separator()}
	mut fe := mask_slider(mut st, 'Растушёвка', .feather, 0, 100, 50, 0)
	rows << SectionRow{edit_row(mut st, mut fe, lbl_w, val_w)}
	mut inv_cb := vgui.checkbox('Действие снаружи эллипса')
	inv_cb.on_change = fn [mut st] (v bool) {
		if st.suppress || !mask_valid(st) || st.edit.params.masks[st.mask_sel].invert == v {
			return
		}
		st.edit.params.masks[st.mask_sel].invert = v
		mask_changed(mut st, 'mask_inv', 'Фильтр ${st.mask_sel + 1}: снаружи ${on_off(v)}')
	}
	u.inv_cb = inv_cb
	rows << SectionRow{inv_cb}
	mut hint := vgui.label('Точки на снимке: перенос, переход, размер и поворот')
	hint.font_size = 12
	st.hint_labels << hint
	rows << SectionRow{hint}
	sync_mask_ui(mut st)
	return rows
}

struct MaskSliderSpec {
	label  string
	f      MaskField
	min    f32
	max    f32
	digits int
}
