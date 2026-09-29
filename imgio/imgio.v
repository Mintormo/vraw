module imgio

// Запись проявленного 8-битного RGB-кадра в файл: JPEG, PNG, BMP (stbi из
// stdlib V), TIFF (свой: Deflate + горизонтальный предиктор), QOI (свой)
// и GIF (свой: палитра 256 цветов медианным сечением, дизеринг
// Флойда-Стейнберга, LZW). Без vgui - годится для фонового потока.
import os
import stbi

// stbi зовёт libm, а ld в Ubuntu (--as-needed) отбрасывает -lm, стоящую
// раньше объектника stbi: без флага линковка под gcc падает и V молча
// берёт запасной компилятор (см. raw/thumb_test.v)
#flag -Wl,--no-as-needed -lm

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
}

// write - записать RGB-кадр (w * h * 3 байт) в формате f
pub fn write(path string, f Format, w int, h int, rgb []u8, o WriteOpts) ! {
	if w <= 0 || h <= 0 || rgb.len < w * h * 3 {
		return error('неверный размер кадра ${w}x${h}')
	}
	match f {
		.jpeg {
			stbi.stbi_write_jpg(path, w, h, 3, rgb.data, o.quality)!
		}
		.png {
			stbi.stbi_write_png(path, w, h, 3, rgb.data, w * 3)!
		}
		.bmp {
			stbi.stbi_write_bmp(path, w, h, 3, rgb.data)!
		}
		.tiff {
			os.write_file_array(path, encode_tiff(w, h, rgb)!)!
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
