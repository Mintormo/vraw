module main

// Удаление пятен (pipeline/spots.v): раздел «Удаление пятен», режим
// инструмента на холсте, показ пыли.
//
// Пятна кадра - в EditState.spots (история, сайдкар, группа копирования
// spots), точки - доли кадра до поворота и кадрирования: пятно
// «приклеено» к снимку. Режим (кнопка раздела, «Правка - Удаление пятен»
// Q): щелчок по снимку - новое пятно размера «Размер», источник ищется
// сам (spot_find_source по сырью превью); у выделенного пятна видны круг,
// источник и стрелка от источника к пятну. Тянуть круг - перенос, край
// круга - размер, круг источника - другой источник; каждое отпускание -
// запись в истории. Delete / Backspace - удалить выделенное, Esc - снять
// выделение, второй Esc или Enter - выйти из режима.
//
// Ползунки «Размер», «Растушёвка», «Сила» (непрозрачность) и режим правят
// выделенное пятно и заодно становятся настройкой новых пятен (как в
// Lightroom); без выделения - только настройка инструмента.
//
// «Показать пыль» - вид (не правка): вместо снимка карта локальных
// перепадов яркости (pipeline.dust_view), пыль на небе - тёмные кружки.
import math
import vgui
import pipeline
import i18n

const spot_sel_line = vgui.Color{255, 255, 255, 240}
const spot_src_line = vgui.Color{120, 200, 255, 230}
const spot_hover_line = vgui.Color{255, 255, 255, 120}
const spot_edge_px = f32(5) // захват края круга (размер) - экранных пикселей
const spot_min_hit = f32(7) // круг меньше - захват по этому радиусу

const spot_modes = ['Восстановление', 'Клонирование']

enum SpotDragKind {
	none
	dest   // перенос пятна (источник на месте)
	source // перенос источника
	size   // край круга - радиус
}

struct SpotDrag {
mut:
	kind  SpotDragKind
	start pipeline.Spot
	px    f64 // точка нажатия в единицах кадра (view_map)
	py    f64
	moved bool
}

struct SpotHit {
	idx  int = -1
	kind SpotDragKind
}

// SpotUi - виджеты раздела (sync_spot_ui выставляет их по st.edit)
@[heap]
struct SpotUi {
mut:
	mode_btn &vgui.Button   = unsafe { nil }
	del_btn  &vgui.Button   = unsafe { nil }
	clr_btn  &vgui.Button   = unsafe { nil }
	src_btn  &vgui.Button   = unsafe { nil }
	kind_cb  &vgui.ComboBox = unsafe { nil }
	count_lb &vgui.Label    = unsafe { nil }
	dust_cb  &vgui.CheckBox = unsafe { nil }
	m_spots  &vgui.MenuItem = unsafe { nil }
}

// spot_radius - радиус пятна (доля высоты кадра) по ползунку «Размер»
// 1..100: квадрат - мелкие размеры (пыль) точнее
fn spot_radius(size f32) f32 {
	k := size / 100
	return 0.002 + 0.098 * k * k
}

// spot_size_of - обратно: «Размер» по радиусу
fn spot_size_of(r f32) f32 {
	v := (r - 0.002) / 0.098
	return clampf(100 * f32(math.sqrt(if v > 0 { v } else { 0 })), 1, 100)
}

fn spot_valid(st &State) bool {
	return st.spot_sel >= 0 && st.spot_sel < st.edit.spots.len
}

// spot_active - режим пятен и холст показывает проявку
fn spot_active(st &State) bool {
	return st.spot_mode && mask_canvas(st)
}

fn spot_redraw(st &State) {
	mask_redraw(st)
}

// set_spot_mode - войти в режим пятен / выйти
fn set_spot_mode(mut st State, on bool) {
	if on && (st.linear.len == 0 || st.suppress) {
		sync_spot_ui(mut st)
		return
	}
	if on == st.spot_mode {
		sync_spot_ui(mut st)
		return
	}
	st.spot_mode = on
	st.spot_drag = SpotDrag{}
	if on {
		if st.crop_mode {
			set_crop_mode(mut st, false)
		}
		set_wb_pick(mut st, false)
		if st.mask_sel >= 0 {
			select_mask(mut st, -1)
		}
	} else {
		st.spot_sel = -1
		st.spot_hover = false
		vgui.set_cursor(vgui.sdl_system_cursor_default)
	}
	sync_spot_ui(mut st)
	spot_redraw(st)
}

// spot_leave - смена или закрытие кадра: режим и выделение сброшены
fn spot_leave(mut st State) {
	st.spot_sel = -1
	st.spot_drag = SpotDrag{}
	st.spot_hover = false
	if st.spot_mode {
		st.spot_mode = false
		sync_spot_ui(mut st)
	}
}

fn select_spot(mut st State, idx int) {
	st.spot_sel = if idx >= 0 && idx < st.edit.spots.len { idx } else { -1 }
	st.spot_drag = SpotDrag{}
	if spot_valid(st) {
		// Настройки инструмента - как у выделенного
		s := st.edit.spots[st.spot_sel]
		st.spot_size = spot_size_of(s.r)
		st.spot_feather = s.feather
		st.spot_opacity = s.opacity
		st.spot_kind = s.mode
	}
	sync_spot_ui(mut st)
	spot_redraw(st)
}

// spot_changed - правка пятен: пересчёт и запись в истории
fn spot_changed(mut st State, key string, name string) {
	sync_spot_ui(mut st)
	if !isnil(st.tone_fx) {
		st.tone_fx()
	}
	record(mut st, key, name, false)
	spot_redraw(st)
}

// spot_find - источник для пятна по сырью превью (доли кадра)
fn spot_find(st &State, x f32, y f32, r f32) (f32, f32) {
	if st.linear.len != st.pw * st.ph * 3 {
		return x + r * 3 * f32(st.ph) / f32(math.max(1, st.pw)), y
	}
	return pipeline.spot_find_source(unsafe { &u16(st.linear.data) }, st.pw, st.ph, x, y,
		r)
}

// add_spot - новое пятно в точке холста (bx, by - пиксели буфера)
fn add_spot(mut st State, mm pipeline.MaskMap, bx f32, by f32) {
	qx, qy := buf_to_m(mm, bx, by)
	x := clampf(f32(qx / mm.ar), 0, 1)
	y := clampf(f32(qy), 0, 1)
	r := spot_radius(st.spot_size)
	sx, sy := spot_find(st, x, y, r)
	st.edit.spots << pipeline.Spot{
		x:       x
		y:       y
		sx:      sx
		sy:      sy
		r:       r
		feather: st.spot_feather
		opacity: st.spot_opacity
		mode:    st.spot_kind
	}
	st.spot_sel = st.edit.spots.len - 1
	spot_changed(mut st, 'spot_add', i18n.trf('Пятно {0}: добавлено', '${st.spot_sel + 1}'))
}

fn delete_spot(mut st State) {
	if !spot_valid(st) {
		return
	}
	n := st.spot_sel + 1
	st.edit.spots.delete(st.spot_sel)
	st.spot_sel = -1
	st.spot_drag = SpotDrag{}
	spot_changed(mut st, 'spot_del', i18n.trf('Пятно {0}: удалено', '${n}'))
}

fn clear_spots(mut st State) {
	if st.edit.spots.len == 0 {
		return
	}
	st.edit.spots = []pipeline.Spot{}
	st.spot_sel = -1
	st.spot_drag = SpotDrag{}
	spot_changed(mut st, 'spot_clear', i18n.tr('Пятна: удалены все'))
}

// spot_new_source - выделенному пятну - другой источник: лучший из
// кандидатов не ближе двух радиусов к нынешнему (как «/» в Lightroom)
fn spot_new_source(mut st State) {
	if !spot_valid(st) || st.linear.len != st.pw * st.ph * 3 {
		return
	}
	s := st.edit.spots[st.spot_sel]
	sx, sy := pipeline.spot_find_source(unsafe { &u16(st.linear.data) }, st.pw, st.ph, s.x,
		s.y, s.r, avoid_x: s.sx, avoid_y: s.sy)
	mut n := s
	n.sx = sx
	n.sy = sy
	st.edit.spots[st.spot_sel] = n
	spot_changed(mut st, 'spot_src', i18n.trf('Пятно {0}: другой источник', '${st.spot_sel + 1}'))
}

// healed - сырьё превью (w x h RGB) с пятнами: без пятен - тот же массив
// (ещё одна ссылка, bufown.v), иначе новая копия с исправлениями
fn healed(lin []u16, w int, h int, spots []pipeline.Spot) []u16 {
	if spots.len == 0 || lin.len != w * h * 3 {
		return share(lin)
	}
	out := own_clone(lin)
	pipeline.spots_apply(unsafe { &u16(out.data) }, pipeline.Region{0, 0, w, h}, w, h,
		spots)
	return out
}

// spot_refit - пятно, у которого источник перекрывает круг (вырос размер)
// или ближе края кадра, - с новым источником; иначе как было
fn spot_refit(st &State, s pipeline.Spot) pipeline.Spot {
	ar := f64(st.pw) / f64(math.max(1, st.ph))
	d := math.hypot((f64(s.sx) - f64(s.x)) * ar, f64(s.sy) - f64(s.y))
	if d >= 2.1 * f64(s.r) {
		return s
	}
	mut n := s
	n.sx, n.sy = spot_find(st, s.x, s.y, s.r)
	return n
}

// ── Холст ──

// spot_circle - круг пятна (или источника) на экране: центр и радиус
fn spot_circle(st &State, mm pipeline.MaskMap, s pipeline.Spot, src bool) (f32, f32, f32) {
	x := f64(if src { s.sx } else { s.x }) * mm.ar
	y := f64(if src { s.sy } else { s.y })
	cx, cy := m_to_screen(st, mm, x, y)
	ex, ey := m_to_screen(st, mm, x + f64(s.r), y)
	return cx, cy, f32(math.hypot(ex - cx, ey - cy))
}

// spot_hit - что под курсором (экран): у выделенного - край (размер),
// источник, круг; у остальных - круг (последние нарисованы сверху)
fn spot_hit(st &State, mm pipeline.MaskMap, sx f32, sy f32) SpotHit {
	if spot_valid(st) {
		s := st.edit.spots[st.spot_sel]
		cx, cy, r := spot_circle(st, mm, s, false)
		d := f32(math.hypot(sx - cx, sy - cy))
		if r > 2 * spot_edge_px && math.abs(d - r) <= spot_edge_px {
			return SpotHit{st.spot_sel, .size}
		}
		qx, qy, qr := spot_circle(st, mm, s, true)
		if f32(math.hypot(sx - qx, sy - qy)) <= math.max(qr, spot_min_hit) {
			return SpotHit{st.spot_sel, .source}
		}
		if d <= math.max(r, spot_min_hit) {
			return SpotHit{st.spot_sel, .dest}
		}
	}
	for i := st.edit.spots.len - 1; i >= 0; i-- {
		if i == st.spot_sel {
			continue
		}
		cx, cy, r := spot_circle(st, mm, st.edit.spots[i], false)
		if f32(math.hypot(sx - cx, sy - cy)) <= math.max(r, spot_min_hit) {
			return SpotHit{i, .dest}
		}
	}
	return SpotHit{}
}

// spot_input - мышь на холсте в режиме пятен; true - обработано
fn spot_input(mut st State, ev &vgui.CanvasInputEvent) bool {
	if !spot_active(st) {
		return false
	}
	cv := st.cv
	mm := view_map(st)
	sx, sy := cv.buf_to_screen(ev.fx, ev.fy)
	match ev.kind {
		.hover {
			st.spot_hover = true
			st.spot_hx = ev.fx
			st.spot_hy = ev.fy
			h := spot_hit(st, mm, sx, sy)
			vgui.set_cursor(match h.kind {
				.dest, .source { vgui.sdl_system_cursor_sizeall }
				.size { vgui.sdl_system_cursor_sizewe }
				.none { vgui.sdl_system_cursor_crosshair }
			})
			spot_redraw(st)
			return true // курсор пятен - шторка до/после его не перебивает
		}
		.leave {
			vgui.set_cursor(vgui.sdl_system_cursor_default)
			if st.spot_hover {
				st.spot_hover = false
				spot_redraw(st)
			}
			return false
		}
		.pointer_down {
			if ev.button != 1 {
				return false
			}
			h := spot_hit(st, mm, sx, sy)
			if h.kind == .none {
				if ev.in_image {
					add_spot(mut st, mm, ev.fx, ev.fy)
				}
				return true
			}
			if h.idx != st.spot_sel {
				select_spot(mut st, h.idx)
			}
			qx, qy := buf_to_m(mm, ev.fx, ev.fy)
			st.spot_drag = SpotDrag{
				kind:  h.kind
				start: st.edit.spots[h.idx]
				px:    qx
				py:    qy
			}
			return true
		}
		.pointer_move {
			st.spot_hx = ev.fx
			st.spot_hy = ev.fy
			d := st.spot_drag
			if d.kind == .none || !spot_valid(st) {
				return false
			}
			x, y := buf_to_m(mm, ev.fx, ev.fy)
			st.edit.spots[st.spot_sel] = drag_spot(d, x, y, mm.ar)
			st.spot_drag.moved = true
			if d.kind == .size {
				st.spot_size = spot_size_of(st.edit.spots[st.spot_sel].r)
				sync_spot_ui(mut st)
			}
			defer_fx(mut st, st.tone_fx)
			spot_redraw(st)
			return true
		}
		.pointer_up {
			d := st.spot_drag
			st.spot_drag = SpotDrag{}
			if d.kind == .none {
				return false
			}
			if d.moved {
				if d.kind == .size && spot_valid(st) {
					st.edit.spots[st.spot_sel] = spot_refit(st, st.edit.spots[st.spot_sel])
				}
				name := match d.kind {
					.source { i18n.tr('источник') }
					.size { i18n.tr('размер') }
					else { i18n.tr('перенос') }
				}
				spot_changed(mut st, 'spot_drag', i18n.trf('Пятно {0}: {1}', '${st.spot_sel + 1}', '${name}'))
			}
			return true
		}
		else {}
	}
	return false
}

// drag_spot - пятно при перетаскивании: (x, y) - мышь в единицах кадра
// (ar - ширина/высота кадра)
fn drag_spot(d SpotDrag, x f64, y f64, ar f64) pipeline.Spot {
	mut s := d.start
	dx := f32((x - d.px) / ar)
	dy := f32(y - d.py)
	match d.kind {
		.dest {
			s.x = clampf(d.start.x + dx, 0, 1)
			s.y = clampf(d.start.y + dy, 0, 1)
		}
		.source {
			s.sx = clampf(d.start.sx + dx, 0, 1)
			s.sy = clampf(d.start.sy + dy, 0, 1)
		}
		.size {
			r := math.hypot(x - f64(d.start.x) * ar, y - f64(d.start.y))
			s.r = clampf(f32(r), pipeline.spot_r_min, pipeline.spot_r_max)
		}
		.none {}
	}
	return s
}

// spot_overlay - круги пятен поверх снимка (без пересчёта): у
// выделенного - граница полного действия, источник и стрелка от него;
// под курсором - круг нового пятна
fn spot_overlay(mut st State, mut ctx vgui.RenderContext) {
	if !spot_active(st) {
		return
	}
	cv := st.cv
	if cv.width != st.gw || cv.height != st.gh {
		return // превью ещё не пересчитано
	}
	mm := view_map(st)
	ix0, iy0 := cv.buf_to_screen(0, 0)
	ix1, iy1 := cv.buf_to_screen(f32(st.gw), f32(st.gh))
	ctx.push_clip(vgui.Rect{ix0, iy0, ix1 - ix0, iy1 - iy0})
	for i, s in st.edit.spots {
		if i == st.spot_sel {
			continue
		}
		cx, cy, r := spot_circle(st, mm, s, false)
		ctx.draw_circle(cx, cy, r + 1, mask_dark)
		ctx.draw_circle(cx, cy, r, mask_line)
	}
	if spot_valid(st) {
		s := st.edit.spots[st.spot_sel]
		cx, cy, r := spot_circle(st, mm, s, false)
		qx, qy, qr := spot_circle(st, mm, s, true)
		// Стрелка от края источника к краю пятна
		dx := cx - qx
		dy := cy - qy
		l := f32(math.hypot(dx, dy))
		if l > r + qr + 4 {
			ux := dx / l
			uy := dy / l
			x0 := qx + ux * qr
			y0 := qy + uy * qr
			x1 := cx - ux * r
			y1 := cy - uy * r
			ctx.draw_line_thick(x0, y0 + 1, x1, y1 + 1, 1, mask_dark)
			ctx.draw_line_thick(x0, y0, x1, y1, 2, spot_src_line)
			ah := f32(8)
			for sg in [f32(1), -1] {
				ex := x1 - ux * ah + sg * uy * ah * 0.5
				ey := y1 - uy * ah - sg * ux * ah * 0.5
				ctx.draw_line_thick(x1, y1, ex, ey, 2, spot_src_line)
			}
		}
		ctx.draw_circle(qx, qy, qr + 1, mask_dark)
		ctx.draw_circle(qx, qy, qr, spot_src_line)
		ctx.draw_circle(cx, cy, r + 1.5, mask_dark)
		ctx.draw_circle(cx, cy, r, spot_sel_line)
		ctx.draw_circle(cx, cy, r - 0.7, spot_sel_line)
		ri := r * (1 - s.feather / 100)
		if ri > 2 && ri < r - 2 {
			ctx.draw_circle(cx, cy, ri, mask_soft)
		}
	}
	// Круг нового пятна под курсором (только над снимком, не над пятном)
	mx := ctx.mouse_x
	my := ctx.mouse_y
	over := cv.hovered && mx >= ix0 && mx < ix1 && my >= iy0 && my < iy1
	if st.spot_hover && over && st.spot_drag.kind == .none {
		sx, sy := cv.buf_to_screen(st.spot_hx, st.spot_hy)
		if spot_hit(st, mm, sx, sy).kind == .none {
			bx, by := buf_to_m(mm, st.spot_hx, st.spot_hy)
			ex, ey := m_to_screen(st, mm, bx + f64(spot_radius(st.spot_size)), by)
			r := f32(math.hypot(ex - sx, ey - sy))
			ctx.draw_circle(sx, sy, r + 1, mask_dark)
			ctx.draw_circle(sx, sy, r, spot_hover_line)
		}
	}
	ctx.pop_clip()
}

// ── Показ пыли ──

fn set_dust_show(mut st State, on bool) {
	st.dust_show = on
	sync_spot_ui(mut st)
	if !isnil(st.tone_fx) {
		st.tone_fx()
	}
}

// ── Раздел панели ──

// sync_spot_ui - кнопка режима, число пятен, доступность по st.edit
fn sync_spot_ui(mut st State) {
	if st.spot_sel >= st.edit.spots.len {
		st.spot_sel = -1
	}
	if isnil(st.spot_ui) {
		return
	}
	mut u := st.spot_ui
	mut mb := u.mode_btn
	mb.style = if st.spot_mode { vgui.ButtonStyle.accent } else { vgui.ButtonStyle.outline }
	mb.text = if st.spot_mode { i18n.tr('Готово (Enter)') } else { i18n.tr('Убрать пятна') }
	n := st.edit.spots.len
	mut cl := u.count_lb
	cl.text = if n == 0 {
		i18n.tr('Пятен нет')
	} else if spot_valid(st) {
		i18n.trf('Пятно {0} из {1}', '${st.spot_sel + 1}', '${n}')
	} else {
		'${n} ${i18n.pl(n, 'пятно|пятна|пятен')}'
	}
	mut db := u.del_btn
	db.enabled = spot_valid(st)
	mut sb := u.src_btn
	sb.enabled = spot_valid(st)
	mut cb := u.clr_btn
	cb.enabled = n > 0
	was := st.suppress
	st.suppress = true
	mut kc := u.kind_cb
	kc.set_selected(if st.spot_kind == .clone { 1 } else { 0 })
	mut dc := u.dust_cb
	dc.set_checked(st.dust_show)
	st.suppress = was
	if !isnil(u.m_spots) {
		mut m := u.m_spots
		m.checked = st.spot_mode
	}
}

// spot_slider - ползунок пятна: правит выделенное (история, откат) и
// настройку новых пятен; без выделения - только настройку (st.edit тот
// же - record ничего не пишет). which: 0 - размер, 1 - растушёвка,
// 2 - непрозрачность
fn spot_slider(mut st State, label string, which int, lbl_w f32, val_w f32) &vgui.HBox {
	mut s := edit_slider(mut st, SliderCfg{
		label:  label
		hname:  i18n.trf('Пятно: {0}', '${label.to_lower()}')
		min:    if which == 1 { f32(0) } else { f32(1) }
		max:    100
		def:    [f32(35), 20, 100][which]
		digits: 0
		signed: false
		live:   which == 0
		get:    fn [mut st, which] (e &EditState) f32 {
			i := st.spot_sel
			if i >= 0 && i < e.spots.len {
				p := e.spots[i]
				return [spot_size_of(p.r), p.feather, p.opacity][which]
			}
			return [st.spot_size, st.spot_feather, st.spot_opacity][which]
		}
		set:    fn [mut st, which] (mut e EditState, v f32) {
			match which {
				0 { st.spot_size = v }
				1 { st.spot_feather = v }
				else { st.spot_opacity = v }
			}
			i := st.spot_sel
			if i >= 0 && i < e.spots.len {
				match which {
					0 { e.spots[i].r = spot_radius(v) }
					1 { e.spots[i].feather = v }
					else { e.spots[i].opacity = v }
				}
				// Круг вырос на источник - источник заново (при откате
				// истории ползунки ставятся под suppress - не трогать)
				if which == 0 && !st.suppress {
					e.spots[i] = spot_refit(st, e.spots[i])
				}
			}
			spot_redraw(st)
		}
		fx:     fn [mut st] () {
			st.tone_fx()
		}
	})
	return edit_row(mut st, mut s, lbl_w, val_w)
}

fn build_spot_section(mut st State, lbl_w f32, val_w f32) []SectionRow {
	mut u := &SpotUi{}
	st.spot_ui = u
	mut rows := []SectionRow{}

	mut mode := vgui.button(i18n.tr('Убрать пятна'))
	mode.icon_name = 'bandage'
	mode.style = .outline
	mode.on_click = fn [mut st] () {
		set_spot_mode(mut st, !st.spot_mode)
	}
	u.mode_btn = mode
	mut clr := icon_button('trash-2', i18n.tr('Удалить все пятна'))
	clr.on_click = fn [mut st] () {
		clear_spots(mut st)
	}
	u.clr_btn = clr
	mut mode_row := vgui.create_hbox_fill()
	mode_row.set_spacing(6)
	mode_row.add(mode, flex: 1)
	mode_row.add(clr)
	rows << SectionRow{mode_row}

	// Выделенное пятно: подпись, другой источник, удалить
	mut count := vgui.label(i18n.tr('Пятен нет'))
	st.secondary_labels << count
	u.count_lb = count
	mut src := icon_button('shuffle', i18n.tr('Другой источник для пятна'))
	src.on_click = fn [mut st] () {
		spot_new_source(mut st)
	}
	u.src_btn = src
	mut del := icon_button('x', i18n.tr('Удалить пятно (Delete)'))
	del.on_click = fn [mut st] () {
		delete_spot(mut st)
	}
	u.del_btn = del
	mut sel_row := vgui.create_hbox_fill()
	sel_row.set_spacing(6)
	sel_row.add(count, flex: 1)
	sel_row.add(src)
	sel_row.add(del)
	rows << SectionRow{sel_row}

	mut kind_cb := vgui.combo_box()
	kind_cb.set_items(i18n.tr_all(spot_modes))
	kind_cb.on_change = fn [mut st] (idx int, text string) {
		if st.suppress {
			return
		}
		k := if idx == 1 { pipeline.SpotMode.clone } else { pipeline.SpotMode.heal }
		st.spot_kind = k
		if spot_valid(st) && st.edit.spots[st.spot_sel].mode != k {
			st.edit.spots[st.spot_sel].mode = k
			spot_changed(mut st, 'spot_mode', i18n.trf('Пятно {0}: {1}', '${st.spot_sel + 1}', i18n.tr(spot_modes[idx]).to_lower()))
		}
	}
	u.kind_cb = kind_cb
	mut kind_row := vgui.create_hbox_fill()
	kind_row.set_spacing(6)
	kind_row.add(vgui.label(i18n.tr('Режим')), min: lbl_w)
	kind_row.add(kind_cb, flex: 1)
	kind_row.add(icon_slot(), min: icon_slot_w)
	rows << SectionRow{kind_row}

	rows << SectionRow{spot_slider(mut st, i18n.tr('Размер'), 0, lbl_w, val_w)}
	rows << SectionRow{spot_slider(mut st, i18n.tr('Растушёвка'), 1, lbl_w, val_w)}
	rows << SectionRow{spot_slider(mut st, i18n.tr('Сила'), 2, lbl_w, val_w)}

	// Показ пыли: флажок и усиление карты (вид, не правка)
	mut dust_cb := vgui.checkbox(i18n.tr('Показать пыль'))
	dust_cb.on_change = fn [mut st] (v bool) {
		if !st.suppress && v != st.dust_show {
			set_dust_show(mut st, v)
		}
	}
	u.dust_cb = dust_cb
	rows << SectionRow{dust_cb}
	lb := vgui.label(i18n.tr('Контраст карты'))
	mut vl := value_label('${int(st.dust_amt)}')
	mut sl := vgui.slider_horizontal(0, 100, st.dust_amt)
	sl.step = 1
	sl.wheel = false
	sl.on_change = fn [mut st, mut vl] (v f32) {
		st.dust_amt = v
		vl.text = '${int(v)}'
		if st.dust_show {
			defer_fx(mut st, st.tone_fx)
		}
	}
	rows << SectionRow{slider_row(mut st, lb, mut sl, vl, 50, lbl_w, val_w)}

	mut hint := vgui.label(i18n.tr('Щелчок по снимку - пятно, источник ищется сам'))
	hint.font_size = 12
	st.hint_labels << hint
	rows << SectionRow{hint}
	mut hint2 := vgui.label(i18n.tr('Тяните круг, его край или голубой источник'))
	hint2.font_size = 12
	st.hint_labels << hint2
	rows << SectionRow{hint2}
	sync_spot_ui(mut st)
	return rows
}
