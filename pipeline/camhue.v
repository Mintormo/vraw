module pipeline

// Цвет «как JPEG камеры»: таблица оттенок × яркость × насыщенность -
// сдвиг оттенка и множитель насыщенности в ячейках cam_hue_n секторов
// круга HSV × cam_lum_n полос яркости V × cam_sat_n полос насыщенности
// HSV (как HueSatMap/LookTable в профилях Adobe Camera Matching, только
// своя и считается из JPEG кадра).
//
// Камерная кривая и общий множитель насыщенности (match_curve,
// match_saturation) повторяют тон камеры, но не её цвет: у Canon (стиль
// «Стандарт») небо насыщеннее нашего (голубые x1.46 по Lab-хроме),
// зелень сдвинута к голубому (+8°), жёлто-оранжевое - к оранжевому.
// Цвет камеры к тому же зависит от яркости и насыщенности: в светах
// камера поднимает насыщенность почти серого в 1.5-2.5 раза, а чистых
// цветов - лишь в ~1.1 (как «сочность»), тени у неё бледнее наших.
// Разброс между кадрами большой (хрома сектора от x0.63 до x1.22), поэтому
// таблица - своя у кадра: подгонка по совмещённым пикселям нашей проявки
// (уже со смешанной кривой и насыщенностью) и JPEG. Применяется в
// HSL-эквалайзере (hsl_pixel, трилинейно по таблице) вместе с ползунками
// пользователя: сдвиг взвешен насыщенностью пикселя (как у эквалайзера),
// множитель - нет.
//
// Замер на 46 кадрах (ΔE Lab по строкам вне подгонки, размытие 1.5 px -
// без краёв и шума JPEG): только по оттенку 2.47 / 1.79 (19 передержанных /
// 27 обычных) -> 2.20 / 1.61, лучше у всех 46. Подгонка, не улучшившая
// отложенные точки, не применяется (таблица пуста).
import math

// Ячейки таблицы: сектора оттенка (по 15°); полосы яркости V 0..255
// (равные, центры (l + 0.5)·64); полосы насыщенности HSV с центрами
// cam_sat_c. Между центрами - линейно, за крайними - как у крайней.
// Индекс ячейки - (l·cam_sat_n + s)·cam_hue_n + k.
pub const cam_hue_n = 24
pub const cam_lum_n = 4
pub const cam_sat_n = 3
pub const cam_tab_n = cam_hue_n * cam_lum_n * cam_sat_n
const cam_sat_c = [f32(0.05), 0.15, 0.35]!

// Стягивание при малом числе точек, вес данных n/(n + n0): сектор (все
// яркости и насыщенности) - к «без изменений», сектор × полоса яркости -
// к сектору, ячейка - к сектору × полосе
const cam_n0 = 75.0

// Пределы: сдвиг оттенка - секстантов HSV (0.5 = 30°), множитель
// насыщенности
const cam_hue_max = f32(0.5)
const cam_hsat_lo = f32(0.6)
const cam_hsat_hi = f32(1.6)

// Точка участвует в подгонке: насыщенность HSV и яркость не ниже
// (оттенок совсем серых и тёмных неустойчив), каналы не у клипа
const cam_hue_min_s = f32(0.03)
const cam_hue_min_v = f32(25)
const cam_hue_clip = f32(250)

// cam_lookup - сдвиг оттенка и множитель насыщенности таблицы (dh, sk -
// cam_tab_n ячеек) для пикселя с оттенком h (секстанты 0..6),
// насыщенностью s и яркостью v (0..255) HSV: трилинейно по центрам ячеек
@[inline]
fn cam_lookup(dh &f32, sk &f32, h f32, s f32, v f32) (f32, f32) {
	n := cam_hue_n
	ph := h * f32(n) / 6 - 0.5
	mut i0 := int(ph)
	if ph < 0 {
		i0 = -1
	}
	fh := ph - f32(i0)
	a0 := if i0 < 0 { n - 1 } else { i0 }
	a1 := if i0 + 1 >= n { 0 } else { i0 + 1 }
	mut pl := v * f32(cam_lum_n) / 256 - 0.5
	if pl < 0 {
		pl = 0
	} else if pl > f32(cam_lum_n - 1) {
		pl = f32(cam_lum_n - 1)
	}
	l0 := int(pl)
	l1 := if l0 < cam_lum_n - 1 { l0 + 1 } else { l0 }
	fl := pl - f32(l0)
	mut s0 := 0
	mut s1 := 0
	mut fs := f32(0)
	if s >= cam_sat_c[2] {
		s0, s1 = 2, 2
	} else if s >= cam_sat_c[1] {
		s0, s1 = 1, 2
		fs = (s - cam_sat_c[1]) / (cam_sat_c[2] - cam_sat_c[1])
	} else if s > cam_sat_c[0] {
		s1 = 1
		fs = (s - cam_sat_c[0]) / (cam_sat_c[1] - cam_sat_c[0])
	}
	// Четыре строки таблицы (яркость × насыщенность) с весами, в каждой -
	// линейно между двумя секторами оттенка
	w00 := (1 - fl) * (1 - fs)
	w01 := (1 - fl) * fs
	w10 := fl * (1 - fs)
	w11 := fl * fs
	r00 := (l0 * cam_sat_n + s0) * n
	r01 := (l0 * cam_sat_n + s1) * n
	r10 := (l1 * cam_sat_n + s0) * n
	r11 := (l1 * cam_sat_n + s1) * n
	gh := 1 - fh
	mut rd := f32(0)
	mut rk := f32(0)
	unsafe {
		rd = w00 * (dh[r00 + a0] * gh + dh[r00 + a1] * fh) + w01 * (dh[r01 + a0] * gh +
			dh[r01 + a1] * fh) + w10 * (dh[r10 + a0] * gh + dh[r10 + a1] * fh) +
			w11 * (dh[r11 + a0] * gh + dh[r11 + a1] * fh)
		rk = w00 * (sk[r00 + a0] * gh + sk[r00 + a1] * fh) + w01 * (sk[r01 + a0] * gh +
			sk[r01 + a1] * fh) + w10 * (sk[r10 + a0] * gh + sk[r10 + a1] * fh) +
			w11 * (sk[r11 + a0] * gh + sk[r11 + a1] * fh)
	}
	return rd, rk
}

// rgb_hsv - оттенок в секстантах (0..6), насыщенность и яркость HSV
// пикселя 0..255; false - почти серый (размах < 0.5)
fn rgb_hsv(r f32, g f32, b f32) (f32, f32, f32, bool) {
	mx := if r > g { if r > b { r } else { b } } else { if g > b { g } else { b } }
	mn := if r < g { if r < b { r } else { b } } else { if g < b { g } else { b } }
	c := mx - mn
	if c < 0.5 || mx <= 0 {
		return 0, 0, mx, false
	}
	mut h := if mx == r {
		(g - b) / c
	} else if mx == g {
		(b - r) / c + 2
	} else {
		(r - g) / c + 4
	}
	if h < 0 {
		h += 6
	}
	return h, c / mx, mx, true
}

// srgb_lab - Lab (D65) пикселя sRGB 0..255 (для оценки ΔE подгонки)
fn srgb_lab(r f32, g f32, b f32, lin []f32) (f32, f32, f32) {
	lr := lin[int(r)]
	lg := lin[int(g)]
	lb := lin[int(b)]
	x := (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
	y := 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
	z := (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
	fx := lab_f(x)
	fy := lab_f(y)
	fz := lab_f(z)
	return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)
}

@[inline]
fn lab_f(t f32) f32 {
	return if t > 0.008856 { math.powf(t, 1.0 / 3.0) } else { 7.787 * t + 16.0 / 116.0 }
}

fn srgb_lin_lut() []f32 {
	mut l := []f32{len: 256}
	for i in 0 .. 256 {
		c := f32(i) / 255
		l[i] = if c <= 0.04045 { c / 12.92 } else { math.powf((c + 0.055) / 1.055, 2.4) }
	}
	return l
}

// cam_hue_pixel - таблица одного пикселя (как hsl_pixel: сдвиг оттенка
// взвешен насыщенностью, насыщенность HSV не больше 1)
fn cam_hue_pixel(r f32, g f32, b f32, dh []f32, sk []f32) (f32, f32, f32) {
	h0, s, v, ok := rgb_hsv(r, g, b)
	if !ok {
		return r, g, b
	}
	d, k := cam_lookup(unsafe { &f32(dh.data) }, unsafe { &f32(sk.data) }, h0, s, v)
	mut h := h0 + d * s
	if h < 0 {
		h += 6
	} else if h >= 6 {
		h -= 6
	}
	mut s2 := s * k
	if s2 > 1 {
		s2 = 1
	}
	return hsv_rgb(h, s2, v)
}

fn hsv_rgb(h f32, s f32, v f32) (f32, f32, f32) {
	sec := int(h)
	f := h - f32(sec)
	pp := v * (1 - s)
	q := v * (1 - s * f)
	t := v * (1 - s * (1 - f))
	return match sec {
		0 { v, t, pp }
		1 { q, v, pp }
		2 { pp, v, t }
		3 { pp, q, v }
		4 { t, pp, v }
		else { v, pp, q }
	}
}

// cam_cell - ячейка подгонки для оттенка h, насыщенности s и яркости v
// HSV: ближайшие полосы
@[inline]
fn cam_cell(h f32, s f32, v f32) int {
	mut l := int(v * f32(cam_lum_n) / 256)
	if l >= cam_lum_n {
		l = cam_lum_n - 1
	}
	sb := if s < (cam_sat_c[0] + cam_sat_c[1]) / 2 {
		0
	} else if s < (cam_sat_c[1] + cam_sat_c[2]) / 2 {
		1
	} else {
		2
	}
	return (l * cam_sat_n + sb) * cam_hue_n + int(h / 6 * f32(cam_hue_n)) % cam_hue_n
}

// block_rgb - средний цвет блока 2x2 с левым верхним пикселем (x, y)
@[inline]
fn block_rgb(p &u8, stride int, w int, x int, y int) (f32, f32, f32) {
	unsafe {
		a := p + (y * w + x) * stride
		b := a + stride
		c := a + w * stride
		d := c + stride
		return f32(int(a[0]) + b[0] + c[0] + d[0]) / 4, f32(int(a[1]) + b[1] + c[1] + d[1]) / 4,
			f32(int(a[2]) + b[2] + c[2] + d[2]) / 4
	}
}

// match_hues - таблица цвета «как JPEG»: ours и ref_ - совмещённые кадры
// w x h (8 бит RGB, шаг пикселя ostride/rstride байт; ours - наша проявка
// с камерной кривой и насыщенностью). Подгонка - по блокам 2x2 строк
// y % 4 == 0, 1 (усреднение гасит шум и остаток совмещения): в каждой
// ячейке сдвиг - наименьшими квадратами с весом насыщенности, множитель -
// отношение насыщенностей; стягивание (cam_n0) и сглаживание по всем трём
// осям, пределы. Проверка - по строкам y % 4 == 2: если средний ΔE не
// уменьшился хотя бы на 2% - таблицы нет (пустые массивы); строки
// y % 4 == 3 не участвуют ни в чём (для внешней оценки). Возвращает сдвиг
// оттенка (секстанты) и множитель насыщенности, по cam_tab_n ячеек.
pub fn match_hues(ours &u8, ostride int, ref_ &u8, rstride int, w int, h int) ([]f32, []f32) {
	n := cam_hue_n
	nt := cam_tab_n
	mut sh := []f64{len: nt}
	mut ss := []f64{len: nt}
	mut sj := []f64{len: nt}
	mut cnt := []f64{len: nt}
	m := 8 // поле у краёв (остаток совмещения)
	for y := m; y + 1 < h - m; y += 4 {
		for x := m; x + 1 < w - m; x += 2 {
			r, g, b := block_rgb(ours, ostride, w, x, y)
			jr, jg, jb := block_rgb(ref_, rstride, w, x, y)
			if r >= cam_hue_clip || g >= cam_hue_clip || b >= cam_hue_clip || jr >= cam_hue_clip
				|| jg >= cam_hue_clip || jb >= cam_hue_clip {
				continue
			}
			ho, so, vo, ok1 := rgb_hsv(r, g, b)
			hj, sjv, _, ok2 := rgb_hsv(jr, jg, jb)
			if !ok1 || !ok2 || so < cam_hue_min_s || vo < cam_hue_min_v {
				continue
			}
			mut d := hj - ho
			if d > 3 {
				d -= 6
			} else if d < -3 {
				d += 6
			}
			// Точки, где кадры не совпали (край предмета) - в стороне
			if d > 1 || d < -1 {
				continue
			}
			k := cam_cell(ho, so, vo)
			sh[k] += f64(so) * f64(d)
			ss[k] += f64(so) * f64(so)
			sj[k] += f64(sjv) * f64(so)
			cnt[k]++
		}
	}
	// Стягивание по уровням: сектор -> сектор × яркость -> ячейка
	mut dh := []f32{len: nt}
	mut sk := []f32{len: nt}
	for k in 0 .. n {
		mut a := [4]f64{} // sh, ss, sj, cnt сектора
		for c := k; c < nt; c += n {
			a[0] += sh[c]
			a[1] += ss[c]
			a[2] += sj[c]
			a[3] += cnt[c]
		}
		d1, k1 := cam_shrink(a[0], a[1], a[2], a[3], 0, 1)
		for l in 0 .. cam_lum_n {
			mut b := [4]f64{}
			for s in 0 .. cam_sat_n {
				c := (l * cam_sat_n + s) * n + k
				b[0] += sh[c]
				b[1] += ss[c]
				b[2] += sj[c]
				b[3] += cnt[c]
			}
			d2, k2 := cam_shrink(b[0], b[1], b[2], b[3], d1, k1)
			for s in 0 .. cam_sat_n {
				c := (l * cam_sat_n + s) * n + k
				d3, k3 := cam_shrink(sh[c], ss[c], sj[c], cnt[c], d2, k2)
				dh[c] = f32(d3)
				sk[c] = f32(k3)
			}
		}
	}
	// Сглаживание 1-2-1: по кругу оттенков, по полосам яркости и
	// насыщенности (края - сами с собой)
	for ax in 0 .. 3 {
		dh = cam_smooth(dh, ax)
		sk = cam_smooth(sk, ax)
	}
	for c in 0 .. nt {
		dh[c] = clampf(dh[c], -cam_hue_max, cam_hue_max)
		sk[c] = clampf(sk[c], cam_hsat_lo, cam_hsat_hi)
	}
	// Проверка на отложенных строках
	lin := srgb_lin_lut()
	mut eb := 0.0
	mut ea := 0.0
	for y := m + 2; y < h - m; y += 4 {
		for x := m; x < w - m; x += 2 {
			o := unsafe { ours + (y * w + x) * ostride }
			j := unsafe { ref_ + (y * w + x) * rstride }
			r := f32(unsafe { o[0] })
			g := f32(unsafe { o[1] })
			b := f32(unsafe { o[2] })
			jl, ja, jb := srgb_lab(f32(unsafe { j[0] }), f32(unsafe { j[1] }), f32(unsafe { j[2] }), lin)
			ol, oa, ob := srgb_lab(r, g, b, lin)
			eb += math.sqrt(f64((ol - jl) * (ol - jl) + (oa - ja) * (oa - ja) + (ob - jb) * (ob - jb)))
			r2, g2, b2 := cam_hue_pixel(r, g, b, dh, sk)
			nl, na, nb := srgb_lab(clampf(r2, 0, 255), clampf(g2, 0, 255), clampf(b2, 0, 255), lin)
			ea += math.sqrt(f64((nl - jl) * (nl - jl) + (na - ja) * (na - ja) + (nb - jb) * (nb - jb)))
		}
	}
	if eb <= 0 || ea >= eb * 0.98 {
		return []f32{}, []f32{}
	}
	return dh, sk
}

// cam_shrink - сдвиг и множитель по суммам точек, стянутые к значению
// уровня выше (pd, pk) с весом данных cnt/(cnt + cam_n0)
fn cam_shrink(sh f64, ss f64, sj f64, cnt f64, pd f64, pk f64) (f64, f64) {
	if ss <= 0 {
		return pd, pk
	}
	w := cnt / (cnt + cam_n0)
	return pd + (sh / ss - pd) * w, pk + (sj / ss - pk) * w
}

// cam_smooth - сглаживание таблицы 1-2-1 по оси ax: 0 - оттенок (по
// кругу), 1 - яркость, 2 - насыщенность (на краях соседом служит сама
// ячейка)
fn cam_smooth(t []f32, ax int) []f32 {
	n := cam_hue_n
	mut o := []f32{len: t.len}
	for l in 0 .. cam_lum_n {
		for s in 0 .. cam_sat_n {
			for k in 0 .. n {
				c := (l * cam_sat_n + s) * n + k
				a, b := match ax {
					0 {
						(l * cam_sat_n + s) * n + (k + n - 1) % n, (l * cam_sat_n + s) * n + (k + 1) % n
					}
					1 {
						(imax(l - 1, 0) * cam_sat_n + s) * n + k, (imin(l + 1, cam_lum_n - 1) * cam_sat_n +
							s) * n + k
					}
					else {
						(l * cam_sat_n + imax(s - 1, 0)) * n + k, (l * cam_sat_n + imin(s + 1,
							cam_sat_n - 1)) * n + k
					}
				}
				o[c] = (t[a] + 2 * t[c] + t[b]) / 4
			}
		}
	}
	return o
}

@[inline]
fn clampf(v f32, lo f32, hi f32) f32 {
	return if v < lo { lo } else if v > hi { hi } else { v }
}

@[inline]
fn imax(a int, b int) int {
	return if a > b { a } else { b }
}
