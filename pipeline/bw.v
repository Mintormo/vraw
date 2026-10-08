module pipeline

// Чёрно-белое с микшером каналов (как B&W Mix в Lightroom): серый -
// BT.709-люма пикселя в тоновом пространстве, а 8 ползунков (диапазоны
// оттенков hsl_centers: красный ... пурпурный, -100..100) делают светлее
// или темнее то, что в кадре было этого цвета: небо темнее, кожа светлее.
// Своя реализация.
//
//   l = 0.2126 r + 0.7152 g + 0.0722 b         тон 0..255, после кривых
//   s = (max - min)/max                        насыщенность HSV - серое
//                                              микшер не трогает
//   k = mix(h)/100                             по кругу оттенков, линейно
//                                              между центрами (hsl_interp)
//   серый = l · 2^(k·s·bw_ev/2.2)              ±100 у чистого цвета - ±2 EV
//
// Место - вместо насыщенности, сочности и HSL (в Ч/Б они не действуют, как
// в Lightroom: цвет кадра - только источник для микшера), перед
// цветокоррекцией - тонирование ложится на серое (раздельное
// тонирование). Множитель по оттенку - таблица на hsl_bins корзин
// (build_bw), на пиксель - min/max, оттенок и одна exp2f; нулевой
// микшер - только люма.

const bw_ev = f32(2.0)

// bw_active_mix - есть ли ненулевой ползунок микшера
fn bw_active_mix(p &Params) bool {
	for v in p.bw_mix {
		if v != 0 {
			return true
		}
	}
	return false
}

// build_bw - показатель степени по корзине оттенка: k·bw_ev/2.2 (умножается
// на насыщенность пикселя)
fn build_bw(p &Params) []f32 {
	mut t := []f32{len: hsl_bins}
	for b in 0 .. hsl_bins {
		deg := (f32(b) + 0.5) * 360.0 / f32(hsl_bins)
		t[b] = hsl_interp(p.bw_mix, deg) / 100 * bw_ev / 2.2
	}
	return t
}

// bw_pixel - серый тон пикселя (клип - у вызывающего); bt - таблица
// build_bw или nil (микшер нулевой - чистая люма)
@[inline]
fn bw_pixel(r f32, g f32, b f32, bt &f32) f32 {
	l := 0.2126 * r + 0.7152 * g + 0.0722 * b
	if isnil(bt) {
		return l
	}
	mx := if r > g { if r > b { r } else { b } } else { if g > b { g } else { b } }
	mn := if r < g { if r < b { r } else { b } } else { if g < b { g } else { b } }
	c := mx - mn
	if c < 0.5 {
		return l
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
	mut bin := int(h * f32(hsl_bins) / 6.0)
	if bin >= hsl_bins {
		bin = hsl_bins - 1
	}
	e := unsafe { bt[bin] } * c / mx
	if e == 0 {
		return l
	}
	return l * exp2f(e)
}
