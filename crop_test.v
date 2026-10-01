module main

import os
import math
import pipeline
import vgui

// Размер на выход: числовая пропорция - ровно (1:1 - квадрат), размер
// по длинной стороне и точный
fn test_crop_out_size() {
	mut e := neutral_edit()
	e.geom = pipeline.Geom{
		x0: 0.1
		y0: 0.2
		x1: 0.5731
		y1: 0.9
	}
	e.crop_aspect = '1:1'
	cw, ch, fw, fh := out_size(&e, 5999, 3999)
	assert cw == ch && fw == cw && fh == ch
	e.size_mode = 2
	e.size_long = 1000
	_, _, lw, lh := out_size(&e, 5999, 3999)
	assert lw == 1000 && lh == 1000
	e.crop_aspect = ''
	e.geom = pipeline.Geom{}
	_, _, aw, ah := out_size(&e, 6000, 4000)
	assert aw == 1000 && ah == 667
	e.size_mode = 1
	e.size_w = 1920
	e.size_h = 1080
	_, _, xw, xh := out_size(&e, 6000, 4000)
	assert xw == 1920 && xh == 1080
	assert crop_ratio(&e, 6000, 4000) > 1.77 && crop_ratio(&e, 6000, 4000) < 1.78
}

fn test_crop_ratio_keys() {
	mut e := neutral_edit()
	assert crop_ratio(&e, 6000, 4000) == 0
	e.crop_aspect = '65:24'
	assert crop_ratio(&e, 6000, 4000) == 65.0 / 24.0
	e.crop_portrait = true
	assert math.abs(crop_ratio(&e, 6000, 4000) - 24.0 / 65.0) < 1e-12
	e.crop_aspect = 'shot'
	e.crop_portrait = false
	assert crop_ratio(&e, 4000, 6000) == 1.5 // «как снято» - по длинной стороне
	e.crop_aspect = 'custom'
	e.crop_aw = 7
	e.crop_ah = 3
	assert crop_ratio(&e, 6000, 4000) == 7.0 / 3.0
	for k in crop_aspects {
		e.crop_aspect = k
		if k != '' {
			assert crop_ratio(&e, 6000, 4000) > 0, k
		}
	}
	assert crop_aspects.len == crop_aspect_names.len && crop_grids.len == crop_grid_names.len
}

// Сайдкар: геометрия туда-обратно; рамка у края (1 + погрешность f32)
// читается и обрезается к 1; старый файл без полей - весь кадр
fn test_sidecar_crop() {
	mut e := neutral_edit()
	e.geom = pipeline.Geom{
		rot90:  3
		flip_h: true
		angle:  -7.25
		x0:     0.125
		y0:     0.25
		x1:     1
		y1:     0.75
	}
	e.crop_aspect = '16:9'
	e.crop_portrait = true
	e.size_mode = 2
	e.size_long = 3000
	s := side_state(e)
	back := edit_state(s)!
	assert back.geom == e.geom
	assert back.crop_aspect == '16:9' && back.crop_portrait && back.size_mode == 2
		&& back.size_long == 3000
	edge := edit_state(SideState{
		...s
		crop: [f32(0.125), 0.25, 1.0000001, 0.75]
	})!
	assert edge.geom.x1 == 1
	if _ := edit_state(SideState{
		...s
		crop: [f32(0.125), 0.25, 1.5, 0.75]
	})
	{
		assert false, 'рамка за кадром должна отвергаться'
	}
	// Старый файл: полей кадрирования нет
	o := edit_state(SideState{
		...side_state(neutral_edit())
		crop:      []f32{}
		crop_aw:   0
		size_w:    0
		size_long: 0
	})!
	assert o.geom.is_identity() && o.crop_aw == 3 && o.size_w == 1920 && o.size_long == 2048
}

// Группа «Кадрирование» в копировании настроек; по умолчанию не копируется
fn test_crop_group() {
	mut src := neutral_edit()
	src.geom.angle = 5
	src.crop_aspect = '1:1'
	a := merge_groups(neutral_edit(), src, ['tone'])
	assert a.geom.angle == 0
	b := merge_groups(neutral_edit(), src, ['crop'])
	assert b.geom.angle == 5 && b.crop_aspect == '1:1'
	assert 'crop' !in default_copy_groups && 'crop' in copy_groups
}

// Экспорт тестового CR3 с поворотом, 1:1 и длинной стороной 1000
fn test_develop_crop() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut e := neutral_edit()
	e.lens_corr = false
	e.crop_aspect = '1:1'
	e.size_mode = 2
	e.size_long = 1000
	g := pipeline.Geom{
		angle: 6
	}
	b := g.max_box(1, 2999.0 / 2, 1999.0 / 2, 2999, 1999)
	e.geom = g.with_box(b, 2999, 1999)
	img := develop_full(path, with_derived(e, []f32{}, pipeline.CamColor{}), unsafe { nil })!
	assert img.width == 1000 && img.height == 1000
	assert img.rgb.len == 1000 * 1000 * 3
	// Без пустых углов: углы кадра не чёрные
	for p in [0, 999, 999 * 1000, 1000 * 1000 - 1] {
		assert int(img.rgb[p * 3]) + int(img.rgb[p * 3 + 1]) + int(img.rgb[p * 3 + 2]) > 30
	}
}

// Миниатюра ленты - с геометрией из сайдкара: нет сайдкара - без
// изменений; есть - как на выходе (out_geom: пропорция 1:1 - квадрат)
fn test_thumb_geom_sidecar() {
	dir := os.join_path(os.temp_dir(), 'vraw_thumb_geom_test')
	os.mkdir_all(dir) or {}
	path := os.join_path(dir, 'X.CR3')
	side := sidecar_path(path)
	os.rm(side) or {}
	assert thumb_geom(path).is_identity()
	mut e := neutral_edit()
	e.crop_aspect = '1:1'
	e.geom = pipeline.Geom{
		angle: 3
		x0:    0.2
		y0:    0.1
		x1:    0.6
		y1:    0.7
	}
	write_atomic(side, encode_history([HistEntry{
		name:  'Открыт файл'
		state: neutral_edit()
	}, HistEntry{
		name:  'Кадрирование'
		state: e
	}], 1))!
	g := thumb_geom(path)
	assert g == out_geom(&e) && g.aspect == 1
	os.rm(side) or {}
}

// Миниатюра тестового CR3 с рамкой 1:1: квадрат по центру буфера 3:2 -
// слева и справа поля фона, в середине снимок
fn test_make_thumb_crop() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		return
	}
	mut e := neutral_edit()
	e.crop_aspect = '1:1'
	g0 := pipeline.Geom{
		angle: 5
	}
	e.geom = g0.with_box(g0.max_box(1, 750, 500, 1500, 1000), 1500, 1000)
	pix := make_thumb(path, out_geom(&e))!
	assert pix.len == thumb_w * thumb_h * 4
	bg := [thumb_bg.r, thumb_bg.g, thumb_bg.b, u8(255)]
	px := fn [pix] (x int, y int) []u8 {
		k := (y * thumb_w + x) * 4
		return pix[k..k + 4]
	}
	assert px(2, thumb_h / 2) == bg && px(thumb_w - 3, thumb_h / 2) == bg
	assert px(thumb_w / 2, thumb_h / 2) != bg
	// Квадрат во всю высоту: углы квадрата - снимок, без пустых углов
	l := (thumb_w - thumb_h) / 2
	for p in [[l + 1, 1], [l + thumb_h - 2, 1], [l + 1, thumb_h - 2], [l + thumb_h - 2, thumb_h - 2]] {
		c := px(p[0], p[1])
		assert c != bg && int(c[0]) + int(c[1]) + int(c[2]) > 0
	}
}

// crop_state - состояние в режиме кадрирования: превью 300x200, рамка
// по центру, холст под весь кадр
fn crop_state() &State {
	mut st := &State{}
	st.edit = neutral_edit()
	st.pw = 300
	st.ph = 200
	st.linear = []u16{len: 300 * 200 * 3}
	st.tone_fx = fn () {}
	mut cv := vgui.canvas(300, 200)
	// Холст показан 1:1 (как после отрисовки): экран = пиксели буфера
	cv.disp_w = 300
	cv.disp_h = 200
	st.cv = cv
	st.crop_mode = true
	st.edit.geom = st.edit.geom.with_box(pipeline.CropBox{100, 50, 200, 150}, 300, 200)
	return st
}

fn crop_ev(kind vgui.CanvasEventKind, x f32, y f32, ctrl bool) vgui.CanvasInputEvent {
	return vgui.CanvasInputEvent{
		kind:   kind
		button: 1
		clicks: 1
		ctrl:   ctrl
		fx:     x
		fy:     y
	}
}

// Перетаскивание снаружи рамки поворачивает кадр (мышь по часовой - кадр
// по часовой, угол минус), рамка остаётся в кадре; одна запись в истории.
// С Ctrl снаружи - новая рамка, угол прежний.
fn test_crop_rotate_drag() {
	mut st := crop_state()
	start_history(mut st)
	// Справа от рамки (центр 150, 100) вниз - по часовой на экране
	assert crop_input(mut st, crop_ev(.pointer_down, 260, 100, false))
	assert st.crop_drag.kind == .rotate
	crop_input(mut st, crop_ev(.pointer_move, 260, 130, false))
	crop_input(mut st, crop_ev(.pointer_move, 260, 160, false))
	a := st.edit.geom.angle
	want := -math.atan2(60, 110) * 180 / math.pi
	assert math.abs(f64(a) - want) < 0.06, '${a} ${want}'
	w0, h0 := crop_frame(st)
	assert st.edit.geom.fits(st.edit.geom.box_of(w0, h0), w0, h0)
	crop_input(mut st, crop_ev(.pointer_up, 260, 160, false))
	assert st.crop_drag.kind == .none
	assert st.history.len == 2 && st.history[1].name.starts_with('Поворот:')
	assert st.history[1].state.geom.angle == a
	// Ctrl снаружи - новая рамка
	crop_input(mut st, crop_ev(.pointer_down, 60, 100, true))
	assert st.crop_drag.kind == .handle
	crop_input(mut st, crop_ev(.pointer_move, 90, 130, true))
	crop_input(mut st, crop_ev(.pointer_up, 90, 130, true))
	assert st.edit.geom.angle == a
	assert st.history.last().name == 'Кадрирование: рамка'
}

// Угол вручную: разбор ввода и применение (ограничение ±45, запись)
fn test_angle_input() {
	assert parse_angle('-2.5')? == -2.5
	assert parse_angle(' −2,5° ')? == -2.5
	assert parse_angle('+3')? == 3
	assert parse_angle('-3ю5')? == -3.5 && parse_angle('1б5')? == 1.5
	assert parse_angle('0')? == 0
	for bad in ['', 'abc', '-', '1.2.3', '--2', '2-', '.'] {
		if _ := parse_angle(bad) {
			assert false, bad
		}
	}
	mut st := crop_state()
	start_history(mut st)
	set_angle_text(mut st, '7.25')
	assert math.abs(st.edit.geom.angle - 7.3) < 1e-4 || math.abs(st.edit.geom.angle - 7.2) < 1e-4
	assert st.history.len == 2 && st.history[1].name.starts_with('Угол:')
	w0, h0 := crop_frame(st)
	assert st.edit.geom.fits(st.edit.geom.box_of(w0, h0), w0, h0)
	set_angle_text(mut st, '90')
	assert st.edit.geom.angle == 45
	set_angle_text(mut st, 'x')
	assert st.edit.geom.angle == 45 && st.history.len == 3
}
