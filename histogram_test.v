module main

// Гистограмма (histogram.v): колонки RAW-вида по ступеням EV, счётчики
// результата и сырья, шкалы высоты, зоны эквалайзера, подсветка клипа
// по сырью (clipping.v)

fn test_raw_col_lut() {
	lut := raw_col_lut
	assert lut[0] == 0
	assert lut[65535] == 255
	assert lut[raw_clip_lvl] == 255
	assert lut[raw_clip_lvl - 1] == 254
	// ступень ниже клипа - на raw_col_per_ev колонок левее
	one := int(lut[raw_clip_lvl / 2])
	assert one >= 254 - int(raw_col_per_ev) - 1 && one <= 254 - int(raw_col_per_ev) + 1
	// дальше raw_ev_span ступеней - в нулевую колонку
	assert lut[1] == 0
}

fn test_count_result() {
	// два пикселя RGBA, считается каждый второй - первый
	pix := [u8(255), 0, 10, 255, 1, 2, 3, 255]
	h := count_result(pix)
	assert h.ok()
	assert h.r[255] == 1 && h.g[0] == 1 && h.b[10] == 1
	assert h.y[(54 * 255 + 19 * 10) >> 8] == 1
	mut total := u32(0)
	for c in h.r {
		total += c
	}
	assert total == 1
}

fn test_count_raw() {
	// два пикселя RGB u16, считается первый: R выбит, G на ступень ниже
	lin := [u16(65535), u16(raw_clip_lvl / 2), 0, 1, 1, 1]
	h := count_raw(lin)
	assert h.r[255] == 1
	assert h.b[0] == 1
	assert h.g[raw_col_lut[raw_clip_lvl / 2]] == 1
}

fn test_hist_height() {
	assert hist_height(0, 100, 100, false) == 0
	assert hist_height(50, 100, 100, false) == 50
	assert hist_height(100, 100, 100, true) == 100
	// логарифм поднимает редкие счётчики
	assert hist_height(1, 10000, 100, true) > hist_height(1, 10000, 100, false)
	assert hist_height(1, 10000, 100, true) > 0
}

fn test_zone_of() {
	assert zone_of(0) == 0
	assert zone_of(15) == 0
	assert zone_of(64) == 1
	assert zone_of(128) == 2
	assert zone_of(191) == 3
	assert zone_of(255) == 4
}

fn test_mark_clipping_src() {
	// пиксель 1: результат не выбит, сырьё выбито - красный;
	// пиксель 2: результат 255, сырьё нет - не трогаем (пересвет кривой);
	// пиксель 3: провал результата - синий
	mut pix := [u8(100), 100, 100, 255, 255, 255, 255, 255, 0, 50, 50, 255]
	raw := [u16(65535), 100, 100, 30000, 30000, 30000, 0, 0, 0]
	mark_clipping_src(mut pix, true, true, unsafe { &u16(raw.data) })
	assert pix[0] == clip_hi_color.r && pix[2] == clip_hi_color.b
	assert pix[4] == 255 && pix[5] == 255
	assert pix[8] == clip_lo_color.r && pix[10] == clip_lo_color.b
	// без сырья - как mark_clipping
	mut a := [u8(255), 0, 0, 255]
	mark_clipping_src(mut a, true, false, unsafe { nil })
	assert a[0] == clip_hi_color.r
}
