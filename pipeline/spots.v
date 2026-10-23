module pipeline

// Удаление пятен (как Spot Removal в Lightroom): пыль на матрице и мелкие
// дефекты закрываются соседним участком кадра.
//
// Пятно - круг (центр и радиус в долях кадра S, до ориентации, поворота и
// кадрирования: пятно «приклеено» к снимку, как градиентный фильтр) и
// источник - центр круга того же размера, откуда берётся замена. Пятна
// правят линейное сырьё после подготовки (объектив, шумодав, Capture) и
// до геометрии, по порядку списка: позднее пятно видит исправления
// ранних. Превью, фрагмент 1:1 и экспорт - одна функция (spots_apply по
// куску кадра), меняется только масштаб пикселей.
//
// Два режима:
//   клонирование - пиксели источника как есть;
//   восстановление - текстура источника, а яркость и цвет - окружения
//     пятна: множитель каналов g(x) = 2^u(x), u - гармоническая функция в
//     круге (решение уравнения Лапласа), на границе равная log2 отношения
//     «окружение пятна / окружение источника» (средние квадратиков
//     (2kb+1)² в точках окружности радиуса r + kb - сразу за кругом). Для круга решение задачи Дирихле
//     известно точно - интеграл Пуассона; на n точках границы он
//     сводится к весам 1/|x - b_k|² (множитель R² - |x|² общий у всех
//     точек и сокращается при нормировке). Множитель (а не добавка) -
//     потому что пыль ослабляет свет: в линейном сырье это деление, и
//     текстура источника переносится с правильным контрастом и в тенях, и
//     в светах. u гладкая - считается на сетке с шагом ~r/12 и билинейно.
//     Граничные значения ограничены ±spot_gain_max EV.
// Край - растушёвка (доля радиуса со спадом smoothstep до нуля) и
// непрозрачность.
//
// Источник по умолчанию ищет spot_find_source: кольцо вокруг пятна
// сравнивается с кольцами кандидатов вокруг (16 направлений x 4
// расстояния), лучший - тот, у которого окружение совпадает по рисунку
// (разброс разности log-люмы колец; общий сдвиг яркости не важен -
// восстановление его уберёт) и внутри нет своей «аномалии».
//
// dust_view - карта для поиска пыли (как Visualize Spots): локальный
// перепад log-люмы (своя размытая окрестность минус крупная) серым
// с большим усилением - пятна пыли на небе видны тёмными кружками.
import math
import bigbuf

pub enum SpotMode {
	heal  // восстановление: текстура источника, яркость и цвет окружения
	clone // клонирование: источник как есть
}

// Spot - пятно: центр и источник - доли ширины и высоты кадра S, радиус -
// доля высоты S; растушёвка и непрозрачность 0..100
pub struct Spot {
pub mut:
	x       f32
	y       f32
	sx      f32
	sy      f32
	r       f32 = 0.01
	feather f32 = 20
	opacity f32 = 100
	mode    SpotMode
}

// Радиус пятна: пределы (доли высоты кадра)
pub const spot_r_min = f32(0.001)
pub const spot_r_max = f32(0.2)

// Предел log2-множителя на границе (EV): источник с другим содержимым
// (лес вместо неба) иначе раздул бы яркость во много раз
const spot_gain_max = f32(2)

// Добавка перед логарифмом (сырьё u16 0..65535): чёрное не даёт
// бесконечного множителя, шум в глубоких тенях не раскачивает его
const spot_eps = f32(64)

// spot_key - пятна строкой (ключи кэшей превью и 1:1)
pub fn spot_key(spots []Spot) string {
	if spots.len == 0 {
		return ''
	}
	mut s := ''
	for p in spots {
		s += '${p.x},${p.y},${p.sx},${p.sy},${p.r},${p.feather},${p.opacity},${int(p.mode)};'
	}
	return s
}

// SpotPx - пятно в пикселях кадра (координаты непрерывные: центр пикселя
// i - i + 0.5)
struct SpotPx {
	cx   f64
	cy   f64
	r    f64
	ri   f64 // граница полного действия (растушёвка)
	ox   int // сдвиг до источника, целые пиксели
	oy   int
	a    f32 // непрозрачность 0..1
	kb   int // полуразмер квадратика усреднения на границе
	heal bool
}

fn spot_px(s Spot, fw int, fh int) SpotPx {
	r := f64(s.r) * fh
	f := f64(clampf(s.feather, 0, 100)) / 100
	return SpotPx{
		cx:   f64(s.x) * fw
		cy:   f64(s.y) * fh
		r:    r
		ri:   r * (1 - f)
		ox:   int(math.round((f64(s.sx) - f64(s.x)) * fw))
		oy:   int(math.round((f64(s.sy) - f64(s.y)) * fh))
		a:    clampf(s.opacity, 0, 100) / 100
		kb:   spot_kb(r)
		heal: s.mode == .heal
	}
}

// spot_kb - полуразмер квадратика усреднения у границы (шум не
// переносится в множитель)
fn spot_kb(r f64) int {
	k := int(r / 8 + 0.5)
	return if k < 1 { 1 } else { k }
}

// spot_box_frame - прямоугольник круга (cx, cy, r) с запасом m в пикселях
// кадра fw x fh
fn spot_box_frame(cx f64, cy f64, r f64, m int, fw int, fh int) Region {
	x0 := clamp_i(int(math.floor(cx - r)) - m, 0, fw)
	y0 := clamp_i(int(math.floor(cy - r)) - m, 0, fh)
	x1 := clamp_i(int(math.ceil(cx + r)) + m, 0, fw)
	y1 := clamp_i(int(math.ceil(cy + r)) + m, 0, fh)
	return Region{x0, y0, x1 - x0, y1 - y0}
}

fn region_union(a Region, b Region) Region {
	if a.is_empty() {
		return b
	}
	if b.is_empty() {
		return a
	}
	x0 := if a.x < b.x { a.x } else { b.x }
	y0 := if a.y < b.y { a.y } else { b.y }
	x1 := if a.x + a.w > b.x + b.w { a.x + a.w } else { b.x + b.w }
	y1 := if a.y + a.h > b.y + b.h { a.y + a.h } else { b.y + b.h }
	return Region{x0, y0, x1 - x0, y1 - y0}
}

fn region_meets(a Region, b Region) bool {
	return !a.is_empty() && !b.is_empty() && a.x < b.x + b.w && b.x < a.x + a.w
		&& a.y < b.y + b.h && b.y < a.y + a.h
}

// spots_region - кусок кадра fw x fh, которого хватает, чтобы пятна в
// прямоугольнике r посчитались так же, как по всему кадру: r плюс
// источники (и окрестности границы) пятен, задевающих его. Два прохода -
// пятно, источник которого лежит на другом пятне
pub fn spots_region(spots []Spot, fw int, fh int, r Region) Region {
	mut out := r
	for _ in 0 .. 2 {
		for s in spots {
			p := spot_px(s, fw, fh)
			if p.r <= 0 {
				continue
			}
			m := 2 * p.kb + 2
			dst := spot_box_frame(p.cx, p.cy, p.r, m, fw, fh)
			if !region_meets(dst, out) {
				continue
			}
			src := spot_box_frame(p.cx + p.ox, p.cy + p.oy, p.r, m, fw, fh)
			out = region_union(out, region_union(dst, src))
		}
	}
	return out
}

// spot_box_avg - среднее каналов квадратика (2k+1)² с центром в пикселе
// (x, y) кадра, только по пикселям куска b (буфер buf - кусок b кадра);
// false - ни одного пикселя
fn spot_box_avg(buf &u16, b Region, x int, y int, k int) ([3]f32, bool) {
	x0 := clamp_i(x - k, b.x, b.x + b.w)
	x1 := clamp_i(x + k + 1, b.x, b.x + b.w)
	y0 := clamp_i(y - k, b.y, b.y + b.h)
	y1 := clamp_i(y + k + 1, b.y, b.y + b.h)
	mut s := [f32(0), 0, 0]!
	if x1 <= x0 || y1 <= y0 {
		return s, false
	}
	mut acc := [f64(0), 0, 0]!
	unsafe {
		for j in y0 .. y1 {
			mut p := buf + ((j - b.y) * b.w + (x0 - b.x)) * 3
			for _ in x0 .. x1 {
				acc[0] += p[0]
				acc[1] += p[1]
				acc[2] += p[2]
				p += 3
			}
		}
	}
	n := f64((x1 - x0) * (y1 - y0))
	for c in 0 .. 3 {
		s[c] = f32(acc[c] / n)
	}
	return s, true
}

// spots_apply - пятна по куску b кадра fw x fh (буфер buf - линейное RGB
// u16 b.w x b.h, правится на месте). Весь кадр - b = {0, 0, fw, fh}.
// Пиксели источника за куском берутся с его края - кусок для 1:1 надо
// брать spots_region.
pub fn spots_apply(buf &u16, b Region, fw int, fh int, spots []Spot) {
	if b.is_empty() || fw <= 0 || fh <= 0 {
		return
	}
	for s in spots {
		p := spot_px(s, fw, fh)
		if p.r < 0.5 || p.a <= 0 {
			continue
		}
		spot_one(buf, b, fw, fh, p)
	}
}

// spot_one - одно пятно
fn spot_one(buf &u16, b Region, fw int, fh int, p SpotPx) {
	// Пиксели пятна в куске
	d := region_clip(spot_box_frame(p.cx, p.cy, p.r, 1, fw, fh), b)
	if d.is_empty() {
		return
	}
	// Снимок источника до правки (источник и пятно могут перекрываться):
	// пиксель (x + ox, y + oy), за куском - его край
	mut snap := []u16{len: d.w * d.h * 3}
	unsafe {
		for j in 0 .. d.h {
			sy := clamp_i(d.y + j + p.oy, b.y, b.y + b.h - 1) - b.y
			for i in 0 .. d.w {
				sx := clamp_i(d.x + i + p.ox, b.x, b.x + b.w - 1) - b.x
				q := buf + (sy * b.w + sx) * 3
				o := (j * d.w + i) * 3
				snap[o] = q[0]
				snap[o + 1] = q[1]
				snap[o + 2] = q[2]
			}
		}
	}
	// Восстановление: log2-множитель на сетке
	mut gs := 1
	mut gw := 0
	mut grid := []f32{}
	if p.heal {
		gs, gw, grid = spot_gain_grid(buf, b, p, d)
	}
	r2 := p.r * p.r
	soft := p.r - p.ri
	unsafe {
		for j in 0 .. d.h {
			y := d.y + j
			dy := f64(y) + 0.5 - p.cy
			mut q := buf + ((y - b.y) * b.w + (d.x - b.x)) * 3
			for i in 0 .. d.w {
				x := d.x + i
				dx := f64(x) + 0.5 - p.cx
				dd := dx * dx + dy * dy
				if dd >= r2 {
					q += 3
					continue
				}
				dist := math.sqrt(dd)
				mut al := p.a
				if dist > p.ri && soft > 0 {
					t := f32((p.r - dist) / soft)
					al *= t * t * (3 - 2 * t)
				}
				o := (j * d.w + i) * 3
				mut g := [f32(0), 0, 0]!
				if grid.len > 0 {
					// Билинейно по сетке: узел (gi, gj) - пиксель (gi·gs, gj·gs)
					fx := f32(i) / f32(gs)
					fy := f32(j) / f32(gs)
					gi := int(fx)
					gj := int(fy)
					tx := fx - f32(gi)
					ty := fy - f32(gj)
					k00 := (gj * gw + gi) * 3
					k10 := k00 + 3
					k01 := k00 + gw * 3
					k11 := k01 + 3
					for c in 0 .. 3 {
						top := grid[k00 + c] + (grid[k10 + c] - grid[k00 + c]) * tx
						bot := grid[k01 + c] + (grid[k11 + c] - grid[k01 + c]) * tx
						g[c] = top + (bot - top) * ty
					}
				}
				for c in 0 .. 3 {
					sv := f32(snap[o + c])
					v := if grid.len > 0 { (sv + spot_eps) * exp2f(g[c]) - spot_eps } else { sv }
					cur := f32(q[c])
					out := cur + (v - cur) * al
					q[c] = if out <= 0 {
						u16(0)
					} else if out >= 65535 {
						u16(65535)
					} else {
						u16(out + 0.5)
					}
				}
				q += 3
			}
		}
	}
}

fn region_clip(a Region, b Region) Region {
	x0 := if a.x > b.x { a.x } else { b.x }
	y0 := if a.y > b.y { a.y } else { b.y }
	x1 := if a.x + a.w < b.x + b.w { a.x + a.w } else { b.x + b.w }
	y1 := if a.y + a.h < b.y + b.h { a.y + a.h } else { b.y + b.h }
	if x1 <= x0 || y1 <= y0 {
		return Region{}
	}
	return Region{x0, y0, x1 - x0, y1 - y0}
}

// spot_gain_grid - log2-множитель каналов (гармоническая функция в круге
// с граничными значениями log2(окружение пятна / окружение источника)) в
// узлах сетки с шагом gs над прямоугольником d: узел (gi, gj) - пиксель
// (d.x + gi·gs, d.y + gj·gs). Пустой массив - на границе нет данных
// (тогда - как клонирование).
fn spot_gain_grid(buf &u16, b Region, p SpotPx, d Region) (int, int, []f32) {
	mut n := int(math.ceil(2 * math.pi * p.r / f64(p.kb)))
	if n < 16 {
		n = 16
	} else if n > 256 {
		n = 256
	}
	mut bx := []f64{cap: n}
	mut by := []f64{cap: n}
	mut bv := []f32{cap: n * 3}
	// Точки границы - на rb = r + kb: квадратик усреднения целиком
	// снаружи круга (край пыли внутри не попадает в множитель)
	rb := p.r + f64(p.kb)
	for k in 0 .. n {
		phi := 2 * math.pi * f64(k) / f64(n)
		px := p.cx + rb * math.cos(phi)
		py := p.cy + rb * math.sin(phi)
		ix := int(math.floor(px))
		iy := int(math.floor(py))
		dv, ok1 := spot_box_avg(buf, b, ix, iy, p.kb)
		sv, ok2 := spot_box_avg(buf, b, ix + p.ox, iy + p.oy, p.kb)
		if !ok1 || !ok2 {
			continue
		}
		bx << px
		by << py
		for c in 0 .. 3 {
			bv << clampf(f32(math.log2(f64((dv[c] + spot_eps) / (sv[c] + spot_eps)))), -spot_gain_max,
				spot_gain_max)
		}
	}
	if bx.len == 0 {
		return 1, 0, []f32{}
	}
	mut gs := int(p.r / 12)
	if gs < 1 {
		gs = 1
	}
	gw := d.w / gs + 2
	gh := d.h / gs + 2
	mut grid := []f32{len: gw * gh * 3}
	for gj in 0 .. gh {
		y := f64(d.y + gj * gs) + 0.5
		for gi in 0 .. gw {
			x := f64(d.x + gi * gs) + 0.5
			mut ws := 0.0
			mut acc := [0.0, 0, 0]!
			for k in 0 .. bx.len {
				ex := x - bx[k]
				ey := y - by[k]
				mut dd := ex * ex + ey * ey
				if dd < 1e-6 {
					dd = 1e-6
				}
				w := 1 / dd
				ws += w
				acc[0] += w * bv[3 * k]
				acc[1] += w * bv[3 * k + 1]
				acc[2] += w * bv[3 * k + 2]
			}
			o := (gj * gw + gi) * 3
			for c in 0 .. 3 {
				grid[o + c] = f32(acc[c] / ws)
			}
		}
	}
	return gs, gw, grid
}

// ── Поиск источника ──

// spot_lum - log2 люмы (BT.709) квадратика (2k+1)² у точки (x, y) кадра
// w x h; false - точка за кадром
fn spot_lum(buf &u16, w int, h int, x f64, y f64, k int) (f32, bool) {
	ix := int(math.floor(x))
	iy := int(math.floor(y))
	if ix < 0 || iy < 0 || ix >= w || iy >= h {
		return 0, false
	}
	v, ok := spot_box_avg(buf, Region{0, 0, w, h}, ix, iy, k)
	if !ok {
		return 0, false
	}
	l := 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
	return f32(math.log2(f64(l + spot_eps))), true
}

// Кольцо сравнения окружения (доли радиуса) и точки внутри источника
const spot_ring = [1.15, 1.4, 1.7]
const spot_ring_n = 24
const spot_inner = [0.35, 0.7]
const spot_inner_n = 8
// Расстояния кандидатов (радиусов) и число направлений
const spot_dists = [2.5, 3.2, 4.2, 5.5]
const spot_dirs = 16

// SpotFind - поиск источника: avoid - точка (доли кадра), к которой
// источник не ближе двух радиусов (прежний источник - «другой
// источник»); -1 - нет
@[params]
pub struct SpotFind {
pub:
	avoid_x f32 = -1
	avoid_y f32 = -1
}

// spot_find_source - источник для пятна (x, y, r - доли кадра, r - доля
// высоты) по сырью buf w x h: центр круга рядом, окружение которого
// больше всего похоже на окружение пятна. Возвращает центр в долях кадра.
pub fn spot_find_source(buf &u16, w int, h int, x f32, y f32, r f32, o SpotFind) (f32, f32) {
	cx := f64(x) * w
	cy := f64(y) * h
	rr := f64(r) * h
	k := int(rr / 6)
	kb := if k < 1 { 1 } else { k }
	// Кольцо пятна
	mut dl := []f32{len: spot_ring.len * spot_ring_n}
	mut dok := []bool{len: dl.len}
	for ri, rk in spot_ring {
		for a in 0 .. spot_ring_n {
			phi := 2 * math.pi * f64(a) / spot_ring_n
			dl[ri * spot_ring_n + a], dok[ri * spot_ring_n + a] = spot_lum(buf, w, h, cx +
				rk * rr * math.cos(phi), cy + rk * rr * math.sin(phi), kb)
		}
	}
	mut best := f64(-1)
	mut bx := 0.0
	mut by := 0.0
	for dk in spot_dists {
		for di in 0 .. spot_dirs {
			phi := 2 * math.pi * f64(di) / spot_dirs + 0.1
			sx := cx + dk * rr * math.cos(phi)
			sy := cy + dk * rr * math.sin(phi)
			// Сам круг источника - внутри кадра
			if sx - rr - kb < 0 || sy - rr - kb < 0 || sx + rr + kb > w || sy + rr + kb > h {
				continue
			}
			if o.avoid_x >= 0 && math.hypot(sx - f64(o.avoid_x) * w, sy - f64(o.avoid_y) * h) < 2 * rr {
				continue
			}
			score := spot_score(buf, w, h, dl, dok, sx, sy, rr, kb)
			if score < 0 {
				continue
			}
			s := score * (1 + 0.04 * dk)
			if best < 0 || s < best {
				best = s
				bx = sx
				by = sy
			}
		}
	}
	if best < 0 {
		// Кандидатов нет (большое пятно у края) - рядом, внутрь кадра
		bx = if cx < f64(w) / 2 { cx + 2.5 * rr } else { cx - 2.5 * rr }
		by = cy
	}
	return f32(bx / w), f32(by / h)
}

// spot_score - насколько плох источник (sx, sy): разброс разности
// log-люмы колец пятна и источника (общий сдвиг не важен) плюс «аномалия»
// внутри источника - разброс сверх разброса его окружения. -1 - мало
// данных
fn spot_score(buf &u16, w int, h int, dl []f32, dok []bool, sx f64, sy f64, rr f64, kb int) f64 {
	mut diffs := []f64{cap: dl.len}
	mut ring_s := []f64{cap: dl.len}
	for ri, rk in spot_ring {
		for a in 0 .. spot_ring_n {
			i := ri * spot_ring_n + a
			if !dok[i] {
				continue
			}
			phi := 2 * math.pi * f64(a) / spot_ring_n
			v, ok := spot_lum(buf, w, h, sx + rk * rr * math.cos(phi), sy + rk * rr * math.sin(phi),
				kb)
			if !ok {
				continue
			}
			diffs << f64(dl[i] - v)
			ring_s << f64(v)
		}
	}
	if diffs.len < dl.len / 2 {
		return -1
	}
	vr := spot_var(diffs)
	mut inner := []f64{cap: 1 + spot_inner.len * spot_inner_n}
	v0, ok0 := spot_lum(buf, w, h, sx, sy, kb)
	if ok0 {
		inner << f64(v0)
	}
	for rk in spot_inner {
		for a in 0 .. spot_inner_n {
			phi := 2 * math.pi * f64(a) / spot_inner_n
			v, ok := spot_lum(buf, w, h, sx + rk * rr * math.cos(phi), sy + rk * rr * math.sin(phi),
				kb)
			if ok {
				inner << f64(v)
			}
		}
	}
	// Внутренность - против среднего своего кольца
	m := spot_mean(ring_s)
	mut vin := 0.0
	for v in inner {
		vin += (v - m) * (v - m)
	}
	vin /= f64(if inner.len > 0 { inner.len } else { 1 })
	extra := vin - spot_var(ring_s)
	return vr + 0.5 * (if extra > 0 { extra } else { 0.0 })
}

fn spot_mean(a []f64) f64 {
	if a.len == 0 {
		return 0
	}
	mut s := 0.0
	for v in a {
		s += v
	}
	return s / f64(a.len)
}

fn spot_var(a []f64) f64 {
	if a.len == 0 {
		return 0
	}
	m := spot_mean(a)
	mut s := 0.0
	for v in a {
		s += (v - m) * (v - m)
	}
	return s / f64(a.len)
}

// ── Карта пыли ──

// dust_view - карта для поиска пыли по линейному сырью src w x h: серый
// 128 + усиление · (B1 - B2), B1 и B2 - log2-люма, размытая слегка (шум) и
// крупно (~1/80 короткой стороны). amount 0..100 - усиление (×4 на
// четверть шкалы). Выход - dst (stride 3 или 4, альфа 255).
pub fn dust_view(src &u16, w int, h int, amount f32, mut dst []u8, stride int) {
	npix := w * h
	if npix == 0 || dst.len < npix * stride {
		return
	}
	mut l := bigbuf.new_f32(npix)
	unsafe {
		mut p := &u16(src)
		for i in 0 .. npix {
			y := 0.2126 * f32(p[0]) + 0.7152 * f32(p[1]) + 0.0722 * f32(p[2])
			l[i] = f32(math.log2(f64(y + spot_eps)))
			p += 3
		}
	}
	short := if w < h { w } else { h }
	mut rb := short / 80
	if rb < 2 {
		rb = 2
	}
	mut b1 := box3_f32(l, w, h, 1)
	mut b2 := box3_f32(l, w, h, rb)
	defer {
		bigbuf.free(mut l)
		bigbuf.free(mut b1)
		bigbuf.free(mut b2)
	}
	gain := f32(150 * math.pow(2, f64(clampf(amount, 0, 100)) / 25))
	for i in 0 .. npix {
		v := 128 + (b1[i] - b2[i]) * gain
		g := if v <= 0 {
			u8(0)
		} else if v >= 255 {
			u8(255)
		} else {
			u8(v + 0.5)
		}
		o := i * stride
		dst[o] = g
		dst[o + 1] = g
		dst[o + 2] = g
		if stride == 4 {
			dst[o + 3] = 255
		}
	}
}

// box3_f32 - тройное размытие квадратом радиуса r (почти гаусс), края -
// среднее по тому, что есть; новый буфер (bigbuf)
fn box3_f32(src []f32, w int, h int, r int) []f32 {
	mut a := bigbuf.new_f32(w * h)
	mut t := bigbuf.new_f32(w * h)
	for i in 0 .. w * h {
		a[i] = src[i]
	}
	for _ in 0 .. 3 {
		box_h_f32(a, mut t, w, h, r)
		box_v_f32(t, mut a, w, h, r)
	}
	bigbuf.free(mut t)
	return a
}

// box_h_f32 - среднее по строке в окне ±r (скользящая сумма)
fn box_h_f32(src []f32, mut dst []f32, w int, h int, r int) {
	for y in 0 .. h {
		o := y * w
		mut s := f32(0)
		mut n := 0
		for x in 0 .. r {
			if x < w {
				s += src[o + x]
				n++
			}
		}
		for x in 0 .. w {
			xa := x + r
			if xa < w {
				s += src[o + xa]
				n++
			}
			xr := x - r - 1
			if xr >= 0 {
				s -= src[o + xr]
				n--
			}
			dst[o + x] = s / f32(n)
		}
	}
}

// box_v_f32 - то же по столбцу
fn box_v_f32(src []f32, mut dst []f32, w int, h int, r int) {
	for x in 0 .. w {
		mut s := f32(0)
		mut n := 0
		for y in 0 .. r {
			if y < h {
				s += src[y * w + x]
				n++
			}
		}
		for y in 0 .. h {
			ya := y + r
			if ya < h {
				s += src[ya * w + x]
				n++
			}
			yr := y - r - 1
			if yr >= 0 {
				s -= src[yr * w + x]
				n--
			}
			dst[y * w + x] = s / f32(n)
		}
	}
}
