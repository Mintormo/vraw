module main

// Показ пересветов и провалов (как клавиша J в Lightroom): прямо на превью
// пиксели, у которых хоть один канал результата ушёл в 255, - красным, в
// 0 - синим. Это вид, а не правка: в историю и сайдкар не пишется, экспорт
// не трогает (подсветка - только в пикселях холста превью).
//
// Включается пунктом «Вид - Пересветы и провалы» (J) - оба сразу - или
// треугольниками в верхних углах гистограммы: левый - провалы, правый -
// пересветы. Треугольник горит цветом, когда в кадре есть клип этого края
// (по гистограмме результата), и обведён (белым в тёмной теме, цветом
// текста в светлой), когда показ включён. Яркость - по доле кадра на
// краю (clip_tint): несколько пикселей (блик, лампа) - тусклый цвет, от
// clip_full_frac кадра - полный; точная доля - в подсказке треугольника
// (histogram.v). Серый «нет клипа» и обводка - из палитры темы
// (Palette.clip_idle, clip_ring).
import math
import vgui

const clip_hi_color = vgui.Color{255, 40, 40, 255}
const clip_lo_color = vgui.Color{40, 120, 255, 255}
// Треугольник в буфере гистограммы 256x100 (растягивается на виджет):
// катеты, отступ от угла; щелчок ловится в квадрате чуть больше
const clip_tri_w = 14
const clip_tri_h = 12
const clip_tri_pad = 3
const clip_hit = 24
// Яркость треугольника: доля кадра на краю от clip_dim_frac и меньше -
// clip_dim_mix цвета клипа (остальное - серый «нет клипа»), от
// clip_full_frac (1 %) - полный цвет, между - по логарифму доли
const clip_dim_frac = 1e-5
const clip_full_frac = 1e-2
const clip_dim_mix = 0.4

// mark_clipping - подсветка клипа в RGBA-буфере результата: канал в 255 -
// красный (пересвет), иначе канал в 0 - синий (провал)
fn mark_clipping(mut pix []u8, hi bool, lo bool) {
	if !hi && !lo {
		return
	}
	unsafe {
		mut p := &u8(pix.data)
		for _ in 0 .. pix.len / 4 {
			r := p[0]
			g := p[1]
			b := p[2]
			if hi && (r == 255 || g == 255 || b == 255) {
				p[0] = clip_hi_color.r
				p[1] = clip_hi_color.g
				p[2] = clip_hi_color.b
			} else if lo && (r == 0 || g == 0 || b == 0) {
				p[0] = clip_lo_color.r
				p[1] = clip_lo_color.g
				p[2] = clip_lo_color.b
			}
			p += 4
		}
	}
}

// mark_clipping_src - как mark_clipping, но пересветы - по сырью raw
// (16 бит, 3 канала, та же сетка пикселей): хоть один канал на уровне
// клипа LibRaw (raw_clip_lvl, histogram.v) - красный; провалы - по
// результату. raw = nil - mark_clipping.
fn mark_clipping_src(mut pix []u8, hi bool, lo bool, raw &u16) {
	if isnil(raw) || !hi {
		mark_clipping(mut pix, hi, lo)
		return
	}
	unsafe {
		mut p := &u8(pix.data)
		mut s := &u16(raw)
		for _ in 0 .. pix.len / 4 {
			if s[0] >= raw_clip_lvl || s[1] >= raw_clip_lvl || s[2] >= raw_clip_lvl {
				p[0] = clip_hi_color.r
				p[1] = clip_hi_color.g
				p[2] = clip_hi_color.b
			} else if lo && (p[0] == 0 || p[1] == 0 || p[2] == 0) {
				p[0] = clip_lo_color.r
				p[1] = clip_lo_color.g
				p[2] = clip_lo_color.b
			}
			p += 4
			s += 3
		}
	}
}

// draw_clip_marks - треугольники в углах гистограммы: цвет - есть клип
// (hi/lo - доля кадра на краю, 0 - нет; яркость - clip_tint), обводка -
// показ включён
fn draw_clip_marks(mut hist vgui.Canvas, hi f64, lo f64, hi_on bool, lo_on bool, p Palette) {
	draw_clip_tri(mut hist, false, clip_tint(clip_lo_color, p.clip_idle, lo), lo_on,
		p.clip_ring)
	draw_clip_tri(mut hist, true, clip_tint(clip_hi_color, p.clip_idle, hi), hi_on,
		p.clip_ring)
	hist.mark_dirty()
}

// clip_tint - цвет треугольника по доле кадра f на краю: 0 - idle, хоть
// что-то - не меньше clip_dim_mix цвета c, от clip_full_frac - сам c
fn clip_tint(c vgui.Color, idle vgui.Color, f f64) vgui.Color {
	if f <= 0 {
		return idle
	}
	t := math.clamp((math.log10(f) - math.log10(clip_dim_frac)) / (math.log10(clip_full_frac) -
		math.log10(clip_dim_frac)), 0, 1)
	k := clip_dim_mix + (1 - clip_dim_mix) * t
	return vgui.Color{u8(math.round(f64(idle.r) + (f64(c.r) - f64(idle.r)) * k)), u8(math.round(
		f64(idle.g) + (f64(c.g) - f64(idle.g)) * k)), u8(math.round(f64(idle.b) + (f64(c.b) - f64(idle.b)) * k)), 255}
}

// draw_clip_tri - прямоугольный треугольник прямым углом в верхний угол
// (right - правый); on - обводка ring в 1 пиксель
fn draw_clip_tri(mut hist vgui.Canvas, right bool, c vgui.Color, on bool, ring vgui.Color) {
	w := hist.width
	for y in 0 .. clip_tri_h {
		// ширина строки убывает от катета к вершине
		n := clip_tri_w - y * clip_tri_w / clip_tri_h
		for i in 0 .. n {
			edge := y == 0 || i == 0 || i == n - 1 || y == clip_tri_h - 1
			col := if on && edge { ring } else { c }
			x := if right { w - 1 - clip_tri_pad - i } else { clip_tri_pad + i }
			k := ((clip_tri_pad + y) * w + x) * 4
			if k < 0 || k + 3 >= hist.pixels.len {
				continue
			}
			hist.pixels[k] = col.r
			hist.pixels[k + 1] = col.g
			hist.pixels[k + 2] = col.b
		}
	}
}

// clip_hit_test - щелчок по гистограмме (координаты буфера): 1 - правый
// треугольник (пересветы), -1 - левый (провалы), 0 - мимо
fn clip_hit_test(x int, y int, w int) int {
	if y > clip_hit {
		return 0
	}
	if x < clip_hit {
		return -1
	}
	if x >= w - clip_hit {
		return 1
	}
	return 0
}

// set_clip_warn - включить/выключить показ; флажок меню - «хоть один»,
// превью пересчитывается (подсветка снимается или накладывается)
fn set_clip_warn(mut st State, hi bool, lo bool) {
	st.clip_hi = hi
	st.clip_lo = lo
	if !isnil(st.m_clipwarn) {
		mut m := st.m_clipwarn
		m.checked = hi || lo
	}
	if !isnil(st.tone_fx) {
		st.tone_fx()
	}
	pair_show(mut st) // левый кадр сравнения - тоже (pair.v)
}
