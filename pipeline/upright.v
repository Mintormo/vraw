module pipeline

// Автоперспектива (как Upright в Lightroom): прямые отрезки ищутся на
// сырье после коррекции объектива (дисторсия уже убрана - прямые прямые),
// затем подбираются наклон и перспектива, при которых почти вертикальные
// отрезки станут вертикальными, а почти горизонтальные - горизонтальными.
//
// Поиск отрезков (line_segments) - упрощённый LSD (Grompone von Gioi и
// др.): градиент 2x2 по уменьшенной люме, пиксели в порядке убывания
// силы края, область растёт по соседям с тем же направлением края
// (допуск 22.5°), у области - главная ось (моменты инерции); отрезок -
// длинная узкая область. Подбор (upright_fit) - устойчивый: вклад линии
// ограничен сверху, порог сужается ступенями (30° -> 3°), так что
// наклонные на самом деле линии (крыши, перила) по ходу выпадают.
import math

// UprightMode - что подбирать: level - только наклон (по горизонталям и
// вертикалям), vertical - «Вертикаль» и наклон (по вертикалям), full -
// обе перспективы и наклон (по всем линиям). Неподбираемое - 0.
pub enum UprightMode {
	level
	vertical
	full
}

// Segment - отрезок в пикселях кадра
pub struct Segment {
pub:
	x0 f64
	y0 f64
	x1 f64
	y1 f64
}

pub fn (s Segment) len() f64 {
	return math.hypot(s.x1 - s.x0, s.y1 - s.y0)
}

// upright_side - длинная сторона уменьшенной люмы для поиска линий
const upright_side = 1000
// upright_tol - допуск направления края внутри области (LSD: 22.5°)
const upright_tol = math.pi / 8
// upright_grad - порог силы края (люма 0..255; LSD: 5.2)
const upright_grad = 6.0
// upright_min_len - самый короткий отрезок, доля длинной стороны
const upright_min_len = 0.035
// upright_span - насколько отрезок может отклоняться от вертикали или
// горизонтали, чтобы участвовать в подборе
const upright_span = 30.0
// upright_inlier - отрезок «лёг ровно», если после подбора отклоняется
// меньше чем на столько градусов
const upright_inlier = 1.5
// upright_need - сколько длины ровно легших отрезков нужно для ответа,
// доля диагонали кадра (у «Полностью» - и вертикалей, и горизонталей)
const upright_need = 0.12
// upright_level_max - «Уровень» ищет наклон в этих пределах, градусы
const upright_level_max = 10.0
// upright_level_mid - вертикали для «Уровня» - только у центра (доля
// ширины от середины): у краёв их заваливает перспектива
const upright_level_mid = 0.2

// upright_luma - люма RGB-кадра w x h, уменьшенная в f раз (f - целое,
// длинная сторона ~upright_side) в шкале ~0..255 (корень - ближе к
// восприятию, края в тенях не теряются)
fn upright_luma(src &u16, w int, h int) ([]f32, int, int, int) {
	f := imax(1, (imax(w, h) + upright_side - 1) / upright_side)
	lw := w / f
	lh := h / f
	mut out := []f32{len: lw * lh}
	inv := 1.0 / (f64(f * f) * 65535.0)
	for y in 0 .. lh {
		for x in 0 .. lw {
			mut s := 0.0
			for j in 0 .. f {
				unsafe {
					mut p := src + ((y * f + j) * w + x * f) * 3
					for _ in 0 .. f {
						s += 0.2126 * f64(p[0]) + 0.7152 * f64(p[1]) + 0.0722 * f64(p[2])
						p += 3
					}
				}
			}
			out[y * lw + x] = f32(math.sqrt(s * inv) * 255)
		}
	}
	return out, lw, lh, f
}

// line_segments - прямые отрезки люмы lum w x h (пиксели этой же люмы)
pub fn line_segments(lum []f32, w int, h int) []Segment {
	if w < 8 || h < 8 {
		return []Segment{}
	}
	// Градиент 2x2 в точке (x + 1, y + 1): сила и направление линии края
	// (перпендикуляр к градиенту, LSD: atan2(gx, -gy))
	gw := w - 1
	gh := h - 1
	mut mag := []f32{len: gw * gh}
	mut ang := []f32{len: gw * gh}
	mut maxm := f32(0)
	for y in 0 .. gh {
		for x in 0 .. gw {
			a := lum[y * w + x]
			b := lum[y * w + x + 1]
			c := lum[(y + 1) * w + x]
			d := lum[(y + 1) * w + x + 1]
			gx := (b + d - a - c) / 2
			gy := (c + d - a - b) / 2
			m := f32(math.sqrt(gx * gx + gy * gy))
			i := y * gw + x
			mag[i] = m
			ang[i] = f32(math.atan2(gx, -gy))
			if m > maxm {
				maxm = m
			}
		}
	}
	if maxm <= upright_grad {
		return []Segment{}
	}
	// Псевдосортировка по силе края - корзинами (как в LSD)
	nb := 1024
	mut bins := [][]int{len: nb}
	for i, m in mag {
		if m > upright_grad {
			k := imin(nb - 1, int(m / maxm * f32(nb)))
			bins[k] << i
		}
	}
	mut used := []bool{len: gw * gh}
	min_len := upright_min_len * f64(imax(w, h))
	mut segs := []Segment{}
	mut reg := []int{cap: 4096}
	for k := nb - 1; k >= 0; k-- {
		for seed in bins[k] {
			if used[seed] {
				continue
			}
			// Рост области: соседи с тем же направлением края
			reg.clear()
			reg << seed
			used[seed] = true
			mut sc := math.cos(f64(ang[seed]))
			mut ss := math.sin(f64(ang[seed]))
			mut th := f64(ang[seed])
			mut qi := 0
			for qi < reg.len {
				p := reg[qi]
				qi++
				px := p % gw
				py := p / gw
				for dy in -1 .. 2 {
					for dx in -1 .. 2 {
						nx := px + dx
						ny := py + dy
						if nx < 0 || ny < 0 || nx >= gw || ny >= gh {
							continue
						}
						n := ny * gw + nx
						if used[n] || mag[n] <= upright_grad {
							continue
						}
						mut da := math.abs(f64(ang[n]) - th)
						if da > math.pi {
							da = 2 * math.pi - da
						}
						if da > upright_tol {
							continue
						}
						used[n] = true
						reg << n
						sc += math.cos(f64(ang[n]))
						ss += math.sin(f64(ang[n]))
						th = math.atan2(ss, sc)
					}
				}
			}
			if f64(reg.len) < min_len {
				continue
			}
			if s := region_segment(reg, mag, gw, min_len) {
				segs << s
			}
		}
	}
	return segs
}

// region_segment - отрезок по области: центр и главная ось по моментам
// (веса - сила края), концы - крайние проекции; none - область не длинная
// и узкая
fn region_segment(reg []int, mag []f32, gw int, min_len f64) ?Segment {
	mut sw := 0.0
	mut cx := 0.0
	mut cy := 0.0
	for p in reg {
		m := f64(mag[p])
		sw += m
		cx += m * f64(p % gw)
		cy += m * f64(p / gw)
	}
	cx /= sw
	cy /= sw
	mut ixx := 0.0
	mut iyy := 0.0
	mut ixy := 0.0
	for p in reg {
		m := f64(mag[p])
		dx := f64(p % gw) - cx
		dy := f64(p / gw) - cy
		ixx += m * dx * dx
		iyy += m * dy * dy
		ixy += m * dx * dy
	}
	// Главная ось - направление наибольшего разброса
	t := 0.5 * math.atan2(2 * ixy, ixx - iyy)
	ux := math.cos(t)
	uy := math.sin(t)
	mut lo := 1e18
	mut hi := -1e18
	mut wlo := 1e18
	mut whi := -1e18
	for p in reg {
		dx := f64(p % gw) - cx
		dy := f64(p / gw) - cy
		a := dx * ux + dy * uy
		b := -dx * uy + dy * ux
		lo = math.min(lo, a)
		hi = math.max(hi, a)
		wlo = math.min(wlo, b)
		whi = math.max(whi, b)
	}
	l := hi - lo + 1
	wd := whi - wlo + 1
	if l < min_len || l < 8 * wd || f64(reg.len) < 0.5 * l * math.min(wd, 3) {
		return none
	}
	// Градиент 2x2 стоит между пикселями: +1 - к пикселям люмы
	return Segment{cx + lo * ux + 1, cy + lo * uy + 1, cx + hi * ux + 1, cy + hi * uy + 1}
}

// upright_segments - отрезки кадра w x h (RGB u16 - сырьё после объектива)
// в пикселях V (после поворотов на 90° и отражений g, до перспективы и
// наклона; w0 x h0)
pub fn upright_segments(src &u16, w int, h int, g Geom) []Segment {
	lum, lw, lh, f := upright_luma(src, w, h)
	segs := line_segments(lum, lw, lh)
	w0, h0 := g.oriented(w, h)
	fw := f64(w)
	fh := f64(h)
	sf := f64(f)
	return segs.map(fn [g, fw, fh, sf, w0, h0] (s Segment) Segment {
		a, b := g.s_to_v(s.x0 * sf / fw, s.y0 * sf / fh)
		c, d := g.s_to_v(s.x1 * sf / fw, s.y1 * sf / fh)
		return Segment{a * f64(w0), b * f64(h0), c * f64(w0), d * f64(h0)}
	})
}

// upright_fit - наклон и перспектива по отрезкам segs (пиксели V кадра
// w0 x h0); none - ровно легших линий слишком мало
pub fn upright_fit(segs []Segment, w0 f64, h0 f64, mode UprightMode) ?PerspFit {
	span := math.sin(upright_span * math.pi / 180)
	// Кандидаты: близкие к вертикали (dx/len < sin 30°) и к горизонтали
	mut lines := []Segment{}
	mut vert := []bool{}
	for s in segs {
		l := s.len()
		if l <= 0 {
			continue
		}
		dx := math.abs(s.x1 - s.x0) / l
		dy := math.abs(s.y1 - s.y0) / l
		if dx < span {
			// «Уровень»: вертикали только у центра
			if mode == .level && math.abs((s.x0 + s.x1) / 2 - w0 / 2) > upright_level_mid * w0 {
				continue
			}
			lines << s
			vert << true
		} else if dy < span && mode != .vertical {
			lines << s
			vert << false
		}
	}
	if lines.len == 0 {
		return none
	}
	fit := if mode == .level {
		level_fit(lines, vert)
	} else {
		persp_fit(lines, vert, w0, h0, mode)
	}
	// Опора: длина отрезков, легших ровно (у «Полностью» - обеих групп)
	need := upright_need * math.hypot(w0, h0)
	vl, hl := inlier_len(lines, vert, w0, h0, fit)
	ok := match mode {
		.level { vl + hl >= need }
		.vertical { vl >= need }
		.full { vl >= need && hl >= need }
	}
	return if ok { fit } else { none }
}

// line_dev - синус отклонения отрезка l кадра V от вертикали (vert) или
// горизонтали после поправки g (R)
fn line_dev(inv Proj, g Geom, l Segment, vert bool, w0 f64, h0 f64) f64 {
	ux, uy := inv.at(l.x0, l.y0)
	vx, vy := inv.at(l.x1, l.y1)
	x0, y0 := g.v_to_r(ux, uy, w0, h0)
	x1, y1 := g.v_to_r(vx, vy, w0, h0)
	dx := x1 - x0
	dy := y1 - y0
	ln := math.sqrt(dx * dx + dy * dy)
	if ln <= 0 {
		return 1
	}
	return (if vert { dx } else { dy }) / ln
}

fn fit_geom(f PerspFit) Geom {
	return Geom{
		pv:    f.pv
		ph:    f.ph
		angle: f.angle
	}
}

// inlier_len - длина вертикалей и горизонталей, легших ровно после f
fn inlier_len(lines []Segment, vert []bool, w0 f64, h0 f64, f PerspFit) (f64, f64) {
	g := fit_geom(f)
	inv := persp_inverse(persp_plan(g, w0, h0))
	lim := math.sin(upright_inlier * math.pi / 180)
	mut vl := 0.0
	mut hl := 0.0
	for k, l in lines {
		if math.abs(line_dev(inv, g, l, vert[k], w0, h0)) < lim {
			if vert[k] {
				vl += l.len()
			} else {
				hl += l.len()
			}
		}
	}
	return vl, hl
}

// level_fit - «Уровень»: наклон, при котором больше всего длины отрезков
// ровные (поиск по сетке 0.05° в ±upright_level_max, окно ±0.5°), затем
// уточнение - средневзвешенное отклонение попавших в окно. Не среднее по
// всем: наклонные на самом деле линии (крыши, колея) его бы утянули
fn level_fit(lines []Segment, vert []bool) PerspFit {
	// Угол каждого отрезка от своей оси, градусы (плюс - против часовой
	// на экране, y вниз)
	mut dev := []f64{len: lines.len}
	for k, l in lines {
		dx := l.x1 - l.x0
		dy := l.y1 - l.y0
		a := if vert[k] {
			// Вертикаль: отклонение по x на единицу y
			math.atan2(if dy < 0 { -dx } else { dx }, math.abs(dy))
		} else {
			-math.atan2(if dx < 0 { -dy } else { dy }, math.abs(dx))
		}
		dev[k] = a * 180 / math.pi
	}
	win := 0.5
	mut best := -1.0
	mut best_a := 0.0
	n := int(upright_level_max / 0.05)
	for i in -n .. n + 1 {
		a := f64(i) * 0.05
		mut wsum := 0.0
		for k, l in lines {
			e := (dev[k] - a) / win
			if e > -1 && e < 1 {
				wsum += l.len() * (1 - e * e)
			}
		}
		// При равенстве - ближе к нулю
		if wsum > best + 1e-9 || (math.abs(wsum - best) <= 1e-9 && math.abs(a) < math.abs(best_a)) {
			best = wsum
			best_a = a
		}
	}
	mut sw := 0.0
	mut sa := 0.0
	for k, l in lines {
		if math.abs(dev[k] - best_a) < win {
			sw += l.len()
			sa += l.len() * dev[k]
		}
	}
	a := if sw > 0 { sa / sw } else { best_a }
	// Выпрямляет поворот на −a (v_to_r: у вертикали dx' = dy·(cos·t +
	// sin), ноль при tg(angle) = −t; у горизонтали так же со знаком dev)
	return PerspFit{
		angle: f32(math.round(-a * 100) / 100)
	}
}

// persp_fit - «Вертикали» и «Полностью»: перспектива и наклон по
// кандидатам, устойчиво (вклад отрезка ограничен, порог сужается).
// «Полностью» - в два шага: сначала как «Вертикали» (по вертикалям), затем
// все три с узким порогом от 8°: горизонтали, уходящие вглубь (столы,
// стены сбоку), далеки от горизонтали и в подбор не попадают
fn persp_fit(lines []Segment, vert []bool, w0 f64, h0 f64, mode UprightMode) PerspFit {
	mut vl := []Segment{}
	for k, l in lines {
		if vert[k] {
			vl << l
		}
	}
	x := persp_search(vl, []bool{len: vl.len, init: true}, w0, h0, [0, 2], [0.0, 0, 0],
		[30.0, 15, 8, 4, 2])
	if mode != .full {
		return persp_round(x)
	}
	return persp_round(persp_search(lines, vert, w0, h0, [0, 1, 2], x, [8.0, 4, 2]))
}

fn persp_round(x []f64) PerspFit {
	return PerspFit{
		pv:    f32(math.round(x[0] * 10) / 10)
		ph:    f32(math.round(x[1] * 10) / 10)
		angle: f32(math.round(x[2] * 100) / 100)
	}
}

// persp_search - поиск по переменным vars (0 - pv, 1 - ph, 2 - angle) от
// start; порог вклада отрезка - по ступеням caps (градусы)
fn persp_search(lines []Segment, vert []bool, w0 f64, h0 f64, vars []int, start []f64, caps []f64) []f64 {
	if lines.len == 0 {
		return start.clone()
	}
	lim := [100.0, 100.0, f64(geom_angle_max)]
	mut x := start.clone()
	for cap_deg in caps {
		c := math.sin(cap_deg * math.pi / 180)
		cost := fn [lines, vert, w0, h0, c] (x []f64) f64 {
			g := Geom{
				pv:    f32(x[0])
				ph:    f32(x[1])
				angle: f32(x[2])
			}
			inv := persp_inverse(persp_plan(g, w0, h0))
			mut sum := 0.0
			for k, l in lines {
				e := line_dev(inv, g, l, vert[k], w0, h0)
				sum += l.len() * math.min(e * e, c * c)
			}
			return sum
		}
		mut best := cost(x)
		mut step := 8.0
		for _ in 0 .. 400 {
			mut moved := false
			for v in vars {
				for d in [-step, step] {
					mut y := x.clone()
					y[v] = math.max(-lim[v], math.min(lim[v], x[v] + d))
					cv := cost(y)
					if cv < best - 1e-12 {
						best = cv
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
	}
	return x
}
