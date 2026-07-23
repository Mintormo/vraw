module pipeline

import math

// Инварианты пайплайна на синтетическом градиенте.
fn test_pipeline_basics() {
	// Серый градиент 256 пикселей: линейные значения 0..65535
	npix := 256
	mut src := []u16{len: npix * 3}
	for i in 0 .. npix {
		v := u16(i * 257)
		src[i * 3] = v
		src[i * 3 + 1] = v
		src[i * 3 + 2] = v
	}
	nomask := &u16(unsafe { nil })

	// Нейтральные параметры: монотонно, серое остаётся серым,
	// края на месте (0 -> 0, 65535 -> 255)
	mut out := []u8{len: npix * 4}
	apply(&u16(src.data), nomask, npix, Params{ dither: false }, mut out, 4)
	assert out[0] == 0
	assert out[(npix - 1) * 4] == 255
	for i in 0 .. npix {
		assert out[i * 4] == out[i * 4 + 1]
		assert out[i * 4] == out[i * 4 + 2]
		assert out[i * 4 + 3] == 255
		if i > 0 {
			assert out[i * 4] >= out[(i - 1) * 4]
		}
	}

	// Экспозиция +1 EV делает средний тон светлее
	mut brighter := []u8{len: npix * 4}
	apply(&u16(src.data), nomask, npix, Params{ exposure: 1.0, dither: false }, mut brighter, 4)
	assert brighter[128 * 4] > out[128 * 4]

	// Проявка теней поднимает тёмное, но не трогает белое
	mut lifted := []u8{len: npix * 4}
	apply(&u16(src.data), nomask, npix, Params{ shadows: 1.0, dither: false }, mut lifted, 4)
	assert lifted[16 * 4] > out[16 * 4]
	assert lifted[(npix - 1) * 4] == out[(npix - 1) * 4]

	// Контраст: тени темнее, света светлее, середина на месте (+-2)
	mut contr := []u8{len: npix * 4}
	apply(&u16(src.data), nomask, npix, Params{ contrast: 1.0, dither: false }, mut contr, 4)
	assert contr[32 * 4] < out[32 * 4]
	assert contr[224 * 4] > out[224 * 4]

	// Насыщенность 0 обесцвечивает цветной пиксель
	col := [u16(50000), 20000, 10000]
	mut cout := []u8{len: 3}
	apply(&u16(col.data), nomask, 1, Params{ saturation: 0.0, dither: false }, mut cout, 3)
	assert cout[0] == cout[1]
	assert cout[1] == cout[2]

	// Тон-эквалайзер: подъём полосы средних светлит середину, края почти не трогает
	mut eqp := Params{ dither: false }
	eqp.eq[2] = 1.0
	mut eout := []u8{len: npix * 4}
	apply(&u16(src.data), nomask, npix, eqp, mut eout, 4)
	assert eout[128 * 4] > out[128 * 4]
	assert eout[(npix - 1) * 4] == out[(npix - 1) * 4]
}

// Камерная кривая: тождественная не меняет ничего, подсветляющая
// поднимает середину и держит края; match_curve восстанавливает
// известное тональное преобразование по гистограммам.
fn test_camera_curve() {
	npix := 4096
	mut src := []u16{len: npix * 3}
	for i in 0 .. npix {
		v := u16(u32(i) * 65535 / u32(npix - 1))
		src[i * 3] = v
		src[i * 3 + 1] = v
		src[i * 3 + 2] = v
	}
	nomask := &u16(unsafe { nil })

	mut base := []u8{len: npix * 4}
	apply(&u16(src.data), nomask, npix, Params{ dither: false }, mut base, 4)

	// Тождественная кривая - результат байт в байт как без кривой
	mut ident := []f32{len: 256}
	for i in 0 .. 256 {
		ident[i] = f32(i)
	}
	mut same := []u8{len: npix * 4}
	apply(&u16(src.data), nomask, npix, Params{ curve: ident, dither: false }, mut same, 4)
	assert base == same

	// Подсветляющая кривая (t -> 255*sqrt(t/255)): середина светлее, края на месте
	mut lift := []f32{len: 256}
	for i in 0 .. 256 {
		lift[i] = 255.0 * math.sqrtf(f32(i) / 255.0)
	}
	mut up := []u8{len: npix * 4}
	apply(&u16(src.data), nomask, npix, Params{ curve: lift, dither: false }, mut up, 4)
	assert up[(npix / 4) * 4] > base[(npix / 4) * 4]
	assert up[0] == base[0]
	assert up[(npix - 1) * 4] == base[(npix - 1) * 4]

	// match_curve: эталон - те же пиксели, прогнанные через lift.
	// Сопоставление гистограмм должно вернуть кривую, близкую к lift.
	mut ref_ := []u8{len: npix * 3}
	for i in 0 .. npix {
		t := math.powf(f32(src[i * 3]) / 65535.0, 1.0 / 2.2) * 255.0
		u := u8(255.0 * math.sqrtf(t / 255.0))
		ref_[i * 3] = u
		ref_[i * 3 + 1] = u
		ref_[i * 3 + 2] = u
	}
	curve := match_curve(&u16(src.data), npix, &u8(ref_.data), npix)
	assert curve.len == 256
	for v in 1 .. 256 {
		assert curve[v] >= curve[v - 1] // монотонность
	}
	for v in [32, 64, 128, 192] {
		want := 255.0 * math.sqrtf(f32(v) / 255.0)
		diff := math.abs(curve[v] - want)
		assert diff < 8.0, 'тон ${v}: ожидалось ~${want:.0f}, получено ${curve[v]:.0f}'
	}
}

// «Тени/Света» (маска по размытой люме, как в RawTherapee):
// подъём теней светлит тёмное и сохраняет локальный контраст,
// приглушение светов темнит яркое, нейтральные значения - тождественны.
fn test_shadows_highlights() {
	// Кадр 64x64: левая половина тёмная (6% линейно) с мелкой шахматкой
	// (локальный контраст), правая - яркая (80% линейно)
	w := 64
	h := 64
	npix := w * h
	dark_a := u16(3300)
	dark_b := u16(4600)
	bright := u16(52000)
	mut src := []u16{len: npix * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			mut v := bright
			if x < w / 2 {
				v = if (x + y) % 2 == 0 { dark_a } else { dark_b }
			}
			i := (y * w + x) * 3
			src[i] = v
			src[i + 1] = v
			src[i + 2] = v
		}
	}
	mask := blur_luma(&u16(src.data), w, h)
	assert mask.len == npix
	// Маска размыта: в глубине тёмной половины она темнее, чем в яркой
	assert mask[(h / 2) * w + 8] < mask[(h / 2) * w + w - 8]

	mut base := []u8{len: npix * 4}
	apply(&u16(src.data), &u16(mask.data), npix, Params{ dither: false }, mut base, 4)

	// Нулевые sh-параметры с маской = как без маски
	mut nom := []u8{len: npix * 4}
	apply(&u16(src.data), &u16(unsafe { nil }), npix, Params{ dither: false }, mut nom, 4)
	assert base == nom

	// Подъём теней: тёмная половина светлее, яркая почти не тронута,
	// перепад шахматки (локальный контраст) не схлопывается в ноль
	mut sh := []u8{len: npix * 4}
	apply(&u16(src.data), &u16(mask.data), npix, Params{ sh_shadows: 80, dither: false }, mut sh, 4)
	di := ((h / 2) * w + 8) * 4 // глубина тёмной половины
	bi := ((h / 2) * w + w - 8) * 4 // глубина яркой половины
	assert sh[di] > base[di]
	assert int(sh[bi]) - int(base[bi]) < 3
	// Соседние клетки шахматки после подъёма всё ещё различимы
	assert sh[di] != sh[di + 4] || base[di] == base[di + 4]

	// Приглушение светов: яркая половина темнее, тёмная почти не тронута
	mut hl := []u8{len: npix * 4}
	apply(&u16(src.data), &u16(mask.data), npix, Params{ sh_highlights: 80, dither: false }, mut hl, 4)
	assert hl[bi] < base[bi]
	assert int(base[di]) - int(hl[di]) <= 3
}

// Дизеринг (TPDF ±1 LSB) финального квантования в 8 бит: без дизера
// результат детерминирован и "ступенчат", с дизером - тоже детерминирован
// (по индексу пикселя), но разбивает полосы, не смещая среднюю яркость.
fn test_dither() {
	// Гладкий линейный градиент большой длины - без дизера на нём banding
	// (соседние пиксели часто квантуются в один и тот же тон).
	npix := 4096
	mut src := []u16{len: npix * 3}
	for i in 0 .. npix {
		v := u16(u32(i) * 65535 / u32(npix - 1))
		src[i * 3] = v
		src[i * 3 + 1] = v
		src[i * 3 + 2] = v
	}
	nomask := &u16(unsafe { nil })

	// dither: false - округление без шума, детерминировано
	mut nod1 := []u8{len: npix * 4}
	mut nod2 := []u8{len: npix * 4}
	apply(&u16(src.data), nomask, npix, Params{ dither: false }, mut nod1, 4)
	apply(&u16(src.data), nomask, npix, Params{ dither: false }, mut nod2, 4)
	assert nod1 == nod2

	// dither: true - тоже детерминировано (два прогона на одном входе совпадают)
	mut d1 := []u8{len: npix * 4}
	mut d2 := []u8{len: npix * 4}
	apply(&u16(src.data), nomask, npix, Params{ dither: true }, mut d1, 4)
	apply(&u16(src.data), nomask, npix, Params{ dither: true }, mut d2, 4)
	assert d1 == d2

	// Дизер разбивает ступени: дисперсия разностей соседних пикселей выше
	mut sum_diff2_nod := f64(0)
	mut sum_diff2_d := f64(0)
	for i in 1 .. npix {
		dn := int(nod1[i * 4]) - int(nod1[(i - 1) * 4])
		dd := int(d1[i * 4]) - int(d1[(i - 1) * 4])
		sum_diff2_nod += f64(dn * dn)
		sum_diff2_d += f64(dd * dd)
	}
	assert sum_diff2_d > sum_diff2_nod

	// Но среднее по большому блоку почти не меняется (шум не смещает яркость)
	mut sum_nod := f64(0)
	mut sum_d := f64(0)
	for i in 0 .. npix {
		sum_nod += f64(nod1[i * 4])
		sum_d += f64(d1[i * 4])
	}
	mean_nod := sum_nod / f64(npix)
	mean_d := sum_d / f64(npix)
	diff := math.abs(mean_d - mean_nod)
	assert diff < 1.0, 'среднее сместилось: без дизера ${mean_nod:.3f}, с дизером ${mean_d:.3f}'
}
