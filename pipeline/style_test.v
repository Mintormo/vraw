module pipeline

fn st_px(r u16, g u16, b u16, p Params) (int, int, int) {
	src := [r, g, b]
	mut dst := []u8{len: 3}
	apply(unsafe { &u16(src.data) }, unsafe { nil }, 1, p, mut dst, 3)
	return int(dst[0]), int(dst[1]), int(dst[2])
}

// Без стиля - байт в байт как раньше; неизвестный ключ - без стиля
fn test_style_none() {
	assert style_by_key('') == Style{}
	assert style_by_key('чужой') == Style{}
	a, b, c := st_px(20000, 9000, 4000, Params{ dither: false })
	x, y, z := st_px(20000, 9000, 4000, Params{ dither: false, style: style_by_key('') })
	assert a == x && b == y && c == z
	for k in style_keys {
		assert style_by_key(k) != Style{}
	}
	assert style_keys.len == style_names.len
}

// Стиль складывается с ползунками: контраст стиля = тот же ползунок
fn test_style_adds_to_sliders() {
	s := Style{
		contrast: 0.5
	}
	a, _, _ := st_px(3000, 3000, 3000, Params{ dither: false, style: s })
	b, _, _ := st_px(3000, 3000, 3000, Params{ dither: false, contrast: 0.5 })
	c, _, _ := st_px(3000, 3000, 3000, Params{ dither: false, contrast: -0.5, style: s })
	d, _, _ := st_px(3000, 3000, 3000, Params{ dither: false })
	assert a == b && c == d
	mut h := Style{}
	h.hsat[5] = 50
	mut q := Params{
		dither: false
	}
	q.hsl_sat[5] = 50
	r1, g1, b1 := st_px(3000, 9000, 40000, Params{ dither: false, style: h })
	r2, g2, b2 := st_px(3000, 9000, 40000, q)
	assert r1 == r2 && g1 == g2 && b1 == b2
}

// Яркий - насыщеннее и контрастнее; портрет - мягче; пейзаж - небо
// насыщеннее; серое у всех серое
fn test_styles_look() {
	n := Params{
		dither: false
	}
	vr, _, vb := st_px(20000, 9000, 4000, Params{ dither: false, style: style_by_key('vivid') })
	nr, _, nb := st_px(20000, 9000, 4000, n)
	assert vr - vb > nr - nb + 5
	dk, _, _ := st_px(1500, 1500, 1500, n)
	pk, _, _ := st_px(1500, 1500, 1500, Params{ dither: false, style: style_by_key('portrait') })
	assert pk > dk // меньше контраста - тени светлее
	lr, _, lb := st_px(4000, 12000, 40000, Params{ dither: false, style: style_by_key('landscape') })
	sr, _, sb := st_px(4000, 12000, 40000, n)
	assert lb - lr > sb - sr + 5
	for k in style_keys {
		r, g, b := st_px(9000, 9000, 9000, Params{ dither: false, style: style_by_key(k) })
		assert r == g && g == b
	}
}
