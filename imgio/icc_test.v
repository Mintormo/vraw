module imgio

import os
import math

fn icc_u32(b []u8, at int) u32 {
	return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
}

fn icc_s15(b []u8, at int) f64 {
	return f64(i32(icc_u32(b, at))) / 65536
}

// icc_tag - смещение и размер тега sig (0, 0 - нет)
fn icc_tag(b []u8, sig string) (int, int) {
	n := int(icc_u32(b, 128))
	for i in 0 .. n {
		at := 132 + 12 * i
		if b[at..at + 4].bytestr() == sig {
			return int(icc_u32(b, at + 4)), int(icc_u32(b, at + 8))
		}
	}
	return 0, 0
}

// Заголовок и теги на месте; размер в заголовке - длина профиля; данные
// тегов внутри профиля
fn test_icc_structure() {
	p := srgb_icc()
	assert int(icc_u32(p, 0)) == p.len
	assert p[12..24].bytestr() == 'mntrRGB XYZ '
	assert p[36..40].bytestr() == 'acsp'
	for sig in ['desc', 'cprt', 'wtpt', 'rXYZ', 'gXYZ', 'bXYZ', 'rTRC', 'gTRC', 'bTRC'] {
		off, size := icc_tag(p, sig)
		assert off > 0 && off % 4 == 0 && off + size <= p.len, sig
	}
	r, _ := icc_tag(p, 'rTRC')
	b, _ := icc_tag(p, 'bTRC')
	assert r == b // одна кривая на три канала
	assert p[r..r + 4].bytestr() == 'curv'
}

// Столбцы матрицы - основные цвета sRGB, приведённые к D50 (известные
// значения с точностью s15Fixed16); сумма - белое D50
fn test_icc_colorants() {
	p := srgb_icc()
	want := {
		'rXYZ': [0.4361, 0.2225, 0.0139]
		'gXYZ': [0.3851, 0.7169, 0.0971]
		'bXYZ': [0.1431, 0.0606, 0.7141]
	}
	mut sum := [0.0, 0.0, 0.0]
	for sig, w in want {
		off, _ := icc_tag(p, sig)
		for k in 0 .. 3 {
			v := icc_s15(p, off + 8 + 4 * k)
			assert math.abs(v - w[k]) < 2e-4, '${sig}[${k}] = ${v}'
			sum[k] += v
		}
	}
	assert math.abs(sum[0] - 0.9642) < 3e-4 && math.abs(sum[1] - 1.0) < 3e-4
		&& math.abs(sum[2] - 0.8249) < 3e-4
}

// Кривая: концы 0 и 65535, монотонна, середина кода 0.5 - линейное 0.214
fn test_icc_curve() {
	p := srgb_icc()
	off, _ := icc_tag(p, 'rTRC')
	n := int(icc_u32(p, off + 8))
	assert n == icc_curve_n
	val := fn [p, off] (i int) int {
		return int(p[off + 12 + 2 * i]) << 8 | int(p[off + 13 + 2 * i])
	}
	assert val(0) == 0 && val(n - 1) == 65535
	for i in 1 .. n {
		assert val(i) >= val(i - 1)
	}
	mid := f64(val(n / 2)) / 65535
	assert math.abs(mid - 0.2140) < 0.002
}

// Профиль в файлах: APP2 в JPEG (после EXIF и JFIF), iCCP в PNG, тег 34675 в TIFF;
// без профиля - ничего
fn test_icc_in_files() ! {
	w, h := 8, 4
	rgb := []u8{len: w * h * 3, init: u8(index * 5)}
	icc := srgb_icc()
	e := Exif{
		make: 'Canon'
	}
	jp := tmp_path('icc.jpg')
	write(jp, .jpeg, w, h, rgb, exif: &e, icc: icc)!
	j := os.read_bytes(jp)!
	assert j[2] == 0xFF && j[3] == 0xE1 // EXIF первым
	mut at := 2
	for j[at + 1] == 0xE0 || j[at + 1] == 0xE1 {
		at += 2 + (int(j[at + 2]) << 8 | int(j[at + 3]))
	}
	assert j[at] == 0xFF && j[at + 1] == 0xE2
	assert j[at + 4..at + 15].bytestr() == 'ICC_PROFILE'
	assert j[at + 18..at + 18 + icc.len] == icc
	pp := tmp_path('icc.png')
	write(pp, .png, w, h, rgb, icc: icc)!
	pn := os.read_bytes(pp)!
	assert pn[37..41].bytestr() == 'iCCP'
	tp := tmp_path('icc.tif')
	write(tp, .tiff, w, h, rgb, icc: icc)!
	assert os.read_bytes(tp)!.bytestr().contains(icc.bytestr())
	plain := tmp_path('plain.jpg')
	write(plain, .jpeg, w, h, rgb)!
	assert !os.read_bytes(plain)!.bytestr().contains('ICC_PROFILE')
}

fn tmp_path(name string) string {
	dir := os.join_path(os.temp_dir(), 'vraw_icc_test')
	os.mkdir_all(dir) or {}
	return os.join_path(dir, name)
}
