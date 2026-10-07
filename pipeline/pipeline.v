module pipeline

// Собственный пайплайн проявки по линейным 16-битным данным LibRaw.
//
// Вся арифметика во f32, 16 бит - только формат исходника (сенсор Canon
// даёт 14 бит, так что запас есть). Порядок операций:
//
//   линейный RGB -> баланс белого (матрица, wb.v) -> экспозиция
//     -> маска по люме (тени + тон-эквалайзер, «Тени/Света», Clarity)
//     -> гамма 1/2.2 + камерная кривая + контраст (S-кривая)
//     -> тональные кривые (общая RGB, затем по каналу) -> насыщенность
//     -> сочность -> HSL-эквалайзер -> резкость (sharpen.v, apply_image) -> 8 бит
// Градиентные фильтры (local.v) встраиваются в те же шаги на пиксель:
// температура/оттенок - до люмы, экспозиция и тени/света - в множитель
// k, контраст и насыщенность - после тона.
//
// Ради живых ползунков всё тяжёлое вынесено в две таблицы, которые
// перестраиваются за ~130К операций при изменении любого параметра:
//   mlut: люма u16 -> общий множитель линейного сигнала (экспозиция,
//         тени, эквалайзер) - маска по яркости, а не по каналу, чтобы
//         подъём теней не сдвигал цвет;
//   flut: линейное значение канала u16 -> тоновое значение 0..255
//         (гамма + камерная кривая + контраст + тональные кривые); при
//         кривых по каналам таблиц три - своя на R, G, B. С камерной
//         кривой она смешанная (по каналам и по люме, см. CamTone), и
//         flut делится на две части: гамма и гамма + кривая (CamTone) и
//         тон -> тон (контраст и тональные кривые, build_post);
//   slut: размытая люма u16 -> множитель «Тени/Света» (см. build_slut) -
//         маска по окрестности сохраняет локальный контраст;
//   cmid: люма u16 -> вес Clarity по тону (build_cmid), деталь - log2
//         люмы пикселя к размытой (log2_lut).
//   HSL: оттенок -> сдвиг оттенка / множители насыщенности и яркости
//         (1024 корзины по кругу оттенков, build_hsl).
// На пиксель остаются только умножения и выборки из таблиц (HSL добавляет
// перевод в HSV и обратно - только когда эквалайзер не нулевой).

import math
import bigbuf

// Params - положение всех ползунков. Нулевые значения (и saturation = 1)
// дают нейтральную проявку: чистая гамма 2.2 по камерному ББ.
@[params]
pub struct Params {
pub mut:
	exposure   f32 // экспозиция, EV (-3..+3)
	contrast   f32 // контраст (-1..+1), S-кривая в тоновом пространстве
	saturation f32 = 1.0 // насыщенность (0..4), 1 = как есть
	// Насыщенность «как JPEG камеры» (match_saturation) - производное
	// поле, множитель к saturation; 1 - нет
	cam_sat f32 = 1.0
	// Цвет «как JPEG камеры» (camhue.v, match_hues) - производные поля:
	// сдвиг оттенка (секстанты HSV) и множитель насыщенности на cam_tab_n
	// ячеек оттенок × яркость × насыщенность; пусто - нет. Применяются в
	// HSL-эквалайзере.
	cam_hue  []f32
	cam_hsat []f32
	// Сочность (vibrance) -100..100: бережная насыщенность - блёклые цвета
	// меняются сильнее насыщенных, тона кожи при подъёме защищены
	vibrance f32
	shadows    f32 // проявка теней, EV (-1..+2), маска (1-t)^2
	eq         [5]f32 // тон-эквалайзер, EV: чёрные, тени, средние, света, белые
	sh_shadows    f32 // «Тени/Света»: подъём теней 0..100 (по размытой маске)
	sh_highlights f32 // «Тени/Света»: приглушение светов 0..100 (по размытой маске)
	// Clarity - локальный контраст -100..100 (минус - смягчение): деталь
	// пикселя относительно размытой люмы окрестности (та же маска, что у
	// «Тени/Света»), в основном в средних тонах; см. build_clut
	clarity f32
	// Тональная кривая «как камерный JPEG» (match_curve): 256 значений,
	// тон 0..255 -> тон 0..255. Пустой массив - кривой нет (тождественная).
	// Применяется после гаммы, до контраста, смесью по каналам и по люме
	// (CamTone).
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
	// Градиентные фильтры (local.v) и отображение пикселя буфера в кадр -
	// производное, его задаёт вызывающий под свой буфер (mask_map); без
	// него (w == 0) фильтры не действуют
	masks []Mask
	lmap  MaskMap
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
// гладкая S-кривая без клиппинга, a = 1 - тождественная. Только без
// камерной кривой (она смешанная, см. CamTone и build_post).
fn build_flut(p &Params) []f32 {
	a := math.powf(2.0, p.contrast)
	mut f := []f32{len: 65536}
	for x in 0 .. 65536 {
		v := math.powf(f32(x) * (1.0 / 65535.0), inv_gamma)
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
// любой длины (flut или build_post);
// с ними - три своих: tc_c(tc_rgb(flut)).
fn channel_luts(p &Params, base []f32) ([]f32, []f32, []f32) {
	has_rgb := p.tc_rgb.len == 256
	has_ch := p.tc_r.len == 256 || p.tc_g.len == 256 || p.tc_b.len == 256
	if !has_rgb && !has_ch {
		return base, base, base
	}
	mut common := base.clone()
	if has_rgb {
		for x in 0 .. base.len {
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
		mut t := []f32{len: base.len}
		for x in 0 .. base.len {
			t[x] = curve_at(curves[c], common[x])
		}
		out[c] = t
	}
	return out[0], out[1], out[2]
}

// Камерная кривая - смесь двух способов (доля по люме cam_curve_lum):
// по каналам (каждый канал через кривую) и по люме (кривая к люме тонов,
// каналы - одним множителем). Кривая по каналам сжимает каждый канал
// отдельно и в светах, где у камерной кривой «плечо», выбеливает цвет:
// на передержанных кадрах света у JPEG камеры насыщеннее нашего (ΔC Lab
// +4.5). По люме цвет держится, но обычные кадры уходят от JPEG (тени и
// света пересыщены). Половина на половину - ближе к JPEG на обоих: по 46
// кадрам (ΔE Lab, размытие 1.5 px - без краёв и шума) передержанные 3.30
// -> 2.47, обычные 2.10 -> 1.79, лучше у 44 кадров, хуже - ни у одного
// заметно (IMG_0375 +0.04). Доля одна на все кадры - не подгонка.
const cam_curve_lum = f32(0.5)

// CamTone - таблица смешанной камерной кривой: линейный канал u16 x ->
// тон 0..255 одной гаммой (gc[2x]) и гаммой с кривой (gc[2x + 1]) -
// рядом, в одной строке кэша
// и множитель люмы kl: доля по люме cam_curve_lum × кривая(l) / l по
// люме тонов l × post_scale
struct CamTone {
	gc []f32
	kl []f32
}

// Линейный канал u16 -> тон 0..255 чистой гаммой: от параметров не
// зависит - считается один раз при запуске
const gamma_lut = build_gamma_lut()

fn build_gamma_lut() []f32 {
	mut gl := []f32{len: 65536}
	for x in 0 .. 65536 {
		gl[x] = math.powf(f32(x) * (1.0 / 65535.0), inv_gamma) * 255.0
	}
	return gl
}

fn build_cam_tone(curve []f32) CamTone {
	mut gc := []f32{len: 2 * 65536}
	for x in 0 .. 65536 {
		gc[2 * x] = gamma_lut[x]
		gc[2 * x + 1] = curve_at(curve, gamma_lut[x])
	}
	mut kl := []f32{len: post_n}
	for i in 0 .. post_n {
		// У самого чёрного (< 0.5) - как у 0.5: отношение там неустойчиво
		mut l := f32(i) / post_scale
		if l < 0.5 {
			l = 0.5
		}
		kl[i] = curve_at(curve, l) / l * cam_curve_lum
	}
	return CamTone{gc, kl}
}

// cam_tone_px - смешанная камерная кривая одного пикселя: тоны каналов
// по гамме (r, g, b) и по гамме с кривой (cr, cg, cb) -> тоны 0..255;
// kl - CamTone.kl
@[inline]
fn cam_tone_px(r f32, g f32, b f32, cr f32, cg f32, cb f32, kl &f32) (f32, f32, f32) {
	l := 0.2126 * r + 0.7152 * g + 0.0722 * b
	k := unsafe { kl[int(l * post_scale + 0.5)] }
	c := 1 - cam_curve_lum
	return clamp_tone(r * k + cr * c), clamp_tone(g * k + cg * c), clamp_tone(b * k + cb * c)
}

@[inline]
fn clamp_tone(v f32) f32 {
	return if v < 0 { f32(0) } else if v > 255 { f32(255) } else { v }
}

// Шаг таблицы build_post: тон × post_scale - индекс (1/16 тона: ошибка
// крутой S-кривой контраста < 0.1 тона, а таблица 16 КБ - в кэше)
const post_scale = f32(16)
const post_n = 255 * 16 + 1

// build_post - таблица тон -> тон после смешанной камерной кривой
// (контраст, как в build_flut), индекс - тон × post_scale: тональные
// кривые на неё накладывает channel_luts. Без контраста и кривых - пусто
// (тон как есть).
fn build_post(p &Params) []f32 {
	if p.contrast == 0 && p.tc_rgb.len != 256 && p.tc_r.len != 256 && p.tc_g.len != 256
		&& p.tc_b.len != 256 {
		return []f32{}
	}
	a := math.powf(2.0, p.contrast)
	mut f := []f32{len: post_n}
	for x in 0 .. post_n {
		mut g := f32(x) / f32(post_n - 1)
		if p.contrast != 0 {
			va := math.powf(g, a)
			ia := math.powf(1.0 - g, a)
			g = if va + ia > 0 { va / (va + ia) } else { f32(0) }
		}
		f[x] = g * 255.0
	}
	return f
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

// cam_hue_on - есть таблица цвета «как JPEG» (camhue.v): она - в
// hsl_pixel, не в таблице эквалайзера (зависит ещё от яркости и
// насыщенности пикселя)
fn cam_hue_on(p &Params) bool {
	return p.cam_hue.len == cam_tab_n && p.cam_hsat.len == cam_tab_n
}

fn hsl_active(p &Params) bool {
	if cam_hue_on(p) {
		return true
	}
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
	return fit_curve(mapping, hs)
}

// Сила сглаживания камерной кривой (штраф за кривизну): слабая в тенях -
// кривая повторяет камерный «носок» (почти плоско у чёрного, потом круто
// вверх), сильная выше curve_soft_edge - неровности распределения (небо
// на полкадра) не дают изломов и ступенек на градиентах. Переход - за
// curve_soft_band тонов. Подобрано по IMG_0634/0817/0991 и тесту
// test_curve_from_mapping_smooth (наклон < 3, излом < 0.8 на 8 тонах).
const curve_lam_shadow = 300.0
const curve_lam = 50000.0
const curve_soft_edge = 40
const curve_soft_band = 16.0

// curve_from_mapping - гладкая кривая по соответствию тонов mapping (тон
// нейтральной проявки -> тон JPEG, -1 - тона в кадре нет), все тона
// равноценны (см. fit_curve)
pub fn curve_from_mapping(mapping []int) []f32 {
	return fit_curve(mapping, []f64{len: 256, init: 1})
}

// fit_curve - камерная кривая по соответствию тонов: сглаживающий сплайн
// на 256 тонах - минимум суммы w[v]·(c[v] - mapping[v])² + λ(v)·(c[v-1] -
// 2c[v] + c[v+1])², концы (0, 0) и (255, 255) закреплены. weight - доля
// пикселей тона (вес - корень из неё: пустые тона не мешают, густые - не
// давят всё остальное). Соответствие гистограмм повторяет каждую
// неровность распределения, а прежняя кривая (опорные точки через 32 тона
// с ограничением перепада наклонов) не могла повторить камерный носок в
// тенях и поднимала чёрный (блёклая проявка, до 13 уровней в тенях) и
// занижала светлое небо. Затем - монотонность.
pub fn fit_curve(mapping []int, weight []f64) []f32 {
	n := 256
	mut total := 0.0
	for v in 0 .. n {
		if mapping[v] >= 0 {
			total += weight[v]
		}
	}
	// Ленточная (пятидиагональная) система A·c = b: a[v][k] - элемент
	// (v, v + k - 2), k = 0..4
	mut a := [][]f64{len: n, init: []f64{len: 5}}
	mut b := []f64{len: n}
	for v in 0 .. n {
		if mapping[v] >= 0 && total > 0 {
			// Масштаб веса - как у превью 6 Мп с выборкой каждого четвёртого
			// пикселя (на нём подобраны силы сглаживания)
			w := math.sqrt(weight[v] / total * 1.5e6 + 1) / 30
			a[v][2] += w
			b[v] += w * f64(mapping[v])
		}
	}
	for v in [0, n - 1] {
		a[v][2] += 1e6
		b[v] += 1e6 * f64(v)
	}
	for v in 1 .. n - 1 {
		t := math.min(1.0, math.max(0.0, f64(v - curve_soft_edge) / curve_soft_band))
		lam := curve_lam_shadow * (1 - t) + curve_lam * t
		// Вклад λ·(c[v-1] - 2c[v] + c[v+1])²: строки v-1, v, v+1
		co := [1.0, -2.0, 1.0]
		for r in 0 .. 3 {
			for q in 0 .. 3 {
				row := v - 1 + r
				col := v - 1 + q
				a[row][col - row + 2] += lam * co[r] * co[q]
			}
		}
	}
	// Гаусс без перестановок (матрица симметрична и положительно
	// определена), ширина ленты 2
	for k in 0 .. n {
		p := a[k][2]
		for i in k + 1 .. math.min(n, k + 3) {
			f := a[i][k - i + 2] / p
			if f == 0 {
				continue
			}
			for j in k .. math.min(n, k + 3) {
				a[i][j - i + 2] -= f * a[k][j - k + 2]
			}
			b[i] -= f * b[k]
		}
	}
	mut c := []f64{len: n}
	for k := n - 1; k >= 0; k-- {
		mut sum := b[k]
		for j in k + 1 .. math.min(n, k + 3) {
			sum -= a[k][j - k + 2] * c[j]
		}
		c[k] = sum / a[k][2]
	}
	mut curve := []f32{len: n}
	for v in 0 .. n {
		mut y := math.max(0.0, math.min(255.0, c[v]))
		if v > 0 && y < f64(curve[v - 1]) {
			y = f64(curve[v - 1])
		}
		curve[v] = f32(y)
	}
	curve[0] = 0
	curve[n - 1] = 255
	return curve
}

// Насыщенность «как JPEG»: пределы множителя и средние тона, по которым
// он считается (в провалах цвет не виден, в пересветах каналы упираются
// в 255 - насыщенностью их не раздвинуть)
const cam_sat_min = f32(0.8)
const cam_sat_max = f32(2.0)
const cam_sat_lo = 25
const cam_sat_hi = 230

// match_saturation - множитель насыщенности «как камерный JPEG»: средняя
// цветность (max - min каналов) JPEG ref (8-бит RGB, ref_npix пикселей)
// к средней цветности нашей проявки src (линейный 16-бит RGB, npix) с
// камерной кривой curve и нейтральными остальными настройками - по
// пикселям средних тонов (люма cam_sat_lo..cam_sat_hi, ни один канал не
// у 255). Насыщенность раздвигает каналы от люмы (v' = l + s(v - l)) -
// цветность растёт ровно в s раз, поэтому отношение средних и есть
// множитель. Кадры могут не совпадать попиксельно (размер, дисторсия у
// JPEG исправлена) - сравниваются средние по кадру. Сочность JPEG
// камеры - в основном её стиль изображения (насыщенность), кривая
// яркости её не даёт. Ограничен cam_sat_min..cam_sat_max; не
// посчитать - 1.
pub fn match_saturation(src &u16, npix int, curve []f32, ref_ &u8, ref_npix int) f32 {
	// Тоны нашей проявки - с той же смешанной камерной кривой, что в render
	has_curve := curve.len == 256
	ct := if has_curve { build_cam_tone(curve) } else { CamTone{} }
	tone := build_flut(&Params{})
	mut cs := 0.0
	mut ns := 0
	unsafe {
		mut s := &u16(src)
		tl := &f32(tone.data)
		gc := &f32(ct.gc.data)
		kl := &f32(ct.kl.data)
		for _ in 0 .. npix / 4 {
			mut r := tl[s[0]]
			mut g := tl[s[1]]
			mut b := tl[s[2]]
			if has_curve {
				r, g, b = cam_tone_px(r, g, b, gc[2 * s[0] + 1], gc[2 * s[1] + 1], gc[2 * s[2] + 1],
					kl)
			}
			s += 12
			l := 0.2126 * r + 0.7152 * g + 0.0722 * b
			mx := if r > g { if r > b { r } else { b } } else { if g > b { g } else { b } }
			mn := if r < g { if r < b { r } else { b } } else { if g < b { g } else { b } }
			if l >= cam_sat_lo && l <= cam_sat_hi && mx < 250 {
				cs += f64(mx - mn)
				ns++
			}
		}
	}
	mut cr := 0.0
	mut nr := 0
	unsafe {
		mut q := &u8(ref_)
		for _ in 0 .. ref_npix / 4 {
			r := f32(q[0])
			g := f32(q[1])
			b := f32(q[2])
			q += 12
			l := 0.2126 * r + 0.7152 * g + 0.0722 * b
			mx := if r > g { if r > b { r } else { b } } else { if g > b { g } else { b } }
			mn := if r < g { if r < b { r } else { b } } else { if g < b { g } else { b } }
			if l >= cam_sat_lo && l <= cam_sat_hi && mx < 250 {
				cr += f64(mx - mn)
				nr++
			}
		}
	}
	if ns < 100 || nr < 100 || cs <= 0 {
		return 1
	}
	k := f32((cr / f64(nr)) / (cs / f64(ns)))
	return if k < cam_sat_min { cam_sat_min } else if k > cam_sat_max { cam_sat_max } else { k }
}

// blur_luma - маска для «Тени/Света»: BT.709-люма каждого пикселя,
// размытая приближением гауссова фильтра (тройной box blur, радиус ~1%
// большей стороны кадра). Считается один раз на кадр (зависит только от
// сырья, не от ползунков), в apply передаётся указателем.
pub fn blur_luma(src &u16, w int, h int) []u16 {
	mut a := []u16{len: w * h}
	blur_luma_into(src, w, h, mut a)
	return a
}

// blur_luma_into - то же в готовый буфер a (w * h; экспорт даёт буфер вне
// сборщика - bigbuf)
pub fn blur_luma_into(src &u16, w int, h int, mut a []u16) {
	npix := w * h
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
	mut b := bigbuf.new_u16(npix)
	for _ in 0 .. 3 {
		box_blur_h(a, mut b, w, h, r)
		box_blur_v(b, mut a, w, h, r)
	}
	bigbuf.free(mut b)
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
// почти не меняются, совсем серые (размах < 0.5) - пропускаются. cdh,
// csk - таблица цвета «как JPEG» (camhue.v, cam_lookup) или nil: её сдвиг
// и множитель - вместе с эквалайзером.
@[inline]
fn hsl_pixel(r f32, g f32, b f32, hdh &f32, hsm &f32, hlm &f32, hact &u8, cdh &f32, csk &f32) (f32, f32, f32) {
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
		// Корзину эквалайзер не трогает (обычно правят 1-2 цвета) и
		// таблицы цвета нет - выход
		user := hact[bin] != 0
		cam := !isnil(cdh)
		if !user && !cam {
			return r, g, b
		}
		inv_mx := 1 / mx
		s := c * inv_mx
		mut udh := f32(0)
		mut k := f32(1)
		mut v := mx
		if user {
			udh = hdh[bin]
			k = hsm[bin]
			v = mx * (1 + hlm[bin] * s)
		}
		if cam {
			cd, ck := cam_lookup(cdh, csk, h, s, mx)
			udh += cd
			k *= ck
		}
		if s * k > 1 {
			k = 1 / s // насыщенность HSV не больше 1
		}
		dh := udh * s
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
// mask - маска окрестности кадра (luma_masks, npix * mask_ch значений:
// размытая люма «Тени/Света» и вес Clarity); nil допустим - тогда
// «Тени/Света» и Clarity не действуют.
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
	lc := local_ctx(&p)
	render_ex(src, mask, haze, npix, p, mut dst, dst_stride, tone, &lc, unsafe { nil })
}

// render_ex - render с готовыми фильтрами lc; wout != nil - показ маски:
// вместо снимка в wout (npix байт) сумма весов фильтров lc (mask_view)
fn render_ex(src &u16, mask &u16, haze &HazeMap, npix int, p Params, mut dst []u8, dst_stride int, tone &u16, lc &LocalCtx, wout &u8) {
	mlut := build_mlut(&p)
	haze_on := p.haze != 0 && !isnil(haze) && haze.d.len == npix
	hlut := if haze_on { build_hlut(&p) } else { []f32{} }
	ha := if haze_on { haze.a } else { [f32(0), 0, 0]! }
	ha0 := ha[0] * 65535.0
	ha1 := ha[1] * 65535.0
	ha2 := ha[2] * 65535.0
	hd := if haze_on { unsafe { &u16(haze.d.data) } } else { unsafe { &u16(nil) } }
	hl := unsafe { &f32(hlut.data) }
	// Камерная кривая - смешанная (CamTone): тогда flut_* - таблицы тон ->
	// тон после неё (build_post), пустые - без контраста и кривых
	cam_curve := p.curve.len == 256
	ct := if cam_curve { build_cam_tone(p.curve) } else { CamTone{} }
	post := if cam_curve { build_post(&p) } else { []f32{} }
	flut_r, flut_g, flut_b := if cam_curve {
		if post.len > 0 { channel_luts(&p, post) } else { post, post, post }
	} else {
		channel_luts(&p, build_flut(&p))
	}
	use_hsl := hsl_active(&p)
	hsl := if use_hsl { build_hsl(&p) } else { HslLut{} }
	use_sh := !isnil(mask) && (p.sh_shadows != 0 || p.sh_highlights != 0)
	slut := if use_sh { build_slut(&p) } else { []f32{} }
	use_cl := !isnil(mask) && (p.clarity != 0 || lc.use_cl)
	cmid := if use_cl { build_cmid(&p) } else { []f32{} }
	sat := p.saturation * p.cam_sat
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
	ctx := RenderCtx{
		lc:         unsafe { lc } // живёт до конца render_ex (потоки ждём здесь)
		wout:       wout
		src:        src
		mask:       mask
		dst:        unsafe { &u8(dst.data) }
		dst_stride: dst_stride
		tone:       tone
		to_tone:    to_tone
		dither:     p.dither
		haze_on:    haze_on
		hl:         hl
		hd:         hd
		ha0:        ha0
		ha1:        ha1
		ha2:        ha2
		ml:         unsafe { &f32(mlut.data) }
		flr:        unsafe { &f32(flut_r.data) }
		flg:        unsafe { &f32(flut_g.data) }
		flb:        unsafe { &f32(flut_b.data) }
		cam_curve:  cam_curve
		cgc:        unsafe { &f32(ct.gc.data) }
		ckl:        unsafe { &f32(ct.kl.data) }
		use_post:   post.len > 0
		use_hsl:    use_hsl
		hdh:        unsafe { &f32(hsl.dh.data) }
		hsm:        unsafe { &f32(hsl.sm.data) }
		hlm:        unsafe { &f32(hsl.lm.data) }
		hact:       unsafe { &u8(hsl.act.data) }
		cdh:        if cam_hue_on(&p) { unsafe { &f32(p.cam_hue.data) } } else { unsafe { nil } }
		csk:        if cam_hue_on(&p) { unsafe { &f32(p.cam_hsat.data) } } else { unsafe { nil } }
		use_sh:     use_sh
		sl:         unsafe { &f32(slut.data) }
		use_cl:     use_cl
		cl:         unsafe { &f32(cmid.data) }
		pcl:        p.clarity / 100
		sat:        sat
		vib:        vib
		wb_on:      wb_on
		wc:         wc
		wd:         wd
		wr:         wr
		wg:         wg
		wm:         wm
		wl:         wl
	}
	// Пиксели независимы (дизер - по номеру пикселя): большие кадры -
	// полосами в несколько потоков (превью 6 Мп: 70 -> ~15 мс), таблицы
	// общие, только чтение. Функция потока - обычная, не замыкание (post.v)
	nt := bands(npix, 1)
	if nt <= 1 {
		render_rows(&ctx, 0, npix)
		return
	}
	step := (npix + nt - 1) / nt
	mut ts := []thread{}
	for a := 0; a < npix; a += step {
		ts << spawn render_rows(&ctx, a, imin(npix, a + step))
	}
	ts.wait()
}

// RenderCtx - всё, что нужно циклу по пикселям render_rows: входы,
// выходы и готовые таблицы (общие для потоков, только чтение)
struct RenderCtx {
	lc         &LocalCtx = unsafe { nil } // градиентные фильтры (n == 0 - нет)
	wout       &u8       = unsafe { nil } // показ маски: вес вместо снимка
	src        &u16 = unsafe { nil }
	mask       &u16 = unsafe { nil }
	dst        &u8  = unsafe { nil }
	dst_stride int
	tone       &u16 = unsafe { nil }
	to_tone    bool
	dither     bool
	haze_on    bool
	hl         &f32 = unsafe { nil }
	hd         &u16 = unsafe { nil }
	ha0        f32
	ha1        f32
	ha2        f32
	ml         &f32 = unsafe { nil }
	flr        &f32 = unsafe { nil }
	flg        &f32 = unsafe { nil }
	flb        &f32 = unsafe { nil }
	cam_curve  bool // камерная кривая смешанная: cgc/ckl, затем flr.. - тон -> тон
	cgc        &f32 = unsafe { nil }
	ckl        &f32 = unsafe { nil }
	use_post   bool
	use_hsl    bool
	hdh        &f32 = unsafe { nil }
	hsm        &f32 = unsafe { nil }
	hlm        &f32 = unsafe { nil }
	hact       &u8  = unsafe { nil }
	cdh        &f32 = unsafe { nil } // таблица цвета «как JPEG» или nil
	csk        &f32 = unsafe { nil }
	use_sh     bool
	sl         &f32 = unsafe { nil }
	use_cl     bool
	cl         &f32 = unsafe { nil } // вес Clarity по тону (build_cmid)
	pcl        f32 // Clarity кадра, -1..1
	sat        f32
	vib        f32
	wb_on      bool
	wc         [9]f32
	wd         [3]f32
	wr         [9]f32
	wg         int
	wm         [9]f32
	wl         f32
}

// render_rows - пиксели i0..i1 (render): тело цикла пайплайна
fn render_rows(rc &RenderCtx, i0 int, i1 int) {
	haze_on := rc.haze_on
	hl := rc.hl
	hd := rc.hd
	ha0 := rc.ha0
	ha1 := rc.ha1
	ha2 := rc.ha2
	wb_on := rc.wb_on
	wc := rc.wc
	wd := rc.wd
	wr := rc.wr
	wg := rc.wg
	wm := rc.wm
	wl := rc.wl
	use_sh := rc.use_sh
	use_cl := rc.use_cl
	pcl := rc.pcl
	use_hsl := rc.use_hsl
	sat := rc.sat
	vib := rc.vib
	to_tone := rc.to_tone
	dst_stride := rc.dst_stride
	dither := rc.dither
	lc := rc.lc
	local := lc.n > 0
	view := !isnil(rc.wout)
	wo := rc.wout
	// Пиксель (x, y) буфера - для веса фильтров
	mut px := if local { i0 % lc.w } else { 0 }
	mut py := if local { i0 / lc.w } else { 0 }
	unsafe {
		mut s := rc.src + i0 * 3
		mut d := rc.dst + i0 * dst_stride
		mut t := if to_tone { rc.tone + i0 * 3 } else { rc.tone }
		ml := rc.ml
		flr := rc.flr
		flg := rc.flg
		flb := rc.flb
		cam_curve := rc.cam_curve
		cgc := rc.cgc
		ckl := rc.ckl
		use_post := rc.use_post
		hdh := rc.hdh
		hsm := rc.hsm
		hlm := rc.hlm
		hact := rc.hact
		cdh := rc.cdh
		csk := rc.csk
		sl := rc.sl
		cl := rc.cl
		lg := &f32(log2_lut.data)
		mk := rc.mask
		for i in i0 .. i1 {
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
			mut ls := LocalSum{}
			if local {
				ls = local_sum(lc, f32(px), f32(py), y, cr, cg, cb)
				px++
				if px == lc.w {
					px = 0
					py++
				}
				if view {
					// Показ маски: вес вместо снимка
					wv := if ls.w > 1 { f32(1) } else { ls.w }
					wo[i] = u8(int(wv * 255 + 0.5))
					s += 3
					continue
				}
				if ls.any && lc.use_wb && (ls.temp != 0 || ls.tint != 0) {
					// Температура и оттенок фильтров - множители каналов (люма та
					// же - y не меняется)
					gr, gg, gb := local_wb(&ls)
					cr *= gr
					cg *= gg
					cb *= gb
				}
			}
			mut k := ml[y]
			if use_sh {
				k *= sl[int(mk[i * mask_ch])]
			}
			if use_cl {
				// Clarity (clarity.v): деталь - сырая люма к размытой (маска
				// - тоже по сырью, до ББ и дымки) с весом фактуры, сила - по
				// тону люмы после них
				// Сила - кадр + фильтры (как экспозиция фильтров)
				mut a := pcl
				if ls.any {
					a += ls.cl
				}
				cs := if a != 0 { clarity_gain(a) * cl[y] } else { f32(0) }
				if cs != 0 {
					yr := if wb_on || haze_on {
						(54 * int(s[0]) + 183 * int(s[1]) + 19 * int(s[2])) >> 8
					} else {
						y
					}
					mp := mk + i * mask_ch
					dl := (lg[yr] - lg[int(mp[0])]) * f32(mp[1]) * (1.0 / 65535.0)
					k *= exp2f(clarity_ev(dl, cs))
				}
			}
			if ls.any && lc.use_ev {
				// Экспозиция фильтров и их тени/света (по тоновой позиции)
				mut ev := ls.ev
				if lc.use_tn {
					tp := lc.tl[y]
					ev += local_tone_ev * (ls.sh * (1 - tp) * (1 - tp) + ls.hi * tp * tp)
				}
				if ev != 0 {
					k *= exp2f(ev)
				}
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
			mut vr := f32(0)
			mut vg := f32(0)
			mut vb := f32(0)
			if cam_curve {
				ir := 2 * int(fr)
				ig := 2 * int(fg)
				ib := 2 * int(fb)
				vr, vg, vb = cam_tone_px(cgc[ir], cgc[ig], cgc[ib], cgc[ir + 1], cgc[ig + 1],
					cgc[ib + 1], ckl)
				if use_post {
					vr = flr[int(vr * post_scale + 0.5)]
					vg = flg[int(vg * post_scale + 0.5)]
					vb = flb[int(vb * post_scale + 0.5)]
				}
			} else {
				vr = flr[int(fr)]
				vg = flg[int(fg)]
				vb = flb[int(fb)]
			}
			mut sp := sat
			if ls.any {
				if lc.use_cn && ls.con != 0 {
					vr = local_contrast(lc, ls.con, vr)
					vg = local_contrast(lc, ls.con, vg)
					vb = local_contrast(lc, ls.con, vb)
				}
				if lc.use_st && ls.sat != 0 {
					sp = sat * if ls.sat < -1 { f32(0) } else { 1 + ls.sat }
				}
			}
			if sp != 1.0 {
				l := 0.2126 * vr + 0.7152 * vg + 0.0722 * vb
				vr = l + sp * (vr - l)
				vg = l + sp * (vg - l)
				vb = l + sp * (vb - l)
			}
			if vib != 0 {
				vr, vg, vb = vibrance_pixel(vr, vg, vb, vib)
			}
			if use_hsl {
				vr, vg, vb = hsl_pixel(vr, vg, vb, hdh, hsm, hlm, hact, cdh, csk)
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
				put_px(d, i, vr, vg, vb, dither, dst_stride)
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
