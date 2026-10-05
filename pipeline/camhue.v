module pipeline

// Цвет «как JPEG камеры»: таблица по оттенку - сдвиг оттенка и множитель
// насыщенности на cam_hue_n секторов круга HSV (как HueSatMap в профилях
// Adobe Camera Matching, только своя и считается из JPEG кадра).
//
// Камерная кривая и общий множитель насыщенности (match_curve,
// match_saturation) повторяют тон камеры, но не её цвет: у Canon (стиль
// «Стандарт») небо насыщеннее нашего (голубые x1.46 по Lab-хроме),
// зелень сдвинута к голубому (+8°), жёлто-оранжевое - к оранжевому.
// Разброс между кадрами большой (хрома сектора от x0.63 до x1.22), поэтому
// таблица - своя у кадра: подгонка по совмещённым пикселям нашей проявки
// (уже с кривой и насыщенностью) и JPEG. Применяется в HSL-эквалайзере
// (build_hsl) вместе с ползунками пользователя: сдвиг взвешен
// насыщенностью пикселя (как у эквалайзера), множитель - нет.
//
// Проверка на 37 кадрах (сравнение по точкам, не участвовавшим в
// подгонке): средний ΔE (Lab) 3.29 -> 2.91, кадр с небом IMG_0817 8.3 ->
// 3.7; ни один кадр не стал хуже - подгонка, не улучшившая отложенные
// точки, не применяется (таблица пуста).
import math

// Секторов оттенка в таблице (по 15°)
pub const cam_hue_n = 24

// Сила стягивания сектора к «без изменений» при малом числе точек:
// вес данных n/(n + cam_hue_n0)
const cam_hue_n0 = 150.0

// Пределы: сдвиг оттенка - секстантов HSV (0.5 = 30°), множитель
// насыщенности
const cam_hue_max = f32(0.5)
const cam_hsat_lo = f32(0.6)
const cam_hsat_hi = f32(1.6)

// Точка участвует в подгонке: насыщенность HSV и яркость не ниже
// (оттенок серых и тёмных неустойчив), каналы не у клипа
const cam_hue_min_s = f32(0.12)
const cam_hue_min_v = f32(25)
const cam_hue_clip = 250

// cam_table - значение таблицы (cam_hue_n секторов) для оттенка h в
// секстантах (0..6): линейно между центрами соседних секторов по кругу
fn cam_table(t []f32, h f32) f32 {
	pos := h * f32(cam_hue_n) / 6 - 0.5
	i0 := int(math.floor(f64(pos)))
	f := pos - f32(i0)
	a := t[(i0 % cam_hue_n + cam_hue_n) % cam_hue_n]
	b := t[((i0 + 1) % cam_hue_n + cam_hue_n) % cam_hue_n]
	return a * (1 - f) + b * f
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
	mut h := h0 + cam_table(dh, h0) * s
	if h < 0 {
		h += 6
	} else if h >= 6 {
		h -= 6
	}
	mut s2 := s * cam_table(sk, h0)
	if s2 > 1 {
		s2 = 1
	}
	sec := int(h)
	f := h - f32(sec)
	pp := v * (1 - s2)
	q := v * (1 - s2 * f)
	t := v * (1 - s2 * (1 - f))
	return match sec {
		0 { v, t, pp }
		1 { q, v, pp }
		2 { pp, v, t }
		3 { pp, q, v }
		4 { t, pp, v }
		else { v, pp, q }
	}
}

// match_hues - таблица цвета «как JPEG»: ours и ref_ - совмещённые кадры
// w x h (8 бит RGB, шаг пикселя ostride/rstride байт; ours - наша проявка
// с камерной кривой и насыщенностью). Подгонка - по строкам y % 2 == 0
// (сдвиг - наименьшими квадратами с весом насыщенности, множитель -
// отношение насыщенностей), стягивание к «без изменений» при малом числе
// точек, сглаживание по кругу, пределы. Проверка - по строкам y % 4 == 1:
// если средний ΔE не уменьшился хотя бы на 2% - таблицы нет (пустые
// массивы). Возвращает сдвиг оттенка (секстанты) и множитель насыщенности.
pub fn match_hues(ours &u8, ostride int, ref_ &u8, rstride int, w int, h int) ([]f32, []f32) {
	n := cam_hue_n
	mut sh := []f64{len: n}
	mut ss := []f64{len: n}
	mut sj := []f64{len: n}
	mut cnt := []int{len: n}
	m := 8 // поле у краёв (остаток совмещения)
	for y := m; y < h - m; y += 2 {
		for x in m .. w - m {
			o := unsafe { ours + (y * w + x) * ostride }
			j := unsafe { ref_ + (y * w + x) * rstride }
			if !usable(o, j) {
				continue
			}
			ho, so, vo, ok1 := rgb_hsv(f32(unsafe { o[0] }), f32(unsafe { o[1] }), f32(unsafe { o[2] }))
			hj, sjv, _, ok2 := rgb_hsv(f32(unsafe { j[0] }), f32(unsafe { j[1] }), f32(unsafe { j[2] }))
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
			k := int(ho / 6 * f32(n)) % n
			sh[k] += f64(so) * f64(d)
			ss[k] += f64(so) * f64(so)
			sj[k] += f64(sjv) * f64(so)
			cnt[k]++
		}
	}
	mut dh0 := []f32{len: n}
	mut sk0 := []f32{len: n}
	for k in 0 .. n {
		wgt := f64(cnt[k]) / (f64(cnt[k]) + cam_hue_n0)
		dh0[k] = if ss[k] > 0 { f32(sh[k] / ss[k] * wgt) } else { 0 }
		sk0[k] = if ss[k] > 0 { f32(1 + (sj[k] / ss[k] - 1) * wgt) } else { 1 }
	}
	mut dh := []f32{len: n}
	mut sk := []f32{len: n}
	for k in 0 .. n {
		a := (k + n - 1) % n
		b := (k + 1) % n
		dh[k] = clampf((dh0[a] + 2 * dh0[k] + dh0[b]) / 4, -cam_hue_max, cam_hue_max)
		sk[k] = clampf((sk0[a] + 2 * sk0[k] + sk0[b]) / 4, cam_hsat_lo, cam_hsat_hi)
	}
	// Проверка на отложенных строках
	lin := srgb_lin_lut()
	mut eb := 0.0
	mut ea := 0.0
	for y := m + 1; y < h - m; y += 4 {
		for x := m; x < w - m; x += 2 {
			o := unsafe { ours + (y * w + x) * ostride }
			j := unsafe { ref_ + (y * w + x) * rstride }
			if !usable(o, j) {
				continue
			}
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

// usable - пара точек годится для сравнения: ни один канал не у клипа
@[inline]
fn usable(o &u8, j &u8) bool {
	unsafe {
		return o[0] < cam_hue_clip && o[1] < cam_hue_clip && o[2] < cam_hue_clip
			&& j[0] < cam_hue_clip && j[1] < cam_hue_clip && j[2] < cam_hue_clip
	}
}

@[inline]
fn clampf(v f32, lo f32, hi f32) f32 {
	return if v < lo { lo } else if v > hi { hi } else { v }
}
