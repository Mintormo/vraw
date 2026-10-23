module pipeline

// Части кадра (region.v): фрагмент геометрии побитово равен вырезке из
// полного прохода geom_apply; увеличение гладкой карты.

// region_src - шумный буфер w x h с ch каналами (детерминированный)
fn region_src(w int, h int, ch int) []u16 {
	mut b := []u16{len: w * h * ch}
	mut s := u32(7)
	for i in 0 .. b.len {
		s = s * 1664525 + 1013904223
		b[i] = u16(s >> 16)
	}
	return b
}

// region_check - geom_apply_region по куску geom_source_box против вырезки
// полного прохода; несколько прямоугольников, в том числе у краёв
fn region_check(g Geom, crop bool) {
	w := 157
	h := 103
	for ch in [1, 3] {
		src := region_src(w, h, ch)
		full, ow, oh := geom_apply(unsafe { &u16(src.data) }, w, h, ch, g, crop)
		for r in [Region{0, 0, ow, oh}, Region{10, 7, 40, 30},
			Region{0, 0, 17, 9}, Region{ow - 23, oh - 11, 23, 11},
			Region{ow / 2, 0, 1, oh}] {
			sb := geom_source_box(g, w, h, crop, r)
			assert !sb.is_empty()
			assert Region{0, 0, w, h}.contains(sb)
			piece := crop_region(unsafe { &u16(src.data) }, w, ch, sb)
			got := geom_apply_region(unsafe { &u16(piece.data) }, sb, w, h, ch, g, crop,
				r)
			want := crop_region(unsafe { &u16(full.data) }, ow, ch, r)
			assert got == want, 'geom ${g} crop=${crop} ch=${ch} r=${r}'
		}
	}
}

fn test_region_identity() {
	region_check(Geom{}, true)
	region_check(Geom{}, false)
}

fn test_region_crop_only() {
	region_check(Geom{
		x0: 0.1
		y0: 0.2
		x1: 0.85
		y1: 0.9
	}, true)
}

fn test_region_rot90_flip() {
	for q in 1 .. 4 {
		region_check(Geom{
			rot90:  q
			flip_h: q == 2
			flip_v: q == 3
			x0:     0.05
			x1:     0.95
		}, true)
	}
}

fn test_region_angle() {
	g := Geom{
		rot90: 1
		angle: 7.3
		x0:    0.1
		y0:    0.1
		x1:    0.9
		y1:    0.85
	}
	region_check(g, true)
	// Режим кадрирования - весь повёрнутый кадр, углы пустые
	region_check(g, false)
	region_check(Geom{
		angle: -31
	}, true)
}

fn test_region_expand_contains() {
	r := Region{5, 5, 10, 10}.expand(8, 20, 30)
	assert r == Region{0, 0, 20, 23}
	assert r.contains(Region{5, 5, 10, 10})
	assert !Region{5, 5, 10, 10}.contains(r)
}

fn test_upsample_region_smooth() {
	// Линейный градиент 2x меньшего размера: увеличение - тот же градиент
	sw := 50
	sh := 40
	mut src := []u16{len: sw * sh}
	for y in 0 .. sh {
		for x in 0 .. sw {
			src[y * sw + x] = u16(x * 1000 + y * 100)
		}
	}
	ow := 100
	oh := 80
	r := Region{20, 10, 30, 20}
	up := upsample_region(src, sw, sh, 1, ow, oh, r)
	assert up.len == r.w * r.h
	for j in 0 .. r.h {
		for i in 0 .. r.w {
			// Центр пикселя выхода в долях -> пиксели src
			fx := (f64(r.x + i) + 0.5) * 0.5 - 0.5
			fy := (f64(r.y + j) + 0.5) * 0.5 - 0.5
			want := fx * 1000 + fy * 100
			assert f64(up[j * r.w + i]) - want < 1.0 && want - f64(up[j * r.w + i]) < 1.0
		}
	}
}

fn test_haze_region_empty_and_size() {
	assert haze_region(&HazeMap{}, 100, 80, Region{0, 0, 10, 10}).d.len == 0
	hm := HazeMap{
		w: 50
		h: 40
		d: []u16{len: 50 * 40, init: 1234}
		a: [f32(0.5), 0.6, 0.7]!
	}
	hr := haze_region(&hm, 100, 80, Region{3, 4, 10, 6})
	assert hr.w == 10 && hr.h == 6 && hr.d.len == 60
	assert hr.a == hm.a
	assert hr.d.all(it == 1234)
}
