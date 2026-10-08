module main

// Кадрирование и поворот: секция «Кадрирование и поворот», режим
// кадрирования на холсте (рамка, ручки, сетка, линия горизонта).
//
// Всё хранится в EditState (история, сайдкар, пресеты): геометрия
// pipeline.Geom - ориентация, угол, рамка в долях повёрнутого кадра R -
// и ограничения рамки (пропорция, размер на выход). Превью и экспорт
// применяют геометрию одинаково (pipeline/geom.v) после подготовки сырья.
//
// Режим кадрирования (кнопка, R, «Правка - Кадрирование»): холст
// показывает весь повёрнутый кадр R, рамка рисуется поверх (on_overlay -
// без пересчёта снимка); вне режима превью - уже обрезанный кадр,
// гистограмма - по нему. Мышь в режиме: ручки углов и сторон, внутри
// рамки - перенос, снаружи - поворот кадра (как в Lightroom), Ctrl+
// перетаскивание снаружи - новая рамка, двойной щелчок - вся рамка.
// Enter - применить (выйти), Esc - отменить правки режима. Каждое
// отпускание - запись в истории (Ctrl+Z работает и в режиме).
import math
import vgui
import pipeline

// Пропорции: ключи (EditState.crop_aspect, settings) и названия. Заданы
// горизонтальными, crop_portrait меняет стороны местами
const crop_aspects = ['', 'shot', '1:1', '3:2', '4:3', '5:4', '7:5', '16:9', '16:10', '2:1',
	'65:24', 'custom']
const crop_aspect_names = ['Свободно', 'Как снято', '1:1', '3:2', '4:3', '5:4 (4:5 Instagram)',
	'7:5', '16:9 (9:16 сторис)', '16:10', '2:1', '65:24 (панорама XPan)', 'Своя']
const crop_grids = ['thirds', 'diagonal', 'golden', 'none']
const crop_grid_names = ['Трети', 'Диагонали', 'Золотое сечение', 'Нет']

// Ручки рамки: углы (0 - левый верхний, по часовой) и стороны (4 - верх,
// 5 - право, 6 - низ, 7 - лево)
const crop_handle_px = f32(10) // радиус захвата ручки на экране
const crop_min_px = f64(8) // наименьшая сторона рамки, пиксели превью

enum CropDragKind {
	none
	move
	handle
	horizon
	persp  // линия для перспективы (инструмент «по двум линиям»)
	rotate // поворот кадра перетаскиванием снаружи рамки
}

struct CropDrag {
mut:
	kind   CropDragKind
	handle int
	start  pipeline.CropBox
	sign_x f64 // направление угла от опоры (новая рамка - по ходу мыши)
	sign_y f64
	px     f64 // точка нажатия, пиксели R
	py     f64
	cx     f64 // текущая точка (линия горизонта)
	cy     f64
	geom   pipeline.Geom // геометрия на момент нажатия (поворот)
	a0     f64           // угол мыши вокруг центра рамки при нажатии, радианы
	moved  bool
}

// CropUi - виджеты секции (sync_crop_ui выставляет их из st.edit)
@[heap]
struct CropUi {
mut:
	mode_btn    &vgui.Button   = unsafe { nil }
	aspect_cb   &vgui.ComboBox = unsafe { nil }
	orient_btn  &vgui.Button   = unsafe { nil }
	aw          &vgui.Spinbox  = unsafe { nil }
	ah          &vgui.Spinbox  = unsafe { nil }
	total       &vgui.Label    = unsafe { nil }
	grid_cb     &vgui.ComboBox = unsafe { nil }
	horizon_btn &vgui.Button   = unsafe { nil }
	persp_btn   &vgui.Button   = unsafe { nil } // перспектива по двум линиям
	angle_sl    &vgui.Slider   = unsafe { nil }
	pv_sl       &vgui.Slider   = unsafe { nil } // перспектива: вертикаль
	ph_sl       &vgui.Slider   = unsafe { nil } // и горизонталь
	angle_in    &vgui.TextInput = unsafe { nil } // угол вручную (Enter)
	m_crop      &vgui.MenuItem = unsafe { nil }
}

// ── Размеры и пропорции ──

// crop_frame - размер повёрнутого кадра R на превью (W0 x H0)
fn crop_frame(st &State) (int, int) {
	return st.edit.geom.oriented(st.pw, st.ph)
}

// full_size - размер полного кадра (как отдаёт LibRaw, до геометрии)
fn full_size(st &State) (int, int) {
	if !isnil(st.dev) {
		w, h := st.dev.full_size()
		if w > 0 && h > 0 {
			return w, h
		}
	}
	return st.pw * 2, st.ph * 2
}

// crop_ratio - пропорция рамки (ширина / высота в пикселях) по настройкам
// кадра e; 0 - свободная. w0 x h0 - повёрнутый кадр («как снято»).
fn crop_ratio(e &EditState, w0 int, h0 int) f64 {
	mut r := match e.crop_aspect {
		'' {
			return 0
		}
		'shot' {
			if w0 > 0 && h0 > 0 { math.max(f64(w0), f64(h0)) / math.min(f64(w0), f64(h0)) } else { 1.5 }
		}
		'custom' {
			if e.crop_aw > 0 && e.crop_ah > 0 { f64(e.crop_aw) / f64(e.crop_ah) } else { 1.5 }
		}
		else {
			parts := e.crop_aspect.split(':')
			if parts.len == 2 && parts[1].f64() > 0 { parts[0].f64() / parts[1].f64() } else { 1.5 }
		}
	}
	if e.crop_portrait {
		r = 1 / r
	}
	return r
}

// out_geom - геометрия для выхода: у числовой пропорции (не свободной и
// не «как снято») высота выхода считается по ширине - 1:1 ровно квадрат
fn out_geom(e &EditState) pipeline.Geom {
	mut g := e.geom
	if e.crop_aspect != '' && e.crop_aspect != 'shot' {
		g.aspect = f32(crop_ratio(e, 3, 2))
	}
	return g
}

// crop_size - размер обрезанного полного кадра (до размера на выход -
// он в окне «Экспорт»)
fn crop_size(e &EditState, full_w int, full_h int) (int, int) {
	return out_geom(e).out_size(full_w, full_h, true)
}

fn size_text(w int, h int) string {
	return '${w} × ${h}'
}

// ── Правки геометрии ──

// crop_apply - новая геометрия кадра: снимок, пересчёт превью, панель и
// запись в истории (key - ключ склейки, name - название)
fn crop_apply(mut st State, g pipeline.Geom, key string, name string, merge bool) {
	st.edit.geom = g
	st.tone_fx()
	sync_crop_ui(mut st)
	record(mut st, key, name, merge)
}

// refit - рамка после смены угла: была наибольшей по центру - снова
// наибольшая при новом угле (рамка сама растёт и сжимается); иначе
// сжимается к своему центру, пока не уйдут пустые углы
fn refit(old pipeline.Geom, g pipeline.Geom, w0 int, h0 int) pipeline.Geom {
	b := old.box_of(w0, h0)
	if b.h() <= 0 {
		return g
	}
	a := b.w() / b.h()
	cx := f64(w0) / 2
	cy := f64(h0) / 2
	was_max := b.w() >= 0.995 * old.max_box(a, cx, cy, w0, h0).w()
		&& math.abs((b.x0 + b.x1) / 2 - cx) < 1 && math.abs((b.y0 + b.y1) / 2 - cy) < 1
	if was_max {
		return g.with_box(g.max_box(a, cx, cy, w0, h0), w0, h0)
	}
	mx := (b.x0 + b.x1) / 2
	my := (b.y0 + b.y1) / 2
	dot := pipeline.CropBox{mx, my, mx, my}
	if g.fits(dot, w0, h0) {
		return g.with_box(g.fit_toward(dot, b, w0, h0), w0, h0)
	}
	return g.with_box(g.max_box(a, cx, cy, w0, h0), w0, h0)
}

// set_angle - угол поворота (градусы) с подгонкой рамки
fn geom_with_angle(st &State, v f32) pipeline.Geom {
	w0, h0 := crop_frame(st)
	mut g := st.edit.geom
	g.angle = f32(math.max(-pipeline.geom_angle_max, math.min(pipeline.geom_angle_max,
		v)))
	return refit(st.edit.geom, g, w0, h0)
}

// rotate90 - поворот на 90° (dir 1 - по часовой, -1 - против): рамка и
// пропорция поворачиваются вместе с кадром
fn rotate90(mut st State, dir int) {
	mut g := st.edit.geom
	g.rot90 = ((g.rot90 + dir) % 4 + 4) % 4
	x0, y0, x1, y1 := g.x0, g.y0, g.x1, g.y1
	if dir > 0 {
		// По часовой: левый край рамки становится верхним
		g.x0, g.y0, g.x1, g.y1 = 1 - y1, x0, 1 - y0, x1
	} else {
		g.x0, g.y0, g.x1, g.y1 = y0, 1 - x1, y1, 1 - x0
	}
	if st.edit.crop_aspect != '' {
		st.edit.crop_portrait = !st.edit.crop_portrait
	}
	crop_apply(mut st, g, 'rot90', if dir > 0 { 'Поворот на 90° по часовой' } else { 'Поворот на 90° против часовой' },
		false)
}

// flip_frame - отражение (h - по горизонтали): рамка отражается, угол меняет знак
fn flip_frame(mut st State, h bool) {
	mut g := st.edit.geom
	if h {
		g.flip_h = !g.flip_h
		g.x0, g.x1 = 1 - g.x1, 1 - g.x0
	} else {
		g.flip_v = !g.flip_v
		g.y0, g.y1 = 1 - g.y1, 1 - g.y0
	}
	g.angle = -g.angle
	crop_apply(mut st, g, 'flip', if h { 'Отражение по горизонтали' } else { 'Отражение по вертикали' },
		false)
}

// fit_ratio - рамка под пропорцию кадра (после смены пропорции,
// ориентации рамки, размера): наибольшая с тем же центром
fn fit_ratio(mut st State, name string) {
	w0, h0 := crop_frame(st)
	g := st.edit.geom
	a := crop_ratio(&st.edit, w0, h0)
	if a <= 0 {
		crop_apply(mut st, g, 'crop_ratio', name, false)
		return
	}
	b := g.box_of(w0, h0)
	nb := g.best_box(a, (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, w0, h0)
	crop_apply(mut st, g.with_box(nb, w0, h0), 'crop_ratio', name, false)
}

// reset_crop - без кадрирования и поворота (пропорция и размер остаются)
fn reset_crop(mut st State) {
	crop_apply(mut st, pipeline.Geom{}, 'crop_reset', 'Кадрирование: сброс', false)
}

// ── Режим кадрирования ──

// set_crop_mode - вход в режим (весь кадр, рамка поверх) и выход (кадр
// обрезается). Вход в кадр без рамки - пропорция последнего выбора.
fn set_crop_mode(mut st State, on bool) {
	if on == st.crop_mode {
		sync_crop_ui(mut st)
		return
	}
	if on && (st.linear.len == 0 || st.suppress) {
		sync_crop_ui(mut st)
		return
	}
	st.crop_mode = on
	st.crop_drag = CropDrag{}
	if on {
		set_wb_pick(mut st, false)
		if st.spot_mode {
			set_spot_mode(mut st, false)
		}
		st.crop_before = st.edit.clone()
		// Кадр без рамки и без выбранной пропорции - последняя выбранная
		// (по ориентации кадра), рамка - наибольшая
		if st.edit.geom.is_identity() && st.edit.crop_aspect == ''
			&& st.settings.crop_aspect != '' {
			w0, h0 := crop_frame(st)
			st.edit.crop_aspect = st.settings.crop_aspect
			st.edit.crop_portrait = h0 > w0 && st.edit.crop_aspect != 'shot'
			a := crop_ratio(&st.edit, w0, h0)
			st.edit.geom = st.edit.geom.with_box(st.edit.geom.max_box(a, f64(w0) / 2,
				f64(h0) / 2, w0, h0), w0, h0)
			record(mut st, 'crop_ratio', 'Пропорция: ${aspect_name(st.edit)}', false)
		}
	} else {
		st.horizon = false
	st.persp_tool = false
		vgui.set_cursor(vgui.sdl_system_cursor_default)
	}
	st.tone_fx()
	sync_crop_ui(mut st)
}

// crop_cancel - Esc: вернуть кадрирование к состоянию при входе в режим
fn crop_cancel(mut st State) {
	if !st.crop_mode {
		return
	}
	b := st.crop_before
	changed := b.geom != st.edit.geom || b.crop_aspect != st.edit.crop_aspect
		|| b.crop_portrait != st.edit.crop_portrait
	st.edit.geom = b.geom
	st.edit.crop_aspect = b.crop_aspect
	st.edit.crop_aw = b.crop_aw
	st.edit.crop_ah = b.crop_ah
	st.edit.crop_portrait = b.crop_portrait
	st.crop_mode = false
	st.horizon = false
	st.persp_tool = false
	st.crop_drag = CropDrag{}
	vgui.set_cursor(vgui.sdl_system_cursor_default)
	set_edit(mut st, st.edit)
	st.tone_fx()
	sync_crop_ui(mut st)
	if changed {
		record(mut st, 'crop_cancel', 'Кадрирование: отмена', false)
	}
}

// crop_leave - выход из режима без пересчёта (смена или закрытие кадра)
fn crop_leave(mut st State) {
	st.crop_mode = false
	st.horizon = false
	st.persp_tool = false
	st.crop_drag = CropDrag{}
	sync_crop_ui(mut st)
}

// persp_line_done - проведена линия перспективы: первая запоминается,
// после второй - перспектива и наклон, при которых линии станут
// вертикальными или горизонтальными (pipeline.persp_lines), рамка
// подгоняется как при смене угла
fn persp_line_done(mut st State, d CropDrag) {
	if math.hypot(d.cx - d.px, d.cy - d.py) < 10 {
		return // щелчок без линии
	}
	iw0, ih0 := crop_frame(st)
	w0 := f64(iw0)
	h0 := f64(ih0)
	g := st.edit.geom
	// Точки R -> V' (снять наклон) -> V (снимок без перспективы)
	to_v := fn [g, w0, h0] (x f64, y f64) (f64, f64) {
		qx, qy := g.r_to_v(x, y, w0, h0)
		return pipeline.persp_to_v(g, w0, h0, qx, qy)
	}
	ax, ay := to_v(d.px, d.py)
	bx, by := to_v(d.cx, d.cy)
	line := [ax, ay, bx, by]
	if st.persp_l1.len != 4 {
		st.persp_l1 = [d.px, d.py, d.cx, d.cy]
		st.persp_v1 = line
		return
	}
	fit := pipeline.persp_lines([st.persp_v1, line], w0, h0, g)
	st.persp_tool = false
	st.persp_l1 = []f64{}
	mut ng := geom_with_angle(st, fit.angle)
	ng.pv = fit.pv
	ng.ph = fit.ph
	crop_apply(mut st, ng, 'persp_lines', 'Перспектива по линиям: ${int(fit.pv)}, ${int(fit.ph)}, ${angle_text(fit.angle)}',
		false)
}

// upright_names - кнопки и записи истории автоперспективы
// (pipeline.UprightMode по порядку)
const upright_names = ['Уровень', 'Вертикали', 'Полностью']

// upright_apply - автоперспектива (pipeline/upright.v): прямые линии
// сырья после объектива (то, что на холсте до геометрии), подбор наклона
// и перспективы по режиму; рамка подгоняется как при смене угла.
// Мало линий - предупреждение, геометрия не меняется
fn upright_apply(mut st State, mode pipeline.UprightMode) {
	if st.raw_linear.len < st.pw * st.ph * 3 || st.pw <= 0 {
		return
	}
	g := st.edit.geom
	segs := pipeline.upright_segments(unsafe { &u16(st.raw_linear.data) }, st.pw, st.ph,
		g)
	w0, h0 := crop_frame(st)
	name := upright_names[int(mode)]
	fit := pipeline.upright_fit(segs, w0, h0, mode) or {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_warning('Автоперспектива: на снимке мало прямых линий')
		}
		return
	}
	mut ng := geom_with_angle(st, fit.angle)
	ng.pv = fit.pv
	ng.ph = fit.ph
	crop_apply(mut st, ng, 'upright', 'Автоперспектива (${name.to_lower()}): ${int(fit.pv)}, ${int(fit.ph)}, ${angle_text(fit.angle)}',
		false)
}

// ── Мышь в режиме кадрирования ──

// crop_hit - что под курсором (экранные координаты): ручка 0..7, 8 -
// внутри рамки, -1 - снаружи
fn crop_hit(st &State, sx f32, sy f32) int {
	if isnil(st.cv) {
		return -1
	}
	cv := st.cv
	w0, h0 := crop_frame(st)
	b := st.edit.geom.box_of(w0, h0)
	pts := handle_points(b)
	for i, p in pts {
		hx, hy := cv.buf_to_screen(f32(p[0]), f32(p[1]))
		if math.abs(hx - sx) <= crop_handle_px && math.abs(hy - sy) <= crop_handle_px {
			return i
		}
	}
	bx0, by0 := cv.buf_to_screen(f32(b.x0), f32(b.y0))
	bx1, by1 := cv.buf_to_screen(f32(b.x1), f32(b.y1))
	if sx > bx0 && sx < bx1 && sy > by0 && sy < by1 {
		return 8
	}
	return -1
}

// handle_points - точки ручек рамки: углы по часовой с левого верхнего,
// затем середины сторон (верх, право, низ, лево)
fn handle_points(b pipeline.CropBox) [][]f64 {
	mx := (b.x0 + b.x1) / 2
	my := (b.y0 + b.y1) / 2
	return [[b.x0, b.y0], [b.x1, b.y0], [b.x1, b.y1], [b.x0, b.y1],
		[mx, b.y0], [b.x1, my], [mx, b.y1], [b.x0, my]]
}

// hit_cursor - курсор над точкой: ручки - стрелки размера, внутри -
// перенос, снаружи - рука (поворот; своего курсора поворота в SDL нет),
// с Ctrl - крест (новая рамка)
fn hit_cursor(hit int, horizon bool, ctrl bool) int {
	if horizon || (hit < 0 && ctrl) {
		return vgui.sdl_system_cursor_crosshair
	}
	return match hit {
		0, 2 { vgui.sdl_system_cursor_sizenwse }
		1, 3 { vgui.sdl_system_cursor_sizenesw }
		4, 6 { vgui.sdl_system_cursor_sizens }
		5, 7 { vgui.sdl_system_cursor_sizewe }
		8 { vgui.sdl_system_cursor_sizeall }
		else { vgui.sdl_system_cursor_hand }
	}
}

// handle_box - рамка при перетаскивании ручки h в точку (mx, my), a -
// пропорция (0 - свободная); без проверки кадра
fn handle_box(d CropDrag, mx f64, my f64, a f64) pipeline.CropBox {
	b := d.start
	h := d.handle
	if h < 4 {
		// Угол: опора - противоположный
		ax := if h == 0 || h == 3 { b.x1 } else { b.x0 }
		ay := if h == 0 || h == 1 { b.y1 } else { b.y0 }
		mut w := math.max(crop_min_px, d.sign_x * (mx - ax))
		mut hh := math.max(crop_min_px, d.sign_y * (my - ay))
		if a > 0 {
			if w / hh > a {
				hh = w / a
			} else {
				w = hh * a
			}
		}
		x1 := ax + d.sign_x * w
		y1 := ay + d.sign_y * hh
		return pipeline.CropBox{math.min(ax, x1), math.min(ay, y1), math.max(ax, x1), math.max(ay, y1)}
	}
	cx := (b.x0 + b.x1) / 2
	cy := (b.y0 + b.y1) / 2
	match h {
		4, 6 {
			// Верх / низ: опора - противоположная сторона
			hh := if h == 4 { math.max(crop_min_px, b.y1 - my) } else { math.max(crop_min_px, my - b.y0) }
			y0 := if h == 4 { b.y1 - hh } else { b.y0 }
			if a > 0 {
				w := hh * a
				return pipeline.CropBox{cx - w / 2, y0, cx + w / 2, y0 + hh}
			}
			return pipeline.CropBox{b.x0, y0, b.x1, y0 + hh}
		}
		else {
			w := if h == 7 { math.max(crop_min_px, b.x1 - mx) } else { math.max(crop_min_px, mx - b.x0) }
			x0 := if h == 7 { b.x1 - w } else { b.x0 }
			if a > 0 {
				hh := w / a
				return pipeline.CropBox{x0, cy - hh / 2, x0 + w, cy + hh / 2}
			}
			return pipeline.CropBox{x0, b.y0, x0 + w, b.y1}
		}
	}
}

// crop_input - события холста в режиме кадрирования; true - обработано
fn crop_input(mut st State, ev &vgui.CanvasInputEvent) bool {
	if !st.crop_mode || isnil(st.cv) {
		return false
	}
	cv := st.cv
	w0, h0 := crop_frame(st)
	g := st.edit.geom
	sx, sy := cv.buf_to_screen(ev.fx, ev.fy)
	mx := f64(ev.fx)
	my := f64(ev.fy)
	match ev.kind {
		.hover {
			vgui.set_cursor(hit_cursor(crop_hit(st, sx, sy), st.horizon || st.persp_tool,
				ev.ctrl))
		}
		.leave {
			vgui.set_cursor(vgui.sdl_system_cursor_default)
		}
		.pointer_down {
			if ev.button != 1 {
				return false
			}
			if st.horizon || st.persp_tool {
				st.crop_drag = CropDrag{
					kind: if st.persp_tool { CropDragKind.persp } else { CropDragKind.horizon }
					px:   mx
					py:   my
					cx:   mx
					cy:   my
				}
				return true
			}
			hit := crop_hit(st, sx, sy)
			if ev.clicks >= 2 {
				// Двойной щелчок - вся рамка (наибольшая по центру)
				a := crop_ratio(&st.edit, w0, h0)
				nb := g.max_box(a, f64(w0) / 2, f64(h0) / 2, w0, h0)
				crop_apply(mut st, g.with_box(nb, w0, h0), 'crop_box', 'Кадрирование: вся рамка',
					false)
				st.crop_drag = CropDrag{}
				return true
			}
			b := g.box_of(w0, h0)
			if hit >= 0 && hit < 8 {
				st.crop_drag = CropDrag{
					kind:   .handle
					handle: hit
					start:  b
					sign_x: if hit == 0 || hit == 3 { -1.0 } else { 1.0 }
					sign_y: if hit == 0 || hit == 1 { -1.0 } else { 1.0 }
					px:     mx
					py:     my
				}
			} else if hit == 8 {
				st.crop_drag = CropDrag{
					kind:  .move
					start: b
					px:    mx
					py:    my
				}
			} else if !ev.ctrl {
				// Снаружи - поворот кадра вокруг центра рамки
				cx := (b.x0 + b.x1) / 2
				cy := (b.y0 + b.y1) / 2
				st.crop_drag = CropDrag{
					kind:  .rotate
					start: b
					geom:  g
					a0:    math.atan2(my - cy, mx - cx)
					px:    mx
					py:    my
				}
			} else {
				// Ctrl снаружи - новая рамка от точки (угол 2, опора - точка)
				nx := math.max(0, math.min(f64(w0), mx))
				ny := math.max(0, math.min(f64(h0), my))
				dot := pipeline.CropBox{nx, ny, nx, ny}
				if !g.fits(dot, w0, h0) {
					return true
				}
				st.crop_drag = CropDrag{
					kind:   .handle
					handle: 2
					start:  dot
					sign_x: 0
					sign_y: 0
					px:     nx
					py:     ny
				}
			}
			return true
		}
		.pointer_move {
			mut d := st.crop_drag
			match d.kind {
				.none {
					return false
				}
				.horizon, .persp {
					st.crop_drag.cx = mx
					st.crop_drag.cy = my
					return true
				}
				.rotate {
					if !d.moved && math.abs(mx - d.px) < 2 && math.abs(my - d.py) < 2 {
						return true
					}
					st.crop_drag.moved = true
					// Мышь по часовой (y вниз) - кадр по часовой, а плюс угла -
					// против часовой. Отсчёт от геометрии нажатия: рамка,
					// сжатая на большом угле, вернётся при обратном повороте
					cx := (d.start.x0 + d.start.x1) / 2
					cy := (d.start.y0 + d.start.y1) / 2
					mut da := math.atan2(my - cy, mx - cx) - d.a0
					if da > math.pi {
						da -= 2 * math.pi
					} else if da < -math.pi {
						da += 2 * math.pi
					}
					mut ng := d.geom
					lim := f64(pipeline.geom_angle_max)
					v := math.max(-lim, math.min(lim, f64(d.geom.angle) - da * 180 / math.pi))
					ng.angle = f32(math.round(v * 10) / 10)
					if ng.angle != st.edit.geom.angle {
						st.edit.geom = refit(d.geom, ng, w0, h0)
						sync_crop_ui(mut st)
						defer_fx(mut st, st.tone_fx)
					}
					return true
				}
				.move {
					dx := mx - d.px
					dy := my - d.py
					s := d.start
					// Сначала по x, затем по y - рамка скользит вдоль края
					tx := pipeline.CropBox{s.x0 + dx, s.y0, s.x1 + dx, s.y1}
					bx := g.fit_toward(s, tx, w0, h0)
					ty := pipeline.CropBox{bx.x0, bx.y0 + dy, bx.x1, bx.y1 + dy}
					nb := g.fit_toward(bx, ty, w0, h0)
					st.edit.geom = g.with_box(nb, w0, h0)
				}
				.handle {
					if d.sign_x == 0 {
						// Новая рамка - направление по первому движению
						if math.abs(mx - d.px) < 2 && math.abs(my - d.py) < 2 {
							return true
						}
						d.sign_x = if mx >= d.px { 1.0 } else { -1.0 }
						d.sign_y = if my >= d.py { 1.0 } else { -1.0 }
						d.handle = if d.sign_x > 0 {
							if d.sign_y > 0 { 2 } else { 1 }
						} else {
							if d.sign_y > 0 { 3 } else { 0 }
						}
						st.crop_drag = d
					}
					a := crop_ratio(&st.edit, w0, h0)
					to := handle_box(d, mx, my, a)
					// От стартовой рамки к цели - до края кадра (новая
					// рамка: старт - точка, путь сохраняет пропорцию)
					from := if d.start.w() <= 0 {
						pipeline.CropBox{d.px, d.py, d.px, d.py}
					} else {
						d.start
					}
					nb := g.fit_toward(from, to, w0, h0)
					if nb.w() >= 1 && nb.h() >= 1 {
						st.edit.geom = g.with_box(nb, w0, h0)
					}
				}
			}
			st.crop_drag.moved = true
			sync_crop_total(mut st)
			return true
		}
		.pointer_up {
			d := st.crop_drag
			st.crop_drag = CropDrag{}
			match d.kind {
				.persp {
					persp_line_done(mut st, d)
				}
				.horizon {
					st.horizon = false
	st.persp_tool = false
					corr := pipeline.horizon_angle(d.px, d.py, d.cx, d.cy)
					if corr != 0 {
						ng := geom_with_angle(st, st.edit.geom.angle + corr)
						crop_apply(mut st, ng, 'angle', 'Выпрямление: ${angle_text(ng.angle)}',
							false)
					} else {
						sync_crop_ui(mut st)
					}
				}
				.rotate {
					if d.moved && st.edit.geom != d.geom {
						crop_apply(mut st, st.edit.geom, 'angle', 'Поворот: ${angle_text(st.edit.geom.angle)}',
							false)
					}
				}
				.move, .handle {
					if d.moved {
						crop_apply(mut st, st.edit.geom, 'crop_box', 'Кадрирование: рамка',
							false)
					}
				}
				.none {}
			}
			return true
		}
		else {}
	}
	return false
}

// parse_angle - угол, введённый вручную: «-2.5», «−2,5», «+3», «3°»;
// «ю» и «б» - тоже разделитель (клавиши точки и запятой в русской
// раскладке); none - не число. Ограничение ±45 - у вызывающего
fn parse_angle(s string) ?f32 {
	mut t := s.trim_space().replace('°', '').replace('−', '-')
	for sep in [',', 'ю', 'Ю', 'б', 'Б'] {
		t = t.replace(sep, '.')
	}
	t = t.trim_space()
	if t.len == 0 {
		return none
	}
	body := t.trim_left('+-')
	if body.len == 0 || !body.contains_any('0123456789')
		|| !body.contains_only('0123456789.') || body.count('.') > 1 || t.len - body.len > 1 {
		return none
	}
	return f32(t.f64())
}

// set_angle_text - угол, введённый в поле: применить с подгонкой рамки
// (как ползунок) и записью в историю; не число - поле возвращается
fn set_angle_text(mut st State, s string) {
	v := parse_angle(s) or {
		sync_crop_ui(mut st)
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_warning('Угол - число от -45 до 45 градусов')
		}
		return
	}
	if st.linear.len == 0 {
		sync_crop_ui(mut st)
		return
	}
	ng := geom_with_angle(st, f32(math.round(f64(v) * 10) / 10))
	if ng != st.edit.geom {
		crop_apply(mut st, ng, 'angle', 'Угол: ${angle_text(ng.angle)}', false)
	}
	// Поле в фокусе sync_crop_ui не трогает - привести к виду «-3.5» здесь
	if !isnil(st.crop_ui) && !isnil(st.crop_ui.angle_in) {
		mut ai := st.crop_ui.angle_in
		ai.set_text('${st.edit.geom.angle:.1f}')
	}
}

fn angle_text(a f32) string {
	return if a > 0 { '+${a:.1f}°' } else { '${a:.1f}°' }
}

fn aspect_name(e EditState) string {
	i := crop_aspects.index(e.crop_aspect)
	n := if i < 0 { crop_aspect_names[0] } else { crop_aspect_names[i] }
	return if e.crop_portrait && e.crop_aspect != '' { '${n}, вертикально' } else { n }
}

// ── Рисование поверх холста ──

const crop_shade = vgui.Color{0, 0, 0, 150}
const crop_line = vgui.Color{255, 255, 255, 230}
const crop_guide = vgui.Color{255, 255, 255, 110}
const crop_fine = vgui.Color{255, 255, 255, 60}
const crop_dark = vgui.Color{0, 0, 0, 200}
const crop_horizon = vgui.Color{255, 214, 10, 255}

fn crop_overlay(mut st State, mut ctx vgui.RenderContext) {
	if !st.crop_mode || isnil(st.cv) || st.linear.len == 0 {
		return
	}
	cv := st.cv
	w0, h0 := crop_frame(st)
	if cv.width != w0 || cv.height != h0 {
		return // превью ещё не пересчитано под режим
	}
	b := st.edit.geom.box_of(w0, h0)
	ix0, iy0 := cv.buf_to_screen(0, 0)
	ix1, iy1 := cv.buf_to_screen(f32(w0), f32(h0))
	bx0, by0 := cv.buf_to_screen(f32(b.x0), f32(b.y0))
	bx1, by1 := cv.buf_to_screen(f32(b.x1), f32(b.y1))
	// Затемнение вне рамки
	ctx.fill_rect(vgui.Rect{ix0, iy0, ix1 - ix0, by0 - iy0}, crop_shade)
	ctx.fill_rect(vgui.Rect{ix0, by1, ix1 - ix0, iy1 - by1}, crop_shade)
	ctx.fill_rect(vgui.Rect{ix0, by0, bx0 - ix0, by1 - by0}, crop_shade)
	ctx.fill_rect(vgui.Rect{bx1, by0, ix1 - bx1, by1 - by0}, crop_shade)
	bw := bx1 - bx0
	bh := by1 - by0
	// Мелкая сетка, пока крутят угол или ведут линию горизонта
	rotating := (!isnil(st.crop_ui) && !isnil(st.crop_ui.angle_sl) && st.crop_ui.angle_sl.dragging)
		|| st.horizon || st.persp_tool || st.crop_drag.kind == .rotate
	if rotating {
		step := f32(40)
		mut x := bx0 + step
		for x < bx1 {
			ctx.draw_line(x, by0, x, by1, crop_fine)
			x += step
		}
		mut y := by0 + step
		for y < by1 {
			ctx.draw_line(bx0, y, bx1, y, crop_fine)
			y += step
		}
	}
	// Направляющие композиции
	match st.settings.crop_grid {
		'thirds', 'golden' {
			f := if st.settings.crop_grid == 'thirds' { f32(1.0 / 3.0) } else { f32(0.381966) }
			for t in [f, 1 - f] {
				ctx.draw_line(bx0 + bw * t, by0, bx0 + bw * t, by1, crop_guide)
				ctx.draw_line(bx0, by0 + bh * t, bx1, by0 + bh * t, crop_guide)
			}
		}
		'diagonal' {
			// Из каждого угла под 45° на длину короткой стороны
			l := if bw < bh { bw } else { bh }
			ctx.draw_line(bx0, by0, bx0 + l, by0 + l, crop_guide)
			ctx.draw_line(bx1, by0, bx1 - l, by0 + l, crop_guide)
			ctx.draw_line(bx0, by1, bx0 + l, by1 - l, crop_guide)
			ctx.draw_line(bx1, by1, bx1 - l, by1 - l, crop_guide)
		}
		else {}
	}
	// Рамка и ручки
	ctx.draw_rect(vgui.Rect{bx0 - 1, by0 - 1, bw + 2, bh + 2}, crop_dark)
	ctx.draw_rect(vgui.Rect{bx0, by0, bw, bh}, crop_line)
	for p in handle_points(b) {
		hx, hy := cv.buf_to_screen(f32(p[0]), f32(p[1]))
		ctx.fill_rect(vgui.Rect{hx - 4, hy - 4, 8, 8}, crop_dark)
		ctx.fill_rect(vgui.Rect{hx - 3, hy - 3, 6, 6}, crop_line)
	}
	// Итоговый размер - у нижнего края рамки
	fw_, fh_ := full_size(st)
	fw, fh := crop_size(&st.edit, fw_, fh_)
	label := '${size_text(fw, fh)} px'
	lw := f32(label.runes().len) * 7.5 + 12
	if bw > lw + 8 && bh > 30 {
		ctx.fill_rect(vgui.Rect{bx0 + 4, by1 - 24, lw, 20}, vgui.Color{0, 0, 0, 170})
		ctx.draw_text(label, bx0 + 9, by1 - 22, crop_line)
	}
	d := st.crop_drag
	// Угол - у верхнего края рамки, пока кадр поворачивают мышью
	if d.kind == .rotate && d.moved {
		at := angle_text(st.edit.geom.angle)
		aw := f32(at.runes().len) * 7.5 + 12
		ctx.fill_rect(vgui.Rect{bx0 + (bw - aw) / 2, by0 + 4, aw, 20}, vgui.Color{0, 0, 0, 170})
		ctx.draw_text(at, bx0 + (bw - aw) / 2 + 6, by0 + 6, crop_line)
	}
	// Линия горизонта и линии перспективы (первая - уже проведена)
	if d.kind == .horizon || d.kind == .persp {
		ax, ay := cv.buf_to_screen(f32(d.px), f32(d.py))
		cx, cy := cv.buf_to_screen(f32(d.cx), f32(d.cy))
		ctx.draw_line_thick(ax, ay, cx, cy, 2, crop_horizon)
	}
	if st.persp_tool && st.persp_l1.len == 4 {
		l := st.persp_l1
		ax, ay := cv.buf_to_screen(f32(l[0]), f32(l[1]))
		cx, cy := cv.buf_to_screen(f32(l[2]), f32(l[3]))
		ctx.draw_line_thick(ax, ay, cx, cy, 2, crop_horizon)
	}
}

// box_pixels - пиксели RGBA холста w x h внутри рамки (гистограмма в
// режиме кадрирования)
fn box_pixels(st &State, pix []u8, w int, h int) []u8 {
	b := st.edit.geom.box_of(w, h)
	x0 := int(math.max(0, math.min(f64(w), b.x0)))
	x1 := int(math.max(0, math.min(f64(w), b.x1)))
	y0 := int(math.max(0, math.min(f64(h), b.y0)))
	y1 := int(math.max(0, math.min(f64(h), b.y1)))
	if x1 <= x0 || y1 <= y0 || pix.len < w * h * 4 {
		return pix
	}
	rw := x1 - x0
	mut out := []u8{len: rw * (y1 - y0) * 4}
	for y in y0 .. y1 {
		unsafe { vmemcpy(&u8(out.data) + (y - y0) * rw * 4, &u8(pix.data) + (y * w + x0) * 4,
			rw * 4) }
	}
	return out
}

// ── Панель ──

// sync_crop_ui - виджеты секции из st.edit (списки set_selected не зовут
// on_change; поля ввода - под suppress)
fn sync_crop_ui(mut st State) {
	if isnil(st.crop_ui) {
		return
	}
	mut u := st.crop_ui
	e := st.edit
	mut mb := u.mode_btn
	mb.style = if st.crop_mode { vgui.ButtonStyle.accent } else { vgui.ButtonStyle.outline }
	mb.text = if st.crop_mode { 'Готово (Enter)' } else { 'Кадрировать' }
	mut acb := u.aspect_cb
	acb.set_selected(math.max(0, crop_aspects.index(e.crop_aspect)))
	mut ob := u.orient_btn
	ob.icon_name = if e.crop_portrait { 'rectangle-vertical' } else { 'rectangle-horizontal' }
	was := st.suppress
	st.suppress = true
	mut aw := u.aw
	mut ah := u.ah
	aw.set_value(e.crop_aw)
	ah.set_value(e.crop_ah)
	aw.enabled = e.crop_aspect == 'custom'
	ah.enabled = aw.enabled
	if !isnil(u.angle_sl) {
		mut asl := u.angle_sl
		asl.set_value(e.geom.angle) // под suppress: подпись и снимок, без пересчёта
	}
	// Перспектива (меняется и инструментом «по двум линиям»)
	if !isnil(u.pv_sl) && !u.pv_sl.dragging {
		mut s := u.pv_sl
		s.set_value(e.geom.pv)
	}
	if !isnil(u.ph_sl) && !u.ph_sl.dragging {
		mut s := u.ph_sl
		s.set_value(e.geom.ph)
	}
	// Поле угла - текущий угол, если в нём не набирают
	if !isnil(u.angle_in) && !u.angle_in.focused {
		mut ai := u.angle_in
		ai.set_text('${e.geom.angle:.1f}')
	}
	st.suppress = was
	mut hb := u.horizon_btn
	hb.style = if st.horizon { vgui.ButtonStyle.accent } else { vgui.ButtonStyle.flat }
	if !isnil(u.persp_btn) {
		mut pb := u.persp_btn
		pb.style = if st.persp_tool { vgui.ButtonStyle.accent } else { vgui.ButtonStyle.flat }
	}
	if !isnil(u.m_crop) {
		mut m := u.m_crop
		m.checked = st.crop_mode
	}
	sync_crop_total(mut st)
}

// sync_crop_total - подпись «Итог» (размер на выход)
fn sync_crop_total(mut st State) {
	if isnil(st.crop_ui) {
		return
	}
	mut t := st.crop_ui.total
	if st.linear.len == 0 {
		t.text = 'Итог: -'
		return
	}
	fw_, fh_ := full_size(st)
	cw, ch := crop_size(&st.edit, fw_, fh_)
	t.text = 'Кадр: ${size_text(cw, ch)} px'
}

// build_crop_section - ряды секции «Кадрирование и поворот»
fn build_crop_section(mut st State, lbl_w f32, val_w f32) []SectionRow {
	mut u := &CropUi{}
	st.crop_ui = u

	mut mode := vgui.button('Кадрировать')
	mode.icon_name = 'crop'
	mode.style = .outline
	mode.on_click = fn [mut st] () {
		set_crop_mode(mut st, !st.crop_mode)
	}
	u.mode_btn = mode
	mut reset := reset_button(mut st, 'Сбросить кадрирование и поворот')
	reset.on_click = fn [mut st] () {
		reset_crop(mut st)
	}
	mut mode_row := vgui.create_hbox_fill()
	mode_row.set_spacing(6)
	mode_row.add(mode, flex: 1)
	mode_row.add(reset)

	// Пропорция и ориентация рамки
	mut acb := vgui.combo_box()
	acb.set_items(crop_aspect_names)
	acb.set_selected(0)
	acb.on_change = fn [mut st] (idx int, text string) {
		if st.suppress || idx < 0 || idx >= crop_aspects.len {
			return
		}
		key := crop_aspects[idx]
		if key != st.edit.crop_aspect && key != '' {
			w0, h0 := crop_frame(st)
			// Новая пропорция у вертикального кадра - вертикальная
			if st.edit.crop_aspect == '' {
				st.edit.crop_portrait = h0 > w0 && key != 'shot'
			}
		}
		st.edit.crop_aspect = key
		st.settings.crop_aspect = key
		save_settings(st.settings)
		fit_ratio(mut st, 'Пропорция: ${aspect_name(st.edit)}')
	}
	u.aspect_cb = acb
	mut orient := icon_button(mut st, 'rectangle-horizontal', 'Горизонтальная / вертикальная рамка')
	orient.on_click = fn [mut st] () {
		w0, h0 := crop_frame(st)
		if st.edit.crop_aspect == '' {
			// Свободная пропорция - рамка поворачивается вокруг центра
			g := st.edit.geom
			b := g.box_of(w0, h0)
			a := if b.w() > 0 { b.h() / b.w() } else { 1.0 }
			nb := g.best_box(a, (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, w0, h0)
			crop_apply(mut st, g.with_box(nb, w0, h0), 'crop_ratio', 'Рамка: другая ориентация',
				false)
			return
		}
		st.edit.crop_portrait = !st.edit.crop_portrait
		fit_ratio(mut st, 'Пропорция: ${aspect_name(st.edit)}')
	}
	u.orient_btn = orient
	mut a_lb := vgui.label('Пропорция')
	mut a_row := vgui.create_hbox_fill()
	a_row.set_spacing(6)
	a_row.add(a_lb, min: lbl_w)
	a_row.add(acb, flex: 1)
	a_row.add(orient)

	// Своя пропорция W : H
	mut aw := vgui.spinbox()
	aw.set_range(1, 100)
	mut ah := vgui.spinbox()
	ah.set_range(1, 100)
	aw.on_change = fn [mut st] (v int) {
		if st.suppress {
			return
		}
		st.edit.crop_aw = v
		fit_ratio(mut st, 'Своя пропорция ${st.edit.crop_aw}:${st.edit.crop_ah}')
	}
	ah.on_change = fn [mut st] (v int) {
		if st.suppress {
			return
		}
		st.edit.crop_ah = v
		fit_ratio(mut st, 'Своя пропорция ${st.edit.crop_aw}:${st.edit.crop_ah}')
	}
	u.aw = aw
	u.ah = ah
	mut c_lb := vgui.label('Своя')
	mut colon := vgui.label(':')
	colon.align = .center
	mut c_row := vgui.create_hbox_fill()
	c_row.set_spacing(6)
	c_row.add(c_lb, min: lbl_w)
	c_row.add(aw, flex: 1)
	c_row.add(colon)
	c_row.add(ah, flex: 1)
	c_row.add(icon_slot(), min: icon_slot_w)

	mut total := vgui.label('Итог: -')
	st.secondary_labels << total
	u.total = total

	// Угол: живой ползунок (геометрия превью пересчитывается по ходу)
	mut angle := edit_slider(mut st, SliderCfg{
		label:  'Угол'
		hname:  'Угол'
		min:    -pipeline.geom_angle_max
		max:    pipeline.geom_angle_max
		digits: 1
		live:   true
		show:   fn (v f32) string {
			return angle_text(v)
		}
		get:    fn (e &EditState) f32 {
			return e.geom.angle
		}
		set:    fn [mut st] (mut e EditState, v f32) {
			if st.suppress {
				e.geom.angle = v
				return
			}
			e.geom = geom_with_angle(st, v)
		}
		fx:     fn [mut st] () {
			st.tone_fx()
			sync_crop_total(mut st)
		}
	})
	u.angle_sl = angle.sl
	mut angle_row := edit_row(mut st, mut angle, lbl_w, val_w)
	// Перспектива: живые ползунки, как угол (кадр сам увеличивается -
	// пустых углов нет, рамка остаётся годной)
	mut pv := edit_slider(mut st, SliderCfg{
		label:  'Вертикаль'
		min:    -100
		max:    100
		digits: 0
		live:   true
		get:    fn (e &EditState) f32 {
			return e.geom.pv
		}
		set:    fn (mut e EditState, v f32) {
			e.geom.pv = v
		}
		fx:     fn [mut st] () {
			st.tone_fx()
		}
	})
	u.pv_sl = pv.sl
	mut pv_row := edit_row(mut st, mut pv, lbl_w, val_w)
	mut ph := edit_slider(mut st, SliderCfg{
		label:  'Горизонталь'
		min:    -100
		max:    100
		digits: 0
		live:   true
		get:    fn (e &EditState) f32 {
			return e.geom.ph
		}
		set:    fn (mut e EditState, v f32) {
			e.geom.ph = v
		}
		fx:     fn [mut st] () {
			st.tone_fx()
		}
	})
	u.ph_sl = ph.sl
	mut ph_row := edit_row(mut st, mut ph, lbl_w, val_w)

	// Поворот на 90°, отражения, линия горизонта
	mut r_ccw := icon_button(mut st, 'rotate-ccw-square', 'Повернуть на 90° против часовой')
	r_ccw.on_click = fn [mut st] () {
		rotate90(mut st, -1)
	}
	mut r_cw := icon_button(mut st, 'rotate-cw-square', 'Повернуть на 90° по часовой')
	r_cw.on_click = fn [mut st] () {
		rotate90(mut st, 1)
	}
	mut f_h := icon_button(mut st, 'flip-horizontal-2', 'Отразить по горизонтали')
	f_h.on_click = fn [mut st] () {
		flip_frame(mut st, true)
	}
	mut f_v := icon_button(mut st, 'flip-vertical-2', 'Отразить по вертикали')
	f_v.on_click = fn [mut st] () {
		flip_frame(mut st, false)
	}
	mut hz := icon_button(mut st, 'ruler', 'Линия горизонта: проведите по горизонту (или вертикали) на снимке')
	hz.on_click = fn [mut st] () {
		if st.horizon {
			st.horizon = false
	st.persp_tool = false
			sync_crop_ui(mut st)
			return
		}
		set_crop_mode(mut st, true)
		if st.crop_mode {
			st.horizon = true
			sync_crop_ui(mut st)
		}
	}
	u.horizon_btn = hz
	mut pl := icon_button(mut st, 'columns-2',
		'Перспектива по двум линиям: проведите по двум вертикалям (или горизонталям) на снимке')
	pl.on_click = fn [mut st] () {
		if st.persp_tool {
			st.persp_tool = false
			sync_crop_ui(mut st)
			return
		}
		set_crop_mode(mut st, true)
		if st.crop_mode {
			st.horizon = false
			st.persp_tool = true
			st.persp_l1 = []f64{}
			sync_crop_ui(mut st)
		}
	}
	u.persp_btn = pl
	// Угол вручную: Enter - применить
	mut ain := vgui.text_input('0.0')
	ain.max_len = 8
	ain.on_submit = fn [mut st] (s string) {
		set_angle_text(mut st, s)
	}
	u.angle_in = ain
	mut ain_tip := vgui.tooltip('Угол вручную, градусы (-45..45): введите и нажмите Enter')
	ain_tip.attach(ain)
	st.tips << ain_tip
	mut tools := vgui.create_hbox_fill()
	tools.set_spacing(6)
	tools.add(vgui.label('Повернуть'), min: lbl_w)
	tools.add(r_ccw)
	tools.add(r_cw)
	tools.add(f_h)
	tools.add(f_v)
	tools.add(hz)
	tools.add(pl)
	tools.add(vgui.label(''), flex: 1)
	tools.add(ain)
	tools.add(vgui.label('°'))

	// Сетка поверх рамки - вид (настройки программы, не кадра)
	mut gcb := vgui.combo_box()
	gcb.set_items(crop_grid_names)
	gcb.set_selected(math.max(0, crop_grids.index(st.settings.crop_grid)))
	gcb.on_change = fn [mut st] (idx int, text string) {
		if idx < 0 || idx >= crop_grids.len {
			return
		}
		st.settings.crop_grid = crop_grids[idx]
		save_settings(st.settings)
	}
	u.grid_cb = gcb
	mut g_lb := vgui.label('Сетка')
	mut g_row := vgui.create_hbox_fill()
	g_row.set_spacing(6)
	g_row.add(g_lb, min: lbl_w)
	g_row.add(gcb, flex: 1)
	g_row.add(icon_slot(), min: icon_slot_w)

	// Автоперспектива (как Upright): кнопки режимов
	mut up_row := vgui.create_hbox_fill()
	up_row.set_spacing(6)
	// Подпись по своей ширине: с колонкой подписей кнопки не влезают
	up_row.add(vgui.label('Авто'))
	up_tips := ['Только наклон: горизонтали и вертикали станут ровными',
		'Вертикали станут параллельными, плюс наклон',
		'Вертикали и горизонтали: обе перспективы и наклон']
	for i, uname in upright_names {
		mut b := vgui.button(uname)
		b.style = .flat
		um := unsafe { pipeline.UprightMode(i) }
		b.on_click = fn [mut st, um] () {
			upright_apply(mut st, um)
		}
		mut tip := vgui.tooltip(up_tips[i])
		tip.attach(b)
		st.tips << tip
		up_row.add(b, flex: 1)
	}

	mut hint := vgui.label('Enter - применить, Esc - отмена, двойной щелчок - вся рамка')
	hint.font_size = 12
	st.hint_labels << hint
	return [SectionRow{mode_row}, SectionRow{a_row}, SectionRow{c_row},
		SectionRow{total},
		SectionRow{angle_row}, SectionRow{pv_row}, SectionRow{ph_row}, SectionRow{up_row},
		SectionRow{tools},
		SectionRow{g_row},
		SectionRow{hint}]
}
