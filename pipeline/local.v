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
import bigbuf

pub enum MaskKind {
	linear
	radial
	brush // кисть: мазки (Stroke), растеризуются под отображение
}

// Stroke - мазок кисти: путь - пары x, y в долях кадра S (до ориентации,
// поворота и кадрирования), радиус - доля высоты S, растушёвка 0..100 -
// доля радиуса со спадом до нуля, сила 0..1. Мазки складываются как
// объединение с силой: w + f·c - w·f·c (c - покрытие мазка)
//
// cols - цвет под центром кисти, по 3 значения на точку пути (сырьё
// буфера до ББ и дымки, u16-шкала, среднее пятна); пишется всегда.
// Автомаска (auto у мазка или у формы-кисти): мазок закрашивает только
// похожее на цвет своих точек - каждая точка красит в своём круге
// пиксели, похожие на её цвет (по расстоянию в log2 RGB: до auto_t0 EV -
// полностью, к auto_t1 - ноль), мазок - объединение точек.
pub struct Stroke {
pub mut:
	pts     []f32
	radius  f32
	feather f32 = 50
	flow    f32 = 1
	auto    bool
	cols    []f32
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
	// Кисть: мазки (kind == .brush); auto - автомаска всех мазков формы
	strokes []Stroke
	auto    bool
	// Части фильтра (сложение масок): формы с операцией над весом -
	// добавить, вычесть, пересечь; применяются по порядку после основы
	parts []MaskPart
	// Расширить / сузить (-100..100): край всей формы (основа с частями,
	// до ограничения диапазоном) сдвигается наружу / внутрь на
	// grow_max·(grow/100)² высоты кадра
	grow f32
	// Имя в списке фильтров (пусто - по виду: «Линейный»)
	name string
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

// MaskOp - операция части над весом фильтра w (wp - вес части):
// add - объединение w + wp - w·wp, subtract - w·(1 - wp), intersect - w·wp
pub enum MaskOp {
	add
	subtract
	intersect
}

// MaskPart - форма фильтра: основа (Mask.shape) или часть с операцией.
// Поля - как у Mask (доли кадра S, длины - доли высоты S)
pub struct MaskPart {
pub mut:
	kind    MaskKind
	op      MaskOp
	ax      f32
	ay      f32
	bx      f32
	by      f32
	rx      f32
	ry      f32
	angle   f32
	feather f32 = 50
	invert  bool
	strokes []Stroke
	auto    bool // кисть: автомаска всех мазков
}

// copy - глубокая копия мазков
pub fn (s Stroke) copy() Stroke {
	return Stroke{
		...s
		pts:  s.pts.clone()
		cols: s.cols.clone()
	}
}

// copy - глубокая копия формы (мазки - свои массивы)
pub fn (p MaskPart) copy() MaskPart {
	return MaskPart{
		...p
		strokes: p.strokes.map(it.copy())
	}
}

// shape - форма фильтра: i = -1 - основа, иначе часть i
pub fn (m Mask) shape(i int) MaskPart {
	if i >= 0 && i < m.parts.len {
		return m.parts[i]
	}
	return MaskPart{
		kind:    m.kind
		ax:      m.ax
		ay:      m.ay
		bx:      m.bx
		by:      m.by
		rx:      m.rx
		ry:      m.ry
		angle:   m.angle
		feather: m.feather
		invert:  m.invert
		strokes: m.strokes
		auto:    m.auto
	}
}

// set_shape - записать форму i (-1 - основа: вид и операция основы не
// меняются)
pub fn (mut m Mask) set_shape(i int, s MaskPart) {
	if i >= 0 && i < m.parts.len {
		m.parts[i] = s
		return
	}
	m.ax = s.ax
	m.ay = s.ay
	m.bx = s.bx
	m.by = s.by
	m.rx = s.rx
	m.ry = s.ry
	m.angle = s.angle
	m.feather = s.feather
	m.invert = s.invert
	m.strokes = s.strokes
	m.auto = s.auto
}

// copy - глубокая копия (части - свой массив: снимки истории не должны
// делить его с живым состоянием)
pub fn (m Mask) copy() Mask {
	return Mask{
		...m
		strokes: m.strokes.map(it.copy())
		parts:   m.parts.map(it.copy())
	}
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

// LocalShape - форма, готовая к рендеру: аффинные функции пикселя буфера
// (линейный - u, 0 в a и 1 в b; радиальный - u, v - оси эллипса,
// единичная окружность - край)
struct LocalShape {
	radial bool
	brush  bool // кисть: вес - из сетки grid (u, v - координаты сетки)
	grid   []u8 // кисть: вес 0..255 на сетке gw x gh (bigbuf, free_ctx)
	gw     int
	gh     int
	invert bool
	inner  f32 // радиальный: полное действие до этого радиуса (1 - растушёвка)
	ua     f32
	ub     f32
	uc     f32
	va     f32
	vb     f32
	vc     f32
}

// LocalPart - часть фильтра к рендеру: форма и операция
struct LocalPart {
	form LocalShape
	op   MaskOp
}

// LocalMask - фильтр, готовый к рендеру: основа, части и правки в
// рабочих единицах
struct LocalMask {
	form   LocalShape
	parts  []LocalPart
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

// compile_mask - фильтр к рендеру под отображение mm; none - основа
// вырождена (точки линейного совпали, нулевой радиус); вырожденная часть
// пропускается
fn compile_mask(m Mask, mm MaskMap, img &ImgRef) ?LocalMask {
	mut form := compile_shape(m.shape(-1), mm, img)?
	mut parts := []LocalPart{}
	for pt in m.parts {
		pf := compile_shape(pt, mm, img) or { continue }
		parts << LocalPart{
			form: pf
			op:   pt.op
		}
	}
	if m.grow != 0 {
		// Расширение - по весу всей формы: она растеризуется в сетку кадра
		// и дальше берётся из неё (как кисть), частей больше нет
		form = grow_shape(LocalMask{ form: form, parts: parts }, mm, m.grow)
		parts = []LocalPart{}
	}
	return LocalMask{
		form:  form
		parts: parts
		ev:    m.exposure
		sh:    m.shadows / 100
		hi:    m.highlights / 100
		con:   m.contrast / 100
		cl:    m.clarity / 100
		sp:    m.sharpness / 100
		sat:   m.saturation / 100
		temp:  m.temp / 100
		tint:  m.tint / 100
		lum:   m.lum_on
		llo:   m.lum_lo / 100
		lhi:   m.lum_hi / 100
		lsf:   if m.lum_soft > 0.5 { m.lum_soft / 100 } else { f32(0.005) }
		col:   m.col_on
		hue:   hue_sextant(m.hue)
		hw:    if m.hue_w > 1 { m.hue_w / 60 } else { f32(1.0 / 60) }
	}
}

// ImgRef - буфер, который рендерится (сырьё до ББ и дымки, w x h) - для
// автомаски кисти; nil - без снимка (автомазки - как обычные)
struct ImgRef {
	src &u16 = unsafe { nil }
	w   int
	h   int
}

// compile_shape - форма к рендеру под отображение mm; none - вырождена.
// img - снимок для автомаски кисти (или nil)
fn compile_shape(m MaskPart, mm MaskMap, img &ImgRef) ?LocalShape {
	if m.kind == .brush {
		if m.strokes.len == 0 {
			return none
		}
		gw, gh := brush_dims(mm.ar)
		// Автомаска: сетка цветов снимка (в рамке автомазков) - мазки
		// красят по похожести клетки на цвет своих точек
		has_img := !isnil(img) && !isnil(img.src) && img.w > 0 && img.h > 0
		autos := m.strokes.filter(is_auto(it, m.auto))
		mut cg := if has_img && autos.len > 0 {
			color_grid(img, mm, gw, gh, autos)
		} else {
			[]u8{}
		}
		grid := raster_strokes(m.strokes, gw, gh, cg, m.auto)
		if cg.len > 0 {
			bigbuf.free(mut cg)
		}
		return grid_shape(grid, gw, gh, mm)
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
		return LocalShape{
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
	return LocalShape{
		radial: true
		invert: m.invert
		inner:  1 - fe
		ua:     f32((mm.a * cs + mm.d * sn) / rx)
		ub:     f32((mm.b * cs + mm.e * sn) / rx)
		uc:     f32(((mm.c - ax) * cs + (mm.f - ay) * sn) / rx)
		va:     f32((-mm.a * sn + mm.d * cs) / ry)
		vb:     f32((-mm.b * sn + mm.e * cs) / ry)
		vc:     f32((-(mm.c - ax) * sn + (mm.f - ay) * cs) / ry)
	}
}

// grid_shape - форма, вес которой берётся из сетки кадра gw x gh (кисть,
// расширенная маска). Сетка в долях кадра: gx = X / ar · gw - 0.5,
// gy = Y · gh - 0.5 (центры клеток), X, Y - единицы кадра (mm)
fn grid_shape(grid []u8, gw int, gh int, mm MaskMap) LocalShape {
	kx := f64(gw) / mm.ar
	ky := f64(gh)
	return LocalShape{
		brush: true
		grid:  grid
		gw:    gw
		gh:    gh
		ua:    f32(mm.a * kx)
		ub:    f32(mm.b * kx)
		uc:    f32(mm.c * kx - 0.5)
		va:    f32(mm.d * ky)
		vb:    f32(mm.e * ky)
		vc:    f32(mm.f * ky - 0.5)
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
fn local_ctx(p &Params, img &ImgRef) LocalCtx {
	mm := p.lmap
	if mm.w <= 0 || p.masks.len == 0 {
		return LocalCtx{}
	}
	mut ms := []LocalMask{}
	for m in p.masks {
		if !m.on || !m.has_edits() {
			continue
		}
		ms << compile_mask(m, mm, img) or { continue }
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

// mask_weight - вес фильтра в пикселе (x, y) буфера, 0..1: основа, затем
// части по порядку
@[inline]
fn mask_weight(m &LocalMask, x f32, y f32) f32 {
	mut w := shape_weight(&m.form, x, y)
	for k in 0 .. m.parts.len {
		pt := unsafe { &m.parts[k] }
		match pt.op {
			.add {
				if w < 1 {
					wp := shape_weight(&pt.form, x, y)
					w = w + wp - w * wp
				}
			}
			.subtract {
				if w > 0 {
					w *= 1 - shape_weight(&pt.form, x, y)
				}
			}
			.intersect {
				if w > 0 {
					w *= shape_weight(&pt.form, x, y)
				}
			}
		}
	}
	return w
}

// shape_weight - вес формы в пикселе (x, y) буфера, 0..1
@[inline]
fn shape_weight(m &LocalShape, x f32, y f32) f32 {
	if m.brush {
		return grid_sample(m, m.ua * x + m.ub * y + m.uc, m.va * x + m.vb * y + m.vc)
	}
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
	lm := compile_mask(m, mm, unsafe { nil }) or { return out }
	for j in 0 .. h {
		for i in 0 .. w {
			out[j * w + i] = u8(int(mask_weight(&lm, f32(i), f32(j)) * 255 + 0.5))
		}
	}
	free_mask(&lm)
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
	lm := compile_mask(p.masks[idx], p.lmap, &ImgRef{
		src: src
		w:   w
		h:   h
	}) or { return out }
	if !lm.lum && !lm.col {
		// Без ограничения диапазоном вес - одна форма, снимок не нужен:
		// без прохода рендера, полосами строк по потокам
		shape_view(&lm, w, h, mut out)
		free_mask(&lm)
		return out
	}
	lc := ctx_of(&p, [lm], w)
	mut none_ := []u8{}
	render_ex(src, unsafe { nil }, haze, w * h, p, mut none_, 4, unsafe { nil }, &lc,
		unsafe { &u8(out.data) }, unsafe { nil })
	free_ctx(&lc) // сетки кисти lm - те же, что в lc
	return out
}

// shape_view - вес формы lm (0..255) на каждом пикселе буфера w x h в out
fn shape_view(lm &LocalMask, w int, h int, mut out []u8) {
	o := unsafe { &u8(out.data) }
	nt := bands(w, h)
	if nt <= 1 {
		shape_view_rows(lm, w, 0, h, o)
		return
	}
	step := (h + nt - 1) / nt
	mut ts := []thread{}
	for y0 := 0; y0 < h; y0 += step {
		ts << spawn shape_view_rows(lm, w, y0, imin(h, y0 + step), o)
	}
	ts.wait()
}

fn shape_view_rows(lm &LocalMask, w int, y0 int, y1 int, o &u8) {
	for j in y0 .. y1 {
		for i in 0 .. w {
			unsafe {
				o[j * w + i] = u8(int(mask_weight(lm, f32(i), f32(j)) * 255 + 0.5))
			}
		}
	}
}

// mask_fill - заливка маски поверх снимка pix (RGBA, stride байт на
// пиксель): по весу wt (0..255) красный с непрозрачностью до amax,
// полосами строк по потокам (w x h)
pub fn mask_fill(wt []u8, mut pix []u8, stride int, w int, h int, amax f32) {
	if wt.len != w * h || pix.len < w * h * stride {
		return
	}
	wp := unsafe { &u8(wt.data) }
	pp := unsafe { &u8(pix.data) }
	nt := bands(w, h)
	if nt <= 1 {
		mask_fill_rows(wp, pp, stride, 0, w * h, amax)
		return
	}
	step := (h + nt - 1) / nt
	mut ts := []thread{}
	for y0 := 0; y0 < h; y0 += step {
		ts << spawn mask_fill_rows(wp, pp, stride, y0 * w, imin(h, y0 + step) * w, amax)
	}
	ts.wait()
}

fn mask_fill_rows(wt &u8, pix &u8, stride int, i0 int, i1 int, amax f32) {
	k := amax / 255
	for i in i0 .. i1 {
		unsafe {
			wv := wt[i]
			if wv == 0 {
				continue
			}
			a := f32(wv) * k
			mut d := pix + i * stride
			r := f32(d[0])
			d[0] = u8(r + (255 - r) * a)
			d[1] = u8(f32(d[1]) * (1 - a))
			d[2] = u8(f32(d[2]) * (1 - a))
		}
	}
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

// ── Кисть ──

// brush_grid - длинная сторона сетки кисти (клеток): на полном кадре 24 Мп
// клетка ~3 px - край жёсткой кисти чуть мягче, растушёванной - незаметно
const brush_grid = 2048

// brush_dims - размер сетки кисти по пропорции кадра ar = W/H
fn brush_dims(ar f64) (int, int) {
	if ar >= 1 {
		return brush_grid, imax(1, int(f64(brush_grid) / ar + 0.5))
	}
	return imax(1, int(f64(brush_grid) * ar + 0.5)), brush_grid
}

// raster_strokes - вес мазков (0..255) на сетке gw x gh (bigbuf,
// освобождает вызывающий). Покрытие мазка - по расстоянию d до пути
// (ломаная, минимум по отрезкам): до inner = r·(1 - растушёвка) - 1,
// дальше гладкий спад до 0 на r; путь из одной точки - круг. Мазки
// складываются объединением (от порядка не зависит), поэтому сетка
// делится на полосы строк по потокам: каждый рисует все мазки в своих
// строках
fn raster_strokes(strokes []Stroke, gw int, gh int, cg []u8, sa bool) []u8 {
	mut g := bigbuf.new_u8(gw * gh)
	rc := RasterCtx{
		strokes: strokes
		g:       unsafe { &u8(g.data) }
		cg:      if cg.len > 0 { unsafe { &u8(cg.data) } } else { unsafe { nil } }
		sa:      sa
		gw:      gw
		gh:      gh
	}
	nt := bands(gw, gh)
	if nt <= 1 {
		raster_rows(&rc, 0, gh)
		return g
	}
	step := (gh + nt - 1) / nt
	mut ts := []thread{}
	for y0 := 0; y0 < gh; y0 += step {
		ts << spawn raster_rows(&rc, y0, imin(gh, y0 + step))
	}
	ts.wait()
	return g
}

// RasterCtx - входы raster_rows (общие для потоков; g - каждый пишет свои
// строки)
struct RasterCtx {
	strokes []Stroke // заголовок массива: данные общие, только чтение
	g       &u8 = unsafe { nil }
	cg      &u8 = unsafe { nil } // сетка цветов снимка (color_grid) или nil
	sa      bool // автомаска формы
	gw      int
	gh      int
}

// raster_rows - мазки в строках ry0..ry1 сетки
fn raster_rows(rc &RasterCtx, ry0 int, ry1 int) {
	gw := rc.gw
	gh := rc.gh
	fw := f64(gw)
	fh := f64(gh)
	for st in rc.strokes {
		n := st.pts.len / 2
		if n == 0 || st.radius <= 0 {
			continue
		}
		mut r := f64(st.radius) * fh
		if r < 0.5 {
			r = 0.5
		}
		mut fe := f64(st.feather) / 100
		fe = if fe < 0.02 { 0.02 } else if fe > 1 { 1.0 } else { fe }
		inner := r * (1 - fe)
		flow := if st.flow < 0 { f32(0) } else if st.flow > 1 { f32(1) } else { st.flow }
		if flow <= 0 {
			continue
		}
		// Рамка мазка на сетке, в строках полосы
		mut x0 := fw
		mut y0 := fh
		mut x1 := -1.0
		mut y1 := -1.0
		for k in 0 .. n {
			px := f64(st.pts[2 * k]) * fw
			py := f64(st.pts[2 * k + 1]) * fh
			x0 = math.min(x0, px)
			y0 = math.min(y0, py)
			x1 = math.max(x1, px)
			y1 = math.max(y1, py)
		}
		bx0 := imax(0, int(math.floor(x0 - r)))
		by0 := imax(ry0, int(math.floor(y0 - r)))
		bx1 := imin(gw, int(math.ceil(x1 + r)) + 1)
		by1 := imin(ry1, int(math.ceil(y1 + r)) + 1)
		if bx0 >= bx1 || by0 >= by1 {
			continue
		}
		bw := bx1 - bx0
		r2 := r * r
		// Автомазок: dd - покрытие (максимум по точкам пути: спад кисти ×
		// похожесть клетки на цвет точки); обычный - минимум квадрата
		// расстояния до пути (r² - вне мазка)
		auto := !isnil(rc.cg) && is_auto(st, rc.sa)
		mut dd := bigbuf.new_f32(bw * (by1 - by0))
		if !auto {
			for i in 0 .. dd.len {
				dd[i] = f32(r2)
			}
		}
		last := if n > 1 { n - 1 } else { 1 }
		for k in 0 .. last {
			ax := f64(st.pts[2 * k]) * fw
			ay := f64(st.pts[2 * k + 1]) * fh
			k2 := if n > 1 { k + 1 } else { k }
			bxp := f64(st.pts[2 * k2]) * fw
			byp := f64(st.pts[2 * k2 + 1]) * fh
			sx0 := imax(bx0, int(math.floor(math.min(ax, bxp) - r)))
			sy0 := imax(by0, int(math.floor(math.min(ay, byp) - r)))
			sx1 := imin(bx1, int(math.ceil(math.max(ax, bxp) + r)) + 1)
			sy1 := imin(by1, int(math.ceil(math.max(ay, byp) + r)) + 1)
			dx := bxp - ax
			dy := byp - ay
			l2 := dx * dx + dy * dy
			il2 := if l2 > 0 { 1 / l2 } else { 0.0 }
			if auto {
				auto_segment(rc, st, k, k2, ax, ay, dx, dy, il2, r, inner, sx0, sy0, sx1, sy1,
					bx0, by0, bw, mut dd)
				continue
			}
			for y in sy0 .. sy1 {
				cy := f64(y) + 0.5 - ay
				row := (y - by0) * bw - bx0
				for x in sx0 .. sx1 {
					cx := f64(x) + 0.5 - ax
					mut t := (cx * dx + cy * dy) * il2
					t = if t < 0 { 0.0 } else if t > 1 { 1.0 } else { t }
					ex := cx - t * dx
					ey := cy - t * dy
					d2 := f32(ex * ex + ey * ey)
					if d2 < dd[row + x] {
						dd[row + x] = d2
					}
				}
			}
		}
		// Покрытие и объединение с сеткой
		inner2 := f32(inner * inner)
		fr := f32(r)
		finner := f32(inner)
		for y in by0 .. by1 {
			row := (y - by0) * bw
			for x in bx0 .. bx1 {
				d2 := dd[row + x - bx0]
				c := if auto {
					d2 * flow // покрытие автомазка
				} else if d2 >= f32(r2) {
					f32(0)
				} else if d2 <= inner2 {
					flow
				} else {
					q := (fr - math.sqrtf(d2)) / (fr - finner)
					q * q * (3 - 2 * q) * flow
				}
				if c <= 0 {
					continue
				}
				unsafe {
					gi := y * gw + x
					v := f32(rc.g[gi]) * (1.0 / 255)
					nv := v + c - v * c
					rc.g[gi] = u8(int(nv * 255 + 0.5))
				}
			}
		}
		bigbuf.free(mut dd)
	}
}

// grid_sample - вес кисти в точке сетки (gx, gy) - билинейно, за краем -
// как у края
@[inline]
fn grid_sample(m &LocalShape, gx f32, gy f32) f32 {
	mut fx := gx
	mut fy := gy
	mx := f32(m.gw - 1)
	my := f32(m.gh - 1)
	fx = if fx < 0 { 0 } else if fx > mx { mx } else { fx }
	fy = if fy < 0 { 0 } else if fy > my { my } else { fy }
	x0 := int(fx)
	y0 := int(fy)
	x1 := if x0 + 1 < m.gw { x0 + 1 } else { x0 }
	y1 := if y0 + 1 < m.gh { y0 + 1 } else { y0 }
	tx := fx - f32(x0)
	ty := fy - f32(y0)
	unsafe {
		g := &u8(m.grid.data)
		a := f32(g[y0 * m.gw + x0]) * (1 - tx) + f32(g[y0 * m.gw + x1]) * tx
		b := f32(g[y1 * m.gw + x0]) * (1 - tx) + f32(g[y1 * m.gw + x1]) * tx
		return (a * (1 - ty) + b * ty) * (1.0 / 255)
	}
}

// free_shape - сетки кисти формы (bigbuf)
fn free_shape(sh &LocalShape) {
	if sh.grid.len > 0 {
		mut g := unsafe { sh.grid } // тот же буфер - освобождаем его
		bigbuf.free(mut g)
	}
}

// free_mask - сетки кисти фильтра
fn free_mask(m &LocalMask) {
	free_shape(&m.form)
	for k in 0 .. m.parts.len {
		free_shape(unsafe { &m.parts[k].form })
	}
}

// free_ctx - сетки кисти всех фильтров контекста (после рендера)
fn free_ctx(lc &LocalCtx) {
	for k in 0 .. lc.ms.len {
		free_mask(unsafe { &lc.ms[k] })
	}
}


// ── Автомаска ──
//
// Модель - отпечатки кисти: каждая точка пути красит в своём круге
// клетки, похожие на её цвет (cols); покрытие мазка - максимум по точкам
// (спад кисти × похожесть). Цвет клетки - из сетки цветов снимка
// (color_grid: среднее пикселей буфера под клеткой, log2, шаг 0.04 EV).
// Похожесть - по расстоянию в log2 RGB (среднее по каналам): до auto_t0
// EV - полная, к auto_t1 - ноль. Сравнение с цветом точки, чей круг
// действительно достаёт до клетки, - без дыр и ступенек приближений
// (первые версии: цвет ближайшей точки на пиксель, затем наборы цветов
// на грубой сетке - ступени на IMG_1118)

const auto_t0 = f32(0.25) // EV: до этого расстояния цвет «тот же»
const auto_t1 = f32(0.8) // EV: дальше - другой, не закрашивается
const auto_off = 128 // добавка к сырью перед log2 - шум теней не раздувает разницу
const auto_qk = f32(25) // шагов на EV в сетке цветов (0.04 EV)
const auto_q0 = f32(7) // log2 нижнего края шкалы (0 в сетке - «нет данных»)

// Сырьё u16 -> цвет сетки u8: (log2(x + auto_off) - auto_q0)·auto_qk,
// 1..255 (константа)
const auto_q = build_auto_q()

fn build_auto_q() []u8 {
	mut q := []u8{len: 65536}
	for x in 0 .. 65536 {
		v := int((f32(math.log2(f64(x + auto_off))) - auto_q0) * auto_qk + 0.5)
		q[x] = u8(if v < 1 { 1 } else if v > 255 { 255 } else { v })
	}
	return q
}

// auto_level - цвет точки мазка (сырьё) в шкале сетки цветов (дробно)
@[inline]
fn auto_level(v f32) f32 {
	return (f32(math.log2(f64(v) + auto_off)) - auto_q0) * auto_qk
}

// is_auto - мазок рисуется автомаской: флаг мазка или формы и цвет на
// каждую точку
@[inline]
fn is_auto(st Stroke, shape_auto bool) bool {
	return (st.auto || shape_auto) && st.cols.len == st.pts.len / 2 * 3 && st.pts.len >= 2
}

// auto_segment - отрезок k..k2 автомазка: клетки в рамке (sx0..sx1,
// sy0..sy1) - покрытие max(dd, спад(d) × похожесть клетки на цвет точки
// отрезка, ближайшей к клетке)
fn auto_segment(rc &RasterCtx, st Stroke, k int, k2 int, ax f64, ay f64, dx f64, dy f64, il2 f64, r f64, inner f64, sx0 int, sy0 int, sx1 int, sy1 int, bx0 int, by0 int, bw int, mut dd []f32) {
	mut ca := [3]f32{}
	mut cb := [3]f32{}
	for c in 0 .. 3 {
		ca[c] = auto_level(st.cols[3 * k + c])
		cb[c] = auto_level(st.cols[3 * k2 + c])
	}
	r2 := r * r
	t0 := auto_t0 * auto_qk
	t1 := auto_t1 * auto_qk
	gw := rc.gw
	for y in sy0 .. sy1 {
		cy := f64(y) + 0.5 - ay
		row := (y - by0) * bw - bx0
		for x in sx0 .. sx1 {
			cx := f64(x) + 0.5 - ax
			mut t := (cx * dx + cy * dy) * il2
			t = if t < 0 { 0.0 } else if t > 1 { 1.0 } else { t }
			ex := cx - t * dx
			ey := cy - t * dy
			d2 := ex * ex + ey * ey
			if d2 >= r2 || dd[row + x] >= 1 {
				continue // вне круга или клетка уже закрашена полностью
			}
			unsafe {
				q := rc.cg + (y * gw + x) * 3
				if q[0] == 0 {
					continue // клетка вне снимка
				}
				ft := f32(t)
				e0 := f32(q[0]) - (ca[0] + (cb[0] - ca[0]) * ft)
				e1 := f32(q[1]) - (ca[1] + (cb[1] - ca[1]) * ft)
				e2 := f32(q[2]) - (ca[2] + (cb[2] - ca[2]) * ft)
				dc2 := (e0 * e0 + e1 * e1 + e2 * e2) * (1.0 / 3)
				if dc2 >= t1 * t1 {
					continue
				}
				// Корни - только в переходах (похожести и мягкого края)
				sim := if dc2 <= t0 * t0 {
					f32(1)
				} else {
					1 - smooth01((math.sqrtf(dc2) - t0) / (t1 - t0))
				}
				cov := if d2 <= inner * inner {
					f32(1)
				} else {
					s := f32((r - math.sqrt(d2)) / (r - inner))
					s * s * (3 - 2 * s)
				}
				v := cov * sim
				if v > dd[row + x] {
					dd[row + x] = v
				}
			}
		}
	}
}

// color_grid - сетка цветов снимка img под сетку кисти gw x gh (по 3 байта
// на клетку, шкала auto_q; 0 - нет данных) в рамке автомазков: цвет клетки
// - среднее пикселей буфера под ней (отображение кадра в буфер - обратное
// к mm). Полосами строк в потоках
fn color_grid(img &ImgRef, mm MaskMap, gw int, gh int, autos []Stroke) []u8 {
	mut cg := bigbuf.new_u8(gw * gh * 3)
	// Рамка автомазков (клетки сетки)
	mut x0 := gw
	mut y0 := gh
	mut x1 := 0
	mut y1 := 0
	for st in autos {
		r := int(math.ceil(f64(st.radius) * gh)) + 1
		for k in 0 .. st.pts.len / 2 {
			px := int(f64(st.pts[2 * k]) * gw)
			py := int(f64(st.pts[2 * k + 1]) * gh)
			x0 = imin(x0, px - r)
			y0 = imin(y0, py - r)
			x1 = imax(x1, px + r + 1)
			y1 = imax(y1, py + r + 1)
		}
	}
	x0 = imax(0, x0)
	y0 = imax(0, y0)
	x1 = imin(gw, x1)
	y1 = imin(gh, y1)
	det := mm.a * mm.e - mm.b * mm.d
	if x0 >= x1 || y0 >= y1 || math.abs(det) < 1e-18 {
		return cg
	}
	// Клетка в пикселях буфера: пикселей на единицу кадра - 1/sqrt|det|
	cell_px := 1.0 / (f64(gh) * math.sqrt(math.abs(det)))
	mut rb := int(cell_px / 2 + 0.5)
	rb = if rb < 1 { 1 } else if rb > 4 { 4 } else { rb }
	cc := ColorCtx{
		img: unsafe { img }
		mm:  mm
		det: det
		gw:  gw
		gh:  gh
		x0:  x0
		x1:  x1
		rb:  rb
		cg:  unsafe { &u8(cg.data) }
	}
	nt := bands(x1 - x0, y1 - y0)
	if nt <= 1 {
		color_rows(&cc, y0, y1)
		return cg
	}
	step := (y1 - y0 + nt - 1) / nt
	mut ts := []thread{}
	for ya := y0; ya < y1; ya += step {
		ts << spawn color_rows(&cc, ya, imin(y1, ya + step))
	}
	ts.wait()
	return cg
}

// ColorCtx - входы color_rows (общие для потоков; cg - каждый пишет свои
// строки)
struct ColorCtx {
	img &ImgRef = unsafe { nil }
	mm  MaskMap
	det f64
	gw  int
	gh  int
	x0  int
	x1  int
	rb  int // полуширина окна усреднения, пиксели буфера
	cg  &u8 = unsafe { nil }
}

// color_rows - цвета клеток строк y0..y1 сетки (столбцы x0..x1)
fn color_rows(c &ColorCtx, y0 int, y1 int) {
	mm := c.mm
	w := c.img.w
	h := c.img.h
	rb := c.rb
	for gy in y0 .. y1 {
		ym := (f64(gy) + 0.5) / f64(c.gh) - mm.f
		for gx in c.x0 .. c.x1 {
			xm := (f64(gx) + 0.5) / f64(c.gw) * mm.ar - mm.c
			// Пиксель буфера: обратное к X = a·i + b·j + c, Y = d·i + e·j + f
			pi := int(math.round((mm.e * xm - mm.b * ym) / c.det))
			pj := int(math.round((-mm.d * xm + mm.a * ym) / c.det))
			if pi < 0 || pj < 0 || pi >= w || pj >= h {
				continue
			}
			mut s0 := 0
			mut s1 := 0
			mut s2 := 0
			mut n := 0
			for j in imax(0, pj - rb) .. imin(h, pj + rb + 1) {
				unsafe {
					mut q := c.img.src + (j * w + imax(0, pi - rb)) * 3
					for _ in imax(0, pi - rb) .. imin(w, pi + rb + 1) {
						s0 += int(q[0])
						s1 += int(q[1])
						s2 += int(q[2])
						n++
						q += 3
					}
				}
			}
			unsafe {
				o := c.cg + (gy * c.gw + gx) * 3
				o[0] = auto_q[s0 / n]
				o[1] = auto_q[s1 / n]
				o[2] = auto_q[s2 / n]
			}
		}
	}
}

// ── Расширить / сузить ──
//
// Вес всей формы фильтра (основа с частями) растеризуется в сетку кадра
// (та же, что у кисти: доли кадра S, поэтому превью, 1:1 и экспорт
// совпадают), затем сетка расширяется (максимум по окрестности) или
// сужается (минимум). Окрестность - правильный восьмиугольник (почти
// круг): сумма отрезков по горизонтали и вертикали (полудлина h) и по
// двум диагоналям (d шагов), h = √2·d, радиус h + 2d. Каждый отрезок -
// проход van Herk / Gil-Werman: O(1) на клетку при любом радиусе. Мягкий
// край сдвигается целиком, с той же шириной перехода. За краем кадра -
// нейтраль (сужение не съедает маску у края кадра).

// grow_max - сдвиг края при ±100, доля высоты кадра
const grow_max = 0.1

// grow_cells - сдвиг края в клетках сетки высотой gh (не меньше 1)
fn grow_cells(grow f32, gh int) int {
	g := f64(grow) / 100
	r := int(grow_max * g * g * f64(gh) + 0.5)
	return if r < 1 { 1 } else { r }
}

// grow_shape - форма lm (основа с частями), расширенная (grow > 0) или
// суженная, сеткой кадра; сетки исходных форм освобождаются
fn grow_shape(lm LocalMask, mm MaskMap, grow f32) LocalShape {
	gw, gh := brush_dims(mm.ar)
	mut g := bigbuf.new_u8(gw * gh)
	// Клетка (gx, gy) -> пиксель буфера: кадр X = (gx + 0.5)·ar / gw,
	// Y = (gy + 0.5) / gh, пиксель - обратное к mm (аффинное)
	det := mm.a * mm.e - mm.b * mm.d
	if math.abs(det) < 1e-18 {
		free_mask(&lm)
		return grid_shape(g, gw, gh, mm)
	}
	sx := mm.ar / f64(gw)
	sy := 1.0 / f64(gh)
	// x = (e·(X - c) - b·(Y - f)) / det, y = (-d·(X - c) + a·(Y - f)) / det
	xc0 := 0.5 * sx - mm.c
	yc0 := 0.5 * sy - mm.f
	rc := GrowCtx{
		m:  &lm
		g:  unsafe { &u8(g.data) }
		gw: gw
		xa: f32(mm.e * sx / det)
		xb: f32(-mm.b * sy / det)
		xc: f32((mm.e * xc0 - mm.b * yc0) / det)
		ya: f32(-mm.d * sx / det)
		yb: f32(mm.a * sy / det)
		yc: f32((-mm.d * xc0 + mm.a * yc0) / det)
	}
	nt := bands(gw, gh)
	step := (gh + nt - 1) / nt
	mut ts := []thread{}
	for y0 := 0; y0 < gh; y0 += step {
		ts << spawn grow_raster(&rc, y0, imin(gh, y0 + step))
	}
	ts.wait()
	free_mask(&lm)
	r := grow_cells(if grow < 0 { -grow } else { grow }, gh)
	d := int(f64(r) / (2 + math.sqrt2) + 0.5)
	h := r - 2 * d
	mx := grow > 0
	mut tmp := bigbuf.new_u8(gw * gh)
	// Проходы попеременно g -> tmp и tmp -> g; in_g - результат в g
	mut in_g := true
	for dir in 0 .. 4 {
		k := if dir < 2 { h } else { d }
		if k <= 0 {
			continue
		}
		pg := unsafe { &u8(g.data) }
		pt := unsafe { &u8(tmp.data) }
		if in_g {
			morph_dir(pg, pt, gw, gh, dir, k, mx)
		} else {
			morph_dir(pt, pg, gw, gh, dir, k, mx)
		}
		in_g = !in_g
	}
	if in_g {
		bigbuf.free(mut tmp)
		return grid_shape(g, gw, gh, mm)
	}
	bigbuf.free(mut g)
	return grid_shape(tmp, gw, gh, mm)
}

// GrowCtx - растеризация веса формы в сетку (общий для потоков, строки -
// свои у каждого)
struct GrowCtx {
	m  &LocalMask = unsafe { nil }
	g  &u8        = unsafe { nil }
	gw int
	xa f32 // клетка -> пиксель буфера: x = xa·gx + xb·gy + xc
	xb f32
	xc f32
	ya f32
	yb f32
	yc f32
}

fn grow_raster(rc &GrowCtx, y0 int, y1 int) {
	for gy in y0 .. y1 {
		row := gy * rc.gw
		for gx in 0 .. rc.gw {
			x := rc.xa * f32(gx) + rc.xb * f32(gy) + rc.xc
			y := rc.ya * f32(gx) + rc.yb * f32(gy) + rc.yc
			w := mask_weight(rc.m, x, y)
			unsafe {
				rc.g[row + gx] = u8(int(w * 255 + 0.5))
			}
		}
	}
}

// line_count - число линий направления dir (0 - строки, 1 - столбцы,
// 2 - диагонали вниз-вправо, 3 - вниз-влево) сетки w x h
fn line_count(dir int, w int, h int) int {
	return match dir {
		0 { h }
		1 { w }
		else { w + h - 1 }
	}
}

// line_of - линия l направления dir: первая клетка, шаг, длина
fn line_of(dir int, l int, w int, h int) (int, int, int) {
	match dir {
		0 {
			return l * w, 1, w
		}
		1 {
			return l, w, h
		}
		2 {
			// Начала: верхняя строка (x = l), затем левый столбец
			x, y := if l < w { l, 0 } else { 0, l - w + 1 }
			return y * w + x, w + 1, imin(w - x, h - y)
		}
		else {
			// Начала: верхняя строка (x = l), затем правый столбец
			x, y := if l < w { l, 0 } else { w - 1, l - w + 1 }
			return y * w + x, w - 1, imin(x + 1, h - y)
		}
	}
}

// morph_dir - максимум (mx) или минимум по отрезку ±k клеток вдоль линий
// направления dir: src -> dst
fn morph_dir(src &u8, dst &u8, w int, h int, dir int, k int, mx bool) {
	n := line_count(dir, w, h)
	nt := bands(w, h)
	if nt <= 1 {
		morph_lines(src, dst, w, h, dir, k, mx, 0, n)
		return
	}
	step := (n + nt - 1) / nt
	mut ts := []thread{}
	for l0 := 0; l0 < n; l0 += step {
		ts << spawn morph_lines(src, dst, w, h, dir, k, mx, l0, imin(n, l0 + step))
	}
	ts.wait()
}

// morph_lines - линии l0..l1 (van Herk / Gil-Werman): линия, дополненная k
// нейтральными с краёв, режется на блоки по 2k + 1; в блоке - накопленный
// экстремум слева направо (f) и справа налево (b); экстремум окна с
// началом i - op(b[i], f[i + 2k])
fn morph_lines(src &u8, dst &u8, w int, h int, dir int, k int, mx bool, l0 int, l1 int) {
	ww := 2 * k + 1
	cap := imax(w, h) + 2 * k + ww
	neutral := if mx { u8(0) } else { u8(255) }
	mut e := []u8{len: cap}
	mut f := []u8{len: cap}
	mut b := []u8{len: cap}
	for l in l0 .. l1 {
		start, st, n := line_of(dir, l, w, h)
		// Дополненная линия длиной m (кратно ww)
		m := ((n + 2 * k + ww - 1) / ww) * ww
		for i in 0 .. m {
			j := i - k
			e[i] = if j >= 0 && j < n { unsafe { src[start + j * st] } } else { neutral }
		}
		for b0 := 0; b0 < m; b0 += ww {
			f[b0] = e[b0]
			for i in b0 + 1 .. b0 + ww {
				f[i] = if mx { u8_max(f[i - 1], e[i]) } else { u8_min(f[i - 1], e[i]) }
			}
			b[b0 + ww - 1] = e[b0 + ww - 1]
			for i := b0 + ww - 2; i >= b0; i-- {
				b[i] = if mx { u8_max(b[i + 1], e[i]) } else { u8_min(b[i + 1], e[i]) }
			}
		}
		for i in 0 .. n {
			v := if mx { u8_max(b[i], f[i + 2 * k]) } else { u8_min(b[i], f[i + 2 * k]) }
			unsafe {
				dst[start + i * st] = v
			}
		}
	}
}

@[inline]
fn u8_max(a u8, b u8) u8 {
	return if a > b { a } else { b }
}

@[inline]
fn u8_min(a u8, b u8) u8 {
	return if a < b { a } else { b }
}
