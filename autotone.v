module main

import pipeline

// Автотон: одна кнопка подбирает экспозицию, контраст, «Тени/Света» и
// чёрные/белые эквалайзера по гистограмме кадра.
//
// Подбор идёт по РЕЗУЛЬТАТУ, а не по сырью: выборка пикселей превью
// (~at_samples) прогоняется настоящим пайплайном (pipeline.apply - с
// камерной кривой, ББ и кривыми кадра, но с нейтральным цветом), и каждый параметр
// подбирается делением пополам, пока нужный перцентиль люмы результата не
// встанет на цель. Порядок - как у Lightroom: экспозиция (медиана к
// среднему серому, но не выше потолка по светам), контраст, света, тени,
// снова экспозиция (тени/света сдвигают середину), белые, чёрные.
// Пиксели, клипнутые уже в сырье, в оценке светов не участвуют: их не
// вытянуть, а приглушение сделало бы белое серым.

// ToneSet - подобранные значения (то, что автотон пишет в Params)
struct ToneSet {
	exposure      f32
	contrast      f32
	sh_shadows    f32
	sh_highlights f32
	blacks        f32 // eq[0], EV
	whites        f32 // eq[4], EV
}

// put записывает подобранное в параметры. Остальные тоновые ручки
// («Тени» с попиксельной маской, средние узлы эквалайзера) обнуляются:
// автотон задаёт основу тона целиком, как «Авто» в Lightroom.
fn (t ToneSet) put(base pipeline.Params) pipeline.Params {
	mut p := base
	p.exposure = t.exposure
	p.contrast = t.contrast
	p.shadows = 0
	p.sh_shadows = t.sh_shadows
	p.sh_highlights = t.sh_highlights
	p.eq = [t.blacks, f32(0), 0, 0, t.whites]!
	return p
}

const at_samples = 60000 // пикселей выборки: ~5 мс на прогон пайплайна
const at_iters = 11 // шагов деления пополам на параметр
const at_clip = u16(0.98 * 65535) // канал сырья у предела - пиксель клипнут
const at_mid = f32(118) // медиана люмы: средний серый (18% ≈ 0.46 после гаммы)
const at_spread = f32(60) // p75 - p25: меньше - кадр блёклый, нужен контраст
const at_hi = f32(240) // p99.5 каналов нетронутых светов выше - приглушать света
const at_lo = f32(22) // p10 ниже - поднимать тени
const at_sh_max = f32(60) // тени «Тени/Света» - не больше
const at_cap = f32(250) // p99 каналов нетронутых светов - потолок экспозиции
const at_cap_hl = f32(50) // ... при таком приглушении светов
const at_white = f32(246) // p99.9 каналов нетронутых светов - белая точка
const at_black = f32(5) // p0.2 - чёрная точка

// ToneProbe - выборка кадра и буфер результата для пробных прогонов
struct ToneProbe {
	src  []u16 // выборка сырья, плотный RGB
	mask []u16 // та же выборка размытой люмы; пусто - без «Тени/Света»
	clip []bool
	n    int
	nu   int // пикселей без клипа в сырье
mut:
	out []u8
	all [256]u32 // гистограмма люмы результата - все пиксели
	// Максимум из каналов, только не клипнутые в сырье: света меряются
	// по каналу, а не по люме - синий неба упирается в 255 раньше люмы
	unc [256]u32
}

fn new_probe(src []u16, mask []u16, npix int) ToneProbe {
	step := if npix > at_samples { npix / at_samples } else { 1 }
	n := npix / step
	mut s := []u16{len: n * 3}
	mut m := []u16{len: if mask.len == npix * pipeline.mask_ch { n * pipeline.mask_ch } else { 0 }}
	mut c := []bool{len: n}
	mut nu := 0
	for i in 0 .. n {
		j := i * step
		r, g, b := src[j * 3], src[j * 3 + 1], src[j * 3 + 2]
		s[i * 3], s[i * 3 + 1], s[i * 3 + 2] = r, g, b
		if m.len > 0 {
			for k in 0 .. pipeline.mask_ch {
				m[i * pipeline.mask_ch + k] = mask[j * pipeline.mask_ch + k]
			}
		}
		c[i] = r >= at_clip || g >= at_clip || b >= at_clip
		if !c[i] {
			nu++
		}
	}
	return ToneProbe{
		src:  s
		mask: m
		clip: c
		n:    n
		nu:   nu
		out:  []u8{len: n * 3}
	}
}

// run прогоняет выборку с параметрами p и строит гистограммы
fn (mut pr ToneProbe) run(p pipeline.Params) {
	mask := if pr.mask.len > 0 { unsafe { &u16(pr.mask.data) } } else { unsafe { &u16(nil) } }
	pipeline.apply(unsafe { &u16(pr.src.data) }, mask, pr.n, p, mut pr.out, 3)
	pr.all = [256]u32{}
	pr.unc = [256]u32{}
	for i in 0 .. pr.n {
		r, g, b := pr.out[i * 3], pr.out[i * 3 + 1], pr.out[i * 3 + 2]
		pr.all[(54 * u32(r) + 183 * u32(g) + 19 * u32(b)) >> 8]++
		if !pr.clip[i] {
			mut mx := if r > g { r } else { g }
			if b > mx {
				mx = b
			}
			pr.unc[mx]++
		}
	}
}

// hist_pct - перцентиль q (0..1) гистограммы, с долей внутри корзины (гладко
// для деления пополам)
fn hist_pct(h [256]u32, total int, q f32) f32 {
	if total == 0 {
		return 0
	}
	want := f64(q) * f64(total)
	mut acc := f64(0)
	for i in 0 .. 256 {
		c := f64(h[i])
		if c > 0 && acc + c >= want {
			return f32(i) + f32((want - acc) / c)
		}
		acc += c
	}
	return 255
}

enum Knob {
	exposure
	contrast
	sh_shadows
	sh_highlights
	blacks
	whites
}

fn with_knob(base pipeline.Params, k Knob, v f32) pipeline.Params {
	mut p := base
	match k {
		.exposure { p.exposure = v }
		.contrast { p.contrast = v }
		.sh_shadows { p.sh_shadows = v }
		.sh_highlights { p.sh_highlights = v }
		.blacks { p.eq[0] = v }
		.whites { p.eq[4] = v }
	}
	return p
}

// Metric - что меряем: перцентиль q2 (минус перцентиль q1, если q1 >= 0 -
// разброс) люмы всех пикселей или (unc) максимума каналов не клипнутых в
// сырье - для светов
struct Metric {
	q1  f32 = -1
	q2  f32
	unc bool
}

fn (mut pr ToneProbe) measure(p pipeline.Params, m Metric) f32 {
	pr.run(p)
	h := if m.unc { pr.unc } else { pr.all }
	total := if m.unc { pr.nu } else { pr.n }
	v := hist_pct(h, total, m.q2)
	return if m.q1 >= 0 { v - hist_pct(h, total, m.q1) } else { v }
}

// solve ищет значение ручки k в [lo, hi], при котором метрика равна
// target (метрика монотонна по ручке, направление - по концам). Цель вне
// досягаемого - ближайший конец.
fn (mut pr ToneProbe) solve(base pipeline.Params, k Knob, lo f32, hi f32, m Metric, target f32) f32 {
	mut p := base
	p = with_knob(p, k, lo)
	vlo := pr.measure(p, m)
	p = with_knob(p, k, hi)
	vhi := pr.measure(p, m)
	up := vhi >= vlo
	if (up && target <= vlo) || (!up && target >= vlo) {
		return lo
	}
	if (up && target >= vhi) || (!up && target <= vhi) {
		return hi
	}
	mut a, mut b := lo, hi
	for _ in 0 .. at_iters {
		c := (a + b) / 2
		p = with_knob(p, k, c)
		v := pr.measure(p, m)
		if (v < target) == up {
			a = c
		} else {
			b = c
		}
	}
	return (a + b) / 2
}

fn round_to(v f32, step f32) f32 {
	return f32(int(v / step + (if v >= 0 { f32(0.5) } else { f32(-0.5) }))) * step
}

// auto_tone подбирает тон по кадру: src - линейное сырьё (плотный RGB,
// npix пикселей), mask - его размытая люма («Тени/Света»; другой длины -
// без них), base - текущие параметры кадра (кривая, ББ, цвет остаются).
fn auto_tone(src []u16, mask []u16, npix int, base pipeline.Params) ToneSet {
	if npix == 0 || src.len < npix * 3 {
		return ToneSet{}
	}
	mut pr := new_probe(src, mask, npix)
	mut p := base
	p.dither = false
	p.masks = []pipeline.Mask{} // градиентные фильтры - не основа тона
	// Цвет - нейтральный: насыщенность «как JPEG» и таблица оттенков
	// раздувают каналы (синий неба IMG_0817 упирался в 255 при любом тоне),
	// а тоном это не исправить. Цвет кадра в итог не входит (ToneSet.put).
	p.saturation = 1
	p.cam_sat = 1
	p.cam_hue = []f32{}
	p.cam_hsat = []f32{}
	p.vibrance = 0
	p.hsl_hue = [8]f32{}
	p.hsl_sat = [8]f32{}
	p.hsl_lum = [8]f32{}
	p.grade = pipeline.Grade{}
	p.bw = false
	p.style = pipeline.Style{
		contrast: base.style.contrast // тон стиля - в основе, цвет - нет
	}
	p.bw_mix = [8]f32{}
	p = ToneSet{}.put(p)
	// Света и белые - только если есть что мерить без клипа
	hi_ok := pr.nu * 100 >= pr.n
	has_sh := pr.mask.len > 0
	med := Metric{
		q2: 0.5
	}
	e_mid := pr.solve(p, .exposure, -4, 4, med, at_mid)
	// Потолок экспозиции: верхний 1% нетронутых светов - не выше at_cap
	// при умеренном приглушении светов. Иначе на контровом свете (тёмная
	// комната и яркое окно, IMG_0634: медиана 40 при 0 EV) медиана
	// потребовала бы +4 EV и выжгла полкадра; недостающую середину
	// добирают тени «Тени/Света» - они локальные, контраст остаётся.
	mut e_cap := f32(4)
	if hi_ok {
		top := Metric{
			q2:  0.99
			unc: true
		}
		mut pc := p
		if has_sh {
			pc.sh_highlights = at_cap_hl
		}
		e_cap = pr.solve(pc, .exposure, -4, 4, top, at_cap)
	}
	p.exposure = if e_mid < e_cap { e_mid } else { e_cap }
	spread := Metric{
		q1: 0.25
		q2: 0.75
	}
	if pr.measure(p, spread) < at_spread {
		p.contrast = pr.solve(p, .contrast, 0, 0.5, spread, at_spread)
	}
	if has_sh {
		hi := Metric{
			q2:  0.995
			unc: true
		}
		if hi_ok && pr.measure(p, hi) > at_hi {
			p.sh_highlights = pr.solve(p, .sh_highlights, 0, 80, hi, at_hi)
		}
		// Тени: глубокие тени (p10) - до at_lo; середина ниже среднего
		// серого (экспозиция упёрлась в потолок) - до него, сколько дадут
		lo := Metric{
			q2: 0.10
		}
		mut sh := f32(0)
		if pr.measure(p, lo) < at_lo {
			sh = pr.solve(p, .sh_shadows, 0, at_sh_max, lo, at_lo)
		}
		if pr.measure(p, med) < at_mid - 4 {
			s2 := pr.solve(p, .sh_shadows, 0, at_sh_max, med, at_mid)
			if s2 > sh {
				sh = s2
			}
		}
		p.sh_shadows = sh
		// Тени и света сдвинули середину - экспозиция ещё раз, не выше потолка
		e2 := pr.solve(p, .exposure, -4, 4, med, at_mid)
		p.exposure = if e2 < e_cap { e2 } else { e_cap }
	}
	if hi_ok {
		white := Metric{
			q2:  0.999
			unc: true
		}
		w := pr.measure(p, white)
		if w < at_white - 6 || w > at_white + 6 {
			p.eq[4] = pr.solve(p, .whites, -1.5, 1.5, white, at_white)
		}
	}
	black := Metric{
		q2: 0.002
	}
	if pr.measure(p, black) > at_black + 8 {
		p.eq[0] = pr.solve(p, .blacks, -1, 0, black, at_black)
	}
	return ToneSet{
		exposure:      round_to(p.exposure, 0.01)
		contrast:      round_to(p.contrast, 0.01)
		sh_shadows:    round_to(p.sh_shadows, 1)
		sh_highlights: round_to(p.sh_highlights, 1)
		blacks:        round_to(p.eq[0], 0.01)
		whites:        round_to(p.eq[4], 0.01)
	}
}
