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
// текста в светлой), когда показ включён. Серый «нет клипа» и обводка -
// из палитры темы (Palette.clip_idle, clip_ring).
import vgui

const clip_hi_color = vgui.Color{255, 40, 40, 255}
const clip_lo_color = vgui.Color{40, 120, 255, 255}
// Треугольник в буфере гистограммы 256x100 (растягивается на виджет):
// катеты, отступ от угла; щелчок ловится в квадрате чуть больше
const clip_tri_w = 14
const clip_tri_h = 12
const clip_tri_pad = 3
const clip_hit = 24

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

// draw_clip_marks - треугольники в углах гистограммы: цвет - есть клип
// (hi_seen/lo_seen), обводка - показ включён
fn draw_clip_marks(mut hist vgui.Canvas, hi_seen bool, lo_seen bool, hi_on bool, lo_on bool, p Palette) {
	draw_clip_tri(mut hist, false, if lo_seen { clip_lo_color } else { p.clip_idle }, lo_on,
		p.clip_ring)
	draw_clip_tri(mut hist, true, if hi_seen { clip_hi_color } else { p.clip_idle }, hi_on,
		p.clip_ring)
	hist.mark_dirty()
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
