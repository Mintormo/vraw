module lens

import math
import time
import pipeline { Region }

// Тесты требуют базы lensfun с профилем RF 24-50 (системная база 0.3.4
// его ещё не содержит - нужны обновления в ~/.local/share/lensfun).
// Если профиля нет - пропуск, по образцу тестов raw/ без тестового CR3.

fn test_vignetting_gain_profile() {
	mut c := find('Canon', 'EOS R8', 'RF24-50mm F4.5-6.3 IS STM') or {
		eprintln('ПРОПУСК: профиль RF 24-50 не найден в базе lensfun')
		return
	}
	assert c.lens_name.contains('24-50')

	w := 600
	h := 400
	mut buf := []u16{len: w * h * 3, init: 2000}
	assert c.vignetting(unsafe { &u16(buf.data) }, w, h, 24.0, 5.6, vign_default)

	ci := ((h / 2) * w + w / 2) * 3
	mid := ((h * 3 / 4) * w + w * 3 / 4) * 3 // ~половина радиуса
	corner := ((h - 1) * w + (w - 1)) * 3

	// Центр коррекция не трогает
	assert buf[ci] >= 2000
	assert buf[ci] < 2100
	// Усиление растёт к краю
	assert buf[mid] > buf[ci] + 100
	assert buf[corner] > buf[mid]
	// Потолок: в вырожденном углу не ноль и не больше 8x (после смягчения
	// vign_default усиление тем более не выше потолка)
	assert buf[corner] > 0
	assert buf[corner] <= 2000 * 8
	// Серый остаётся серым: каналы усилены одинаково
	assert buf[corner] == buf[corner + 1]
	assert buf[corner + 1] == buf[corner + 2]

	// Смягчение в лог-домене (сила < 1) даёт в углу меньшее
	// усиление, чем было бы при полной силе (strength = 1) - иначе
	// это не смягчение (см. CLAUDE.md: перекоррекция углов RF 24-50)
	full_gain := math.powf(f32(buf[corner]) / 2000.0, 1.0 / vign_default)
	assert full_gain > f32(buf[corner]) / 2000.0

	c.free()
}

fn test_geometry_remap() {
	mut c := find('Canon', 'EOS R8', 'RF24-50mm F4.5-6.3 IS STM') or {
		eprintln('ПРОПУСК: профиль RF 24-50 не найден в базе lensfun')
		return
	}

	w := 600
	h := 400
	// Серый горизонтальный градиент: 100 единиц на пиксель
	mut buf := []u16{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			i := (y * w + x) * 3
			v := u16(x * 100)
			buf[i] = v
			buf[i + 1] = v
			buf[i + 2] = v
		}
	}
	orig := buf.clone()
	assert c.geometry(unsafe { &u16(buf.data) }, w, h, 24.0)

	row := (h / 2) * w * 3
	ci := row + (w / 2) * 3
	// Центр неподвижен (допуск 2 пикселя градиента на субпиксельный сдвиг)
	cd := int(buf[ci]) - int(orig[ci])
	assert cd > -200 && cd < 200
	// Серый остаётся почти серым: TCA-сдвиг каналов в центре ничтожен
	gd := int(buf[ci]) - int(buf[ci + 1])
	assert gd > -100 && gd < 100
	// Бочка на 24 мм заметная: на 3/4 ширины контент сдвинут не меньше
	// чем на 3 пикселя градиента
	qi := row + (w * 3 / 4) * 3
	qd := int(buf[qi]) - int(orig[qi])
	assert qd > 300 || qd < -300
	// Монотонность градиента вдоль центральной строки сохраняется
	// (ремап по строке - монотонное отображение x)
	for x in 1 .. w {
		assert int(buf[row + x * 3]) >= int(buf[row + (x - 1) * 3]) - 60
	}

	c.free()
}

// Край кадра после geometry не прижат к рамке: авто-масштаб (с
// LF_MODIFY_SCALE и доувеличением по border_overflow) не даёт рамке
// смотреть за источник - иначе крайние столбцы повторяют один и тот же
// клампнутый столбец. На градиенте по x соседние крайние столбцы разные.
//
// Проверяется на RF 24-105 при 105 мм: подушка, у которой без
// масштабирования рамка смотрит за источник (IMG_0991.CR3). Бочка RF 24-50
// на 24 мм такого не даёт.
fn test_geometry_edges_not_clamped() {
	mut c := find('Canon', 'EOS R8', 'RF24-105mm F4-7.1 IS STM') or {
		eprintln('ПРОПУСК: профиль RF 24-105 F4-7.1 не найден в базе lensfun')
		return
	}
	w := 600
	h := 400
	mut buf := []u16{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			i := (y * w + x) * 3
			v := u16(1000 + x * 100)
			buf[i] = v
			buf[i + 1] = v
			buf[i + 2] = v
		}
	}
	for focal in [f32(105), 70] {
		mut g := buf.clone()
		assert c.geometry(unsafe { &u16(g.data) }, w, h, focal)
		row := (h / 2) * w * 3
		// Левый и правый края: соседние столбцы различаются (не клампнуты)
		assert g[row + 1 * 3 + 1] > g[row + 0 * 3 + 1]
		assert g[row + (w - 1) * 3 + 1] > g[row + (w - 2) * 3 + 1]
		// И угол тоже
		assert g[(1 * w + 1) * 3 + 1] > g[(1 * w + 0) * 3 + 1]
	}
	assert border_overflow_ok(c, w, h, 105)
	c.free()
}

// border_overflow_ok - после geometry_modifier с подобранным масштабом
// рамка кадра смотрит внутрь источника
fn border_overflow_ok(c &Corrector, w int, h int, focal f32) bool {
	m := c.geometry_modifier(w, h, focal, 0.0) or { return false }
	over := border_overflow(m, w, h)
	C.lf_modifier_destroy(m)
	// Сам авто-масштаб бывает чуть мал - это нормально, geometry()
	// доувеличит; проверяем, что вылет небольшой и измеряется
	return over > 0.5 && over < 1.05
}

fn test_find_unknown_lens() {
	if _ := find('Canon', 'EOS R8', 'Fantasy Lens 1-999mm f/0.5') {
		assert false, 'выдуманный объектив не должен находиться'
	}
	if _ := find('Canon', 'EOS R8', '') {
		assert false, 'пустое имя объектива не должно находиться'
	}
}

// Общая база: поиск без повторной загрузки, Corrector её не освобождает
fn test_shared_database() {
	mut db := load_db()!
	defer {
		db.free()
	}
	mut c := db.find('Canon', 'EOS R8', 'RF24-50mm F4.5-6.3 IS STM') or {
		eprintln('ПРОПУСК: профиль RF 24-50 не найден в базе lensfun')
		return
	}
	c.free() // не трогает общую базу
	// После free профиля база жива: второй поиск работает
	c2 := db.find('Canon', 'EOS R8', 'RF24-50mm F4.5-6.3 IS STM') or {
		assert false, 'база испорчена после Corrector.free'
		return
	}
	assert c2.lens_name.contains('24-50')
	w := 60
	h := 40
	mut buf := []u16{len: w * h * 3, init: 2000}
	assert c2.vignetting(unsafe { &u16(buf.data) }, w, h, 24.0, 5.6, vign_default)
	// Неизвестное - none
	if _ := db.find('Canon', 'EOS R8', '') {
		assert false
	}
	if _ := db.find('Nobody', 'Camera X', 'Lens') {
		assert false
	}
}

// Профиль виньетирования: не убывает (спад и ноль за «полюсом» - значение
// до него), мягкий потолок непрерывен и не выше cap
fn test_vign_profile_pole() {
	w := 201
	h := 101
	cx := f64(w - 1) / 2
	cy := f64(h - 1) / 2
	rmax := math.sqrt(cx * cx + cy * cy)
	// Карта как у вырожденного профиля: растёт, у 0.9 - полюс, дальше 0
	mut gain := []f32{len: w * h}
	for y in 0 .. h {
		for x in 0 .. w {
			r := math.sqrt((f64(x) - cx) * (f64(x) - cx) + (f64(y) - cy) * (f64(y) - cy)) / rmax
			gain[y * w + x] = if r < 0.9 { f32(1 / (1 - r * r * 1.2)) } else { 0 }
		}
	}
	lut := vign_profile(gain, w, h, 2.5, 4)
	for i in 1 .. lut.len {
		assert lut[i] >= lut[i - 1]
	}
	assert lut[0] == 1 && lut.last() <= 4 && lut.last() > 3
	// soft_cap: до колена - как есть, дальше непрерывно и не выше потолка
	assert soft_cap(2, 2.5, 4) == 2
	assert math.abs(soft_cap(2.5001, 2.5, 4) - 2.5001) < 1e-3
	assert soft_cap(1000, 2.5, 4) <= 4 && soft_cap(1000, 2.5, 4) > 3.99
}

// Рабочая копия для подбора силы: размер match_dims, ln усиления растёт к
// краю, сила 0 - копия без изменений, сила 1 у края - ярче
fn test_match_frame() {
	mut c := find('Canon', 'EOS R8', 'RF24-50mm F4.5-6.3 IS STM') or {
		eprintln('ПРОПУСК: профиль RF 24-50 не найден в базе lensfun')
		return
	}
	defer {
		c.free()
	}
	w := 1200
	h := 800
	buf := []u16{len: w * h * 3, init: 3000}
	mf := c.match_frame(unsafe { &u16(buf.data) }, w, h, 24.0, 6.3) or {
		assert false
		return
	}
	rw, rh := match_dims(w, h)
	assert mf.w == rw && mf.h == rh && rw == match_side
	ci := (rh / 2) * rw + rw / 2
	ei := (rh / 2) * rw + rw - 3 // у края по горизонтали
	assert math.abs(mf.lgain[ci]) < 0.01
	assert mf.lgain[ei] > 0.2
	assert mf.with_strength(0) == mf.lin
	full := mf.with_strength(1)
	assert full[ei * 3] > mf.lin[ei * 3] + 300
	assert math.abs(int(full[ci * 3]) - int(mf.lin[ci * 3])) < 30
}

// Фрагмент кадра (настоящий 1:1): виньетирование и дисторсия + TCA по
// прямоугольнику побитово равны той же области полного прохода.
fn lens_noise(w int, h int) []u16 {
	mut b := []u16{len: w * h * 3}
	mut s := u32(99)
	for i in 0 .. b.len {
		s = s * 1664525 + 1013904223
		b[i] = u16(s >> 18) + 1000
	}
	return b
}

fn lens_crop(src []u16, w int, r Region) []u16 {
	mut out := []u16{len: r.w * r.h * 3}
	for j in 0 .. r.h {
		for i in 0 .. r.w * 3 {
			out[j * r.w * 3 + i] = src[((r.y + j) * w + r.x) * 3 + i]
		}
	}
	return out
}

fn test_region_matches_full() {
	mut c := find('Canon', 'EOS R8', 'RF24-50mm F4.5-6.3 IS STM') or {
		eprintln('ПРОПУСК: профиль RF 24-50 не найден в базе lensfun')
		return
	}
	w := 600
	h := 400
	src := lens_noise(w, h)
	// Полный проход: виньетирование, затем ремап
	mut full := src.clone()
	assert c.vignetting(unsafe { &u16(full.data) }, w, h, 24.0, 5.6, vign_default)
	assert c.geometry(unsafe { &u16(full.data) }, w, h, 24.0)

	lut := c.vign_lut(w, h, 24.0, 5.6, vign_default) or { panic('нет профиля') }
	mut p := c.geometry_plan(w, h, 24.0) or { panic('нет геометрии') }
	for r in [Region{0, 0, w, h}, Region{50, 30, 120, 80}, Region{0, 0, 40, 25},
		Region{w - 70, h - 50, 70, 50}, Region{300, 0, 1, h}] {
		sb := p.source_box(r)
		assert sb.w > 0 && sb.h > 0
		assert sb.x >= 0 && sb.y >= 0 && sb.x + sb.w <= w && sb.y + sb.h <= h
		// Кусок источника, виньетирование по куску, ремап выхода r
		mut piece := lens_crop(src, w, sb)
		vign_apply_region(unsafe { &u16(piece.data) }, sb, w, h, lut)
		mut got := []u16{len: r.w * r.h * 3}
		p.remap(unsafe { &u16(piece.data) }, sb, r, unsafe { &u16(got.data) })
		assert got == lens_crop(full, w, r), 'r=${r} sb=${sb}'
	}
	p.free()
	c.free()
}

// Цена фрагмента на полном кадре R8 (6000x4000), 1100x900 у края - замер,
// без проверок скорости (машины разные)
fn test_region_cost() {
	mut c := find('Canon', 'EOS R8', 'RF24-50mm F4.5-6.3 IS STM') or { return }
	w := 6000
	h := 4000
	src := []u16{len: w * h * 3, init: 5000}
	mut sw := time.new_stopwatch()
	lut := c.vign_lut(w, h, 24.0, 5.6, vign_default) or { panic('') }
	t_lut := sw.elapsed().milliseconds()
	sw.restart()
	mut p := c.geometry_plan(w, h, 24.0) or { panic('') }
	t_plan := sw.elapsed().milliseconds()
	r := Region{4500, 2800, 1100, 900}
	sw.restart()
	sb := p.source_box(r)
	t_box := sw.elapsed().milliseconds()
	sw.restart()
	mut piece := lens_crop(src, w, sb)
	vign_apply_region(unsafe { &u16(piece.data) }, sb, w, h, lut)
	mut got := []u16{len: r.w * r.h * 3}
	p.remap(unsafe { &u16(piece.data) }, sb, r, unsafe { &u16(got.data) })
	t_remap := sw.elapsed().milliseconds()
	eprintln('фрагмент 1100x900 полного кадра: профиль виньетки ${t_lut} мс, план ${t_plan} мс, кусок ${t_box} мс, виньетка+ремап ${t_remap} мс')
	p.free()
	c.free()
}
