module main

import os
import math
import json2
import pipeline

fn sample_spots() []pipeline.Spot {
	return [
		pipeline.Spot{
			x:  0.3
			y:  0.4
			sx: 0.35
			sy: 0.4
			r:  0.01
		},
		pipeline.Spot{
			x:       0.7
			y:       0.2
			sx:      0.7
			sy:      0.25
			r:       0.02
			feather: 10
			opacity: 80
			mode:    .clone
		},
	]
}

// Сайдкар: пятна туда и обратно, старый файл без поля, чужие значения - в
// пределах
fn test_sidecar_spots() {
	mut e := neutral_edit()
	e.spots = sample_spots()
	back := edit_state(json2.decode[SideState](json2.encode(side_state(e)))!)!
	assert back.spots == e.spots
	o := edit_state(json2.decode[SideState](json2.encode(side_state(neutral_edit())).replace(',"spots":[]',
		''))!)!
	assert o.spots.len == 0
	bad := SideState{
		...side_state(e)
		spots: [SideSpot{
			x:       1.5
			y:       -1
			r:       3
			feather: 200
			opacity: -5
			mode:    'что-то'
		}]
	}
	s := edit_state(bad)!.spots[0]
	assert s.x == 1 && s.y == 0 && s.r == pipeline.spot_r_max
	assert s.feather == 100 && s.opacity == 0 && s.mode == .heal
}

// Снимок истории не делит массив пятен; группа «Удаление пятен» заменяет
// пятна целиком и по умолчанию не копируется
fn test_spots_clone_and_group() {
	mut e := neutral_edit()
	e.spots = sample_spots()
	c := e.clone()
	e.spots[0].r = 0.05
	assert c.spots[0].r == 0.01
	assert 'spots' in copy_groups && 'spots' !in default_copy_groups
	assert copy_groups.len == copy_group_names.len
	mut dst := neutral_edit()
	dst.spots = [pipeline.Spot{}]
	assert merge_groups(dst, e, ['tone']).spots.len == 1
	assert merge_groups(dst, e, ['spots']).spots == e.spots
}

// Размер ползунка <-> радиус; перетаскивание: перенос, источник, размер
fn test_spot_drag() {
	for v in [f32(1), 20, 50, 100] {
		assert math.abs(spot_size_of(spot_radius(v)) - v) < 0.01
	}
	s := sample_spots()[0]
	ar := 1.5
	d := SpotDrag{
		kind:  .dest
		start: s
		px:    f64(s.x) * ar
		py:    f64(s.y)
	}
	m := drag_spot(d, f64(s.x) * ar + 0.15, f64(s.y) + 0.1, ar)
	assert math.abs(m.x - (s.x + 0.1)) < 1e-6 && math.abs(m.y - (s.y + 0.1)) < 1e-6
	assert m.sx == s.sx && m.sy == s.sy // источник на месте
	q := drag_spot(SpotDrag{ ...d, kind: .source }, f64(s.x) * ar + 0.15, f64(s.y), ar)
	assert math.abs(q.sx - (s.sx + 0.1)) < 1e-6 && q.x == s.x
	z := drag_spot(SpotDrag{ ...d, kind: .size }, f64(s.x) * ar + 0.03, f64(s.y) + 0.04, ar)
	assert math.abs(z.r - 0.05) < 1e-6
}

// Экспорт: клонирование тёмного участка светлым меняет только круг пятна
fn test_develop_full_spot() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut e0 := neutral_edit()
	e0.lens_corr = false
	e0.params.dither = false
	n := develop_full(path, with_derived(e0, CamLook{}, pipeline.CamColor{}), unsafe { nil })!
	mut e1 := e0.clone()
	e1.spots << pipeline.Spot{
		x:       0.5
		y:       0.5
		sx:      0.2
		sy:      0.3
		r:       0.05
		feather: 0
		mode:    .clone
	}
	b := develop_full(path, with_derived(e1, CamLook{}, pipeline.CamColor{}), unsafe { nil })!
	assert n.width == b.width && n.height == b.height
	w := n.width
	h := n.height
	r := 0.05 * f64(h)
	mut inside := 0
	mut same_in := 0
	for y := 0; y < h; y += 3 {
		for x := 0; x < w; x += 3 {
			d := math.hypot(f64(x) + 0.5 - 0.5 * f64(w), f64(y) + 0.5 - 0.5 * f64(h))
			i := (y * w + x) * 3
			if d > r + 2 {
				assert n.rgb[i] == b.rgb[i] && n.rgb[i + 1] == b.rgb[i + 1]
			} else if d < r - 2 {
				inside++
				// Внутри - пиксель источника (сдвиг на целые пиксели)
				sx := x + int(math.round((0.2 - 0.5) * f64(w)))
				sy := y + int(math.round((0.3 - 0.5) * f64(h)))
				if b.rgb[i + 1] == n.rgb[(sy * w + sx) * 3 + 1] {
					same_in++
				}
			}
		}
	}
	assert inside > 100
	assert same_in == inside
}
