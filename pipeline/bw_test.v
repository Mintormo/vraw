module pipeline

// Один пиксель линейного цвета (r, g, b 0..65535) через пайплайн
fn bw_px(r u16, g u16, b u16, p Params) (int, int, int) {
	src := [r, g, b]
	mut dst := []u8{len: 3}
	apply(unsafe { &u16(src.data) }, unsafe { nil }, 1, p, mut dst, 3)
	return int(dst[0]), int(dst[1]), int(dst[2])
}

fn bw_mix_at(i int, v f32) [8]f32 {
	mut m := [8]f32{}
	m[i] = v
	return m
}

// Ч/Б: каналы равны; серое - как в цвете; нулевой микшер - люма тона
fn test_bw_gray() {
	r, g, b := bw_px(30000, 12000, 5000, Params{ dither: false, bw: true })
	assert r == g && g == b
	cr, cg, cb := bw_px(9000, 9000, 9000, Params{ dither: false })
	gr, _, _ := bw_px(9000, 9000, 9000, Params{ dither: false, bw: true, bw_mix: bw_mix_at(5, 100) })
	assert cr == cg && cg == cb && gr == cr
	// серое микшер не трогает
	// Насыщенность, сочность и HSL в Ч/Б не действуют
	base, _, _ := bw_px(30000, 12000, 5000, Params{ dither: false, bw: true })
	mut hp := Params{
		dither:     false
		bw:         true
		saturation: 3
		vibrance:   80
	}
	hp.hsl_lum[0] = 100
	hp.hsl_lum[1] = 100
	x, _, _ := bw_px(30000, 12000, 5000, hp)
	assert x == base
}

// Микшер: синий -100 темнит синее, не трогает красное; красный +100
// светлит красное
fn test_bw_mix() {
	blue0, _, _ := bw_px(3000, 9000, 40000, Params{ dither: false, bw: true })
	blue1, _, _ := bw_px(3000, 9000, 40000, Params{ dither: false, bw: true, bw_mix: bw_mix_at(5, -100) })
	assert blue1 < blue0 - 15
	red0, _, _ := bw_px(30000, 3000, 2000, Params{ dither: false, bw: true })
	red1, _, _ := bw_px(30000, 3000, 2000, Params{ dither: false, bw: true, bw_mix: bw_mix_at(5, -100) })
	assert red1 == red0
	red2, _, _ := bw_px(30000, 3000, 2000, Params{ dither: false, bw: true, bw_mix: bw_mix_at(0, 100) })
	assert red2 > red0 + 15
}

// Цветокоррекция после Ч/Б - тонирование серого
fn test_bw_toning() {
	mut g := Grade{}
	g.zones[3] = GradeZone{30, 40, 0}
	r, _, b := bw_px(12000, 9000, 6000, Params{ dither: false, bw: true, grade: g })
	assert r > b + 10
}
