module pipeline

import math

// Перспектива (persp.v): тождество, центр и заполнение без пустых углов,
// направление ползунков, ориентация, выборка без чёрных краёв, подбор по
// двум линиям

// Ширина выхода в источнике: расстояние между образами двух точек строки
fn persp_span(p Proj, x0 f64, x1 f64, y f64) f64 {
	ax, ay := p.at(x0, y)
	bx, by := p.at(x1, y)
	return math.hypot(bx - ax, by - ay)
}

fn test_persp_plan_fill_and_center() {
	w0, h0 := 600.0, 400.0
	assert !Geom{}.has_persp()
	for pv in [f32(-100), -40, 0, 35, 100] {
		for ph in [f32(-60), 0, 80] {
			g := Geom{
				pv: pv
				ph: ph
			}
			p := persp_plan(g, w0, h0)
			// Центр выхода - в центр кадра
			cx, cy := p.at(w0 / 2, h0 / 2)
			assert math.abs(cx - w0 / 2) < 1e-6 && math.abs(cy - h0 / 2) < 1e-6
			// Углы внутри кадра, хотя бы один - на краю (наибольшее увеличение)
			mut edge := false
			for c in [[0.0, 0.0], [w0, 0.0], [0.0, h0], [w0, h0]] {
				x, y := p.at(c[0], c[1])
				assert x >= -1e-3 && y >= -1e-3 && x <= w0 + 1e-3 && y <= h0 + 1e-3
				if x < 0.01 || y < 0.01 || x > w0 - 0.01 || y > h0 - 0.01 {
					edge = true
				}
			}
			assert edge
		}
	}
	// Без перспективы - тождество
	p0 := persp_plan(Geom{}, w0, h0)
	x, y := p0.at(123, 45)
	assert math.abs(x - 123) < 1e-9 && math.abs(y - 45) < 1e-9
}

fn test_persp_direction() {
	w0, h0 := 600.0, 400.0
	// «Вертикаль» минус - верх шире: верхняя строка выхода берёт из кадра
	// меньший отрезок, чем нижняя (растянута); плюс - наоборот
	up := persp_plan(Geom{ pv: -50 }, w0, h0)
	assert persp_span(up, 0, w0, 0) < persp_span(up, 0, w0, h0) * 0.9
	dn := persp_plan(Geom{ pv: 50 }, w0, h0)
	assert persp_span(dn, 0, w0, 0) > persp_span(dn, 0, w0, h0) * 1.1
	// «Горизонталь» минус - левый край выше (шире)
	lf := persp_plan(Geom{ ph: -50 }, w0, h0)
	la, lb := lf.at(0, 0)
	lc, ld := lf.at(0, h0)
	ra, rb := lf.at(w0, 0)
	rc, rd := lf.at(w0, h0)
	assert math.hypot(lc - la, ld - lb) < math.hypot(rc - ra, rd - rb) * 0.9
}

// geom_apply с перспективой: ровное поле без чёрных краёв, размер выхода
// прежний, «Вертикаль» на повёрнутом на 90° кадре - вертикаль показа
fn test_persp_apply() {
	w, h := 90, 60
	src := []u16{len: w * h * 3, init: 30000}
	g := Geom{
		pv: -60
		ph: 25
	}
	out, ow, oh := geom_apply(unsafe { &u16(src.data) }, w, h, 3, g, true)
	assert ow == w && oh == h
	for v in out {
		assert v == 30000
	}
	// Кадр, повёрнутый на 90°: в выходе (показ, h x w) верх шире низа -
	// по плоскости 10·y + x источника ширина образа строки показа
	r := geom_proj(Geom{ rot90: 1, pv: -50 }, w, h, true, h, w)
	assert persp_span(r, 0, f64(h), 0) < persp_span(r, 0, f64(h), f64(w)) * 0.9
}

// Фрагмент с перспективой (и поворотом, кадрированием) - побитово вырезка
// полного прохода
fn test_persp_region() {
	w, h, ch := 120, 80, 3
	mut src := []u16{len: w * h * ch}
	for i in 0 .. src.len {
		src[i] = u16((i * 37) % 60000)
	}
	g := Geom{
		pv:    -45
		ph:    20
		angle: 3
		x0:    0.1
		y0:    0.05
		x1:    0.9
		y1:    0.95
	}
	full, ow, _ := geom_apply(unsafe { &u16(src.data) }, w, h, ch, g, true)
	r := Region{13, 9, 40, 30}
	sb := geom_source_box(g, w, h, true, r)
	mut part := []u16{len: sb.w * sb.h * ch}
	for j in 0 .. sb.h {
		for i in 0 .. sb.w * ch {
			part[j * sb.w * ch + i] = src[((sb.y + j) * w + sb.x) * ch + i]
		}
	}
	got := geom_apply_region(unsafe { &u16(part.data) }, sb, w, h, ch, g, true, r)
	for j in 0 .. r.h {
		for i in 0 .. r.w * ch {
			assert got[j * r.w * ch + i] == full[((r.y + j) * ow + r.x) * ch + i]
		}
	}
}

// Линии на выходе (R) вертикальны / горизонтальны при поправке g: те же
// линии на снимке (V) - подбор возвращает g
fn persp_lines_of(g Geom, w0 f64, h0 f64, rl [][]f64) [][]f64 {
	p := persp_plan(g, w0, h0)
	mut out := [][]f64{}
	for l in rl {
		ax, ay := g.r_to_v(l[0], l[1], w0, h0)
		bx, by := g.r_to_v(l[2], l[3], w0, h0)
		cx, cy := p.at(ax, ay)
		dx, dy := p.at(bx, by)
		out << [cx, cy, dx, dy]
	}
	return out
}

fn test_persp_lines() {
	w0, h0 := 600.0, 400.0
	verts := [[150.0, 60, 150, 340], [470.0, 60, 470, 340]]
	hors := [[40.0, 80, 560, 80], [40.0, 330, 560, 330]]
	// Две вертикали: «Вертикаль» и наклон, «Горизонталь» - прежняя
	gv := Geom{
		pv:    -37
		ph:    5
		angle: 3
	}
	fv := persp_lines(persp_lines_of(gv, w0, h0, verts), w0, h0, Geom{ ph: 5 })
	assert math.abs(fv.pv - gv.pv) < 1 && math.abs(fv.angle - gv.angle) < 0.2 && fv.ph == 5, '${fv}'
	// Две горизонтали: «Горизонталь» и наклон
	gh := Geom{
		ph:    25
		angle: -2
	}
	fh := persp_lines(persp_lines_of(gh, w0, h0, hors), w0, h0, Geom{})
	assert math.abs(fh.ph - gh.ph) < 1 && math.abs(fh.angle - gh.angle) < 0.2 && fh.pv == 0, '${fh}'
	// Вертикаль и горизонталь: обе перспективы, наклон 0
	gm := Geom{
		pv: -20
		ph: 15
	}
	fm := persp_lines(persp_lines_of(gm, w0, h0, [verts[0], hors[1]]), w0, h0, Geom{
		angle: 7
	})
	assert math.abs(fm.pv - gm.pv) < 1.5 && math.abs(fm.ph - gm.ph) < 1.5 && fm.angle == 0, '${fm}'
}
