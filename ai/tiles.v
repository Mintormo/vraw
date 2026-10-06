module ai

// Плитки шумодава кадра по отдельности - для фрагмента настоящего 1:1.
//
// Сетка плиток (позиции и веса сшивки) - та же, что у прохода по всему
// кадру (denoise_into), поэтому пиксель фрагмента - сумма тех же плиток с
// теми же весами в том же порядке: результат совпадает с экспортом бит в
// бит (тест test_tiles_match_denoise). Выход плитки (sRGB f32) хранится в
// TileCache - при прокрутке модель считает только новые плитки.
import math
import bigbuf

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

// span - плитки, задевающие отрезок [a, b) оси (первая и последняя
// включительно); пусто - (0, -1)
fn span(pos []int, n int, a int, b int) (int, int) {
	mut lo := -1
	mut hi := -1
	for k, p in pos {
		e := if p + tile < n { p + tile } else { n }
		if p < b && e > a {
			if lo < 0 {
				lo = k
			}
			hi = k
		}
	}
	return if lo < 0 { 0, -1 } else { lo, hi }
}

// TileSpan - плитки i0..i1 x j0..j1 (включительно)
pub struct TileSpan {
pub:
	i0 int
	i1 int
	j0 int
	j1 int
}

pub fn (t TileSpan) count() int {
	return if t.i1 < t.i0 || t.j1 < t.j0 { 0 } else { (t.i1 - t.i0 + 1) * (t.j1 - t.j0 + 1) }
}

// cover - плитки, нужные прямоугольнику r
pub fn (g &Grid) cover(r Rect) TileSpan {
	i0, i1 := span(g.xs, g.w, r.x, r.x + r.w)
	j0, j1 := span(g.ys, g.h, r.y, r.y + r.h)
	return TileSpan{i0, i1, j0, j1}
}

// window - часть кадра, которую читают плитки t (вход модели)
pub fn (g &Grid) window(t TileSpan) Rect {
	if t.count() == 0 {
		return Rect{}
	}
	x0 := g.xs[t.i0]
	y0 := g.ys[t.j0]
	x1 := int(math.min(g.xs[t.i1] + tile, g.w))
	y1 := int(math.min(g.ys[t.j1] + tile, g.h))
	return Rect{x0, y0, x1 - x0, y1 - y0}
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

// TileCache - выходы модели по плиткам одного кадра (вне сборщика,
// 3 x 256 x 256 f32 = 768 КБ на плитку). Держатель один; free - всё.
@[heap]
pub struct TileCache {
pub:
	grid Grid
mut:
	out  map[int][]f32 // j * число столбцов + i
	used map[int]u64   // для вытеснения: номер последнего обращения
	tick u64
}

pub fn new_tile_cache(w int, h int) &TileCache {
	return &TileCache{
		grid: new_grid(w, h)
	}
}

fn (c &TileCache) key(i int, j int) int {
	return j * c.grid.xs.len + i
}

// missing - сколько плиток из t ещё не посчитано
pub fn (c &TileCache) missing(t TileSpan) int {
	mut n := 0
	for j in t.j0 .. t.j1 + 1 {
		for i in t.i0 .. t.i1 + 1 {
			if c.key(i, j) !in c.out {
				n++
			}
		}
	}
	return n
}

// fill - досчитать недостающие плитки t моделью m по куску кадра pr
// (линейный RGB u16, накрывает g.window(t)); progress.step - после каждой
// новой плитки (false - отмена: посчитанное остаётся в кэше)
pub fn (mut c TileCache) fill(m Runner, t TileSpan, src &u16, pr Rect, mut progress Progress) ! {
	total := c.missing(t)
	mut done := 0
	mut input := []f32{len: 3 * tile * tile}
	for j in t.j0 .. t.j1 + 1 {
		for i in t.i0 .. t.i1 + 1 {
			k := c.key(i, j)
			c.tick++
			c.used[k] = c.tick
			if k in c.out {
				continue
			}
			c.grid.fill_input(i, j, src, pr, mut input)
			mut output := bigbuf.new_f32(3 * tile * tile)
			m.run(input, mut output, tile, tile) or {
				bigbuf.free(mut output)
				return err
			}
			c.out[k] = output
			done++
			if !progress.step(done, total) {
				return Cancelled{}
			}
		}
	}
}

// compose - результат шумодава прямоугольника r (линейный RGB u16) из
// плиток кэша; все нужные плитки должны быть посчитаны (иначе ошибка)
pub fn (c &TileCache) compose(r Rect) ![]u16 {
	g := &c.grid
	t := g.cover(r)
	if c.missing(t) > 0 {
		return error('не все плитки посчитаны')
	}
	mut acc := bigbuf.new_f32(r.w * r.h * 3)
	defer {
		bigbuf.free(mut acc)
	}
	// Порядок сложения - как у denoise_into: строки плиток, в строке слева
	for j in t.j0 .. t.j1 + 1 {
		for i in t.i0 .. t.i1 + 1 {
			g.accumulate(i, j, c.out[c.key(i, j)], mut acc, r)
		}
	}
	mut out := []u16{len: r.w * r.h * 3}
	finish(acc, mut out)
	return out
}

// trim - оставить не больше max плиток: вытесняются давно не нужные
pub fn (mut c TileCache) trim(max int) {
	for c.out.len > max {
		mut oldest := -1
		mut ot := u64(0)
		for k, _ in c.out {
			u := c.used[k] or { 0 }
			if oldest < 0 || u < ot {
				oldest = k
				ot = u
			}
		}
		mut a := c.out[oldest] or { break }
		bigbuf.free(mut a)
		c.out.delete(oldest)
		c.used.delete(oldest)
	}
}

pub fn (c &TileCache) len() int {
	return c.out.len
}

// free - все плитки системе
pub fn (mut c TileCache) free() {
	for k in c.out.keys() {
		mut a := c.out[k] or { continue }
		bigbuf.free(mut a)
	}
	c.out.clear()
	c.used.clear()
}
