module pipeline

import math

// Кадр w x h: левая половина тёмно-серая, правая светлая (вертикальный
// край), плюс слабый детерминированный шум
fn edge_frame(w int, h int, noise int) []u16 {
	mut src := []u16{len: w * h * 3}
	mut seed := u32(12345)
	for y in 0 .. h {
		for x in 0 .. w {
			mut v := if x < w / 2 { 8000 } else { 30000 }
			if noise > 0 {
				seed = seed * 1664525 + 1013904223
				v += int(seed >> 20) % (2 * noise + 1) - noise
			}
			i := (y * w + x) * 3
			src[i] = u16(v)
			src[i + 1] = u16(v)
			src[i + 2] = u16(v)
		}
	}
	return src
}

fn render_sharp(src []u16, w int, h int, s Sharpen) []u8 {
	mut p := Params{
		dither: false
		sharp:  s
	}
	mut out := []u8{len: w * h * 3}
	apply_image(unsafe { &u16(src.data) }, unsafe { nil }, unsafe { nil }, w, h, p, 1.0, mut out, 3)
	return out
}

fn test_sharpen_off_equals_apply() {
	w, h := 40, 20
	src := edge_frame(w, h, 300)
	mut a := []u8{len: w * h * 3}
	apply(unsafe { &u16(src.data) }, unsafe { nil }, w * h, Params{ dither: false }, mut a, 3)
	b := render_sharp(src, w, h, Sharpen{})
	assert a == b
	// Радиус по умолчанию - 1 px
	assert Params{}.sharp.radius == 1.0
}

fn test_sharpen_edge_contrast() {
	w, h := 40, 20
	src := edge_frame(w, h, 0)
	base := render_sharp(src, w, h, Sharpen{})
	sh := render_sharp(src, w, h, Sharpen{ amount: 100 })
	row := 10 * w
	x0 := w / 2 - 1 // последний тёмный
	x1 := w / 2 // первый светлый
	// У края тёмное темнее, светлое светлее (ореол USM)
	assert sh[(row + x0) * 3] < base[(row + x0) * 3]
	assert sh[(row + x1) * 3] > base[(row + x1) * 3]
	// Вдали от края - без изменений, серое остаётся серым
	assert sh[(row + 3) * 3] == base[(row + 3) * 3]
	assert sh[(row + w - 3) * 3] == base[(row + w - 3) * 3]
	for i in 0 .. w * h {
		assert sh[i * 3] == sh[i * 3 + 1] && sh[i * 3] == sh[i * 3 + 2]
	}
}

// Сумма квадратов отклонений от базовой проявки на ровном участке
fn flat_diff(a []u8, b []u8, w int, h int) f64 {
	mut s := 0.0
	for y in 2 .. h - 2 {
		for x in 2 .. w / 2 - 4 {
			d := f64(int(a[(y * w + x) * 3]) - int(b[(y * w + x) * 3]))
			s += d * d
		}
	}
	return s
}

// Порог и маска краёв: шум на ровном усиливается заметно меньше, край -
// почти как без них
fn test_sharpen_threshold_and_masking() {
	w, h := 60, 30
	src := edge_frame(w, h, 400)
	base := render_sharp(src, w, h, Sharpen{})
	plain := render_sharp(src, w, h, Sharpen{ amount: 150 })
	thr := render_sharp(src, w, h, Sharpen{ amount: 150, detail: 100 })
	msk := render_sharp(src, w, h, Sharpen{ amount: 150, masking: 100 })
	np := flat_diff(plain, base, w, h)
	assert np > 0
	assert flat_diff(thr, base, w, h) < np / 2
	assert flat_diff(msk, base, w, h) < np / 2
	row := 15 * w
	x1 := w / 2
	gain := int(plain[(row + x1) * 3]) - int(base[(row + x1) * 3])
	gain_m := int(msk[(row + x1) * 3]) - int(base[(row + x1) * 3])
	assert gain > 0
	assert f64(gain_m) > 0.6 * f64(gain)
}

fn test_gauss_blur_preserves_mean() {
	w, h := 21, 15
	mut a := []f32{len: w * h}
	a[7 * w + 10] = 100
	b := gauss_blur(a, w, h, 1.5)
	mut s := f32(0)
	for v in b {
		s += v
	}
	assert math.abs(s - 100) < 0.01
	assert b[7 * w + 10] < 100 && b[7 * w + 10] > b[7 * w + 11]
}
