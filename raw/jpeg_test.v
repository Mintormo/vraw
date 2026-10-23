module raw

import os
import stbi

// Встроенный JPEG тестового CR3: размер и пиксели - как у stbi (разные
// IDCT и сглаживание цветности - в пределах нескольких уровней)
fn test_decode_jpeg_matches_stbi() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('пропуск: нет ${path}')
		return
	}
	mut d := open(path)!
	defer {
		d.close()
	}
	data := d.thumb()!
	mut j := decode_jpeg(data)!
	defer {
		j.free()
	}
	mut s := stbi.load_from_memory(data.data, data.len, desired_channels: 3)!
	defer {
		s.free()
	}
	assert j.width == s.width && j.height == s.height
	assert j.pix.len == j.width * j.height * 3
	sp := unsafe { &u8(s.data) }
	mut sum := i64(0)
	mut worst := 0
	for i := 0; i < j.pix.len; i += 7 {
		dv := int(j.pix[i]) - int(unsafe { sp[i] })
		ad := if dv < 0 { -dv } else { dv }
		sum += ad
		if ad > worst {
			worst = ad
		}
	}
	mean := f64(sum) / f64(j.pix.len / 7)
	assert mean < 1.0, 'среднее расхождение ${mean}'
}

fn test_decode_jpeg_garbage() {
	if _ := decode_jpeg([u8(1), 2, 3, 4, 5, 6]) {
		assert false
	}
	if _ := decode_jpeg([]u8{}) {
		assert false
	}
	// Обрезанный файл: libjpeg дописывает серым, но не падает
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		return
	}
	mut d := open(path)!
	defer {
		d.close()
	}
	data := d.thumb()!
	if mut j := decode_jpeg(data[..data.len / 2]) {
		j.free()
	}
}
