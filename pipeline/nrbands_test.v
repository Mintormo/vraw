module pipeline

// Полосы шумодава, импульсов и ореолов дают тот же кадр, что проход
// целиком, бит в бит (запас полосы не меньше радиуса фильтра).

// Шумный кадр с контрастными краями, цветными пятнами и горячими пикселями
fn nr_scene(w int, h int) []u16 {
	mut s := u32(777)
	mut a := []u16{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			s = s * 1664525 + 1013904223
			n := int(s >> 20) - 2048
			mut r := if x < w / 2 { 8000 } else { 30000 }
			mut g := if y < h / 3 { 12000 } else { 5000 }
			mut b := if (x / 9 + y / 7) % 2 == 0 { 20000 } else { 3000 }
			if s % 997 == 0 {
				r = 65535
			}
			i := (y * w + x) * 3
			a[i] = u16(imax(0, imin(65535, r + n)))
			a[i + 1] = u16(imax(0, imin(65535, g + n / 2)))
			a[i + 2] = u16(imax(0, imin(65535, b - n)))
		}
	}
	return a
}

fn test_bands_match_whole() {
	w := 97
	h := 413
	for op in [NrOp.impulse, .denoise, .defringe] {
		src := nr_scene(w, h)
		mut whole := src.clone()
		nr_run(op, unsafe { &u16(whole.data) }, w, h, 60, 70)
		// Полосы разной высоты (меньше и больше запаса), 1 и 3 потока
		for rows in [1, 37, 128, 200] {
			for nt in [1, 3] {
				mut b := src.clone()
				nr_bands(unsafe { &u16(b.data) }, w, h, op, 60, 70, rows, nt)
				assert b == whole, '${op} rows ${rows} threads ${nt}'
			}
		}
		// Публичная функция (полосы по умолчанию) тоже
		mut p := src.clone()
		match op {
			.impulse { impulse(unsafe { &u16(p.data) }, w, h, 60) }
			.denoise { denoise(unsafe { &u16(p.data) }, w, h, 60, 70) }
			.defringe { defringe(unsafe { &u16(p.data) }, w, h, 60) }
		}
		assert p == whole
		assert whole != src
	}
}
