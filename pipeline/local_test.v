module pipeline

import math

// Градиентные фильтры (local.v): вес по форме, правки только под
// фильтром, сложение фильтров, отображение через геометрию и фрагменты.

fn lt_gray(w int, h int, v u16) []u16 {
	mut src := []u16{len: w * h * 3}
	for i in 0 .. src.len {
		src[i] = v
	}
	return src
}

fn lt_render(src []u16, w int, h int, p Params) []u8 {
	mut out := []u8{len: w * h * 3}
	apply_image(unsafe { &u16(src.data) }, unsafe { nil }, unsafe { nil }, w, h, p, 1.0, mut
		out, 3)
	return out
}

// Кадр w x h без геометрии: отображение пикселя в доли высоты
fn lt_map(w int, h int) MaskMap {
	return mask_map(Geom{}, w, h, true, w, h)
}

fn test_local_none_is_identity() {
	w, h := 64, 48
	src := lt_gray(w, h, 12000)
	base := lt_render(src, w, h, Params{})
	// Фильтр без правок, выключенный, или без отображения - как без фильтров
	empty := Mask{
		kind: .linear
		ax:   0
		ay:   0
		bx:   0
		by:   1
	}
	mut off := empty
	off.exposure = 1
	off.on = false
	mut nomap := empty
	nomap.exposure = 1
	for p in [Params{
		masks: [empty]
		lmap:  lt_map(w, h)
	}, Params{
		masks: [off]
		lmap:  lt_map(w, h)
	}, Params{
		masks: [nomap]
	}] {
		assert lt_render(src, w, h, p) == base
	}
}

fn test_local_linear() {
	w, h := 40, 100
	src := lt_gray(w, h, 8000)
	base := lt_render(src, w, h, Params{})
	// Переход с 20% до 60% высоты: выше - +1 EV целиком, ниже - без изменений
	m := Mask{
		kind:     .linear
		ax:       0.5
		ay:       0.2
		bx:       0.5
		by:       0.6
		exposure: 1
	}
	out := lt_render(src, w, h, Params{
		masks: [m]
		lmap:  lt_map(w, h)
	})
	full := lt_render(src, w, h, Params{ exposure: 1 })
	px := fn [w] (o []u8, y int) int {
		return int(o[(y * w + w / 2) * 3 + 1])
	}
	// Полное действие - как глобальная экспозиция (±1 уровень дизера)
	assert math.abs(px(out, 5) - px(full, 5)) <= 1
	assert math.abs(px(out, 90) - px(base, 90)) <= 1
	assert px(out, 5) > px(base, 5) + 20
	// Переход монотонный (сравнение через 4 строки - сквозь дизер)
	for y in 20 .. 56 {
		assert px(out, y) >= px(out, y + 4) - 1
	}
	// По ширине одинаково
	assert math.abs(int(out[(30 * w + 1) * 3]) - int(out[(30 * w + w - 2) * 3])) <= 1
}

fn test_local_radial() {
	w, h := 120, 80
	src := lt_gray(w, h, 8000)
	base := lt_render(src, w, h, Params{})
	mut m := Mask{
		kind:     .radial
		ax:       0.5
		ay:       0.5
		rx:       0.3
		ry:       0.2
		feather:  50
		exposure: 1
	}
	out := lt_render(src, w, h, Params{
		masks: [m]
		lmap:  lt_map(w, h)
	})
	at := fn [w] (o []u8, x int, y int) int {
		return int(o[(y * w + x) * 3 + 1])
	}
	assert at(out, 60, 40) > at(base, 60, 40) + 20
	assert math.abs(at(out, 2, 2) - at(base, 2, 2)) <= 1
	// Полуось rx = 0.3 высоты = 24 px: за ней по горизонтали - без изменений
	assert math.abs(at(out, 60 + 26, 40) - at(base, 60 + 26, 40)) <= 1
	assert math.abs(at(out, 60, 40 + 18) - at(base, 60, 40 + 18)) <= 1
	// Растушёвка 50%: до половины радиуса - полное действие
	assert math.abs(at(out, 60 + 10, 40) - at(out, 60, 40)) <= 1
	// Поворот на 90° меняет полуоси местами
	m.angle = 90
	rot := lt_render(src, w, h, Params{
		masks: [m]
		lmap:  lt_map(w, h)
	})
	assert at(rot, 60, 40 + 20) > at(base, 60, 40 + 20) + 5
	assert math.abs(at(rot, 60 + 20, 40) - at(base, 60 + 20, 40)) <= 1
	// Снаружи: центр как был, угол светлее
	m.angle = 0
	m.invert = true
	inv := lt_render(src, w, h, Params{
		masks: [m]
		lmap:  lt_map(w, h)
	})
	assert math.abs(at(inv, 60, 40) - at(base, 60, 40)) <= 1
	assert at(inv, 2, 2) > at(base, 2, 2) + 20
}

fn test_local_stack_and_edits() {
	w, h := 16, 16
	src := lt_gray(w, h, 8000)
	mmap := lt_map(w, h)
	all := Mask{
		kind: .linear
		ax:   0
		ay:   2
		bx:   0
		by:   3 // весь кадр - до точки a: полное действие
	}
	mut one := all
	one.exposure = 1
	mut two := all
	two.exposure = 2
	a := lt_render(src, w, h, Params{
		masks: [one, one]
		lmap:  mmap
	})
	b := lt_render(src, w, h, Params{
		masks: [two]
		lmap:  mmap
	})
	for i in 0 .. a.len {
		assert math.abs(int(a[i]) - int(b[i])) <= 1
	}
	// Температура: теплее - R > B, люма почти та же; оттенок + - G ниже
	mut warm := all
	warm.temp = 100
	o := lt_render(src, w, h, Params{
		masks:  [warm]
		lmap:   mmap
		dither: false
	})
	g := lt_render(src, w, h, Params{ dither: false })
	assert o[0] > o[2] + 10
	l0 := 0.2126 * f32(g[0]) + 0.7152 * f32(g[1]) + 0.0722 * f32(g[2])
	l1 := 0.2126 * f32(o[0]) + 0.7152 * f32(o[1]) + 0.0722 * f32(o[2])
	assert math.abs(l0 - l1) < 4
	mut mag := all
	mag.tint = 100
	t := lt_render(src, w, h, Params{
		masks:  [mag]
		lmap:   mmap
		dither: false
	})
	assert t[1] < t[0] && t[1] < t[2]
	// Насыщенность -100 - ч/б; контраст + на тёмном - темнее
	col := [u16(30000), 12000, 6000]
	mut cs := all
	cs.saturation = -100
	c := lt_render(col, 1, 1, Params{
		masks:  [cs]
		lmap:   lt_map(1, 1)
		dither: false
	})
	assert c[0] == c[1] && c[1] == c[2]
	mut ct := all
	ct.contrast = 100
	dark := lt_gray(1, 1, 3000)
	d0 := lt_render(dark, 1, 1, Params{ dither: false })
	d1 := lt_render(dark, 1, 1, Params{
		masks:  [ct]
		lmap:   lt_map(1, 1)
		dither: false
	})
	assert d1[1] < d0[1]
	// Тени + поднимают тёмное сильнее светлого
	mut sh := all
	sh.shadows = 100
	light := lt_gray(1, 1, 40000)
	ds := lt_render(dark, 1, 1, Params{
		masks:  [sh]
		lmap:   lt_map(1, 1)
		dither: false
	})
	l_0 := lt_render(light, 1, 1, Params{ dither: false })
	ls := lt_render(light, 1, 1, Params{
		masks:  [sh]
		lmap:   lt_map(1, 1)
		dither: false
	})
	assert int(ds[1]) - int(d0[1]) > int(ls[1]) - int(l_0[1])
}

// Фильтр приклеен к снимку: под поворотом на 90° и кадрированием вес в
// пикселе выхода - вес той же точки кадра без геометрии
fn test_local_geometry() {
	w, h := 60, 40
	m := Mask{
		kind:    .radial
		ax:      0.3
		ay:      0.4
		rx:      0.25
		ry:      0.15
		angle:   30
		feather: 70
	}
	plain := mask_weights(m, lt_map(w, h), w, h)
	for g in [Geom{
		rot90: 1
	}, Geom{
		flip_h: true
		x0:     0.1
		y0:     0.2
		x1:     0.9
		y1:     0.8
	}] {
		ow, oh := g.out_size(w, h, true)
		got := mask_weights(m, mask_map(g, w, h, true, ow, oh), ow, oh)
		mut checked := 0
		mp := geom_affine(g, w, h, true, ow, oh)
		for j in 0 .. oh {
			for i in 0 .. ow {
				sx := mp.a * i + mp.b * j + mp.c
				sy := mp.d * i + mp.e * j + mp.f
				// Центр пикселя выхода попадает в центр пикселя S
				fx := sx - 0.5
				fy := sy - 0.5
				if math.abs(fx - math.round(fx)) > 1e-3 || math.abs(fy - math.round(fy)) > 1e-3 {
					continue
				}
				assert math.abs(int(got[j * ow + i]) - int(plain[int(math.round(fy)) * w + int(math.round(fx))])) <= 1
				checked++
			}
		}
		assert checked > ow * oh / 2
	}
	// Фрагмент: отображение со сдвигом = вырезка из целого
	mm := lt_map(w, h)
	part := mask_weights(m, mm.region(7, 5, 20), 20, 10)
	for j in 0 .. 10 {
		for i in 0 .. 20 {
			assert math.abs(int(part[j * 20 + i]) - int(plain[(j + 5) * w + i + 7])) <= 1
		}
	}
}

// Рендер полосами в потоках и фрагментами строк - тот же результат
fn test_local_threads_rows() {
	w, h := 700, 500
	npix := w * h
	mut src := []u16{len: npix * 3}
	mut s := u32(777)
	for i in 0 .. npix * 3 {
		s = s * 1664525 + 1013904223
		src[i] = u16(s >> 17)
	}
	mm := lt_map(w, h)
	p := Params{
		masks: [
			Mask{
				kind:       .radial
				ax:         0.4
				ay:         0.5
				rx:         0.4
				ry:         0.3
				exposure:   0.7
				contrast:   40
				saturation: 30
				shadows:    50
			},
			Mask{
				kind:       .linear
				ax:         0.2
				ay:         0
				bx:         0.6
				by:         0.5
				temp:       -40
				highlights: -60
			},
		]
		lmap:  mm
	}
	mut full := []u8{len: npix * 4}
	apply(unsafe { &u16(src.data) }, unsafe { nil }, npix, p, mut full, 4)
	for y in [0, 137, 499] {
		mut row := []u8{len: w * 4}
		mut pr := p
		pr.lmap = mm.region(0, y, w)
		apply(unsafe { &u16(src.data) + y * w * 3 }, unsafe { nil }, w, pr, mut row, 4)
		// Дизер - по номеру пикселя: сравнение без последнего бита
		for i in 0 .. w * 4 {
			assert math.abs(int(row[i]) - int(full[y * w * 4 + i])) <= 2
		}
	}
}

fn test_exp2f() {
	for x in [f32(-8), -3.3, -1, -0.01, 0, 0.5, 1, 2.75, 7.9] {
		want := math.pow(2, f64(x))
		assert math.abs(f64(exp2f(x)) / want - 1) < 3e-4
	}
}

// Ограничение по яркости: фильтр на весь кадр действует только на
// светлом; по цвету - только на синем, красное и серое не трогает
fn test_local_range() {
	// Строка: 0..63 - тёмно-серое, 64..127 - светло-серое, 128..191 -
	// синее, 192..255 - красное (одинаковой яркости)
	w, h := 256, 2
	mut src := []u16{len: w * h * 3}
	for j in 0 .. h {
		for i in 0 .. w {
			k := (j * w + i) * 3
			c := if i < 64 {
				[u16(2000), 2000, 2000]
			} else if i < 128 {
				[u16(30000), 30000, 30000]
			} else if i < 192 {
				[u16(3000), 6000, 30000]
			} else {
				[u16(30000), 6000, 3000]
			}
			src[k] = c[0]
			src[k + 1] = c[1]
			src[k + 2] = c[2]
		}
	}
	mm := lt_map(w, h)
	all := Mask{
		kind:     .linear
		ax:       0
		ay:       2
		bx:       0
		by:       3
		exposure: 1
	}
	base := lt_render(src, w, h, Params{ dither: false })
	at := fn [w] (o []u8, x int) int {
		return int(o[x * 3 + 1])
	}
	mut lm := all
	lm.lum_on = true
	lm.lum_lo = 50
	lm.lum_hi = 100
	lm.lum_soft = 5
	lo := lt_render(src, w, h, Params{
		masks:  [lm]
		lmap:   mm
		dither: false
	})
	assert at(lo, 30) == at(base, 30) // тёмное (тон ~0.2) - вне диапазона
	assert at(lo, 100) > at(base, 100) + 20 // светлое (тон ~0.7) - внутри
	mut cm := all
	cm.col_on = true
	cm.hue = 225 // (3000, 6000, 30000) - 233°: в полном действии (±15°)
	cm.hue_w = 30
	co := lt_render(src, w, h, Params{
		masks:  [cm]
		lmap:   mm
		dither: false
	})
	assert at(co, 160) > at(base, 160) + 10
	assert at(co, 220) == at(base, 220) // красное
	assert at(co, 100) == at(base, 100) // серое
	// Показ маски: вес по диапазону; без ограничения - вес формы
	v := mask_view(unsafe { &u16(src.data) }, unsafe { nil }, w, h, Params{
		masks: [cm]
		lmap:  mm
	}, 0)
	assert v[160] == 255 && v[220] == 0 && v[100] == 0
	g := mask_view(unsafe { &u16(src.data) }, unsafe { nil }, w, h, Params{
		masks: [all]
		lmap:  mm
	}, 0)
	assert g == mask_weights(all, mm, w, h)
	// Пипетка: синий
	pr := probe(3000, 6000, 30000, &Params{})
	assert math.abs(pr.hue - 233.33) < 0.1 && pr.sat > 0.8
	assert math.abs(probe(30000, 30000, 30000, &Params{}).tone - 100 * math.powf(30000.0 / 65535, 1 / 2.2)) < 0.1
}

// Части фильтра: вычесть, пересечь, добавить - вес по порядку частей
fn test_local_parts() {
	w, h := 60, 60
	mm := lt_map(w, h)
	// Основа - весь кадр (линейный, до точки a полное действие)
	all := Mask{
		kind:     .linear
		ax:       0
		ay:       2
		bx:       0
		by:       3
		exposure: 1
	}
	// Круг в центре, радиус 0.2 высоты, почти без растушёвки
	disk := MaskPart{
		kind:    .radial
		ax:      0.5
		ay:      0.5
		rx:      0.2
		ry:      0.2
		feather: 1
	}
	at := fn [w] (wt []u8, x int, y int) int {
		return int(wt[y * w + x])
	}
	mut sub := all.copy()
	sub.parts << MaskPart{
		...disk
		op: .subtract
	}
	ws := mask_weights(sub, mm, w, h)
	assert at(ws, 30, 30) == 0 && at(ws, 2, 2) == 255
	mut inter := all.copy()
	inter.parts << MaskPart{
		...disk
		op: .intersect
	}
	wi := mask_weights(inter, mm, w, h)
	assert at(wi, 30, 30) == 255 && at(wi, 2, 2) == 0
	// Добавить: основа - только верх (до 0.2 высоты), круг внизу
	mut add := all.copy()
	add.ay = 0.15
	add.by = 0.2
	add.parts << MaskPart{
		...disk
		ay: 0.75
		op: .add
	}
	wa := mask_weights(add, mm, w, h)
	assert at(wa, 30, 2) == 255 // верх - основа
	assert at(wa, 30, 45) == 255 // круг
	assert at(wa, 2, 45) == 0 // ни то ни другое
	// Порядок: вычесть круг, затем добавить тот же - круг снова в фильтре
	mut ord := sub.copy()
	ord.parts << MaskPart{
		...disk
		op: .add
	}
	assert at(mask_weights(ord, mm, w, h), 30, 30) == 255
	// Вырожденная часть пропускается, основа действует
	mut bad := all.copy()
	bad.parts << MaskPart{
		kind: .radial
		op:   .intersect
	}
	assert at(mask_weights(bad, mm, w, h), 30, 30) == 255
	// copy - свой массив частей
	mut c := sub.copy()
	c.parts[0].ax = 0.1
	assert sub.parts[0].ax == 0.5
}

// Кисть: вес по мазку, сила, ластик (вычитающая часть), одинаково при
// разном размере буфера, пустая кисть не действует
fn test_local_brush() {
	w, h := 300, 200
	mm := lt_map(w, h)
	stroke := Stroke{
		pts:     [f32(0.2), 0.5, 0.8, 0.5]
		radius:  0.05
		feather: 20
	}
	br := Mask{
		kind:     .brush
		strokes:  [stroke]
		exposure: 1
	}
	at := fn [w] (wt []u8, x int, y int) int {
		return int(wt[y * w + x])
	}
	wb := mask_weights(br, mm, w, h)
	assert at(wb, 150, 100) >= 254 // на пути
	assert at(wb, 150, 140) == 0 // вдали от пути (0.2 высоты)
	assert at(wb, 20, 100) == 0 // за концом
	assert at(wb, 150, 108) > 200 // внутри радиуса (10 px), до растушёвки
	// Сила 0.5 - половина
	mut half := br.copy()
	half.strokes[0].flow = 0.5
	wh := mask_weights(half, mm, w, h)
	assert math.abs(at(wh, 150, 100) - 128) <= 2
	// Ластик: весь кадр минус мазок
	all := Mask{
		kind:     .linear
		ax:       0
		ay:       2
		bx:       0
		by:       3
		exposure: 1
		parts:    [MaskPart{
			kind:    .brush
			op:      .subtract
			strokes: [stroke]
		}]
	}
	we := mask_weights(all, mm, w, h)
	assert at(we, 150, 100) <= 1 && at(we, 150, 150) == 255
	// Вдвое больший буфер: та же точка кадра - тот же вес. Пиксель (x, y)
	// и (2x, 2y) - центры сдвинуты на четверть пикселя: в глубине мазка
	// разница не больше 2 уровней, на крутом краю - до 24
	w2, h2 := 600, 400
	wb2 := mask_weights(br, lt_map(w2, h2), w2, h2)
	for pt in [[150, 100, 2], [70, 100, 2], [150, 107, 24], [150, 110, 24]] {
		a := at(wb, pt[0], pt[1])
		b := int(wb2[(2 * pt[1]) * w2 + 2 * pt[0]])
		assert math.abs(a - b) <= pt[2], '${pt}: ${a} / ${b}'
	}
	// Пустая кисть - не действует (как вырожденная форма)
	empty := Mask{
		kind:     .brush
		exposure: 1
	}
	src := lt_gray(w, h, 8000)
	assert lt_render(src, w, h, Params{
		masks: [empty]
		lmap:  mm
	}) == lt_render(src, w, h, Params{})
}

// Автомаска: мазок через границу «небо / лес» с цветом неба закрашивает
// небо и не трогает лес; обычный мазок - обе стороны; без снимка (вес
// формы для показа) - как обычный
fn test_local_brush_auto() {
	w, h := 200, 200
	mut src := []u16{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			i := (y * w + x) * 3
			// Небо голубое светлое, лес тёмно-зелёный
			c := if y < 100 { [u16(20000), 30000, 45000] } else { [u16(2500), 5000, 2000] }
			src[i] = c[0]
			src[i + 1] = c[1]
			src[i + 2] = c[2]
		}
	}
	mm := lt_map(w, h)
	pts := [f32(0.2), 0.4, 0.4, 0.5, 0.6, 0.6, 0.8, 0.5]
	mut cols := []f32{}
	for _ in 0 .. 4 {
		cols << [f32(20000), 30000, 45000] // кисть ведут по небу
	}
	auto := Stroke{
		pts:     pts
		radius:  0.15
		feather: 10
		auto:    true
		cols:    cols
	}
	mk := fn [mm] (st Stroke) Params {
		return Params{
			masks:  [Mask{
				kind:     .brush
				strokes:  [st]
				exposure: 2
			}]
			lmap:   mm
			dither: false
		}
	}
	base := lt_render(src, w, h, Params{ dither: false })
	a := lt_render(src, w, h, mk(auto))
	p := lt_render(src, w, h, mk(Stroke{
		...auto
		auto: false
	}))
	sky := (90 * w + 100) * 3 // небо у границы, под мазком
	forest := (110 * w + 100) * 3 // лес у границы, под мазком
	assert a[sky] > base[sky] + 20, 'небо: ${base[sky]} -> ${a[sky]}'
	assert a[forest] == base[forest], 'лес: ${base[forest]} -> ${a[forest]}'
	assert p[forest] > base[forest] + 10 // обычная кисть красит и лес
	// Вес формы без снимка - покрытие кистью целиком
	wt := mask_weights(mk(auto).masks[0], mm, w, h)
	assert wt[110 * w + 100] > 200
	// Цвета не по числу точек - мазок обычный
	mut bad := auto
	bad.cols = [f32(1), 2, 3]
	assert lt_render(src, w, h, mk(bad)) == p
	// Точка пути с цветом леса (центр кисти заехал на лес) не делает дыру
	// в небе рядом: небо похоже на соседние точки, чьи круги до него
	// достают (раньше - сравнение только с ближайшей точкой)
	// Путь плотный, как при рисовании (точки через четверть радиуса), по
	// небу на высоте 0.4; одна точка посередине - цвет леса
	mut dip := Stroke{
		...auto
		pts:  []f32{}
		cols: []f32{}
	}
	for k in 0 .. 40 {
		dip.pts << [f32(0.1 + 0.02 * k), 0.4]
		if k == 20 {
			dip.cols << [f32(2500), 5000, 2000]
		} else {
			dip.cols << [f32(20000), 30000, 45000]
		}
	}
	d := lt_render(src, w, h, mk(dip))
	near := (80 * w + 100) * 3 // небо у «лесной» точки (0.5, 0.4)
	assert d[near] > base[near] + 20, 'дыра в небе: ${base[near]} -> ${d[near]}'
	// Автомаска формы (не мазка): то же, что у мазка
	mut shp := Mask{
		kind:     .brush
		auto:     true
		strokes:  [Stroke{
			...auto
			auto: false
		}]
		exposure: 2
	}
	assert lt_render(src, w, h, Params{
		masks:  [shp]
		lmap:   mm
		dither: false
	}) == a
}
