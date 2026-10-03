module imgio

import os
import stbi

// Блок EXIF разбирается своим мини-читателем IFD (exiftool в тестах не
// нужен; вручную файлы проверены и им)

struct ExifVal {
	typ   int
	count int
	data  []u8 // значения: до 4 байт - из поля, иначе - по смещению
}

fn ex_u16(d []u8, at int) int {
	return int(d[at]) | int(d[at + 1]) << 8
}

fn ex_u32(d []u8, at int) u32 {
	return u32(d[at]) | u32(d[at + 1]) << 8 | u32(d[at + 2]) << 16 | u32(d[at + 3]) << 24
}

fn ex_type_size(typ int) int {
	return match typ {
		3 { 2 }
		4 { 4 }
		5 { 8 }
		else { 1 }
	}
}

// ex_ifd - теги IFD по смещению at (смещения - от начала d)
fn ex_ifd(d []u8, at int) map[int]ExifVal {
	n := ex_u16(d, at)
	mut out := map[int]ExifVal{}
	mut prev := -1
	for i in 0 .. n {
		e := at + 2 + i * 12
		tag := ex_u16(d, e)
		assert tag > prev, 'теги IFD - по возрастанию'
		prev = tag
		typ := ex_u16(d, e + 2)
		count := int(ex_u32(d, e + 4))
		size := count * ex_type_size(typ)
		off := if size <= 4 { e + 8 } else { int(ex_u32(d, e + 8)) }
		if size > 4 {
			assert off % 2 == 0, 'данные - по чётным смещениям'
		}
		out[tag] = ExifVal{typ, count, d[off..off + size].clone()}
	}
	return out
}

fn ex_str(v ExifVal) string {
	assert v.typ == 2
	assert v.data.last() == 0
	return v.data[..v.data.len - 1].bytestr()
}

fn ex_rat(v ExifVal) f64 {
	assert v.typ == 5
	return f64(ex_u32(v.data, 0)) / f64(ex_u32(v.data, 4))
}

fn sample_exif() Exif {
	return Exif{
		make:      'Canon'
		model:     'Canon EOS R8'
		lens_make: 'Canon'
		lens:      'RF24-50mm F4.5-6.3 IS STM'
		date:      '2026:09:28 14:05:33'
		modified:  '2026:10:03 10:00:00'
		exposure:  1.0 / 250
		fnumber:   6.3
		focal:     24
		iso:       400
		copyright: '(c) Igor'
	}
}

// check_tiff_exif - IFD0 и Exif IFD блока d (начало TIFF - d[0])
fn check_tiff_exif(d []u8) {
	assert d[0] == `I` && d[1] == `I` && ex_u16(d, 2) == 42
	ifd0 := ex_ifd(d, int(ex_u32(d, 4)))
	assert ex_str(ifd0[271]) == 'Canon'
	assert ex_str(ifd0[272]) == 'Canon EOS R8'
	assert ex_u16(ifd0[274].data, 0) == 1 // ориентация: кадр уже повёрнут
	assert ex_str(ifd0[305]) == 'vraw'
	assert ex_str(ifd0[306]) == '2026:10:03 10:00:00'
	assert ex_str(ifd0[33432]) == '(c) Igor'
	assert 315 !in ifd0 // автор пуст - тега нет
	ex := ex_ifd(d, int(ex_u32(ifd0[34665].data, 0)))
	assert ex_u32(ex[33434].data, 0) == 1 && ex_u32(ex[33434].data, 4) == 250
	assert ex_rat(ex[33437]) == 6.3
	assert ex_u16(ex[34855].data, 0) == 400
	assert ex[36864].data.bytestr() == '0232'
	assert ex_str(ex[36867]) == '2026:09:28 14:05:33'
	assert ex_str(ex[36868]) == '2026:09:28 14:05:33'
	assert ex_rat(ex[37386]) == 24
	assert ex_str(ex[42035]) == 'Canon'
	assert ex_str(ex[42036]) == 'RF24-50mm F4.5-6.3 IS STM'
}

fn test_exif_block() {
	check_tiff_exif(exif_tiff(sample_exif()))
	// Длинная выдержка - десятыми, пустые поля не пишутся
	d := exif_tiff(Exif{
		exposure: 2.5
	})
	ifd0 := ex_ifd(d, 8)
	assert 271 !in ifd0 && 33432 !in ifd0
	ex := ex_ifd(d, int(ex_u32(ifd0[34665].data, 0)))
	assert ex_rat(ex[33434]) == 2.5
	assert 36867 !in ex && 33437 !in ex
}

fn ex_tmp(name string) string {
	dir := os.join_path(os.temp_dir(), 'vraw_exif_test')
	os.mkdir_all(dir) or {}
	return os.join_path(dir, name)
}

fn ex_pixels(p string) []u8 {
	img := stbi.load(p, desired_channels: 3) or { panic(err) }
	defer {
		img.free()
	}
	return unsafe { img.data.vbytes(img.width * img.height * 3) }.clone()
}

fn ex_frame(w int, h int) []u8 {
	mut rgb := []u8{len: w * h * 3}
	for i in 0 .. rgb.len {
		rgb[i] = u8(i * 7 % 251)
	}
	return rgb
}

// JPEG: APP1 «Exif» сразу за SOI, картинка та же
fn test_exif_jpeg() {
	w, h := 64, 48
	rgb := ex_frame(w, h)
	e := sample_exif()
	plain := ex_tmp('plain.jpg')
	with := ex_tmp('exif.jpg')
	write(plain, .jpeg, w, h, rgb)!
	write(with, .jpeg, w, h, rgb, exif: &e)!
	d := os.read_bytes(with)!
	assert d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF && d[3] == 0xE1
	n := int(d[4]) << 8 | int(d[5])
	assert d[6..12] == [u8(`E`), `x`, `i`, `f`, 0, 0]
	check_tiff_exif(d[12..4 + n])
	// за сегментом - тот же JPEG без SOI
	assert d[4 + n..] == os.read_bytes(plain)![2..]
	assert ex_pixels(with) == ex_pixels(plain)
}

// PNG: чанк eXIf до IDAT с верной CRC (stbi читает), пиксели те же
fn test_exif_png() {
	w, h := 31, 17
	rgb := ex_frame(w, h)
	e := sample_exif()
	p := ex_tmp('exif.png')
	write(p, .png, w, h, rgb, exif: &e)!
	d := os.read_bytes(p)!
	assert d[37..41].bytestr() == 'eXIf'
	n := int(d[33]) << 24 | int(d[34]) << 16 | int(d[35]) << 8 | int(d[36])
	check_tiff_exif(d[41..41 + n])
	assert ex_pixels(p) == rgb
}

// TIFF: теги EXIF в IFD кадра, Exif IFD за ним, кадр читается как прежде
fn test_exif_tiff() {
	w, h := 40, 130 // три полосы
	rgb := ex_frame(w, h)
	e := sample_exif()
	d := encode_tiff(w, h, rgb, &e)!
	check_tiff_exif(d)
	ifd0 := ex_ifd(d, int(ex_u32(d, 4)))
	assert ex_u32(ifd0[256].data, 0) == u32(w)
	assert ifd0[273].count == 3 && ifd0[279].count == 3
	// Без EXIF - Software есть, ссылки на Exif IFD нет
	pd := encode_tiff(w, h, rgb, unsafe { nil })!
	plain := ex_ifd(pd, int(ex_u32(pd, 4)))
	assert ex_str(plain[305]) == 'vraw'
	assert 34665 !in plain && 271 !in plain
}

fn test_has_exif() {
	assert Format.jpeg.has_exif() && Format.png.has_exif() && Format.tiff.has_exif()
	assert !Format.bmp.has_exif() && !Format.qoi.has_exif() && !Format.gif.has_exif()
}
