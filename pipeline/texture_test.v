module pipeline

import math

// Тоновый буфер (×256) w x h, серый: v(x, y) уровней 0..255
fn tone_frame(w int, h int, v fn (int, int) f32) []u16 {
	mut t := []u16{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			u := u16(v(x, y) * 256 + 0.5)
			i := (y * w + x) * 3
			t[i] = u
			t[i + 1] = u
			t[i + 2] = u
		}
	}
	return t
}

// Размах (макс - мин) канала G в строке y, в уровнях, без краёв x < m
fn row_span(t []u16, w int, y int, m int) f32 {
	mut lo := f32(1e9)
	mut hi := f32(-1e9)
	for x in m .. w - m {
		v := f32(t[(y * w + x) * 3 + 1]) / 256
		lo = if v < lo { v } else { lo }
		hi = if v > hi { v } else { hi }
	}
	return hi - lo
}

fn sine_frame(w int, h int, period f32) []u16 {
	return tone_frame(w, h, fn [period] (x int, y int) f32 {
		return 128 + 10 * f32(math.sin(2 * math.pi * f64(x) / period))
	})
}

fn test_texture_zero_unchanged() {
	src := sine_frame(64, 8, 16)
	mut t := src.clone()
	texture_tone(mut t, 64, 8, 0, 1.0)
	assert t == src
}

// Средняя деталь (период 16 px полного кадра) - плюс усиливает, минус
// смягчает; цвет серого не сдвигается (добавка одна на каналы)
fn test_texture_mid_band() {
	w, h := 128, 8
	src := sine_frame(w, h, 16)
	base := row_span(src, w, 4, 16)
	mut up := src.clone()
	texture_tone(mut up, w, h, 100, 1.0)
	mut dn := src.clone()
	texture_tone(mut dn, w, h, -100, 1.0)
	assert row_span(up, w, 4, 16) > base * 1.2
	assert row_span(dn, w, 4, 16) < base * 0.8
	for i in 0 .. w * h {
		assert up[3 * i] == up[3 * i + 1] && up[3 * i + 1] == up[3 * i + 2]
	}
}

// Мелкий шум (шахматка ±0.5 уровня) почти не усиливается: мельче полосы
// и ниже порога
fn test_texture_noise_kept() {
	w, h := 64, 64
	src := tone_frame(w, h, fn (x int, y int) f32 {
		return if (x + y) % 2 == 0 { f32(127.5) } else { f32(128.5) }
	})
	mut t := src.clone()
	texture_tone(mut t, w, h, 100, 1.0)
	mut worst := 0
	for i in 0 .. t.len {
		d := math.abs(int(t[i]) - int(src[i]))
		worst = if d > worst { d } else { worst }
	}
	assert worst < 256 / 4 // меньше четверти уровня
}

// Сильный край (40 -> 200): добавка ограничена пределом - без ореола
fn test_texture_edge_limited() {
	w, h := 64, 8
	src := tone_frame(w, h, fn [w] (x int, y int) f32 {
		return if x < w / 2 { f32(40) } else { f32(200) }
	})
	mut t := src.clone()
	texture_tone(mut t, w, h, 100, 1.0)
	mut over := f32(0)
	for x in 0 .. w {
		v := f32(t[(4 * w + x) * 3 + 1]) / 256
		o := if x < w / 2 { 40 - v } else { v - 200 }
		over = if o > over { o } else { over }
	}
	assert over > 0 // край всё же чуть подчёркнут
	assert over <= tx_gain * tx_edge + 0.5
}

// Половинное превью (scale 0.5): та же деталь вдвое мельче в пикселях -
// то же усиление, что у полного кадра
fn test_texture_scale() {
	w, h := 256, 8
	full := sine_frame(w, h, 16)
	half := sine_frame(w / 2, h, 8)
	mut a := full.clone()
	texture_tone(mut a, w, h, 100, 1.0)
	mut b := half.clone()
	texture_tone(mut b, w / 2, h, 100, 0.5)
	ga := row_span(a, w, 4, 32) / row_span(full, w, 4, 32)
	gb := row_span(b, w / 2, 4, 16) / row_span(half, w / 2, 4, 16)
	assert math.abs(ga - gb) < 0.1 * ga
}

// apply_image: текстура действует и без резкости (свой путь через
// тоновый буфер), без текстуры и резкости - как apply
fn test_texture_in_apply_image() {
	w, h := 64, 16
	mut src := []u16{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			v := u16(12000 + 4000 * math.sin(2 * math.pi * f64(x) / 16))
			i := (y * w + x) * 3
			src[i] = v
			src[i + 1] = v
			src[i + 2] = v
		}
	}
	mut a := []u8{len: w * h * 3}
	apply_image(unsafe { &u16(src.data) }, unsafe { nil }, unsafe { nil }, w, h, Params{
		dither: false
	}, 1.0, mut a, 3)
	mut b := []u8{len: w * h * 3}
	apply_image(unsafe { &u16(src.data) }, unsafe { nil }, unsafe { nil }, w, h, Params{
		dither:  false
		texture: 100
	}, 1.0, mut b, 3)
	mut sa := 0
	mut sb := 0
	for x in 16 .. w - 16 {
		i := (8 * w + x) * 3 + 1
		sa = if a[i] > sa { a[i] } else { sa }
		sb = if b[i] > sb { b[i] } else { sb }
	}
	assert sb > sa
}
