module pipeline

// Точечный цвет (как Point Color в Lightroom, Color Editor в Capture One):
// цвет, взятый пипеткой со снимка, и правки только для него - сдвиг
// оттенка, насыщенность, яркость. В отличие от HSL (8 постоянных
// диапазонов оттенка) выделение - вокруг конкретного цвета сразу по трём
// осям: оттенку, насыщенности и яркости, с шириной «Диапазон».
//
// Место в пайплайне - сразу после HSL, в тоновом пространстве (0..255), в
// Ч/Б не действует (как HSL). Вес пикселя для точки - произведение трёх
// гладких «колоколов» (1 − t²)² по расстоянию до центра в долях
// полуширины (t ≥ 1 - вес 0): оттенок по кругу (секстанты HSV), HSV-
// насыщенность, яркость V. Полуширины растут с «Диапазоном» r = 0..1:
// оттенок 15° + 45°·r, насыщенность 0.2 + 0.6·r, яркость (0.25 + 0.75·r)
// шкалы. Правки точек складываются: сдвиги оттенка и яркости (EV) -
// суммой с весами, насыщенность - произведением множителей. Серое (размах
// каналов < 0.5 уровня) не трогается: оттенка у него нет.
import math

pub const pcolor_max = 8

// PointColor - точка: центр (цвет пипетки до точечного цвета) и правки
pub struct PointColor {
pub mut:
	hue   f32 // оттенок HSV центра, градусы 0..360
	sat   f32 // насыщенность HSV центра, 0..1
	val   f32 // яркость V центра (тон), 0..1
	dhue  f32 // -100..100: ±30°
	dsat  f32 // -100..100: -100 - серое, +100 - ×2
	dlum  f32 // -100..100: ±1 EV
	range f32 = 50 // 0..100 - ширина выделения
}

// active - точка что-то меняет
pub fn (p PointColor) active() bool {
	return p.dhue != 0 || p.dsat != 0 || p.dlum != 0
}

// pcolor_on - есть точка, которая что-то меняет (в Ч/Б - нет)
pub fn pcolor_on(p &Params) bool {
	if p.bw {
		return false
	}
	for c in p.pcolor {
		if c.active() {
			return true
		}
	}
	return false
}

// pcolor_weight - вес пикселя (оттенок h в секстантах 0..6, насыщенность
// s 0..1, яркость v 0..255) для точки c: 0..1
pub fn pcolor_weight(c PointColor, h f32, s f32, v f32) f32 {
	pt := pc_point(c)
	return pc_w(&pt, h, s, v)
}

// PcPt - точка, готовая для рендера: центры и обратные полуширины
struct PcPt {
	hc  f32 // центр оттенка, секстанты 0..6
	ihw f32 // 1 / полуширина оттенка (секстанты)
	sc  f32
	isw f32
	vc  f32 // центр яркости, 0..255
	ivw f32
	dh  f32 // сдвиг оттенка, секстанты (±0.5 = ±30°)
	ds  f32 // множитель насыщенности - 1 (-1..1)
	dl  f32 // яркость, EV (-1..1)
}

// PcLut - активные точки кадра (не больше pcolor_max)
pub struct PcLut {
mut:
	n   int
	pts [pcolor_max]PcPt
}

fn pc_point(c PointColor) PcPt {
	r := clampf32(c.range, 0, 100) / 100
	return PcPt{
		hc:  f32(math.fmod(f64(c.hue) / 60, 6) + if c.hue < 0 { 6.0 } else { 0.0 })
		ihw: 1 / (0.25 + 0.75 * r)
		sc:  clampf32(c.sat, 0, 1)
		isw: 1 / (0.2 + 0.6 * r)
		vc:  clampf32(c.val, 0, 1) * 255
		ivw: 1 / ((0.25 + 0.75 * r) * 255)
		dh:  clampf32(c.dhue, -100, 100) / 200
		ds:  clampf32(c.dsat, -100, 100) / 100
		dl:  clampf32(c.dlum, -100, 100) / 100
	}
}

// build_pcolor - активные точки для рендера
fn build_pcolor(pc []PointColor) PcLut {
	mut l := PcLut{}
	for c in pc {
		if c.active() && l.n < pcolor_max {
			l.pts[l.n] = pc_point(c)
			l.n++
		}
	}
	return l
}

// pc_bell - «колокол» (1 − t²)² при t < 1, иначе 0
@[inline]
fn pc_bell(t f32) f32 {
	if t >= 1 {
		return 0
	}
	u := 1 - t * t
	return u * u
}

@[inline]
fn pc_w(pt &PcPt, h f32, s f32, v f32) f32 {
	mut d := h - pt.hc
	if d < 0 {
		d = -d
	}
	if d > 3 {
		d = 6 - d
	}
	wh := pc_bell(d * pt.ihw)
	if wh == 0 {
		return 0
	}
	ds := if s > pt.sc { s - pt.sc } else { pt.sc - s }
	ws := pc_bell(ds * pt.isw)
	if ws == 0 {
		return 0
	}
	dv := if v > pt.vc { v - pt.vc } else { pt.vc - v }
	return wh * ws * pc_bell(dv * pt.ivw)
}

// pcolor_pixel - точечный цвет пикселя тона (0..255)
fn pcolor_pixel(r f32, g f32, b f32, l &PcLut) (f32, f32, f32) {
	mx := if r > g { if r > b { r } else { b } } else { if g > b { g } else { b } }
	mn := if r < g { if r < b { r } else { b } } else { if g < b { g } else { b } }
	c := mx - mn
	if c < 0.5 {
		return r, g, b
	}
	inv_c := 1 / c
	mut h := if mx == r {
		(g - b) * inv_c
	} else if mx == g {
		(b - r) * inv_c + 2
	} else {
		(r - g) * inv_c + 4
	}
	if h < 0 {
		h += 6
	}
	s := c / mx
	mut dh := f32(0)
	mut k := f32(1)
	mut dl := f32(0)
	mut hit := false
	for i in 0 .. l.n {
		pt := &l.pts[i]
		w := pc_w(pt, h, s, mx)
		if w == 0 {
			continue
		}
		hit = true
		dh += w * pt.dh
		k *= 1 + w * pt.ds
		dl += w * pt.dl
	}
	if !hit {
		return r, g, b
	}
	v := if dl != 0 { mx * exp2f(dl) } else { mx }
	if s * k > 1 {
		k = 1 / s // насыщенность HSV не больше 1
	}
	if dh == 0 {
		// Без сдвига оттенка - без обратного перевода (как hsl_pixel)
		q := v / mx
		return q * (mx - k * (mx - r)), q * (mx - k * (mx - g)), q * (mx - k * (mx - b))
	}
	h += dh
	if h < 0 {
		h += 6
	} else if h >= 6 {
		h -= 6
	}
	s2 := s * k
	sec := int(h)
	f := h - f32(sec)
	pp := v * (1 - s2)
	q := v * (1 - s2 * f)
	t := v * (1 - s2 * (1 - f))
	return match sec {
		0 { v, t, pp }
		1 { q, v, pp }
		2 { pp, v, t }
		3 { pp, q, v }
		4 { t, pp, v }
		else { v, pp, q }
	}
}

// rgb_point - центр точки по цвету тона (0..255): оттенок в градусах,
// насыщенность и яркость HSV (для пипетки)
pub fn rgb_point(r f32, g f32, b f32) PointColor {
	mx := if r > g { if r > b { r } else { b } } else { if g > b { g } else { b } }
	mn := if r < g { if r < b { r } else { b } } else { if g < b { g } else { b } }
	c := mx - mn
	if mx <= 0 {
		return PointColor{}
	}
	mut h := f32(0)
	if c > 0 {
		h = if mx == r {
			(g - b) / c
		} else if mx == g {
			(b - r) / c + 2
		} else {
			(r - g) / c + 4
		}
		if h < 0 {
			h += 6
		}
	}
	return PointColor{
		hue: h * 60
		sat: c / mx
		val: mx / 255
	}
}

fn clampf32(v f32, lo f32, hi f32) f32 {
	return if v < lo { lo } else if v > hi { hi } else { v }
}
