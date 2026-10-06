module raw

// Декодирование встроенного JPEG камеры (libjpeg-turbo - LibRaw уже с ним
// слинкован) в RGB вне сборщика мусора (bigbuf). stbi выделял полный кадр
// 24 Мп (72 МБ) в куче сборщика на каждое открытие кадра, а сборщик
// освобождённое системе не отдаёт.
import bigbuf

#flag -ljpeg
#include "@VMODROOT/raw/jpeg_shim.h"

fn C.vraw_jpeg_decode(data &u8, len u64, w &int, h &int, out &u8) int

// Jpeg - декодированный JPEG, RGB по 3 байта, строки подряд; pix - в
// bigbuf, освобождать free() ровно один раз
pub struct Jpeg {
pub:
	width  int
	height int
pub mut:
	pix []u8
}

pub fn (mut j Jpeg) free() {
	bigbuf.free(mut j.pix)
}

// decode_jpeg - JPEG из памяти в RGB (вне сборщика)
pub fn decode_jpeg(data []u8) !Jpeg {
	if data.len < 4 {
		return error('не JPEG')
	}
	mut w := 0
	mut h := 0
	if C.vraw_jpeg_decode(data.data, u64(data.len), &w, &h, unsafe { nil }) != 0 || w <= 0
		|| h <= 0 {
		return error('не JPEG')
	}
	mut pix := bigbuf.new_u8(w * h * 3)
	if C.vraw_jpeg_decode(data.data, u64(data.len), &w, &h, pix.data) != 0 {
		bigbuf.free(mut pix)
		return error('испорченный JPEG')
	}
	return Jpeg{
		width:  w
		height: h
		pix:    pix
	}
}
