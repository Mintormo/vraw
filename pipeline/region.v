module pipeline

// Части кадра - для настоящего 1:1: видимый фрагмент полного кадра
// считается той же цепочкой, что весь кадр на экспорте, но только в своём
// прямоугольнике (плюс запас для фильтров с окрестностью).
//
// geom_apply_region даёт прямоугольник выхода геометрии, побитово равный
// той же области geom_apply по всему кадру, если сырьё в нужном куске
// источника (geom_source_box) то же самое. Маска «Тени/Света» и карта
// дымки гладкие - их фрагмент берётся из превью с увеличением
// (upsample_region, haze_region).
import math

// Region - прямоугольник в пикселях (x, y - левый верхний угол)
pub struct Region {
pub:
	x int
	y int
	w int
	h int
}

pub fn (r Region) is_empty() bool {
	return r.w <= 0 || r.h <= 0
}

// contains - r целиком внутри o
pub fn (o Region) contains(r Region) bool {
	return r.x >= o.x && r.y >= o.y && r.x + r.w <= o.x + o.w && r.y + r.h <= o.y + o.h
}

// expand - r с запасом m по всем сторонам, в пределах w x h
pub fn (r Region) expand(m int, w int, h int) Region {
	x0 := if r.x - m < 0 { 0 } else { r.x - m }
	y0 := if r.y - m < 0 { 0 } else { r.y - m }
	x1 := if r.x + r.w + m > w { w } else { r.x + r.w + m }
	y1 := if r.y + r.h + m > h { h } else { r.y + r.h + m }
	return Region{x0, y0, x1 - x0, y1 - y0}
}

// crop_region - копия прямоугольника r буфера w x h с ch каналами
pub fn crop_region(src &u16, w int, ch int, r Region) []u16 {
	mut out := []u16{len: r.w * r.h * ch}
	unsafe {
		for j in 0 .. r.h {
			vmemcpy(&u16(out.data) + j * r.w * ch, src + ((r.y + j) * w + r.x) * ch, r.w * ch * 2)
		}
	}
	return out
}

// geom_source_box - прямоугольник источника w x h, из которого
// geom_apply_region читает выход r (выход ow x oh - g.out_size(w, h, crop)):
// все точки выборки, с соседями билинейной интерполяции.
pub fn geom_source_box(g Geom, w int, h int, crop bool, r Region) Region {
	if r.is_empty() {
		return Region{}
	}
	if geom_is_copy(g, crop) {
		return r
	}
	ow, oh := g.out_size(w, h, crop)
	m := geom_affine(g, w, h, crop, ow, oh)
	pp := if g.has_persp() { geom_proj(g, w, h, crop, ow, oh) } else { Proj{} }
	mut sx0 := math.max_f64
	mut sy0 := math.max_f64
	mut sx1 := -math.max_f64
	mut sy1 := -math.max_f64
	// Отображение аффинное или проективное (прямые - в прямые) - крайние
	// точки у углов прямоугольника
	for c in [[r.x, r.y], [r.x + r.w - 1, r.y], [r.x, r.y + r.h - 1],
		[r.x + r.w - 1, r.y + r.h - 1]] {
		mut sx := m.a * c[0] + m.b * c[1] + m.c
		mut sy := m.d * c[0] + m.e * c[1] + m.f
		if g.has_persp() {
			sx, sy = pp.at(f64(c[0]), f64(c[1]))
		}
		sx0 = math.min(sx0, sx)
		sy0 = math.min(sy0, sy)
		sx1 = math.max(sx1, sx)
		sy1 = math.max(sy1, sy)
	}
	// Ближайший пиксель - floor(s); билинейная - floor(s - 0.5) и +1
	x0 := clamp_i(int(math.floor(sx0 - 0.5)) - 1, 0, w - 1)
	y0 := clamp_i(int(math.floor(sy0 - 0.5)) - 1, 0, h - 1)
	x1 := clamp_i(int(math.floor(sx1)) + 2, 0, w - 1)
	y1 := clamp_i(int(math.floor(sy1)) + 2, 0, h - 1)
	return Region{x0, y0, x1 - x0 + 1, y1 - y0 + 1}
}

// geom_is_copy - геометрия выдаёт кадр как есть (geom_apply - копия)
fn geom_is_copy(g Geom, crop bool) bool {
	return g.is_noop(crop)
}

fn clamp_i(v int, lo int, hi int) int {
	return if v < lo { lo } else if v > hi { hi } else { v }
}

// geom_apply_region - прямоугольник r выхода geom_apply(src полного кадра
// w x h). src - не весь кадр, а его кусок sb (обычно geom_source_box(r)
// или шире): буфер sb.w x sb.h с ch каналами. Отображение и правила
// выборки - те же, что у geom_apply, поэтому результат побитово равен
// вырезке из полного прохода.
pub fn geom_apply_region(src &u16, sb Region, w int, h int, ch int, g Geom, crop bool, r Region) []u16 {
	mut out := []u16{len: r.w * r.h * ch}
	if r.is_empty() {
		return out
	}
	// Читает пиксель (sx, sy) полного кадра из куска sb
	at := fn [src, sb, ch] (sx int, sy int) &u16 {
		return unsafe { src + ((sy - sb.y) * sb.w + (sx - sb.x)) * ch }
	}
	if geom_is_copy(g, crop) {
		for j in 0 .. r.h {
			unsafe {
				vmemcpy(&u16(out.data) + j * r.w * ch, at(r.x, r.y + j), r.w * ch * 2)
			}
		}
		return out
	}
	ow, oh := g.out_size(w, h, crop)
	if g.has_persp() || g.angle != 0 {
		persp_apply(src, sb, w, h, ch, geom_proj(g, w, h, crop, ow, oh), r, unsafe { &u16(out.data) })
		return out
	}
	// Без поворота - ближайший пиксель, как у geom_apply
	m := geom_affine(g, w, h, crop, ow, oh)
	unsafe {
		mut d := &u16(out.data)
		for j in r.y .. r.y + r.h {
			for i in r.x .. r.x + r.w {
				sx := clamp_i(int(math.floor(m.a * i + m.b * j + m.c)), 0, w - 1)
				sy := clamp_i(int(math.floor(m.d * i + m.e * j + m.f)), 0, h - 1)
				s := at(sx, sy)
				for c in 0 .. ch {
					d[c] = s[c]
				}
				d += ch
			}
		}
	}
	return out
}

// upsample_region - прямоугольник r кадра ow x oh, взятый билинейно из
// того же кадра в меньшем размере src (sw x sh, ch каналов): центры
// пикселей совмещены по долям кадра. Для гладких карт (маска «Тени/
// Света», дымка), посчитанных по превью.
pub fn upsample_region(src []u16, sw int, sh int, ch int, ow int, oh int, r Region) []u16 {
	mut out := []u16{len: r.w * r.h * ch}
	if sw <= 0 || sh <= 0 || src.len < sw * sh * ch || r.is_empty() {
		return out
	}
	kx := f64(sw) / f64(ow)
	ky := f64(sh) / f64(oh)
	mut o := 0
	for j in r.y .. r.y + r.h {
		fy := (f64(j) + 0.5) * ky - 0.5
		mut y0 := int(math.floor(fy))
		ty := f32(fy - f64(y0))
		mut y1 := y0 + 1
		y0 = clamp_i(y0, 0, sh - 1)
		y1 = clamp_i(y1, 0, sh - 1)
		for i in r.x .. r.x + r.w {
			fx := (f64(i) + 0.5) * kx - 0.5
			mut x0 := int(math.floor(fx))
			tx := f32(fx - f64(x0))
			mut x1 := x0 + 1
			x0 = clamp_i(x0, 0, sw - 1)
			x1 = clamp_i(x1, 0, sw - 1)
			for c in 0 .. ch {
				p00 := f32(src[(y0 * sw + x0) * ch + c])
				p10 := f32(src[(y0 * sw + x1) * ch + c])
				p01 := f32(src[(y1 * sw + x0) * ch + c])
				p11 := f32(src[(y1 * sw + x1) * ch + c])
				top := p00 + (p10 - p00) * tx
				bot := p01 + (p11 - p01) * tx
				out[o] = u16(top + (bot - top) * ty + 0.5)
				o++
			}
		}
	}
	return out
}

// haze_region - карта дымки прямоугольника r кадра ow x oh из карты того
// же кадра в другом размере (превью): та же A, D - с увеличением. Пустая
// карта - пустая (удаление дымки выключено).
pub fn haze_region(hm &HazeMap, ow int, oh int, r Region) HazeMap {
	if hm.d.len == 0 {
		return HazeMap{}
	}
	return HazeMap{
		w: r.w
		h: r.h
		d: upsample_region(hm.d, hm.w, hm.h, 1, ow, oh, r)
		a: hm.a
	}
}
