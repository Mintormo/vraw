module imgio

// TIFF: baseline RGB 8 бит, little-endian, полосы по tiff_rows_per_strip
// строк, сжатие Deflate (Adobe, тег 8) с горизонтальным предиктором (2):
// в полосе хранятся разности соседних пикселей строки - так сжатие
// фотографии заметно лучше. Deflate - zlib-компрессор из stb_image_write
// (тот же, что пишет PNG; stbi.o слинкован импортом stbi в imgio.v).
// Прототип - свой заголовок (см. stbiw_zlib.h).

#include "@VMODROOT/imgio/stbiw_zlib.h"

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

// encode_tiff - TIFF кадра; exif не nil - теги EXIF в IFD кадра и
// Exif IFD за ним (exif.v); icc не пуст - тег InterColorProfile (icc.v)
fn encode_tiff(w int, h int, rgb []u8, exif &Exif, icc []u8) ![]u8 {
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
	// IFD кадра (данные тегов, не влезающие в 4 байта, put_ifd кладёт
	// следом); теги сортируются по номеру
	mut tags := [
		long_entry(256, u32(w)), // ImageWidth
		long_entry(257, u32(h)), // ImageLength
		shorts_entry(258, [8, 8, 8]), // BitsPerSample
		short_entry(259, 8), // Compression: Deflate
		short_entry(262, 2), // Photometric: RGB
		longs_entry(273, offsets), // StripOffsets
		short_entry(277, 3), // SamplesPerPixel
		long_entry(278, tiff_rows_per_strip), // RowsPerStrip
		longs_entry(279, counts), // StripByteCounts
		rational_entry(282, 72, 1), // XResolution
		rational_entry(283, 72, 1), // YResolution
		short_entry(284, 1), // PlanarConfiguration: вперемешку
		short_entry(296, 2), // ResolutionUnit: дюймы
		short_entry(317, 2), // Predictor: горизонтальный
	]
	if icc.len > 0 {
		tags << IfdEntry{34675, 7, icc.len, icc} // InterColorProfile
	}
	set_u32_le(mut out, 4, u32(out.len))
	if isnil(exif) {
		tags << ascii_entry(305, 'vraw') // Software
		put_ifd(mut out, tags)
	} else {
		put_exif_ifds(mut out, exif, tags) // Software - из exif
	}
	return out
}
