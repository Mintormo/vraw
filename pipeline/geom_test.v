module pipeline

import math

// Кадр w x h, один канал: значение = 10·y + x (узнаваемые пиксели)
fn plane(w int, h int) []u16 {
	mut p := []u16{len: w * h}
	for y in 0 .. h {
		for x in 0 .. w {
			p[y * w + x] = u16(10 * y + x)
		}
	}
	return p
}

fn geo(src []u16, w int, h int, g Geom, crop bool) ([]u16, int, int) {
	return geom_apply(unsafe { &u16(src.data) }, w, h, 1, g, crop)
}

fn test_geom_identity_and_orientation() {
	src := plane(3, 2) // 0 1 2 / 10 11 12
	a, aw, ah := geo(src, 3, 2, Geom{}, true)
	assert a == src && aw == 3 && ah == 2
	// По часовой на 90: 2 x 3, первая строка - левый столбец снизу вверх
	r, rw, rh := geo(src, 3, 2, Geom{ rot90: 1 }, true)
	assert rw == 2 && rh == 3
	assert r == [u16(10), 0, 11, 1, 12, 2]
	// Отражение по горизонтали
	f, _, _ := geo(src, 3, 2, Geom{ flip_h: true }, true)
	assert f == [u16(2), 1, 0, 12, 11, 10]
	// По вертикали
	v, _, _ := geo(src, 3, 2, Geom{ flip_v: true }, true)
	assert v == [u16(10), 11, 12, 0, 1, 2]
	// Четыре поворота - как было
	q, _, _ := geo(src, 3, 2, Geom{ rot90: 2 }, true)
	assert q == [u16(12), 11, 10, 2, 1, 0]
}

fn test_geom_crop_fractions() {
	src := plane(10, 8)
	g := Geom{
		x0: 0.2
		y0: 0.25
		x1: 0.7
		y1: 0.75
	}
	c, cw, ch := geo(src, 10, 8, g, true)
	assert cw == 5 && ch == 4
	assert c[0] == 10 * 2 + 2 && c[cw * ch - 1] == 10 * 5 + 6
	// Без обрезки (режим кадрирования) - весь кадр
	_, fw, fh := geo(src, 10, 8, g, false)
	assert fw == 10 && fh == 8
}

// Поворот на 90° против часовой у квадрата = три четверти по часовой
fn test_geom_angle_direction() {
	src := plane(4, 4)
	a, _, _ := geo(src, 4, 4, Geom{ angle: 90 }, true)
	b, _, _ := geo(src, 4, 4, Geom{ rot90: 3 }, true)
	for i in 0 .. a.len {
		assert math.abs(int(a[i]) - int(b[i])) <= 1, '${i}: ${a[i]} ${b[i]}'
	}
}

// Прямое и обратное отображения сходятся при всех ориентациях и угле
fn test_geom_point_roundtrip() {
	for k in 0 .. 4 {
		for fh in [false, true] {
			for fv in [false, true] {
				g := Geom{
					rot90:  k
					flip_h: fh
					flip_v: fv
					angle:  7.5
				}
				sx, sy := g.point_to_source(123.4, 56.7, 300, 200)
				px, py := g.source_to_point(sx, sy, 300, 200)
				assert math.abs(px - 123.4) < 1e-6 && math.abs(py - 56.7) < 1e-6
			}
		}
	}
}

fn test_geom_fits_and_max_box() {
	w0, h0 := 300, 200
	g := Geom{}
	full := g.max_box(0, 150, 100, w0, h0)
	assert math.abs(full.w() - 300) < 0.01 && math.abs(full.h() - 200) < 0.01
	// С поворотом рамка меньше, помещается, а чуть больше - нет
	r := Geom{
		angle: 10
	}
	b := r.max_box(1.5, 150, 100, w0, h0)
	assert b.w() < 290 && b.w() > 150
	assert r.fits(b, w0, h0)
	big := CropBox{b.x0 - 2, b.y0 - 2, b.x1 + 2, b.y1 + 2}
	assert !r.fits(big, w0, h0)
	// Движение к недопустимой цели останавливается на краю
	to := CropBox{b.x0 + 200, b.y0, b.x1 + 200, b.y1}
	s := r.fit_toward(b, to, w0, h0)
	assert r.fits(s, w0, h0) && s.x0 >= b.x0 && s.x0 < to.x0
}

// Линия, горизонтальная в содержимом, после поворота на θ наклонена;
// поправка горизонта возвращает угол к нулю
fn test_geom_horizon() {
	for th in [f32(-12), 3, 25] {
		g := Geom{
			angle: th
		}
		ax, ay := g.v_to_r(50, 100, 300, 200)
		bx, by := g.v_to_r(250, 100, 300, 200)
		corr := horizon_angle(ax, ay, bx, by)
		assert math.abs(th + corr) < 0.01, 'th ${th} corr ${corr}'
		// Вертикальная линия - тоже к нулю
		cx, cy := g.v_to_r(150, 20, 300, 200)
		dx, dy := g.v_to_r(150, 180, 300, 200)
		assert math.abs(th + horizon_angle(cx, cy, dx, dy)) < 0.01
	}
}

fn test_resize_rgb() {
	// Шахматка 1 px -> вдвое меньше - серое среднее
	w, h := 8, 6
	mut src := []u8{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			v := if (x + y) % 2 == 0 { u8(200) } else { u8(40) }
			for c in 0 .. 3 {
				src[(y * w + x) * 3 + c] = v
			}
		}
	}
	d := resize_rgb(src, w, h, 4, 3)
	for v in d {
		assert v == 120
	}
	// Ровное поле при любом размере - ровное
	flat := []u8{len: 7 * 5 * 3, init: 77}
	for nw in [3, 7, 13] {
		o := resize_rgb(flat, 7, 5, nw, nw)
		for v in o {
			assert v == 77
		}
	}
}

// Резкость на выход: без силы - как resize_rgb; на ступеньке перепад у
// края растёт (ореол по обе стороны), ровное поле остаётся ровным
fn test_resize_rgb_sharp() {
	w, h := 40, 20
	mut src := []u8{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			v := if x < w / 2 { u8(60) } else { u8(180) }
			for c in 0 .. 3 {
				src[(y * w + x) * 3 + c] = v
			}
		}
	}
	plain := resize_rgb(src, w, h, 20, 10)
	assert resize_rgb_sharp(src, w, h, 20, 10, 0) == plain
	sharp := resize_rgb_sharp(src, w, h, 20, 10, 1.0)
	row := 5 * 20 * 3
	// Тёмная сторона у края темнее, светлая - светлее
	assert sharp[row + 9 * 3] < plain[row + 9 * 3]
	assert sharp[row + 10 * 3] > plain[row + 10 * 3]
	// Вдали от края - без изменений
	assert sharp[row] == plain[row] && sharp[row + 19 * 3] == plain[row + 19 * 3]
	flat := []u8{len: 7 * 5 * 3, init: 77}
	for v in resize_rgb_sharp(flat, 7, 5, 4, 3, 1.3) {
		assert v == 77
	}
}
