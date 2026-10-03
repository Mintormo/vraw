module main

// До/после и увеличение щелчком - постоянная проверка «лучше или хуже»,
// резкости и шума.
//
// «До» - тон и цвет первой записи истории («Открыт файл»: нейтральные
// настройки или что было при первом открытии) по тому же сырью и с той
// же геометрией, что «после»: второй прогон pipeline.apply в свой буфер
// (st.ba_before), пересчёт - только когда меняются сырьё, геометрия или
// сама запись. Подготовка сырья (коррекция объектива, шумодав,
// Capture-резкость) у «до» та же, что сейчас: она уже в линейном буфере.
// Два режима:
// - удержание «\» - весь снимок «до», пока клавиша нажата (KeyWatch);
// - шторка (Y, «Вид - До/после: шторка») - слева «до», справа «после»,
//   вертикальную линию тянут мышью. «После» (st.ba_after) хранится,
//   чтобы двигать линию без пересчёта пайплайна.
//
// Щелчок по снимку - 100% в эту точку, повторный - обратно «вписать»
// (Z и пробел - то же по центру вида). Превью половинного размера: 100% -
// пиксель превью на пиксель экрана, как пункт «Вид - 100% (1:1)».
import vgui
import pipeline

// Шторка: линия, ручка, подписи
const ba_line = vgui.Color{255, 255, 255, 230}
const ba_line_dark = vgui.Color{0, 0, 0, 140}
const ba_label_bg = vgui.Color{20, 20, 22, 190}
const ba_label_fg = vgui.Color{235, 235, 235, 255}
const ba_grab_px = f32(10) // захват линии мышью - экранных пикселей
const click_px = f32(4) // сдвиг мыши, после которого это не щелчок, а жест

// BaKey - от чего зависит буфер «до»
struct BaKey {
	lin_gen int
	geom    GeomKey
	state   EditState
}

// ba_active - «до» показывается (удержание или шторка) и есть что
// сравнивать: кадр проявлен, история есть, не режим кадрирования и не
// показ карты дымки или резкости
fn ba_active(st &State) bool {
	return (st.ba_hold || st.ba_split) && st.history.len > 0 && st.glin.len > 0
		&& !st.crop_mode && !st.haze_show && !st.sharp_show && st.sharp_drag == .off
}

// ba_render - буфер «до» по первой записи истории (кэш по BaKey)
fn ba_render(mut st State) {
	before := st.history[0].state
	key := BaKey{
		lin_gen: st.lin_gen
		geom:    st.geom_key
		state:   before
	}
	npix := st.gw * st.gh
	if key == st.ba_key && st.ba_before.len == npix * 4 {
		return
	}
	if before.params.haze != 0 && st.haze.d.len != npix {
		st.haze = pipeline.haze_map(unsafe { &u16(st.glin.data) }, st.gw, st.gh)
	}
	st.ba_before = []u8{len: npix * 4}
	mask := if st.gmask.len == npix { unsafe { &u16(st.gmask.data) } } else { unsafe { &u16(nil) } }
	pipeline.apply_image(unsafe { &u16(st.glin.data) }, mask, &st.haze, st.gw, st.gh,
		before.params, preview_scale, mut st.ba_before, 4)
	st.ba_key = key
}

// ba_apply - в конце apply_pipeline (cv.pixels - уже «после», с
// гистограммой и подсветкой клипа): запомнить «после» и показать «до»
// целиком или шторкой
fn ba_apply(mut st State, mut cv vgui.Canvas) {
	if !ba_active(st) {
		st.ba_after = []u8{}
		return
	}
	ba_render(mut st)
	st.ba_after = cv.pixels.clone()
	ba_compose(mut st, mut cv)
}

// ba_compose - холст из «до» и «после» без пересчёта пайплайна: при
// удержании - «до», в шторке - «до» левее линии
fn ba_compose(mut st State, mut cv vgui.Canvas) {
	n := st.gw * st.gh * 4
	if st.ba_before.len != n || st.ba_after.len != n || cv.pixels.len != n {
		return
	}
	if st.ba_hold {
		unsafe { vmemcpy(cv.pixels.data, st.ba_before.data, n) }
	} else {
		split := ba_split_x(st)
		row := st.gw * 4
		unsafe {
			mut d := &u8(cv.pixels.data)
			mut b := &u8(st.ba_before.data)
			mut a := &u8(st.ba_after.data)
			for _ in 0 .. st.gh {
				vmemcpy(d, b, split * 4)
				vmemcpy(d + split * 4, a + split * 4, row - split * 4)
				d += row
				b += row
				a += row
			}
		}
	}
	cv.mark_dirty()
}

// ba_split_x - столбец линии шторки в пикселях превью
fn ba_split_x(st &State) int {
	x := int(st.ba_pos * f32(st.gw) + 0.5)
	return if x < 0 { 0 } else if x > st.gw { st.gw } else { x }
}

// set_ba_hold - удержание «\»: показать «до» / вернуть «после»
fn set_ba_hold(mut st State, on bool) {
	if on == st.ba_hold {
		return
	}
	st.ba_hold = on
	ba_refresh(mut st)
}

// set_ba_split - шторка вкл/выкл (Y, меню «Вид»)
fn set_ba_split(mut st State, on bool) {
	st.ba_split = on
	st.ba_drag = false
	if !isnil(st.m_split) {
		mut m := st.m_split
		m.checked = on
	}
	if on && st.history.len > 0 && st.crop_mode && !isnil(st.nm) {
		mut nm := st.nm
		nm.show_info('До/после - после выхода из кадрирования')
	}
	ba_refresh(mut st)
}

// ba_refresh - холст под режим: «после» уже посчитано - только
// пересборка из буферов, иначе - пересчёт пайплайна
fn ba_refresh(mut st State) {
	if isnil(st.cv) {
		return
	}
	mut cv := st.cv
	n := st.gw * st.gh * 4
	if st.ba_after.len == n && cv.pixels.len == n {
		if !ba_active(st) {
			unsafe { vmemcpy(cv.pixels.data, st.ba_after.data, n) }
			st.ba_after = []u8{}
			cv.mark_dirty()
			return
		}
		ba_render(mut st)
		ba_compose(mut st, mut cv)
		return
	}
	if !isnil(st.tone_fx) {
		st.tone_fx()
	}
}

// ba_overlay - линия шторки, ручка и подписи «До» / «После» (поверх
// снимка, экранные координаты)
fn ba_overlay(mut st State, mut ctx vgui.RenderContext) {
	if !ba_active(st) || isnil(st.cv) {
		return
	}
	cv := st.cv
	x0, y0 := cv.buf_to_screen(0, 0)
	x1, y1 := cv.buf_to_screen(f32(cv.width), f32(cv.height))
	if st.ba_hold {
		ba_label(mut ctx, 'До', x0 + 10, y0 + 10)
		return
	}
	sx, _ := cv.buf_to_screen(f32(ba_split_x(st)), 0)
	ctx.fill_rect(vgui.Rect{sx - 2, y0, 4, y1 - y0}, ba_line_dark)
	ctx.fill_rect(vgui.Rect{sx - 1, y0, 2, y1 - y0}, ba_line)
	my := (y0 + y1) / 2
	ctx.fill_circle(sx, my, 11, ba_line_dark)
	ctx.fill_circle(sx, my, 9, ba_line)
	ctx.fill_triangle(sx - 6, my, sx - 2, my - 4, sx - 2, my + 4, ba_line_dark)
	ctx.fill_triangle(sx + 6, my, sx + 2, my - 4, sx + 2, my + 4, ba_line_dark)
	if sx - x0 > 60 {
		ba_label(mut ctx, 'До', sx - 10 - label_w('До'), y0 + 10)
	}
	if x1 - sx > 80 {
		ba_label(mut ctx, 'После', sx + 10, y0 + 10)
	}
}

// label_w - ширина плашки подписи (оценка по числу букв, как у подписей
// рамки кадрирования: шрифта в оверлее под рукой нет)
fn label_w(text string) f32 {
	return f32(text.runes().len) * 7.5 + 12
}

fn ba_label(mut ctx vgui.RenderContext, text string, x f32, y f32) {
	ctx.fill_rounded_rect(vgui.Rect{x, y, label_w(text), 20}, ba_label_bg, 4)
	ctx.draw_text(text, x + 6, y + 2, ba_label_fg)
}

// ba_input - мышь в шторке: захват линии и перетаскивание; true - событие
// забрано
fn ba_input(mut st State, ev &vgui.CanvasInputEvent) bool {
	if !st.ba_split || !ba_active(st) || isnil(st.cv) {
		st.ba_drag = false
		return false
	}
	mut cv := st.cv
	sc := cv.screen_scale()
	match ev.kind {
		.pointer_down {
			if ev.button != 1 {
				return false
			}
			d := (ev.fx - f32(ba_split_x(st))) * sc
			if d > -ba_grab_px && d < ba_grab_px {
				st.ba_drag = true
				vgui.set_cursor(vgui.sdl_system_cursor_sizewe)
				return true
			}
		}
		.pointer_move {
			if st.ba_drag {
				st.ba_pos = clamp01f(ev.fx / f32(st.gw))
				ba_compose(mut st, mut cv)
				return true
			}
		}
		.pointer_up {
			if st.ba_drag {
				st.ba_drag = false
				return true
			}
		}
		.hover {
			d := (ev.fx - f32(ba_split_x(st))) * sc
			vgui.set_cursor(if d > -ba_grab_px && d < ba_grab_px {
				vgui.sdl_system_cursor_sizewe
			} else {
				vgui.sdl_system_cursor_default
			})
		}
		else {}
	}
	return false
}

// zoom_at - масштаб z с точкой буфера (bx, by) на том же месте экрана
// (zoom_at у vgui.Canvas приватный: прокрутка считается здесь)
fn zoom_at(mut cv vgui.Canvas, bx f32, by f32, z f32) {
	sx, sy := cv.buf_to_screen(bx, by)
	cv.set_zoom(z)
	cv.scroll_x = cv.bounds.x + bx * z - sx
	cv.scroll_y = cv.bounds.y + by * z - sy
	cv.set_zoom(z) // ограничит прокрутку краями
}

// toggle_zoom - вписан (или другой масштаб) - 100% в точку (bx, by),
// 100% - обратно «вписать»
fn toggle_zoom(mut cv vgui.Canvas, bx f32, by f32) {
	if !cv.auto_fit && cv.zoom == 1.0 {
		cv.fit_to_view()
	} else {
		zoom_at(mut cv, bx, by, 1.0)
	}
}

// toggle_zoom_center - Z и пробел: 100% в центр видимой части
fn toggle_zoom_center(mut st State) {
	if isnil(st.cv) || st.linear.len == 0 {
		return
	}
	mut cv := st.cv
	cx := cv.bounds.x + cv.bounds.w / 2
	cy := cv.bounds.y + cv.bounds.h / 2
	sc := cv.screen_scale()
	bx := if sc > 0 { (cx - cv.disp_x) / sc } else { f32(cv.width) / 2 }
	by := if sc > 0 { (cy - cv.disp_y) / sc } else { f32(cv.height) / 2 }
	toggle_zoom(mut cv, bx, by)
}

// zoom_click - щелчок левой кнопкой по снимку (нажали и отпустили почти
// на месте) - toggle_zoom в эту точку; true - событие забрано
fn zoom_click(mut st State, ev &vgui.CanvasInputEvent) bool {
	if isnil(st.cv) || st.linear.len == 0 || st.crop_mode || st.wb_pick {
		st.click_down = false
		return false
	}
	mut cv := st.cv
	match ev.kind {
		.pointer_down {
			if ev.button == 1 && ev.in_image {
				st.click_down = true
				st.click_x = ev.fx
				st.click_y = ev.fy
			}
		}
		.pointer_up {
			if ev.button == 1 && st.click_down {
				st.click_down = false
				sc := cv.screen_scale()
				dx := (ev.fx - st.click_x) * sc
				dy := (ev.fy - st.click_y) * sc
				if dx * dx + dy * dy <= click_px * click_px {
					toggle_zoom(mut cv, st.click_x, st.click_y)
					return true
				}
			}
		}
		else {}
	}
	return false
}

// KeyWatch - невидимый виджет окна для клавиш, которым мало горячей
// клавиши: удержание «\» (нужно и отпускание - у горячих клавиш vgui
// его нет) и однобуквенные сочетания в русской раскладке (SDL отдаёт
// в keycode букву раскладки - «з» вместо P, и меню их не узнаёт; здесь -
// по scancode, месту клавиши). Добавляется в окно после корня: события
// получает раньше меню, но после виджета в фокусе (поле ввода свои
// буквы заберёт само).
@[heap]
struct KeyWatch {
mut:
	st &State = unsafe { nil }
}

// Scancode SDL (USB HID): буквы с 4 (A), «\» - 49
const sc_backslash = 49

// printable_key - клавиша печатного символа (пробел, буквы любой
// раскладки, цифры, знаки): не служебная (у стрелок и F-клавиш в
// keycode бит 1 << 30), не Esc, Enter, Tab, Backspace, Delete
fn printable_key(keycode int) bool {
	return keycode >= 32 && keycode != 127 && keycode & (1 << 30) == 0
}

fn (mut k KeyWatch) draw(mut _ vgui.RenderContext) {}

fn (mut k KeyWatch) handle_event(ev &vgui.GuiEvent, app &vgui.App) bool {
	if isnil(k.st) {
		return false
	}
	mut st := k.st
	if ev.typ == .window_focus_lost {
		set_ba_hold(mut st, false) // отпускание «\» в другом окне не придёт
		return false
	}
	if ev.typ != .key_down && ev.typ != .key_up {
		return false
	}
	// Поле ввода в фокусе: печатные клавиши - его. Буквы и цифры поле
	// получает текстом, а key_down отдаёт дальше - и меню поставило бы
	// звёзды (0..5) или флажок, пока набирают угол или пропорцию
	ctx := app.get_active_ctx()
	if ev.typ == .key_down && !isnil(ctx) && ctx.focus.wants_text()
		&& ev.mod_keys & (vgui.sdl_kmod_ctrl | vgui.sdl_kmod_alt) == 0 && printable_key(ev.keycode) {
		return true
	}
	mods := ev.mod_keys & (vgui.sdl_kmod_ctrl | vgui.sdl_kmod_alt | vgui.sdl_kmod_shift)
	if ev.scancode == sc_backslash && mods == 0 {
		set_ba_hold(mut st, ev.typ == .key_down)
		return true
	}
	// Буква раскладки не латинская - сочетание по месту клавиши
	if ev.typ != .key_down || mods != 0 || (ev.keycode >= `a` && ev.keycode <= `z`) {
		return false
	}
	match ev.scancode {
		19 { set_flag(mut st, 1) } // P
		27 { set_flag(mut st, -1) } // X
		24 { set_flag(mut st, 0) } // U
		29 { toggle_zoom_center(mut st) } // Z
		28 { set_ba_split(mut st, !st.ba_split) } // Y
		13 { set_clip_warn(mut st, !(st.clip_hi || st.clip_lo), !(st.clip_hi || st.clip_lo)) } // J
		21 { set_crop_mode(mut st, !st.crop_mode) } // R
		else { return false }
	}
	return true
}
