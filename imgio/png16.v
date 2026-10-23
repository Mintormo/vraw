module imgio

// PNG 16 бит на канал (RGB, тип цвета 2) - свой кодер: stb_image_write
// пишет только 8 бит. Отсчёты в PNG - big-endian; фильтр строк - Sub
// (разность с тем же байтом левого пикселя, 6 байт назад) у всех строк:
// для фотографии он почти так же хорош, как подбор фильтра на строку, и
// прост. Сжатие - zlib из stb (zlib_compress, tiff.v). EXIF и ICC
// вставляет write (with_meta) - сразу за IHDR, как и у 8-битного PNG.
import hash.crc32

// encode_png16 - PNG кадра w x h: rgb - u16 в машинном порядке байт
// (w * h * 6 байт)
fn encode_png16(w int, h int, rgb []u8) ![]u8 {
	row := w * 6
	// Сырые строки: байт фильтра (1 - Sub) и отсчёты big-endian
	mut raw := []u8{len: h * (row + 1)}
	mut be := []u8{len: row}
	for y in 0 .. h {
		p := unsafe { &u16(&rgb[y * row]) }
		for x in 0 .. w * 3 {
			v := unsafe { p[x] }
			be[2 * x] = u8(v >> 8)
			be[2 * x + 1] = u8(v)
		}
		o := y * (row + 1)
		raw[o] = 1
		for i in 0 .. row {
			raw[o + 1 + i] = if i < 6 { be[i] } else { be[i] - be[i - 6] }
		}
	}
	z := zlib_compress(raw)!
	mut out := []u8{cap: z.len + 64}
	out << [u8(0x89), `P`, `N`, `G`, `\r`, `\n`, 0x1a, `\n`]
	mut ihdr := []u8{cap: 13}
	put_u32_be(mut ihdr, u32(w))
	put_u32_be(mut ihdr, u32(h))
	ihdr << [u8(16), 2, 0, 0, 0] // 16 бит, RGB, deflate, фильтр 0, без чересстрочности
	png_chunk(mut out, 'IHDR', ihdr)
	png_chunk(mut out, 'IDAT', z)
	png_chunk(mut out, 'IEND', []u8{})
	return out
}

// png_chunk - чанк PNG: длина, тип, данные, CRC (по типу и данным)
fn png_chunk(mut out []u8, typ string, data []u8) {
	put_u32_be(mut out, u32(data.len))
	mut body := typ.bytes()
	body << data
	out << body
	put_u32_be(mut out, crc32.sum(body))
}
