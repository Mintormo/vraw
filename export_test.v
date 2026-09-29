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

// Этапы экспорта по настройкам и общая доля по весам
fn test_export_plan() {
	mut e := neutral_edit()
	e.lens_corr = false
	p := export_plan(e, 0)
	assert p.stages == [ExportStage.decode, .tone, .write]
	e.lens_corr = true
	e.nr[1] = 10
	p2 := export_plan(e, 0)
	assert p2.stages == [ExportStage.decode, .lens, .denoise, .tone, .write]
	mut c := ExportCtl{
		plan:  p2
		stage: .decode
	}
	assert c.fraction() == 0
	assert c.stage_no() == 1
	c.stage = .write
	assert c.stage_no() == 5
	// всё, кроме записи: 9 из 10 весовых секунд
	assert c.fraction() > 0.89 && c.fraction() < 0.91
}

// Длинный путь: многоточие в начале, в подсказке - строки по «/»
fn test_path_elide() {
	assert elide_left('/a/b', 10) == '/a/b'
	s := elide_left('/home/igor/очень/длинный/путь', 12)
	assert s.runes().len == 12 && s.starts_with('...') && s.ends_with('/путь')
	long := '/' + ['abcdefghij'].repeat(10).join('/')
	tip := path_tip(long)
	assert tip.replace('\n', '') == long
	for line in tip.split('\n') {
		assert line.runes().len <= path_tip_line
	}
	assert path_tip('/tmp/x') == '/tmp/x'
	// Windows: разрыв и по «\»
	win := 'C:\\' + ['abcdefghij'].repeat(10).join('\\')
	wtip := path_tip(win)
	assert wtip.replace('\n', '') == win
	assert wtip.contains('\n')
	for line in wtip.split('\n') {
		assert line.runes().len <= path_tip_line
		assert line.ends_with('\\') || line == wtip.split('\n').last()
	}
}

// Отмена в начале экспорта - ExportCancelled, файл не открывается
fn test_develop_cancel() {
	res := develop_full('/нет/такого.CR3', neutral_edit(), unsafe { nil },
		progress: fn (_ ExportStage, _ int, _ int) bool {
			return false
		}
	) or {
		assert err is ExportCancelled
		return
	}
	assert false, 'ожидалась отмена, получено ${res.width}'
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
