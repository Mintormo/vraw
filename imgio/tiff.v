module imgio

// TIFF: baseline RGB 8 бит, little-endian, полосы по tiff_rows_per_strip
// строк, сжатие Deflate (Adobe, тег 8) с горизонтальным предиктором (2):
// в полосе хранятся разности соседних пикселей строки - так сжатие
// фотографии заметно лучше. Deflate - zlib-компрессор из stb_image_write
// (тот же, что пишет PNG; stbi.o слинкован импортом stbi в imgio.v).

fn C.stbi_zlib_compress(data &u8, data_len int, out_len &int, quality int) &u8

const tiff_rows_per_strip = 64

fn put_u16_le(mut out []u8, v int) {
	out << u8(v)
	out << u8(v >> 8)
}

fn put_u32_le(mut out []u8, v u32) {
	out << u8(v)
	out << u8(v >> 8)
	out << u8(v >> 16)
	out << u8(v >> 24)
}

fn set_u32_le(mut out []u8, at int, v u32) {
	out[at] = u8(v)
	out[at + 1] = u8(v >> 8)
	out[at + 2] = u8(v >> 16)
	out[at + 3] = u8(v >> 24)
}

// zlib_compress - поток zlib (как требует Deflate в TIFF)
fn zlib_compress(data []u8) ![]u8 {
	mut n := 0
	p := C.stbi_zlib_compress(data.data, data.len, &n, 8)
	if isnil(p) {
		return error('сжатие Deflate не удалось')
	}
	res := unsafe { p.vbytes(n) }.clone()
	// stb выделяет через V (stbi__callback_malloc в модуле stbi) - и
	// освобождать V-шным free, C.free падает («invalid pointer»)
	unsafe { free(p) }
	return res
}

struct TiffTag {
	tag   int
	typ   int // 3 - SHORT, 4 - LONG, 5 - RATIONAL, 2 - ASCII
	count int
	value u32 // значение (влезает в 4 байта) или смещение данных
}

fn encode_tiff(w int, h int, rgb []u8) ![]u8 {
	row := w * 3
	strips := (h + tiff_rows_per_strip - 1) / tiff_rows_per_strip
	mut out := []u8{cap: rgb.len / 2}
	out << [u8(`I`), `I`, 42, 0]
	put_u32_le(mut out, 0) // смещение IFD - в конце, когда оно известно
	// Полосы: предиктор (разность с левым пикселем того же канала) и Deflate
	mut offsets := []u32{cap: strips}
	mut counts := []u32{cap: strips}
	mut buf := []u8{len: row * tiff_rows_per_strip}
	for s in 0 .. strips {
		y0 := s * tiff_rows_per_strip
		y1 := if y0 + tiff_rows_per_strip < h { y0 + tiff_rows_per_strip } else { h }
		n := (y1 - y0) * row
		for y in y0 .. y1 {
			src := y * row
			dst := (y - y0) * row
			buf[dst] = rgb[src]
			buf[dst + 1] = rgb[src + 1]
			buf[dst + 2] = rgb[src + 2]
			for x in 3 .. row {
				buf[dst + x] = rgb[src + x] - rgb[src + x - 3]
			}
		}
		z := zlib_compress(buf[..n])!
		offsets << u32(out.len)
		counts << u32(z.len)
		out << z
		if out.len % 2 == 1 {
			out << 0 // данные TIFF - по чётным смещениям
		}
	}
	// Данные тегов, не влезающие в 4 байта
	bps_at := u32(out.len)
	for _ in 0 .. 3 {
		put_u16_le(mut out, 8)
	}
	res_at := u32(out.len) // 72/1 точек на дюйм - для X и Y одно значение
	put_u32_le(mut out, 72)
	put_u32_le(mut out, 1)
	soft_at := u32(out.len)
	out << 'vraw'.bytes()
	out << 0
	if out.len % 2 == 1 {
		out << 0
	}
	mut off_val := offsets[0]
	mut cnt_val := counts[0]
	if strips > 1 {
		off_val = u32(out.len)
		for v in offsets {
			put_u32_le(mut out, v)
		}
		cnt_val = u32(out.len)
		for v in counts {
			put_u32_le(mut out, v)
		}
	}
	// IFD: теги строго по возрастанию номера
	tags := [
		TiffTag{256, 4, 1, u32(w)}, // ImageWidth
		TiffTag{257, 4, 1, u32(h)}, // ImageLength
		TiffTag{258, 3, 3, bps_at}, // BitsPerSample 8,8,8
		TiffTag{259, 3, 1, 8}, // Compression: Deflate
		TiffTag{262, 3, 1, 2}, // Photometric: RGB
		TiffTag{273, 4, strips, off_val}, // StripOffsets
		TiffTag{277, 3, 1, 3}, // SamplesPerPixel
		TiffTag{278, 4, 1, tiff_rows_per_strip}, // RowsPerStrip
		TiffTag{279, 4, strips, cnt_val}, // StripByteCounts
		TiffTag{282, 5, 1, res_at}, // XResolution
		TiffTag{283, 5, 1, res_at}, // YResolution
		TiffTag{284, 3, 1, 1}, // PlanarConfiguration: вперемешку
		TiffTag{296, 3, 1, 2}, // ResolutionUnit: дюймы
		TiffTag{305, 2, 5, soft_at}, // Software
		TiffTag{317, 3, 1, 2}, // Predictor: горизонтальный
	]
	set_u32_le(mut out, 4, u32(out.len))
	put_u16_le(mut out, tags.len)
	for t in tags {
		put_u16_le(mut out, t.tag)
		put_u16_le(mut out, t.typ)
		put_u32_le(mut out, u32(t.count))
		if t.typ == 3 && t.count == 1 {
			// SHORT прижимается к началу поля значения
			put_u16_le(mut out, int(t.value))
			put_u16_le(mut out, 0)
		} else {
			put_u32_le(mut out, t.value)
		}
	}
	put_u32_le(mut out, 0) // следующего IFD нет
	return out
}
