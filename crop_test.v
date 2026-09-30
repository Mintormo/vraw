module main

import os
import math
import pipeline

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
