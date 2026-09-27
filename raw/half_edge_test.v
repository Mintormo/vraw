module raw

import os

// Half-size при нечётном размере кадра: LibRaw отдаёт неполную последнюю
// ячейку Байера (B = 0) - оранжевая полоса по краю превью. crop_half_edge
// её отрезает: размер «вниз», крайние столбец и строка того же цвета,
// что соседние.
fn test_half_edge_cropped() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut d := open(path)!
	defer {
		d.close()
	}
	mut img := d.develop(half: true)!
	defer {
		img.free()
	}
	w := img.width
	h := img.height
	assert w == d.full_w / 2
	assert h == d.full_h / 2
	p := img.data_u16()
	// Средние по каналам крайнего и соседнего столбца / строки
	mut last_col := [f64(0), 0, 0]
	mut prev_col := [f64(0), 0, 0]
	for y in 0 .. h {
		for c in 0 .. 3 {
			last_col[c] += unsafe { p[(y * w + w - 1) * 3 + c] }
			prev_col[c] += unsafe { p[(y * w + w - 2) * 3 + c] }
		}
	}
	mut last_row := [f64(0), 0, 0]
	mut prev_row := [f64(0), 0, 0]
	for x in 0 .. w {
		for c in 0 .. 3 {
			last_row[c] += unsafe { p[((h - 1) * w + x) * 3 + c] }
			prev_row[c] += unsafe { p[((h - 2) * w + x) * 3 + c] }
		}
	}
	for c in 0 .. 3 {
		assert last_col[c] > prev_col[c] * 0.8 && last_col[c] < prev_col[c] * 1.25
		assert last_row[c] > prev_row[c] * 0.8 && last_row[c] < prev_row[c] * 1.25
	}
}
