module pipeline

// Собственный пайплайн проявки по линейным 16-битным данным LibRaw.
//
// Вся арифметика во f32, 16 бит - только формат исходника (сенсор Canon
// даёт 14 бит, так что запас есть). Порядок операций:
//
//   линейный RGB -> экспозиция -> маска по люме (тени + тон-эквалайзер)
//     -> гамма 1/2.2 + контраст (S-кривая) -> насыщенность -> 8 бит
//
// Ради живых ползунков всё тяжёлое вынесено в две таблицы, которые
// перестраиваются за ~130К операций при изменении любого параметра:
//   mlut: люма u16 -> общий множитель линейного сигнала (экспозиция,
//         тени, эквалайзер) - маска по яркости, а не по каналу, чтобы
//         подъём теней не сдвигал цвет;
//   flut: линейное значение канала u16 -> тоновое значение 0..255
//         (гамма + камерная кривая + контраст);
//   slut: размытая люма u16 -> множитель «Тени/Света» (см. build_slut) -
//         маска по окрестности сохраняет локальный контраст.
// На пиксель остаются только умножения и выборки из таблиц.

import math

// Params - положение всех ползунков. Нулевые значения (и saturation = 1)
// дают нейтральную проявку: чистая гамма 2.2 по камерному ББ.
@[params]
pub struct Params {
pub mut:
	exposure   f32 // экспозиция, EV (-3..+3)
	contrast   f32 // контраст (-1..+1), S-кривая в тоновом пространстве
	saturation f32 = 1.0 // насыщенность (0..2), 1 = как есть
	shadows    f32 // проявка теней, EV (-1..+2), маска (1-t)^2
	eq         [5]f32 // тон-эквалайзер, EV: чёрные, тени, средние, света, белые
	sh_shadows    f32 // «Тени/Света»: подъём теней 0..100 (по размытой маске)
	sh_highlights f32 // «Тени/Света»: приглушение светов 0..100 (по размытой маске)
	// Тональная кривая «как камерный JPEG» (match_curve): 256 значений,
	// тон 0..255 -> тон 0..255. Пустой массив - кривой нет (тождественная).
	// Применяется после гаммы, до контраста.
	curve []f32
	// Дизеринг финального квантования в 8 бит (TPDF ±1 LSB) - убирает
	// полосы (banding) на гладких градиентах (небо). Включён по умолчанию.
	dither bool = true
}

const inv_gamma = f32(1.0 / 2.2)

// eq_ev - добавка эквалайзера в EV для тоновой позиции t (0..1):
// пять узлов на t = 0, 0.25, 0.5, 0.75, 1 с линейной интерполяцией.
fn eq_ev(p &Params, t f32) f32 {
	pos := t * 4.0
	mut i := int(pos)
	if i > 3 {
		i = 3
	}
	frac := pos - f32(i)
	return p.eq[i] * (1.0 - frac) + p.eq[i + 1] * frac
}

// build_mlut - таблица: линейная люма (u16) -> множитель линейного сигнала.
fn build_mlut(p &Params) []f32 {
	e := math.powf(2.0, p.exposure)
	mut m := []f32{len: 65536}
	for y in 0 .. 65536 {
		// Тоновая позиция считается после экспозиции
		mut yl := f32(y) * (1.0 / 65535.0) * e
		if yl > 1.0 {
			yl = 1.0
		}
		t := math.powf(yl, inv_gamma)
		w := (1.0 - t) * (1.0 - t) // маска теней: 1 в черноте, 0 в белом
		ev := p.shadows * w + eq_ev(p, t)
		m[y] = e * math.powf(2.0, ev)
	}
	return m
}

// build_flut - таблица: линейное значение канала (u16) -> тон 0..255 (f32).
// Гамма 1/2.2, затем контраст кривой v^a / (v^a + (1-v)^a), a = 2^contrast:
// гладкая S-кривая без клиппинга, a = 1 - тождественная.
fn build_flut(p &Params) []f32 {
	a := math.powf(2.0, p.contrast)
	has_curve := p.curve.len == 256
	mut f := []f32{len: 65536}
	for x in 0 .. 65536 {
		mut v := math.powf(f32(x) * (1.0 / 65535.0), inv_gamma)
		if has_curve {
			// Камерная кривая (линейная интерполяция между узлами)
			pos := v * 255.0
			mut i := int(pos)
			if i > 254 {
				i = 254
			}
			frac := pos - f32(i)
			v = (p.curve[i] * (1.0 - frac) + p.curve[i + 1] * frac) * f32(1.0 / 255.0)
		}
		mut g := v
		if p.contrast != 0 {
			va := math.powf(v, a)
			ia := math.powf(1.0 - v, a)
			g = if va + ia > 0 { va / (va + ia) } else { f32(0) }
		}
		f[x] = g * 255.0
	}
	return f
}

// build_slut - таблица инструмента «Тени/Света»: РАЗМЫТАЯ люма (u16) ->
// множитель линейного сигнала. Отличие от масок mlut: тоновая позиция
// берётся из размытой люмы окрестности (blur_luma), поэтому соседние
// пиксели получают почти одинаковый множитель - локальный контраст
// сохраняется, тени не становятся плоскими (приём RawTherapee/darktable).
// 100 на ползунке теней = +3 EV в черноте, светов = -2 EV в белом.
fn build_slut(p &Params) []f32 {
	e := math.powf(2.0, p.exposure)
	sh := p.sh_shadows * f32(3.0 / 100.0)
	hl := p.sh_highlights * f32(2.0 / 100.0)
	mut m := []f32{len: 65536}
	for y in 0 .. 65536 {
		mut yl := f32(y) * (1.0 / 65535.0) * e
		if yl > 1.0 {
			yl = 1.0
		}
		t := math.powf(yl, inv_gamma)
		ev := sh * (1.0 - t) * (1.0 - t) - hl * t * t
		m[y] = math.powf(2.0, ev)
	}
	return m
}

// match_curve - тональная кривая «как камерный JPEG» гистограммным
// сопоставлением (приём «Автоопределение тоновой кривой» RawTherapee).
// src - линейный 16-бит RGB (npix пикселей), ref - 8-бит RGB (stride 3,
// ref_npix пикселей) с камерной обработкой (встроенное превью RAW).
// Возвращает монотонную кривую тонов: 256 значений, тон 0..255 нашей
// нейтральной проявки (гамма 2.2) -> тон 0..255 камерного JPEG.
// Кадры могут быть разного размера - сопоставляются квантили яркости.
pub fn match_curve(src &u16, npix int, ref_ &u8, ref_npix int) []f32 {
	// Тон нейтральной проявки для каждой линейной люмы - через LUT.
	// Гистограммам не нужны все пиксели - сэмплируется каждый четвёртый
	// (на форму CDF это не влияет, а стоимость вчетверо ниже).
	p0 := Params{}
	tone := build_flut(&p0)
	mut hs := []f64{len: 256} // гистограмма тонов источника
	mut hr := []f64{len: 256} // гистограмма тонов камерного JPEG
	unsafe {
		mut s := src
		tl := &f32(tone.data)
		ps := &f64(hs.data)
		for _ in 0 .. npix / 4 {
			y := (54 * int(s[0]) + 183 * int(s[1]) + 19 * int(s[2])) >> 8
			ps[int(tl[y])] += 1.0
			s += 12
		}
		mut r := ref_
		pr := &f64(hr.data)
		for _ in 0 .. ref_npix / 4 {
			pr[(54 * int(r[0]) + 183 * int(r[1]) + 19 * int(r[2])) >> 8] += 1.0
			r += 12
		}
	}
	// Нормированные CDF
	mut cs := []f64{len: 257}
	mut cr := []f64{len: 257}
	for i in 0 .. 256 {
		cs[i + 1] = cs[i] + hs[i]
		cr[i + 1] = cr[i] + hr[i]
	}
	for i in 1 .. 257 {
		cs[i] /= cs[256]
		cr[i] /= cr[256]
	}
	// Сопоставление квантилей: тон v источника -> тон u JPEG той же доли
	mut curve := []f32{len: 256}
	mut u := 0
	for v in 0 .. 256 {
		q := cs[v + 1]
		for u < 255 && cr[u + 1] < q {
			u++
		}
		curve[v] = f32(u)
	}
	// Сглаживание (два прохода box r=2) + монотонность
	for _ in 0 .. 2 {
		mut sm := []f32{len: 256}
		for v in 0 .. 256 {
			lo := if v < 2 { 0 } else { v - 2 }
			hi := if v > 253 { 255 } else { v + 2 }
			mut sum := f32(0)
			for j in lo .. hi + 1 {
				sum += curve[j]
			}
			sm[v] = sum / f32(hi - lo + 1)
		}
		curve = sm.clone()
	}
	for v in 1 .. 256 {
		if curve[v] < curve[v - 1] {
			curve[v] = curve[v - 1]
		}
	}
	return curve
}

// blur_luma - маска для «Тени/Света»: BT.709-люма каждого пикселя,
// размытая приближением гауссова фильтра (тройной box blur, радиус ~1%
// большей стороны кадра). Считается один раз на кадр (зависит только от
// сырья, не от ползунков), в apply передаётся указателем.
pub fn blur_luma(src &u16, w int, h int) []u16 {
	npix := w * h
	mut a := []u16{len: npix}
	unsafe {
		mut s := src
		d := &u16(a.data)
		for i in 0 .. npix {
			d[i] = u16((54 * u32(s[0]) + 183 * u32(s[1]) + 19 * u32(s[2])) >> 8)
			s += 3
		}
	}
	mut r := (if w > h { w } else { h }) / 100
	if r < 2 {
		r = 2
	}
	mut b := []u16{len: npix}
	for _ in 0 .. 3 {
		box_blur_h(a, mut b, w, h, r)
		box_blur_v(b, mut a, w, h, r)
	}
	return a
}

// box_blur_h - горизонтальный box blur c бегущей суммой; окно
// [x-r, x+r] у краёв укорачивается (среднее по фактическому окну).
fn box_blur_h(src []u16, mut dst []u16, w int, h int, r int) {
	unsafe {
		s := &u16(src.data)
		d := &u16(dst.data)
		for y in 0 .. h {
			base := y * w
			mut sum := u32(0)
			mut hi := 0 // первый ещё не добавленный в окно индекс
			mut lo := 0 // первый входящий в окно индекс
			for x in 0 .. w {
				for hi <= x + r && hi < w {
					sum += u32(s[base + hi])
					hi++
				}
				for lo < x - r {
					sum -= u32(s[base + lo])
					lo++
				}
				d[base + x] = u16(sum / u32(hi - lo))
			}
		}
	}
}

// box_blur_v - вертикальный box blur: бегущие суммы сразу всех колонок
// (проход по строкам - последовательный доступ к памяти).
fn box_blur_v(src []u16, mut dst []u16, w int, h int, r int) {
	mut sums := []u32{len: w}
	unsafe {
		s := &u16(src.data)
		d := &u16(dst.data)
		ps := &u32(sums.data)
		mut hi := 0
		mut lo := 0
		for y in 0 .. h {
			for hi <= y + r && hi < h {
				row := hi * w
				for x in 0 .. w {
					ps[x] += u32(s[row + x])
				}
				hi++
			}
			for lo < y - r {
				row := lo * w
				for x in 0 .. w {
					ps[x] -= u32(s[row + x])
				}
				lo++
			}
			cnt := u32(hi - lo)
			row := y * w
			for x in 0 .. w {
				d[row + x] = u16(ps[x] / cnt)
			}
		}
	}
}

// apply прогоняет линейный 16-битный RGB (плотный, npix пикселей) через
// пайплайн и пишет 8-битный результат: dst_stride 4 - RGBA для холста
// (альфа 255), 3 - RGB для JPEG. dst должен вмещать npix * dst_stride байт.
// mask - размытая люма кадра (blur_luma, npix значений) для «Тени/Света»;
// nil допустим - тогда sh_shadows/sh_highlights игнорируются.
pub fn apply(src &u16, mask &u16, npix int, p Params, mut dst []u8, dst_stride int) {
	mlut := build_mlut(&p)
	flut := build_flut(&p)
	use_sh := !isnil(mask) && (p.sh_shadows != 0 || p.sh_highlights != 0)
	slut := if use_sh { build_slut(&p) } else { []f32{} }
	sat := p.saturation
	unsafe {
		mut s := src
		mut d := &u8(dst.data)
		ml := &f32(mlut.data)
		fl := &f32(flut.data)
		sl := &f32(slut.data)
		mk := mask
		for i in 0 .. npix {
			r := int(s[0])
			g := int(s[1])
			b := int(s[2])
			// Целочисленная люма BT.709: 54+183+19 = 256
			y := (54 * r + 183 * g + 19 * b) >> 8
			mut k := ml[y]
			if use_sh {
				k *= sl[int(mk[i])]
			}
			mut fr := f32(r) * k
			mut fg := f32(g) * k
			mut fb := f32(b) * k
			if fr > 65535.0 {
				fr = 65535.0
			}
			if fg > 65535.0 {
				fg = 65535.0
			}
			if fb > 65535.0 {
				fb = 65535.0
			}
			mut vr := fl[int(fr)]
			mut vg := fl[int(fg)]
			mut vb := fl[int(fb)]
			if sat != 1.0 {
				l := 0.2126 * vr + 0.7152 * vg + 0.0722 * vb
				vr = l + sat * (vr - l)
				vg = l + sat * (vg - l)
				vb = l + sat * (vb - l)
			}
			if vr < 0 {
				vr = 0
			} else if vr > 255.0 {
				vr = 255.0
			}
			if vg < 0 {
				vg = 0
			} else if vg > 255.0 {
				vg = 255.0
			}
			if vb < 0 {
				vb = 0
			} else if vb > 255.0 {
				vb = 255.0
			}
			if p.dither {
				// TPDF ±1 LSB: разность двух независимых LCG-семплов в [0,1)
				// даёт треугольное распределение шума (-1, 1), детерминировано
				// по индексу пикселя - воспроизводимость для тестов.
				mut seed := u32(i) * 2654435761
				seed = seed * 1664525 + 1013904223
				r1 := f32(seed >> 8) * (1.0 / 16777216.0)
				seed = seed * 1664525 + 1013904223
				r2 := f32(seed >> 8) * (1.0 / 16777216.0)
				seed = seed * 1664525 + 1013904223
				g1 := f32(seed >> 8) * (1.0 / 16777216.0)
				seed = seed * 1664525 + 1013904223
				g2 := f32(seed >> 8) * (1.0 / 16777216.0)
				seed = seed * 1664525 + 1013904223
				b1 := f32(seed >> 8) * (1.0 / 16777216.0)
				seed = seed * 1664525 + 1013904223
				b2 := f32(seed >> 8) * (1.0 / 16777216.0)
				vr += r1 - r2
				vg += g1 - g2
				vb += b1 - b2
				if vr < 0 {
					vr = 0
				} else if vr > 255.0 {
					vr = 255.0
				}
				if vg < 0 {
					vg = 0
				} else if vg > 255.0 {
					vg = 255.0
				}
				if vb < 0 {
					vb = 0
				} else if vb > 255.0 {
					vb = 255.0
				}
			}
			d[0] = u8(int(vr + 0.5))
			d[1] = u8(int(vg + 0.5))
			d[2] = u8(int(vb + 0.5))
			if dst_stride == 4 {
				d[3] = 255
			}
			s += 3
			d += dst_stride
		}
	}
}
