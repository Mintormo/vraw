module develop

import os
import raw

fn test_params_mapping() {
	mut s := neutral()
	s.exposure = 0.7
	s.eq[2] = -0.5
	s.hsl_sat[3] = 40
	s.curves[1] = [Point{0, 0}, Point{0.5, 0.7}, Point{1, 1}]
	cam := []f32{len: 256, init: f32(index)}
	p := s.params(cam)
	assert p.exposure == 0.7
	assert p.eq[2] == -0.5
	assert p.hsl_sat[3] == 40
	assert p.saturation == 1
	assert p.curve.len == 256
	assert p.tc_rgb.len == 0 // диагональ - кривой нет
	assert p.tc_r.len == 256
	assert p.tc_r[128] > 128 * 1.2 // точка (0.5, 0.7) поднимает середину
	assert p.dither
	s.use_curve = false
	assert s.params(cam).curve.len == 0
}

fn test_curve_lut_basics() {
	id := curve_lut(identity_points(), 5)
	assert id == [f32(0), 0.25, 0.5, 0.75, 1]
	// Монотонность: сплайн не выходит за соседние точки
	l := curve_lut([Point{0, 0}, Point{0.3, 0.6}, Point{0.6, 0.65}, Point{1, 1}], 256)
	for i in 1 .. 256 {
		assert l[i] >= l[i - 1]
	}
	assert is_identity(identity_points())
	assert !is_identity([Point{0, 0.1}, Point{1, 1}])
}

fn test_sidecar_roundtrip_and_validation() {
	mut s := neutral()
	s.exposure = 1.25
	s.nr[1] = 35
	f := File{
		state:        s
		current:      1
		history:      [Entry{
			name:  'Открыт файл'
			state: neutral()
		}, Entry{
			name:  'Экспозиция +1.25'
			key:   'Экспозиция'
			state: s
		}]
		camera_curve: []f32{len: 256, init: f32(index)}
	}
	g := decode(encode(f))!
	assert g.current == 1
	assert g.state.exposure == 1.25
	assert g.state.nr[1] == 35
	assert g.history[1].name == 'Экспозиция +1.25'
	assert g.camera_curve.len == 256
	// Испорченное - ошибка
	if _ := decode('{"app": "vraw", "version": 1, "current": 5, "history": []}') {
		assert false
	}
	if _ := decode(encode(f).replace('"camera_curve": [', '"camera_curve": [1, ')) {
		assert false
	}
	mut bad := f
	bad.state.nr = [f32(1)]
	if _ := decode(encode(bad)) {
		assert false
	}
}

// Проявка тестового CR3 в половинном размере: экспозиция +1 EV светлее
// нейтральной, камерная кривая считается сама (256 узлов)
fn test_full_half() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut d := raw.open(path)!
	cam := camera_curve(mut d, neutral(), unsafe { nil })
	d.close()
	assert cam.len == 256
	mut s0 := neutral()
	s0.lens_corr = false
	n := full(path, s0, half: true, cam_curve: cam)!
	mut s := s0
	s.exposure = 1
	b := full(path, s, half: true, cam_curve: cam)!
	assert n.width == b.width && n.rgb.len == n.width * n.height * 3
	mut sn := u64(0)
	mut sb := u64(0)
	for i in 0 .. n.rgb.len {
		sn += n.rgb[i]
		sb += b.rgb[i]
	}
	assert sb > sn * 11 / 10
}
