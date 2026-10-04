module pipeline

// Capture-резкость (как «Capture sharpening» RawTherapee): возврат
// резкости, потерянной в оптике и демозаике, - деконволюция Ричардсона-
// Люси по ЛИНЕЙНОЙ люме, до тонального пайплайна.
//
//   Y - линейная люма BT.709; PSF - гаусс σ = dc_radius (px полного
//   кадра, на превью × scale); итерации (dc_iters):
//     est ← est · G∗(Y / G∗est)
//   порог контраста: вес m = c²/(c² + t²), c - градиент гамма-люмы
//   (на пиксель полного кадра), t = dc_contrast · 0.0005 - ровные и
//   шумные места (небо, кожа, тени) не трогаются;
//   выход: Y' = Y + a·m·(est − Y), a = dc_amount/100; каналы R, G, B
//   умножаются на Y'/Y (цвет не меняется), множитель в [0.5, 2].
// Зависит только от сырья и трёх ползунков: GUI держит результат в кэше
// и пересчитывает лишь при их смене; экспорт - один раз на полный кадр.
import math
import bigbuf

pub const dc_iters = 20

// deconvolve - Capture-резкость линейного буфера w x h (RGB u16) в новый
// буфер; при dc_amount <= 0 - копия
pub fn deconvolve(src &u16, w int, h int, s Sharpen, scale f32) []u16 {
	mut out := []u16{len: w * h * 3}
	deconvolve_into(src, w, h, s, scale, mut out)
	return out
}

// deconvolve_into - то же в готовый буфер out (w * h * 3; экспорт даёт
// буфер вне сборщика - bigbuf)
pub fn deconvolve_into(src &u16, w int, h int, s Sharpen, scale f32, mut out []u16) {
	npix := w * h
	unsafe { vmemcpy(out.data, src, npix * 6) }
	if s.dc_amount <= 0 || w < 3 || h < 3 {
		return
	}
	// Рабочие плоскости - вне сборщика (bigbuf): на полном кадре 4 x 96 МБ
	mut y := bigbuf.new_f32(npix)
	mut est := bigbuf.new_f32(npix)
	mut conv := bigbuf.new_f32(npix)
	mut tmp := bigbuf.new_f32(npix)
	defer {
		bigbuf.free(mut y)
		bigbuf.free(mut est)
		bigbuf.free(mut conv)
		bigbuf.free(mut tmp)
	}
	unsafe {
		for i in 0 .. npix {
			y[i] = 0.2126 * f32(src[3 * i]) + 0.7152 * f32(src[3 * i + 1]) +
				0.0722 * f32(src[3 * i + 2])
		}
	}
	mut sigma := s.dc_radius * scale
	if sigma < 0.2 {
		sigma = 0.2
	}
	k := gauss_kernel(sigma)
	unsafe { vmemcpy(est.data, y.data, npix * int(sizeof(f32))) }
	py := unsafe { &f32(y.data) }
	pe := unsafe { &f32(est.data) }
	pc := unsafe { &f32(conv.data) }
	pt := unsafe { &f32(tmp.data) }
	pk := unsafe { &f32(k.data) }
	nt := bands(w, h)
	step := (h + nt - 1) / nt
	mut ts := []thread{}
	for _ in 0 .. dc_iters {
		// G∗est -> отношение Y / G∗est (в conv)
		for y0 := 0; y0 < h; y0 += step {
			ts << spawn gauss_rows(pe, pt, w, y0, imin(h, y0 + step), pk, k.len)
		}
		ts.wait()
		ts.clear()
		for y0 := 0; y0 < h; y0 += step {
			ts << spawn dc_cols(pt, pc, py, pe, w, h, y0, imin(h, y0 + step), pk, k.len,
				false)
		}
		ts.wait()
		ts.clear()
		// G∗отношение -> est *= (PSF симметрична: G^T = G)
		for y0 := 0; y0 < h; y0 += step {
			ts << spawn gauss_rows(pc, pt, w, y0, imin(h, y0 + step), pk, k.len)
		}
		ts.wait()
		ts.clear()
		for y0 := 0; y0 < h; y0 += step {
			ts << spawn dc_cols(pt, pc, py, pe, w, h, y0, imin(h, y0 + step), pk, k.len,
				true)
		}
		ts.wait()
		ts.clear()
	}
	mut m := contrast_mask(y, w, h, s.dc_contrast, scale)
	defer {
		bigbuf.free(mut m)
	}
	a := s.dc_amount / 100
	unsafe {
		for i in 0 .. npix {
			yy := y[i]
			if yy < 1 {
				continue
			}
			mut kk := (yy + a * m[i] * (est[i] - yy)) / yy
			if kk < 0.5 {
				kk = 0.5
			} else if kk > 2 {
				kk = 2
			}
			j := 3 * i
			for c in 0 .. 3 {
				v := f32(src[j + c]) * kk
				out[j + c] = if v >= 65535 { u16(65535) } else { u16(v + 0.5) }
			}
		}
	}
}

// contrast_mask - вес деконволюции 0..1 по локальному контрасту: градиент
// сглаженной гамма-люмы на пиксель ПОЛНОГО кадра (превью half-size -
// scale 0.5: соседние пиксели вдвое дальше), мягкий порог t. Результат -
// вне сборщика (bigbuf): освобождает вызывающий.
fn contrast_mask(y []f32, w int, h int, contrast f32, scale f32) []f32 {
	npix := w * h
	mut m := bigbuf.new_f32(npix)
	t := contrast * 0.0005
	if t <= 0 {
		for i in 0 .. npix {
			m[i] = 1
		}
		return m
	}
	t2 := t * t
	// Гамма по таблице: люма u16 -> тон 0..1
	mut g := []f32{len: 65536}
	for i in 0 .. 65536 {
		g[i] = math.powf(f32(i) / 65535.0, inv_gamma)
	}
	mut v := bigbuf.new_f32(npix)
	for i in 0 .. npix {
		yy := y[i]
		v[i] = if yy <= 0 {
			0
		} else if yy >= 65535 {
			1
		} else {
			g[int(yy)]
		}
	}
	mut vs := gauss_blur(v, w, h, 0.7)
	bigbuf.free(mut v)
	defer {
		bigbuf.free(mut vs)
	}
	f := scale / 2 // центральная разность - два шага по scale пикселя
	for yy in 0 .. h {
		row := yy * w
		up := if yy > 0 { row - w } else { row }
		dn := if yy < h - 1 { row + w } else { row }
		for x in 0 .. w {
			i := row + x
			xl := if x > 0 { i - 1 } else { i }
			xr := if x < w - 1 { i + 1 } else { i }
			gx := (vs[xr] - vs[xl]) * f
			gy := (vs[dn + x] - vs[up + x]) * f
			c2 := gx * gx + gy * gy
			m[i] = c2 / (c2 + t2)
		}
	}
	return m
}

// dc_cols - проход гаусса по y для строк y0..y1 (tmp -> conv) и сразу
// поэлементный шаг Ричардсона-Люси: update = false - conv = Y / G∗est,
// update = true - est *= G∗отношение
fn dc_cols(pt &f32, pc &f32, py &f32, pe &f32, w int, h int, y0 int, y1 int, pk &f32, kn int, update bool) {
	gauss_cols(pt, pc, w, h, y0, y1, pk, kn)
	unsafe {
		for i in y0 * w .. y1 * w {
			if update {
				pe[i] *= pc[i]
			} else {
				c := pc[i]
				pc[i] = if c > 1 { py[i] / c } else { 1 }
			}
		}
	}
}
