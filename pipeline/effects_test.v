module pipeline

import math

// Серый линейный кадр w x h (тон ~128 после гаммы)
fn fx_gray(w int, h int) []u16 {
	return []u16{len: w * h * 3, init: 14290}
}

fn fx_render(src []u16, w int, h int, p Params, scale f32) []u8 {
	mut dst := []u8{len: w * h * 3}
	apply_image(unsafe { &u16(src.data) }, unsafe { nil }, unsafe { nil }, w, h, p, scale, mut
		dst, 3)
	return dst
}

fn fx_g(d []u8, w int, x int, y int) int {
	return int(d[(y * w + x) * 3 + 1])
}

// Эффекты по умолчанию (величины 0) - байт в байт без них
fn test_fx_off_unchanged() {
	w, h := 60, 40
	src := fx_gray(w, h)
	base := fx_render(src, w, h, Params{ dither: false }, 1.0)
	p := Params{
		dither: false
		fx:     Effects{
			vig_round:  -60
			grain_size: 80
		}
	}
	assert fx_render(src, w, h, p, 1.0) == base
}

// Виньетка: минус темнит углы, плюс светлит, центр не трогается; кадр
// симметричен; серое остаётся серым
fn test_fx_vignette() {
	w, h := 120, 80
	src := fx_gray(w, h)
	c := fx_g(fx_render(src, w, h, Params{ dither: false }, 1.0), w, w / 2, h / 2)
	dk := fx_render(src, w, h, Params{
		dither: false
		fx:     Effects{
			vig_amount: -100
		}
	}, 1.0)
	lt := fx_render(src, w, h, Params{
		dither: false
		fx:     Effects{
			vig_amount: 100
		}
	}, 1.0)
	assert fx_g(dk, w, w / 2, h / 2) == c
	assert fx_g(lt, w, w / 2, h / 2) == c
	assert fx_g(dk, w, 0, 0) < c - 50
	assert fx_g(lt, w, 0, 0) > c + 50
	assert fx_g(dk, w, 0, 0) == fx_g(dk, w, w - 1, h - 1)
	assert fx_g(dk, w, 3, h / 2) == fx_g(dk, w, w - 4, h / 2)
	// К углу темнее монотонно
	mut prev := 255
	for k in 0 .. 40 {
		v := fx_g(dk, w, w / 2 - k * w / 80, h / 2 - k * h / 80)
		assert v <= prev
		prev = v
	}
	for i in 0 .. w * h {
		assert dk[3 * i] == dk[3 * i + 1] && dk[3 * i + 1] == dk[3 * i + 2]
	}
}

// Средняя точка и округлость: больше середина - у края светлее; к
// прямоугольнику (минус) - середина края темнее, чем у эллипса
fn test_fx_vignette_shape() {
	w, h := 150, 100
	src := fx_gray(w, h)
	shape := fn [src, w, h] (mid f32, round f32) []u8 {
		return fx_render(src, w, h, Params{
			dither: false
			fx:     Effects{
				vig_amount: -100
				vig_mid:    mid
				vig_round:  round
			}
		}, 1.0)
	}
	e := shape(50, 0)
	assert fx_g(shape(90, 0), w, 10, h / 2) > fx_g(e, w, 10, h / 2)
	assert fx_g(shape(50, -100), w, w / 2, 2) < fx_g(e, w, w / 2, 2)
	// Круг на широком кадре: у левого края (дальше от центра) темнее,
	// чем у верхнего на том же отступе
	o := shape(50, 100)
	assert fx_g(o, w, 5, h / 2) < fx_g(o, w, w / 2, 5)
}

// Зерно: среднее почти то же, разброс ~ пику; одинаково на каналах;
// крупнее - соседние пиксели ближе
fn test_fx_grain() {
	w, h := 200, 200
	src := fx_gray(w, h)
	base := fx_g(fx_render(src, w, h, Params{ dither: false }, 1.0), w, 0, 0)
	stats := fn [src, w, h, base] (size f32) (f64, f64, f64) {
		d := fx_render(src, w, h, Params{
			dither: false
			fx:     Effects{
				grain:       100
				grain_size:  size
				grain_rough: 0
			}
		}, 1.0)
		mut s := 0.0
		mut s2 := 0.0
		mut nb := 0.0
		for y in 0 .. h {
			for x in 0 .. w {
				v := f64(fx_g(d, w, x, y) - base)
				s += v
				s2 += v * v
				if x > 0 {
					q := f64(fx_g(d, w, x, y) - fx_g(d, w, x - 1, y))
					nb += q * q
				}
				i := (y * w + x) * 3
				assert d[i] == d[i + 1] && d[i + 1] == d[i + 2]
			}
		}
		n := f64(w * h)
		return s / n, math.sqrt(s2 / n - (s / n) * (s / n)), math.sqrt(nb / n)
	}
	m1, sd1, nb1 := stats(10)
	m2, sd2, nb2 := stats(90)
	assert math.abs(m1) < 1.0 && math.abs(m2) < 1.5
	assert sd1 > 5 && sd1 < 20
	assert sd2 > 5 && sd2 < 20
	assert nb2 / sd2 < 0.6 * (nb1 / sd1)
}

// Фрагмент 1:1 (fxmap) - байт в байт тот же кусок, что у полного кадра
fn test_fx_region_matches_full() {
	w, h := 160, 100
	src := fx_gray(w, h)
	fx := Effects{
		vig_amount:  -70
		vig_round:   -40
		grain:       60
		grain_rough: 80
	}
	full := fx_render(src, w, h, Params{ dither: false, fx: fx }, 1.0)
	r := Region{37, 21, 50, 40}
	sub := crop_region(unsafe { &u16(src.data) }, w, 3, r)
	part := fx_render(sub, r.w, r.h, Params{
		dither: false
		fx:     fx
		fxmap:  FxMap{r.x, r.y, w, h}
	}, 1.0)
	for y in 0 .. r.h {
		for x in 0 .. r.w {
			assert fx_g(part, r.w, x, y) == fx_g(full, w, r.x + x, r.y + y)
		}
	}
}

// Половинное превью: зерно мельче шага в 1 px буфера ослаблено
fn test_fx_grain_preview_scale() {
	fx := Effects{
		grain:      100
		grain_size: 0
	}
	assert grain_amp(fx, 0.5) < grain_amp(fx, 1.0)
	big := Effects{
		grain:      100
		grain_size: 100
	}
	assert grain_amp(big, 0.5) == grain_amp(big, 1.0)
}
