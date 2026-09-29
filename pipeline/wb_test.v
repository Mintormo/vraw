module pipeline

import math

// Цвет камеры Canon R8 (IMG_0991.CR3, данные LibRaw после open)
fn r8_color() CamColor {
	return CamColor{
		shot:    [f32(2068), 1024, 1436]!
		rgb_cam: [f32(1.705885), -0.775013, 0.069128, -0.159320, 1.633560, -0.474240, 0.000133,
			-0.614919, 1.614786]!
		cam_xyz: [f32(0.8293), -0.1789, -0.1094, -0.5025, 1.2925, 0.2327, -0.1199, 0.2769, 0.6108]!
	}
}

fn apply_m(m [9]f32, r f64, g f64, b f64) (f64, f64, f64) {
	return m[0] * r + m[1] * g + m[2] * b, m[3] * r + m[4] * g + m[5] * b, m[6] * r + m[7] * g +
		m[8] * b
}

// Настройки «как снято» дают тождественную матрицу; обратная задача
// (цвет -> температура/оттенок) сходится с прямой
fn test_wb_as_shot_identity() {
	c := r8_color()
	t, tint := c.as_shot()
	// Дневной свет R8: разумная температура, оттенок около нуля
	assert t > 4000 && t < 7000, 'as shot ${t}'
	assert math.abs(tint) < 30, 'tint ${tint}'
	m := c.wb_matrix(t, tint)
	for i in 0 .. 9 {
		want := if i % 4 == 0 { f32(1) } else { f32(0) }
		assert math.abs(m[i] - want) < 0.01, 'm[${i}] = ${m[i]}'
	}
}

// Выше температура источника - картинка теплее (R/B растёт); плюс
// оттенка - пурпурнее (G падает относительно R и B)
fn test_wb_direction() {
	c := r8_color()
	r1, _, b1 := apply_m(c.wb_matrix(3000, 0), 0.5, 0.5, 0.5)
	r2, _, b2 := apply_m(c.wb_matrix(8000, 0), 0.5, 0.5, 0.5)
	assert r2 / b2 > r1 / b1
	assert r1 < b1 // лампа накаливания: серое становится синее
	assert r2 > b2 // тень: серое становится теплее
	rm, gm, bm := apply_m(c.wb_matrix(5500, 50), 0.5, 0.5, 0.5)
	rg, gg, bg := apply_m(c.wb_matrix(5500, -50), 0.5, 0.5, 0.5)
	assert gm / (rm + bm) < gg / (rg + bg)
}

// Пипетка: для цвета, снятого под другим светом, найденные настройки
// делают его серым
fn test_wb_neutral_pick() {
	c := r8_color()
	for tt in [f32(2800), 4200, 6500, 9000] {
		for ti in [f32(-40), 0, 40] {
			// Серый под источником (tt, ti) в превью «как снято» - это
			// то, что матрица (tt, ti) приводит к серому: обратная матрица
			m := c.wb_matrix(tt, ti)
			mut mm := [9]f64{}
			for i in 0 .. 9 {
				mm[i] = m[i]
			}
			inv := mat_inv(mm)
			col := mat_vec(inv, [0.4, 0.4, 0.4]!)
			t, tint := c.neutral_temp_tint(col[0], col[1], col[2])
			assert math.abs(1e6 / t - 1e6 / tt) < 2, '${tt}/${ti}: ${t}'
			assert math.abs(tint - ti) < 1.5, '${tt}/${ti}: tint ${tint}'
			r, g, b := apply_m(c.wb_matrix(t, tint), col[0], col[1], col[2])
			assert math.abs(r - g) < 0.004 && math.abs(b - g) < 0.004
		}
	}
}

// Неизвестная камера (нулевые матрицы) - запасная модель, без NaN
fn test_wb_fallback() {
	c := CamColor{}
	t, tint := c.as_shot()
	assert t > 5000 && t < 8000
	m := c.wb_matrix(3000, 20)
	for v in m {
		assert !math.is_nan(v) && !math.is_inf(v, 0)
	}
}

// Пайплайн: тождественная матрица = без ББ; защита светов - клипнутое
// белое остаётся белым
fn test_wb_in_pipeline() {
	npix := 256
	mut src := []u16{len: npix * 3}
	for i in 0 .. npix {
		src[i * 3] = u16(i * 257)
		src[i * 3 + 1] = u16((i * 181) % 65536)
		src[i * 3 + 2] = u16(65535 - i * 200)
	}
	nomask := &u16(unsafe { nil })
	mut a := []u8{len: npix * 3}
	apply(unsafe { &u16(src.data) }, nomask, npix, Params{ dither: false }, mut a, 3)
	mut id := Params{
		dither: false
		wb_on:  true
	}
	id.wb = [f32(1), 0, 0, 0, 1, 0, 0, 0, 1]!
	mut b := []u8{len: npix * 3}
	apply(unsafe { &u16(src.data) }, nomask, npix, id, mut b, 3)
	for i in 0 .. a.len {
		assert math.abs(int(a[i]) - int(b[i])) <= 1
	}
	white := [u16(65535), 65535, 65535]
	mut warm := Params{
		dither: false
		wb_on:  true
	}
	warm.wb = r8_color().wb_matrix(3000, 0)
	mut o := []u8{len: 3}
	apply(unsafe { &u16(white.data) }, nomask, 1, warm, mut o, 3)
	assert o[0] == 255 && o[1] == 255 && o[2] == 255, '${o}'
}
