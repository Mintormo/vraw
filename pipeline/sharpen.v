module pipeline

// Резкость - последний шаг проявки: unsharp mask по люме в тоновом
// (гамма) пространстве, после HSL, перед квантованием в 8 бит.
//
//   L - люма тонов (BT.709 по тоновым R, G, B), B - L, размытая гауссом
//   радиуса radius; деталь d = L - B;
//   порог:  d' = d · d²/(d² + t²), t = detail · 0.06 (0..6 уровней из 255) -
//           мелкие перепады (шум) почти не усиливаются, крупные - как есть;
//   маска:  d'' = d' · e²/(e² + te²), e - градиент размытой люмы B,
//           te = masking · 0.15 - на ровном (небо, кожа) e мал, резкости нет;
//   выход:  R, G, B += amount/100 · d'' - одна добавка на все каналы:
//           резкость только по яркости, без цветных ореолов.
// Перцептивное пространство - как в RawTherapee (USM по L*): одинаковый
// ореол у светлого и тёмного края. Половинное превью - радиус × scale.
import math

// apply_image - пайплайн кадра w x h с дымкой и резкостью. haze - карта
// дымки кадра (haze_map; nil - без удаления дымки). scale - масштаб кадра
// относительно полного (превью half-size - 0.5): радиус резкости задан в
// пикселях полного кадра. Без резкости - то же, что apply.
pub fn apply_image(src &u16, mask &u16, haze &HazeMap, w int, h int, p Params, scale f32, mut dst []u8, dst_stride int) {
	npix := w * h
	if p.sharp.amount <= 0 || w < 3 || h < 3 {
		render(src, mask, haze, npix, p, mut dst, dst_stride, unsafe { nil })
		return
	}
	mut tone := []u16{len: npix * 3}
	render(src, mask, haze, npix, p, mut dst, dst_stride, unsafe { &u16(tone.data) })
	sharpen_tone(tone, w, h, p.sharp, scale, p.dither, mut dst, dst_stride)
}

// sharpen_tone - резкость по тоновому буферу (×256) и запись 8 бит в dst
fn sharpen_tone(tone []u16, w int, h int, s Sharpen, scale f32, dither bool, mut dst []u8, dst_stride int) {
	npix := w * h
	mut l := []f32{len: npix}
	for i in 0 .. npix {
		l[i] = (0.2126 * f32(tone[3 * i]) + 0.7152 * f32(tone[3 * i + 1]) +
			0.0722 * f32(tone[3 * i + 2])) * f32(1.0 / 256.0)
	}
	mut sigma := s.radius * scale
	if sigma < 0.25 {
		sigma = 0.25
	}
	b := gauss_blur(l, w, h, sigma)
	amount := s.amount / 100
	t := s.detail * 0.06
	t2 := t * t
	te := s.masking * 0.15
	te2 := te * te
	unsafe {
		pl := &f32(l.data)
		pb := &f32(b.data)
		pt := &u16(tone.data)
		mut d := &u8(dst.data)
		for y in 0 .. h {
			row := y * w
			up := if y > 0 { row - w } else { row }
			dn := if y < h - 1 { row + w } else { row }
			for x in 0 .. w {
				i := row + x
				mut dd := pl[i] - pb[i]
				if t2 > 0 {
					q := dd * dd
					dd *= q / (q + t2)
				}
				if te2 > 0 {
					xl := if x > 0 { i - 1 } else { i }
					xr := if x < w - 1 { i + 1 } else { i }
					gx := pb[xr] - pb[xl]
					gy := pb[dn + x] - pb[up + x]
					e2 := gx * gx + gy * gy
					dd *= e2 / (e2 + te2)
				}
				add := amount * dd
				j := 3 * i
				mut vr := f32(pt[j]) * f32(1.0 / 256.0) + add
				mut vg := f32(pt[j + 1]) * f32(1.0 / 256.0) + add
				mut vb := f32(pt[j + 2]) * f32(1.0 / 256.0) + add
				vr = clamp255(vr)
				vg = clamp255(vg)
				vb = clamp255(vb)
				put_px(d, i, vr, vg, vb, dither, dst_stride)
				d += dst_stride
			}
		}
	}
}

@[inline]
fn clamp255(v f32) f32 {
	return if v < 0 { 0 } else if v > 255.0 { 255.0 } else { v }
}

// gauss_blur - гауссово размытие плоскости w x h (разделимое: строки,
// затем столбцы; у краёв - повтор крайнего пикселя)
fn gauss_blur(src []f32, w int, h int, sigma f32) []f32 {
	kr := int(math.ceil(3 * sigma))
	mut k := []f32{len: 2 * kr + 1}
	mut sum := f32(0)
	for i in -kr .. kr + 1 {
		v := f32(math.exp(-f64(i * i) / (2 * f64(sigma) * f64(sigma))))
		k[i + kr] = v
		sum += v
	}
	for i in 0 .. k.len {
		k[i] /= sum
	}
	mut tmp := []f32{len: w * h}
	mut out := []f32{len: w * h}
	unsafe {
		ps := &f32(src.data)
		pt := &f32(tmp.data)
		po := &f32(out.data)
		pk := &f32(k.data)
		// По строкам
		for y in 0 .. h {
			row := y * w
			for x in 0 .. w {
				mut acc := f32(0)
				for j in -kr .. kr + 1 {
					mut xx := x + j
					if xx < 0 {
						xx = 0
					} else if xx >= w {
						xx = w - 1
					}
					acc += ps[row + xx] * pk[j + kr]
				}
				pt[row + x] = acc
			}
		}
		// По столбцам: строка результата - взвешенная сумма строк
		// (последовательный доступ к памяти)
		for y in 0 .. h {
			row := y * w
			for j in -kr .. kr + 1 {
				mut yy := y + j
				if yy < 0 {
					yy = 0
				} else if yy >= h {
					yy = h - 1
				}
				kw := pk[j + kr]
				srow := yy * w
				for x in 0 .. w {
					po[row + x] += pt[srow + x] * kw
				}
			}
		}
	}
	return out
}
