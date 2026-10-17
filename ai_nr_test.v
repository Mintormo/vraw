module main

// half_of: пиксель превью - среднее своей ячейки 2x2 полного кадра;
// нечётный край полного кадра (у превью он отрезан) не участвует
fn test_half_of() {
	fw, fh := 5, 3 // нечётные: превью 2 x 1
	mut full := []u16{len: fw * fh * 3}
	for y in 0 .. fh {
		for x in 0 .. fw {
			for c in 0 .. 3 {
				full[(y * fw + x) * 3 + c] = u16(1000 * (y * fw + x) + c)
			}
		}
	}
	mut out := half_of(full, fw, fh, 2, 1)
	defer {
		drop(mut out)
	}
	assert out.len == 2 * 1 * 3
	// (0,0): пиксели 0, 1, 5, 6 -> 3000; (1,0): 2, 3, 7, 8 -> 5000
	assert out[0] == 3000 && out[1] == 3001 && out[2] == 3002
	assert out[3] == 5000 && out[5] == 5002
	// Полный кадр меньше двойного превью - нули, а не чтение за краем
	mut bad := half_of(full, fw, fh, 3, 2)
	defer {
		drop(mut bad)
	}
	assert bad.all(it == 0)
}
