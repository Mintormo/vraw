module pipeline

// Подавление шумов и ореолов (цветной каймы). Обе операции - подготовка
// сырья, как коррекция объектива: выполняются один раз над линейным
// буфером ДО тонального пайплайна, тональные ползунки остаются живыми.
//
// Работа идёт в sqrt-домене (канал u16 -> sqrt(f32)): фотонный шум
// пуассоновский, его дисперсия растёт с сигналом, а после корня становится
// примерно равномерной по всему диапазону - один порог годится и для теней,
// и для светов (стабилизация дисперсии, приём darktable). Цвет отделяется
// от яркости обратимым преобразованием y = BT.709(r,g,b), u = r-y, v = b-y
// (по sqrt-значениям - это не колориметрия, а декорреляция каналов).
//
// Шумодав - вейвлет à trous (B3-сплайн), как в RawTherapee: кадр
// раскладывается на уровни детализации, в каждом уровне мелкие коэффициенты
// (шум) мягко давятся к нулю, крупные (контуры) проходят как есть.
// Ореолы (defringe) - там, где градиент люмы высок (контур) И цветность
// резко отклоняется от окрестности (кайма), цветность подтягивается
// к размытому значению окрестности.
import math

// to_yuv_sqrt раскладывает линейный RGB на плоскости y/u/v в sqrt-домене.
fn to_yuv_sqrt(buf &u16, npix int) ([]f32, []f32, []f32) {
	mut y := []f32{len: npix}
	mut u := []f32{len: npix}
	mut v := []f32{len: npix}
	unsafe {
		mut s := &u16(buf)
		py := &f32(y.data)
		pu := &f32(u.data)
		pv := &f32(v.data)
		for i in 0 .. npix {
			r := math.sqrtf(f32(s[0]))
			g := math.sqrtf(f32(s[1]))
			b := math.sqrtf(f32(s[2]))
			yy := 0.2126 * r + 0.7152 * g + 0.0722 * b
			py[i] = yy
			pu[i] = r - yy
			pv[i] = b - yy
			s += 3
		}
	}
	return y, u, v
}

// sq_clamp возвращает sqrt-значение обратно в линейный u16.
fn sq_clamp(x f32) u16 {
	if x <= 0 {
		return 0
	}
	q := x * x
	if q >= 65535.0 {
		return 65535
	}
	return u16(q + 0.5)
}

// from_yuv_sqrt собирает плоскости y/u/v обратно в линейный RGB-буфер.
fn from_yuv_sqrt(buf &u16, npix int, y []f32, u []f32, v []f32) {
	unsafe {
		mut d := &u16(buf)
		py := &f32(y.data)
		pu := &f32(u.data)
		pv := &f32(v.data)
		for i in 0 .. npix {
			yy := py[i]
			r := yy + pu[i]
			b := yy + pv[i]
			g := (yy - 0.2126 * r - 0.0722 * b) * f32(1.0 / 0.7152)
			d[0] = sq_clamp(r)
			d[1] = sq_clamp(g)
			d[2] = sq_clamp(b)
			d += 3
		}
	}
}

// atrous_blur - сепарабельная свёртка B3-сплайном (1,4,6,4,1)/16 с шагом
// step между отсчётами (алгоритм à trous: шаг удваивается с уровнем).
// Края клампятся. dst может совпадать с src (tmp - рабочий буфер).
fn atrous_blur(src []f32, mut tmp []f32, mut dst []f32, w int, h int, step int) {
	unsafe {
		s := &f32(src.data)
		t := &f32(tmp.data)
		d := &f32(dst.data)
		for y in 0 .. h {
			base := y * w
			for x in 0 .. w {
				x0 := if x >= 2 * step { x - 2 * step } else { 0 }
				x1 := if x >= step { x - step } else { 0 }
				x2 := if x + step < w { x + step } else { w - 1 }
				x3 := if x + 2 * step < w { x + 2 * step } else { w - 1 }
				t[base + x] = (s[base + x0] + 4.0 * s[base + x1] + 6.0 * s[base + x] +
					4.0 * s[base + x2] + s[base + x3]) * f32(1.0 / 16.0)
			}
		}
		for y in 0 .. h {
			y0 := if y >= 2 * step { y - 2 * step } else { 0 }
			y1 := if y >= step { y - step } else { 0 }
			y2 := if y + step < h { y + step } else { h - 1 }
			y3 := if y + 2 * step < h { y + 2 * step } else { h - 1 }
			r0 := y0 * w
			r1 := y1 * w
			rc := y * w
			r2 := y2 * w
			r3 := y3 * w
			for x in 0 .. w {
				d[rc + x] = (t[r0 + x] + 4.0 * t[r1 + x] + 6.0 * t[rc + x] + 4.0 * t[r2 + x] +
					t[r3 + x]) * f32(1.0 / 16.0)
			}
		}
	}
}

// atrous_denoise - вейвлетный шумодав одной плоскости: разложение à trous
// на thresholds.len уровней, деталь каждого уровня мягко давится
// d^3/(d^2+t^2) (плавный аналог порога: мелкое -> почти ноль, крупное -
// как есть), остаток и усечённые детали складываются обратно.
fn atrous_denoise(mut a []f32, w int, h int, thresholds []f32) {
	npix := w * h
	mut acc := []f32{len: npix} // сумма усечённых деталей
	mut tmp := []f32{len: npix}
	mut cur := a.clone()
	mut next := []f32{len: npix}
	for l in 0 .. thresholds.len {
		atrous_blur(cur, mut tmp, mut next, w, h, 1 << l)
		t2 := thresholds[l] * thresholds[l]
		unsafe {
			pc := &f32(cur.data)
			pn := &f32(next.data)
			pa := &f32(acc.data)
			for i in 0 .. npix {
				d := pc[i] - pn[i]
				pa[i] += d * d * d / (d * d + t2)
			}
			vmemcpy(cur.data, next.data, npix * int(sizeof(f32)))
		}
	}
	unsafe {
		pc := &f32(cur.data)
		pa := &f32(acc.data)
		out := &f32(a.data)
		for i in 0 .. npix {
			out[i] = pa[i] + pc[i]
		}
	}
}

// impulse_pass - один проход детектора импульсов по плоскости: пиксель,
// чьё значение отклоняется от медианы 8 соседей больше порога t, заменяется
// этой медианой; остальные проходят как есть. Детект по src, поэтому
// замены соседей друг на друга не влияют.
fn impulse_pass(src []f32, mut dst []f32, w int, h int, t f32) {
	unsafe {
		s := &f32(src.data)
		d := &f32(dst.data)
		for y in 0 .. h {
			ym := if y > 0 { y - 1 } else { 0 }
			yp := if y < h - 1 { y + 1 } else { h - 1 }
			for x in 0 .. w {
				xm := if x > 0 { x - 1 } else { 0 }
				xp := if x < w - 1 { x + 1 } else { w - 1 }
				mut n := [s[ym * w + xm], s[ym * w + x], s[ym * w + xp], s[y * w + xm], s[y * w + xp],
					s[yp * w + xm], s[yp * w + x], s[yp * w + xp]]!
				c := s[y * w + x]
				// Дешёвый отсев: медиана лежит между min и max соседей,
				// поэтому если оба в пределах t от центра - точно не импульс.
				// Сортировка достаётся только кандидатам (доли процента).
				mut mn := n[0]
				mut mx := n[0]
				for i in 1 .. 8 {
					if n[i] < mn {
						mn = n[i]
					} else if n[i] > mx {
						mx = n[i]
					}
				}
				if c - mn <= t && mx - c <= t {
					d[y * w + x] = c
					continue
				}
				// вставочная сортировка 8 элементов
				for i in 1 .. 8 {
					v := n[i]
					mut j := i
					for j > 0 && n[j - 1] > v {
						n[j] = n[j - 1]
						j--
					}
					n[j] = v
				}
				med := (n[3] + n[4]) * 0.5
				dd := c - med
				d[y * w + x] = if dd > t || dd < -t { med } else { c }
			}
		}
	}
}

// impulse - подавление импульсного шума (горячие/мёртвые пиксели, аналог
// «Подавление импульсного шума» RawTherapee) на месте. strength 0..100 -
// чувствительность детектора: порог t в sqrt-домене падает с силой, большие
// значения могут съедать одиночные яркие детали (звёзды, блики).
// Каналы обрабатываются независимо (горячий пиксель часто одноканальный).
// Два прохода: демозаика размазывает выброс в пятно 2-3 пк, первый проход
// снимает края пятна, второй добивает центр. Резкие края переживают детект:
// у пикселя на границе медиана соседей лежит на его же стороне перепада.
pub fn impulse(buf &u16, w int, h int, strength f32) {
	if strength <= 0 {
		return
	}
	npix := w * h
	t := f32(55.0) - strength * f32(0.5) // sqrt-домен: 100 -> 5, 50 -> 30
	mut a := []f32{len: npix}
	mut b := []f32{len: npix}
	for ch in 0 .. 3 {
		unsafe {
			s := buf
			pa := &f32(a.data)
			for i in 0 .. npix {
				pa[i] = math.sqrtf(f32(s[i * 3 + ch]))
			}
		}
		impulse_pass(a, mut b, w, h, t)
		impulse_pass(b, mut a, w, h, t)
		unsafe {
			d := buf
			pa := &f32(a.data)
			for i in 0 .. npix {
				d[i * 3 + ch] = sq_clamp(pa[i])
			}
		}
	}
}

// denoise - подавление шумов линейного RGB-буфера на месте.
// luma/chroma - силы 0..100 (0 - канал не трогается): порог вейвлета
// в sqrt-домене. Цветовой шум давится сильнее и глубже (4 уровня против 3):
// цветность реальных сцен низкочастотна, глазу потеря цветовых мелочей
// почти не видна, а цветной шум - самый неприятный.
pub fn denoise(buf &u16, w int, h int, luma f32, chroma f32) {
	if luma <= 0 && chroma <= 0 {
		return
	}
	npix := w * h
	mut y, mut u, mut v := to_yuv_sqrt(buf, npix)
	if luma > 0 {
		t := luma * f32(6.0 / 100.0)
		atrous_denoise(mut y, w, h, [t, t * 0.6, t * 0.35])
	}
	if chroma > 0 {
		t := chroma * f32(12.0 / 100.0)
		th := [t, t * 0.8, t * 0.6, t * 0.45]
		atrous_denoise(mut u, w, h, th)
		atrous_denoise(mut v, w, h, th)
	}
	from_yuv_sqrt(buf, npix, y, u, v)
}

// defringe - подавление ореолов (цветной каймы на контрастных краях,
// аналог «Подавление ореолов» RawTherapee) на месте. strength 0..100.
// Кайма - это пиксели, у которых цветность резко выбивается из окрестности
// И которые лежат на контуре по люме: их цветность подтягивается к размытой
// цветности окрестности. Однородные цветные области не трогаются (их
// цветность совпадает с размытой), плавные переходы - тоже (нет контура).
pub fn defringe(buf &u16, w int, h int, strength f32) {
	if strength <= 0 {
		return
	}
	npix := w * h
	y, u, v := to_yuv_sqrt(buf, npix)
	// Размытая цветность окрестности: два уровня B3 (шаги 1 и 2) ~ гаусс
	// с радиусом ~6 - шире типичной каймы в 2-4 пикселя
	mut tmp := []f32{len: npix}
	mut ub := []f32{len: npix}
	mut vb := []f32{len: npix}
	atrous_blur(u, mut tmp, mut ub, w, h, 1)
	atrous_blur(ub, mut tmp, mut ub, w, h, 2)
	atrous_blur(v, mut tmp, mut vb, w, h, 1)
	atrous_blur(vb, mut tmp, mut vb, w, h, 2)
	s := strength * f32(1.0 / 100.0)
	e0 := f32(6.0) // полувес контура: градиент люмы в sqrt-домене
	t2 := f32(3.0 * 3.0) // полувес отклонения цветности от окрестности
	unsafe {
		py := &f32(y.data)
		pu := &f32(u.data)
		pv := &f32(v.data)
		pub_ := &f32(ub.data)
		pvb := &f32(vb.data)
		for yy in 0 .. h {
			for x in 0 .. w {
				i := yy * w + x
				xl := if x > 0 { i - 1 } else { i }
				xr := if x < w - 1 { i + 1 } else { i }
				yu := if yy > 0 { i - w } else { i }
				yd := if yy < h - 1 { i + w } else { i }
				mut gx := py[xr] - py[xl]
				if gx < 0 {
					gx = -gx
				}
				mut gy := py[yd] - py[yu]
				if gy < 0 {
					gy = -gy
				}
				e := gx + gy
				du := pu[i] - pub_[i]
				dv := pv[i] - pvb[i]
				m2 := du * du + dv * dv
				k := s * (e / (e + e0)) * (m2 / (m2 + t2))
				pu[i] -= k * du
				pv[i] -= k * dv
			}
		}
	}
	from_yuv_sqrt(buf, npix, y, u, v)
}
