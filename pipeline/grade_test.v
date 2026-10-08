module pipeline

// Серая лестница: по пикселю на каждый из n уровней линейного значения
fn gr_ramp(n int) []u16 {
	mut s := []u16{len: n * 3}
	for i in 0 .. n {
		v := u16(i * 65535 / (n - 1))
		s[3 * i] = v
		s[3 * i + 1] = v
		s[3 * i + 2] = v
	}
	return s
}

fn gr_render(src []u16, p Params) []u8 {
	n := src.len / 3
	mut dst := []u8{len: n * 3}
	apply(unsafe { &u16(src.data) }, unsafe { nil }, n, p, mut dst, 3)
	return dst
}

fn gr_zone(z int, hue f32, sat f32, lum f32) Grade {
	mut g := Grade{}
	g.zones[z] = GradeZone{hue, sat, lum}
	return g
}

// Без цветокоррекции (нулевые насыщенность и яркость при любом оттенке,
// смешении и балансе) - байт в байт как без неё
fn test_grade_off_unchanged() {
	src := gr_ramp(256)
	base := gr_render(src, Params{ dither: false })
	mut g := Grade{
		blend:   80
		balance: -40
	}
	g.zones[0].hue = 200
	g.zones[3].hue = 30
	assert !g.active()
	assert gr_render(src, Params{ dither: false, grade: g }) == base
}

// Сдвиг цвета не меняет люму: размах 1, сумма с весами BT.709 - 0
fn test_grade_chroma() {
	for deg in [f32(0), 30, 95, 180, 240, 300, 359, 720, -60] {
		r, g, b := grade_chroma(deg)
		y := 0.2126 * r + 0.7152 * g + 0.0722 * b
		assert y > -0.0001 && y < 0.0001
		mx := if r > g { if r > b { r } else { b } } else { if g > b { g } else { b } }
		mn := if r < g { if r < b { r } else { b } } else { if g < b { g } else { b } }
		assert mx - mn > 0.999 && mx - mn < 1.001
	}
	r, _, b := grade_chroma(0)
	assert r > 0.7 && b < 0 // красный
	r2, _, b2 := grade_chroma(240)
	assert b2 > 0.8 && r2 < 0 // синий
}

// Веса зон: тени в тёмном, света в светлом, средние посередине; баланс
// плюс отдаёт кадр светам
fn test_grade_weights() {
	g := Grade{}
	s0, m0, h0 := grade_weights(&g, 0.05)
	assert s0 > 0.99 && h0 < 0.01 && m0 < 0.01
	s1, m1, h1 := grade_weights(&g, 0.5)
	assert m1 > 0.9 && s1 < 0.05 && h1 < 0.05
	s2, _, h2 := grade_weights(&g, 0.95)
	assert h2 > 0.99 && s2 < 0.01
	gb := Grade{
		balance: 100
	}
	_, _, hb := grade_weights(&gb, 0.6)
	_, _, hn := grade_weights(&g, 0.6)
	assert hb > hn + 0.3
	// Смешение 0 - резкая граница, 100 - широкое перекрытие
	sharp := Grade{
		blend: 0
	}
	soft := Grade{
		blend: 100
	}
	ss, _, _ := grade_weights(&sharp, 0.45)
	sw, _, _ := grade_weights(&soft, 0.45)
	assert ss < 0.01 && sw > 0.1
}

// Тонирование теней синим: тёмные серые синеют, светлые не меняются,
// чистый чёрный остаётся чёрным; светов оранжевым - наоборот
fn test_grade_split_toning() {
	src := gr_ramp(256)
	base := gr_render(src, Params{ dither: false })
	sh := gr_render(src, Params{ dither: false, grade: gr_zone(0, 240, 60, 0) })
	hi := gr_render(src, Params{ dither: false, grade: gr_zone(2, 30, 60, 0) })
	// тёмный пиксель: тон ~45
	mut dark := 0
	for i in 0 .. 256 {
		if base[3 * i + 1] >= 45 {
			dark = i
			break
		}
	}
	assert int(sh[3 * dark + 2]) > int(sh[3 * dark]) + 15 // синее
	assert int(hi[3 * dark + 2]) - int(hi[3 * dark]) < 3 // света тёмное не трогают
	// светлый пиксель (тон ~230)
	mut light := 0
	for i in 0 .. 256 {
		if base[3 * i + 1] >= 230 {
			light = i
			break
		}
	}
	assert int(hi[3 * light]) > int(hi[3 * light + 2]) + 15 // оранжевее
	assert int(sh[3 * light + 2]) - int(sh[3 * light]) < 3
	// чёрный и белый
	assert sh[0] == 0 && sh[1] == 0 && sh[2] == 0
	last := 3 * 255
	assert hi[last] == 255 && hi[last + 1] == 255 && hi[last + 2] == 255
}

// Общий оттенок и яркость: цвет у всего кадра, люма средних почти та же;
// яркость теней поднимает тёмное
fn test_grade_global_and_lum() {
	src := gr_ramp(256)
	base := gr_render(src, Params{ dither: false })
	gl := gr_render(src, Params{ dither: false, grade: gr_zone(3, 120, 40, 0) })
	mut i := 0
	for base[3 * i + 1] < 128 {
		i++
	}
	assert int(gl[3 * i + 1]) > int(gl[3 * i]) + 10 // зеленее
	y0 := 0.2126 * f32(base[3 * i]) + 0.7152 * f32(base[3 * i + 1]) + 0.0722 * f32(base[3 * i + 2])
	y1 := 0.2126 * f32(gl[3 * i]) + 0.7152 * f32(gl[3 * i + 1]) + 0.0722 * f32(gl[3 * i + 2])
	assert y1 - y0 < 1.5 && y0 - y1 < 1.5
	lf := gr_render(src, Params{ dither: false, grade: gr_zone(0, 0, 0, 100) })
	mut d := 0
	for base[3 * d + 1] < 40 {
		d++
	}
	assert int(lf[3 * d + 1]) > int(base[3 * d + 1]) + 20
	assert lf[3 * d] == lf[3 * d + 1] && lf[3 * d + 1] == lf[3 * d + 2] // без цвета - серое
}
