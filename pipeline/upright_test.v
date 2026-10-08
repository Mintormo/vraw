module pipeline

import math

// facade - «фасад» w x h: светлые полосы-простенки и тёмные окна (сетка
// вертикалей и горизонталей), RGB u16
fn facade(w int, h int) []u16 {
	mut b := []u16{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			col := (x / 60) % 2 == 0 && x % 60 > 8
			row := (y / 50) % 2 == 0 && y % 50 > 6
			v := if col && row { u16(4000) } else { u16(30000) }
			i := (y * w + x) * 3
			b[i] = v
			b[i + 1] = v
			b[i + 2] = v
		}
	}
	return b
}

// warped - фасад, снятый с перспективой g (обратное исправление: кадр,
// который g превратил бы в ровный фасад, - это ровный фасад через
// обратный поворот камеры)
fn warped(w int, h int, g Geom) []u16 {
	src := facade(w, h)
	out, _, _ := geom_apply(unsafe { &u16(src.data) }, w, h, 3, g, false)
	return out
}

fn test_line_segments_simple() {
	w := 400
	h := 300
	mut lum := []f32{len: w * h}
	// Вертикальная граница на x = 200, наклонная на 10° - в правой части
	for y in 0 .. h {
		for x in 0 .. w {
			mut v := f32(30)
			if x >= 200 {
				v = 200
			}
			lum[y * w + x] = v
		}
	}
	segs := line_segments(lum, w, h)
	assert segs.len >= 1
	mut found := false
	for s in segs {
		if s.len() > 200 && math.abs(s.x0 - 200) < 1.5 && math.abs(s.x1 - 200) < 1.5 {
			found = true
		}
	}
	assert found, '${segs}'
}

fn test_upright_vertical_recovers() {
	w := 900
	h := 600
	// Снято снизу: вертикали сходятся (обратная перспектива pv = -25)
	for want in [f32(25), -18] {
		img := warped(w, h, Geom{
			pv: -want
		})
		segs := upright_segments(unsafe { &u16(img.data) }, w, h, Geom{})
		assert segs.len > 10
		fit := upright_fit(segs, w, h, .vertical) or { panic('нет линий') }
		assert math.abs(fit.pv - want) < 2.0, 'ждали ${want}: ${fit}'
		assert math.abs(fit.angle) < 0.5, '${fit}'
		assert fit.ph == 0
	}
}

fn test_upright_level_and_full() {
	w := 900
	h := 600
	// Наклон кадра на 3°: «Уровень» возвращает его
	img := warped(w, h, Geom{
		angle: 3
	})
	segs := upright_segments(unsafe { &u16(img.data) }, w, h, Geom{})
	fit := upright_fit(segs, w, h, .level) or { panic('нет линий') }
	assert math.abs(fit.angle + 3) < 0.3, '${fit}'
	assert fit.pv == 0 && fit.ph == 0
	// Повёрнуто вбок: «Полностью» находит «Горизонталь»
	img2 := warped(w, h, Geom{
		ph: 20
	})
	segs2 := upright_segments(unsafe { &u16(img2.data) }, w, h, Geom{})
	fit2 := upright_fit(segs2, w, h, .full) or { panic('нет линий') }
	assert math.abs(fit2.ph + 20) < 2.5, '${fit2}'
	assert math.abs(fit2.pv) < 2.5, '${fit2}'
	assert math.abs(fit2.angle) < 0.5, '${fit2}'
}

fn test_upright_orientation() {
	// Кадр, повёрнутый на 90°: линии - в координатах показа (V)
	w := 600
	h := 900
	g := Geom{
		rot90: 1
	}
	// Ровный фасад в показе - в S это фасад, повёрнутый обратно
	img := warped(h, w, Geom{
		pv: -20
	})
	mut s := []u16{len: w * h * 3}
	// V (h x w) - S (w x h), повёрнутый по часовой (Geom.v_to_s):
	// V(x, y) = S(y, h - 1 - x)
	for y in 0 .. w {
		for x in 0 .. h {
			sx := y
			sy := h - 1 - x
			for c in 0 .. 3 {
				s[(sy * w + sx) * 3 + c] = img[(y * h + x) * 3 + c]
			}
		}
	}
	segs := upright_segments(unsafe { &u16(s.data) }, w, h, g)
	fit := upright_fit(segs, h, w, .vertical) or { panic('нет линий') }
	assert math.abs(fit.pv - 20) < 2.0, '${fit}'
}

fn test_upright_no_lines() {
	w := 300
	h := 200
	flat := []u16{len: w * h * 3, init: 20000}
	segs := upright_segments(unsafe { &u16(flat.data) }, w, h, Geom{})
	assert segs.len == 0
	if _ := upright_fit(segs, w, h, .vertical) {
		assert false
	}
}
