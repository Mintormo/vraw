module pipeline

// 16-битный выход (stride16, экспорт TIFF/PNG 16 бит): тот же тон, что у
// 8-битного, только без округления до уровня - старший байт u16
// отличается от 8 бит без дизера не больше чем на 1, на всех путях:
// прямой рендер, тоновый буфер (резкость) и уменьшение
fn ramp(w int, h int) []u16 {
	mut src := []u16{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			i := (y * w + x) * 3
			src[i] = u16(x * 65535 / (w - 1))
			src[i + 1] = u16(y * 65535 / (h - 1))
			src[i + 2] = u16((x + y) * 65535 / (w + h - 2))
		}
	}
	return src
}

fn close16(o8 []u8, o16 []u8, n int) {
	unsafe {
		q := &u16(o16.data)
		for i in 0 .. n * 3 {
			d := int(o8[i]) - int((u32(q[i]) + 128) / 257)
			assert d >= -1 && d <= 1
		}
	}
}

fn test_out16_matches_8bit() {
	w, h := 64, 48
	src := ramp(w, h)
	nomask := &u16(unsafe { nil })
	sp := unsafe { &u16(src.data) }
	for sharp in [f32(0), 80] {
		p := Params{
			dither:   false
			exposure: 0.3
			contrast: 0.2
			sharp:    Sharpen{
				amount: sharp
			}
		}
		mut o8 := []u8{len: w * h * 3}
		mut o16 := []u8{len: w * h * stride16}
		apply_image(sp, nomask, unsafe { nil }, w, h, p, 1, mut o8, 3)
		apply_image(sp, nomask, unsafe { nil }, w, h, p, 1, mut o16, stride16)
		close16(o8, o16, w * h)
		// 16 бит действительно тоньше 8: младшие байты не все кратны 257
		mut fine := 0
		unsafe {
			q := &u16(o16.data)
			for i in 0 .. w * h * 3 {
				if q[i] % 257 != 0 {
					fine++
				}
			}
		}
		assert fine > w * h
	}
	// Уменьшение с резкостью на выход: как у 8-битного
	mut o8 := []u8{len: w * h * 3}
	mut o16 := []u8{len: w * h * stride16}
	apply(sp, nomask, w * h, Params{ dither: false }, mut o8, 3)
	apply(sp, nomask, w * h, Params{ dither: false }, mut o16, stride16)
	s8 := resize_rgb_sharp(o8, w, h, 30, 22, 0.8)
	s16 := resize_rgb16_sharp(o16, w, h, 30, 22, 0.8)
	assert s16.len == 30 * 22 * 6
	close16(s8, s16, 30 * 22)
}
