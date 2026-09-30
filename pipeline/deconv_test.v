module pipeline

// Размытый край: ступенька 6000 -> 30000 по x, размытая гауссом σ = 1
// (как оптика), серая
fn blurred_edge(w int, h int, noise int) []u16 {
	mut row := []f32{len: w}
	for x in 0 .. w {
		row[x] = if x < w / 2 { 6000 } else { 30000 }
	}
	k := gauss_kernel(1.0)
	kr := k.len / 2
	mut br := []f32{len: w}
	for x in 0 .. w {
		mut acc := f32(0)
		for j in -kr .. kr + 1 {
			mut xx := x + j
			xx = if xx < 0 {
				0
			} else if xx >= w {
				w - 1
			} else {
				xx
			}
			acc += row[xx] * k[j + kr]
		}
		br[x] = acc
	}
	mut src := []u16{len: w * h * 3}
	mut seed := u32(777)
	for y in 0 .. h {
		for x in 0 .. w {
			mut v := int(br[x])
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

fn dc(src []u16, w int, h int, s Sharpen) []u16 {
	return deconvolve(unsafe { &u16(src.data) }, w, h, s, 1.0)
}

fn test_deconv_off_is_copy() {
	w, h := 40, 12
	src := blurred_edge(w, h, 200)
	assert dc(src, w, h, Sharpen{}) == src
}

fn test_deconv_restores_edge() {
	w, h := 40, 12
	src := blurred_edge(w, h, 0)
	out := dc(src, w, h, Sharpen{
		dc_amount:   100
		dc_radius:   1.0
		dc_contrast: 0
	})
	row := 6 * w
	x0 := w / 2 - 1
	x1 := w / 2
	// Перепад у края круче: не меньше чем в 1.3 раза
	g_src := int(src[(row + x1) * 3]) - int(src[(row + x0) * 3])
	g_out := int(out[(row + x1) * 3]) - int(out[(row + x0) * 3])
	assert f64(g_out) > 1.3 * f64(g_src)
	// Вдали от края почти без изменений, серое остаётся серым
	for x in [2, w - 3] {
		i := (row + x) * 3
		assert math_abs(int(out[i]) - int(src[i])) <= 60
		assert out[i] == out[i + 1] && out[i + 1] == out[i + 2]
	}
}

fn test_deconv_contrast_threshold_spares_flat() {
	// Ровное поле с шумом: порог контраста гасит усиление шума
	w, h := 48, 48
	mut src := []u16{len: w * h * 3}
	mut seed := u32(99)
	for i in 0 .. w * h {
		seed = seed * 1664525 + 1013904223
		v := u16(12000 + int(seed >> 20) % 401 - 200)
		src[3 * i] = v
		src[3 * i + 1] = v
		src[3 * i + 2] = v
	}
	free := dc(src, w, h, Sharpen{ dc_amount: 100, dc_contrast: 0 })
	gated := dc(src, w, h, Sharpen{ dc_amount: 100, dc_contrast: 40 })
	mut d_free := 0.0
	mut d_gated := 0.0
	for i in 0 .. w * h {
		d_free += math_abs(int(free[3 * i]) - int(src[3 * i]))
		d_gated += math_abs(int(gated[3 * i]) - int(src[3 * i]))
	}
	assert d_free > 0
	assert d_gated < d_free / 3
}

fn math_abs(v int) f64 {
	return if v < 0 { f64(-v) } else { f64(v) }
}
