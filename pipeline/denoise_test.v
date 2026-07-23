module pipeline

// Инварианты шумодава и подавления ореолов на синтетике.

// Детерминированный LCG-шум, чтобы тест был воспроизводимым.
fn lcg(seed u32) u32 {
	return seed * 1664525 + 1013904223
}

fn luma_stats(buf []u16, npix int) (f64, f64) {
	mut sum := f64(0)
	mut sum2 := f64(0)
	for i in 0 .. npix {
		y := f64(54 * u32(buf[i * 3]) + 183 * u32(buf[i * 3 + 1]) + 19 * u32(buf[i * 3 + 2])) / 256.0
		sum += y
		sum2 += y * y
	}
	mean := sum / f64(npix)
	return mean, sum2 / f64(npix) - mean * mean // среднее, дисперсия
}

fn test_denoise_luma() {
	w := 64
	h := 64
	npix := w * h
	base := 20000
	mut seed := u32(12345)
	mut src := []u16{len: npix * 3}
	for i in 0 .. npix {
		seed = lcg(seed)
		noise := int(seed >> 16 & 0x7ff) - 1024 // +-1024 линейно
		val := u16(base + noise)
		src[i * 3] = val
		src[i * 3 + 1] = val
		src[i * 3 + 2] = val
	}

	// Нулевая сила - буфер не тронут
	mut same := src.clone()
	denoise(&u16(same.data), w, h, 0, 0)
	assert same == src

	mean0, var0 := luma_stats(src, npix)
	mut den := src.clone()
	denoise(&u16(den.data), w, h, 100, 0)
	mean1, var1 := luma_stats(den, npix)

	// Дисперсия шума падает в разы, среднее сохраняется
	assert var1 < var0 * 0.3, 'дисперсия: было ${var0:.0f}, стало ${var1:.0f}'
	assert (mean1 - mean0) / mean0 < 0.02 && (mean0 - mean1) / mean0 < 0.02

	// Серое остаётся серым
	for i in 0 .. npix {
		dr := int(den[i * 3]) - int(den[i * 3 + 1])
		assert dr < 64 && dr > -64
	}
}

fn test_denoise_edge_preserved() {
	// Резкий край (две половины) с шумом: после шумодава перепад
	// между половинами сохраняется, а шум внутри половин давится
	w := 64
	h := 64
	npix := w * h
	mut seed := u32(777)
	mut src := []u16{len: npix * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			base := if x < w / 2 { 8000 } else { 40000 }
			seed = lcg(seed)
			noise := int(seed >> 16 & 0x7ff) - 1024
			val := u16(base + noise)
			i := (y * w + x) * 3
			src[i] = val
			src[i + 1] = val
			src[i + 2] = val
		}
	}
	mut den := src.clone()
	denoise(&u16(den.data), w, h, 100, 0)
	// Средние по глубине половин (вдали от края)
	mut dark := f64(0)
	mut bright := f64(0)
	for y in 0 .. h {
		dark += f64(den[(y * w + 8) * 3])
		bright += f64(den[(y * w + w - 8) * 3])
	}
	dark /= f64(h)
	bright /= f64(h)
	// Перепад края сохранился хотя бы на 85%
	assert bright - dark > f64(40000 - 8000) * 0.85
}

fn test_denoise_chroma() {
	// Цветной шум на сером поле: r/b качаются в противофазе.
	// Цветовой шумодав должен вернуть поле к серому, не сдвинув яркость.
	w := 64
	h := 64
	npix := w * h
	base := 20000
	mut seed := u32(999)
	mut src := []u16{len: npix * 3}
	for i in 0 .. npix {
		seed = lcg(seed)
		noise := int(seed >> 16 & 0x7ff) - 1024
		src[i * 3] = u16(base + noise)
		src[i * 3 + 1] = u16(base)
		src[i * 3 + 2] = u16(base - noise)
	}
	mut sat0 := f64(0)
	for i in 0 .. npix {
		d := int(src[i * 3]) - int(src[i * 3 + 1])
		sat0 += f64(if d < 0 { -d } else { d })
	}
	mut den := src.clone()
	denoise(&u16(den.data), w, h, 0, 100)
	mut sat1 := f64(0)
	mut sum := f64(0)
	for i in 0 .. npix {
		d := int(den[i * 3]) - int(den[i * 3 + 1])
		sat1 += f64(if d < 0 { -d } else { d })
		sum += f64(den[i * 3 + 1])
	}
	assert sat1 < sat0 * 0.25, 'цветной шум: было ${sat0:.0f}, стало ${sat1:.0f}'
	// Зелёный канал (без шума) почти не сдвинулся
	mean_g := sum / f64(npix)
	assert mean_g > f64(base) * 0.97 && mean_g < f64(base) * 1.03
}

fn test_impulse() {
	// Шумное поле из двух половин (резкий край) с одиночными выбросами:
	// горячий пиксель (все каналы), одноканальный горячий, мёртвый.
	// После impulse выбросы убраны, поле и перепад края сохранены.
	w := 64
	h := 64
	npix := w * h
	mut seed := u32(4242)
	mut src := []u16{len: npix * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			base := if x < w / 2 { 20000 } else { 40000 }
			seed = lcg(seed)
			noise := int(seed >> 16 & 0x3ff) - 512
			val := u16(base + noise)
			i := (y * w + x) * 3
			src[i] = val
			src[i + 1] = val
			src[i + 2] = val
		}
	}
	hot := (10 * w + 10) * 3 // горячий: все каналы
	src[hot] = 65000
	src[hot + 1] = 65000
	src[hot + 2] = 65000
	hot_r := (20 * w + 40) * 3 // горячий только в красном
	src[hot_r] = 60000
	dead := (50 * w + 20) * 3 // мёртвый: все каналы в ноль
	src[dead] = 50
	src[dead + 1] = 50
	src[dead + 2] = 50

	// Нулевая сила - тождественность
	mut same := src.clone()
	impulse(&u16(same.data), w, h, 0)
	assert same == src

	mut out := src.clone()
	impulse(&u16(out.data), w, h, 60)

	// Выбросы вернулись к фону (20000 +- шум)
	assert out[hot] > 15000 && out[hot] < 25000, 'горячий: ${out[hot]}'
	assert out[hot_r] > 35000 && out[hot_r] < 45000, 'горячий r: ${out[hot_r]}'
	assert out[dead] > 15000 && out[dead] < 25000, 'мёртвый: ${out[dead]}'

	// Обычные пиксели почти не тронуты: изменённых меньше 2%
	mut changed := 0
	for i in 0 .. npix {
		d := int(out[i * 3]) - int(src[i * 3])
		if d > 256 || d < -256 {
			changed++
		}
	}
	assert changed < npix / 50, 'изменено пикселей: ${changed}'

	// Перепад края сохранился (средние вдали от края)
	mut dark := f64(0)
	mut bright := f64(0)
	for y in 0 .. h {
		dark += f64(out[(y * w + 8) * 3])
		bright += f64(out[(y * w + w - 8) * 3])
	}
	dark /= f64(h)
	bright /= f64(h)
	assert bright - dark > f64(40000 - 20000) * 0.95
}

fn test_defringe() {
	// Тёмная/светлая половины, вдоль границы - фиолетовая кайма 2 пикселя
	// (r и b подняты). Плюс однородное цветное пятно вдали от границы -
	// его defringe трогать не должен.
	w := 64
	h := 64
	npix := w * h
	mut src := []u16{len: npix * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			i := (y * w + x) * 3
			base := u16(if x < w / 2 { 3000 } else { 40000 })
			src[i] = base
			src[i + 1] = base
			src[i + 2] = base
			if x == w / 2 - 1 || x == w / 2 {
				// фиолетовая кайма на контуре
				src[i] = 25000
				src[i + 1] = 8000
				src[i + 2] = 25000
			}
		}
	}
	// Цветное пятно 14x14 в глубине тёмной половины
	for y in 8 .. 22 {
		for x in 4 .. 18 {
			i := (y * w + x) * 3
			src[i] = 12000
			src[i + 1] = 4000
			src[i + 2] = 4000
		}
	}

	// Нулевая сила - тождественность
	mut same := src.clone()
	defringe(&u16(same.data), w, h, 0)
	assert same == src

	mut out := src.clone()
	defringe(&u16(out.data), w, h, 100)

	// Кайма обесцветилась: |r-g| в её пикселях упал хотя бы вдвое
	fi := (32 * w + w / 2) * 3
	fringe0 := int(src[fi]) - int(src[fi + 1])
	fringe1 := int(out[fi]) - int(out[fi + 1])
	assert fringe1 < fringe0 / 2, 'кайма: |r-g| было ${fringe0}, стало ${fringe1}'

	// Центр цветного пятна не тронут (цветность совпадает с окрестностью)
	pi := (15 * w + 11) * 3
	d0 := int(src[pi]) - int(src[pi + 1])
	d1 := int(out[pi]) - int(out[pi + 1])
	assert d1 > d0 * 9 / 10, 'пятно: |r-g| было ${d0}, стало ${d1}'
}
