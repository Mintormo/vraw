module main

import os
import vgui
import json2
import pipeline

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
	p := export_plan(e, 0, .jpeg)
	assert p.stages == [ExportStage.decode, .tone, .write]
	e.lens_corr = true
	e.nr[1] = 10
	p2 := export_plan(e, 0, .jpeg)
	assert p2.stages == [ExportStage.decode, .lens, .denoise, .tone, .write]
	// Capture-резкость - после шумодава, перед тоном
	mut e3 := e
	e3.params.sharp.dc_amount = 50
	assert export_plan(e3, 0, .jpeg).stages == [ExportStage.decode, .lens, .denoise, .capture,
		.tone, .write]
	mut c := ExportCtl{
		plan:  p2
		stage: .decode
	}
	assert c.fraction() == 0
	assert c.stage_no() == 1
	c.stage = .write
	assert c.stage_no() == 5
	// всё, кроме записи JPEG: 9 из 9.7 весовых секунд
	assert c.fraction() > 0.92 && c.fraction() < 0.94
	// запись PNG - дольше, её доля больше
	c.plan = export_plan(e, 0, .png)
	assert c.fraction() < 0.7
}

// Настройки старой версии (без поля) - AI при экспорте включён
fn test_settings_export_ai_default() {
	old := json2.decode[Settings]('{"theme": "dark", "jpeg_quality": 90}')!
	assert !old.export_no_ai
	off := json2.decode[Settings]('{"export_no_ai": true}')!
	assert off.export_no_ai
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
	n := develop_full(path, with_derived(e0, []f32{}, pipeline.CamColor{}), unsafe { nil })!
	mut e1 := e0.clone()
	e1.params.exposure = 1
	b := develop_full(path, with_derived(e1, []f32{}, pipeline.CamColor{}), unsafe { nil })!
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

// Размер на выход: длинная сторона ровно, пропорции сохраняются, кадр не
// увеличивается; вписать в Ш × В - по тесной стороне; проценты
fn test_export_dims() {
	mut w, mut h := export_dims(ExportSize{}, 6000, 4000)
	assert w == 6000 && h == 4000
	w, h = export_dims(ExportSize{ mode: 'long', long: 2048 }, 6000, 4000)
	assert w == 2048 && h == 1365
	w, h = export_dims(ExportSize{ mode: 'long', long: 2048 }, 4000, 6000)
	assert w == 1365 && h == 2048
	w, h = export_dims(ExportSize{ mode: 'long', long: 9000 }, 6000, 4000)
	assert w == 6000 && h == 4000 // не увеличивать
	w, h = export_dims(ExportSize{ mode: 'fit', w: 1920, h: 1080 }, 6000, 4000)
	assert w == 1620 && h == 1080 // упор в высоту
	w, h = export_dims(ExportSize{ mode: 'fit', w: 1920, h: 1920 }, 6000, 4000)
	assert w == 1920 && h == 1280
	w, h = export_dims(ExportSize{ mode: 'pct', pct: 50 }, 5999, 3999)
	assert w == 3000 && h == 2000
	w, h = export_dims(ExportSize{ mode: 'pct', pct: 100 }, 5999, 3999)
	assert w == 5999 && h == 3999
}

// Имя по шаблону: {имя}, запрещённые символы, пустое - имя RAW
fn test_export_file_name() {
	assert export_file_name('{имя}', '/a/IMG_0991.CR3') == 'IMG_0991'
	assert export_file_name('{имя}_web', '/a/IMG_0991.CR3') == 'IMG_0991_web'
	assert export_file_name('{name}-1', '/a/X.CR3') == 'X-1'
	assert export_file_name('a/b:c', '/a/X.CR3') == 'a_b_c'
	assert export_file_name('  ', '/a/X.CR3') == 'X'
	assert export_file_name('...', '/a/X.CR3') == 'X'
}

// Путь: рядом с RAW или в папке; существующий файл - номер или перезапись
fn test_export_path() {
	dir := os.join_path(os.temp_dir(), 'vraw_export_path_test')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir)!
	raw_path := os.join_path(dir, 'IMG_1.CR3')
	mut s := Settings{}
	assert export_path(&s, raw_path, .jpeg) == os.join_path(dir, 'IMG_1.jpg')
	os.write_file(os.join_path(dir, 'IMG_1.jpg'), 'x')!
	assert export_path(&s, raw_path, .jpeg) == os.join_path(dir, 'IMG_1-2.jpg')
	os.write_file(os.join_path(dir, 'IMG_1-2.jpg'), 'x')!
	assert export_path(&s, raw_path, .jpeg) == os.join_path(dir, 'IMG_1-3.jpg')
	assert export_path(&s, raw_path, .png) == os.join_path(dir, 'IMG_1.png')
	s.export_exists = 'overwrite'
	assert export_path(&s, raw_path, .jpeg) == os.join_path(dir, 'IMG_1.jpg')
	s.export_dir_mode = 'dir'
	s.export_dir = '/tmp/out'
	s.export_name = '{имя}_web'
	assert export_path(&s, raw_path, .tiff) == '/tmp/out/IMG_1_web.tif'
	os.rmdir_all(dir) or {}
}

// Настройки экспорта: старый файл без полей - значения по умолчанию
fn test_settings_export_defaults() {
	s := Settings{}
	assert s.export_dir_mode == 'raw' && s.export_name == '{имя}' && s.export_exists == 'number'
		&& s.export_size == '' && s.export_long == 2048 && s.export_pct == 50
	old := json2.decode[Settings]('{"theme": "dark"}')!
	assert old.export_size == '' && old.export_dir == ''
	assert clamp_px(0, 2048) == 2048 && clamp_px(99999, 1920) == 1920 && clamp_px(800, 1) == 800
}
