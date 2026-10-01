module pipeline

// Собственный пайплайн проявки по линейным 16-битным данным LibRaw.
//
// Вся арифметика во f32, 16 бит - только формат исходника (сенсор Canon
// даёт 14 бит, так что запас есть). Порядок операций:
//
//   линейный RGB -> баланс белого (матрица, wb.v) -> экспозиция
//     -> маска по люме (тени + тон-эквалайзер)
//     -> гамма 1/2.2 + камерная кривая + контраст (S-кривая)
//     -> тональные кривые (общая RGB, затем по каналу) -> насыщенность
//     -> сочность -> HSL-эквалайзер -> резкость (sharpen.v, apply_image) -> 8 бит
//
// Ради живых ползунков всё тяжёлое вынесено в две таблицы, которые
// перестраиваются за ~130К операций при изменении любого параметра:
//   mlut: люма u16 -> общий множитель линейного сигнала (экспозиция,
//         тени, эквалайзер) - маска по яркости, а не по каналу, чтобы
//         подъём теней не сдвигал цвет;
//   flut: линейное значение канала u16 -> тоновое значение 0..255
//         (гамма + камерная кривая + контраст + тональные кривые); при
//         кривых по каналам таблиц три - своя на R, G, B;
//   slut: размытая люма u16 -> множитель «Тени/Света» (см. build_slut) -
//         маска по окрестности сохраняет локальный контраст.
//   HSL: оттенок -> сдвиг оттенка / множители насыщенности и яркости
//         (1024 корзины по кругу оттенков, build_hsl).
// На пиксель остаются только умножения и выборки из таблиц (HSL добавляет
// перевод в HSV и обратно - только когда эквалайзер не нулевой).

import math

// Params - положение всех ползунков. Нулевые значения (и saturation = 1)
// дают нейтральную проявку: чистая гамма 2.2 по камерному ББ.
@[params]
pub struct Params {
pub mut:
	exposure   f32 // экспозиция, EV (-3..+3)
	contrast   f32 // контраст (-1..+1), S-кривая в тоновом пространстве
	saturation f32 = 1.0 // насыщенность (0..4), 1 = как есть
	// Сочность (vibrance) -100..100: бережная насыщенность - блёклые цвета
	// меняются сильнее насыщенных, тона кожи при подъёме защищены
	vibrance f32
	shadows    f32 // проявка теней, EV (-1..+2), маска (1-t)^2
	eq         [5]f32 // тон-эквалайзер, EV: чёрные, тени, средние, света, белые
	sh_shadows    f32 // «Тени/Света»: подъём теней 0..100 (по размытой маске)
	sh_highlights f32 // «Тени/Света»: приглушение светов 0..100 (по размытой маске)
	// Тональная кривая «как камерный JPEG» (match_curve): 256 значений,
	// тон 0..255 -> тон 0..255. Пустой массив - кривой нет (тождественная).
	// Применяется после гаммы, до контраста.
	curve []f32
	// Тональные кривые (редактор кривых): по 256 значений, тон 0..255 ->
	// тон 0..255, пустой массив - тождественная. Сначала общая (tc_rgb),
	// затем своя у канала. Применяются после контраста, до насыщенности.
	tc_rgb []f32
	tc_r   []f32
	tc_g   []f32
	tc_b   []f32
	// HSL-эквалайзер: 8 цветовых диапазонов (hsl_centers - красный,
	// оранжевый, жёлтый, зелёный, голубой, синий, фиолетовый, пурпурный),
	// значения -100..100. Оттенок: 100 = +30°; насыщенность: -100 - ч/б,
	// +100 - ×2; яркость: ±100 = ±1 EV. Сила действия растёт с
	// насыщенностью пикселя - серое не трогается.
	hsl_hue [8]f32
	hsl_sat [8]f32
	hsl_lum [8]f32
	// Дизеринг финального квантования в 8 бит (TPDF ±1 LSB) - убирает
	// полосы (banding) на гладких градиентах (небо). Включён по умолчанию.
	dither bool = true
	// Баланс белого (wb.v): матрица по шагам через пространство камеры с
	// клипом каналов там (WbXform); накладывается на сырьё первой.
	// Производное поле - считается из температуры и оттенка кадра
	// (CamColor.wb_xform); wb_on = false - «как снято», матрицы нет.
	wb_on bool
	wb    WbXform
	// Удаление дымки (dehaze.v, только в apply_image - нужна карта кадра):
	// сила -100..100 (минус - добавить дымку), глубина 0..100 - насколько
	// близко к камере действует (25 - как у тёмного канала без поправки)
	haze       f32
	haze_depth f32 = 25
	// Резкость (sharpen.v) - последний шаг, только в apply_image
	sharp Sharpen
}

// Sharpen - резкость: unsharp mask в тоновом пространстве (по люме или
// по каналам RGB) и Capture-резкость - деконволюция Ричардсона-Люси по
// линейной люме (deconv.v, до тона)
pub struct Sharpen {
pub mut:
	amount  f32        // величина 0..150 (%), 0 - выключена
	radius  f32 = 1.0 // радиус размытия, px полного кадра (0.5..3)
	detail  f32        // порог 0..100: слабые перепады (шум) не усиливаются
	masking f32        // маска по краям 0..100: ровные области не трогаются
	rgb     bool       // по каналам RGB (резче цветные края, возможны цветные ореолы)
	// Capture-резкость: сила 0..100 (0 - выключена), радиус размытия
	// оптики (px полного кадра, 0.4..1.5), порог контраста 0..100 -
	// ровные и шумные места не трогаются
	dc_amount   f32
	dc_radius   f32 = 0.75
	dc_contrast f32 = 10
}

const inv_gamma = f32(1.0 / 2.2)

// eq_ev - добавка эквалайзера в EV для тоновой позиции t (0..1):
// пять узлов на t = 0, 0.25, 0.5, 0.75, 1 с линейной интерполяцией.
fn eq_ev(p &Params, t f32) f32 {
	pos := t * 4.0
	mut i := int(pos)
	if i > 3 {
		i = 3
	}
	frac := pos - f32(i)
	return p.eq[i] * (1.0 - frac) + p.eq[i + 1] * frac
}

// build_mlut - таблица: линейная люма (u16) -> множитель линейного сигнала.
fn build_mlut(p &Params) []f32 {
	e := math.powf(2.0, p.exposure)
	mut m := []f32{len: 65536}
	for y in 0 .. 65536 {
		// Тоновая позиция считается после экспозиции
		mut yl := f32(y) * (1.0 / 65535.0) * e
		if yl > 1.0 {
			yl = 1.0
		}
		t := math.powf(yl, inv_gamma)
		w := (1.0 - t) * (1.0 - t) // маска теней: 1 в черноте, 0 в белом
		ev := p.shadows * w + eq_ev(p, t)
		m[y] = e * math.powf(2.0, ev)
	}
	return m
}

// build_flut - таблица: линейное значение канала (u16) -> тон 0..255 (f32).
// Гамма 1/2.2, затем контраст кривой v^a / (v^a + (1-v)^a), a = 2^contrast:
// гладкая S-кривая без клиппинга, a = 1 - тождественная.
fn build_flut(p &Params) []f32 {
	a := math.powf(2.0, p.contrast)
	has_curve := p.curve.len == 256
	mut f := []f32{len: 65536}
	for x in 0 .. 65536 {
		mut v := math.powf(f32(x) * (1.0 / 65535.0), inv_gamma)
		if has_curve {
			// Камерная кривая (линейная интерполяция между узлами)
			pos := v * 255.0
			mut i := int(pos)
			if i > 254 {
				i = 254
			}
			frac := pos - f32(i)
			v = (p.curve[i] * (1.0 - frac) + p.curve[i + 1] * frac) * f32(1.0 / 255.0)
		}
		mut g := v
		if p.contrast != 0 {
			va := math.powf(v, a)
			ia := math.powf(1.0 - v, a)
			g = if va + ia > 0 { va / (va + ia) } else { f32(0) }
		}
		f[x] = g * 255.0
	}
	return f
}

// curve_at - значение кривой (256 узлов тон -> тон) в тоне v 0..255,
// линейная интерполяция между узлами.
fn curve_at(c []f32, v f32) f32 {
	mut pos := v
	if pos < 0 {
		pos = 0
	} else if pos > 255 {
		pos = 255
	}
	mut i := int(pos)
	if i > 254 {
		i = 254
	}
	frac := pos - f32(i)
	return c[i] * (1.0 - frac) + c[i + 1] * frac
}

// channel_luts - таблицы канал -> тон с тональными кривыми. Без кривых по
// каналам все три указывают на одну таблицу (общая кривая вшита в неё),
// с ними - три своих: tc_c(tc_rgb(flut)).
fn channel_luts(p &Params, base []f32) ([]f32, []f32, []f32) {
	has_rgb := p.tc_rgb.len == 256
	has_ch := p.tc_r.len == 256 || p.tc_g.len == 256 || p.tc_b.len == 256
	if !has_rgb && !has_ch {
		return base, base, base
	}
	mut common := base.clone()
	if has_rgb {
		for x in 0 .. 65536 {
			common[x] = curve_at(p.tc_rgb, common[x])
		}
	}
	if !has_ch {
		return common, common, common
	}
	mut out := [][]f32{len: 3}
	curves := [p.tc_r, p.tc_g, p.tc_b]
	for c in 0 .. 3 {
		if curves[c].len != 256 {
			out[c] = common
			continue
		}
		mut t := []f32{len: 65536}
		for x in 0 .. 65536 {
			t[x] = curve_at(curves[c], common[x])
		}
		out[c] = t
	}
	return out[0], out[1], out[2]
}

// Центры восьми цветовых диапазонов HSL, градусы оттенка: красный,
// оранжевый, жёлтый, зелёный, голубой, синий, фиолетовый, пурпурный.
// Шаг неравномерный (как у Lightroom): тёплых оттенков больше.
pub const hsl_centers = [f32(0), 30, 60, 120, 180, 240, 270, 300]

const hsl_bins = 1024

// HslLut - HSL-эквалайзер по корзинам оттенка (hsl_bins на круг):
// сдвиг оттенка (в секстантах HSV, 1 = 60°), множитель насыщенности,
// добавка к множителю яркости (2^EV - 1).
struct HslLut {
	dh  []f32
	sm  []f32
	lm  []f32
	act []u8 // 1 - корзину эквалайзер меняет; 0 - пиксель выходит сразу
}

fn hsl_active(p &Params) bool {
	for i in 0 .. 8 {
		if p.hsl_hue[i] != 0 || p.hsl_sat[i] != 0 || p.hsl_lum[i] != 0 {
			return true
		}
	}
	return false
}

// hsl_weight - вклад значения диапазонов в оттенок deg: линейная
// интерполяция между соседними центрами по кругу (300° -> 360° = красный).
fn hsl_interp(vals [8]f32, deg f32) f32 {
	for i in 0 .. 8 {
		lo := hsl_centers[i]
		hi := if i == 7 { f32(360) } else { hsl_centers[i + 1] }
		if deg >= lo && deg < hi {
			t := (deg - lo) / (hi - lo)
			nxt := if i == 7 { vals[0] } else { vals[i + 1] }
			return vals[i] * (1 - t) + nxt * t
		}
	}
	return vals[0]
}

fn build_hsl(p &Params) HslLut {
	mut dh := []f32{len: hsl_bins}
	mut sm := []f32{len: hsl_bins}
	mut lm := []f32{len: hsl_bins}
	mut act := []u8{len: hsl_bins}
	for b in 0 .. hsl_bins {
		deg := (f32(b) + 0.5) * 360.0 / f32(hsl_bins)
		dh[b] = hsl_interp(p.hsl_hue, deg) * f32(0.5 / 100.0) // 100 -> 30° = 0.5 секстанта
		mut sv := 1.0 + hsl_interp(p.hsl_sat, deg) * f32(1.0 / 100.0)
		if sv < 0 {
			sv = 0
		}
		sm[b] = sv
		lm[b] = math.powf(2.0, hsl_interp(p.hsl_lum, deg) * f32(1.0 / 100.0)) - 1.0
		if dh[b] != 0 || sm[b] != 1 || lm[b] != 0 {
			act[b] = 1
		}
	}
	return HslLut{dh, sm, lm, act}
}

// build_slut - таблица инструмента «Тени/Света»: РАЗМЫТАЯ люма (u16) ->
// множитель линейного сигнала. Отличие от масок mlut: тоновая позиция
// берётся из размытой люмы окрестности (blur_luma), поэтому соседние
// пиксели получают почти одинаковый множитель - локальный контраст
// сохраняется, тени не становятся плоскими (приём RawTherapee/darktable).
// 100 на ползунке теней = +3 EV в черноте, светов = -2 EV в белом.
fn build_slut(p &Params) []f32 {
	e := math.powf(2.0, p.exposure)
	sh := p.sh_shadows * f32(3.0 / 100.0)
	hl := p.sh_highlights * f32(2.0 / 100.0)
	mut m := []f32{len: 65536}
	for y in 0 .. 65536 {
		mut yl := f32(y) * (1.0 / 65535.0) * e
		if yl > 1.0 {
			yl = 1.0
		}
		t := math.powf(yl, inv_gamma)
		ev := sh * (1.0 - t) * (1.0 - t) - hl * t * t
		m[y] = math.powf(2.0, ev)
	}
	return m
}

// match_curve - тональная кривая «как камерный JPEG» гистограммным
// сопоставлением (приём «Автоопределение тоновой кривой» RawTherapee).
// src - линейный 16-бит RGB (npix пикселей), ref - 8-бит RGB (stride 3,
// ref_npix пикселей) с камерной обработкой (встроенное превью RAW).
// Возвращает монотонную кривую тонов: 256 значений, тон 0..255 нашей
// нейтральной проявки (гамма 2.2) -> тон 0..255 камерного JPEG.
// Кадры могут быть разного размера - сопоставляются квантили яркости.
pub fn match_curve(src &u16, npix int, ref_ &u8, ref_npix int) []f32 {
	// Тон нейтральной проявки для каждой линейной люмы - через LUT.
	// Гистограммам не нужны все пиксели - сэмплируется каждый четвёртый
	// (на форму CDF это не влияет, а стоимость вчетверо ниже).
	p0 := Params{}
	tone := build_flut(&p0)
	mut hs := []f64{len: 256} // гистограмма тонов источника
	mut hr := []f64{len: 256} // гистограмма тонов камерного JPEG
	unsafe {
		mut s := &u16(src)
		tl := &f32(tone.data)
		ps := &f64(hs.data)
		for _ in 0 .. npix / 4 {
			y := (54 * int(s[0]) + 183 * int(s[1]) + 19 * int(s[2])) >> 8
			ps[int(tl[y])] += 1.0
			s += 12
		}
		mut r := &u8(ref_)
		pr := &f64(hr.data)
		for _ in 0 .. ref_npix / 4 {
			pr[(54 * int(r[0]) + 183 * int(r[1]) + 19 * int(r[2])) >> 8] += 1.0
			r += 12
		}
	}
	// Нормированные CDF
	mut cs := []f64{len: 257}
	mut cr := []f64{len: 257}
	for i in 0 .. 256 {
		cs[i + 1] = cs[i] + hs[i]
		cr[i + 1] = cr[i] + hr[i]
	}
	for i in 1 .. 257 {
		cs[i] /= cs[256]
		cr[i] /= cr[256]
	}
	// Сопоставление квантилей: тон v источника -> тон u JPEG той же доли.
	// Тона, которых в кадре нет, - без соответствия (-1)
	mut mapping := []int{len: 256, init: -1}
	mut u := 0
	for v in 0 .. 256 {
		q := cs[v + 1]
		for u < 255 && cr[u + 1] < q {
			u++
		}
		if hs[v] > 0 {
			mapping[v] = u
		}
	}
	return curve_from_mapping(mapping)
}

// Шаг опорных точек камерной кривой, тонов: местные изгибы соответствия
// гистограмм (меньше шага) в кривую не попадают
const curve_step = 32
// Во сколько раз наклон кривой может меняться от отрезка к отрезку
const curve_slope_ratio = 2.0

// curve_from_mapping - гладкая кривая по соответствию тонов mapping (тон
// нейтральной проявки -> тон JPEG, -1 - тона в кадре нет). Соответствие
// гистограмм повторяет каждую неровность распределения: небо на полкадра
// давало участок с наклоном x4.6 рядом с пологим и изломы на границах
// (IMG_0817.CR3: ступенчатое небо). Поэтому: опорные точки через
// curve_step тонов; наклон соседних отрезков различается не больше чем в
// curve_slope_ratio раз (средняя точка тянется к хорде соседей, пока
// ограничение не выполнится); через точки - монотонный кубический сплайн
// (Фрич-Карлсон): гладкий, без выбросов, не убывает.
pub fn curve_from_mapping(mapping []int) []f32 {
	mut xs := [f64(0)]
	mut ys := [f64(0)]
	for x := curve_step / 2; x < 256 - curve_step / 4; x += curve_step {
		// Значение - среднее в ±2 тонах (ступенчатость квантилей); окно
		// шире занижало бы изогнутые участки (тени)
		mut sum := 0.0
		mut n := 0
		for k in x - 2 .. x + 3 {
			if k >= 0 && k < 256 && mapping[k] >= 0 {
				sum += f64(mapping[k])
				n++
			}
		}
		// Пусто - ближайший тон с данными в ±curve_step/4 (тени редкие);
		// нет и его (край гистограммы) - точку не ставить
		if n == 0 {
			for dk in 3 .. curve_step / 4 + 1 {
				for k in [x - dk, x + dk] {
					if n == 0 && k >= 0 && k < 256 && mapping[k] >= 0 {
						sum = f64(mapping[k])
						n = 1
					}
				}
			}
		}
		if n > 0 {
			xs << f64(x)
			ys << sum / f64(n)
		}
	}
	xs << 255
	ys << 255
	// Монотонность точек
	for i in 1 .. ys.len {
		if ys[i] < ys[i - 1] {
			ys[i] = ys[i - 1]
		}
	}
	limit_slopes(xs, mut ys)
	return monotone_spline(xs, ys)
}

// limit_slopes - выравнивание наклонов отрезков ломаной (xs, ys): если
// соседние наклоны различаются больше чем в curve_slope_ratio раз,
// средняя точка сдвигается на четверть пути к хорде соседей; повтор, пока
// всё не уложится (или 200 проходов). Концы (0,0) и (255,255) неподвижны.
fn limit_slopes(xs []f64, mut ys []f64) {
	for _ in 0 .. 200 {
		mut moved := false
		for i in 1 .. xs.len - 1 {
			s0 := (ys[i] - ys[i - 1]) / (xs[i] - xs[i - 1])
			s1 := (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])
			lo := math.min(s0, s1)
			hi := math.max(s0, s1)
			if hi > curve_slope_ratio * math.max(lo, 1e-3) {
				chord := ys[i - 1] + (xs[i] - xs[i - 1]) / (xs[i + 1] - xs[i - 1]) * (ys[i + 1] - ys[i - 1])
				ys[i] += (chord - ys[i]) * 0.25
				moved = true
			}
		}
		if !moved {
			break
		}
	}
}

// monotone_spline - кривая 0..255 через точки (xs возрастают)
// монотонным кубическим сплайном Фрича-Карлсона
fn monotone_spline(xs []f64, ys []f64) []f32 {
	n := xs.len
	mut curve := []f32{len: 256}
	if n < 2 {
		for v in 0 .. 256 {
			curve[v] = f32(v)
		}
		return curve
	}
	mut d := []f64{len: n - 1} // наклоны отрезков
	for k in 0 .. n - 1 {
		d[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k])
	}
	mut m := []f64{len: n} // касательные в точках
	m[0] = d[0]
	m[n - 1] = d[n - 2]
	for k in 1 .. n - 1 {
		m[k] = if d[k - 1] * d[k] <= 0 { 0.0 } else { (d[k - 1] + d[k]) / 2 }
	}
	for k in 0 .. n - 1 {
		if d[k] == 0 {
			m[k] = 0
			m[k + 1] = 0
			continue
		}
		a := m[k] / d[k]
		b := m[k + 1] / d[k]
		h := a * a + b * b
		if h > 9 {
			t := 3 / math.sqrt(h)
			m[k] = t * a * d[k]
			m[k + 1] = t * b * d[k]
		}
	}
	mut k := 0
	for v in 0 .. 256 {
		x := f64(v)
		for k < n - 2 && x > xs[k + 1] {
			k++
		}
		hk := xs[k + 1] - xs[k]
		t := (x - xs[k]) / hk
		t2 := t * t
		t3 := t2 * t
		y := (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * hk * m[k] +
			(-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * hk * m[k + 1]
		curve[v] = f32(math.max(0, math.min(255, y)))
	}
	for v in 1 .. 256 {
		if curve[v] < curve[v - 1] {
			curve[v] = curve[v - 1]
		}
	}
	return curve
}

// blur_luma - маска для «Тени/Света»: BT.709-люма каждого пикселя,
// размытая приближением гауссова фильтра (тройной box blur, радиус ~1%
// большей стороны кадра). Считается один раз на кадр (зависит только от
// сырья, не от ползунков), в apply передаётся указателем.
pub fn blur_luma(src &u16, w int, h int) []u16 {
	npix := w * h
	mut a := []u16{len: npix}
	unsafe {
		mut s := &u16(src)
		d := &u16(a.data)
		for i in 0 .. npix {
			d[i] = u16((54 * u32(s[0]) + 183 * u32(s[1]) + 19 * u32(s[2])) >> 8)
			s += 3
		}
	}
	mut r := (if w > h { w } else { h }) / 100
	if r < 2 {
		r = 2
	}
	mut b := []u16{len: npix}
	for _ in 0 .. 3 {
		box_blur_h(a, mut b, w, h, r)
		box_blur_v(b, mut a, w, h, r)
	}
	return a
}

// box_blur_h - горизонтальный box blur c бегущей суммой; окно
// [x-r, x+r] у краёв укорачивается (среднее по фактическому окну).
fn box_blur_h(src []u16, mut dst []u16, w int, h int, r int) {
	unsafe {
		s := &u16(src.data)
		d := &u16(dst.data)
		for y in 0 .. h {
			base := y * w
			mut sum := u32(0)
			mut hi := 0 // первый ещё не добавленный в окно индекс
			mut lo := 0 // первый входящий в окно индекс
			for x in 0 .. w {
				for hi <= x + r && hi < w {
					sum += u32(s[base + hi])
					hi++
				}
				for lo < x - r {
					sum -= u32(s[base + lo])
					lo++
				}
				d[base + x] = u16(sum / u32(hi - lo))
			}
		}
	}
}

// box_blur_v - вертикальный box blur: бегущие суммы сразу всех колонок
// (проход по строкам - последовательный доступ к памяти).
fn box_blur_v(src []u16, mut dst []u16, w int, h int, r int) {
	mut sums := []u32{len: w}
	unsafe {
		s := &u16(src.data)
		d := &u16(dst.data)
		ps := &u32(sums.data)
		mut hi := 0
		mut lo := 0
		for y in 0 .. h {
			for hi <= y + r && hi < h {
				row := hi * w
				for x in 0 .. w {
					ps[x] += u32(s[row + x])
				}
				hi++
			}
			for lo < y - r {
				row := lo * w
				for x in 0 .. w {
					ps[x] -= u32(s[row + x])
				}
				lo++
			}
			cnt := u32(hi - lo)
			row := y * w
			for x in 0 .. w {
				d[row + x] = u16(ps[x] / cnt)
			}
		}
	}
}

// hsl_pixel - HSL-эквалайзер одного пикселя в тоновом пространстве
// (0..255): RGB -> HSV, по корзине оттенка - сдвиг оттенка, множитель
// насыщенности и яркости, обратно в RGB. Сдвиг оттенка и яркость
// взвешены насыщенностью s: почти серые пиксели (оттенок неустойчив)
// почти не меняются, совсем серые (размах < 0.5) - пропускаются.
@[inline]
fn hsl_pixel(r f32, g f32, b f32, hdh &f32, hsm &f32, hlm &f32, hact &u8) (f32, f32, f32) {
	mx := if r > g { if r > b { r } else { b } } else { if g > b { g } else { b } }
	mn := if r < g { if r < b { r } else { b } } else { if g < b { g } else { b } }
	c := mx - mn
	if c < 0.5 {
		return r, g, b
	}
	inv_c := 1 / c
	mut h := if mx == r {
		(g - b) * inv_c
	} else if mx == g {
		(b - r) * inv_c + 2
	} else {
		(r - g) * inv_c + 4
	}
	if h < 0 {
		h += 6
	}
	mut bin := int(h * f32(hsl_bins) / 6.0)
	if bin >= hsl_bins {
		bin = hsl_bins - 1
	}
	unsafe {
		// Корзину эквалайзер не трогает (обычно правят 1-2 цвета) - выход
		if hact[bin] == 0 {
			return r, g, b
		}
		inv_mx := 1 / mx
		s := c * inv_mx
		v := mx * (1 + hlm[bin] * s)
		mut k := hsm[bin]
		if s * k > 1 {
			k = 1 / s // насыщенность HSV не больше 1
		}
		dh := hdh[bin] * s
		if dh == 0 {
			// Только насыщенность и яркость: канал в HSV - mx·(1 - s·f),
			// f = (mx - ch)/c, поэтому при s -> s·k, mx -> v он становится
			// v/mx · (mx - k·(mx - ch)) - без обратного перевода HSV -> RGB
			q := v * inv_mx
			return q * (mx - k * (mx - r)), q * (mx - k * (mx - g)), q * (mx - k * (mx - b))
		}
		h += dh
		if h < 0 {
			h += 6
		} else if h >= 6 {
			h -= 6
		}
		s2 := s * k
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
}

// Защита тонов кожи при подъёме сочности: оттенки 0..60° (R >= G >= B)
// с центром около 30° (оранжевый) получают вдвое меньший подъём
const vib_skin_c = f32(0.5) // центр защиты в секстанте R-G (0..1 = 0..60°)
const vib_skin_w = f32(1.0 / 0.4) // полуширина 0.4 секстанта (~24°)
const vib_skin_k = f32(0.5) // доля подъёма, которую снимает защита

// vibrance_pixel - сочность одного пикселя в тоновом пространстве
// (0..255): множитель насыщенности 1 + a·(1 - s)², где s - насыщенность
// HSV: блёклые пиксели получают почти полный множитель, чистые цвета
// почти не меняются. При a > 0 тона кожи защищены (vib_skin_*), и
// множитель ограничен так, чтобы канал не ушёл за 0..255 (без клипа
// насыщенных цветов). Раздвигаем каналы от люмы - как насыщенность.
@[inline]
fn vibrance_pixel(r f32, g f32, b f32, a f32) (f32, f32, f32) {
	mx := if r > g { if r > b { r } else { b } } else { if g > b { g } else { b } }
	mn := if r < g { if r < b { r } else { b } } else { if g < b { g } else { b } }
	c := mx - mn
	if c < 0.5 {
		return r, g, b
	}
	s := c / mx
	u := 1 - s
	mut amt := a * u * u
	if a > 0 {
		if r >= g && g >= b {
			// Оттенок в секстанте R-G: 0 - красный, 1 - жёлтый
			h := (g - b) / c
			d := if h > vib_skin_c { h - vib_skin_c } else { vib_skin_c - h }
			w := 1 - d * vib_skin_w
			if w > 0 {
				amt *= 1 - vib_skin_k * w
			}
		}
	}
	mut k := 1 + amt
	l := 0.2126 * r + 0.7152 * g + 0.0722 * b
	if k > 1 {
		// Ограничение: ни один канал не выходит за 0..255
		if mx > l {
			lim := (255.0 - l) / (mx - l)
			if k > lim {
				k = if lim > 1 { lim } else { 1 }
			}
		}
		if mn < l {
			lim := l / (l - mn)
			if k > lim {
				k = if lim > 1 { lim } else { 1 }
			}
		}
	}
	return l + k * (r - l), l + k * (g - l), l + k * (b - l)
}

// apply прогоняет линейный 16-битный RGB (плотный, npix пикселей) через
// пайплайн и пишет 8-битный результат: dst_stride 4 - RGBA для холста
// (альфа 255), 3 - RGB для JPEG. dst должен вмещать npix * dst_stride байт.
// mask - размытая люма кадра (blur_luma, npix значений) для «Тени/Света»;
// nil допустим - тогда sh_shadows/sh_highlights игнорируются.
// Резкость apply не делает (ей нужны размеры кадра) - это apply_image.
pub fn apply(src &u16, mask &u16, npix int, p Params, mut dst []u8, dst_stride int) {
	render(src, mask, unsafe { nil }, npix, p, mut dst, dst_stride, unsafe { nil })
}

// Клип ББ в пространстве камеры (wb.v, WbXform): предел канала и порог
// «канал у предела» - от wb_sat_lo до почти 65535 вес пересвета плавно
// растёт 0 -> 1 (по сырью «как снято» клипнутое значение чуть ниже
// 65535 - демозаика, клип выхода LibRaw)
const wb_clip = f32(65535.0)
const wb_sat_lo = f32(0.98 * 65535.0)
const wb_sat_k = f32(1.0 / (0.018 * 65535.0))

// render - пайплайн по пикселям. tone == nil - 8-битный результат в dst;
// иначе тоновые значения (0..255, ×256 в u16, без квантования и дизера)
// в tone - для резкости, которая досчитает и запишет dst сама.
fn render(src &u16, mask &u16, haze &HazeMap, npix int, p Params, mut dst []u8, dst_stride int, tone &u16) {
	mlut := build_mlut(&p)
	haze_on := p.haze != 0 && !isnil(haze) && haze.d.len == npix
	hlut := if haze_on { build_hlut(&p) } else { []f32{} }
	ha := if haze_on { haze.a } else { [f32(0), 0, 0]! }
	ha0 := ha[0] * 65535.0
	ha1 := ha[1] * 65535.0
	ha2 := ha[2] * 65535.0
	hd := if haze_on { unsafe { &u16(haze.d.data) } } else { unsafe { &u16(nil) } }
	hl := unsafe { &f32(hlut.data) }
	flut_r, flut_g, flut_b := channel_luts(&p, build_flut(&p))
	use_hsl := hsl_active(&p)
	hsl := if use_hsl { build_hsl(&p) } else { HslLut{} }
	use_sh := !isnil(mask) && (p.sh_shadows != 0 || p.sh_highlights != 0)
	slut := if use_sh { build_slut(&p) } else { []f32{} }
	sat := p.saturation
	vib := p.vibrance / 100.0
	wb_on := p.wb_on
	wx := p.wb
	wc := wx.cam
	wd := wx.d
	wr := wx.rgb
	wg := wx.g
	wm := wx.m
	wl := wx.lim
	to_tone := !isnil(tone)
	unsafe {
		mut s := &u16(src)
		mut d := &u8(dst.data)
		mut t := &u16(tone)
		ml := &f32(mlut.data)
		flr := &f32(flut_r.data)
		flg := &f32(flut_g.data)
		flb := &f32(flut_b.data)
		hdh := &f32(hsl.dh.data)
		hsm := &f32(hsl.sm.data)
		hlm := &f32(hsl.lm.data)
		hact := &u8(hsl.act.data)
		sl := &f32(slut.data)
		mk := mask
		for i in 0 .. npix {
			mut cr := f32(s[0])
			mut cg := f32(s[1])
			mut cb := f32(s[2])
			mut y := 0
			if haze_on {
				// Дымка: I = J·t + A·(1 - t); таблица - множитель к (I - A):
				// 1/t при удалении, t при добавлении
				k := hl[hd[i]]
				cr = (cr - ha0) * k + ha0
				cg = (cg - ha1) * k + ha1
				cb = (cb - ha2) * k + ha2
				if cr < 0 {
					cr = 0
				}
				if cg < 0 {
					cg = 0
				}
				if cb < 0 {
					cb = 0
				}
			}
			mx_in := if cr > cg { if cr > cb { cr } else { cb } } else { if cg > cb { cg } else { cb } }
			if wb_on && mx_in < wl {
				// Далеко от клипа - одной матрицей
				ir := cr
				ig := cg
				ib := cb
				cr = wm[0] * ir + wm[1] * ig + wm[2] * ib
				cg = wm[3] * ir + wm[4] * ig + wm[5] * ib
				cb = wm[6] * ir + wm[7] * ig + wm[8] * ib
				if cr < 0 {
					cr = 0
				}
				if cg < 0 {
					cg = 0
				}
				if cb < 0 {
					cb = 0
				}
			} else if wb_on {
				// Светлое: по шагам (wb.v) - в камеру, множители, клип
				// каналов в камере, обратно в sRGB
				mut c := [3]f32{}
				c[0] = wc[0] * cr + wc[1] * cg + wc[2] * cb
				c[1] = wc[3] * cr + wc[4] * cg + wc[5] * cb
				c[2] = wc[6] * cr + wc[7] * cg + wc[8] * cb
				// Пересвет на сенсоре: канал, клипающийся только там, у предела
				sens := (c[wg] - wb_sat_lo) * wb_sat_k
				mut o := [3]f32{}
				for ch in 0 .. 3 {
					mut v := c[ch] * wd[ch]
					if sens > 0 {
						// Клипнутый канал пересвеченного пикселя - в предел
						// (под новым ББ он тоже за пределом)
						mut q := (c[ch] - wb_sat_lo) * wb_sat_k
						if q > 0 {
							q = if q > 1 { 1 } else { q }
							sw := if sens > 1 { f32(1) } else { sens }
							v += (wb_clip - v) * sw * q
						}
					}
					// Отрицательные (вне охвата) не трогаем - как у матрицы
					// быстрого пути, без шва на границе
					o[ch] = if v > wb_clip { wb_clip } else { v }
				}
				cr = wr[0] * o[0] + wr[1] * o[1] + wr[2] * o[2]
				cg = wr[3] * o[0] + wr[4] * o[1] + wr[5] * o[2]
				cb = wr[6] * o[0] + wr[7] * o[1] + wr[8] * o[2]
				if cr < 0 {
					cr = 0
				}
				if cg < 0 {
					cg = 0
				}
				if cb < 0 {
					cb = 0
				}
			}
			if wb_on || haze_on {
				yf := 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
				y = if yf >= 65535.0 { 65535 } else { int(yf) }
			} else {
				// Целочисленная люма BT.709: 54+183+19 = 256
				y = (54 * int(s[0]) + 183 * int(s[1]) + 19 * int(s[2])) >> 8
			}
			mut k := ml[y]
			if use_sh {
				k *= sl[int(mk[i])]
			}
			mut fr := cr * k
			mut fg := cg * k
			mut fb := cb * k
			if fr > 65535.0 {
				fr = 65535.0
			}
			if fg > 65535.0 {
				fg = 65535.0
			}
			if fb > 65535.0 {
				fb = 65535.0
			}
			mut vr := flr[int(fr)]
			mut vg := flg[int(fg)]
			mut vb := flb[int(fb)]
			if sat != 1.0 {
				l := 0.2126 * vr + 0.7152 * vg + 0.0722 * vb
				vr = l + sat * (vr - l)
				vg = l + sat * (vg - l)
				vb = l + sat * (vb - l)
			}
			if vib != 0 {
				vr, vg, vb = vibrance_pixel(vr, vg, vb, vib)
			}
			if use_hsl {
				vr, vg, vb = hsl_pixel(vr, vg, vb, hdh, hsm, hlm, hact)
			}
			if vr < 0 {
				vr = 0
			} else if vr > 255.0 {
				vr = 255.0
			}
			if vg < 0 {
				vg = 0
			} else if vg > 255.0 {
				vg = 255.0
			}
			if vb < 0 {
				vb = 0
			} else if vb > 255.0 {
				vb = 255.0
			}
			if to_tone {
				t[0] = u16(vr * 256.0 + 0.5)
				t[1] = u16(vg * 256.0 + 0.5)
				t[2] = u16(vb * 256.0 + 0.5)
				t += 3
			} else {
				put_px(d, i, vr, vg, vb, p.dither, dst_stride)
				d += dst_stride
			}
			s += 3
		}
	}
}

// put_px - квантование тона 0..255 в 8 бит (с дизером) и запись пикселя;
// i - индекс пикселя (зерно дизера)
@[inline]
fn put_px(d &u8, i int, r f32, g f32, b f32, dither bool, dst_stride int) {
	mut vr := r
	mut vg := g
	mut vb := b
	unsafe {
		if dither {
			// TPDF ±1 LSB: разность двух независимых LCG-семплов в [0,1)
			// даёт треугольное распределение шума (-1, 1), детерминировано
			// по индексу пикселя - воспроизводимость для тестов.
			mut seed := u32(i) * 2654435761
			seed = seed * 1664525 + 1013904223
			r1 := f32(seed >> 8) * (1.0 / 16777216.0)
			seed = seed * 1664525 + 1013904223
			r2 := f32(seed >> 8) * (1.0 / 16777216.0)
			seed = seed * 1664525 + 1013904223
			g1 := f32(seed >> 8) * (1.0 / 16777216.0)
			seed = seed * 1664525 + 1013904223
			g2 := f32(seed >> 8) * (1.0 / 16777216.0)
			seed = seed * 1664525 + 1013904223
			b1 := f32(seed >> 8) * (1.0 / 16777216.0)
			seed = seed * 1664525 + 1013904223
			b2 := f32(seed >> 8) * (1.0 / 16777216.0)
			vr += r1 - r2
			vg += g1 - g2
			vb += b1 - b2
			if vr < 0 {
				vr = 0
			} else if vr > 255.0 {
				vr = 255.0
			}
			if vg < 0 {
				vg = 0
			} else if vg > 255.0 {
				vg = 255.0
			}
			if vb < 0 {
				vb = 0
			} else if vb > 255.0 {
				vb = 255.0
			}
		}
		d[0] = u8(int(vr + 0.5))
		d[1] = u8(int(vg + 0.5))
		d[2] = u8(int(vb + 0.5))
		if dst_stride == 4 {
			d[3] = 255
		}
	}
}
