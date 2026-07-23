module raw

import os

const sample = '/home/igor/Изображения/Передержка фото/IMG_0641.CR3'

// Основа отзывчивости GUI: один Developer проявляется повторно с разными
// параметрами без повторных open/unpack, и bright реально влияет на результат.
fn test_redevelop_with_different_bright() {
	if !os.exists(sample) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut d := open(sample)!
	mut a := d.develop(half: true)!
	assert a.width > 0
	assert a.height > 0
	assert a.colors == 3

	mut b := d.develop(half: true, bright: 2.0)!
	assert b.width == a.width
	assert b.height == a.height

	// Средняя яркость первых строк у bright=2.0 должна быть заметно выше
	n := a.width * 3 * 20 // 20 строк RGB
	mut sum_a := u64(0)
	mut sum_b := u64(0)
	unsafe {
		pa := a.data()
		pb := b.data()
		for i in 0 .. n {
			sum_a += pa[i]
			sum_b += pb[i]
		}
	}
	assert sum_b > sum_a

	a.free()
	b.free()
	d.close()
}
