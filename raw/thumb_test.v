module raw

import os
import stbi

// thumb_min выбирает наименьшее достаточное встроенное превью:
// у CR3 - 1620x1080 для 256 и 1000, 160x120 для 100, полное для 4000.
fn test_thumb_min() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut d := open(path)!
	defer {
		d.close()
	}
	for min_side, want in {
		100:  160
		256:  1620
		1000: 1620
		4000: 6000
	} {
		j := d.thumb_min(min_side)!
		mut img := stbi.load_from_memory(j.data, j.len, desired_channels: 3)!
		long := if img.width > img.height { img.width } else { img.height }
		img.free()
		assert long == want, 'min_side ${min_side}: ${long}'
	}
	assert d.flip() == 0
	// Обычный thumb() после thumb_min - по-прежнему полный JPEG
	full := d.thumb()!
	assert full.len > 1_000_000
}

// После проявки unpack_thumb_ex LibRaw запрещает - thumb_min всё равно
// отдаёт превью (вторым хендлом). Так вызывает камерная кривая GUI.
fn test_thumb_min_after_develop() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		return
	}
	mut d := open(path)!
	defer {
		d.close()
	}
	mut im := d.develop(half: true, linear16: true)!
	im.free()
	j := d.thumb_min(1000)!
	mut img := stbi.load_from_memory(j.data, j.len, desired_channels: 3)!
	assert img.width == 1620
	img.free()
	// И повторная проявка после этого работает
	mut im2 := d.develop(half: true, linear16: true)!
	assert im2.width > 0
	im2.free()
}

// Порядок вызовов фонового загрузчика GUI: маленькое превью, проявка,
// затем полный JPEG для камерной кривой - thumb() обязан отдать полный,
// а не последнее выбранное превью (1620x1080)
fn test_thumb_after_thumb_min_and_develop() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		return
	}
	mut d := open(path)!
	defer {
		d.close()
	}
	small := d.thumb_min(1000)!
	mut im := d.develop(half: true, linear16: true)!
	im.free()
	full := d.thumb()!
	assert full.len > 1_000_000
	assert full.len > small.len * 3
	mut img := stbi.load_from_memory(full.data, full.len, desired_channels: 3)!
	assert img.width == 6000
	img.free()
}
