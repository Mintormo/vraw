module imgio

import os
import rand
import stbi
import compress.zlib

// Тестовые кадры: плавный градиент (фото-подобный) и «шум» из немногих
// цветов в разных 5-битных ячейках - палитра GIF передаёт их точно, так
// что GIF обязан вернуться байт в байт (проверка LZW со сбросами словаря)
fn gradient(w int, h int) []u8 {
	mut rgb := []u8{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			i := (y * w + x) * 3
			rgb[i] = u8(x * 255 / (w - 1))
			rgb[i + 1] = u8(y * 255 / (h - 1))
			rgb[i + 2] = u8((x + y) * 255 / (w + h - 2))
		}
	}
	return rgb
}

fn few_colors(w int, h int, n int) []u8 {
	rand.seed([u32(7), 11])
	mut pal := []u8{}
	for k in 0 .. n {
		// ячейки 5 бит: r = k % 32, g = k / 32, b - своя на цвет
		pal << u8((k % 32) * 8 + 3)
		pal << u8((k / 32) * 8 + 3)
		pal << u8((k * 7 % 32) * 8 + 3)
	}
	mut rgb := []u8{len: w * h * 3}
	for i in 0 .. w * h {
		// длинные повторы вперемешку со случайными пикселями
		k := if i % 97 < 40 { (i / 97) % n } else { rand.intn(n) or { 0 } }
		rgb[i * 3] = pal[k * 3]
		rgb[i * 3 + 1] = pal[k * 3 + 1]
		rgb[i * 3 + 2] = pal[k * 3 + 2]
	}
	return rgb
}

fn tmp_path(name string) string {
	dir := os.join_path(os.temp_dir(), 'vraw_imgio_test')
	os.mkdir_all(dir) or {}
	return os.join_path(dir, name)
}

fn load_stbi(path string) ![]u8 {
	img := stbi.load(path, desired_channels: 3)!
	defer {
		img.free()
	}
	return unsafe { (&u8(img.data)).vbytes(img.width * img.height * 3) }.clone()
}

fn mean_abs(a []u8, b []u8) f64 {
	mut s := u64(0)
	for i in 0 .. a.len {
		s += u64(if a[i] > b[i] { a[i] - b[i] } else { b[i] - a[i] })
	}
	return f64(s) / f64(a.len)
}

// block_diff - наибольшая разница средних по блокам 8×8 (b - исходник):
// дизеринг GIF шумит попиксельно, но в среднем по блоку цвет должен
// совпадать. Блоки у краёв гаммы (среднее исходника хоть по одному каналу < 24 или > 231) не
// в счёт: цвета палитры медианного сечения - средние своих коробок, до
// чистых 0 и 255 они не достают, там дизерингу некуда уходить.
fn block_diff(a []u8, b []u8, w int, h int) f64 {
	mut worst := 0.0
	for by in 0 .. h / 8 {
		blocks: for bx in 0 .. w / 8 {
			mut sa := [0, 0, 0]!
			mut sb := [0, 0, 0]!
			for y in by * 8 .. by * 8 + 8 {
				for x in bx * 8 .. bx * 8 + 8 {
					for c in 0 .. 3 {
						sa[c] += a[(y * w + x) * 3 + c]
						sb[c] += b[(y * w + x) * 3 + c]
					}
				}
			}
			// хоть один канал у края гаммы - блок не в счёт (см. выше)
			for c in 0 .. 3 {
				if sb[c] < 24 * 64 || sb[c] > 231 * 64 {
					continue blocks
				}
			}
			for c in 0 .. 3 {
				d := f64(if sa[c] > sb[c] { sa[c] - sb[c] } else { sb[c] - sa[c] }) / 64
				if d > worst {
					worst = d
				}
			}
		}
	}
	return worst
}

fn get_u16_le(b []u8, at int) int {
	return int(b[at]) | (int(b[at + 1]) << 8)
}

fn get_u32_le(b []u8, at int) u32 {
	return u32(b[at]) | (u32(b[at + 1]) << 8) | (u32(b[at + 2]) << 16) | (u32(b[at + 3]) << 24)
}

// decode_qoi - минимальный декодер QOI (RGB) по спецификации
fn decode_qoi(d []u8) ![]u8 {
	if d.len < 22 || d[..4].bytestr() != 'qoif' {
		return error('не QOI')
	}
	w := (int(d[4]) << 24) | (int(d[5]) << 16) | (int(d[6]) << 8) | int(d[7])
	h := (int(d[8]) << 24) | (int(d[9]) << 16) | (int(d[10]) << 8) | int(d[11])
	mut out := []u8{cap: w * h * 3}
	mut index := [][4]u8{len: 64}
	mut px := [u8(0), 0, 0, 255]!
	mut p := 14
	mut run := 0
	for _ in 0 .. w * h {
		if run > 0 {
			run--
		} else {
			b := d[p]
			p++
			if b == 0xfe {
				px[0] = d[p]
				px[1] = d[p + 1]
				px[2] = d[p + 2]
				p += 3
			} else if b == 0xff {
				px[0] = d[p]
				px[1] = d[p + 1]
				px[2] = d[p + 2]
				px[3] = d[p + 3]
				p += 4
			} else if b & 0xc0 == 0x00 {
				px = index[b]
			} else if b & 0xc0 == 0x40 {
				px[0] += ((b >> 4) & 3) - 2
				px[1] += ((b >> 2) & 3) - 2
				px[2] += (b & 3) - 2
			} else if b & 0xc0 == 0x80 {
				b2 := d[p]
				p++
				dg := (b & 0x3f) - 32
				px[0] += dg - 8 + ((b2 >> 4) & 0x0f)
				px[1] += dg
				px[2] += dg - 8 + (b2 & 0x0f)
			} else {
				run = int(b & 0x3f)
			}
			idx := (int(px[0]) * 3 + int(px[1]) * 5 + int(px[2]) * 7 + int(px[3]) * 11) % 64
			index[idx] = px
		}
		out << px[0]
		out << px[1]
		out << px[2]
	}
	return out
}

// decode_tiff - минимальный декодер ровно того TIFF, что пишет encode_tiff
fn decode_tiff(d []u8) !([]u8, int, int) {
	if d[0] != `I` || d[1] != `I` || get_u16_le(d, 2) != 42 {
		return error('не TIFF little-endian')
	}
	ifd := int(get_u32_le(d, 4))
	n := get_u16_le(d, ifd)
	mut tags := map[int][]u32{}
	for i in 0 .. n {
		e := ifd + 2 + i * 12
		tag := get_u16_le(d, e)
		typ := get_u16_le(d, e + 2)
		count := int(get_u32_le(d, e + 4))
		mut vals := []u32{}
		if typ == 3 && count == 1 {
			vals << u32(get_u16_le(d, e + 8))
		} else if typ == 4 && count == 1 {
			vals << get_u32_le(d, e + 8)
		} else if typ == 4 {
			at := int(get_u32_le(d, e + 8))
			for k in 0 .. count {
				vals << get_u32_le(d, at + k * 4)
			}
		} else {
			vals << get_u32_le(d, e + 8)
		}
		tags[tag] = vals
	}
	w := int(tags[256][0])
	h := int(tags[257][0])
	assert tags[259][0] == 8 // Deflate
	assert tags[317][0] == 2 // предиктор
	assert tags[262][0] == 2 // RGB
	offs := tags[273]
	cnts := tags[279]
	mut out := []u8{cap: w * h * 3}
	for s in 0 .. offs.len {
		mut strip := zlib.decompress(d[int(offs[s])..int(offs[s] + cnts[s])])!
		row := w * 3
		for y in 0 .. strip.len / row {
			for x in 3 .. row {
				strip[y * row + x] += strip[y * row + x - 3]
			}
		}
		out << strip
	}
	return out, w, h
}

fn test_format_by_path() {
	assert format_by_path('/a/b/IMG.JPG')? == .jpeg
	assert format_by_path('x.jpeg')? == .jpeg
	assert format_by_path('x.tiff')? == .tiff
	assert format_by_path('x.Tif')? == .tiff
	assert format_by_path('x.qoi')? == .qoi
	assert format_by_path('x.gif')? == .gif
	assert format_by_path('x.png')? == .png
	assert format_by_path('x.bmp')? == .bmp
	if _ := format_by_path('x.webp') {
		assert false
	}
	if _ := format_by_path('noext') {
		assert false
	}
	for f in formats {
		assert format_by_key(f.key())? == f
		assert format_by_path('a.' + f.ext())? == f
	}
}

// Без потерь: PNG, BMP, TIFF, QOI - байт в байт
fn test_lossless() {
	w, h := 301, 157 // нечётные размеры: хвосты строк, паддинг BMP
	for rgb in [gradient(w, h), few_colors(w, h, 200)] {
		for f in [Format.png, .bmp] {
			p := tmp_path('t.${f.ext()}')
			write(p, f, w, h, rgb)!
			assert load_stbi(p)! == rgb, f.name()
		}
		qoi := encode_qoi(w, h, rgb)
		assert decode_qoi(qoi)! == rgb
		tif, tw, th := decode_tiff(encode_tiff(w, h, rgb, unsafe { nil })!)!
		assert tw == w && th == h
		assert tif == rgb
	}
}

// TIFF из нескольких полос и с одной полосой
fn test_tiff_strips() {
	for h in [1, 64, 65, 200] {
		rgb := gradient(33, h + 1)[..33 * h * 3]
		tif, _, th := decode_tiff(encode_tiff(33, h, rgb, unsafe { nil })!)!
		assert th == h
		assert tif == rgb
	}
}

// GIF: немногие цвета - точно (палитра их передаёт, LZW не теряет)
fn test_gif_exact() {
	w, h := 640, 480 // 300 тыс. пикселей: много сбросов словаря
	rgb := few_colors(w, h, 250)
	p := tmp_path('t.gif')
	write(p, .gif, w, h, rgb)!
	assert load_stbi(p)! == rgb
	// одноцветный и крошечный
	one := []u8{len: 5 * 3, init: 77}
	write(p, .gif, 5, 1, one)!
	assert load_stbi(p)! == one
}

// GIF и JPEG фото-подобного кадра: близко к исходному
fn test_lossy_close() {
	w, h := 400, 300
	rgb := gradient(w, h)
	p := tmp_path('t.gif')
	write(p, .gif, w, h, rgb)!
	g := load_stbi(p)!
	assert mean_abs(g, rgb) < 8 // попиксельно - шум дизеринга
	assert block_diff(g, rgb, w, h) < 3 // в среднем - тот же цвет
	pj := tmp_path('t.jpg')
	write(pj, .jpeg, w, h, rgb, quality: 92)!
	assert mean_abs(load_stbi(pj)!, rgb) < 2
}

fn test_bad_size() {
	write(tmp_path('x.png'), .png, 10, 10, []u8{len: 5}) or { return }
	assert false
}
