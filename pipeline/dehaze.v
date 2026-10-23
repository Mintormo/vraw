module pipeline

// Удаление дымки (как «Удаление дымки» RawTherapee и Dehaze Lightroom):
// метод тёмного канала (He, Sun, Tang, 2009) с управляемым фильтром.
//
// Модель дымки в линейном свете: I = J·t + A·(1 - t), где J - сцена без
// дымки, A - свет дымки (атмосферы), t - пропускание (1 - близко и
// прозрачно, 0 - далеко, всё в дымке). Априорное знание: в любой
// окрестности ясного снимка у какого-то канала есть почти чёрные пиксели
// (тени, насыщенные цвета), поэтому «тёмный канал» dark(I/A) - минимум
// по каналам и по окну - почти целиком и есть доля дымки 1 - t.
//
// Карта (haze_map) зависит только от сырья: считается раз на кадр на
// уменьшенной копии (длинная сторона ~1024, превью и полный кадр дают
// практически одну карту), уточняется управляемым фильтром по люме
// (края объектов, без ореолов от окна минимума) и растягивается на
// полный размер (быстрый управляемый фильтр, He 2015): коэффициенты a, b
// билинейно, D = a·люма + b. Сила и глубина применяются в render на
// пиксель: t = 1 - ω·D^γ - ползунки живые.
import math
import bigbuf

const haze_work = 1024 // длинная сторона рабочей копии
const haze_r = 7 // радиус окна тёмного канала (15x15, как у He) на рабочей копии
const haze_gr = 28 // радиус управляемого фильтра
const haze_eps = f32(2e-4) // регуляризация фильтра (линейная люма - дисперсии малы)
const haze_t0 = f32(0.1) // нижний предел пропускания: иначе шум дальнего плана взрывается

// HazeMap - карта дымки кадра: D 0..65535 (доля дымки, ~1 - t) на каждый
// пиксель и свет дымки A (линейный 0..1 по каналам)
pub struct HazeMap {
pub:
	w int
	h int
pub mut:
	d []u16
pub:
	a [3]f32
}

// free - освободить карту, выделенную haze_map_big (у обычной - забыть)
pub fn (mut m HazeMap) free() {
	bigbuf.free(mut m.d)
}

// haze_map - карта дымки линейного 16-бит RGB w x h
pub fn haze_map(src &u16, w int, h int) HazeMap {
	return haze_map_impl(src, w, h, false)
}

// haze_map_big - то же, карта вне сборщика (bigbuf; экспорт): освобождать
// HazeMap.free
pub fn haze_map_big(src &u16, w int, h int) HazeMap {
	return haze_map_impl(src, w, h, true)
}

fn haze_map_impl(src &u16, w int, h int, big bool) HazeMap {
	mut f := (if w > h { w } else { h } + haze_work - 1) / haze_work
	if f < 1 {
		f = 1
	}
	sw := (w + f - 1) / f
	sh := (h + f - 1) / f
	n := sw * sh
	// Уменьшенная копия: среднее блока f x f (неполные блоки у краёв - по факту)
	mut sr := []f32{len: n}
	mut sg := []f32{len: n}
	mut sb := []f32{len: n}
	mut cnt := []f32{len: n}
	unsafe {
		s := &u16(src)
		for y in 0 .. h {
			row := (y / f) * sw
			for x in 0 .. w {
				j := row + x / f
				i := (y * w + x) * 3
				sr[j] += f32(s[i])
				sg[j] += f32(s[i + 1])
				sb[j] += f32(s[i + 2])
				cnt[j] += 1
			}
		}
	}
	for j in 0 .. n {
		k := 1 / (cnt[j] * 65535.0)
		sr[j] *= k
		sg[j] *= k
		sb[j] *= k
	}
	// Свет дымки A: 0.1% пикселей с самым светлым тёмным каналом (самые
	// «затуманенные», не просто яркие), их средний цвет
	mut minc := []f32{len: n}
	for j in 0 .. n {
		minc[j] = min3(sr[j], sg[j], sb[j])
	}
	dk := min_filter(minc, sw, sh, haze_r)
	mut hist := []int{len: 1024}
	for v in dk {
		hist[bin1024(v)]++
	}
	top := if n / 1000 > 1 { n / 1000 } else { 1 }
	mut acc := 0
	mut thr := 1023
	for thr > 0 {
		acc += hist[thr]
		if acc >= top {
			break
		}
		thr--
	}
	mut a := [f32(0), 0, 0]!
	mut na := 0
	for j in 0 .. n {
		if bin1024(dk[j]) >= thr {
			a[0] += sr[j]
			a[1] += sg[j]
			a[2] += sb[j]
			na++
		}
	}
	for c in 0 .. 3 {
		a[c] /= f32(na)
		if a[c] < 0.02 {
			a[c] = 0.02
		} else if a[c] > 1 {
			a[c] = 1
		}
	}
	// Тёмный канал нормированного I/A - сырая доля дымки
	for j in 0 .. n {
		minc[j] = min3(sr[j] / a[0], sg[j] / a[1], sb[j] / a[2])
		if minc[j] > 1 {
			minc[j] = 1
		}
	}
	p := min_filter(minc, sw, sh, haze_r)
	// Управляемый фильтр: направляющая - люма, уточняемое - p
	mut g := []f32{len: n}
	mut gp := []f32{len: n}
	mut gg := []f32{len: n}
	for j in 0 .. n {
		l := 0.2126 * sr[j] + 0.7152 * sg[j] + 0.0722 * sb[j]
		g[j] = l
		gp[j] = l * p[j]
		gg[j] = l * l
	}
	mg := box_mean(g, sw, sh, haze_gr)
	mp := box_mean(p, sw, sh, haze_gr)
	mgp := box_mean(gp, sw, sh, haze_gr)
	mgg := box_mean(gg, sw, sh, haze_gr)
	mut ca := []f32{len: n}
	mut cb := []f32{len: n}
	for j in 0 .. n {
		va := mgg[j] - mg[j] * mg[j]
		cov := mgp[j] - mg[j] * mp[j]
		ca[j] = cov / (va + haze_eps)
		cb[j] = mp[j] - ca[j] * mg[j]
	}
	ma := box_mean(ca, sw, sh, haze_gr)
	mb := box_mean(cb, sw, sh, haze_gr)
	// Полный размер: a, b - билинейно, люма - своя у каждого пикселя
	mut d := if big { bigbuf.new_u16(w * h) } else { []u16{len: w * h} }
	inv := 1 / f32(f)
	unsafe {
		s := &u16(src)
		for y in 0 .. h {
			fy := (f32(y) + 0.5) * inv - 0.5
			mut y0 := int(math.floor(fy))
			ty := fy - f32(y0)
			mut y1 := y0 + 1
			if y0 < 0 {
				y0 = 0
			}
			if y1 > sh - 1 {
				y1 = sh - 1
			}
			if y0 > sh - 1 {
				y0 = sh - 1
			}
			for x in 0 .. w {
				fx := (f32(x) + 0.5) * inv - 0.5
				mut x0 := int(math.floor(fx))
				tx := fx - f32(x0)
				mut x1 := x0 + 1
				if x0 < 0 {
					x0 = 0
				}
				if x1 > sw - 1 {
					x1 = sw - 1
				}
				if x0 > sw - 1 {
					x0 = sw - 1
				}
				i00 := y0 * sw + x0
				i01 := y0 * sw + x1
				i10 := y1 * sw + x0
				i11 := y1 * sw + x1
				av := (ma[i00] * (1 - tx) + ma[i01] * tx) * (1 - ty) + (ma[i10] * (1 - tx) +
					ma[i11] * tx) * ty
				bv := (mb[i00] * (1 - tx) + mb[i01] * tx) * (1 - ty) + (mb[i10] * (1 - tx) +
					mb[i11] * tx) * ty
				i := (y * w + x) * 3
				l := (0.2126 * f32(s[i]) + 0.7152 * f32(s[i + 1]) + 0.0722 * f32(s[i + 2])) * f32(1.0 / 65535.0)
				mut q := av * l + bv
				if q < 0 {
					q = 0
				} else if q > 1 {
					q = 1
				}
				d[y * w + x] = u16(q * 65535.0 + 0.5)
			}
		}
	}
	return HazeMap{
		w: w
		h: h
		d: d
		a: a
	}
}

@[inline]
fn min3(a f32, b f32, c f32) f32 {
	m := if a < b { a } else { b }
	return if m < c { m } else { c }
}

@[inline]
fn bin1024(v f32) int {
	i := int(v * 1023)
	return if i < 0 { 0 } else if i > 1023 { 1023 } else { i }
}

// min_filter - минимум по квадратному окну (2r+1)², разделимо: строки,
// затем столбцы; бегущий минимум на монотонной очереди - O(1) на пиксель
fn min_filter(src []f32, w int, h int, r int) []f32 {
	mut tmp := []f32{len: w * h}
	mut out := []f32{len: w * h}
	mut q := []int{len: if w > h { w } else { h }}
	for y in 0 .. h {
		min_line(src, mut tmp, y * w, 1, w, r, mut q)
	}
	for x in 0 .. w {
		min_line(tmp, mut out, x, w, h, r, mut q)
	}
	return out
}

// min_line - бегущий минимум одной линии: элементы base + k·step, k < n
fn min_line(src []f32, mut dst []f32, base int, step int, n int, r int, mut q []int) {
	mut head := 0
	mut tail := 0
	mut next := 0 // следующий ещё не добавленный в окно
	for k in 0 .. n {
		for next <= k + r && next < n {
			v := src[base + next * step]
			for tail > head && src[base + q[tail - 1] * step] >= v {
				tail--
			}
			q[tail] = next
			tail++
			next++
		}
		for q[head] < k - r {
			head++
		}
		dst[base + k * step] = src[base + q[head] * step]
	}
}

// box_mean - среднее по окну (2r+1)² (у краёв окно укорачивается),
// бегущие суммы по строкам и столбцам
fn box_mean(src []f32, w int, h int, r int) []f32 {
	mut tmp := []f32{len: w * h}
	for y in 0 .. h {
		row := y * w
		mut sum := f64(0)
		mut hi := 0
		mut lo := 0
		for x in 0 .. w {
			for hi <= x + r && hi < w {
				sum += src[row + hi]
				hi++
			}
			for lo < x - r {
				sum -= src[row + lo]
				lo++
			}
			tmp[row + x] = f32(sum / f64(hi - lo))
		}
	}
	mut out := []f32{len: w * h}
	mut sums := []f64{len: w}
	mut hi := 0
	mut lo := 0
	for y in 0 .. h {
		for hi <= y + r && hi < h {
			for x in 0 .. w {
				sums[x] += tmp[hi * w + x]
			}
			hi++
		}
		for lo < y - r {
			for x in 0 .. w {
				sums[x] -= tmp[lo * w + x]
			}
			lo++
		}
		c := f64(hi - lo)
		for x in 0 .. w {
			out[y * w + x] = f32(sums[x] / c)
		}
	}
	return out
}

// haze_gamma - показатель глубины: D^γ; глубина 25 - γ = 1, больше -
// γ < 1 (дымка убирается и на ближнем плане), меньше - только вдали
fn haze_gamma(depth f32) f32 {
	return math.powf(2.0, (25 - depth) / 25)
}

// build_hlut - таблица: D (u16) -> множитель к (I - A). Удаление (сила > 0):
// 1/t, t = 1 - ω·D^γ не ниже haze_t0, ω = 0.95 при 100 (как у He - немного
// дымки оставить, иначе дальний план выглядит плоско); добавление (сила
// < 0): t = 1 - |ω|·D^γ.
fn build_hlut(p &Params) []f32 {
	om := p.haze / 100 * 0.95
	gm := haze_gamma(p.haze_depth)
	mut t := []f32{len: 65536}
	for i in 0 .. 65536 {
		dv := math.powf(f32(i) * f32(1.0 / 65535.0), gm)
		if om > 0 {
			mut tr := 1 - om * dv
			if tr < haze_t0 {
				tr = haze_t0
			}
			t[i] = 1 / tr
		} else {
			t[i] = 1 + om * dv
		}
	}
	return t
}

// haze_view - карта глубины (D^γ с учётом «Глубины») серым в dst -
// флажок «Показать карту глубины»: светлее - больше дымки
pub fn haze_view(m &HazeMap, depth f32, mut dst []u8, dst_stride int) {
	gm := haze_gamma(depth)
	mut lut := []u8{len: 65536}
	for i in 0 .. 65536 {
		lut[i] = u8(int(math.powf(f32(i) * f32(1.0 / 65535.0), gm) * 255 + 0.5))
	}
	for i in 0 .. m.d.len {
		v := lut[m.d[i]]
		dst[i * dst_stride] = v
		dst[i * dst_stride + 1] = v
		dst[i * dst_stride + 2] = v
		if dst_stride == 4 {
			dst[i * dst_stride + 3] = 255
		}
	}
}
