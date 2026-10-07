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
//           резкость только по яркости, без цветных ореолов;
//           по каналам (rgb) - деталь каждого канала от его размытия,
//           маска краёв та же (по люме).
// Перцептивное пространство - как в RawTherapee (USM по L*): одинаковый
// ореол у светлого и тёмного края. Половинное превью - радиус × scale.
// Градиентные фильтры (local.v) добавляют к amount свою резкость на
// пиксель (буфер от прохода рендера); сумма меньше нуля - смягчение:
// L + a·(L - B), a ≥ -1 (-1 - размытая люма), без порога и маски краёв.
import math
import bigbuf
import runtime

// SharpView - показ работы резкости вместо снимка (с Alt при
// перетаскивании ползунка или флажком): mask - маска краёв (белое -
// резкость действует, чёрное - нет), detail - добавка резкости на сером
// 128 (×8; по каналам RGB - цветная)
pub enum SharpView {
	off
	mask
	detail
}

// apply_image - пайплайн кадра w x h с дымкой и резкостью. haze - карта
// дымки кадра (haze_map; nil - без удаления дымки). scale - масштаб кадра
// относительно полного (превью half-size - 0.5): радиус резкости задан в
// пикселях полного кадра. Без резкости - то же, что apply.
pub fn apply_image(src &u16, mask &u16, haze &HazeMap, w int, h int, p Params, scale f32, mut dst []u8, dst_stride int) {
	apply_image_view(src, mask, haze, w, h, p, scale, .off, mut dst, dst_stride)
}

// apply_image_view - apply_image с показом работы резкости (view != off):
// в dst вместо снимка - маска краёв или добавка резкости
pub fn apply_image_view(src &u16, mask &u16, haze &HazeMap, w int, h int, p Params, scale f32, view SharpView, mut dst []u8, dst_stride int) {
	npix := w * h
	lc := local_ctx(&p, &ImgRef{
		src: src
		w:   w
		h:   h
	})
	defer {
		free_ctx(&lc) // сетки кисти фильтров
	}
	if (p.sharp.amount <= 0 && p.texture == 0 && !lc.use_sp && view == .off) || w < 3 || h < 3 {
		render_ex(src, mask, haze, npix, p, mut dst, dst_stride, unsafe { nil }, &lc,
			unsafe { nil }, unsafe { nil })
		return
	}
	mut tone := bigbuf.new_u16(npix * 3)
	mut sp := if lc.use_sp { bigbuf.new_u8(npix) } else { []u8{} }
	defer {
		bigbuf.free(mut tone)
		if sp.len > 0 {
			bigbuf.free(mut sp)
		}
	}
	spp := if sp.len > 0 { unsafe { &u8(sp.data) } } else { unsafe { &u8(nil) } }
	render_ex(src, mask, haze, npix, p, mut dst, dst_stride, unsafe { &u16(tone.data) }, &lc,
		unsafe { nil }, spp)
	texture_tone(mut tone, w, h, p.texture, scale) // текстура - до резкости (texture.v)
	sharpen_tone(tone, spp, w, h, p.sharp, scale, p.dither, view, mut dst, dst_stride)
}

// sharpen_tone - резкость по тоновому буферу (×256) и запись 8 бит в dst.
// Маска краёв - всегда по размытой люме; добавка - одна на все каналы
// (по люме) или своя у каждого канала (s.rgb). sp - резкость фильтров на
// пиксель (sp_enc, npix байт) или nil.
fn sharpen_tone(tone []u16, sp &u8, w int, h int, s Sharpen, scale f32, dither bool, view SharpView, mut dst []u8, dst_stride int) {
	npix := w * h
	mut l := bigbuf.new_f32(npix)
	for i in 0 .. npix {
		l[i] = (0.2126 * f32(tone[3 * i]) + 0.7152 * f32(tone[3 * i + 1]) +
			0.0722 * f32(tone[3 * i + 2])) * f32(1.0 / 256.0)
	}
	mut sigma := s.radius * scale
	if sigma < 0.25 {
		sigma = 0.25
	}
	mut b := gauss_blur(l, w, h, sigma)
	// По каналам: размытые плоскости R, G, B (детали - от своего канала)
	mut cb := [][]f32{}
	if s.rgb {
		mut pl := bigbuf.new_f32(npix)
		for c in 0 .. 3 {
			for i in 0 .. npix {
				pl[i] = f32(tone[3 * i + c]) * f32(1.0 / 256.0)
			}
			cb << gauss_blur(pl, w, h, sigma)
		}
		bigbuf.free(mut pl)
	}
	defer {
		bigbuf.free(mut l)
		bigbuf.free(mut b)
		for c in 0 .. cb.len {
			bigbuf.free(mut cb[c])
		}
	}
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
				mut m := f32(1)
				if te2 > 0 {
					xl := if x > 0 { i - 1 } else { i }
					xr := if x < w - 1 { i + 1 } else { i }
					gx := pb[xr] - pb[xl]
					gy := pb[dn + x] - pb[up + x]
					e2 := gx * gx + gy * gy
					m = e2 / (e2 + te2)
				}
				j := 3 * i
				vr0 := f32(pt[j]) * f32(1.0 / 256.0)
				vg0 := f32(pt[j + 1]) * f32(1.0 / 256.0)
				vb0 := f32(pt[j + 2]) * f32(1.0 / 256.0)
				mut ar := f32(0)
				mut ag := f32(0)
				mut ab := f32(0)
				mut a := amount
				if !isnil(sp) {
					a += sp_dec(sp[i])
				}
				if a > 0 {
					if s.rgb {
						ar = a * m * soft_threshold(vr0 - cb[0][i], t2)
						ag = a * m * soft_threshold(vg0 - cb[1][i], t2)
						ab = a * m * soft_threshold(vb0 - cb[2][i], t2)
					} else {
						add := a * m * soft_threshold(pl[i] - pb[i], t2)
						ar = add
						ag = add
						ab = add
					}
				} else if a < 0 {
					// Смягчение фильтром: к размытому, без порога и маски краёв
					if a < -1 {
						a = -1
					}
					if s.rgb {
						ar = a * (vr0 - cb[0][i])
						ag = a * (vg0 - cb[1][i])
						ab = a * (vb0 - cb[2][i])
					} else {
						add := a * (pl[i] - pb[i])
						ar = add
						ag = add
						ab = add
					}
				}
				match view {
					.off {
						put_px(d, i, clamp255(vr0 + ar), clamp255(vg0 + ag), clamp255(vb0 + ab),
							dither, dst_stride)
					}
					.mask {
						g := m * 255
						put_px(d, i, g, g, g, false, dst_stride)
					}
					.detail {
						put_px(d, i, clamp255(128 + 8 * ar), clamp255(128 + 8 * ag), clamp255(128 +
							8 * ab), false, dst_stride)
					}
				}
				d += dst_stride
			}
		}
	}
}

// Резкость на выход (окно «Экспорт», resize_rgb_sharp): уменьшение
// усредняет соседние пиксели и смягчает края - мелкий unsharp mask по люме
// уже уменьшенного кадра возвращает чёткость. Радиус - в пикселях выхода
// (под размер экспорта, не кадра), порог в 1 уровень - не усиливать шум,
// добавка одна на все каналы - без цветных ореолов (как sharpen_tone).
const out_sharp_sigma = f32(0.6)
const out_sharp_t2 = f32(1.0)

// out_sharpen - резкость на выход по RGB w x h во f32 (тона 0..255), на
// месте; amount - доля детали (0.4 слабая .. 1.3 сильная)
pub fn out_sharpen(mut f []f32, w int, h int, amount f32) {
	npix := w * h
	if amount <= 0 || w < 3 || h < 3 || f.len < npix * 3 {
		return
	}
	mut l := bigbuf.new_f32(npix)
	for i in 0 .. npix {
		l[i] = 0.2126 * f[3 * i] + 0.7152 * f[3 * i + 1] + 0.0722 * f[3 * i + 2]
	}
	mut b := gauss_blur(l, w, h, out_sharp_sigma)
	defer {
		bigbuf.free(mut l)
		bigbuf.free(mut b)
	}
	for i in 0 .. npix {
		add := amount * soft_threshold(l[i] - b[i], out_sharp_t2)
		f[3 * i] += add
		f[3 * i + 1] += add
		f[3 * i + 2] += add
	}
}

// soft_threshold - мягкий порог детали: d · d²/(d² + t²) (t2 = 0 - без порога)
@[inline]
fn soft_threshold(d f32, t2 f32) f32 {
	if t2 <= 0 {
		return d
	}
	q := d * d
	return d * q / (q + t2)
}

@[inline]
fn clamp255(v f32) f32 {
	return if v < 0 {
		0
	} else if v > 255.0 {
		255.0
	} else {
		v
	}
}

// gauss_blur - гауссово размытие плоскости w x h (разделимое: строки,
// затем столбцы; у краёв - повтор крайнего пикселя). Результат - вне
// сборщика (bigbuf): освобождает вызывающий.
fn gauss_blur(src []f32, w int, h int, sigma f32) []f32 {
	k := gauss_kernel(sigma)
	mut tmp := bigbuf.new_f32(w * h)
	mut out := bigbuf.new_f32(w * h)
	gauss_into(src, mut out, mut tmp, w, h, k)
	bigbuf.free(mut tmp)
	return out
}

// gauss_kernel - нормированное ядро гаусса радиуса ⌈3σ⌉
fn gauss_kernel(sigma f32) []f32 {
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
	return k
}

// gauss_into - размытие src ядром k в out через рабочий буфер tmp (оба
// w * h, выделены заранее - деконволюция размывает десятки раз).
// Большие кадры - полосами строк в несколько потоков.
fn gauss_into(src []f32, mut out []f32, mut tmp []f32, w int, h int, k []f32) {
	ps := unsafe { &f32(src.data) }
	pt := unsafe { &f32(tmp.data) }
	po := unsafe { &f32(out.data) }
	pk := unsafe { &f32(k.data) }
	nt := bands(w, h)
	if nt <= 1 {
		gauss_rows(ps, pt, w, 0, h, pk, k.len)
		gauss_cols(pt, po, w, h, 0, h, pk, k.len)
		return
	}
	step := (h + nt - 1) / nt
	mut ts := []thread{}
	for y0 := 0; y0 < h; y0 += step {
		ts << spawn gauss_rows(ps, pt, w, y0, imin(h, y0 + step), pk, k.len)
	}
	ts.wait()
	ts.clear()
	// Столбцы - после всех строк: полоса читает строки соседних полос
	for y0 := 0; y0 < h; y0 += step {
		ts << spawn gauss_cols(pt, po, w, h, y0, imin(h, y0 + step), pk, k.len)
	}
	ts.wait()
}

// bands - сколько потоков давать проходу по кадру w x h (мелкие - один)
fn bands(w int, h int) int {
	if w * h < 250000 {
		return 1
	}
	n := runtime.nr_cpus()
	return if n > 16 { 16 } else { n }
}

@[inline]
fn imin(a int, b int) int {
	return if a < b { a } else { b }
}

// gauss_rows - размытие строк y0..y1 по x (src -> dst), ядро pk из kn
// элементов; середина строки без проверок края
fn gauss_rows(ps &f32, pt &f32, w int, y0 int, y1 int, pk &f32, kn int) {
	kr := kn / 2
	unsafe {
		for y in y0 .. y1 {
			row := y * w
			for x in 0 .. w {
				mut acc := f32(0)
				if x >= kr && x < w - kr {
					base := row + x - kr
					for j in 0 .. kn {
						acc += ps[base + j] * pk[j]
					}
				} else {
					for j in -kr .. kr + 1 {
						mut xx := x + j
						if xx < 0 {
							xx = 0
						} else if xx >= w {
							xx = w - 1
						}
						acc += ps[row + xx] * pk[j + kr]
					}
				}
				pt[row + x] = acc
			}
		}
	}
}

// gauss_cols - размытие по y строк результата y0..y1: строка - взвешенная
// сумма строк tmp (последовательный доступ к памяти)
fn gauss_cols(pt &f32, po &f32, w int, h int, y0 int, y1 int, pk &f32, kn int) {
	kr := kn / 2
	unsafe {
		for y in y0 .. y1 {
			row := y * w
			for x in 0 .. w {
				po[row + x] = 0
			}
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
}
