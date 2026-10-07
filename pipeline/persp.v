module pipeline

// Перспектива (Geom.pv, Geom.ph): поворот плоскости снимка, как будто
// камеру наклонили или повернули, - сходящиеся вертикали становятся
// параллельными. Модель - камера, повёрнутая вокруг своего центра:
// H = K·R·K⁻¹ (K - фокусное f = длинная сторона кадра, центр - центр
// кадра), затем сдвиг и увеличение так, чтобы центр выхода смотрел в
// центр кадра, а пустых углов не было (наибольшее k, при котором все
// четыре угла выхода попадают в кадр).
//
// Отображение действует в V (после поворотов на 90° и отражений, до
// наклона angle): «вертикаль» - вертикаль показа при любой ориентации.
import math

// persp_max - поворот плоскости при ±100, радианы (30°)
const persp_max = math.pi / 6

// Proj - проективное отображение точки (x, y):
// x' = (m0·x + m1·y + m2) / (m6·x + m7·y + m8), y' - то же с m3, m4, m5
struct Proj {
	m [9]f64
}

fn (p Proj) at(x f64, y f64) (f64, f64) {
	d := p.m[6] * x + p.m[7] * y + p.m[8]
	return (p.m[0] * x + p.m[1] * y + p.m[2]) / d, (p.m[3] * x + p.m[4] * y + p.m[5]) / d
}

// then - сначала p, затем q (матрица q·p)
fn (p Proj) then(q Proj) Proj {
	mut r := [9]f64{}
	for i in 0 .. 3 {
		for j in 0 .. 3 {
			mut v := 0.0
			for k in 0 .. 3 {
				v += q.m[i * 3 + k] * p.m[k * 3 + j]
			}
			r[i * 3 + j] = v
		}
	}
	return Proj{
		m: r
	}
}

// proj_affine - аффинное отображение по трём точкам: f(0, 0), f(1, 0),
// f(0, 1)
fn proj_affine(f fn (f64, f64) (f64, f64)) Proj {
	x00, y00 := f(0, 0)
	x10, y10 := f(1, 0)
	x01, y01 := f(0, 1)
	return Proj{
		m: [x10 - x00, x01 - x00, x00, y10 - y00, y01 - y00, y00, 0, 0, 1]!
	}
}

// persp_rot - поворот R = Ry(φ)·Rx(θ) по ползункам; inv - обратный (Rᵀ)
fn persp_rot(g Geom, inv bool) [9]f64 {
	// Минус «Вертикали» - верх шире (наклон назад), минус «Горизонтали» -
	// левый край шире
	t := f64(g.pv) / 100 * persp_max
	p := -f64(g.ph) / 100 * persp_max
	ct := math.cos(t)
	st := math.sin(t)
	cp := math.cos(p)
	sp := math.sin(p)
	// Ry = [[cp, 0, sp], [0, 1, 0], [-sp, 0, cp]],
	// Rx = [[1, 0, 0], [0, ct, -st], [0, st, ct]]
	r := [cp, sp * st, sp * ct, 0, ct, -st, -sp, cp * st, cp * ct]!
	if !inv {
		return r
	}
	return [r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]]!
}

// persp_cam - K·R·K⁻¹ для кадра w0 x h0 (пиксели V)
fn persp_cam(g Geom, w0 f64, h0 f64, inv bool) Proj {
	f := math.max(w0, h0)
	cx := w0 / 2
	cy := h0 / 2
	r := persp_rot(g, inv)
	kinv := Proj{
		m: [1 / f, 0, -cx / f, 0, 1 / f, -cy / f, 0, 0, 1]!
	}
	k := Proj{
		m: [f, 0, cx, 0, f, cy, 0, 0, 1]!
	}
	return kinv.then(Proj{ m: r }).then(k)
}

// persp_plan - V' -> V (пиксели кадра w0 x h0): центр выхода смотрит в
// центр кадра, увеличение - наибольшее без пустых углов
pub fn persp_plan(g Geom, w0 f64, h0 f64) Proj {
	cx := w0 / 2
	cy := h0 / 2
	h := persp_cam(g, w0, h0, false)
	ux, uy := persp_cam(g, w0, h0, true).at(cx, cy)
	plan := fn [h, cx, cy, ux, uy] (k f64) Proj {
		t := Proj{
			m: [k, 0, ux - k * cx, 0, k, uy - k * cy, 0, 0, 1]!
		}
		return t.then(h)
	}
	inside := fn [plan, w0, h0] (k f64) bool {
		p := plan(k)
		for c in [[0.0, 0.0], [w0, 0.0], [0.0, h0], [w0, h0]] {
			x, y := p.at(c[0], c[1])
			if x < -1e-9 || y < -1e-9 || x > w0 + 1e-9 || y > h0 + 1e-9 {
				return false
			}
		}
		return true
	}
	mut lo := 0.01
	mut hi := 4.0
	for _ in 0 .. 50 {
		mid := (lo + hi) / 2
		if inside(mid) {
			lo = mid
		} else {
			hi = mid
		}
	}
	return plan(lo)
}

// geom_proj - отображение выхода ow x oh в источник w x h (как
// geom_affine, но с перспективой): выход -> V' (аффинное, через R) ->
// V (persp_plan) -> S (аффинное)
fn geom_proj(g Geom, w int, h int, crop bool, ow int, oh int) Proj {
	w0, h0 := g.oriented(w, h)
	fw0 := f64(w0)
	fh0 := f64(h0)
	rx0 := if crop { f64(g.x0) * fw0 } else { 0.0 }
	ry0 := if crop { f64(g.y0) * fh0 } else { 0.0 }
	rw := if crop { f64(g.x1 - g.x0) * fw0 } else { fw0 }
	rh := if crop { f64(g.y1 - g.y0) * fh0 } else { fh0 }
	to_v := proj_affine(fn [g, rx0, ry0, rw, rh, ow, oh, fw0, fh0] (i f64, j f64) (f64, f64) {
		return g.r_to_v(rx0 + (i + 0.5) * rw / f64(ow), ry0 + (j + 0.5) * rh / f64(oh), fw0,
			fh0)
	})
	to_s := proj_affine(fn [g, w, h, fw0, fh0] (x f64, y f64) (f64, f64) {
		s, t := g.v_to_s(x / fw0, y / fh0)
		return s * f64(w), t * f64(h)
	})
	if !g.has_persp() {
		return to_v.then(to_s)
	}
	return to_v.then(persp_plan(g, fw0, fh0)).then(to_s)
}

// PerspCtx - выборка с перспективой (общий для потоков; строки выхода
// j0..j1 - у каждого свои): источник - кусок sb кадра w x h
struct PerspCtx {
	src &u16 = unsafe { nil }
	sb  Region
	w   int
	h   int
	ch  int
	p   Proj
	dst &u16 = unsafe { nil }
	r   Region // прямоугольник выхода
}

// persp_apply - прямоугольник r выхода (по p) из куска sb источника
// w x h, билинейно; потоки - полосами строк. Пиксель считается сам по
// себе (без накопления) - фрагмент побитово равен вырезке полного прохода
fn persp_apply(src &u16, sb Region, w int, h int, ch int, p Proj, r Region, dst &u16) {
	pc := PerspCtx{
		src: src
		sb:  sb
		w:   w
		h:   h
		ch:  ch
		p:   p
		dst: dst
		r:   r
	}
	nt := bands(r.w, r.h)
	if nt <= 1 {
		persp_rows(&pc, r.y, r.y + r.h)
		return
	}
	step := (r.h + nt - 1) / nt
	mut ts := []thread{}
	for y0 := r.y; y0 < r.y + r.h; y0 += step {
		ts << spawn persp_rows(&pc, y0, imin(r.y + r.h, y0 + step))
	}
	ts.wait()
}

fn persp_rows(pc &PerspCtx, j0 int, j1 int) {
	w := pc.w
	h := pc.h
	ch := pc.ch
	sb := pc.sb
	r := pc.r
	unsafe {
		mut d := pc.dst + ((j0 - r.y) * r.w) * ch
		for j in j0 .. j1 {
			for i in r.x .. r.x + r.w {
				mut sx, mut sy := pc.p.at(f64(i), f64(j))
				sx -= 0.5
				sy -= 0.5
				if sx < -0.5 || sy < -0.5 || sx > f64(w) - 0.5 || sy > f64(h) - 0.5 {
					for c in 0 .. ch {
						d[c] = 0
					}
				} else {
					mut x0 := int(math.floor(sx))
					mut y0 := int(math.floor(sy))
					fx := f32(sx - f64(x0))
					fy := f32(sy - f64(y0))
					mut x1 := x0 + 1
					mut y1 := y0 + 1
					x0 = clamp_i(x0, 0, w - 1)
					y0 = clamp_i(y0, 0, h - 1)
					x1 = clamp_i(x1, 0, w - 1)
					y1 = clamp_i(y1, 0, h - 1)
					p00 := pc.src + ((y0 - sb.y) * sb.w + (x0 - sb.x)) * ch
					p10 := pc.src + ((y0 - sb.y) * sb.w + (x1 - sb.x)) * ch
					p01 := pc.src + ((y1 - sb.y) * sb.w + (x0 - sb.x)) * ch
					p11 := pc.src + ((y1 - sb.y) * sb.w + (x1 - sb.x)) * ch
					for c in 0 .. ch {
						top := f32(p00[c]) + (f32(p10[c]) - f32(p00[c])) * fx
						bot := f32(p01[c]) + (f32(p11[c]) - f32(p01[c])) * fx
						v := top + (bot - top) * fy
						d[c] = u16(if v < 0 { f32(0) } else if v > 65535 { f32(65535) } else { v + 0.5 })
					}
				}
				d += ch
			}
		}
	}
}

// PerspFit - поправка по линиям: перспектива и угол наклона
pub struct PerspFit {
pub:
	pv    f32
	ph    f32
	angle f32
}

// persp_lines - поправка по линиям снимка (x0, y0, x1, y1 в пикселях V -
// кадра без перспективы и наклона, w0 x h0): каждая линия станет
// вертикальной (если она ближе к вертикали) или горизонтальной на выходе
// (R). Что подбирается - по линиям (как Guided Upright в Lightroom): все
// вертикальные - «Вертикаль» и наклон (общий завал вертикалей - это
// наклон камеры, а не поворот вбок: по одним вертикалям «Горизонталь»
// почти не определена и ловила бы неточность линий), все горизонтальные -
// «Горизонталь» и наклон, вперемешку - обе перспективы, наклон 0.
// Остальное - из start. Поиск с шагом и уточнением.
pub fn persp_lines(lines [][]f64, w0 f64, h0 f64, start Geom) PerspFit {
	vert := lines.map(math.abs(it[3] - it[1]) >= math.abs(it[2] - it[0]))
	nv := vert.filter(it).len
	// Подбираемые: 0 - pv, 1 - ph, 2 - angle
	vars := if nv == lines.len {
		[0, 2]
	} else if nv == 0 {
		[1, 2]
	} else {
		[0, 1]
	}
	mut x := [f64(start.pv), f64(start.ph), if nv == lines.len || nv == 0 {
		f64(start.angle)
	} else {
		0.0
	}]
	lim := [100.0, 100.0, f64(geom_angle_max)]
	cost := fn [lines, w0, h0, vert] (x []f64) f64 {
		g := Geom{
			pv:    f32(x[0])
			ph:    f32(x[1])
			angle: f32(x[2])
		}
		// Линия снимка (V) -> V' (обратное к persp_plan) -> R (наклон)
		inv := persp_inverse(persp_plan(g, w0, h0))
		mut c := 0.0
		for k, l in lines {
			ux, uy := inv.at(l[0], l[1])
			vx, vy := inv.at(l[2], l[3])
			x0, y0 := g.v_to_r(ux, uy, w0, h0)
			x1, y1 := g.v_to_r(vx, vy, w0, h0)
			dx := x1 - x0
			dy := y1 - y0
			len2 := dx * dx + dy * dy
			if len2 <= 0 {
				continue
			}
			// Вертикальная - dx = 0, горизонтальная - dy = 0
			e := if vert[k] { dx } else { dy }
			c += e * e / len2
		}
		return c
	}
	mut best := cost(x)
	mut step := 10.0
	for _ in 0 .. 200 {
		mut moved := false
		for da in [-step, 0.0, step] {
			for db in [-step, 0.0, step] {
				if da == 0 && db == 0 {
					continue
				}
				mut y := x.clone()
				y[vars[0]] = math.max(-lim[vars[0]], math.min(lim[vars[0]], x[vars[0]] + da))
				y[vars[1]] = math.max(-lim[vars[1]], math.min(lim[vars[1]], x[vars[1]] + db))
				c := cost(y)
				if c < best - 1e-15 {
					best = c
					x = y.clone()
					moved = true
				}
			}
		}
		if !moved {
			step /= 2
			if step < 0.01 {
				break
			}
		}
	}
	return PerspFit{
		pv:    f32(math.round(x[0] * 10) / 10)
		ph:    f32(math.round(x[1] * 10) / 10)
		angle: f32(math.round(x[2] * 100) / 100)
	}
}

// persp_inverse - обратное проективное отображение (обратная матрица 3x3)
fn persp_inverse(p Proj) Proj {
	m := p.m
	a := m[4] * m[8] - m[5] * m[7]
	b := m[5] * m[6] - m[3] * m[8]
	c := m[3] * m[7] - m[4] * m[6]
	det := m[0] * a + m[1] * b + m[2] * c
	if math.abs(det) < 1e-300 {
		return p
	}
	k := 1 / det
	return Proj{
		m: [a * k, (m[2] * m[7] - m[1] * m[8]) * k, (m[1] * m[5] - m[2] * m[4]) * k, b * k,
			(m[0] * m[8] - m[2] * m[6]) * k, (m[2] * m[3] - m[0] * m[5]) * k, c * k,
			(m[1] * m[6] - m[0] * m[7]) * k, (m[0] * m[4] - m[1] * m[3]) * k]!
	}
}

// persp_to_v - точка V' (пиксели исправленного кадра w0 x h0) -> точка V
// снимка без перспективы
pub fn persp_to_v(g Geom, w0 f64, h0 f64, x f64, y f64) (f64, f64) {
	if !g.has_persp() {
		return x, y
	}
	return persp_plan(g, w0, h0).at(x, y)
}
