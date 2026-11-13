module imgio

// EXIF готового файла: дата и время съёмки, камера, объектив, выдержка,
// диафрагма, ISO, фокусное, ориентация 1 (кадр уже повёрнут), автор и
// копирайт. Без сторонних библиотек: блок EXIF - это маленький TIFF
// (заголовок, IFD0 с тегами камеры и ссылкой на Exif IFD). В JPEG он
// кладётся сегментом APP1 сразу за SOI, в PNG - чанком eXIf перед IDAT,
// в TIFF теги пишутся прямо в IFD кадра (encode_tiff). BMP, QOI и GIF
// метаданных EXIF не держат.
import math
import i18n

// Exif - метаданные для записи; пустые строки и нули не пишутся
pub struct Exif {
pub:
	make      string
	model     string
	lens_make string
	lens      string
	date      string // дата съёмки 'ГГГГ:ММ:ДД чч:мм:сс' (DateTimeOriginal)
	modified  string // дата записи файла (DateTime), тот же формат
	exposure  f32    // выдержка, секунды
	fnumber   f32
	focal     f32 // мм
	iso       int
	artist    string
	copyright string
	software  string = 'vraw'
}

// IfdEntry - тег IFD: тип TIFF (2 ASCII, 3 SHORT, 4 LONG, 5 RATIONAL,
// 7 UNDEFINED), число значений и сами значения little-endian
struct IfdEntry {
	tag   int
	typ   int
	count int
	data  []u8
}

fn ascii_entry(tag int, s string) IfdEntry {
	mut d := s.bytes()
	d << 0
	return IfdEntry{tag, 2, d.len, d}
}

fn short_entry(tag int, v int) IfdEntry {
	mut d := []u8{}
	put_u16_le(mut d, v)
	return IfdEntry{tag, 3, 1, d}
}

fn shorts_entry(tag int, vs []int) IfdEntry {
	mut d := []u8{}
	for v in vs {
		put_u16_le(mut d, v)
	}
	return IfdEntry{tag, 3, vs.len, d}
}

fn long_entry(tag int, v u32) IfdEntry {
	mut d := []u8{}
	put_u32_le(mut d, v)
	return IfdEntry{tag, 4, 1, d}
}

fn longs_entry(tag int, vs []u32) IfdEntry {
	mut d := []u8{}
	for v in vs {
		put_u32_le(mut d, v)
	}
	return IfdEntry{tag, 4, vs.len, d}
}

fn rational_entry(tag int, num u32, den u32) IfdEntry {
	mut d := []u8{}
	put_u32_le(mut d, num)
	put_u32_le(mut d, den)
	return IfdEntry{tag, 5, 1, d}
}

fn sort_entries(entries []IfdEntry) []IfdEntry {
	mut s := entries.clone()
	s.sort(a.tag < b.tag)
	return s
}

// ifd_size - байт под IFD вместе с данными, не влезающими в 4 байта
// (каждый кусок данных - с выравниванием на чётное)
fn ifd_size(entries []IfdEntry) int {
	mut n := 2 + entries.len * 12 + 4
	for e in entries {
		if e.data.len > 4 {
			n += e.data.len + e.data.len % 2
		}
	}
	return n
}

// put_ifd дописывает IFD (теги по возрастанию номера) и за ним данные
// тегов; смещения - от начала out (начало TIFF). Возвращает место поля
// «следующий IFD» (в нём 0).
fn put_ifd(mut out []u8, entries []IfdEntry) int {
	es := sort_entries(entries)
	mut data_at := out.len + 2 + es.len * 12 + 4
	put_u16_le(mut out, es.len)
	for e in es {
		put_u16_le(mut out, e.tag)
		put_u16_le(mut out, e.typ)
		put_u32_le(mut out, u32(e.count))
		if e.data.len <= 4 {
			// Значение прижимается к началу поля
			out << e.data
			for _ in e.data.len .. 4 {
				out << 0
			}
		} else {
			put_u32_le(mut out, u32(data_at))
			data_at += e.data.len + e.data.len % 2
		}
	}
	next_at := out.len
	put_u32_le(mut out, 0)
	for e in es {
		if e.data.len > 4 {
			out << e.data
			if e.data.len % 2 == 1 {
				out << 0
			}
		}
	}
	return next_at
}

// exposure_rational - выдержка дробью RATIONAL: 1/N, если s - ровно
// (с точностью 2%) доля секунды, а короче 0.3 с - всегда; иначе
// десятыми (0.4 -> 4/10, 0.6 -> 6/10, 0.8 -> 8/10, 2.5 -> 25/10)
fn exposure_rational(s f32) (u32, u32) {
	if s <= 0 {
		return 0, 10
	}
	if s < 1 {
		inv := f32(1) / s
		n := u32(inv + 0.5)
		if s < 0.29 || math.abs(inv - f32(n)) <= 0.02 * inv {
			return 1, n
		}
	}
	return u32(s * 10 + 0.5), 10
}

// ifd0_entries - теги кадра (IFD0) без ссылки на Exif IFD
fn (e Exif) ifd0_entries() []IfdEntry {
	mut es := []IfdEntry{}
	if e.make.len > 0 {
		es << ascii_entry(271, e.make)
	}
	if e.model.len > 0 {
		es << ascii_entry(272, e.model)
	}
	es << short_entry(274, 1) // Orientation: кадр уже повёрнут
	if e.software.len > 0 {
		es << ascii_entry(305, e.software)
	}
	if e.modified.len > 0 {
		es << ascii_entry(306, e.modified)
	}
	if e.artist.len > 0 {
		es << ascii_entry(315, e.artist)
	}
	if e.copyright.len > 0 {
		es << ascii_entry(33432, e.copyright)
	}
	return es
}

// exif_entries - теги Exif IFD (съёмка)
fn (e Exif) exif_entries() []IfdEntry {
	mut es := []IfdEntry{}
	if e.exposure > 0 {
		n, d := exposure_rational(e.exposure)
		es << rational_entry(33434, n, d) // ExposureTime
	}
	if e.fnumber > 0 {
		es << rational_entry(33437, u32(e.fnumber * 10 + 0.5), 10) // FNumber
	}
	if e.iso > 0 {
		es << short_entry(34855, if e.iso > 65535 { 65535 } else { e.iso }) // ISO
	}
	es << IfdEntry{36864, 7, 4, '0232'.bytes()} // ExifVersion
	es << short_entry(40961, 1) // ColorSpace: sRGB (кадр всегда в sRGB, icc.v)
	if e.date.len > 0 {
		es << ascii_entry(36867, e.date) // DateTimeOriginal
		es << ascii_entry(36868, e.date) // DateTimeDigitized
	}
	if e.focal > 0 {
		es << rational_entry(37386, u32(e.focal * 10 + 0.5), 10) // FocalLength
	}
	if e.lens_make.len > 0 {
		es << ascii_entry(42035, e.lens_make)
	}
	if e.lens.len > 0 {
		es << ascii_entry(42036, e.lens)
	}
	return es
}

// put_exif_ifds дописывает в out IFD0 (теги кадра extra + теги камеры +
// ссылка на Exif IFD) и сразу за ним Exif IFD (теги съёмки + exif_extra);
// смещения - от начала out.
fn put_exif_ifds(mut out []u8, e Exif, extra []IfdEntry, exif_extra []IfdEntry) {
	mut ifd0 := extra.clone()
	ifd0 << e.ifd0_entries()
	exif_at := out.len + ifd_size(ifd0) + 12 // + запись ссылки на Exif IFD
	ifd0 << long_entry(34665, u32(exif_at))
	put_ifd(mut out, ifd0)
	mut ex := e.exif_entries()
	ex << exif_extra
	put_ifd(mut out, ex)
}

// exif_frame_tags - теги о самом файле, обязательные по EXIF 2.32
// (exiftool -validate) для блока EXIF в JPEG и PNG: IFD0 - разрешение
// 72 dpi, Exif IFD - FlashpixVersion и размер кадра (PixelX/YDimension);
// у JPEG ещё YCbCrPositioning и ComponentsConfiguration (Y, Cb, Cr). У
// TIFF разрешение и размер - в IFD кадра (tiff.v). Возвращает (IFD0, Exif
// IFD)
fn exif_frame_tags(w int, h int, jpeg bool) ([]IfdEntry, []IfdEntry) {
	mut ifd0 := []IfdEntry{}
	ifd0 << rational_entry(282, 72, 1) // XResolution
	ifd0 << rational_entry(283, 72, 1) // YResolution
	ifd0 << short_entry(296, 2) // ResolutionUnit: дюймы
	mut ex := []IfdEntry{}
	ex << IfdEntry{40960, 7, 4, '0100'.bytes()} // FlashpixVersion
	ex << long_entry(40962, u32(w)) // PixelXDimension
	ex << long_entry(40963, u32(h)) // PixelYDimension
	if jpeg {
		ifd0 << short_entry(531, 1) // YCbCrPositioning: по центру
		ex << IfdEntry{37121, 7, 4, [u8(1), 2, 3, 0]} // ComponentsConfiguration
	}
	return ifd0, ex
}

// exif_tiff - блок EXIF: TIFF little-endian, IFD0 (теги кадра ifd0 + теги
// камеры) и Exif IFD (теги съёмки + exif)
pub fn exif_tiff(e Exif, ifd0 []IfdEntry, exif []IfdEntry) []u8 {
	mut out := [u8(`I`), `I`, 42, 0]
	put_u32_le(mut out, 8)
	put_exif_ifds(mut out, e, ifd0, exif)
	return out
}

// jpeg_exif_seg - сегмент APP1 «Exif» целиком; встаёт сразу за SOI (так
// требует стандарт EXIF; APP0 JFIF от stb остаётся следом - читатели
// понимают оба порядка), вставляет jpeg_meta (imgio.v)
fn jpeg_exif_seg(e Exif, w int, h int) ![]u8 {
	i0, ex := exif_frame_tags(w, h, true)
	tiff := exif_tiff(e, i0, ex)
	n := 2 + 6 + tiff.len // длина сегмента - вместе с полем длины
	if n > 65535 {
		return error(i18n.tr('EXIF больше 64 КБ'))
	}
	mut out := []u8{cap: n + 2}
	out << [u8(0xFF), 0xE1, u8(n >> 8), u8(n)]
	out << 'Exif'.bytes()
	out << [u8(0), 0]
	out << tiff
	return out
}

// png_exif_chunk - чанк eXIf (PNG 1.5) целиком; встаёт за IHDR - до IDAT
// (png_meta)
fn png_exif_chunk(e Exif, w int, h int) []u8 {
	i0, ex := exif_frame_tags(w, h, false)
	tiff := exif_tiff(e, i0, ex)
	mut out := []u8{cap: tiff.len + 12}
	png_chunk(mut out, 'eXIf', tiff)
	return out
}
