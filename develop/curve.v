module develop

// Тональные кривые: монотонный кубический сплайн (Фрич-Карлсон) по
// опорным точкам. Это ТОТ ЖЕ алгоритм, что vgui.curve_lut (редактор
// кривых GUI рисует им же) - перенесён сюда, чтобы проявка (GUI и CLI)
// не зависела от vgui. Совпадение сверяет тест gui/edit_test.v.
import math

// is_identity - кривая совпадает с диагональю
pub fn is_identity(pts []Point) bool {
	for q in pts {
		if math.abs(q.x - q.y) > 1e-4 {
			return false
		}
	}
	return true
}

fn tangents(p []Point) []f32 {
	n := p.len
	mut d := []f32{len: n - 1}
	for i in 0 .. n - 1 {
		dx := p[i + 1].x - p[i].x
		d[i] = if dx > 0 { (p[i + 1].y - p[i].y) / dx } else { f32(0) }
	}
	mut m := []f32{len: n}
	m[0] = d[0]
	m[n - 1] = d[n - 2]
	for i in 1 .. n - 1 {
		m[i] = if d[i - 1] * d[i] <= 0 { f32(0) } else { (d[i - 1] + d[i]) * 0.5 }
	}
	for i in 0 .. n - 1 {
		if d[i] == 0 {
			m[i] = 0
			m[i + 1] = 0
			continue
		}
		a := m[i] / d[i]
		b := m[i + 1] / d[i]
		s := a * a + b * b
		if s > 9 {
			t := 3 / math.sqrtf(s)
			m[i] = t * a * d[i]
			m[i + 1] = t * b * d[i]
		}
	}
	return m
}

fn hermite(p []Point, m []f32, x f32) f32 {
	n := p.len
	if x <= p[0].x {
		return p[0].y
	}
	if x >= p[n - 1].x {
		return p[n - 1].y
	}
	mut i := 0
	for i < n - 2 && x > p[i + 1].x {
		i++
	}
	h := p[i + 1].x - p[i].x
	if h <= 0 {
		return p[i].y
	}
	t := (x - p[i].x) / h
	t2 := t * t
	t3 := t2 * t
	return (2 * t3 - 3 * t2 + 1) * p[i].y + (t3 - 2 * t2 + t) * h * m[i] +
		(-2 * t3 + 3 * t2) * p[i + 1].y + (t3 - t2) * h * m[i + 1]
}

fn clamp01(v f32) f32 {
	return if v < 0 { f32(0) } else if v > 1 { f32(1) } else { v }
}

// curve_lut - n равномерных выборок кривой (x = i/(n-1)), значения 0..1
pub fn curve_lut(pts []Point, n int) []f32 {
	mut out := []f32{len: n}
	if n <= 0 {
		return out
	}
	if pts.len < 2 {
		for i in 0 .. n {
			out[i] = if n > 1 { f32(i) / f32(n - 1) } else { 0 }
		}
		return out
	}
	m := tangents(pts)
	for i in 0 .. n {
		x := if n > 1 { f32(i) / f32(n - 1) } else { f32(0) }
		out[i] = clamp01(hermite(pts, m, x))
	}
	return out
}

// tone_lut - кривая как таблица пайплайна: 256 узлов тон 0..255 -> тон
// 0..255; тождественная - пустой массив (кривой нет)
pub fn tone_lut(pts []Point) []f32 {
	if is_identity(pts) {
		return []f32{}
	}
	mut l := curve_lut(pts, 256)
	for i in 0 .. 256 {
		l[i] *= 255.0
	}
	return l
}
