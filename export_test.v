module main

import os
import time
import vgui
import json2
import pipeline
import imgio

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
	p := export_plan(e, .jpeg)
	assert p.stages == [ExportStage.decode, .tone, .write]
	e.lens_corr = true
	e.nr[1] = 10
	p2 := export_plan(e, .jpeg)
	assert p2.stages == [ExportStage.decode, .lens, .denoise, .tone, .write]
	// Capture-резкость - после шумодава, перед тоном
	mut e3 := e
	e3.params.sharp.dc_amount = 50
	assert export_plan(e3, .jpeg).stages == [ExportStage.decode, .lens, .denoise, .capture,
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
	c.plan = export_plan(e, .png)
	assert c.fraction() < 0.7
}

// Настройки версии с AI-шумодавом (поля export_no_ai, no_ai_cache)
// читаются: лишние поля пропускаются
fn test_settings_old_ai_fields() {
	old := json2.decode[Settings]('{"export_no_ai": true, "no_ai_cache": true, "jpeg_quality": 90}')!
	assert old.jpeg_quality == 90
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

// CancelStage - прогресс экспорта, отменяющий его сразу
struct CancelStage {}

fn (mut c CancelStage) stage(_ ExportStage, _ int, _ int) bool {
	return false
}

// Отмена в начале экспорта - ExportCancelled, файл не открывается
fn test_develop_cancel() {
	res := develop_full('/нет/такого.CR3', neutral_edit(), unsafe { nil },
		progress: StageProgress(CancelStage{})
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
	n := develop_full(path, with_derived(e0, CamLook{}, pipeline.CamColor{}), unsafe { nil })!
	mut e1 := e0.clone()
	e1.params.exposure = 1
	b := develop_full(path, with_derived(e1, CamLook{}, pipeline.CamColor{}), unsafe { nil })!
	assert n.width == b.width && n.rgb.len == n.width * n.height * 3
	assert n.width > 5000 // полный размер
	mut sn := u64(0)
	mut sb := u64(0)
	for i in 0 .. n.rgb.len {
		sn += n.rgb[i]
		sb += b.rgb[i]
	}
	assert sb > sn * 11 / 10
	// EXIF по метаданным кадра: камера, дата, съёмка; запись - только
	// при включённом флажке и формате, который EXIF держит
	m := n.meta
	assert m.cam_make == 'Canon' && m.shot > 0 && m.iso > 0 && m.shutter > 0
	x := export_exif(m, '© тест')
	assert x.model == 'Canon EOS R8'
	assert x.date == shot_date(m.shot, path).replace('-', ':') + x.date[10..]
	assert x.date.len == 19 && x.iso > 0 && x.copyright == '© тест'
	small := Image{
		width:  4
		height: 2
		rgb:    []u8{len: 24, init: 128}
		meta:   m
	}
	dir := os.join_path(os.temp_dir(), 'vraw_exif_main')
	os.mkdir_all(dir)!
	mut s := Settings{}
	for f in [imgio.Format.jpeg, .png, .tiff, .bmp] {
		p := os.join_path(dir, 'a.${f.ext()}')
		write_image(p, f, small, 90, &s)!
		has := os.read_file(p)!.contains('Canon EOS R8')
		assert has == f.has_exif(), f.name()
	}
	s.export_no_exif = true
	p := os.join_path(dir, 'b.jpg')
	write_image(p, .jpeg, small, 90, &s)!
	assert !os.read_file(p)!.contains('Canon EOS R8')
}

// Экспорт с градиентным фильтром под поворотом на 90°: фильтр на верхней
// трети кадра (до поворота) - на выходе правая сторона темнее, левая
// как без фильтра
fn test_develop_full_mask() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut e0 := neutral_edit()
	e0.lens_corr = false
	e0.geom.rot90 = 1
	e0.params.dither = false
	n := develop_full(path, with_derived(e0, CamLook{}, pipeline.CamColor{}), unsafe { nil })!
	mut e1 := e0.clone()
	e1.params.masks << pipeline.Mask{
		kind:     .linear
		ax:       0.5
		ay:       0.2
		bx:       0.5
		by:       0.4
		exposure: -1
	}
	b := develop_full(path, with_derived(e1, CamLook{}, pipeline.CamColor{}), unsafe { nil })!
	assert n.width == b.width && n.height == b.height && n.height > n.width
	// Суммы по столбцам: x < 0.55 ширины - как было, x > 0.85 - темнее
	w := n.width
	mut left_n := u64(0)
	mut left_b := u64(0)
	mut right_n := u64(0)
	mut right_b := u64(0)
	for y := 0; y < n.height; y += 7 {
		for x in 0 .. w {
			i := (y * w + x) * 3 + 1
			if x < w * 55 / 100 {
				left_n += n.rgb[i]
				left_b += b.rgb[i]
			} else if x > w * 85 / 100 {
				right_n += n.rgb[i]
				right_b += b.rgb[i]
			}
		}
	}
	assert left_b == left_n
	assert right_b < right_n * 80 / 100
}

// Настройки старой версии (без поля) - EXIF при экспорте пишется
fn test_settings_exif_default() {
	old := json2.decode[Settings]('{"theme": "dark"}')!
	assert !old.export_no_exif && old.exif_copyright == ''
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

// Имя по шаблону: {name}, {num} (ширина - по числу кадров), {date},
// запрещённые символы, пустое - имя RAW
fn test_export_file_name() {
	ni := NameInfo{}
	assert export_file_name('{name}', '/a/IMG_0991.CR3', ni) == 'IMG_0991'
	assert export_file_name('{name}_web', '/a/IMG_0991.CR3', ni) == 'IMG_0991_web'
	assert export_file_name('trip_{num}', '/a/X.CR3', NameInfo{ num: 7, count: 12 }) == 'trip_007'
	assert export_file_name('{num}', '/a/X.CR3', NameInfo{ num: 42, count: 1500 }) == '0042'
	assert export_file_name('{num}', '/a/X.CR3', ni) == '001'
	// 28.09.2026 12:00 местного времени
	shot := time.new(year: 2026, month: 9, day: 28, hour: 12).unix() - time.offset()
	assert export_file_name('{date}_{name}', '/a/X.CR3', NameInfo{ shot: shot }) == '2026-09-28_X'
	assert export_file_name('a/b:c', '/a/X.CR3', ni) == 'a_b_c'
	assert export_file_name('  ', '/a/X.CR3', ni) == 'X'
	assert export_file_name('...', '/a/X.CR3', ni) == 'X'
	assert export_file_name('{имя}', '/a/X.CR3', ni) == '{имя}' // только английские
}

// Дата съёмки тестового CR3 из EXIF; шаблон с {date} - путь с датой
fn test_export_date_real() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		return
	}
	shot := raw_shot(path)
	assert shot > time.new(year: 2020, month: 1, day: 1).unix()
	mut s := Settings{}
	s.export_name = '{date}_{name}'
	p := export_path(&s, path, .jpeg)
	assert os.file_name(p) == '${shot_date(shot, path)}_IMG_0991.jpg'
}

// Старый шаблон {имя} при загрузке настроек становится {name}
fn test_settings_name_migration() {
	assert name_tmpl_migrate('{имя}_web') == '{name}_web'
	assert name_tmpl_migrate('  ') == '{name}'
	assert name_tmpl_migrate('{num}') == '{num}'
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
	out := os.join_path(os.temp_dir(), 'out')
	s.export_dir = out
	s.export_name = '{name}_web'
	assert export_path(&s, raw_path, .tiff) == os.join_path(out, 'IMG_1_web.tif')
	os.rmdir_all(dir) or {}
}

// Настройки экспорта: старый файл без полей - значения по умолчанию
fn test_settings_export_defaults() {
	s := Settings{}
	assert s.export_dir_mode == 'raw' && s.export_name == '{name}' && s.export_exists == 'number'
		&& s.export_size == '' && s.export_long == 2048 && s.export_pct == 50
	old := json2.decode[Settings]('{"theme": "dark"}')!
	assert old.export_size == '' && old.export_dir == ''
	assert clamp_px(0, 2048) == 2048 && clamp_px(99999, 1920) == 1920 && clamp_px(800, 1) == 800
}

// Резкость на выход: по умолчанию нет; сила - по ключу; в итоге пакета -
// только при уменьшении
fn test_export_sharp_settings() {
	mut s := Settings{}
	assert s.export_sharp == '' && s.export_size_opts().sharp == 0
	s.export_sharp = 'std'
	assert s.export_size_opts().sharp == 0.8
	assert size_desc(&s) == 'полный размер'
	s.export_size = 'long'
	assert size_desc(&s) == 'длинная сторона до 2048 px, резкость: средняя'
	s.export_sharp = 'bogus'
	assert s.export_size_opts().sharp == 0
}

// Экспорт в 16 бит: тот же кадр, что в 8 бит (старший уровень - в
// пределах 1, дизер 8 бит выключен), и с уменьшением. Кадр - тестовый
// CR3 или VRAW_TEST_CR3.
fn test_develop_full16() {
	path := os.getenv_opt('VRAW_TEST_CR3') or { os.join_path(@VMODROOT, 'IMG_0991.CR3') }
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut e := neutral_edit()
	e.lens_corr = false
	e.params.dither = false
	e.params.exposure = 0.5
	e.params.sharp.amount = 40
	ed := with_derived(e, CamLook{}, pipeline.CamColor{})
	for size in [ExportSize{}, ExportSize{
		mode:  'long'
		long:  1600
		sharp: 0.8
	}] {
		mut a := develop_full(path, ed, unsafe { nil }, size: size)!
		mut b := develop_full(path, ed, unsafe { nil }, size: size, bits16: true)!
		defer {
			a.free()
			b.free()
		}
		assert b.bits16 && !a.bits16
		assert a.width == b.width && a.height == b.height
		n := a.width * a.height * 3
		assert b.rgb.len == n * 2
		mut fine := 0
		unsafe {
			q := &u16(b.rgb.data)
			for i in 0 .. n {
				d := int(a.rgb[i]) - int((u32(q[i]) + 128) / 257)
				assert d >= -1 && d <= 1
				if q[i] % 257 != 0 {
					fine++
				}
			}
		}
		assert fine > n / 2
	}
}
