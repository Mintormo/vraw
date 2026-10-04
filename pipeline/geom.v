module pipeline

// Геометрия кадра: ориентация (поворот на 90°, отражения), поворот на
// произвольный угол и кадрирование. Правит линейное сырьё после
// подготовки (объектив, шумодав) и до тонального пайплайна, одинаково на
// превью и полном кадре: всё задано в долях кадра, не в пикселях.
//
// Системы координат (пиксель i занимает [i, i+1], y вниз):
//   S  - исходный кадр w x h (как отдаёт LibRaw);
//   V  - после ориентации W0 x H0: сначала rot90 четвертей по часовой,
//        затем отражения flip_h / flip_v (в показе);
//   R  - V, повёрнутый на angle градусов ПРОТИВ часовой вокруг центра,
//        того же размера W0 x H0 (углы за краем V - пустые);
//   O  - выход: рамка [x0, x1] x [y0, y1] в долях R.
// Выход -> источник - аффинное отображение (geom_affine): на пиксель
// выборка из S (без поворота - ближайший пиксель, с поворотом -
// билинейная).
import math
import bigbuf

// Geom - геометрия кадра (в EditState; по умолчанию - без изменений)
pub struct Geom {
pub mut:
	rot90  int  // 0..3 - четверти по часовой
	flip_h bool // отражение по горизонтали (лево <-> право)
	flip_v bool // по вертикали
	angle  f32  // поворот, градусы, плюс - против часовой (-45..45)
	x0     f32
	y0     f32
	x1     f32 = 1
	y1     f32 = 1
	// Пропорция выхода (ширина / высота): высота выхода - по ширине и ей,
	// а не округлением доли (1:1 - ровно квадрат); 0 - по рамке.
	// Производное поле (crop.v, out_geom), в сайдкар не пишется
	aspect f32
}

pub const geom_angle_max = f32(45)

// is_identity - геометрия ничего не меняет
pub fn (g Geom) is_identity() bool {
	return g.rot90 % 4 == 0 && !g.flip_h && !g.flip_v && g.angle == 0 && g.x0 <= 0
		&& g.y0 <= 0 && g.x1 >= 1 && g.y1 >= 1
}

// oriented - размер кадра w x h после ориентации (W0 x H0)
pub fn (g Geom) oriented(w int, h int) (int, int) {
	return if g.rot90 % 2 == 1 { h, w } else { w, h }
}

// out_size - размер выхода для кадра w x h; crop = false - весь R (режим
// кадрирования: рамка рисуется поверх)
pub fn (g Geom) out_size(w int, h int, crop bool) (int, int) {
	ow, oh := g.oriented(w, h)
	if !crop {
		return ow, oh
	}
	cw := int(math.round(f64(g.x1 - g.x0) * f64(ow)))
	ch := if g.aspect > 0 {
		int(math.round(f64(cw) / f64(g.aspect)))
	} else {
		int(math.round(f64(g.y1 - g.y0) * f64(oh)))
	}
	return if cw < 1 { 1 } else { cw }, if ch < 1 { 1 } else { ch }
}

// r_to_v - точка R (пиксели W0 x H0) -> точка V: обратный поворот вокруг
// центра. Прямой (V -> R, против часовой при y вниз):
// p - c = [[cos, sin], [-sin, cos]] (q - c).
pub fn (g Geom) r_to_v(px f64, py f64, w0 f64, h0 f64) (f64, f64) {
	if g.angle == 0 {
		return px, py
	}
	a := f64(g.angle) * math.pi / 180
	cs := math.cos(a)
	sn := math.sin(a)
	dx := px - w0 / 2
	dy := py - h0 / 2
	return w0 / 2 + cs * dx - sn * dy, h0 / 2 + sn * dx + cs * dy
}

// v_to_r - точка V -> точка R (прямой поворот)
pub fn (g Geom) v_to_r(qx f64, qy f64, w0 f64, h0 f64) (f64, f64) {
	if g.angle == 0 {
		return qx, qy
	}
	a := f64(g.angle) * math.pi / 180
	cs := math.cos(a)
	sn := math.sin(a)
	dx := qx - w0 / 2
	dy := qy - h0 / 2
	return w0 / 2 + cs * dx + sn * dy, h0 / 2 - sn * dx + cs * dy
}

// v_to_s - доли V (u, v) -> доли S: снять отражения, затем повороты на 90°
fn (g Geom) v_to_s(u f64, v f64) (f64, f64) {
	mut a := if g.flip_h { 1 - u } else { u }
	mut b := if g.flip_v { 1 - v } else { v }
	for _ in 0 .. g.rot90 % 4 {
		// Кадр, повёрнутый по часовой: точка (a, b) показа - это (b, 1 - a)
		// кадра до поворота
		a, b = b, 1 - a
	}
	return a, b
}

// s_to_v - доли S -> доли V (обратное к v_to_s)
fn (g Geom) s_to_v(s f64, t f64) (f64, f64) {
	mut a := s
	mut b := t
	for _ in 0 .. g.rot90 % 4 {
		a, b = 1 - b, a
	}
	if g.flip_h {
		a = 1 - a
	}
	if g.flip_v {
		b = 1 - b
	}
	return a, b
}

// point_to_source - точка R (пиксели кадра W0 x H0 из w x h) -> точка S
// (пиксели w x h)
pub fn (g Geom) point_to_source(px f64, py f64, w int, h int) (f64, f64) {
	w0, h0 := g.oriented(w, h)
	qx, qy := g.r_to_v(px, py, w0, h0)
	s, t := g.v_to_s(qx / f64(w0), qy / f64(h0))
	return s * f64(w), t * f64(h)
}

// source_to_point - точка S (пиксели w x h) -> точка R (для пипетки,
// линии горизонта и т.п. в обратную сторону)
pub fn (g Geom) source_to_point(sx f64, sy f64, w int, h int) (f64, f64) {
	w0, h0 := g.oriented(w, h)
	u, v := g.s_to_v(sx / f64(w), sy / f64(h))
	return g.v_to_r(u * f64(w0), v * f64(h0), w0, h0)
}

// Affine - выход (i, j) -> источник: sx = a·i + b·j + c, sy = d·i + e·j + f
// (центр пикселя выхода (i + 0.5, j + 0.5) - в точку S, пиксели)
struct Affine {
	a f64
	b f64
	c f64
	d f64
	e f64
	f f64
}

// geom_affine - отображение выхода ow x oh в источник w x h; crop = false -
// выход весь R
fn geom_affine(g Geom, w int, h int, crop bool, ow int, oh int) Affine {
	w0, h0 := g.oriented(w, h)
	rx0 := if crop { f64(g.x0) * w0 } else { 0.0 }
	ry0 := if crop { f64(g.y0) * h0 } else { 0.0 }
	rw := if crop { f64(g.x1 - g.x0) * w0 } else { f64(w0) }
	rh := if crop { f64(g.y1 - g.y0) * h0 } else { f64(h0) }
	at := fn [g, w, h, rx0, ry0, rw, rh, ow, oh] (i f64, j f64) (f64, f64) {
		return g.point_to_source(rx0 + (i + 0.5) * rw / f64(ow), ry0 + (j + 0.5) * rh / f64(oh),
			w, h)
	}
	x00, y00 := at(0, 0)
	x10, y10 := at(1, 0)
	x01, y01 := at(0, 1)
	return Affine{
		a: x10 - x00
		b: x01 - x00
		c: x00
		d: y10 - y00
		e: y01 - y00
		f: y00
	}
}

// is_noop - геометрия не меняет буфер: тождественная или (весь кадр,
// crop = false) только рамка обрезки - результат равен исходному
pub fn (g Geom) is_noop(crop bool) bool {
	return g.is_identity() || (!crop && g.rot90 % 4 == 0 && !g.flip_h && !g.flip_v && g.angle == 0)
}

// geom_apply - геометрия буфера w x h с ch каналами u16 (3 - сырьё, 1 -
// маска «Тени/Света»): новый буфер и его размер. crop = false - весь R
// (режим кадрирования). Без изменений - копия.
pub fn geom_apply(src &u16, w int, h int, ch int, g Geom, crop bool) ([]u16, int, int) {
	ow, oh := g.out_size(w, h, crop)
	mut out := []u16{len: ow * oh * ch}
	rw, rh := geom_apply_into(src, w, h, ch, g, crop, mut out)
	return out, rw, rh
}

// geom_apply_into - то же в готовый буфер out длиной ow * oh * ch, где
// ow, oh = g.out_size(w, h, crop) (экспорт даёт буфер вне сборщика -
// bigbuf); возвращает размер результата
pub fn geom_apply_into(src &u16, w int, h int, ch int, g Geom, crop bool, mut out []u16) (int, int) {
	ow, oh := g.out_size(w, h, crop)
	if g.is_noop(crop) {
		unsafe { vmemcpy(out.data, src, w * h * ch * 2) }
		return w, h
	}
	m := geom_affine(g, w, h, crop, ow, oh)
	unsafe {
		mut d := &u16(out.data)
		if g.angle == 0 {
			// Без поворота - ближайший пиксель (центры ложатся на центры)
			for j in 0 .. oh {
				for i in 0 .. ow {
					mut sx := int(math.floor(m.a * i + m.b * j + m.c))
					mut sy := int(math.floor(m.d * i + m.e * j + m.f))
					sx = if sx < 0 { 0 } else if sx >= w { w - 1 } else { sx }
					sy = if sy < 0 { 0 } else if sy >= h { h - 1 } else { sy }
					s := src + (sy * w + sx) * ch
					for c in 0 .. ch {
						d[c] = s[c]
					}
					d += ch
				}
			}
			return ow, oh
		}
		// С поворотом - билинейно; за краем кадра - чёрное
		for j in 0 .. oh {
			mut sx := m.a * 0 + m.b * j + m.c - 0.5
			mut sy := m.d * 0 + m.e * j + m.f - 0.5
			for _ in 0 .. ow {
				if sx < -0.5 || sy < -0.5 || sx > f64(w) - 0.5 || sy > f64(h) - 0.5 {
					for c in 0 .. ch {
						d[c] = 0
					}
				} else {
					mut x0 := int(math.floor(sx))
					mut y0 := int(math.floor(sy))
					fx := f32(sx - f64(x0))
					fy := f32(sy - f64(y0))
					mut x1 := x0 + 1
					mut y1 := y0 + 1
					x0 = if x0 < 0 { 0 } else { x0 }
					y0 = if y0 < 0 { 0 } else { y0 }
					x1 = if x1 >= w { w - 1 } else { x1 }
					y1 = if y1 >= h { h - 1 } else { y1 }
					p00 := src + (y0 * w + x0) * ch
					p10 := src + (y0 * w + x1) * ch
					p01 := src + (y1 * w + x0) * ch
					p11 := src + (y1 * w + x1) * ch
					for c in 0 .. ch {
						top := f32(p00[c]) + (f32(p10[c]) - f32(p00[c])) * fx
						bot := f32(p01[c]) + (f32(p11[c]) - f32(p01[c])) * fx
						v := top + (bot - top) * fy
						d[c] = u16(if v < 0 { f32(0) } else if v > 65535 { f32(65535) } else { v + 0.5 })
					}
				}
				d += ch
				sx += m.a
				sy += m.d
			}
		}
	}
	return ow, oh
}

// geom_rgba - геометрия 8-битного RGBA (быстрое превью камеры) в выход
// ow x oh любого размера (кадр вписан целиком); crop - как у geom_apply.
// Ближайший пиксель - превью на доли секунды.
pub fn geom_rgba(src []u8, w int, h int, g Geom, crop bool, ow int, oh int) []u8 {
	mut out := []u8{len: ow * oh * 4}
	if w <= 0 || h <= 0 || src.len < w * h * 4 {
		return out
	}
	m := geom_affine(g, w, h, crop, ow, oh)
	for j in 0 .. oh {
		for i in 0 .. ow {
			sx := int(math.floor(m.a * i + m.b * j + m.c))
			sy := int(math.floor(m.d * i + m.e * j + m.f))
			o := (j * ow + i) * 4
			if sx < 0 || sy < 0 || sx >= w || sy >= h {
				out[o + 3] = 255
				continue
			}
			s := (sy * w + sx) * 4
			out[o] = src[s]
			out[o + 1] = src[s + 1]
			out[o + 2] = src[s + 2]
			out[o + 3] = 255
		}
	}
	return out
}

// ── Рамка кадрирования в R ──

// CropBox - рамка в пикселях R (кадр W0 x H0)
pub struct CropBox {
pub mut:
	x0 f64
	y0 f64
	x1 f64
	y1 f64
}

pub fn (b CropBox) w() f64 {
	return b.x1 - b.x0
}

pub fn (b CropBox) h() f64 {
	return b.y1 - b.y0
}

// box_of - рамка геометрии в пикселях R кадра w0 x h0
pub fn (g Geom) box_of(w0 int, h0 int) CropBox {
	return CropBox{f64(g.x0) * w0, f64(g.y0) * h0, f64(g.x1) * w0, f64(g.y1) * h0}
}

// with_box - геометрия с рамкой b (пиксели R кадра w0 x h0)
pub fn (g Geom) with_box(b CropBox, w0 int, h0 int) Geom {
	// В пределах кадра: доли у края - ровно 0 и 1 (без погрешности)
	return Geom{
		...g
		x0: frac01(b.x0 / w0)
		y0: frac01(b.y0 / h0)
		x1: frac01(b.x1 / w0)
		y1: frac01(b.y1 / h0)
	}
}

fn frac01(v f64) f32 {
	return if v < 1e-6 { f32(0) } else if v > 1 - 1e-6 { f32(1) } else { f32(v) }
}

// fits - рамка целиком внутри повёрнутого кадра (без пустых углов)
pub fn (g Geom) fits(b CropBox, w0 int, h0 int) bool {
	if b.x0 > b.x1 || b.y0 > b.y1 {
		return false
	}
	eps := 1e-3
	for p in [[b.x0, b.y0], [b.x1, b.y0], [b.x0, b.y1], [b.x1, b.y1]] {
		qx, qy := g.r_to_v(p[0], p[1], w0, h0)
		if qx < -eps || qy < -eps || qx > f64(w0) + eps || qy > f64(h0) + eps {
			return false
		}
	}
	return true
}

// lerp_box - промежуточная рамка между a (t = 0) и b (t = 1)
fn lerp_box(a CropBox, b CropBox, t f64) CropBox {
	return CropBox{a.x0 + (b.x0 - a.x0) * t, a.y0 + (b.y0 - a.y0) * t, a.x1 + (b.x1 - a.x1) * t,
		a.y1 + (b.y1 - a.y1) * t}
}

// fit_toward - самая близкая к цели рамка на пути from -> to, которая
// ещё помещается в кадр (from помещается): бисекция по доле пути. Так
// ограничиваются все движения рамки - перетаскивание, ручки, поворот.
pub fn (g Geom) fit_toward(from CropBox, to CropBox, w0 int, h0 int) CropBox {
	if g.fits(to, w0, h0) {
		return to
	}
	mut lo := 0.0
	mut hi := 1.0
	for _ in 0 .. 30 {
		mid := (lo + hi) / 2
		if g.fits(lerp_box(from, to, mid), w0, h0) {
			lo = mid
		} else {
			hi = mid
		}
	}
	return lerp_box(from, to, lo)
}

// max_box - наибольшая рамка пропорции aspect (ширина / высота в
// пикселях; 0 - как у кадра) с центром (cx, cy), помещающаяся в кадр;
// центр вне кадра - нулевая рамка
pub fn (g Geom) max_box(aspect f64, cx f64, cy f64, w0 int, h0 int) CropBox {
	a := if aspect > 0 { aspect } else { f64(w0) / f64(h0) }
	// Полуширина - бисекцией (помещается - монотонно по размеру)
	mut lo := 0.0
	mut hi := f64(w0 + h0)
	for _ in 0 .. 40 {
		mid := (lo + hi) / 2
		b := CropBox{cx - mid, cy - mid / a, cx + mid, cy + mid / a}
		if g.fits(b, w0, h0) {
			lo = mid
		} else {
			hi = mid
		}
	}
	return CropBox{cx - lo, cy - lo / a, cx + lo, cy + lo / a}
}

// best_box - наибольшая рамка пропорции aspect: с центром (cx, cy), если
// она не меньше 85% рамки по центру кадра, иначе по центру кадра
pub fn (g Geom) best_box(aspect f64, cx f64, cy f64, w0 int, h0 int) CropBox {
	mid := g.max_box(aspect, f64(w0) / 2, f64(h0) / 2, w0, h0)
	at := g.max_box(aspect, cx, cy, w0, h0)
	return if at.w() >= 0.85 * mid.w() { at } else { mid }
}

// horizon_angle - поправка угла, при которой линия (ax, ay) - (bx, by),
// проведённая по R, станет горизонтальной (или вертикальной, если она
// ближе к вертикали): градусы, добавить к angle
pub fn horizon_angle(ax f64, ay f64, bx f64, by f64) f32 {
	dx := bx - ax
	dy := by - ay
	if dx * dx + dy * dy < 1 {
		return 0
	}
	// Угол линии на экране (против часовой, y вниз)
	mut phi := math.atan2(-dy, dx) * 180 / math.pi
	for phi > 45 {
		phi -= 90
	}
	for phi <= -45 {
		phi += 90
	}
	// Повернуть картинку на -phi
	return f32(-phi)
}

// ── Размер на выход ──

// resize_rgb - 8-битный RGB w x h -> nw x nh: уменьшение - усреднение по
// площади (каждый выходной пиксель - среднее покрытых им входных, с
// долями на краях), увеличение - билинейно. Разделимо: по x, затем по y.
pub fn resize_rgb(src []u8, w int, h int, nw int, nh int) []u8 {
	if nw == w && nh == h {
		return src.clone()
	}
	mut f := resize_rgb_f32(src, w, h, nw, nh)
	defer {
		bigbuf.free(mut f)
	}
	return quantize_rgb(f)
}

// resize_rgb_sharp - resize_rgb и резкость на выход силы amount (окно
// «Экспорт», out_sharpen) - по значениям до округления в 8 бит
pub fn resize_rgb_sharp(src []u8, w int, h int, nw int, nh int, amount f32) []u8 {
	if amount <= 0 {
		return resize_rgb(src, w, h, nw, nh)
	}
	mut f := resize_rgb_f32(src, w, h, nw, nh)
	defer {
		bigbuf.free(mut f)
	}
	out_sharpen(mut f, nw, nh, amount)
	return quantize_rgb(f)
}

// resize_rgb_f32 - пересчёт размера (см. resize_rgb) без округления:
// RGB nw x nh во f32, 0..255; результат - вне сборщика (bigbuf):
// освобождает вызывающий
fn resize_rgb_f32(src []u8, w int, h int, nw int, nh int) []f32 {
	// По x: w -> nw, строки h
	mut tmp := bigbuf.new_f32(nw * h * 3)
	defer {
		bigbuf.free(mut tmp)
	}
	wx := resample_weights(w, nw)
	for y in 0 .. h {
		for x in 0 .. nw {
			for k in wx[x] {
				s := (y * w + k.i) * 3
				t := (y * nw + x) * 3
				tmp[t] += f32(src[s]) * k.w
				tmp[t + 1] += f32(src[s + 1]) * k.w
				tmp[t + 2] += f32(src[s + 2]) * k.w
			}
		}
	}
	// По y: h -> nh
	mut out := bigbuf.new_f32(nw * nh * 3)
	wy := resample_weights(h, nh)
	for y in 0 .. nh {
		for x in 0 .. nw {
			mut r := f32(0)
			mut g := f32(0)
			mut b := f32(0)
			for k in wy[y] {
				s := (k.i * nw + x) * 3
				r += tmp[s] * k.w
				g += tmp[s + 1] * k.w
				b += tmp[s + 2] * k.w
			}
			t := (y * nw + x) * 3
			out[t] = r
			out[t + 1] = g
			out[t + 2] = b
		}
	}
	return out
}

// quantize_rgb - f32 0..255 -> u8 с округлением
fn quantize_rgb(f []f32) []u8 {
	mut out := []u8{len: f.len}
	for i, v in f {
		out[i] = u8(clamp255(v) + 0.5)
	}
	return out
}

struct Tap {
	i int
	w f32
}

// resample_weights - веса выборки n -> m по одной оси: m < n - площадь
// (сумма весов 1), иначе билинейно по центрам пикселей
fn resample_weights(n int, m int) [][]Tap {
	mut res := [][]Tap{len: m}
	scale := f64(n) / f64(m)
	for o in 0 .. m {
		if m < n {
			a := f64(o) * scale
			b := f64(o + 1) * scale
			mut i := int(math.floor(a))
			for f64(i) < b && i < n {
				lo := if f64(i) > a { f64(i) } else { a }
				hi := if f64(i + 1) < b { f64(i + 1) } else { b }
				if hi > lo {
					res[o] << Tap{i, f32((hi - lo) / scale)}
				}
				i++
			}
		} else {
			c := (f64(o) + 0.5) * scale - 0.5
			mut i0 := int(math.floor(c))
			f := c - f64(i0)
			mut i1 := i0 + 1
			i0 = if i0 < 0 { 0 } else if i0 >= n { n - 1 } else { i0 }
			i1 = if i1 < 0 { 0 } else if i1 >= n { n - 1 } else { i1 }
			res[o] << Tap{i0, f32(1 - f)}
			res[o] << Tap{i1, f32(f)}
		}
	}
	return res
}
