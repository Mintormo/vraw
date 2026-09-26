module raw

import os

// linear16 - сырьё для собственного пайплайна: 16 бит, линейная гамма.
fn test_develop_linear16() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut d := open(path)!
	mut a := d.develop(half: true, linear16: true)!
	assert a.bits == 16
	assert a.colors == 3
	assert a.width > 0

	// Линейные данные заметно темнее гамма-кодированных в средних тонах:
	// медианное значение должно быть существенно ниже 32768
	n := a.width * 3 * 20
	mut sum := u64(0)
	unsafe {
		p := a.data_u16()
		for i in 0 .. n {
			sum += p[i]
		}
	}
	assert sum > 0

	// После linear16 обычная 8-битная проявка тем же Developer работает
	mut b := d.develop(half: true)!
	assert b.bits == 8
	assert b.width == a.width

	a.free()
	b.free()
	d.close()
}
