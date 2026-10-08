module main

// Сравнение двух кадров (C, «Вид - Сравнить с выделенным») - выбрать
// лучший из серии. Область снимка делится, как «до/после: бок о бок»
// (тот же второй холст st.cv_b слева, ряд st.cmp_row): слева - выделенный
// в ленте кадр с правками из его сайдкара (только просмотр), справа -
// открытый, его можно править. Зум и прокрутка связаны (sbs_sync).
//
// Пока сравнение включено, одиночный щелчок по миниатюре ленты меняет
// левый кадр - можно перебирать серию рядом с открытым. Shift+C или
// двойной щелчок по левому кадру - поменять местами: левый открывается
// для правки, прежний открытый уходит влево (его картинка - сразу из
// готового превью, без пересчёта).
//
// Левый кадр проявляется в фоне путём экспорта (develop_full) в размере
// превью (half) и без AI-шумодава: модель по кадру - минуты. На 100% он -
// увеличенное превью, а не пиксели полного кадра, как у открытого.
// С «до/после» (шторка, бок о бок) сравнение взаимоисключающее.
import os
import vgui
import lens
import i18n

// PairJob - проявка левого кадра (поток)
struct PairJob {
	gen  int
	path string
	edit EditState // из сайдкара, без производных полей
	db   &lens.Database = unsafe { nil }
	stop &StopFlag      = unsafe { nil }
}

// PairResult - левый кадр (RGBA w x h) или ошибка
struct PairResult {
	gen  int
	path string
	w    int
	h    int
	rgba []u8
	err  string
}

// PairStop - прогресс проявки: только проверка отмены (новый кадр выбран
// раньше, чем проявился прежний)
struct PairStop {
	stop &StopFlag = unsafe { nil }
}

fn (mut p PairStop) stage(_ ExportStage, _ int, _ int) bool {
	return isnil(p.stop) || !p.stop.stop
}

fn pair_worker(job PairJob, mut app vgui.App, on_done fn (PairResult)) {
	post_result(mut app, on_done, pair_render(job))
}

// pair_render - кадр по настройкам сайдкара в размере превью, без AI
fn pair_render(job PairJob) PairResult {
	mut e := batch_derive(job.path, job.edit, job.db) or {
		return PairResult{
			gen:  job.gen
			path: job.path
			err:  err.msg()
		}
	}
	e.ai = 0
	mut img := develop_full(job.path, e, job.db,
		half:     true
		progress: StageProgress(PairStop{
			stop: job.stop
		})
	) or {
		return PairResult{
			gen:  job.gen
			path: job.path
			err:  if err is ExportCancelled { '' } else { err.msg() }
		}
	}
	defer {
		img.free()
	}
	n := img.width * img.height
	mut rgba := []u8{len: n * 4}
	unsafe {
		mut s := &u8(img.rgb.data)
		mut d := &u8(rgba.data)
		for _ in 0 .. n {
			d[0] = s[0]
			d[1] = s[1]
			d[2] = s[2]
			d[3] = 255
			s += 3
			d += 4
		}
	}
	return PairResult{
		gen:  job.gen
		path: job.path
		w:    img.width
		h:    img.height
		rgba: rgba
	}
}

// pair_side_edit - настройки кадра из его сайдкара (нет - нейтральные)
fn pair_side_edit(path string) EditState {
	side := load_sidecar(sidecar_path(path)) or { return neutral_edit() }
	return if side.history.len > 0 { side.history[side.current].state } else { neutral_edit() }
}

// pair_candidate - кадр для левой половины: выделенный в ленте, а если
// выделен открытый - соседний (следующий, у последнего - предыдущий)
fn pair_candidate(st &State) string {
	if isnil(st.strip) {
		return ''
	}
	cur := row_of(st, st.frame_idx)
	mut row := st.strip.selected
	if row < 0 || row == cur {
		row = if cur + 1 < st.shown.len { cur + 1 } else { cur - 1 }
	}
	f := frame_of_row(st, row)
	return if f >= 0 && f != st.frame_idx { st.frames[f].path } else { '' }
}

// set_pair - сравнение вкл/выкл (C, меню «Вид»): ряд области снимка
// пересобирается - левый холст добавляется или убирается; до/после
// выключается
fn set_pair(mut st State, on bool) {
	if on {
		path := pair_candidate(st)
		if st.history.len == 0 || path.len == 0 {
			if !isnil(st.nm) {
				mut nm := st.nm
				nm.show_info(i18n.tr('Сравнение - откройте кадр папки и выделите в ленте второй'))
			}
			on_off_menu(st.m_pair, st.pair_on)
			return
		}
		if st.ba_split {
			set_ba_split(mut st, false)
		}
		if st.ba_sbs {
			set_ba_sbs(mut st, false)
		}
		st.pair_on = true
		pair_layout(mut st)
		pair_load(mut st, path)
	} else {
		st.pair_on = false
		pair_stop(mut st)
		st.pair_path = ''
		st.pair_img = []u8{}
		pair_layout(mut st)
	}
	on_off_menu(st.m_pair, st.pair_on)
}

fn on_off_menu(m &vgui.MenuItem, on bool) {
	if !isnil(m) {
		mut it := unsafe { m }
		it.checked = on
	}
}

// pair_layout - ряд области снимка: при сравнении слева холст второго
// кадра (тот же вид, что у открытого - дальше sbs_sync)
fn pair_layout(mut st State) {
	if isnil(st.cmp_row) || isnil(st.cv) || isnil(st.cv_b) {
		return
	}
	mut row := st.cmp_row
	mut cb := st.cv_b
	row.clear()
	if st.pair_on {
		row.add(cb, flex: 1)
	}
	row.add(st.cv, flex: 1)
	cb.visible = st.pair_on
	cv := st.cv
	if st.pair_on {
		set_view_state(mut cb, view_state(cv))
	}
	st.sbs_last = view_state(cv)
}

// pair_stop - отменить проявку левого кадра (результат отбросится по gen)
fn pair_stop(mut st State) {
	st.pair_gen++
	st.pair_busy = false
	if !isnil(st.pair_flag) {
		mut f := st.pair_flag
		f.stop = true
	}
}

// pair_load - проявить кадр path для левой половины (фон); до прихода
// результата там прежняя картинка с подписью «проявка...»
fn pair_load(mut st State, path string) {
	pair_stop(mut st)
	st.pair_path = path
	if isnil(st.app) || path.len == 0 {
		return
	}
	st.pair_busy = true
	stop := &StopFlag{}
	st.pair_flag = stop
	job := PairJob{
		gen:  st.pair_gen
		path: path
		edit: pair_side_edit(path)
		db:   st.lens_db
		stop: stop
	}
	mut app := st.app
	st.pair_threads << spawn pair_worker(job, mut app, st.pair_done)
	pair_redraw(st)
}

// pair_take - левый кадр проявлен (главный поток)
fn pair_take(mut st State, res PairResult) {
	if res.gen != st.pair_gen || !st.pair_on {
		return
	}
	st.pair_busy = false
	if res.err.len > 0 {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_error(i18n.trf('{0}: не проявлен ({1})', '${os.file_name(res.path)}', '${res.err}'))
		}
		pair_redraw(st)
		return
	}
	st.pair_img = res.rgba
	st.pair_w = res.w
	st.pair_h = res.h
	pair_show(mut st)
}

// pair_show - картинка левого кадра на холст (с подсветкой клипа, если
// она включена - как у открытого)
fn pair_show(mut st State) {
	if !st.pair_on || isnil(st.cv_b) {
		return
	}
	n := st.pair_w * st.pair_h * 4
	if st.pair_img.len != n || n == 0 {
		return
	}
	mut cb := st.cv_b
	resized := cb.width != st.pair_w || cb.height != st.pair_h
	if resized {
		cb.width = st.pair_w
		cb.height = st.pair_h
		cb.pixels = []u8{len: n}
		cb.destroy_texture()
	}
	unsafe { vmemcpy(cb.pixels.data, st.pair_img.data, n) }
	mark_clipping(mut cb.pixels, st.clip_hi, st.clip_lo)
	if resized && !isnil(st.cv) {
		cv := st.cv
		cb.auto_fit = false // вписать заново под новый размер
		set_view_state(mut cb, view_state(cv))
	}
	cb.mark_dirty()
}

fn pair_redraw(st &State) {
	if !isnil(st.cv_b) {
		mut cb := st.cv_b
		cb.mark_dirty()
	}
}

// pair_before_open - из open_file до смены кадра: открывают левый кадр
// (поменять местами) - левым становится уходящий открытый, его картинка -
// готовое превью (без подсветки клипа; с ней или во время загрузки -
// проявка в фоне)
fn pair_before_open(mut st State, new_path string) {
	if !st.pair_on || new_path != st.pair_path || st.raw_path.len == 0 {
		return
	}
	old := st.raw_path
	if !isnil(st.cv) && !st.loading && !st.clip_hi && !st.clip_lo && !ba_active(st) {
		cv := st.cv
		n := st.gw * st.gh * 4
		if n > 0 && cv.pixels.len == n {
			pair_stop(mut st)
			st.pair_path = old
			st.pair_img = cv.pixels.clone()
			st.pair_w = st.gw
			st.pair_h = st.gh
			pair_show(mut st)
			return
		}
	}
	pair_load(mut st, old)
}

// pair_select - щелчок по миниатюре ленты (строка row): при сравнении -
// этот кадр слева (открытый и тот же - без изменений)
fn pair_select(mut st State, row int) {
	if !st.pair_on {
		return
	}
	f := frame_of_row(st, row)
	if f < 0 || f == st.frame_idx || st.frames[f].path == st.pair_path {
		return
	}
	pair_load(mut st, st.frames[f].path)
}

// pair_swap - поменять местами (Shift+C, двойной щелчок по левому):
// левый кадр открывается, прежний уходит влево (pair_before_open)
fn pair_swap(mut st State) {
	if !st.pair_on || st.pair_path.len == 0 || isnil(st.goto_frame) {
		return
	}
	for i, f in st.frames {
		if f.path == st.pair_path {
			st.goto_frame(i)
			return
		}
	}
}

// pair_edited - сайдкар кадра переписан не из окна (вставка настроек в
// выделенные): левый кадр - проявить заново
fn pair_edited(mut st State, path string) {
	if st.pair_on && path == st.pair_path {
		pair_load(mut st, path)
	}
}

// pair_input - мышь на левом холсте: двойной щелчок - поменять местами;
// одиночный щелчок забирается (100% / вписать - у открытого, колесо и
// Z - связаны)
fn pair_input(mut st State, ev &vgui.CanvasInputEvent) bool {
	if !st.pair_on {
		return false
	}
	if ev.kind == .pointer_down && ev.button == 1 && ev.clicks == 2 {
		pair_swap(mut st)
	}
	return ev.kind in [.pointer_down, .pointer_up] && ev.button == 1
}

// pair_overlay_b - подпись левого кадра: имя файла (и «проявка...»)
fn pair_overlay_b(st &State, mut ctx vgui.RenderContext) {
	if isnil(st.cv_b) || st.pair_path.len == 0 {
		return
	}
	cb := st.cv_b
	mut text := os.file_name(st.pair_path)
	if st.pair_busy {
		text += i18n.tr(' - проявка...')
	}
	ba_label(mut ctx, text, cb.bounds.x + 10, cb.bounds.y + 10)
}

// pair_overlay - подпись открытого кадра при сравнении
fn pair_overlay(st &State, mut ctx vgui.RenderContext) {
	if !st.pair_on || isnil(st.cv) || st.raw_path.len == 0 {
		return
	}
	cv := st.cv
	ba_label(mut ctx, i18n.trf('{0} - правка', '${os.file_name(st.raw_path)}'), cv.bounds.x + 10, cv.bounds.y + 10)
}

// wait_pair - дождаться проявок левого кадра на выходе
fn wait_pair(mut st State) {
	pair_stop(mut st)
	for t in st.pair_threads {
		t.wait()
	}
	st.pair_threads.clear()
}
