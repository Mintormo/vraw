module ai

// Сетка плиток шумодава кадра (позиции и веса сшивки), вход модели для
// плитки и сложение её выхода - для прохода по всему кадру (denoise_with).
// До 18.10.2026 здесь же был кэш плиток для фрагмента 1:1; теперь 1:1
// берёт кусок готового результата по полному кадру (main, ai_nr.v).
import math

// Rect - прямоугольник в пикселях кадра
pub struct Rect {
pub:
	x int
	y int
	w int
	h int
}

// Grid - плитки кадра w x h: начала по осям и веса сшивки
pub struct Grid {
pub:
	w  int
	h  int
	xs []int
	ys []int
mut:
	wx  [][]f32
	wy  [][]f32
	fwd []f32 // линейное u16 -> sRGB 0..1
	inv []u16 // sRGB (u16-шкала) -> линейное u16
}

pub fn new_grid(w int, h int) Grid {
	xs := positions(w)
	ys := positions(h)
	fwd, inv := srgb_luts()
	return Grid{
		w:   w
		h:   h
		xs:  xs
		ys:  ys
		wx:  axis_weights(xs, w)
		wy:  axis_weights(ys, h)
		fwd: fwd
		inv: inv
	}
}

// fill_input - вход модели для плитки (i, j): sRGB, планарно; src - кусок
// кадра pr (линейный RGB u16), накрывающий окно плитки. За краем КАДРА -
// повтор крайнего пикселя (как у прохода по всему кадру).
fn (g &Grid) fill_input(i int, j int, src &u16, pr Rect, mut input []f32) {
	plane := tile * tile
	x0 := g.xs[i]
	y0 := g.ys[j]
	for ty in 0 .. tile {
		sy := math.min(y0 + ty, g.h - 1) - pr.y
		for tx in 0 .. tile {
			sx := math.min(x0 + tx, g.w - 1) - pr.x
			s := (sy * pr.w + sx) * 3
			o := ty * tile + tx
			unsafe {
				input[o] = g.fwd[src[s]]
				input[plane + o] = g.fwd[src[s + 1]]
				input[2 * plane + o] = g.fwd[src[s + 2]]
			}
		}
	}
}

// accumulate - вклад плитки (i, j) с весами сшивки в накопитель
// прямоугольника r (r.w * r.h * 3 f32)
fn (g &Grid) accumulate(i int, j int, output []f32, mut acc []f32, r Rect) {
	plane := tile * tile
	x0 := g.xs[i]
	y0 := g.ys[j]
	ya := int(math.max(y0, r.y))
	yb := int(math.min(math.min(y0 + tile, g.h), r.y + r.h))
	xa := int(math.max(x0, r.x))
	xb := int(math.min(math.min(x0 + tile, g.w), r.x + r.w))
	for yy in ya .. yb {
		ty := yy - y0
		ky := g.wy[j][ty]
		for xx in xa .. xb {
			tx := xx - x0
			k := ky * g.wx[i][tx]
			d := ((yy - r.y) * r.w + (xx - r.x)) * 3
			o := ty * tile + tx
			acc[d] += k * output[o]
			acc[d + 1] += k * output[plane + o]
			acc[d + 2] += k * output[2 * plane + o]
		}
	}
}

// finish - накопитель (sRGB 0..1) -> линейный u16
fn finish(acc []f32, mut out []u16) {
	_, inv := srgb_luts()
	for n, v in acc {
		gv := if v <= 0 { 0 } else if v >= 1 { 65535 } else { int(v * 65535 + 0.5) }
		out[n] = inv[gv]
	}
}
