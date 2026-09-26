module raw

import os

// Режимы highlight (пересветы) должны реально менять данные
// на передержанном кадре: клип vs смешение vs реконструкция.
fn test_develop_highlight() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut d := open(path)!
	mut a := d.develop(half: true, linear16: true)! // 0 - клип
	mut b := d.develop(half: true, linear16: true, highlight: 2)! // смешение
	mut c := d.develop(half: true, linear16: true, highlight: 5)! // реконструкция
	assert a.bits == 16
	assert a.width == b.width
	assert a.width == c.width

	n := a.width * a.height * 3
	mut diff_ab := u64(0)
	mut diff_ac := u64(0)
	unsafe {
		pa := a.data_u16()
		pb := b.data_u16()
		pc := c.data_u16()
		for i in 0 .. n {
			diff_ab += u64(if pa[i] > pb[i] { pa[i] - pb[i] } else { pb[i] - pa[i] })
			diff_ac += u64(if pa[i] > pc[i] { pa[i] - pc[i] } else { pc[i] - pa[i] })
		}
	}
	assert diff_ab > 0
	assert diff_ac > 0

	a.free()
	b.free()
	c.free()
	d.close()
}
