module pipeline

import math

// spt_field - кадр w x h: яркость base · 2^(grad · x / w) по всем каналам
// (каналы в отношении 1 : 1.2 : 0.8), пыль - круг (dx, dy, dr) в
// пикселях с пропусканием dust
fn spt_field(w int, h int, base f64, grad f64, dx f64, dy f64, dr f64, dust f64) []u16 {
	mut b := []u16{len: w * h * 3}
	ks := [1.0, 1.2, 0.8]
	for y in 0 .. h {
		for x in 0 .. w {
			mut v := base * math.pow(2, grad * f64(x) / f64(w))
			ex := f64(x) + 0.5 - dx
			ey := f64(y) + 0.5 - dy
			if ex * ex + ey * ey < dr * dr {
				v *= dust
			}
			for c in 0 .. 3 {
				b[(y * w + x) * 3 + c] = u16(math.min(65535.0, v * ks[c]))
			}
		}
	}
	return b
}

fn spt_px(b []u16, w int, x int, y int, c int) f64 {
	return f64(b[(y * w + x) * 3 + c])
}

fn test_spots_none() {
	w, h := 64, 48
	mut b := spt_field(w, h, 8000, 1, 30, 20, 5, 0.6)
	orig := b.clone()
	spots_apply(unsafe { &u16(b.data) }, Region{0, 0, w, h}, w, h, []Spot{})
	assert b == orig
	// Непрозрачность 0 - тоже без изменений
	spots_apply(unsafe { &u16(b.data) }, Region{0, 0, w, h}, w, h, [
		Spot{
			x:       0.5
			y:       0.5
			sx:      0.2
			sy:      0.5
			r:       0.2
			opacity: 0
		},
	])
	assert b == orig
}

// Клонирование на ровном поле: пыль заменена источником, снаружи - как было
fn test_spots_clone_flat() {
	w, h := 120, 80
	mut b := spt_field(w, h, 10000, 0, 60, 40, 8, 0.6)
	orig := b.clone()
	s := Spot{
		x:       60.0 / w
		y:       40.0 / h
		sx:      30.0 / w
		sy:      40.0 / h
		r:       f32(12.0 / h)
		feather: 30
		mode:    .clone
	}
	spots_apply(unsafe { &u16(b.data) }, Region{0, 0, w, h}, w, h, [s])
	// Центр и почти весь круг пыли - ровное поле
	for y in 33 .. 47 {
		for x in 53 .. 67 {
			assert math.abs(spt_px(b, w, x, y, 1) - 12000) < 2
		}
	}
	// Вне круга пятна - байт в байт
	assert spt_px(b, w, 80, 40, 0) == spt_px(orig, w, 80, 40, 0)
	assert spt_px(b, w, 60, 20, 2) == spt_px(orig, w, 60, 20, 2)
}

// Восстановление на градиенте: источник левее (темнее), но яркость
// пятна - по окружению; клонирование оставило бы тёмное пятно
fn test_spots_heal_gradient() {
	w, h := 200, 100
	mut b := spt_field(w, h, 6000, 2, 120, 50, 10, 0.6)
	clean := spt_field(w, h, 6000, 2, 120, 50, 10, 1)
	mut s := Spot{
		x:       120.0 / w
		y:       50.0 / h
		sx:      70.0 / w
		sy:      50.0 / h
		r:       f32(14.0 / h)
		feather: 20
	}
	mut c := b.clone()
	spots_apply(unsafe { &u16(b.data) }, Region{0, 0, w, h}, w, h, [s])
	s.mode = .clone
	spots_apply(unsafe { &u16(c.data) }, Region{0, 0, w, h}, w, h, [s])
	mut worst := 0.0
	mut worst_clone := 0.0
	for y in 42 .. 58 {
		for x in 112 .. 128 {
			for ch in 0 .. 3 {
				want := spt_px(clean, w, x, y, ch)
				worst = math.max(worst, math.abs(spt_px(b, w, x, y, ch) / want - 1))
				worst_clone = math.max(worst_clone, math.abs(spt_px(c, w, x, y, ch) / want - 1))
			}
		}
	}
	assert worst < 0.02, 'восстановление: ${worst}'
	assert worst_clone > 0.25, 'клонирование: ${worst_clone}'
}

// Кусок кадра (1:1) с запасом spots_region - то же, что весь кадр
fn test_spots_region() {
	w, h := 160, 120
	full0 := spt_field(w, h, 5000, 1.5, 100, 70, 9, 0.5)
	mut full := full0.clone()
	spots := [
		Spot{
			x:  100.0 / w
			y:  70.0 / h
			sx: 40.0 / w
			sy: 30.0 / h
			r:  f32(12.0 / h)
		},
		Spot{
			x:    30.0 / w
			y:    100.0 / h
			sx:   60.0 / w
			sy:   100.0 / h
			r:    f32(6.0 / h)
			mode: .clone
		},
	]
	spots_apply(unsafe { &u16(full.data) }, Region{0, 0, w, h}, w, h, spots)
	view := Region{90, 60, 30, 25}
	need := spots_region(spots, w, h, view)
	assert need.contains(view)
	assert need.x <= 30 && need.y <= 20 // источник первого пятна - в куске
	mut piece := crop_region(unsafe { &u16(full0.data) }, w, 3, need)
	spots_apply(unsafe { &u16(piece.data) }, need, w, h, spots)
	for y in view.y .. view.y + view.h {
		for x in view.x .. view.x + view.w {
			for c in 0 .. 3 {
				a := full[(y * w + x) * 3 + c]
				bb := piece[((y - need.y) * need.w + (x - need.x)) * 3 + c]
				assert a == bb
			}
		}
	}
}

// Поиск источника: слева - полосы, справа - ровно; пятно на ровном у
// границы - источник тоже на ровном
fn test_spot_find_source() {
	w, h := 300, 200
	mut b := []u16{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			v := if x < 150 { if (x / 4) % 2 == 0 { 3000 } else { 9000 } } else { 7000 }
			for c in 0 .. 3 {
				b[(y * w + x) * 3 + c] = u16(v)
			}
		}
	}
	sx, sy := spot_find_source(unsafe { &u16(b.data) }, w, h, f32(175.0 / w), f32(100.0 / h),
		f32(8.0 / h))
	px := f64(sx) * w
	py := f64(sy) * h
	// Круг источника целиком на ровном и в кадре
	assert px - 8 > 150, 'источник ${px}, ${py}'
	assert px + 8 < w && py - 8 > 0 && py + 8 < h
	// Не на самом пятне
	assert math.hypot(px - 175, py - 100) > 16
}

// Карта пыли: ровное поле - серое 128, пыль - темнее
fn test_dust_view() {
	w, h := 960, 640
	b := spt_field(w, h, 8000, 0, 480, 320, 4, 0.85)
	mut out := []u8{len: w * h * 4}
	dust_view(unsafe { &u16(b.data) }, w, h, 50, mut out, 4)
	assert out[(10 * w + 10) * 4] == 128
	assert out[(320 * w + 480) * 4] < 60
	assert out[(320 * w + 480) * 4 + 3] == 255
}

fn test_spot_key() {
	assert spot_key([]Spot{}) == ''
	a := [Spot{
		x: 0.1
	}]
	b := [Spot{
		x: 0.2
	}]
	assert spot_key(a) != spot_key(b)
}
