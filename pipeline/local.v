module pipeline

// Локальные правки: градиентные фильтры (линейный и радиальный).
//
// Фильтр - описание формы (точки в долях кадра S, до ориентации, поворота
// и кадрирования - фильтр «приклеен» к снимку) и свой набор правок. Вес
// фильтра w (0..1) считается на пиксель из формы: превью, фрагмент 1:1 и
// полный кадр дают одно и то же (форма растеризуется под размер, не
// хранится картинкой).
//
// Правки складываются по фильтрам с весами (как в Lightroom: два
// фильтра по +1 EV на пересечении дают +2) и действуют на пиксель там же,
// где их глобальные родственники, но без перестройки таблиц:
//   температура/оттенок - множители каналов линейного сырья (с
//     сохранением люмы), до люмы;
//   экспозиция, тени, света - добавка в EV к общему множителю k
//     (тени/света - по тоновой позиции пикселя, маски (1-t)² и t²);
//   контраст - S-кривая тона (смесь с тождественной по силе);
//   насыщенность - множитель к действующей насыщенности;
//   чёткость (Clarity) - добавка к силе Clarity кадра (clarity.v; нужна
//     маска окрестности - без неё не действует);
//   резкость - добавка к силе резкости кадра (sharpen.v, только
//     apply_image): проход пишет сумму в буфер, резкость берёт её на
//     пиксель; минус - смягчение.
// Пиксели вне всех фильтров (сумма весов 0) не меняются - байт в байт
// как без фильтров.
import math

pub enum MaskKind {
	linear
	radial
}

// Mask - градиентный фильтр. Координаты точек - доли кадра S (x - по
// ширине, y - по высоте); длины радиального - в долях ВЫСОТЫ S (кадр
// неквадратный: эллипс должен оставаться эллипсом при любом размере).
pub struct Mask {
pub mut:
	kind MaskKind
	on   bool = true // выключенный фильтр не действует (остаётся в списке)
	// Линейный: a - начало перехода (полное действие), b - конец (действия
	// нет); за a - полное, за b - нет. Радиальный: a - центр
	ax f32
	ay f32
	bx f32
	by f32
	// Радиальный: полуоси (доли высоты S), поворот оси rx (градусы, от оси
	// x кадра S к оси y - по часовой при y вниз), растушёвка 0..100 (доля
	// радиуса, на которой действие спадает до нуля), invert - действие
	// снаружи эллипса
	rx      f32
	ry      f32
	angle   f32
	feather f32 = 50
	invert  bool
	// Ограничение диапазоном (умножает вес формы). По яркости - тоновая
	// позиция пикселя (0..100: гамма-шкала люмы после экспозиции, как у
	// теней/светов) от lum_lo до lum_hi, края спадают на lum_soft. По
	// цвету - оттенок hue (градусы, HSV линейного RGB после ББ): полное
	// действие до hue_w/2 от него, спад до нуля к hue_w; серое (почти без
	// насыщенности) не входит
	lum_on   bool
	lum_lo   f32
	lum_hi   f32 = 100
	lum_soft f32 = 10
	col_on   bool
	hue      f32
	hue_w    f32 = 30
	// Правки: экспозиция EV (-4..4), остальное -100..100
	exposure   f32
	contrast   f32
	clarity    f32
	sharpness  f32
	highlights f32
	shadows    f32
	saturation f32
	temp       f32
	tint       f32
}

// has_edits - у фильтра есть хоть одна правка (пустой не считается)
pub fn (m Mask) has_edits() bool {
	return m.exposure != 0 || m.contrast != 0 || m.clarity != 0 || m.sharpness != 0
		|| m.highlights != 0 || m.shadows != 0 || m.saturation != 0 || m.temp != 0 || m.tint != 0
}

// MaskMap - пиксель (i, j) рендерного буфера -> точка кадра в единицах
// высоты S: X = a·i + b·j + c, Y = d·i + e·j + f (центр пикселя). Его
// задаёт вызывающий под свой буфер (mask_map, region) - производное поле
// Params.lmap; w == 0 - фильтры не применяются.
pub struct MaskMap {
pub:
	w  int // ширина буфера, пиксели
	ar f64 // ширина / высота кадра S
	a  f64
	b  f64
	c  f64
	d  f64
	e  f64
	f  f64
}

// mask_map - отображение для буфера ow x oh, полученного геометрией g из
// кадра sw x sh (crop - как в geom_apply); важна только пропорция кадра,
// поэтому превью и полный кадр дают одно и то же в долях
pub fn mask_map(g Geom, sw int, sh int, crop bool, ow int, oh int) MaskMap {
	m := geom_affine(g, sw, sh, crop, ow, oh)
	k := 1.0 / f64(sh)
	return MaskMap{
		w:  ow
		ar: f64(sw) / f64(sh)
		a:  m.a * k
		b:  m.b * k
		c:  m.c * k
		d:  m.d * k
		e:  m.e * k
		f:  m.f * k
	}
}

// region - то же для фрагмента ширины w, чей пиксель (0, 0) - пиксель
// (x, y) буфера (настоящий 1:1)
pub fn (m MaskMap) region(x int, y int, w int) MaskMap {
	return MaskMap{
		w:  w
		ar: m.ar
		a:  m.a
		b:  m.b
		c:  m.c + m.a * x + m.b * y
		d:  m.d
		e:  m.e
		f:  m.f + m.d * x + m.e * y
	}
}

// LocalMask - фильтр, готовый к рендеру: форма как аффинные функции
// пикселя буфера (линейный - u, 0 в a и 1 в b; радиальный - u, v - оси
// эллипса, единичная окружность - край) и правки в рабочих единицах
struct LocalMask {
	radial bool
	invert bool
	inner  f32 // радиальный: полное действие до этого радиуса (1 - растушёвка)
	ua     f32
	ub     f32
	uc     f32
	va     f32
	vb     f32
	vc     f32
	ev     f32 // EV
	sh     f32 // -1..1
	hi     f32
	con    f32
	cl     f32 // чёткость -1..1
	sp     f32 // резкость -1..1 (доля силы резкости кадра, 1 = 100%)
	sat    f32
	temp   f32
	tint   f32
	// Ограничение диапазоном: яркость - тоновая позиция 0..1, цвет -
	// оттенок и ширина в секстантах (0..6)
	lum bool
	llo f32
	lhi f32
	lsf f32
	col bool
	hue f32
	hw  f32
}

// LocalCtx - фильтры кадра для render_rows (только чтение, общий для
// потоков); n == 0 - фильтров нет
struct LocalCtx {
	n      int
	w      int
	ms     []LocalMask
	use_wb bool  // есть температура/оттенок
	use_tn bool  // есть тени/света
	use_tl bool  // нужна таблица тоновой позиции tl (тени/света, яркость)
	use_ev bool  // есть экспозиция или тени/света
	use_cn bool  // есть контраст
	use_cl bool  // есть чёткость
	use_sp bool  // есть резкость
	use_st bool  // есть насыщенность
	tl     []f32 // люма u16 -> тоновая позиция 0..1 после экспозиции
	cp     []f32 // S-кривая контраста +1 (a = 2), 257 узлов тон -> тон
	cn     []f32 // контраста -1 (a = 1/2)
}

// Силы правок: тени/света ±100 - ±local_tone_ev EV в черноте/белом;
// температура ±100 - отношение R/B ×2^(±2·local_temp_ev); оттенок ±100 -
// G ×2^(∓local_tint_ev)
const local_tone_ev = f32(1.5)
const local_temp_ev = f32(0.3)
const local_tint_ev = f32(0.25)
const local_feather_min = f32(0.01)

// compile_mask - фильтр к рендеру под отображение mm; none - форма
// вырождена (точки линейного совпали, нулевой радиус)
fn compile_mask(m Mask, mm MaskMap) ?LocalMask {
	mut lm := LocalMask{
		radial: m.kind == .radial
		invert: m.invert
		ev:     m.exposure
		sh:     m.shadows / 100
		hi:     m.highlights / 100
		con:    m.contrast / 100
		cl:     m.clarity / 100
		sp:     m.sharpness / 100
		sat:    m.saturation / 100
		temp:   m.temp / 100
		tint:   m.tint / 100
		lum:    m.lum_on
		llo:    m.lum_lo / 100
		lhi:    m.lum_hi / 100
		lsf:    if m.lum_soft > 0.5 { m.lum_soft / 100 } else { f32(0.005) }
		col:    m.col_on
		hue:    hue_sextant(m.hue)
		hw:     if m.hue_w > 1 { m.hue_w / 60 } else { f32(1.0 / 60) }
	}
	ax := f64(m.ax) * mm.ar
	ay := f64(m.ay)
	if m.kind == .linear {
		dx := f64(m.bx) * mm.ar - ax
		dy := f64(m.by) - ay
		l2 := dx * dx + dy * dy
		if l2 <= 1e-12 {
			return none
		}
		return LocalMask{
			...lm
			ua: f32((mm.a * dx + mm.d * dy) / l2)
			ub: f32((mm.b * dx + mm.e * dy) / l2)
			uc: f32(((mm.c - ax) * dx + (mm.f - ay) * dy) / l2)
		}
	}
	if m.rx <= 1e-6 || m.ry <= 1e-6 {
		return none
	}
	a := f64(m.angle) * math.pi / 180
	cs := math.cos(a)
	sn := math.sin(a)
	rx := f64(m.rx)
	ry := f64(m.ry)
	mut fe := m.feather / 100
	if fe < local_feather_min {
		fe = local_feather_min
	} else if fe > 1 {
		fe = 1
	}
	// u = ((X - ax)·cos + (Y - ay)·sin) / rx,
	// v = (-(X - ax)·sin + (Y - ay)·cos) / ry
	return LocalMask{
		...lm
		inner: 1 - fe
		ua:    f32((mm.a * cs + mm.d * sn) / rx)
		ub:    f32((mm.b * cs + mm.e * sn) / rx)
		uc:    f32(((mm.c - ax) * cs + (mm.f - ay) * sn) / rx)
		va:    f32((-mm.a * sn + mm.d * cs) / ry)
		vb:    f32((-mm.b * sn + mm.e * cs) / ry)
		vc:    f32((-(mm.c - ax) * sn + (mm.f - ay) * cs) / ry)
	}
}

// hue_sextant - градусы -> секстанты 0..6
fn hue_sextant(deg f32) f32 {
	mut h := f32(math.fmod(f64(deg), 360))
	if h < 0 {
		h += 360
	}
	return h / 60
}

// local_ctx - фильтры к рендеру: только включённые и с правками
fn local_ctx(p &Params) LocalCtx {
	mm := p.lmap
	if mm.w <= 0 || p.masks.len == 0 {
		return LocalCtx{}
	}
	mut ms := []LocalMask{}
	for m in p.masks {
		if !m.on || !m.has_edits() {
			continue
		}
		ms << compile_mask(m, mm) or { continue }
	}
	return ctx_of(p, ms, mm.w)
}

// ctx_of - контекст рендера по готовым фильтрам (флаги и таблицы - по
// тому, что в них есть)
fn ctx_of(p &Params, ms []LocalMask, w int) LocalCtx {
	if ms.len == 0 {
		return LocalCtx{}
	}
	mut use_wb := false
	mut use_tn := false
	mut use_ev := false
	mut use_cn := false
	mut use_cl := false
	mut use_sp := false
	mut use_st := false
	mut use_lum := false
	for lm in ms {
		use_wb = use_wb || lm.temp != 0 || lm.tint != 0
		use_tn = use_tn || lm.sh != 0 || lm.hi != 0
		use_ev = use_ev || lm.ev != 0 || lm.sh != 0 || lm.hi != 0
		use_cn = use_cn || lm.con != 0
		use_cl = use_cl || lm.cl != 0
		use_sp = use_sp || lm.sp != 0
		use_st = use_st || lm.sat != 0
		use_lum = use_lum || lm.lum
	}
	use_tl := use_tn || use_lum
	return LocalCtx{
		n:      ms.len
		w:      w
		ms:     ms
		use_wb: use_wb
		use_tn: use_tn
		use_tl: use_tl
		use_ev: use_ev
		use_cn: use_cn
		use_cl: use_cl
		use_sp: use_sp
		use_st: use_st
		tl:     if use_tl { build_tlut(p) } else { []f32{} }
		cp:     if use_cn { contrast_curve(2) } else { []f32{} }
		cn:     if use_cn { contrast_curve(0.5) } else { []f32{} }
	}
}

// build_tlut - люма u16 -> тоновая позиция t после экспозиции (как в
// build_mlut): маски локальных теней и светов
fn build_tlut(p &Params) []f32 {
	e := math.powf(2.0, p.exposure)
	mut t := []f32{len: 65536}
	for y in 0 .. 65536 {
		mut yl := f32(y) * (1.0 / 65535.0) * e
		if yl > 1.0 {
			yl = 1.0
		}
		t[y] = math.powf(yl, inv_gamma)
	}
	return t
}

// contrast_curve - S-кривая v^a / (v^a + (1-v)^a) по тону 0..255, 257
// узлов (последний - повтор, для интерполяции у 255)
fn contrast_curve(a f32) []f32 {
	mut c := []f32{len: 257}
	for i in 0 .. 256 {
		v := f32(i) / 255
		va := math.powf(v, a)
		ia := math.powf(1 - v, a)
		c[i] = if va + ia > 0 { 255 * va / (va + ia) } else { f32(0) }
	}
	c[256] = c[255]
	return c
}

// mask_weight - вес фильтра в пикселе (x, y) буфера, 0..1
@[inline]
fn mask_weight(m &LocalMask, x f32, y f32) f32 {
	u := m.ua * x + m.ub * y + m.uc
	if !m.radial {
		// Полное действие до a (u <= 0), нет - за b (u >= 1), между -
		// гладкий спад
		if u <= 0 {
			return 1
		}
		if u >= 1 {
			return 0
		}
		s := 1 - u
		return s * s * (3 - 2 * s)
	}
	v := m.va * x + m.vb * y + m.vc
	d2 := u * u + v * v
	mut w := f32(0)
	if d2 < 1 {
		d := math.sqrtf(d2)
		if d <= m.inner {
			w = 1
		} else {
			s := (1 - d) / (1 - m.inner)
			w = s * s * (3 - 2 * s)
		}
	}
	return if m.invert { 1 - w } else { w }
}

// Цвет: насыщенность HSV, ниже которой пиксель в диапазон не входит
// совсем, и выше которой - целиком (между - гладко): серое и почти серое
// по оттенку не выбирается (шум даёт ему случайный оттенок)
const range_sat_lo = f32(0.03)
const range_sat_hi = f32(0.12)

@[inline]
fn smooth01(v f32) f32 {
	if v <= 0 {
		return 0
	}
	if v >= 1 {
		return 1
	}
	return v * v * (3 - 2 * v)
}

// range_weight - ограничение фильтра диапазоном в пикселе: tp - тоновая
// позиция, cr, cg, cb - линейный RGB после ББ
@[inline]
fn range_weight(m &LocalMask, tp f32, cr f32, cg f32, cb f32) f32 {
	mut w := f32(1)
	if m.lum {
		if tp < m.llo {
			w = smooth01((tp - m.llo + m.lsf) / m.lsf)
		} else if tp > m.lhi {
			w = smooth01((m.lhi + m.lsf - tp) / m.lsf)
		}
		if w <= 0 {
			return 0
		}
	}
	if m.col {
		h, sv := hue_sat(cr, cg, cb)
		ws := smooth01((sv - range_sat_lo) / (range_sat_hi - range_sat_lo))
		if ws <= 0 {
			return 0
		}
		mut dh := h - m.hue
		if dh < 0 {
			dh = -dh
		}
		if dh > 3 {
			dh = 6 - dh
		}
		// Полное действие до половины ширины, спад до нуля к ширине
		w *= ws * smooth01((m.hw - dh) / (0.5 * m.hw))
	}
	return w
}

// hue_sat - оттенок (секстанты 0..6) и насыщенность HSV
@[inline]
fn hue_sat(r f32, g f32, b f32) (f32, f32) {
	mx := if r > g {
		if r > b { r } else { b }
	} else {
		if g > b { g } else { b }
	}
	mn := if r < g {
		if r < b { r } else { b }
	} else {
		if g < b { g } else { b }
	}
	c := mx - mn
	if c <= 0 || mx <= 0 {
		return 0, 0
	}
	mut h := f32(0)
	if mx == r {
		h = (g - b) / c
		if h < 0 {
			h += 6
		}
	} else if mx == g {
		h = (b - r) / c + 2
	} else {
		h = (r - g) / c + 4
	}
	return h, c / mx
}

// Probe - пипетка ограничения: оттенок (градусы), насыщенность HSV и
// тоновая позиция (0..100) - как их видит фильтр
pub struct Probe {
pub:
	hue  f32
	sat  f32
	tone f32
}

// probe - что фильтр «видит» в линейном цвете превью r, g, b (среднее
// пятна, до ББ): ББ матрицей (как быстрый путь рендера, без дымки)
pub fn probe(r f32, g f32, b f32, p &Params) Probe {
	mut cr := r
	mut cg := g
	mut cb := b
	if p.wb_on {
		m := p.wb.m
		cr = m[0] * r + m[1] * g + m[2] * b
		cg = m[3] * r + m[4] * g + m[5] * b
		cb = m[6] * r + m[7] * g + m[8] * b
	}
	h, sv := hue_sat(cr, cg, cb)
	mut yl := (0.2126 * cr + 0.7152 * cg + 0.0722 * cb) / 65535 * math.powf(2, p.exposure)
	yl = if yl < 0 {
		0
	} else if yl > 1 {
		1
	} else {
		yl
	}
	return Probe{
		hue:  h * 60
		sat:  sv
		tone: math.powf(yl, inv_gamma) * 100
	}
}

// exp2f - 2^x без powf (локальные правки на пиксель): целая часть - в
// показатель f32, дробная - ряд Тейлора 5-й степени (ошибка < 2e-4
// относительной, ~3e-4 EV)
@[inline]
fn exp2f(x f32) f32 {
	mut v := x
	if v < -30 {
		v = -30
	} else if v > 30 {
		v = 30
	}
	mut xi := int(v)
	if f32(xi) > v {
		xi--
	}
	f := v - f32(xi)
	p := 1 + f * (0.6931472 + f * (0.2402265 + f * (0.05550411 + f * (0.009618129 +
		f * 0.001333356))))
	return p * math.f32_from_bits(u32((xi + 127) << 23))
}

// LocalSum - сумма правок фильтров в пикселе (с весами)
struct LocalSum {
mut:
	any  bool
	w    f32 // сумма весов (показ маски одного фильтра - его вес)
	ev   f32
	sh   f32
	hi   f32
	con  f32
	cl   f32
	sp   f32
	sat  f32
	temp f32
	tint f32
}

// local_sum - правки всех фильтров в пикселе (x, y) буфера; yl - люма
// u16 (для яркости - через таблицу tl), cr, cg, cb - линейный RGB после
// ББ и дымки (для цвета)
@[inline]
fn local_sum(lc &LocalCtx, x f32, y f32, yl int, cr f32, cg f32, cb f32) LocalSum {
	mut s := LocalSum{}
	for k in 0 .. lc.n {
		m := unsafe { &lc.ms[k] }
		mut w := mask_weight(m, x, y)
		if w <= 0 {
			continue
		}
		if m.lum || m.col {
			tp := if m.lum { unsafe { lc.tl[yl] } } else { f32(0) }
			w *= range_weight(m, tp, cr, cg, cb)
			if w <= 0 {
				continue
			}
		}
		s.any = true
		s.w += w
		s.ev += w * m.ev
		s.sh += w * m.sh
		s.hi += w * m.hi
		s.con += w * m.con
		s.cl += w * m.cl
		s.sp += w * m.sp
		s.sat += w * m.sat
		s.temp += w * m.temp
		s.tint += w * m.tint
	}
	return s
}

// local_wb - температура и оттенок фильтров: множители каналов
// линейного сырья, нормированные по люме BT.709 (яркость не меняется)
@[inline]
fn local_wb(s &LocalSum) (f32, f32, f32) {
	gr := exp2f(s.temp * local_temp_ev)
	gb := exp2f(-s.temp * local_temp_ev)
	gg := exp2f(-s.tint * local_tint_ev)
	n := 1 / (0.2126 * gr + 0.7152 * gg + 0.0722 * gb)
	return gr * n, gg * n, gb * n
}

// local_contrast - контраст фильтров по тону v (0..255): смесь
// тождественной и S-кривой ±1 по силе (сумма ограничена ±1 - дальше
// смесь потеряла бы монотонность)
@[inline]
fn local_contrast(lc &LocalCtx, con f32, v f32) f32 {
	mut a := con
	c := if a > 0 { lc.cp } else { lc.cn }
	if a < 0 {
		a = -a
	}
	if a > 1 {
		a = 1
	}
	mut x := v
	if x < 0 {
		x = 0
	} else if x > 255 {
		x = 255
	}
	i := int(x)
	fr := x - f32(i)
	cv := unsafe { c[i] * (1 - fr) + c[i + 1] * fr }
	return v + a * (cv - v)
}

// mask_weights - вес фильтра m (0..255) на каждом пикселе буфера w x h,
// отображение mm (показ маски заливкой поверх снимка). Правки не нужны:
// форма считается и у пустого фильтра.
pub fn mask_weights(m Mask, mm MaskMap, w int, h int) []u8 {
	mut out := []u8{len: w * h}
	lm := compile_mask(m, mm) or { return out }
	for j in 0 .. h {
		for i in 0 .. w {
			out[j * w + i] = u8(int(mask_weight(&lm, f32(i), f32(j)) * 255 + 0.5))
		}
	}
	return out
}

// mask_view - вес фильтра p.masks[idx] (0..255) на каждом пикселе кадра w
// x h с ограничением диапазоном (показ маски): тот же проход, что рендер
// (дымка, ББ, люма), но вместо снимка - вес. Форма считается и у
// выключенного и пустого фильтра. haze - как в apply_image (nil - без
// дымки).
pub fn mask_view(src &u16, haze &HazeMap, w int, h int, p Params, idx int) []u8 {
	mut out := []u8{len: w * h}
	if idx < 0 || idx >= p.masks.len || p.lmap.w != w {
		return out
	}
	lm := compile_mask(p.masks[idx], p.lmap) or { return out }
	lc := ctx_of(&p, [lm], w)
	mut none_ := []u8{}
	render_ex(src, unsafe { nil }, haze, w * h, p, mut none_, 4, unsafe { nil }, &lc,
		unsafe { &u8(out.data) }, unsafe { nil })
	return out
}

// sp_enc - сумма резкости фильтров (доля силы, -1..1.55) в байт: (s + 1)
// ×100; без фильтров - 100
@[inline]
fn sp_enc(s f32) u8 {
	v := int((s + 1) * 100 + 0.5)
	return if v < 0 { u8(0) } else if v > 255 { u8(255) } else { u8(v) }
}

// sp_dec - обратно из байта
@[inline]
fn sp_dec(v u8) f32 {
	return f32(v) * 0.01 - 1
}
