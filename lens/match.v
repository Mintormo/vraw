module lens

import math

// Подготовка к подбору силы коррекции виньетирования по JPEG камеры
// (сам подбор - в приложении, vign_match в loader.v: ему нужен пайплайн).
//
// JPEG камеры исправлен по дисторсии, поэтому сравнивать с ним можно
// только после geometry(). Чтобы перебор силы не повторял geometry на
// каждую пробу, рабочая копия кадра (match_side) проходит geometry один
// раз без виньетки, а карта усиления полного профиля - той же geometry
// (усиление закодировано в u16 и сдвинуто как кадр). Тогда кадр с силой s
// - это копия, умноженная на gain^s: усиление исходной точки сенсора, как
// при настоящем порядке «виньетка, потом геометрия» (отличие - только
// билинейная выборка гладкой карты).

// Длинная сторона рабочей копии: хватает для спада по радиусу, лишние
// пиксели только множат время
pub const match_side = 512
// База кодирования карты усиления в u16 (потолок vign_cap = 16: 64000)
const match_base = 4000.0

// MatchFrame - рабочая копия кадра для подбора силы: линейный RGB w x h
// после geometry без виньетки и ln усиления полного профиля в каждой точке
pub struct MatchFrame {
pub:
	w     int
	h     int
	lin   []u16
	lgain []f32
}

// match_dims - размер рабочей копии кадра w x h
pub fn match_dims(w int, h int) (int, int) {
	if w >= h {
		return match_side, imax(1, int(f64(h) * match_side / f64(w) + 0.5))
	}
	return imax(1, int(f64(w) * match_side / f64(h) + 0.5)), match_side
}

// match_frame - рабочая копия кадра для подбора силы. src - линейный RGB
// u16 w x h БЕЗ коррекции объектива. none - в профиле нет виньетирования.
pub fn (c &Corrector) match_frame(src &u16, w int, h int, focal f32, aperture f32) ?MatchFrame {
	if isnil(c.lens) || w <= 0 || h <= 0 {
		return none
	}
	rw, rh := match_dims(w, h)
	small := box_down(src, w, h, rw, rh)
	gmap := []u16{len: rw * rh * 3, init: u16(match_base)}
	if !c.vignetting(unsafe { &u16(gmap.data) }, rw, rh, focal, aperture, 1.0) {
		return none
	}
	c.geometry(unsafe { &u16(small.data) }, rw, rh, focal)
	c.geometry(unsafe { &u16(gmap.data) }, rw, rh, focal)
	mut lg := []f32{len: rw * rh}
	for i in 0 .. lg.len {
		lg[i] = f32(math.log(f64(imax(1, gmap[i * 3 + 1])) / match_base))
	}
	return MatchFrame{
		w:     rw
		h:     rh
		lin:   small
		lgain: lg
	}
}

// with_strength - рабочая копия с коррекцией виньетирования силы s
pub fn (m &MatchFrame) with_strength(s f32) []u16 {
	mut out := []u16{len: m.lin.len}
	for i in 0 .. m.lgain.len {
		g := f32(math.exp(f64(s * m.lgain[i])))
		for ch in 0 .. 3 {
			v := f32(m.lin[i * 3 + ch]) * g
			out[i * 3 + ch] = if v > 65535.0 { u16(65535) } else { u16(v) }
		}
	}
	return out
}

// downscale - уменьшение линейного RGB u16 w x h до dw x dh (среднее по
// прямоугольнику источника)
pub fn downscale(src &u16, w int, h int, dw int, dh int) []u16 {
	return box_down(src, w, h, dw, dh)
}

// box_down - уменьшение линейного RGB u16 w x h до dw x dh средним по
// прямоугольнику источника
fn box_down(src &u16, w int, h int, dw int, dh int) []u16 {
	mut out := []u16{len: dw * dh * 3}
	for y in 0 .. dh {
		v0 := y * h / dh
		v1 := imax(v0 + 1, (y + 1) * h / dh)
		for x in 0 .. dw {
			u0 := x * w / dw
			u1 := imax(u0 + 1, (x + 1) * w / dw)
			mut acc := [3]u64{}
			for v in v0 .. v1 {
				unsafe {
					mut p := src + (v * w + u0) * 3
					for _ in u0 .. u1 {
						acc[0] += p[0]
						acc[1] += p[1]
						acc[2] += p[2]
						p += 3
					}
				}
			}
			cnt := u64((v1 - v0) * (u1 - u0))
			for ch in 0 .. 3 {
				out[(y * dw + x) * 3 + ch] = u16(acc[ch] / cnt)
			}
		}
	}
	return out
}

fn imax(a int, b int) int {
	return if a > b { a } else { b }
}
