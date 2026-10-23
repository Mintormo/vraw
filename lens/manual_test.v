module lens

import math
import pipeline { Region }

// gradient_frame - кадр w x h с плавным, разным по каналам рисунком
fn gradient_frame(w int, h int) []u16 {
	mut b := []u16{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			i := (y * w + x) * 3
			b[i] = u16(1000 + x * 37 + y * 11)
			b[i + 1] = u16(2000 + int(800 * math.sin(f64(x) / 9) * math.cos(f64(y) / 7)) + 1000)
			b[i + 2] = u16(500 + (x * y) % 3000)
		}
	}
	return b
}

fn test_manual_inactive() {
	m := Manual{}
	assert !m.active()
	assert m.key() == '-'
	mut b := []u16{len: 30 * 20 * 3, init: 1234}
	assert !manual_correct(unsafe { &u16(b.data) }, 30, 20, m)
	assert b.all(it == 1234)
	if _ := manual_plan(Manual{ vign: 30 }, 30, 20) {
		assert false, 'виньетирование без ремапа'
	}
}

fn test_manual_scale_no_empty_edges() {
	w := 300
	h := 200
	// Бочка (плюс) - кадр увеличивается, подушка (минус) - уменьшается
	pb := manual_plan(Manual{ dist: 100 }, w, h) or { panic('нет плана') }
	assert pb.s > 1
	pp := manual_plan(Manual{ dist: -100 }, w, h) or { panic('нет плана') }
	assert pp.s < 1
	for m in [Manual{
		dist: 100
	}, Manual{
		dist: -100
	}, Manual{
		ca_r: 100
		ca_b: -100
	}, Manual{
		dist: -40
		ca_r: -70
	}] {
		p := manual_plan(m, w, h) or { panic('нет плана') }
		assert p.border_inside()
		// Центр неподвижен у зелёного канала
		x, y := p.at(1, p.cx, p.cy)
		assert math.abs(x - p.cx) < 1e-9 && math.abs(y - p.cy) < 1e-9
		// Хотя бы один край выхода на краю источника (масштаб наибольший)
		mut edge := 0.0
		for c in 0 .. 3 {
			for pt in [[0.0, 0.0], [f64(w - 1), 0.0], [0.0, p.cy], [p.cx, 0.0]] {
				sx, sy := p.at(c, pt[0], pt[1])
				edge = math.max(edge, math.max(math.abs(sx - p.cx) / p.cx, math.abs(sy - p.cy) / p.cy))
			}
		}
		assert edge > 0.995, '${m}: ${edge}'
	}
	// Ровное поле остаётся ровным - без чёрных краёв
	mut b := []u16{len: w * h * 3, init: 20000}
	assert manual_correct(unsafe { &u16(b.data) }, w, h, Manual{ dist: -60, ca_b: 50 })
	assert b.all(it == 20000)
}

fn test_manual_ca_moves_channels() {
	w := 300
	h := 200
	p := manual_plan(Manual{ ca_r: 100 }, w, h) or { panic('нет плана') }
	// Красный читает дальше от центра, чем зелёный, синий - как зелёный
	rx, _ := p.at(0, f64(w - 1), p.cy)
	gx, _ := p.at(1, f64(w - 1), p.cy)
	bx, _ := p.at(2, f64(w - 1), p.cy)
	assert rx > gx + 0.1
	assert math.abs(bx - gx) < 1e-9
}

fn test_manual_region_matches_full() {
	w := 240
	h := 160
	m := Manual{
		dist:     -35
		vign:     60
		vign_mid: 30
		ca_r:     40
		ca_b:     -25
	}
	src := gradient_frame(w, h)
	mut full := src.clone()
	assert manual_correct(unsafe { &u16(full.data) }, w, h, m)
	p := manual_plan(m, w, h) or { panic('нет плана') }
	lut := manual_vign_lut(m)
	for r in [Region{0, 0, 37, 29}, Region{100, 60, 50, 40}, Region{200, 120, 40, 40},
		Region{0, 0, w, h}] {
		sb := p.source_box(r)
		mut piece := pipeline.crop_region(unsafe { &u16(src.data) }, w, 3, sb)
		manual_vign_region(unsafe { &u16(piece.data) }, sb, w, h, lut)
		mut out := []u16{len: r.w * r.h * 3}
		p.remap(unsafe { &u16(piece.data) }, sb, r, unsafe { &u16(out.data) })
		for j in 0 .. r.h {
			for i in 0 .. r.w {
				for c in 0 .. 3 {
					a := out[(j * r.w + i) * 3 + c]
					b := full[((r.y + j) * w + r.x + i) * 3 + c]
					assert a == b, '${r} (${i}, ${j}) канал ${c}: ${a} != ${b}'
				}
			}
		}
	}
}

fn test_manual_vignetting() {
	w := 201
	h := 101
	mut b := []u16{len: w * h * 3, init: 8000}
	assert manual_correct(unsafe { &u16(b.data) }, w, h, Manual{ vign: 100 })
	// Центр не тронут, угол - +2 EV (x4), к краю растёт
	c := b[((h / 2) * w + w / 2) * 3]
	assert c == 8000
	corner := b[0]
	assert corner > 31000 && corner <= 32000, '${corner}'
	mut prev := u16(0)
	for x in w / 2 .. w {
		v := b[((h / 2) * w + x) * 3]
		assert v >= prev
		prev = v
	}
	// Минус затемняет, средняя точка дальше - спад ближе к углу
	mut d := []u16{len: w * h * 3, init: 8000}
	manual_correct(unsafe { &u16(d.data) }, w, h, Manual{ vign: -100 })
	assert d[0] < 2100
	lo := manual_vign_lut(Manual{ vign: 50, vign_mid: 20 })
	hi := manual_vign_lut(Manual{ vign: 50, vign_mid: 80 })
	assert lo[vign_lut_n / 2] > hi[vign_lut_n / 2]
	assert math.abs(lo[vign_lut_n - 1] - hi[vign_lut_n - 1]) < 1e-4
}
