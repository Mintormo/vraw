module main

// Настоящий 1:1 в окне: при масштабе больше 50% (пиксель превью half-size
// крупнее пикселя экрана) поверх холста показывается фрагмент полного
// кадра - слой детализации vgui.Canvas (set_detail). Расчёт - detail.v.
//
// Как устроено:
// - detail_watch (из on_overlay холста, на каждую отрисовку) сверяет
//   масштаб и видимую часть с прошлой отрисовкой; изменилось - detail_check
//   через app.post (не посреди draw).
// - detail_check: не нужен (вписан, режим кадрирования, показ дымки, JPEG
//   камеры) - слои сняты; готовые фрагменты покрывают видимое и посчитаны
//   по тем же настройкам подготовки - показать; иначе - фоновый расчёт
//   недостающего (один за раз; запрос во время работы - ещё проход после).
// - Фрагментов два (сторона DetailSide): «после» - нынешние настройки,
//   «до» - запись «до» сравнения (compare.v: удержание «\», шторка, бок о
//   бок). У «до» своя подготовка сырья (объектив, шумодав, Capture,
//   AI) и свой тон; геометрия - нынешняя. В шторке слой - оба
//   фрагмента, сшитые по линии; бок о бок - «до» на своём холсте.
// - Полный кадр LibRaw (~0.6 с) и объектив кадра грузятся ЛЕНИВО - при
//   первом увеличении - и живут до смены кадра (~150 МБ вне сборщика:
//   detail_free отдаёт их системе). Полный кадр - один, общий у «после»
//   и «до».
// - Тональные ползунки (apply_pipeline) перерисовывают готовые фрагменты
//   сразу (detail_show, ~10-30 мс); шумодав, объектив, резкость, геометрия
//   меняют ключ подготовки - фрагмент пересчитывается в фоне, до этого виден
//   прежний.
// Запрос - в долях видимой части превью: размер полного кадра воркер узнаёт
// сам (у превью half-size нечётный край обрезан).
// - AI-шумодав (если он есть в превью): кнопка AI считает модель сразу по
//   ПОЛНОМУ кадру после объектива (ai_nr.v, st.ai_full) - фрагмент берёт
//   из него свой кусок, ничего не досчитывая, и совпадает с экспортом.
import math
import vgui
import lens
import pipeline { Region }

// Запас вокруг видимой части, в долях её размера: прокрутка на четверть
// экрана - без пересчёта
const detail_pad = f32(0.25)
// Детализация - когда пиксель превью крупнее пикселя экрана
const detail_min_scale = f32(1.01)
// Настоящие 100%: пиксель полного кадра на пиксель экрана - зум холста
// превью 1 / preview_scale
const zoom_one = f32(1.0) / preview_scale
// Полных кадров LibRaw в памяти (~150 МБ): один - открытого кадра, общий
// у «после» и «до»
const detail_srcs_max = 1

// Стороны фрагмента: 0 - «после», 1 - «до»
const side_after = 0
const side_before = 1

// DetailFrag - готовый фрагмент: сырьё lin прямоугольника r выхода ow x oh,
// ключ подготовки key, кадр gen
struct DetailFrag {
mut:
	lin []u16
	r   Region
	ow  int
	oh  int
	key string
	gen int
}

@[heap]
struct DetailCtl {
mut:
	srcs     []&DetailSrc // полные кадры (src_key - путь)
	lens     &DetailLens = unsafe { nil }
	lens_key string // кадр, сила виньетки и увеличение lens
	running  bool
	pending  bool // запрос во время работы - ещё проход после
	drop     bool // кадр сменился во время работы - src и lens выбросить
	threads  []thread
	run_key  string     // ключ подготовки идущего расчёта (со стороной)
	run_frac DetailFrac // его видимая часть с запасом
	frag      [2]DetailFrag
	// Шторка на 1:1: последние картинки «после» и «до» (RGBA фрагмента) -
	// линию двигают без финального прохода
	split_a []u8
	split_b []u8
	// Последний увиденный вид холста (detail_watch)
	seen string
}

// DetailFrac - видимая часть превью в долях кадра (после кадрирования)
struct DetailFrac {
	x0 f32
	y0 f32
	x1 f32
	y1 f32
}

// DetailPrep - подготовка сырья фрагмента одной стороны
struct DetailPrep {
	use_lens  bool
	man       lens.Manual // ручная коррекция объектива
	nr        [4]f32
	dc        pipeline.Sharpen
	ai_s      f32 // 0 - без AI
	spots     []pipeline.Spot // удаление пятен (после подготовки, до геометрии)
}

// detail_prep_of - подготовка стороны: «после» - нынешние настройки (AI -
// как в превью: сила, если результат модели готов), «до» - запись «до»
fn detail_prep_of(st &State, side int) DetailPrep {
	if side == side_before && st.history.len > 0 {
		b := ba_state(st)
		return DetailPrep{
			use_lens:  b.lens_corr && !isnil(st.corr)
			man:       b.lman
			nr:        b.nr
			dc:        b.params.sharp
			ai_s:      ba_ai(st, b)
			spots:     b.spots
		}
	}
	return DetailPrep{
		use_lens:  st.edit.lens_corr && !isnil(st.corr)
		man:       st.edit.lman
		nr:        st.edit.nr
		dc:        st.edit.params.sharp
		ai_s:      ai_effective(st)
		spots:     st.edit.spots
	}
}

// DetailReq - снимок для фонового расчёта (без State и vgui)
struct DetailReq {
	gen       int
	side      int
	path      string
	src_key   string
	lens_key  string
	prep      DetailPrep
	corr      &lens.Corrector = unsafe { nil }
	vign      f32
	zoom      f32 = 1
	src       &DetailSrc  = unsafe { nil } // готовый (тот же src_key) или nil
	lens      &DetailLens = unsafe { nil } // готовый (тот же lens_key) или nil
	frac      DetailFrac
	region    Region // задан (w > 0) - считать ровно его, а не frac с запасом
	geom      pipeline.Geom
	key       string
	// AI: результат модели по полному кадру (своя ссылка, bufown.v -
	// воркер отпускает; пусто - без AI)
	ai_full []u16
	ai_fw   int
	ai_fh   int
}

struct DetailRes {
	req DetailReq
mut:
	src       &DetailSrc    = unsafe { nil }
	lens      &DetailLens   = unsafe { nil }
	lin       []u16
	r         Region
	ow        int
	oh        int
	err       string
}

// detail_prep_key - настройки, от которых зависит сырьё фрагмента стороны
fn detail_prep_key(st &State, side int) string {
	g := out_geom(&st.edit)
	p := detail_prep_of(st, side)
	return '${st.file_gen}|${p.use_lens}|${p.man.key()}|${st.look.vign}|${st.look.zoom}|${p.nr}|${dc_key(p.dc)}|${g}|${p.ai_s}|${if p.ai_s > 0 {
		st.ai_raw_gen
	} else {
		0
	}}|${pipeline.spot_key(p.spots)}'
}

// detail_wanted - нужен ли слой детализации сейчас
fn detail_wanted(st &State) bool {
	if isnil(st.cv) || isnil(st.dt) || st.loading || st.raw_path == '' || st.glin.len == 0 {
		return false
	}
	// Режим кадрирования - весь повёрнутый кадр; дымка и резкость
	// показываются картой
	if st.crop_mode || st.haze_show || st.dust_show || jpeg_active(st) {
		return false
	}
	cv := st.cv
	return !cv.auto_fit && cv.screen_scale() > detail_min_scale
}

// detail_sides - какие фрагменты сейчас видны (первым - тот, что важнее
// показать раньше)
fn detail_sides(st &State) []int {
	if !ba_active(st) {
		return [side_after]
	}
	if st.ba_hold {
		return [side_before]
	}
	return [side_after, side_before]
}

// detail_frac - видимая часть холста в долях буфера
fn detail_frac(st &State) DetailFrac {
	cv := st.cv
	v := cv.visible_buf_rect()
	if v.w <= 0 || cv.width <= 0 || cv.height <= 0 {
		return DetailFrac{}
	}
	return DetailFrac{v.x / f32(cv.width), v.y / f32(cv.height), (v.x + v.w) / f32(cv.width), (
		v.y + v.h) / f32(cv.height)}
}

// frac_region - доли кадра -> пиксели выхода ow x oh, с запасом pad (доля
// размера) по сторонам, в пределах кадра
fn frac_region(f DetailFrac, ow int, oh int, pad f32) Region {
	mx := (f.x1 - f.x0) * pad
	my := (f.y1 - f.y0) * pad
	x0 := int(math.floor(f64((f.x0 - mx) * f32(ow))))
	y0 := int(math.floor(f64((f.y0 - my) * f32(oh))))
	x1 := int(math.ceil(f64((f.x1 + mx) * f32(ow))))
	y1 := int(math.ceil(f64((f.y1 + my) * f32(oh))))
	cx0 := if x0 < 0 { 0 } else { x0 }
	cy0 := if y0 < 0 { 0 } else { y0 }
	cx1 := if x1 > ow { ow } else { x1 }
	cy1 := if y1 > oh { oh } else { y1 }
	return Region{cx0, cy0, cx1 - cx0, cy1 - cy0}
}

// frac_contains - часть a (с запасом pad) накрывает часть b
fn frac_contains(a DetailFrac, pad f32, b DetailFrac) bool {
	mx := (a.x1 - a.x0) * pad
	my := (a.y1 - a.y0) * pad
	return b.x0 >= a.x0 - mx && b.y0 >= a.y0 - my && b.x1 <= a.x1 + mx && b.y1 <= a.y1 + my
}

// detail_watch - из on_overlay холста: вид (масштаб, видимая часть)
// изменился - проверка после отрисовки
fn detail_watch(mut st State) {
	if isnil(st.dt) || isnil(st.cv) || isnil(st.app) {
		return
	}
	cv := st.cv
	v := cv.visible_buf_rect()
	seen := '${cv.auto_fit}|${cv.screen_scale()}|${v}'
	mut dt := st.dt
	if seen == dt.seen {
		return
	}
	dt.seen = seen
	mut app := st.app
	app.post(st.dt_check)
}

// frag_ready - фрагмент стороны покрывает видимое и посчитан по нынешним
// настройкам; в шторке «до» ещё и совпадает по месту с «после» (сшиваются)
fn frag_ready(st &State, side int, f DetailFrac) bool {
	dt := st.dt
	fr := dt.frag[side]
	if fr.lin.len == 0 || fr.gen != st.file_gen || fr.ow <= 0 {
		return false
	}
	if fr.key != detail_prep_key(st, side) || !fr.r.contains(frac_region(f, fr.ow, fr.oh, 0)) {
		return false
	}
	if side == side_before && st.ba_split && !st.ba_hold {
		return fr.r == dt.frag[side_after].r
	}
	return true
}

// clear_details - снять слои детализации с обоих холстов
fn clear_details(mut st State) {
	mut cv := st.cv
	if cv.has_detail() {
		cv.clear_detail()
		cv.mark_dirty()
	}
	if !isnil(st.cv_b) {
		mut cb := st.cv_b
		if cb.has_detail() {
			cb.clear_detail()
			cb.mark_dirty()
		}
	}
}

// detail_check - показать готовые фрагменты, запросить недостающий или
// снять слои
fn detail_check(mut st State) {
	if isnil(st.dt) || isnil(st.cv) {
		return
	}
	if !detail_wanted(st) {
		clear_details(mut st)
		return
	}
	f := detail_frac(st)
	if f.x1 <= f.x0 {
		return
	}
	// Слоя нет (только что увеличили, сменили режим до/после) - показать
	// готовое; при прокрутке слой уже стоит - без перерисовки
	cv := st.cv
	if !cv.has_detail() || (st.ba_sbs && ba_active(st) && !isnil(st.cv_b) && !st.cv_b.has_detail()) {
		detail_show(mut st)
	}
	for side in detail_sides(st) {
		if !frag_ready(st, side, f) {
			detail_start(mut st, side)
			return
		}
	}
}

// find_src - готовый полный кадр по ключу или nil
fn find_src(dt &DetailCtl, key string) &DetailSrc {
	for s in dt.srcs {
		if s.path == key {
			return s
		}
	}
	return unsafe { nil }
}

// detail_start - фоновый расчёт фрагмента стороны side по текущему виду и
// настройкам
fn detail_start(mut st State, side int) {
	mut dt := st.dt
	key := detail_prep_key(st, side)
	run_key := '${side}|${key}'
	if dt.running {
		// Идущий расчёт и так даст нужное - ждать его; иначе - ещё проход
		// после него
		if dt.run_key == run_key && frac_contains(dt.run_frac, detail_pad, detail_frac(st)) {
			return
		}
		dt.pending = true
		return
	}
	p := detail_prep_of(st, side)
	src_key := st.raw_path
	lens_key := '${st.raw_path}|${st.look.vign}|${st.look.zoom}'
	use_ai := p.ai_s > 0 && st.ai_full.len > 0
	// Шторка: «до» - ровно на месте готового «после» (сшиваются по линии)
	fa := dt.frag[side_after]
	region := if side == side_before && st.ba_split && !st.ba_hold && fa.lin.len > 0
		&& fa.gen == st.file_gen {
		fa.r
	} else {
		Region{}
	}
	req := DetailReq{
		gen:       st.file_gen
		side:      side
		path:      st.raw_path
		src_key:   src_key
		lens_key:  lens_key
		prep:      DetailPrep{
			...p
			ai_s: if use_ai { p.ai_s } else { f32(0) }
		}
		corr:      st.corr
		vign:      st.look.vign
		zoom:      st.look.zoom
		src:       find_src(dt, src_key)
		lens:      if dt.lens_key == lens_key { dt.lens } else { unsafe { nil } }
		frac:      detail_frac(st)
		region:    region
		geom:      out_geom(&st.edit)
		key:       key
		ai_full:   if use_ai { share(st.ai_full) } else { []u16{} }
		ai_fw:     st.ai_fw
		ai_fh:     st.ai_fh
	}
	dt.running = true
	dt.run_key = run_key
	dt.run_frac = detail_frac(st)
	mut app := st.app
	dt.threads << spawn detail_worker(req, mut app, st.dt_done)
}

fn detail_worker(req DetailReq, mut app vgui.App, on_done fn (DetailRes)) {
	// Своя ссылка на результат AI - отпустить в конце (res.req её не читают)
	mut ai_full := unsafe { req.ai_full }
	defer {
		drop(mut ai_full)
	}
	mut res := DetailRes{
		req:  req
		src:  req.src
		lens: req.lens
	}
	if isnil(res.src) {
		res.src = load_detail_src(req.path) or {
			res.err = err.msg()
			post_result(mut app, on_done, res)
			return
		}
	}
	if req.prep.use_lens && isnil(res.lens) {
		res.lens = make_detail_lens(req.corr, res.src, req.vign, req.zoom)
	}
	ow, oh := req.geom.out_size(res.src.w, res.src.h, true)
	// Шторка: «до» - ровно прямоугольник готового «после»
	r := if req.region.w > 0 && req.region.x + req.region.w <= ow && req.region.y + req.region.h <= oh {
		req.region
	} else {
		frac_region(req.frac, ow, oh, detail_pad)
	}
	dai := DetailAi{
		full:     req.ai_full
		fw:       req.ai_fw
		fh:       req.ai_fh
		strength: req.prep.ai_s
	}
	if !r.is_empty() {
		ln := if req.prep.use_lens { res.lens } else { unsafe { &DetailLens(nil) } }
		res.lin = detail_prep(res.src, ln, DetailJob{
			r:     r
			geom:  req.geom
			nr:    req.prep.nr
			dc:    req.prep.dc
			spots: req.prep.spots
			man:   req.prep.man
		}, dai) or {
			res.err = err.msg()
			[]u16{}
		}
	}
	res.r = r
	res.ow = ow
	res.oh = oh
	post_result(mut app, on_done, res)
}

// detail_done - результат воркера (главный поток)
fn detail_done(mut st State, res DetailRes) {
	mut dt := st.dt
	dt.running = false
	dt.run_key = ''
	// То, что воркер собрал заново (полный кадр, объектив), -
	// теперь наше или лишнее
	if dt.drop || res.req.gen != st.file_gen {
		dt.drop = false
		if !isnil(res.src) && !has_src(dt, res.src) {
			mut s := res.src
			s.free()
		}
		if !isnil(res.lens) && voidptr(res.lens) != voidptr(dt.lens) {
			mut l := res.lens
			l.free()
		}
		detail_free(mut dt)
		dt.pending = false
		detail_check(mut st)
		return
	}
	if !isnil(res.src) && !has_src(dt, res.src) {
		dt.srcs << res.src
		// Лишний полный кадр - прежнего файла: остаётся только новый
		if dt.srcs.len > detail_srcs_max {
			mut kept := []&DetailSrc{}
			for i in 0 .. dt.srcs.len {
				mut x := dt.srcs[i]
				if voidptr(x) == voidptr(res.src) {
					kept << x
				} else {
					x.free()
				}
			}
			dt.srcs = kept
		}
	}
	if !isnil(res.lens) && voidptr(res.lens) != voidptr(dt.lens) {
		if !isnil(dt.lens) {
			mut l := dt.lens
			l.free()
		}
		dt.lens = res.lens
		dt.lens_key = res.req.lens_key
	}
	if res.err.len > 0 {
		dt.pending = false
		return
	}
	dt.frag[res.req.side] = DetailFrag{
		lin: res.lin
		r:   res.r
		ow:  res.ow
		oh:  res.oh
		key: res.req.key
		gen: res.req.gen
	}
	dt.pending = false
	// Показать и досчитать недостающее (вид или настройки могли смениться
	// за время расчёта; в до/после - вторая сторона)
	detail_show(mut st)
	detail_check(mut st)
}

// has_src - полный кадр p уже у DetailCtl (сравнение по адресу)
fn has_src(dt &DetailCtl, p &DetailSrc) bool {
	for s in dt.srcs {
		if voidptr(s) == voidptr(p) {
			return true
		}
	}
	return false
}

// frag_usable - фрагмент стороны есть для этого кадра (может быть по
// прежним настройкам - показывается, пока считается новый)
fn frag_usable(st &State, side int) bool {
	fr := st.dt.frag[side]
	return fr.lin.len > 0 && fr.gen == st.file_gen && fr.ow > 0
}

// render_side - фрагмент стороны с её тоном (финальный проход) в RGBA
fn render_side(st &State, side int, view pipeline.SharpView) []u8 {
	fr := st.dt.frag[side]
	// Градиентные фильтры: пиксель фрагмента - пиксель полного выхода
	mm := pipeline.mask_map(out_geom(&st.edit), st.pw, st.ph, true, fr.ow, fr.oh).region(fr.r.x,
		fr.r.y, fr.r.w)
	// Эффекты (виньетка, зерно): место фрагмента в полном кадре
	fm := pipeline.FxMap{fr.r.x, fr.r.y, fr.ow, fr.oh}
	if side == side_before {
		gmask, haze := ba_maps(st)
		return detail_render(fr.lin, fr.r, fr.ow, fr.oh, gmask, st.gw, st.gh, haze, with_fxmap(with_lmap(ba_state(st).params,
			mm), fm), view)
	}
	return detail_render(fr.lin, fr.r, fr.ow, fr.oh, st.gmask, st.gw, st.gh, &st.haze,
		with_fxmap(with_lmap(st.edit.params, mm), fm), view)
}

// with_fxmap - параметры с местом буфера в кадре для эффектов (копия, как
// with_lmap)
fn with_fxmap(p pipeline.Params, fm pipeline.FxMap) pipeline.Params {
	if !p.fx.active() {
		return p
	}
	mut q := p
	q.fxmap = fm
	return q
}

// set_frag_layer - фрагмент pix (на месте фрагмента стороны side) - слоем
// детализации холста
fn set_frag_layer(st &State, mut cv vgui.Canvas, side int, pix []u8) {
	fr := st.dt.frag[side]
	kx := f32(st.gw) / f32(fr.ow)
	ky := f32(st.gh) / f32(fr.oh)
	cv.set_detail(pix.data, pix.len, fr.r.w, fr.r.h, f32(fr.r.x) * kx, f32(fr.r.y) * ky,
		f32(fr.r.w) * kx, f32(fr.r.h) * ky)
	cv.mark_dirty()
}

fn clear_layer(mut cv vgui.Canvas) {
	if cv.has_detail() {
		cv.clear_detail()
		cv.mark_dirty()
	}
}

// detail_show - готовые фрагменты с текущим тоном на холсты (финальный
// проход): обычно - «после»; удержание «\» - «до»; шторка - «до» левее
// линии, «после» правее; бок о бок - «до» на холсте «до»
fn detail_show(mut st State) {
	if isnil(st.dt) || isnil(st.cv) {
		return
	}
	mut cv := st.cv
	if !detail_wanted(st) {
		clear_details(mut st)
		return
	}
	view := if st.sharp_drag != .off {
		st.sharp_drag
	} else if st.sharp_show {
		pipeline.SharpView.mask
	} else {
		pipeline.SharpView.off
	}
	ba := ba_active(st)
	// Холст «до» (бок о бок)
	if !isnil(st.cv_b) {
		mut cb := st.cv_b
		if ba && st.ba_sbs && !st.ba_hold && frag_usable(st, side_before) {
			mut pb := render_side(st, side_before, view)
			mark_clipping(mut pb, st.clip_hi, st.clip_lo)
			set_frag_layer(st, mut cb, side_before, pb)
		} else {
			clear_layer(mut cb)
		}
	}
	if ba && st.ba_hold {
		if frag_usable(st, side_before) {
			mut pb := render_side(st, side_before, view)
			mark_clipping(mut pb, st.clip_hi, st.clip_lo)
			set_frag_layer(st, mut cv, side_before, pb)
		} else {
			clear_layer(mut cv)
		}
		return
	}
	if !frag_usable(st, side_after) {
		clear_layer(mut cv)
		return
	}
	mut pix := render_side(st, side_after, view)
	if view == .off {
		mark_clipping(mut pix, st.clip_hi, st.clip_lo)
	}
	if ba && st.ba_split {
		// Шторка: без «до» на том же месте слоя нет (видно превью со
		// шторкой), иначе - левее линии «до»
		fa := st.dt.frag[side_after]
		fb := st.dt.frag[side_before]
		if !frag_usable(st, side_before) || fb.r != fa.r || fb.ow != fa.ow {
			clear_layer(mut cv)
			return
		}
		mut pb := render_side(st, side_before, view)
		mark_clipping(mut pb, st.clip_hi, st.clip_lo)
		mut dt := st.dt
		dt.split_a = pix
		dt.split_b = pb
		detail_split_compose(mut st)
		return
	}
	set_frag_layer(st, mut cv, side_after, pix)
}

// detail_split_compose - слой шторки из готовых картинок «до» и «после»:
// левее линии «до»
fn detail_split_compose(mut st State) {
	dt := st.dt
	fa := dt.frag[side_after]
	n := fa.r.w * fa.r.h * 4
	if dt.split_a.len != n || dt.split_b.len != n || fa.ow <= 0 {
		return
	}
	mut pix := dt.split_a.clone()
	// Линия шторки - в пикселях превью; в выходе полного кадра
	split := int(f32(ba_split_x(st)) * f32(fa.ow) / f32(st.gw) + 0.5) - fa.r.x
	cut := if split < 0 { 0 } else if split > fa.r.w { fa.r.w } else { split }
	for y in 0 .. fa.r.h {
		o := y * fa.r.w * 4
		unsafe { vmemcpy(&u8(pix.data) + o, &u8(dt.split_b.data) + o, cut * 4) }
	}
	mut cv := st.cv
	set_frag_layer(st, mut cv, side_after, pix)
}

// detail_split_move - линию шторки сдвинули: слой - из готовых картинок
fn detail_split_move(mut st State) {
	if isnil(st.dt) || isnil(st.cv) || !st.cv.has_detail() || !st.ba_split || st.ba_hold {
		return
	}
	detail_split_compose(mut st)
}

// detail_refresh - после пересчёта превью: те же фрагменты с новым тоном
// и, если вид или подготовка сменились, - новый расчёт
fn detail_refresh(mut st State) {
	detail_show(mut st)
	detail_check(mut st)
}

// detail_free - выбросить полные кадры и объектив (смена кадра)
fn detail_free(mut dt DetailCtl) {
	if !isnil(dt.lens) {
		mut l := dt.lens
		l.free()
	}
	dt.lens = unsafe { nil }
	dt.lens_key = ''
	for i in 0 .. dt.srcs.len {
		mut x := dt.srcs[i]
		x.free()
	}
	dt.srcs.clear()
}

// detail_reset - новый кадр: слои сняты, готовые фрагменты забыты; полные
// кадры прежнего - выброшены (если воркер их ещё держит - по окончании)
fn detail_reset(mut st State) {
	if isnil(st.dt) {
		return
	}
	mut dt := st.dt
	dt.frag = [2]DetailFrag{}
	dt.seen = ''
	if dt.running {
		dt.drop = true
	} else {
		detail_free(mut dt)
	}
	if !isnil(st.cv) {
		mut cv := st.cv
		cv.clear_detail()
	}
	if !isnil(st.cv_b) {
		mut cb := st.cv_b
		cb.clear_detail()
	}
}

// wait_details - дождаться фоновых расчётов на выходе
fn wait_details(mut st State) {
	if isnil(st.dt) {
		return
	}
	mut dt := st.dt
	for t in dt.threads {
		t.wait()
	}
	dt.threads.clear()
}
