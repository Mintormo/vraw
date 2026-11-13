module imgio

// Запись проявленного 8-битного RGB-кадра в файл: JPEG, PNG, BMP (stbi из
// stdlib V), TIFF (свой: Deflate + горизонтальный предиктор), QOI (свой)
// и GIF (свой: палитра 256 цветов медианным сечением, дизеринг
// Флойда-Стейнберга, LZW). TIFF и PNG - ещё и 16 бит на канал
// (WriteOpts.bits16; PNG 16 бит - свой кодер, png16.v). Без vgui -
// годится для фонового потока.
import os
import i18n

pub enum Format {
	jpeg
	png
	tiff
	bmp
	qoi
	gif
}

pub const formats = [Format.jpeg, .png, .tiff, .bmp, .qoi, .gif]

// name - название формата для людей
pub fn (f Format) name() string {
	return match f {
		.jpeg { 'JPEG' }
		.png { 'PNG' }
		.tiff { 'TIFF' }
		.bmp { 'BMP' }
		.qoi { 'QOI' }
		.gif { 'GIF' }
	}
}

// key - ключ формата в настройках
pub fn (f Format) key() string {
	return match f {
		.jpeg { 'jpeg' }
		.png { 'png' }
		.tiff { 'tiff' }
		.bmp { 'bmp' }
		.qoi { 'qoi' }
		.gif { 'gif' }
	}
}

// ext - расширение нового файла (без точки)
pub fn (f Format) ext() string {
	return match f {
		.jpeg { 'jpg' }
		.png { 'png' }
		.tiff { 'tif' }
		.bmp { 'bmp' }
		.qoi { 'qoi' }
		.gif { 'gif' }
	}
}

// exts - все расширения формата (для фильтра диалога и распознавания)
pub fn (f Format) exts() []string {
	return match f {
		.jpeg { ['jpg', 'jpeg'] }
		.tiff { ['tif', 'tiff'] }
		else { [f.ext()] }
	}
}

// lossy - формат с потерями: JPEG (качество) и GIF (256 цветов)
pub fn (f Format) lossy() bool {
	return f == .jpeg || f == .gif
}

pub fn format_by_key(key string) ?Format {
	for f in formats {
		if f.key() == key {
			return f
		}
	}
	return none
}

// format_by_path - формат по расширению файла (регистр не важен)
pub fn format_by_path(path string) ?Format {
	ext := os.file_ext(path).trim_left('.').to_lower()
	for f in formats {
		if ext in f.exts() {
			return f
		}
	}
	return none
}

@[params]
pub struct WriteOpts {
pub:
	quality int = 92 // JPEG, 1..100
	// метаданные EXIF (exif.v): JPEG, PNG и TIFF; nil - без них
	exif &Exif = unsafe { nil }
	// ICC-профиль (icc.v, srgb_icc): JPEG, PNG и TIFF; пусто - без него
	icc []u8
	// 16 бит на канал (только has_16bit): rgb - u16 в машинном порядке
	// байт, w * h * 6 байт
	bits16 bool
}

// has_16bit - формат пишется и в 16 бит на канал (TIFF, PNG)
pub fn (f Format) has_16bit() bool {
	return f in [Format.png, .tiff]
}

// has_exif - формат держит EXIF (JPEG, PNG, TIFF)
pub fn (f Format) has_exif() bool {
	return f in [Format.jpeg, .png, .tiff]
}

// write - записать RGB-кадр (w * h * 3 байт; o.bits16 - w * h * 6) в
// формате f
pub fn write(path string, f Format, w int, h int, rgb []u8, o WriteOpts) ! {
	bpp := if o.bits16 { 6 } else { 3 }
	if w <= 0 || h <= 0 || rgb.len < w * h * bpp {
		return error(i18n.trf('неверный размер кадра {0}x{1}', '${w}', '${h}'))
	}
	data := if o.bits16 {
		match f {
			.png { png_meta(encode_png16(w, h, rgb)!, o)! }
			.tiff { encode_tiff16(w, h, rgb, o.exif, o.icc)! }
			else { return error(i18n.trf('{0} не бывает 16-битным', f.name())) }
		}
	} else {
		match f {
			.jpeg { jpeg_meta(stb_jpg(w, h, rgb, o.quality)!, o)! }
			.png { png_meta(stb_png(w, h, rgb)!, o)! }
			.bmp { stb_bmp(w, h, rgb)! }
			.tiff { encode_tiff(w, h, rgb, o.exif, o.icc)! }
			.qoi { encode_qoi(w, h, rgb) }
			.gif {
				if w > 65535 || h > 65535 {
					return error(i18n.tr('GIF не бывает больше 65535 px по стороне'))
				}
				encode_gif(w, h, rgb)
			}
		}
	}
	write_atomic(path, data)!
}

// write_atomic - запись через временный файл рядом и переименование:
// сбой записи (кончилось место) не портит прежний файл с тем же именем
// (режим «перезаписать»), недописанный временный удаляется
fn write_atomic(path string, data []u8) ! {
	tmp := path + '.vraw-tmp'
	os.write_file_array(tmp, data) or {
		os.rm(tmp) or {}
		return err
	}
	os.mv(tmp, path) or {
		os.rm(tmp) or {}
		return err
	}
}

// png_meta - PNG с ICC-профилем (iCCP) и EXIF (eXIf) сразу за IHDR.
// Файл копируется один раз (у 16-битного PNG это ~100 МБ); без
// метаданных - как есть
fn png_meta(png []u8, o WriteOpts) ![]u8 {
	if isnil(o.exif) && o.icc.len == 0 {
		return png
	}
	// Подпись 8 байт, IHDR: длина 4 + тип 4 + 13 данных + CRC 4
	ihdr_end := 8 + 25
	if png.len < ihdr_end || png[12..16].bytestr() != 'IHDR' {
		return error(i18n.tr('не PNG'))
	}
	icc := if o.icc.len > 0 { png_icc_chunk(o.icc)! } else { []u8{} }
	exif := if isnil(o.exif) { []u8{} } else { png_exif_chunk(*o.exif) }
	mut out := []u8{cap: png.len + icc.len + exif.len}
	out << png[..ihdr_end]
	out << icc
	out << exif
	out << png[ihdr_end..]
	return out
}

// jpeg_meta - JPEG с EXIF (APP1 сразу за SOI) и ICC-профилем (APP2 за
// сегментами APP0/APP1 в начале). Файл копируется один раз; без
// метаданных - как есть
fn jpeg_meta(jpg []u8, o WriteOpts) ![]u8 {
	if isnil(o.exif) && o.icc.len == 0 {
		return jpg
	}
	if jpg.len < 2 || jpg[0] != 0xFF || jpg[1] != 0xD8 {
		return error(i18n.tr('не JPEG'))
	}
	exif := if isnil(o.exif) { []u8{} } else { jpeg_exif_seg(*o.exif)! }
	icc := if o.icc.len > 0 { jpeg_icc_seg(o.icc)! } else { []u8{} }
	mut at := 2
	for at + 4 <= jpg.len && jpg[at] == 0xFF && (jpg[at + 1] == 0xE0 || jpg[at + 1] == 0xE1) {
		at += 2 + (int(jpg[at + 2]) << 8 | int(jpg[at + 3]))
	}
	if at > jpg.len {
		return error(i18n.tr('битый JPEG'))
	}
	mut out := []u8{cap: jpg.len + exif.len + icc.len}
	out << jpg[..2]
	out << exif
	out << jpg[2..at]
	out << icc
	out << jpg[at..]
	return out
}
