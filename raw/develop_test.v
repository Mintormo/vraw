module raw

import os

// Проявка - сырьё для собственного пайплайна: 16 бит, линейная гамма;
// тот же Developer проявляется повторно без нового open/unpack.
fn test_develop_linear16() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut d := open(path)!
	mut a := d.develop(half: true)!
	assert a.bits == 16
	assert a.colors == 3
	assert a.width > 0

	n := a.width * 3 * 20
	mut sum := u64(0)
	unsafe {
		p := a.data_u16()
		for i in 0 .. n {
			sum += p[i]
		}
	}
	assert sum > 0

	// Повторная проявка с другими параметрами тем же Developer
	mut b := d.develop(half: true, highlight: 2)!
	assert b.bits == 16
	assert b.width == a.width

	a.free()
	b.free()
	d.close()
}
