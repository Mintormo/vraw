module pipeline

// Clarity (локальный контраст): усиление детали пикселя относительно
// размытой люмы окрестности, кроме сильных краёв.
//
// Деталь d = (1 − a) · log2(люма / размытая люма), EV; множитель
// линейного сигнала 2^(сила(тон) · g(d)) - одинаковый для R, G, B (цвет не
// сдвигается). Размытая люма - та же, что у «Тени/Света» (blur_luma). На
// резкой границе (лес на фоне неба) размытие смешивает обе стороны: небо
// у края светлее размытого, лес темнее - без веса Clarity рисовал бы
// светлую полосу над лесом (ореол, замер IMG_0817: до +17 уровней). Вес
// фактуры 1 − a - из управляемого фильтра (He, Sun, Tang 2010) по люме в
// логарифмах: a = var / (var + eps) по окну. На ровной фактуре var мал - a
// ≈ 0, деталь усиливается; у сильного края var велик - a ≈ 1, детали
// (и ореола) нет; в логарифмах eps не зависит от экспозиции. a считается
// на уменьшенной до cl_work копии и сглаживается тем же окном - поле
// гладкое, поэтому на размер буфера - билинейно, а превью, фрагмент 1:1
// (маска превью с увеличением) и полный кадр дают одно и то же.
//
// Вес хранится вторым каналом маски окрестности (luma_masks: канал 0 -
// размытая люма «Тени/Света», 1 - вес Clarity ×65535) и вместе с ней
// проходит геометрию, кэш кадров и увеличение фрагмента 1:1.
import math
import bigbuf

// mask_ch - каналов в маске окрестности (luma_masks)
pub const mask_ch = 2

// Сила: g(d) - мягкие пределы: слабые перепады (шум, порог cl_noise EV)
// почти не усиливаются, сильные растут медленнее (полунасыщение на
// cl_halo EV). 100 на ползунке - деталь средних тонов ×(1 + cl_gain) в EV;
// минус - к размытой: -100 - ×(1 - cl_gain_neg) (больше 1 перевернул бы
// деталь). Подбор (07.10.2026) по IMG_0991 (листва: разброс средних
// деталей) и IMG_0817 (небо над лесом: подъём неба у кромки): окно 0.03,
// eps 0.06, усиление 3.4 - текстура ×1.25, ореол неба в среднем +0.4
// уровня (максимум +5); без веса фактуры при той же силе - +10.6 (+80).
// Окно уже (0.01, 0.02) пропускает хвосты размытия: ореол ×5 и ×2.
const cl_gain = f32(3.0)
const cl_gain_neg = f32(0.9)
const cl_noise = f32(0.04)
const cl_halo = f32(1.0)

const cl_work = 1024 // длинная сторона рабочей копии
const cl_radius = f32(0.015) // радиус окна - доля длинной стороны
const cl_eps = f32(0.15) // EV²: перепады больше ~√eps - края, а не фактура
const cl_flat = f32(0.002) // EV²: окно с разбросом меньше ~√cl_flat - ровное

// luma_masks - маска окрестности кадра (mask_ch каналов на пиксель):
// размытая люма «Тени/Света» и вес Clarity. Считается один раз на кадр
// (зависит только от сырья).
pub fn luma_masks(src &u16, w int, h int) []u16 {
	mut a := []u16{len: w * h * mask_ch}
	luma_masks_into(src, w, h, mut a)
	return a
}

// luma_masks_into - то же в готовый буфер a (w * h * mask_ch; экспорт
// даёт буфер вне сборщика - bigbuf)
pub fn luma_masks_into(src &u16, w int, h int, mut a []u16) {
	luma_masks_eps(src, w, h, cl_eps, mut a)
}

// luma_masks_eps - то же с заданным eps (EV²; подбор в экспериментах)
pub fn luma_masks_eps(src &u16, w int, h int, eps f32, mut a []u16) {
	npix := w * h
	mut b := bigbuf.new_u16(npix)
	blur_luma_into(src, w, h, mut b)
	unsafe {
		d := &u16(a.data)
		s := &u16(b.data)
		for i in 0 .. npix {
			d[i * mask_ch] = s[i]
		}
	}
	bigbuf.free(mut b)
	clarity_weight_ch(src, w, h, eps, unsafe { &u16(a.data) + 1 }, mask_ch)
}

// clarity_weight_ch - вес фактуры Clarity (1 − a) ×65535 в out[i * stride]
fn clarity_weight_ch(src &u16, w int, h int, eps f32, out &u16, stride int) {
	// Рабочая копия: log2 средней люмы блоков f x f
	mut f := (if w > h { w } else { h } + cl_work - 1) / cl_work
	if f < 1 {
		f = 1
	}
	sw := (w + f - 1) / f
	sh := (h + f - 1) / f
	n := sw * sh
	mut acc := []u32{len: n}
	mut cnt := []u32{len: n}
	unsafe {
		mut s := &u16(src)
		for y in 0 .. h {
			row := (y / f) * sw
			for x in 0 .. w {
				j := row + x / f
				acc[j] += u32((54 * int(s[0]) + 183 * int(s[1]) + 19 * int(s[2])) >> 8)
				cnt[j]++
				s += 3
			}
		}
	}
	mut li := []f32{len: n}
	mut li2 := []f32{len: n}
	for j in 0 .. n {
		l := log2_lut[acc[j] / cnt[j]]
		li[j] = l
		li2[j] = l * l
	}
	mut r := int(f32(if sw > sh { sw } else { sh }) * cl_radius + 0.5)
	if r < 2 {
		r = 2
	}
	mi := box_mean(li, sw, sh, r)
	mii := box_mean(li2, sw, sh, r)
	// Вес краёв 1 − a = eps / (var + eps): минимум по окну (у края вес
	// нулевой на всю ширину хвостов размытия), затем сглаживание. Вес
	// ровного var / (var + cl_flat): на гладком (небо) деталь - шум
	mut ce := []f32{len: n}
	mut cf := []f32{len: n}
	for j in 0 .. n {
		mut v := mii[j] - mi[j] * mi[j]
		if v < 0 {
			v = 0
		}
		ce[j] = eps / (v + eps)
		cf[j] = v / (v + cl_flat)
	}
	me := box_mean(min_filter(ce, sw, sh, r), sw, sh, r)
	mf := box_mean(cf, sw, sh, r)
	mut mw := []f32{len: n}
	for j in 0 .. n {
		mw[j] = me[j] * mf[j]
	}
	// На размер буфера - билинейно (центры блоков), полосами строк в потоках
	oc := ClOut{
		mw:     unsafe { &f32(mw.data) }
		sw:     sw
		sh:     sh
		f:      f
		w:      w
		out:    out
		stride: stride
	}
	nt := bands(w, h)
	step := (h + nt - 1) / nt
	mut ts := []thread{}
	for y0 := 0; y0 < h; y0 += step {
		ts << spawn cl_out_rows(&oc, y0, imin(h, y0 + step))
	}
	ts.wait()
}

// ClOut - входы прохода cl_out_rows (общие для потоков; out - каждый
// поток пишет свои строки)
struct ClOut {
	mw     &f32 = unsafe { nil }
	sw     int
	sh     int
	f      int
	w      int
	out    &u16 = unsafe { nil }
	stride int
}

// bilin - билинейная выборка с сетки, уменьшенной в f раз (центры
// блоков): пиксель i -> соседние узлы i0, i1 (не дальше n - 1) и доля t
@[inline]
fn bilin(i int, f int, n int) (int, int, f32) {
	mut fi := (f32(i) + 0.5) / f32(f) - 0.5
	if fi < 0 {
		fi = 0
	}
	mut i0 := int(fi)
	if i0 > n - 1 {
		i0 = n - 1
	}
	i1 := if i0 + 1 < n { i0 + 1 } else { i0 }
	return i0, i1, fi - f32(i0)
}

// cl_out_rows - вес (1 − a) ×65535 для строк y0..y1 буфера
fn cl_out_rows(c &ClOut, y0 int, y1 int) {
	unsafe {
		for y in y0 .. y1 {
			mut d := c.out + (y * c.w) * c.stride
			ya, yb, ty := bilin(y, c.f, c.sh)
			for x in 0 .. c.w {
				xa, xb, tx := bilin(x, c.f, c.sw)
				wv := (c.mw[ya * c.sw + xa] * (1 - tx) + c.mw[ya * c.sw + xb] * tx) * (1 - ty) +
					(c.mw[yb * c.sw + xa] * (1 - tx) + c.mw[yb * c.sw + xb] * tx) * ty
				v := wv * 65535 + 0.5
				d[0] = if v >= 65535 { u16(65535) } else if v < 0 { u16(0) } else { u16(v) }
				d += c.stride
			}
		}
	}
}

// Линейная величина u16 -> log2 (0 читается как 1 - без -inf); от
// параметров не зависит
const log2_lut = build_log2_lut()

fn build_log2_lut() []f32 {
	mut l := []f32{len: 65536}
	for x in 0 .. 65536 {
		l[x] = f32(math.log2(f64(if x < 1 { 1 } else { x })))
	}
	return l
}

// build_cmid - вес Clarity по люме пикселя (u16, после экспозиции - тон
// t): средние тона 1 - |2t - 1|³ (в чёрном и белом - 0: локальный
// контраст не клипает тени и света)
fn build_cmid(p &Params) []f32 {
	e := math.powf(2.0, p.exposure)
	mut m := []f32{len: 65536}
	for y in 0 .. 65536 {
		mut yl := f32(y) * (1.0 / 65535.0) * e
		if yl > 1.0 {
			yl = 1.0
		}
		t := math.powf(yl, inv_gamma)
		a := math.abs(2 * t - 1)
		m[y] = 1 - a * a * a
	}
	return m
}

// clarity_gain - сила Clarity по сумме a (кадр + фильтры, 1 = 100 на
// ползунке): плюс - ×cl_gain, минус - ×cl_gain_neg; сумма в -1..2 (ниже
// -1 деталь перевернулась бы)
@[inline]
fn clarity_gain(a f32) f32 {
	if a > 0 {
		return (if a > 2 { f32(2) } else { a }) * cl_gain
	}
	return (if a < -1 { f32(-1) } else { a }) * cl_gain_neg
}

// clarity_ev - добавка Clarity в EV: деталь d (EV) с мягкими пределами
// (cl_noise, cl_halo), умноженная на силу по тону s
@[inline]
fn clarity_ev(d f32, s f32) f32 {
	dd := d * d
	ad := if d < 0 { -d } else { d }
	return s * d * dd / (dd + cl_noise * cl_noise) / (1 + ad * (1.0 / cl_halo))
}
