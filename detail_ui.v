module main

// Настоящий 1:1 в окне: при масштабе больше 50% (пиксель превью half-size
// крупнее пикселя экрана) поверх холста показывается фрагмент полного
// кадра - слой детализации vgui.Canvas (set_detail). Расчёт - detail.v.
//
// Как устроено:
// - detail_watch (из on_overlay холста, на каждую отрисовку) сверяет
//   масштаб и видимую часть с прошлой отрисовкой; изменилось - detail_check
//   через app.post (не посреди draw).
// - detail_check: не нужен (вписан, режим кадрирования, показ дымки,
//   до/после, AI в превью) - слой снят; готовый фрагмент покрывает видимое
//   и посчитан по тем же настройкам подготовки - показать; иначе - фоновый
//   расчёт (один за раз; запрос во время работы - ещё проход после).
// - Полный кадр LibRaw (~0.6 с) и объектив кадра грузятся ЛЕНИВО - при
//   первом увеличении - и живут до смены кадра (~150 МБ).
// - Тональные ползунки (apply_pipeline) перерисовывают готовый фрагмент
//   сразу (detail_show, ~10-30 мс); шумодав, объектив, резкость, геометрия
//   меняют ключ подготовки - фрагмент пересчитывается в фоне, до этого виден
//   прежний.
// Запрос - в долях видимой части превью: размер полного кадра воркер узнаёт
// сам (у превью half-size нечётный край обрезан).
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

@[heap]
struct DetailCtl {
mut:
	src      &DetailSrc  = unsafe { nil }
	src_key  string // путь и режим пересветов src
	lens     &DetailLens = unsafe { nil }
	lens_key string // кадр, профиль и сила виньетки lens
	running  bool
	pending  bool // запрос во время работы - ещё проход после
	drop     bool // кадр сменился во время работы - src и lens выбросить
	threads  []thread
	// Готовый фрагмент: сырьё lin прямоугольника r выхода ow x oh, ключ
	// подготовки key, кадр gen
	lin []u16
	r   Region
	ow  int
	oh  int
	key string
	gen int
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

// DetailReq - снимок для фонового расчёта (без State и vgui)
struct DetailReq {
	gen       int
	path      string
	highlight int
	src_key   string
	lens_key  string
	use_lens  bool
	corr      &lens.Corrector = unsafe { nil }
	vign      f32
	src       &DetailSrc  = unsafe { nil } // готовый (тот же src_key) или nil
	lens      &DetailLens = unsafe { nil } // готовый (тот же lens_key) или nil
	frac      DetailFrac
	geom      pipeline.Geom
	nr        [4]f32
	dc        pipeline.Sharpen
	key       string
}

struct DetailRes {
	req DetailReq
mut:
	src  &DetailSrc  = unsafe { nil }
	lens &DetailLens = unsafe { nil }
	lin  []u16
	r    Region
	ow   int
	oh   int
	err  string
}

// detail_prep_key - настройки, от которых зависит сырьё фрагмента
fn detail_prep_key(st &State) string {
	g := out_geom(&st.edit)
	return '${st.file_gen}|${st.edit.highlight}|${st.edit.lens_corr}|${st.look.vign}|${st.edit.nr}|${dc_key(st.edit.params.sharp)}|${g}'
}

// detail_wanted - нужен ли слой детализации сейчас
fn detail_wanted(st &State) bool {
	if isnil(st.cv) || isnil(st.dt) || st.loading || st.raw_path == '' || st.glin.len == 0 {
		return false
	}
	// Режим кадрирования - весь повёрнутый кадр; дымка показывается картой;
	// до/после и AI на фрагменте - позже (ROADMAP)
	if st.crop_mode || st.haze_show || ba_active(st) || st.ai_applied > 0 {
		return false
	}
	cv := st.cv
	return !cv.auto_fit && cv.screen_scale() > detail_min_scale
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

// detail_check - показать готовый фрагмент, запросить новый или снять слой
fn detail_check(mut st State) {
	if isnil(st.dt) || isnil(st.cv) {
		return
	}
	mut cv := st.cv
	if !detail_wanted(st) {
		if cv.has_detail() {
			cv.clear_detail()
			cv.mark_dirty()
		}
		return
	}
	mut dt := st.dt
	f := detail_frac(st)
	if f.x1 <= f.x0 {
		return
	}
	if dt.lin.len > 0 && dt.gen == st.file_gen && dt.ow > 0 {
		if !cv.has_detail() {
			detail_show(mut st)
		}
		if dt.key == detail_prep_key(st) && dt.r.contains(frac_region(f, dt.ow, dt.oh, 0)) {
			return
		}
	}
	detail_start(mut st)
}

// detail_start - фоновый расчёт фрагмента по текущему виду и настройкам
fn detail_start(mut st State) {
	mut dt := st.dt
	if dt.running {
		dt.pending = true
		return
	}
	src_key := '${st.raw_path}|${st.edit.highlight}'
	use_lens := st.edit.lens_corr && !isnil(st.corr)
	lens_key := '${src_key}|${use_lens}|${st.look.vign}'
	req := DetailReq{
		gen:       st.file_gen
		path:      st.raw_path
		highlight: st.edit.highlight
		src_key:   src_key
		lens_key:  lens_key
		use_lens:  use_lens
		corr:      st.corr
		vign:      st.look.vign
		src:       if dt.src_key == src_key { dt.src } else { unsafe { nil } }
		lens:      if dt.lens_key == lens_key { dt.lens } else { unsafe { nil } }
		frac:      detail_frac(st)
		geom:      out_geom(&st.edit)
		nr:        st.edit.nr
		dc:        st.edit.params.sharp
		key:       detail_prep_key(st)
	}
	dt.running = true
	mut app := st.app
	dt.threads << spawn detail_worker(req, mut app, st.dt_done)
}

fn detail_worker(req DetailReq, mut app vgui.App, on_done fn (DetailRes)) {
	mut res := DetailRes{
		req:  req
		src:  req.src
		lens: req.lens
	}
	if isnil(res.src) {
		res.src = load_detail_src(req.path, req.highlight) or {
			res.err = err.msg()
			post_result(mut app, on_done, res)
			return
		}
	}
	if req.use_lens && isnil(res.lens) {
		res.lens = make_detail_lens(req.corr, res.src, req.vign)
	}
	ow, oh := req.geom.out_size(res.src.w, res.src.h, true)
	r := frac_region(req.frac, ow, oh, detail_pad)
	if !r.is_empty() {
		ln := if req.use_lens { res.lens } else { unsafe { &DetailLens(nil) } }
		res.lin = detail_prep(res.src, ln, DetailJob{
			r:    r
			geom: req.geom
			nr:   req.nr
			dc:   req.dc
		})
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
	// Объектив, который воркер собрал заново, - теперь наш или лишний
	if dt.drop || res.req.gen != st.file_gen {
		dt.drop = false
		detail_free(mut dt)
		if !isnil(res.lens) && res.lens != dt.lens {
			mut l := res.lens
			l.free()
		}
		dt.pending = false
		detail_check(mut st)
		return
	}
	if res.err.len > 0 {
		dt.pending = false
		return
	}
	dt.src = res.src
	dt.src_key = res.req.src_key
	if res.req.use_lens && res.lens != dt.lens {
		if !isnil(dt.lens) {
			mut l := dt.lens
			l.free()
		}
		dt.lens = res.lens
		dt.lens_key = res.req.lens_key
	}
	dt.lin = res.lin
	dt.r = res.r
	dt.ow = res.ow
	dt.oh = res.oh
	dt.key = res.req.key
	dt.gen = res.req.gen
	detail_show(mut st)
	if dt.pending {
		dt.pending = false
	}
	// Вид или настройки могли смениться за время расчёта
	detail_check(mut st)
}

// detail_show - готовый фрагмент с текущим тоном на холст (финальный проход)
fn detail_show(mut st State) {
	if isnil(st.dt) || isnil(st.cv) {
		return
	}
	mut cv := st.cv
	dt := st.dt
	if !detail_wanted(st) || dt.lin.len == 0 || dt.gen != st.file_gen || dt.ow <= 0 {
		if cv.has_detail() {
			cv.clear_detail()
			cv.mark_dirty()
		}
		return
	}
	view := if st.sharp_drag != .off {
		st.sharp_drag
	} else if st.sharp_show {
		pipeline.SharpView.mask
	} else {
		pipeline.SharpView.off
	}
	mut pix := detail_render(dt.lin, dt.r, dt.ow, dt.oh, st.gmask, st.gw, st.gh, &st.haze,
		st.edit.params, view)
	if view == .off {
		mark_clipping(mut pix, st.clip_hi, st.clip_lo)
	}
	kx := f32(st.gw) / f32(dt.ow)
	ky := f32(st.gh) / f32(dt.oh)
	cv.set_detail(pix.data, pix.len, dt.r.w, dt.r.h, f32(dt.r.x) * kx, f32(dt.r.y) * ky,
		f32(dt.r.w) * kx, f32(dt.r.h) * ky)
	cv.mark_dirty()
}

// detail_refresh - после пересчёта превью: тот же фрагмент с новым тоном
// и, если вид или подготовка сменились, - новый расчёт
fn detail_refresh(mut st State) {
	detail_show(mut st)
	detail_check(mut st)
}

// detail_free - выбросить полный кадр и объектив (смена кадра)
fn detail_free(mut dt DetailCtl) {
	if !isnil(dt.lens) {
		mut l := dt.lens
		l.free()
	}
	dt.lens = unsafe { nil }
	dt.lens_key = ''
	dt.src = unsafe { nil }
	dt.src_key = ''
}

// detail_reset - новый кадр: слой снят, готовый фрагмент забыт; полный
// кадр прежнего - выброшен (если воркер его ещё держит - по окончании)
fn detail_reset(mut st State) {
	if isnil(st.dt) {
		return
	}
	mut dt := st.dt
	dt.lin = []u16{}
	dt.key = ''
	dt.ow = 0
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
