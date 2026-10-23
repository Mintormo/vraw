module pipeline

import math

const ct_w = 400
const ct_h = 300

// ct_frame - серый кадр: слева фактура (синусы периода 24 px, ±0.25 EV
// вокруг средне-серого), справа - резкая ступень тёмное/светлое без
// фактуры (небо над лесом)
fn ct_frame() []u16 {
	mut src := []u16{len: ct_w * ct_h * 3}
	for y in 0 .. ct_h {
		for x in 0 .. ct_w {
			v := if x < ct_w / 2 {
				ev := 0.25 * math.sin(f64(x) * 2 * math.pi / 24) * math.sin(f64(y) * 2 * math.pi / 24)
				0.12 * math.pow(2, ev)
			} else if y < ct_h / 2 {
				0.25
			} else {
				0.03
			}
			i := (y * ct_w + x) * 3
			u := u16(v * 65535)
			src[i] = u
			src[i + 1] = u
			src[i + 2] = u
		}
	}
	return src
}

fn ct_render(src []u16, mask []u16, clarity f32) []u8 {
	mut out := []u8{len: ct_w * ct_h * 3}
	m := if mask.len > 0 { unsafe { &u16(mask.data) } } else { unsafe { &u16(nil) } }
	apply(unsafe { &u16(src.data) }, m, ct_w * ct_h, Params{
		clarity: clarity
		dither:  false
	}, mut out, 3)
	return out
}

// ct_spread - размах тона фактуры (средний модуль отклонения от среднего)
// в глубине левой половины
fn ct_spread(o []u8) f64 {
	mut s := 0.0
	mut n := 0
	for y in 60 .. 240 {
		for x in 40 .. 160 {
			s += f64(o[(y * ct_w + x) * 3])
			n++
		}
	}
	mean := s / n
	mut d := 0.0
	for y in 60 .. 240 {
		for x in 40 .. 160 {
			d += math.abs(f64(o[(y * ct_w + x) * 3]) - mean)
		}
	}
	return d / n
}

// Вес фактуры: на фактуре ~1, у резкой ступени и на ровном (небо, там
// деталь - шум) ~0
fn test_clarity_weight() {
	src := ct_frame()
	mask := luma_masks(unsafe { &u16(src.data) }, ct_w, ct_h)
	assert mask.len == ct_w * ct_h * mask_ch
	tex := mask[(150 * ct_w + 100) * mask_ch + 1]
	edge := mask[(150 * ct_w + 300) * mask_ch + 1]
	flat := mask[(30 * ct_w + 330) * mask_ch + 1]
	assert tex > 45000, 'вес на фактуре ${tex}'
	assert edge < 10000, 'вес у ступени ${edge}'
	assert flat < 3000, 'вес на ровном ${flat}'
}

// 0 - как без маски; плюс усиливает фактуру, минус ослабляет; серое
// остаётся серым
fn test_clarity_texture() {
	src := ct_frame()
	mask := luma_masks(unsafe { &u16(src.data) }, ct_w, ct_h)
	base := ct_render(src, mask, 0)
	assert base == ct_render(src, []u16{}, 0)
	up := ct_render(src, mask, 100)
	down := ct_render(src, mask, -100)
	s0 := ct_spread(base)
	s1 := ct_spread(up)
	s2 := ct_spread(down)
	assert s1 > s0 * 1.3, 'плюс: ${s0} -> ${s1}'
	assert s2 < s0 * 0.75, 'минус: ${s0} -> ${s2}'
	for i in 0 .. ct_w * ct_h {
		assert up[i * 3] == up[i * 3 + 1] && up[i * 3] == up[i * 3 + 2]
	}
}

// У резкой ступени без фактуры светлое у края не светлеет полосой
// (ореол): разница с тем же светлым вдали от края - в пределах 3 уровней
fn test_clarity_no_halo() {
	src := ct_frame()
	mask := luma_masks(unsafe { &u16(src.data) }, ct_w, ct_h)
	up := ct_render(src, mask, 100)
	far := int(up[(20 * ct_w + 330) * 3])
	mut worst := 0
	for y in 100 .. 150 {
		d := math.abs(int(up[(y * ct_w + 330) * 3]) - far)
		if d > worst {
			worst = d
		}
	}
	// Без веса фактуры та же сила дала бы заметную полосу - проверка, что
	// случай ореольный
	mut nw := mask.clone()
	for i in 0 .. ct_w * ct_h {
		nw[i * mask_ch + 1] = 65535
	}
	raw_up := ct_render(src, nw, 100)
	raw_d := math.abs(int(raw_up[(145 * ct_w + 330) * 3]) - int(raw_up[(20 * ct_w + 330) * 3]))
	assert raw_d > 6, 'без веса ступень не даёт ореола: ${raw_d}'
	assert worst <= 3, 'ореол ${worst} (без веса ${raw_d})'
}

fn ct_render_p(src []u16, mask []u16, p Params) []u8 {
	mut out := []u8{len: ct_w * ct_h * 3}
	apply(unsafe { &u16(src.data) }, unsafe { &u16(mask.data) }, ct_w * ct_h, Params{
		...p
		dither: false
	}, mut out, 3)
	return out
}

// ct_spread_rows - ct_spread по строкам y0..y1 левой половины
fn ct_spread_rows(o []u8, y0 int, y1 int) f64 {
	mut s := 0.0
	mut n := 0
	for y in y0 .. y1 {
		for x in 40 .. 160 {
			s += f64(o[(y * ct_w + x) * 3])
			n++
		}
	}
	mean := s / n
	mut d := 0.0
	for y in y0 .. y1 {
		for x in 40 .. 160 {
			d += math.abs(f64(o[(y * ct_w + x) * 3]) - mean)
		}
	}
	return d / n
}

// Чёткость фильтра - добавка к Clarity кадра: на весь кадр - как у кадра,
// только верх - меняется только верх, кадр +100 с фильтром -100 - как без
// Clarity
fn test_clarity_in_mask() {
	src := ct_frame()
	mask := luma_masks(unsafe { &u16(src.data) }, ct_w, ct_h)
	mm := mask_map(Geom{}, ct_w, ct_h, true, ct_w, ct_h)
	all := Mask{
		kind:    .linear
		ax:      0
		ay:      2
		bx:      0
		by:      3 // весь кадр - до точки a
		clarity: 100
	}
	glob := ct_render_p(src, mask, Params{ clarity: 100 })
	assert ct_render_p(src, mask, Params{
		masks: [all]
		lmap:  mm
	}) == glob
	base := ct_render_p(src, mask, Params{})
	mut top := all
	top.ay = 0.45
	top.by = 0.5
	t := ct_render_p(src, mask, Params{
		masks: [top]
		lmap:  mm
	})
	assert ct_spread_rows(t, 20, 120) > ct_spread_rows(base, 20, 120) * 1.3
	for i in (170 * ct_w) * 3 .. t.len {
		assert t[i] == base[i]
	}
	mut minus := all
	minus.clarity = -100
	assert ct_render_p(src, mask, Params{
		clarity: 100
		masks:   [minus]
		lmap:    mm
	}) == base
}
