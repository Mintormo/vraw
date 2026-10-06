module main

import math
import json2
import pipeline

fn sample_masks() []pipeline.Mask {
	return [
		pipeline.Mask{
			kind:     .linear
			ax:       0.5
			ay:       0.1
			bx:       0.6
			by:       0.5
			exposure: -1.25
			temp:     20
		},
		pipeline.Mask{
			kind:       .radial
			on:         false
			ax:         0.4
			ay:         0.6
			rx:         0.3
			ry:         0.2
			angle:      -30
			feather:    80
			invert:     true
			contrast:   15
			highlights: -40
			shadows:    35
			saturation: -10
			tint:       5
			lum_on:     true
			lum_lo:     40
			lum_hi:     90
			lum_soft:   7
			col_on:     true
			hue:        215
			hue_w:      25
		},
	]
}

// Фильтры в сайдкаре: через JSON и обратно - те же; старый файл - без них
fn test_sidecar_masks() {
	mut e := neutral_edit()
	e.params.masks = sample_masks()
	text := json2.encode(side_state(e))
	back := edit_state(json2.decode[SideState](text)!)!
	assert back.params.masks == e.params.masks
	o := edit_state(json2.decode[SideState](json2.encode(side_state(neutral_edit())).replace(',"masks":[]',
		''))!)!
	assert o.params.masks.len == 0
	// Чужие значения - в пределах ползунков
	mut bad := side_state(e)
	bad = SideState{
		...bad
		masks: [SideMask{
			kind:     'radial'
			exposure: 99
			rx:       0.2
			ry:       0.2
		}]
	}
	assert edit_state(bad)!.params.masks[0].exposure == 4
	// Файл до ограничения диапазоном: поля нулевые - значения по умолчанию
	old := edit_state(SideState{
		...bad
		masks: [SideMask{
			kind: 'linear'
			by:   1
		}]
	})!.params.masks[0]
	assert !old.lum_on && old.lum_hi == 100 && old.lum_soft == 10 && old.hue_w == 30
}

// Снимок истории не делит массив фильтров с живым состоянием; группа
// «Градиентные фильтры» заменяет фильтры целиком и по умолчанию не
// копируется
fn test_masks_clone_and_group() {
	mut e := neutral_edit()
	e.params.masks = sample_masks()
	c := e.clone()
	e.params.masks[0].exposure = 3
	assert c.params.masks[0].exposure == -1.25
	assert 'masks' in copy_groups && 'masks' !in default_copy_groups
	mut dst := neutral_edit()
	dst.params.masks = [pipeline.Mask{
		kind: .radial
	}]
	assert merge_groups(dst, e, ['tone']).params.masks.len == 1
	m := merge_groups(dst, e, ['masks'])
	assert m.params.masks == e.params.masks
}

// Холст <-> кадр: обратное отображение, в том числе под поворотом
fn test_mask_view_map() {
	for g in [pipeline.Geom{}, pipeline.Geom{
		rot90: 1
		angle: 7
		x0:    0.1
		y0:    0.05
		x1:    0.8
		y1:    0.9
	}] {
		ow, oh := g.out_size(600, 400, true)
		mm := pipeline.mask_map(g, 600, 400, true, ow, oh)
		for p in [[f64(0), 0], [123.4, 56.7], [f64(ow), f64(oh)]] {
			x, y := buf_to_m(mm, p[0], p[1])
			bx, by := m_to_buf(mm, x, y)
			assert math.abs(bx - p[0]) < 1e-6 && math.abs(by - p[1]) < 1e-6
		}
	}
}

// Ручки: конец полуоси задаёт радиус и поворот, перенос сдвигает обе точки
fn test_drag_mask() {
	ar := 1.5
	r := pipeline.Mask{
		kind: .radial
		ax:   0.5
		ay:   0.5
		rx:   0.2
		ry:   0.1
	}
	// Ось rx за конец на -1: курсор слева от центра на 0.3 - радиус 0.3, угол 0
	m := drag_mask(MaskDrag{
		kind:  .axis
		sign:  -1
		start: r
	}, 0.75 - 0.3, 0.5, ar)
	assert math.abs(m.rx - 0.3) < 1e-6 && math.abs(m.angle) < 1e-4 && m.ry == 0.1
	// Ось ry вниз от центра: поворот 0, курсор под углом 45° - поворот -45
	m2 := drag_mask(MaskDrag{
		kind:  .axis
		ry:    true
		sign:  1
		start: r
	}, 0.75 + 0.1, 0.5 + 0.1, ar)
	assert math.abs(m2.angle + 45) < 1e-3 && math.abs(m2.ry - math.sqrt2 * 0.1) < 1e-6
	l := pipeline.Mask{
		kind: .linear
		ax:   0.2
		ay:   0.1
		bx:   0.2
		by:   0.5
	}
	mv := drag_mask(MaskDrag{
		kind:  .move
		start: l
		px:    0.3
		py:    0.3
	}, 0.3 + 0.15, 0.3 + 0.05, ar)
	assert math.abs(mv.ax - 0.3) < 1e-6 && math.abs(mv.bx - 0.3) < 1e-6
	assert math.abs(mv.ay - 0.15) < 1e-6 && math.abs(mv.by - 0.55) < 1e-6
}
