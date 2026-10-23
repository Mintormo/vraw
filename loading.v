module main

// Оверлей загрузки кадра: пока кадр проявляется (load_worker, ~0.75 с на
// 24 Мп), на месте снимка - вращающееся кольцо и надпись «Обработка» на
// градиенте в цветах темы. Встроенный JPEG камеры вместо него не
// показывается: он обработан иначе, чем наша проявка, и смена картинки
// бросалась в глаза (JPEG отдельно - «Вид - JPEG камеры», camjpeg.v).
// Кольцо - без процентов (индикатор занятости): этапы загрузки неравные,
// доли по ним шли рывками.
import math
import vgui
import i18n

const load_ring_r = f32(26)
// Доля акцентного цвета темы в центре градиента - лёгкое свечение за
// кольцом
const load_glow = f32(0.14)

// LoadOverlay - слой view_stack поверх холста и заглушки: фон и кольцо
// с надписью по центру
@[heap]
struct LoadOverlay {
mut:
	stack &vgui.Stack       = unsafe { nil }
	bg    &vgui.Canvas      = unsafe { nil }
	ring  &vgui.ProgressBar = unsafe { nil }
	label &vgui.Label       = unsafe { nil }
}

fn make_load_overlay(th vgui.Theme) &LoadOverlay {
	mut bg := vgui.canvas(480, 360)
	bg.stretch = true
	bg.passive = true
	bg.set_wheel_zoom(false)
	bg.set_pan_buttons(0)
	mut ring := vgui.progress_circular()
	ring.indeterminate = true
	ring.radius = load_ring_r
	ring.thickness = 4
	ring.anim_speed = 0.8
	mut label := vgui.label(i18n.tr('Обработка'))
	label.align = .center
	mut col := vgui.create_vbox_fill()
	col.set_spacing(14)
	col.add(ring, align: .center)
	col.add(label)
	mut center := vgui.create_centered(200, 2 * load_ring_r + 44)
	center.set_child(col)
	mut stack := &vgui.Stack{}
	stack.add(bg)
	stack.add(center)
	stack.visible = false
	mut ov := &LoadOverlay{
		stack: stack
		bg:    bg
		ring:  ring
		label: label
	}
	paint_load_overlay(mut ov, th)
	return ov
}

// paint_load_overlay - фон и цвета под тему: радиальный градиент от
// поверхности с лёгким акцентом в центре к фону темы по краям (край - как
// поле вокруг, view_area), кольцо - акцент на дорожке цвета рамки
fn paint_load_overlay(mut ov LoadOverlay, th vgui.Theme) {
	mut bg := ov.bg
	gw := bg.width
	gh := bg.height
	edge := th.bg
	c0 := mix_color(th.surface, th.accent, load_glow)
	unsafe {
		mut p := &u8(bg.pixels.data)
		mut seed := u32(777)
		for y in 0 .. gh {
			for x in 0 .. gw {
				dx := (f32(x) - gw / 2) / (gw / 2)
				dy := (f32(y) - gh / 2) / (gh / 2)
				mut r := math.sqrtf(dx * dx + dy * dy) / 1.2
				if r > 1 {
					r = 1
				}
				t := r * r * (3 - 2 * r) // smoothstep
				// Дизер: на гладком градиенте иначе видны ступени
				seed = seed * 1664525 + 1013904223
				n := f32(seed >> 8) / 16777216.0
				p[0] = clamp_u8(f32(c0.r) + (f32(edge.r) - f32(c0.r)) * t + n)
				p[1] = clamp_u8(f32(c0.g) + (f32(edge.g) - f32(c0.g)) * t + n)
				p[2] = clamp_u8(f32(c0.b) + (f32(edge.b) - f32(c0.b)) * t + n)
				p[3] = 255
				p += 4
			}
		}
	}
	bg.mark_dirty()
	mut ring := ov.ring
	ring.fill_color = th.accent
	ring.bg_color = mix_color(th.surface, th.text_secondary, 0.18)
	mut label := ov.label
	label.color = th.text_secondary
}

fn mix_color(a vgui.Color, b vgui.Color, t f32) vgui.Color {
	return vgui.Color{u8(f32(a.r) + (f32(b.r) - f32(a.r)) * t), u8(f32(a.g) +
		(f32(b.g) - f32(a.g)) * t), u8(f32(a.b) + (f32(b.b) - f32(a.b)) * t), 255}
}

// load_shown - оверлей сейчас на экране
fn load_shown(st &State) bool {
	return !isnil(st.load_ov) && st.load_ov.stack.visible
}

// show_loading - оверлей вместо снимка (кадр открывается) или снимок
// вместо оверлея (готово); заглушку прячет. Холст на время загрузки
// скрыт - старый кадр не путается с новым, гистограмма очищается.
fn show_loading(mut st State, on bool) {
	if isnil(st.load_ov) || isnil(st.cv) {
		return
	}
	mut ov := st.load_ov
	mut cv := st.cv
	ov.stack.visible = on
	if on {
		cv.visible = false
		if !isnil(st.hist_cv) {
			mut hist := st.hist_cv
			clear_histogram(mut st, mut hist)
		}
		if !isnil(st.holder) {
			mut ph := st.holder.stack
			ph.visible = false
		}
	}
	sync_view_bg(mut st)
}
