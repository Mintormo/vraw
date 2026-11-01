module main

// Маска фокуса (focus.v): резкие края отмечаются, размытые - нет; ровное и
// шум (ISO 6400) не отмечаются; закраска - только у резких мест

// stripes_rgba - вертикальные полосы 40/200 шириной period: левая половина -
// ступенькой, правая - с рампой шириной ramp пикселей (размытый край);
// шум ±noise уровней (LCG, детерминирован)
fn stripes_rgba(w int, h int, period int, ramp int, noise int) []u8 {
	mut p := []u8{len: w * h * 4}
	mut seed := u32(12345)
	for y in 0 .. h {
		for x in 0 .. w {
			ph := x % (2 * period)
			hi := ph < period
			// расстояние до ближайшей границы полос
			dist := if hi { min_i(ph, period - ph) } else { min_i(ph - period, 2 * period - ph) }
			mut v := if hi { 200.0 } else { 40.0 }
			if x >= w / 2 && dist < ramp {
				// рампа: на границе - середина, к краю рампы - уровень полосы
				t := 0.5 + 0.5 * f64(dist) / f64(ramp)
				v = if hi { 120.0 + 80.0 * (2 * t - 1) } else { 120.0 - 80.0 * (2 * t - 1) }
			}
			if noise > 0 {
				seed = seed * 1103515245 + 12345
				v += f64(int((seed >> 16) % u32(2 * noise + 1)) - noise)
			}
			c := u8(if v < 0 { 0.0 } else if v > 255 { 255.0 } else { v })
			k := (y * w + x) * 4
			p[k] = c
			p[k + 1] = c
			p[k + 2] = c
			p[k + 3] = 255
		}
	}
	return p
}

fn min_i(a int, b int) int {
	return if a < b { a } else { b }
}

// focus_count - отмеченные пиксели в столбцах x0..x1
fn focus_count(b FocusBufs, w int, h int, x0 int, x1 int) int {
	mut n := 0
	for y in 0 .. h {
		for x in x0 .. x1 {
			if b.m[y * w + x] != 0 {
				n++
			}
		}
	}
	return n
}

fn test_focus_sharp_vs_blurred() {
	w := 1000
	h := 600 // больше focus_band_px - считается в потоках
	pix := stripes_rgba(w, h, 25, 4, 0)
	mut b := FocusBufs{}
	assert focus_map(pix, w, h, 1, mut b)
	left := focus_count(b, w, h, 20, w / 2 - 20)
	right := focus_count(b, w, h, w / 2 + 20, w - 20)
	assert left > 4 * h // каждый край слева - отмечен
	assert right == 0
	// Повторный расчёт в тех же буферах - тот же результат
	m1 := b.m.clone()
	assert focus_map(pix, w, h, 1, mut b)
	assert b.m == m1
	b.free()
}

fn test_focus_flat_and_noise() {
	w := 400
	h := 300
	mut b := FocusBufs{}
	// Ровное поле
	mut flat := []u8{len: w * h * 4, init: 128}
	assert focus_map(flat, w, h, 1, mut b)
	assert focus_count(b, w, h, 0, w) == 0
	// Сильный шум без краёв - почти не «резко»: независимый шум ±22 жёстче
	// настоящего (у того соседи связаны демозаикой; IMG_1117, ISO 6400 -
	// чисто), редкие точки допустимы
	mut noisy := stripes_rgba(w, h, 10000, 0, 22)
	for i in 0 .. w * h {
		noisy[i * 4] = u8(int(noisy[i * 4]) - 40 + 128)
		noisy[i * 4 + 1] = noisy[i * 4]
		noisy[i * 4 + 2] = noisy[i * 4]
	}
	assert focus_map(noisy, w, h, 1, mut b)
	assert focus_count(b, w, h, 0, w) < w * h / 100
	// Резкие края в том же шуме - отмечены, размытые - почти нет
	ns := stripes_rgba(w, h, 25, 4, 10)
	assert focus_map(ns, w, h, 1, mut b)
	assert focus_count(b, w, h, 20, w / 2 - 20) > 2 * h
	assert focus_count(b, w, h, w / 2 + 20, w - 20) < h / 4
	b.free()
}

fn test_mark_focus_paint() {
	w := 300
	h := 200
	mut pix := stripes_rgba(w, h, 25, 4, 0)
	orig := pix.clone()
	mut b := FocusBufs{}
	mark_focus(mut pix, w, h, 1, mut b)
	// Край левой половины (x = 25) - зеленее, середина полосы и правая
	// половина - без изменений
	k := (100 * w + 25) * 4
	assert pix[k + 1] > pix[k] && pix[k + 1] > pix[k + 2]
	m := (100 * w + 12) * 4
	assert pix[m..m + 4] == orig[m..m + 4]
	r := (100 * w + 225) * 4
	assert pix[r..r + 4] == orig[r..r + 4]
	assert pix[3] == 255 // альфа не тронута
	// Кадр меньше окна - без маски
	mut tiny := []u8{len: 8 * 8 * 4, init: 100}
	assert !focus_map(tiny, 8, 8, 1, mut b)
	// Шаг 2 (фрагмент 1:1): размытый край шириной 4 в масштабе полного
	// кадра - как ширина 2 на превью, резкий
	big := stripes_rgba(w, h, 50, 2, 0)
	assert focus_map(big, w, h, 2, mut b)
	assert focus_count(b, w, h, w / 2 + 20, w - 20) > 0
	b.free()
}
