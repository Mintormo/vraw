module main

// Предзагрузка соседнего кадра: когда открытый кадр загружен, его сосед в
// ленте (в сторону, куда листали; с фильтром - среди кадров фильтра)
// проявляется в фоне тем же load_compute, что и обычная загрузка, и
// ложится в кэш кадров (framecache.v). Переход на него - как возврат к
// уже виденному: без оверлея «Обработка», через один apply (~45 мс
// вместо ~0.75 с).
//
// Перешли на кадр, пока его предзагрузка ещё идёт, - она не начинается
// заново: open_file делает всё быстрое (сайдкар, история, лента), держит
// свой хендл LibRaw (pf_nd) и показывает «Обработку», а итог предзагрузки
// сразу уходит в on_load_done (через кэш - frame_take). Переход на другой
// кадр, закрытие кадра или смена папки предзагрузку отменяют (флаг между
// этапами, итог отбрасывается по pf_gen).
//
// Поток - с пониженным приоритетом (nice, как фоновая нагрузка экспорта):
// окно и правки открытого кадра важнее. Нужен включённый кэш кадров.
// Воркер сам открывает LibRaw (хендл закрывает - в кэше хендла нет) и сам
// читает сайдкар соседа (только коррекцию объектива: с ней считается
// сырьё; остальное - при открытии, как всегда).
import vgui
import raw
import lens

const pf_nice = 10

struct PfJob {
	gen  int
	path string
	db   &lens.Database = unsafe { nil }
	stop &StopFlag      = unsafe { nil }
}

struct PfResult {
	gen  int
	path string
	res  LoadResult // dev уже закрыт (nil)
}

// prefetch_worker - в spawn: открыть, проявить, закрыть хендл -> on_done
fn prefetch_worker(job PfJob, mut app vgui.App, on_done fn (PfResult)) {
	apply_load(LoadLevel{
		nice: pf_nice
	})
	mut out := PfResult{
		gen:  job.gen
		path: job.path
	}
	mut d := raw.open(job.path) or {
		out = PfResult{
			...out
			res: LoadResult{
				err: err.msg()
			}
		}
		post_result(mut app, on_done, out)
		return
	}
	mut lens_corr := neutral_edit().lens_corr
	mut man := lens.Manual{}
	if side := load_sidecar(sidecar_path(job.path)) {
		if side.history.len > 0 {
			lens_corr = side.history[side.current].state.lens_corr
			man = side.history[side.current].state.lman
		}
	}
	mut res := load_compute(LoadJob{
		gen:       job.gen
		dev:       d
		db:        job.db
		lens_corr: lens_corr
		man:       man
		stop:      job.stop
	})
	d.close()
	res = LoadResult{
		...res
		dev: unsafe { nil }
	}
	if job.stop.stop && res.err.len == 0 {
		res = LoadResult{
			...res
			err: 'отменено'
		}
	}
	out = PfResult{
		...out
		res: res
	}
	post_result(mut app, on_done, out)
}

// prefetch_next - начать предзагрузку соседа открытого кадра (если её нет
// и сосед ещё не в кэше). Зовётся, когда кадр загружен (on_load_done).
fn prefetch_next(mut st State) {
	if st.settings.no_frame_cache || st.pf_running || st.loading || isnil(st.app)
		|| st.frame_idx < 0 || st.raw_path == '' {
		return
	}
	mut next := next_shown(st, st.frame_idx, st.nav_dir)
	if next < 0 {
		next = next_shown(st, st.frame_idx, -st.nav_dir)
	}
	if next < 0 {
		return
	}
	path := st.frames[next].path
	if path == st.raw_path || st.fcache.any(it.path == path) {
		return
	}
	st.pf_gen++
	stop := &StopFlag{}
	st.pf_stop = stop
	st.pf_path = path
	st.pf_running = true
	job := PfJob{
		gen:  st.pf_gen
		path: path
		db:   st.lens_db
		stop: stop
	}
	mut app := st.app
	st.load_threads << spawn prefetch_worker(job, mut app, st.pf_done)
}

// prefetch_cancel - отменить идущую предзагрузку (её итог отбросится) и
// ожидание её итога открытым кадром
fn prefetch_cancel(mut st State) {
	if st.pf_running {
		mut s := st.pf_stop
		s.stop = true
		st.pf_running = false
		st.pf_gen++
	}
	pf_unwait(mut st)
}

// pf_unwait - открытый кадр больше не ждёт предзагрузку: закрыть его хендл
fn pf_unwait(mut st State) {
	if !isnil(st.pf_nd) {
		mut d := st.pf_nd
		d.close()
		st.pf_nd = unsafe { nil }
	}
	st.pf_wait = ''
}

// prefetch_adopt - из open_file: кадр path как раз предзагружается -
// дождаться её итога вместо новой загрузки (nd - хендл, открытый
// open_file; перейдёт в итог). false - предзагрузки этого кадра нет.
fn prefetch_adopt(mut st State, path string, nd &raw.Developer) bool {
	if !st.pf_running || st.pf_path != path {
		return false
	}
	pf_unwait(mut st)
	st.pf_wait = path
	st.pf_nd = unsafe { nd }
	return true
}

// prefetch_take - итог предзагрузки в главном потоке: в кэш кадров, а
// если открытый кадр его ждёт - сразу в on_load_done
fn prefetch_take(mut st State, r PfResult) {
	if r.gen != st.pf_gen {
		free_load(r.res) // отменённая
		return
	}
	st.pf_running = false
	waiting := st.pf_wait == r.path && r.path == st.raw_path
	if r.res.err.len > 0 || r.res.dev_linear.len == 0 {
		free_load(r.res)
		if waiting {
			// Не вышло - обычная загрузка тем хендлом, что открыл open_file
			nd := st.pf_nd
			st.pf_nd = unsafe { nil }
			st.pf_wait = ''
			load_start(mut st, nd)
		}
		return
	}
	if r.path == st.raw_path && !waiting {
		free_load(r.res) // кадр уже открыт своей загрузкой
		return
	}
	frame_put(mut st, r.path, r.res)
	if waiting {
		nd := st.pf_nd
		st.pf_nd = unsafe { nil }
		st.pf_wait = ''
		if res := frame_take(mut st, r.path, nd) {
			st.on_load_done(res)
		} else {
			load_start(mut st, nd) // кэш выключили за это время
		}
	}
}

// load_start - обычная фоновая загрузка открытого кадра хендлом nd (open_file)
fn load_start(mut st State, nd &raw.Developer) {
	stop := &StopFlag{}
	st.load_stop = stop
	show_loading(mut st, true)
	job := LoadJob{
		gen:       st.file_gen
		dev:       nd
		db:        st.lens_db
		lens_corr: st.edit.lens_corr
		man:       st.edit.lman
		stop:      stop
	}
	mut app := st.app
	st.load_threads << spawn load_worker(job, mut app, st.on_load_done)
}
