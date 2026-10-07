module imgio

// Запись проявленного 8-битного RGB-кадра в файл: JPEG, PNG, BMP (stbi из
// stdlib V), TIFF (свой: Deflate + горизонтальный предиктор), QOI (свой)
// и GIF (свой: палитра 256 цветов медианным сечением, дизеринг
// Флойда-Стейнберга, LZW). Без vgui - годится для фонового потока.
import os
import stbi

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
}

// has_exif - формат держит EXIF (JPEG, PNG, TIFF)
pub fn (f Format) has_exif() bool {
	return f in [Format.jpeg, .png, .tiff]
}

// write - записать RGB-кадр (w * h * 3 байт) в формате f
pub fn write(path string, f Format, w int, h int, rgb []u8, o WriteOpts) ! {
	if w <= 0 || h <= 0 || rgb.len < w * h * 3 {
		return error('неверный размер кадра ${w}x${h}')
	}
	match f {
		.jpeg {
			stbi.stbi_write_jpg(path, w, h, 3, rgb.data, o.quality)!
			add_meta(path, o, jpeg_with_exif, jpeg_with_icc)!
		}
		.png {
			stbi.stbi_write_png(path, w, h, 3, rgb.data, w * 3)!
			add_meta(path, o, png_with_exif, png_with_icc)!
		}
		.bmp {
			stbi.stbi_write_bmp(path, w, h, 3, rgb.data)!
		}
		.tiff {
			os.write_file_array(path, encode_tiff(w, h, rgb, o.exif, o.icc)!)!
		}
		.qoi {
			os.write_file_array(path, encode_qoi(w, h, rgb))!
		}
		.gif {
			if w > 65535 || h > 65535 {
				return error('GIF не бывает больше 65535 px по стороне')
			}
			os.write_file_array(path, encode_gif(w, h, rgb))!
		}
	}
}

// add_meta - вставить EXIF и ICC-профиль в только что записанный stbi
// файл (stb пишет сразу в файл; перечитать 8 МБ JPEG - миллисекунды)
fn add_meta(path string, o WriteOpts, with_exif fn ([]u8, Exif) ![]u8, with_icc fn ([]u8, []u8) ![]u8) ! {
	if isnil(o.exif) && o.icc.len == 0 {
		return
	}
	mut data := os.read_bytes(path)!
	if !isnil(o.exif) {
		data = with_exif(data, *o.exif)!
	}
	if o.icc.len > 0 {
		data = with_icc(data, o.icc)!
	}
	os.write_file_array(path, data)!
}
