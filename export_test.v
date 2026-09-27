module main

import os
import vgui

fn test_tone_lut() {
	assert tone_lut(identity_curve()).len == 0 // диагональ - кривой нет
	l := tone_lut([vgui.CurvePoint{0, 0}, vgui.CurvePoint{0.5, 0.7}, vgui.CurvePoint{1, 1}])
	assert l.len == 256
	assert l[128] > 128 * 1.2 // точка (0.5, 0.7) поднимает середину
	for i in 1 .. 256 {
		assert l[i] >= l[i - 1]
	}
}

// Экспорт тестового CR3: экспозиция +1 EV светлее нейтральной
fn test_develop_full() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut e0 := neutral_edit()
	e0.lens_corr = false
	n := develop_full(path, with_derived(e0, []f32{}), unsafe { nil })!
	mut e1 := e0.clone()
	e1.params.exposure = 1
	b := develop_full(path, with_derived(e1, []f32{}), unsafe { nil })!
	assert n.width == b.width && n.rgb.len == n.width * n.height * 3
	assert n.width > 5000 // полный размер
	mut sn := u64(0)
	mut sb := u64(0)
	for i in 0 .. n.rgb.len {
		sn += n.rgb[i]
		sb += b.rgb[i]
	}
	assert sb > sn * 11 / 10
}
