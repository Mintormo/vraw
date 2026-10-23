module imgio

// JPEG, PNG и BMP кодирует stb_image_write (stbi из stdlib V) - но в
// память, а не в файл: в файл пишет os, который понимает UTF-8 пути и на
// Windows (fopen stb там ждёт кодировку ANSI - кириллица в пути ломалась
// бы), а EXIF и ICC вставляются без перечитывания файла.
import stbi as _
import i18n

fn C.stbi_write_jpg_to_func(func voidptr, ctx voidptr, w int, h int, comp int, data voidptr, quality int) int
fn C.stbi_write_png_to_func(func voidptr, ctx voidptr, w int, h int, comp int, data voidptr, stride int) int
fn C.stbi_write_bmp_to_func(func voidptr, ctx voidptr, w int, h int, comp int, data voidptr) int

// StbOut - куда stb складывает закодированный файл
struct StbOut {
mut:
	data []u8
}

// stb_append - приёмник stbi_write_func: дописать кусок в StbOut
fn stb_append(ctx voidptr, data voidptr, size int) {
	mut o := unsafe { &StbOut(ctx) }
	unsafe { o.data.push_many(data, size) }
}

fn stb_result(ok int, o &StbOut, what string) ![]u8 {
	if ok == 0 {
		return error(i18n.trf('не удалось закодировать {0}', what))
	}
	return o.data
}

fn stb_jpg(w int, h int, rgb []u8, quality int) ![]u8 {
	mut o := &StbOut{
		data: []u8{cap: w * h / 2}
	}
	ok := C.stbi_write_jpg_to_func(stb_append, o, w, h, 3, rgb.data, quality)
	return stb_result(ok, o, 'JPEG')
}

fn stb_png(w int, h int, rgb []u8) ![]u8 {
	mut o := &StbOut{}
	ok := C.stbi_write_png_to_func(stb_append, o, w, h, 3, rgb.data, w * 3)
	return stb_result(ok, o, 'PNG')
}

fn stb_bmp(w int, h int, rgb []u8) ![]u8 {
	mut o := &StbOut{
		data: []u8{cap: w * h * 3 + 64}
	}
	ok := C.stbi_write_bmp_to_func(stb_append, o, w, h, 3, rgb.data)
	return stb_result(ok, o, 'BMP')
}
