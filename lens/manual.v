module lens

// Ручная коррекция объектива - для объективов, которых нет в базе lensfun
// (мануальные, старые, через адаптер), и для доводки поверх профиля:
// дисторсия, хроматические аберрации (ХА) по каналам и виньетирование.
// Свой код, без lensfun: все три поправки радиальные, от центра кадра,
// радиус - в долях полудиагонали (одинаково на превью half-size и полном
// кадре).
//
// Порядок - как у профиля: виньетирование по исходной геометрии сенсора
// (до перемещения пикселей), затем ремап. Вместе с профилем:
// виньетирование профиля, ручное виньетирование, геометрия профиля,
// ручная геометрия (доводка уже исправленного кадра) - manual_vignetting
// и manual_geometry по отдельности (lens_full в приложении).
import math
import runtime
import bigbuf
import pipeline { Region }

// man_dist_max - коэффициент дисторсии при ±100: r_src = r·(1 − k·r²).
// При k < 1/3 отображение монотонно до угла (без «складки»)
const man_dist_max = 0.25
// man_ca_max - разница масштаба канала при ±100 (0.2% - ~7 px в углу
// полного кадра 24 Мп)
const man_ca_max = 0.002
// man_vign_ev - добавка яркости в углу при ±100, EV
const man_vign_ev = 2.0

// Manual - ручные поправки (ползунки секции «Объектив»), −100..100;
// vign_mid 0..100 - где начинается спад виньетки (50 - как у обычного
// объектива, больше - ближе к углам)
pub struct Manual {
pub mut:
	dist     f32 // плюс - убирает бочку, минус - подушку
	vign     f32 // плюс - светлее углы
	vign_mid f32 = 50
	ca_r     f32 // красный/голубой: масштаб красного канала
	ca_b     f32 // синий/жёлтый: масштаб синего канала
}

// active - есть ли что исправлять
pub fn (m Manual) active() bool {
	return m.vign != 0 || m.has_geom()
}

// has_geom - нужен ли ремап (дисторсия или ХА)
pub fn (m Manual) has_geom() bool {
	return m.dist != 0 || m.ca_r != 0 || m.ca_b != 0
}

// key - строка для ключей кэшей (1:1, до/после)
pub fn (m Manual) key() string {
	if !m.active() {
		return '-'
	}
	return '${m.dist}/${m.vign}/${m.vign_mid}/${m.ca_r}/${m.ca_b}'
}

// man_vign_power - показатель спада виньетки r^p по средней точке:
// 50 - p = 2 (как спад обычного объектива), 0 - 0.5, 100 - 8
fn man_vign_power(mid f32) f64 {
	return 2.0 * math.pow(4.0, (f64(mid) - 50) / 50)
}

// man_vign_gain - усиление в точке на радиусе r (доля полудиагонали)
fn man_vign_gain(m Manual, r f64) f32 {
	return f32(math.pow(2.0, f64(m.vign) / 100 * man_vign_ev * math.pow(r, man_vign_power(m.vign_mid))))
}

// manual_vign_lut - радиальный профиль усиления (как vign_lut профиля:
// vign_lut_n точек от центра до угла); пусто - без виньетирования
pub fn manual_vign_lut(m Manual) []f32 {
	if m.vign == 0 {
		return []f32{}
	}
	mut lut := []f32{len: vign_lut_n}
	for i in 0 .. vign_lut_n {
		lut[i] = man_vign_gain(m, f64(i) / f64(vign_lut_n - 1))
	}
	return lut
}

// ManualPlan - ремап дисторсии и ХА кадра w x h: выход (i, j) канала c
// читает источник в c + (p − c)·s·kc·(1 − k·(s·|p − c|/R)²), где c -
// центр, R - полудиагональ, s - масштаб без пустых углов (fit_scale), kc -
// масштаб канала (ХА). Точка считается сама по себе (без накопления) -
// фрагмент побитово равен вырезке полного прохода.
pub struct ManualPlan {
pub:
	w int
	h int
mut:
	cx f64
	cy f64
	rr f64 // полудиагональ
	k  f64
	s  f64
	kc [3]f64
}

// manual_plan - план ремапа; none - дисторсии и ХА нет
pub fn manual_plan(m Manual, w int, h int) ?ManualPlan {
	if !m.has_geom() || w < 2 || h < 2 {
		return none
	}
	cx := f64(w - 1) / 2
	cy := f64(h - 1) / 2
	mut p := ManualPlan{
		w:  w
		h:  h
		cx: cx
		cy: cy
		rr: math.sqrt(cx * cx + cy * cy)
		k:  f64(m.dist) / 100 * man_dist_max
		s:  1
		kc: [1 + f64(m.ca_r) / 100 * man_ca_max, 1.0, 1 + f64(m.ca_b) / 100 * man_ca_max]!
	}
	p.s = p.fit_scale()
	return p
}

// at - точка источника для выхода (x, y) канала c
@[inline]
fn (p &ManualPlan) at(c int, x f64, y f64) (f64, f64) {
	dx := (x - p.cx) * p.s
	dy := (y - p.cy) * p.s
	r2 := (dx * dx + dy * dy) / (p.rr * p.rr)
	f := p.kc[c] * (1 - p.k * r2)
	return p.cx + dx * f, p.cy + dy * f
}

// fit_scale - наибольший масштаб s, при котором край выхода (всех каналов)
// попадает в кадр: нет пустых краёв и потеряно меньше всего. Бочка (k > 0)
// тянет края к центру - s > 1, подушка - s < 1. Сверху s ограничен
// монотонностью r·(1 − k·r²) (иначе отображение «складывается» и проверка
// края врёт).
fn (p &ManualPlan) fit_scale() f64 {
	mut hi := 2.0
	if p.k > 0 {
		hi = math.min(hi, 0.95 / math.sqrt(3 * p.k))
	}
	mut lo := 0.3
	mut t := ManualPlan{
		...*p
	}
	for _ in 0 .. 40 {
		mid := (lo + hi) / 2
		t.s = mid
		if t.border_inside() {
			lo = mid
		} else {
			hi = mid
		}
	}
	return lo
}

// border_inside - все точки края выхода (по 64 на сторону и углы) читают
// источник внутри кадра
fn (p &ManualPlan) border_inside() bool {
	n := 64
	fw := f64(p.w - 1)
	fh := f64(p.h - 1)
	for i in 0 .. n + 1 {
		a := f64(i) / f64(n)
		for pt in [[a * fw, 0.0], [a * fw, fh], [0.0, a * fh], [fw, a * fh]] {
			for c in 0 .. 3 {
				x, y := p.at(c, pt[0], pt[1])
				if x < -1e-6 || y < -1e-6 || x > fw + 1e-6 || y > fh + 1e-6 {
					return false
				}
			}
		}
	}
	return true
}

// source_box - кусок источника, из которого remap читает выход r (с
// соседями билинейной выборки). Отображение радиальное и монотонное -
// образ прямоугольника ограничен образом его края, внутренние точки не
// нужны
pub fn (p &ManualPlan) source_box(r Region) Region {
	if r.w <= 0 || r.h <= 0 {
		return Region{}
	}
	mut b := BoxAcc{
		x0: p.w - 1
		y0: p.h - 1
	}
	for x in r.x .. r.x + r.w {
		p.box_add(mut b, x, r.y)
		p.box_add(mut b, x, r.y + r.h - 1)
	}
	for y in r.y .. r.y + r.h {
		p.box_add(mut b, r.x, y)
		p.box_add(mut b, r.x + r.w - 1, y)
	}
	return Region{b.x0, b.y0, b.x1 - b.x0 + 1, b.y1 - b.y0 + 1}
}

// BoxAcc - рамка точек источника (source_box)
struct BoxAcc {
mut:
	x0 int
	y0 int
	x1 int
	y1 int
}

// box_add - точки выборки трёх каналов выхода (x, y) с соседями (после
// прижатия к кадру, как в bilinear)
fn (p &ManualPlan) box_add(mut b BoxAcc, x int, y int) {
	fw := f32(p.w - 1)
	fh := f32(p.h - 1)
	for c in 0 .. 3 {
		sx, sy := p.at(c, f64(x), f64(y))
		ix := int(clamp_f(f32(sx), fw))
		iy := int(clamp_f(f32(sy), fh))
		b.x0 = imin(b.x0, ix)
		b.y0 = imin(b.y0, iy)
		b.x1 = imax(b.x1, imin(ix + 1, p.w - 1))
		b.y1 = imax(b.y1, imin(iy + 1, p.h - 1))
	}
}

// ManCtx - общее для потоков ремапа
struct ManCtx {
	p   &ManualPlan = unsafe { nil }
	src &u16        = unsafe { nil }
	sb  Region
	r   Region
	dst &u16 = unsafe { nil }
}

// remap - выход r (кадр w x h) в dst (r.w x r.h RGB) из куска источника sb
// (source_box(r) или шире); строки - в потоки
pub fn (p &ManualPlan) remap(src &u16, sb Region, r Region, dst &u16) {
	ctx := ManCtx{
		p:   p
		src: src
		sb:  sb
		r:   r
		dst: dst
	}
	nt := imin(runtime.nr_cpus(), 16)
	if nt <= 1 || r.h < 64 {
		man_rows(&ctx, 0, r.h)
		return
	}
	step := (r.h + nt - 1) / nt
	mut ts := []thread{}
	for y0 := 0; y0 < r.h; y0 += step {
		ts << spawn man_rows(&ctx, y0, imin(r.h, y0 + step))
	}
	ts.wait()
}

// man_rows - строки j0..j1 выхода (от r.y)
fn man_rows(ctx &ManCtx, j0 int, j1 int) {
	p := ctx.p
	r := ctx.r
	unsafe {
		mut d := ctx.dst + j0 * r.w * 3
		for j in j0 .. j1 {
			y := f64(r.y + j)
			for i in 0 .. r.w {
				x := f64(r.x + i)
				for c in 0 .. 3 {
					sx, sy := p.at(c, x, y)
					d[c] = bilinear(ctx.src, ctx.sb, p.w, p.h, c, f32(sx), f32(sy))
				}
				d += 3
			}
		}
	}
}

// manual_vign_region - ручное виньетирование куска r кадра w x h
// (усиление - от центра полного кадра)
pub fn manual_vign_region(buf &u16, r Region, w int, h int, lut []f32) {
	if lut.len == vign_lut_n {
		apply_radial_gain(buf, r, w, h, lut)
	}
}

// manual_vignetting - ручное виньетирование всего кадра на месте (до
// любого ремапа - и профиля, и ручного)
pub fn manual_vignetting(buf &u16, w int, h int, m Manual) {
	manual_vign_region(buf, Region{0, 0, w, h}, w, h, manual_vign_lut(m))
}

// manual_geometry - дисторсия и ХА всего кадра на месте (после геометрии
// профиля). false - ремап не нужен
pub fn manual_geometry(buf &u16, w int, h int, m Manual) bool {
	p := manual_plan(m, w, h) or { return false }
	mut src := bigbuf.new_u16(w * h * 3)
	defer {
		bigbuf.free(mut src)
	}
	unsafe { vmemcpy(src.data, buf, u64(w) * u64(h) * 3 * 2) }
	full := Region{0, 0, w, h}
	p.remap(unsafe { &u16(src.data) }, full, full, buf)
	return true
}

// manual_correct - вся ручная коррекция кадра без профиля: виньетирование,
// затем дисторсия и ХА. false - исправлять нечего
pub fn manual_correct(buf &u16, w int, h int, m Manual) bool {
	if !m.active() {
		return false
	}
	manual_vignetting(buf, w, h, m)
	manual_geometry(buf, w, h, m)
	return true
}
