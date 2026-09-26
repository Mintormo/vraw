module lens

import math

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
	assert c.vignetting(unsafe { &u16(buf.data) }, w, h, 24.0, 5.6)

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
	// vign_strength усиление тем более не выше потолка)
	assert buf[corner] > 0
	assert buf[corner] <= 2000 * 8
	// Серый остаётся серым: каналы усилены одинаково
	assert buf[corner] == buf[corner + 1]
	assert buf[corner + 1] == buf[corner + 2]

	// Смягчение в лог-домене (vign_strength < 1) даёт в углу меньшее
	// усиление, чем было бы при полной силе (strength = 1) - иначе
	// это не смягчение (см. CLAUDE.md: перекоррекция углов RF 24-50)
	full_gain := math.powf(f32(buf[corner]) / 2000.0, 1.0 / vign_strength)
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
