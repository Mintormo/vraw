module pipeline

import math

// Синтетическая дымка: сцена J - цветные пятна и тени (у ясной сцены
// тёмный канал около нуля), пропускание t падает слева направо (справа -
// «далеко»), I = J·t + A·(1 - t)
const hz_a = [f32(0.8), 0.82, 0.86]!

fn hazy_frame(w int, h int) []u16 {
	mut src := []u16{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			// Верхняя полоса - небо: одна дымка (t = 0)
			t := if y < h / 6 { f32(0) } else { 1.0 - 0.8 * f32(x) / f32(w - 1) }
			cell := (x / 8 + y / 8) % 4
			j := match cell {
				0 { [f32(0.6), 0.1, 0.05]! }
				1 { [f32(0.05), 0.4, 0.1]! }
				2 { [f32(0.1), 0.15, 0.5]! }
				else { [f32(0.02), 0.02, 0.02]! }
			}
			i := (y * w + x) * 3
			for c in 0 .. 3 {
				v := j[c] * t + hz_a[c] * (1 - t)
				src[i + c] = u16(v * 65535)
			}
		}
	}
	return src
}

// Размах яркости (станд. отклонение 8-бит R) в столбцах x0..x1
fn column_spread(out []u8, w int, h int, x0 int, x1 int) f64 {
	mut s := 0.0
	mut s2 := 0.0
	mut n := 0
	for y in h / 4 .. h {
		for x in x0 .. x1 {
			v := f64(out[(y * w + x) * 3])
			s += v
			s2 += v * v
			n++
		}
	}
	m := s / n
	return math.sqrt(s2 / n - m * m)
}

fn render_haze(src []u16, m &HazeMap, w int, h int, haze f32) []u8 {
	p := Params{
		dither: false
		haze:   haze
	}
	mut out := []u8{len: w * h * 3}
	apply_image(unsafe { &u16(src.data) }, unsafe { nil }, m, w, h, p, 1.0, mut out, 3)
	return out
}

fn test_haze_map_and_removal() {
	w, h := 160, 96
	src := hazy_frame(w, h)
	m := haze_map(unsafe { &u16(src.data) }, w, h)
	assert m.d.len == w * h
	// Свет дымки найден близко к настоящему
	for c in 0 .. 3 {
		assert math.abs(m.a[c] - hz_a[c]) < 0.12, 'A[${c}] = ${m.a[c]}'
	}
	// Дымки справа («далеко») больше, чем слева
	mut left := 0.0
	mut right := 0.0
	for y in h / 4 .. h {
		left += f64(m.d[y * w + 10])
		right += f64(m.d[y * w + w - 10])
	}
	assert right > left * 2
	// Сила 0 - как без карты; удаление поднимает контраст дальнего плана,
	// добавление - снижает
	base := render_haze(src, m, w, h, 0)
	mut plain := []u8{len: w * h * 3}
	apply(unsafe { &u16(src.data) }, unsafe { nil }, w * h, Params{ dither: false }, mut plain, 3)
	assert base == plain
	rem := render_haze(src, m, w, h, 100)
	add := render_haze(src, m, w, h, -100)
	far0 := column_spread(base, w, h, w - 40, w)
	assert column_spread(rem, w, h, w - 40, w) > far0 * 1.5
	assert column_spread(add, w, h, w - 40, w) < far0
}

fn test_min_filter() {
	w, h := 9, 7
	mut a := []f32{len: w * h, init: 1}
	a[3 * w + 4] = 0
	b := min_filter(a, w, h, 2)
	for y in 0 .. h {
		for x in 0 .. w {
			inside := math.abs(x - 4) <= 2 && math.abs(y - 3) <= 2
			assert b[y * w + x] == if inside { f32(0) } else { f32(1) }
		}
	}
}
