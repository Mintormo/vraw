module main

// До/после и увеличение щелчком - постоянная проверка «лучше или хуже»,
// резкости и шума.
//
// «До» - выбранная запись истории (st.ba_ref; по умолчанию первая -
// «Открыт файл»), посчитанная честно, целиком: если её подготовка сырья
// (коррекция объектива, шумодав, Capture-резкость, AI)
// отличается от нынешней, у «до» своё сырьё (st.ba_lin) - его готовит
// фоновый prep_compute из dev_linear. Пока оно считается, «до» - по нынешнему сырью. AI у «до»
// - только если результат модели годится для его сырья (тот же объектив,
// та же модель). Кадрирование и поворот у «до» - нынешние (иначе
// шторка не совпала бы). Тон и цвет - второй прогон pipeline.apply в свой
// буфер (st.ba_before), пересчёт - только когда меняются сырьё, геометрия
// или сама запись.
// Три режима:
// - удержание «\» - весь снимок «до», пока клавиша нажата (KeyWatch);
// - шторка (Y, «Вид - До/после: шторка») - слева «до», справа «после»,
//   вертикальную линию тянут мышью. «После» (st.ba_after) хранится,
//   чтобы двигать линию без пересчёта пайплайна;
// - бок о бок (Shift+Y) - два снимка рядом: слева «до» (второй холст
//   st.cv_b), справа «после»; зум и панорама связаны (sbs_sync).
// На 100% и «до», и «после» - фрагменты полного кадра (detail_ui.v).
//
// Щелчок по снимку - 100% в эту точку, повторный - обратно «вписать»
// (Z и пробел - то же по центру вида).
import vgui
import pipeline
import lens

// Шторка: линия, ручка, подписи
const ba_line = vgui.Color{255, 255, 255, 230}
const ba_line_dark = vgui.Color{0, 0, 0, 140}
const ba_label_bg = vgui.Color{20, 20, 22, 190}
const ba_label_fg = vgui.Color{235, 235, 235, 255}
const ba_grab_px = f32(10) // захват линии мышью - экранных пикселей
const click_px = f32(4) // сдвиг мыши, после которого это не щелчок, а жест
const sbs_gap = 8 // промежуток между снимками «бок о бок», px

// BaKey - от чего зависит буфер «до»
struct BaKey {
	lin_gen int    // номер сырья, по которому считали (нынешнее или своё «до»)
	raw     string // чьё сырьё: '' - нынешнее, иначе ключ подготовки «до»
	geom    GeomKey
	state   EditState
}

// ba_active - «до» показывается (удержание, шторка или бок о бок) и есть
// что сравнивать: кадр проявлен, история есть, не режим кадрирования и не
// показ карты дымки или резкости
fn ba_active(st &State) bool {
	return (st.ba_hold || st.ba_split || st.ba_sbs) && st.history.len > 0 && st.glin.len > 0
		&& !st.crop_mode && !st.haze_show && !st.dust_show && !st.sharp_show && st.sharp_drag == .off
}

// ba_index - номер записи «до» (выбранная, если она ещё есть, иначе первая)
fn ba_index(st &State) int {
	return if st.ba_ref > 0 && st.ba_ref < st.history.len { st.ba_ref } else { 0 }
}

// ba_state - снимок «до»
fn ba_state(st &State) EditState {
	return st.history[ba_index(st)].state
}

// ba_ai - сила AI у «до»: результат модели посчитан по нынешнему сырью
// после объектива - годится, только если у «до» тот же объектив и модель
fn ba_ai(st &State, b EditState) f32 {
	return if b.ai > 0 && ai_ready(st) && b.lens_corr == st.edit.lens_corr && b.lman == st.edit.lman && b.ai_model == st.ai_lin_model {
		b.ai
	} else {
		0
	}
}

// prep_key_of - подготовка сырья снимка (то, что не входит в тон)
fn prep_key_of(lens_on bool, man lens.Manual, nr [4]f32, dc [3]f32, ai_s f32) string {
	return '${lens_on}|${man.key()}|${nr}|${dc}|${ai_s}'
}

// ba_prep_key - подготовка сырья «до»
fn ba_prep_key(st &State, b EditState) string {
	return prep_key_of(b.lens_corr && !isnil(st.corr), b.lman, b.nr, dc_key(b.params.sharp),
		ba_ai(st, b))
}

// cur_prep_key - подготовка нынешнего сырья (linear)
fn cur_prep_key(st &State) string {
	return prep_key_of(st.edit.lens_corr && !isnil(st.corr), st.edit.lman, st.nr_applied,
		st.dc_applied, st.ai_applied)
}

// ba_own - у «до» своё сырьё и оно готово (иначе - нынешнее): другая
// подготовка - своё из dev_linear; та же подготовка, но другие пятна -
// нынешнее сырьё со своими пятнами
fn ba_own(st &State) bool {
	if st.history.len == 0 {
		return false
	}
	b := ba_state(st)
	need := ba_prep_key(st, b)
	if need != cur_prep_key(st) {
		return st.ba_raw_key == need && st.ba_glin.len > 0
	}
	return ba_spots_differ(st, b) && st.ba_glin.len > 0 && st.ba_gkey == ba_gkey_of(st, b, false)
}

// ba_spots_differ - пятна «до» не те, что у нынешней правки
fn ba_spots_differ(st &State, b EditState) bool {
	return pipeline.spot_key(b.spots) != pipeline.spot_key(st.edit.spots)
}

// ba_gkey_of - ключ сырья «до» после пятен и геометрии: своё сырьё
// (own_raw - номер ba_gen) или нынешнее (номер lin_gen, со знаком минус -
// не путать с ba_gen); пятна - записи «до», геометрия - нынешняя
fn ba_gkey_of(st &State, b EditState, own_raw bool) GeomKey {
	return GeomKey{
		lin_gen: if own_raw { st.ba_gen } else { -1 - st.lin_gen }
		geom:    st.edit.geom
		crop:    !st.crop_mode
		valid:   true
		spots:   pipeline.spot_key(b.spots)
	}
}

// ba_maps - маска «Тени/Света» и карта дымки, по которым считается «до»
// (для фрагмента 1:1 - тоже)
fn ba_maps(st &State) ([]u16, &pipeline.HazeMap) {
	return if ba_own(st) { st.ba_gmask, &st.ba_haze } else { st.gmask, &st.haze }
}

// ba_ensure_raw - сырьё «до»: нынешнее подходит - ничего; своё готово -
// геометрия по нему; иначе - запустить подготовку (пока она идёт, «до» -
// по нынешнему сырью)
fn ba_ensure_raw(mut st State) {
	b := ba_state(st)
	need := ba_prep_key(st, b)
	own_raw := need != cur_prep_key(st)
	if own_raw && (st.ba_raw_key != need || st.ba_lin.len == 0) {
		ba_prep_start(mut st, b, need)
		return
	}
	if !own_raw && !ba_spots_differ(st, b) {
		return
	}
	// Пятна записи «до», геометрия - нынешняя (шторка совпадает), пересчёт
	// по ключу
	gk := ba_gkey_of(st, b, own_raw)
	if gk == st.ba_gkey && st.ba_glin.len > 0 {
		return
	}
	lin := if own_raw { st.ba_lin } else { st.linear }
	mask := if own_raw { st.ba_mask } else { st.mask }
	geom_stage(lin, mask, st.pw, st.ph, b.spots, gk, mut st.ba_glin, mut st.ba_gmask)
	st.ba_haze = pipeline.HazeMap{}
	st.ba_gkey = gk
}

// ba_prep_start - подготовка сырья «до» в фоне (prep_compute со
// настройками записи «до»). Один воркер: запрос во время работы
// запомнится и проверится по окончании.
fn ba_prep_start(mut st State, b EditState, key string) {
	if st.ba_running {
		return
	}
	if st.dev_linear.len == 0 || st.loading || isnil(st.app) {
		return
	}
	ai_s := ba_ai(st, b)
	job := PrepJob{
		gen:       st.file_gen
		src:       share(st.dev_linear)
		w:         st.pw
		h:         st.ph
		redo_lens: true
		corr:      if b.lens_corr { st.corr } else { unsafe { nil } }
		focal:     st.meta.focal
		aperture:  st.meta.aperture
		vign:      st.look.vign
		zoom:      st.look.zoom
		man:       b.lman
		nr:        b.nr
		ai_src:    if ai_s > 0 { share(st.ai_linear) } else { []u16{} }
		ai_s:      ai_s
		dc:        b.params.sharp
	}
	st.ba_running = true
	st.ba_want = key
	mut app := st.app
	st.ba_threads << spawn prep_worker(job, mut app, st.ba_prep_done)
}

// ba_prep_take - сырьё «до» готово (главный поток)
fn ba_prep_take(mut st State, res PrepResult) {
	st.ba_running = false
	mut r := res
	drop(mut r.raw_linear)
	if r.gen != st.file_gen {
		drop(mut r.linear)
		drop(mut r.mask)
		// Кадр сменился, пока считали: «до» нового кадра - заново
		if ba_active(st) {
			ba_refresh(mut st)
		}
		return
	}
	drop(mut st.ba_lin)
	drop(mut st.ba_mask)
	drop(mut st.ba_glin)
	drop(mut st.ba_gmask)
	st.ba_lin = r.linear
	st.ba_mask = r.mask
	st.ba_raw_key = st.ba_want
	st.ba_gen++
	st.ba_haze = pipeline.HazeMap{}
	// «До» показывается - пересобрать по своему сырью (или запустить
	// следующую подготовку, если запись «до» за это время сменилась)
	if ba_active(st) {
		ba_refresh(mut st)
	}
}

// ba_forget - смена кадра: сырьё «до» и выбранная запись забыты
fn ba_forget(mut st State) {
	drop(mut st.ba_lin)
	drop(mut st.ba_mask)
	drop(mut st.ba_glin)
	drop(mut st.ba_gmask)
	st.ba_raw_key = ''
	st.ba_haze = pipeline.HazeMap{}
	st.ba_gen++
	st.ba_ref = 0
	st.ba_before = []u8{}
}

// wait_ba - дождаться подготовки «до» на выходе
fn wait_ba(mut st State) {
	for t in st.ba_threads {
		t.wait()
	}
	st.ba_threads.clear()
	st.ba_running = false
}

// ba_render - буфер «до» по записи «до» (кэш по BaKey)
fn ba_render(mut st State) {
	before := ba_state(st)
	ba_ensure_raw(mut st)
	own := ba_own(st)
	key := BaKey{
		lin_gen: if own { st.ba_gen } else { st.lin_gen }
		raw:     if own { st.ba_raw_key } else { '' }
		geom:    st.geom_key
		state:   before
	}
	npix := st.gw * st.gh
	if key == st.ba_key && st.ba_before.len == npix * 4 {
		return
	}
	glin := if own { st.ba_glin } else { st.glin }
	gmask := if own { st.ba_gmask } else { st.gmask }
	if glin.len != npix * 3 {
		return
	}
	if before.params.haze != 0 {
		if own && st.ba_haze.d.len != npix {
			st.ba_haze = pipeline.haze_map(unsafe { &u16(glin.data) }, st.gw, st.gh)
		} else if !own && st.haze.d.len != npix {
			st.haze = pipeline.haze_map(unsafe { &u16(glin.data) }, st.gw, st.gh)
		}
	}
	st.ba_before = []u8{len: npix * 4}
	mask := if gmask.len == npix * pipeline.mask_ch {
		unsafe { &u16(gmask.data) }
	} else {
		unsafe { &u16(nil) }
	}
	haze := if own { &st.ba_haze } else { &st.haze }
	pipeline.apply_image(unsafe { &u16(glin.data) }, mask, haze, st.gw, st.gh, view_params(st,
		before.params), preview_scale, mut st.ba_before, 4)
	st.ba_key = key
}

// ba_apply - в конце apply_pipeline (cv.pixels - уже «после», с
// гистограммой и подсветкой клипа): запомнить «после» и показать «до»
// целиком, шторкой или рядом
fn ba_apply(mut st State, mut cv vgui.Canvas) {
	// Холст «до» (бок о бок) - только пока до/после действует: в режиме
	// кадрирования и при показе карт там был бы старый снимок
	if !isnil(st.cv_b) {
		mut cb := st.cv_b
		cb.visible = ba_active(st) || st.pair_on
	}
	if !ba_active(st) {
		st.ba_after = []u8{}
		return
	}
	ba_render(mut st)
	st.ba_after = cv.pixels.clone()
	ba_compose(mut st, mut cv)
}

// ba_compose - холст из «до» и «после» без пересчёта пайплайна: при
// удержании - «до», в шторке - «до» левее линии, бок о бок - «до» на
// своём холсте
fn ba_compose(mut st State, mut cv vgui.Canvas) {
	n := st.gw * st.gh * 4
	if st.ba_before.len != n || st.ba_after.len != n || cv.pixels.len != n {
		return
	}
	if st.ba_hold {
		unsafe { vmemcpy(cv.pixels.data, st.ba_before.data, n) }
	} else if st.ba_sbs {
		unsafe { vmemcpy(cv.pixels.data, st.ba_after.data, n) }
		if !isnil(st.cv_b) {
			mut cb := st.cv_b
			if cb.width != st.gw || cb.height != st.gh {
				cb.width = st.gw
				cb.height = st.gh
				cb.pixels = []u8{len: n}
				cb.destroy_texture()
			}
			unsafe { vmemcpy(cb.pixels.data, st.ba_before.data, n) }
			cb.mark_dirty()
		}
	} else {
		split := ba_split_x(st)
		row := st.gw * 4
		unsafe {
			mut d := &u8(cv.pixels.data)
			mut b := &u8(st.ba_before.data)
			mut a := &u8(st.ba_after.data)
			for _ in 0 .. st.gh {
				vmemcpy(d, b, split * 4)
				vmemcpy(d + split * 4, a + split * 4, row - split * 4)
				d += row
				b += row
				a += row
			}
		}
	}
	cv.mark_dirty()
}

// ba_split_x - столбец линии шторки в пикселях превью
fn ba_split_x(st &State) int {
	x := int(st.ba_pos * f32(st.gw) + 0.5)
	return if x < 0 { 0 } else if x > st.gw { st.gw } else { x }
}

// set_ba_hold - удержание «\»: показать «до» / вернуть «после»
fn set_ba_hold(mut st State, on bool) {
	if on == st.ba_hold {
		return
	}
	st.ba_hold = on
	ba_refresh(mut st)
}

// set_ba_split - шторка вкл/выкл (Y, меню «Вид»); бок о бок выключается
fn set_ba_split(mut st State, on bool) {
	if on && st.ba_sbs {
		set_ba_sbs(mut st, false)
	}
	if on && st.pair_on {
		set_pair(mut st, false) // сравнение кадров (pair.v)
	}
	st.ba_split = on
	st.ba_drag = false
	if !isnil(st.m_split) {
		mut m := st.m_split
		m.checked = on
	}
	if on && st.history.len > 0 && st.crop_mode && !isnil(st.nm) {
		mut nm := st.nm
		nm.show_info('До/после - после выхода из кадрирования')
	}
	ba_refresh(mut st)
}

// set_ba_sbs - бок о бок вкл/выкл (Shift+Y, меню «Вид»): область снимка
// пересобирается - второй холст «до» слева; шторка выключается
fn set_ba_sbs(mut st State, on bool) {
	if on && st.ba_split {
		set_ba_split(mut st, false)
	}
	if on && st.pair_on {
		set_pair(mut st, false) // сравнение кадров (pair.v)
	}
	st.ba_sbs = on
	if !isnil(st.m_sbs) {
		mut m := st.m_sbs
		m.checked = on
	}
	if !isnil(st.cmp_row) && !isnil(st.cv) {
		mut row := st.cmp_row
		row.clear()
		if on && !isnil(st.cv_b) {
			mut cb := st.cv_b
			row.add(cb, flex: 1)
		}
		row.add(st.cv, flex: 1)
		// Зум прежний; холст «до» - с тем же видом (дальше - sbs_sync)
		cv := st.cv
		if on && !isnil(st.cv_b) {
			mut cb := st.cv_b
			set_view_state(mut cb, view_state(cv))
		}
		st.sbs_last = view_state(cv)
	}
	if on && st.history.len > 0 && st.crop_mode && !isnil(st.nm) {
		mut nm := st.nm
		nm.show_info('До/после - после выхода из кадрирования')
	}
	ba_refresh(mut st)
}

// set_ba_ref - «до» - запись истории idx (выделенная в списке истории)
fn set_ba_ref(mut st State, idx int) {
	if idx < 0 || idx >= st.history.len {
		return
	}
	st.ba_ref = idx
	refresh_history(mut st)
	sync_ba_ui(mut st)
	if !ba_active(st) && !isnil(st.cv) {
		// Выбрали «до» - сразу показать шторкой
		set_ba_split(mut st, true)
		return
	}
	ba_refresh(mut st)
}

// sync_ba_ui - подпись «До: N. название» под историей
fn sync_ba_ui(mut st State) {
	if isnil(st.ba_lb) {
		return
	}
	mut lb := st.ba_lb
	lb.text = if st.history.len == 0 {
		'До: первая запись'
	} else {
		i := ba_index(st)
		'До: ${i + 1}. ${st.history[i].name}'
	}
}

// ba_refresh - холст под режим: «после» уже посчитано - только
// пересборка из буферов, иначе - пересчёт пайплайна
fn ba_refresh(mut st State) {
	if isnil(st.cv) {
		return
	}
	if !isnil(st.cv_b) {
		mut cb := st.cv_b
		cb.visible = ba_active(st) || st.pair_on
	}
	mut cv := st.cv
	n := st.gw * st.gh * 4
	if st.ba_after.len == n && cv.pixels.len == n {
		if !ba_active(st) {
			unsafe { vmemcpy(cv.pixels.data, st.ba_after.data, n) }
			st.ba_after = []u8{}
			cv.mark_dirty()
			detail_refresh(mut st) // фрагмент 1:1 - снова только «после»
			return
		}
		ba_render(mut st)
		ba_compose(mut st, mut cv)
		detail_refresh(mut st) // фрагменты «до» и «после»
		return
	}
	if !isnil(st.tone_fx) {
		st.tone_fx()
	}
}

// ViewState - зум и прокрутка холста (связь холстов «бок о бок»)
struct ViewState {
	auto_fit bool
	zoom     f32
	sx       f32
	sy       f32
}

fn view_state(cv &vgui.Canvas) ViewState {
	return ViewState{cv.auto_fit, cv.zoom, cv.scroll_x, cv.scroll_y}
}

fn set_view_state(mut cv vgui.Canvas, v ViewState) {
	if v.auto_fit {
		if !cv.auto_fit {
			cv.fit_to_view()
		}
	} else {
		cv.auto_fit = false
		cv.zoom = v.zoom
		cv.scroll_x = v.sx
		cv.scroll_y = v.sy
	}
	cv.mark_dirty()
}

// sbs_sync - из on_overlay холста (b - холст «до»): его зум или прокрутка
// изменились с прошлой связи - перенести на второй холст
fn sbs_sync(mut st State, b bool) {
	if (!st.ba_sbs && !st.pair_on) || isnil(st.cv) || isnil(st.cv_b) {
		return
	}
	mut cv := st.cv
	mut cb := st.cv_b
	me := if b { view_state(cb) } else { view_state(cv) }
	if me == st.sbs_last {
		return
	}
	other := if b { view_state(cv) } else { view_state(cb) }
	st.sbs_last = me
	if other == me {
		return
	}
	if b {
		set_view_state(mut cv, me)
	} else {
		set_view_state(mut cb, me)
	}
	// Второй холст в этом кадре уже нарисован - ещё одна отрисовка
	if !isnil(st.app) {
		mut app := st.app
		app.post(st.dt_check)
	}
}

// ba_overlay - линия шторки, ручка и подписи «До» / «После» (поверх
// снимка, экранные координаты)
fn ba_overlay(mut st State, mut ctx vgui.RenderContext) {
	if !ba_active(st) || isnil(st.cv) {
		return
	}
	cv := st.cv
	x0, y0 := cv.buf_to_screen(0, 0)
	x1, y1 := cv.buf_to_screen(f32(cv.width), f32(cv.height))
	// Подписи - у верхнего края видимой части снимка (на 100% верх кадра
	// за экраном)
	ly := (if y0 > cv.bounds.y { y0 } else { cv.bounds.y }) + 10
	lx := if x0 > cv.bounds.x { x0 } else { cv.bounds.x }
	if st.ba_hold {
		ba_label(mut ctx, 'До', lx + 10, ly)
		return
	}
	if st.ba_sbs {
		ba_label(mut ctx, 'После', cv.bounds.x + 10, cv.bounds.y + 10)
		return
	}
	sx, _ := cv.buf_to_screen(f32(ba_split_x(st)), 0)
	ctx.fill_rect(vgui.Rect{sx - 2, y0, 4, y1 - y0}, ba_line_dark)
	ctx.fill_rect(vgui.Rect{sx - 1, y0, 2, y1 - y0}, ba_line)
	my := (y0 + y1) / 2
	ctx.fill_circle(sx, my, 11, ba_line_dark)
	ctx.fill_circle(sx, my, 9, ba_line)
	ctx.fill_triangle(sx - 6, my, sx - 2, my - 4, sx - 2, my + 4, ba_line_dark)
	ctx.fill_triangle(sx + 6, my, sx + 2, my - 4, sx + 2, my + 4, ba_line_dark)
	if sx - lx > 60 {
		ba_label(mut ctx, 'До', sx - 10 - label_w(ctx, 'До'), ly)
	}
	if x1 - sx > 80 && sx + 80 < cv.bounds.x + cv.bounds.w {
		ba_label(mut ctx, 'После', sx + 10, ly)
	}
}

// ba_overlay_b - подпись холста «до» (бок о бок) с номером записи
fn ba_overlay_b(st &State, mut ctx vgui.RenderContext) {
	if !st.ba_sbs || isnil(st.cv_b) || !ba_active(st) {
		return
	}
	cb := st.cv_b
	i := ba_index(st)
	text := if i == 0 { 'До' } else { 'До: ${i + 1}. ${st.history[i].name}' }
	ba_label(mut ctx, text, cb.bounds.x + 10, cb.bounds.y + 10)
}

// label_w - ширина плашки подписи: текст, измеренный шрифтом подписи,
// и поля по 6 px (без шрифта - оценка по числу букв)
fn label_w(ctx &vgui.RenderContext, text string) f32 {
	m := if isnil(ctx.fonts) { f32(0) } else { ctx.measure_text_with_font(text, ctx.fonts.regular).x }
	return if m > 0 { m + 12 } else { f32(text.runes().len) * 7.5 + 12 }
}

fn ba_label(mut ctx vgui.RenderContext, text string, x f32, y f32) {
	ctx.fill_rounded_rect(vgui.Rect{x, y, label_w(ctx, text), 20}, ba_label_bg, 4)
	ctx.draw_text(text, x + 6, y + 2, ba_label_fg)
}

// ba_input - мышь в шторке: захват линии и перетаскивание; true - событие
// забрано
fn ba_input(mut st State, ev &vgui.CanvasInputEvent) bool {
	if !st.ba_split || !ba_active(st) || isnil(st.cv) {
		st.ba_drag = false
		return false
	}
	mut cv := st.cv
	sc := cv.screen_scale()
	match ev.kind {
		.pointer_down {
			if ev.button != 1 {
				return false
			}
			d := (ev.fx - f32(ba_split_x(st))) * sc
			if d > -ba_grab_px && d < ba_grab_px {
				st.ba_drag = true
				vgui.set_cursor(vgui.sdl_system_cursor_sizewe)
				return true
			}
		}
		.pointer_move {
			if st.ba_drag {
				st.ba_pos = clamp01f(ev.fx / f32(st.gw))
				ba_compose(mut st, mut cv)
				detail_split_move(mut st) // фрагмент 1:1 - по новой линии
				return true
			}
		}
		.pointer_up {
			if st.ba_drag {
				st.ba_drag = false
				return true
			}
		}
		.hover {
			d := (ev.fx - f32(ba_split_x(st))) * sc
			vgui.set_cursor(if d > -ba_grab_px && d < ba_grab_px {
				vgui.sdl_system_cursor_sizewe
			} else {
				vgui.sdl_system_cursor_default
			})
		}
		else {}
	}
	return false
}

// zoom_at - масштаб z с точкой буфера (bx, by) на том же месте экрана
// (zoom_at у vgui.Canvas приватный: прокрутка считается здесь)
fn zoom_at(mut cv vgui.Canvas, bx f32, by f32, z f32) {
	sx, sy := cv.buf_to_screen(bx, by)
	cv.set_zoom(z)
	cv.scroll_x = cv.bounds.x + bx * z - sx
	cv.scroll_y = cv.bounds.y + by * z - sy
	cv.set_zoom(z) // ограничит прокрутку краями
}

// toggle_zoom - вписан (или другой масштаб) - 100% в точку (bx, by),
// 100% - обратно «вписать». 100% - настоящие: пиксель полного кадра на
// пиксель экрана (зум холста превью zoom_one), поверх - фрагмент полного
// кадра (detail_ui.v)
fn toggle_zoom(mut cv vgui.Canvas, bx f32, by f32) {
	if !cv.auto_fit && cv.zoom == zoom_one {
		cv.fit_to_view()
	} else {
		zoom_at(mut cv, bx, by, zoom_one)
	}
}

// toggle_zoom_center - Z и пробел: 100% в центр видимой части
fn toggle_zoom_center(mut st State) {
	if isnil(st.cv) || st.linear.len == 0 {
		return
	}
	mut cv := st.cv
	cx := cv.bounds.x + cv.bounds.w / 2
	cy := cv.bounds.y + cv.bounds.h / 2
	sc := cv.screen_scale()
	bx := if sc > 0 { (cx - cv.disp_x) / sc } else { f32(cv.width) / 2 }
	by := if sc > 0 { (cy - cv.disp_y) / sc } else { f32(cv.height) / 2 }
	toggle_zoom(mut cv, bx, by)
}

// zoom_click - щелчок левой кнопкой по снимку (нажали и отпустили почти
// на месте) - toggle_zoom в эту точку; true - событие забрано
fn zoom_click(mut st State, mut cv vgui.Canvas, ev &vgui.CanvasInputEvent) bool {
	if isnil(st.cv) || st.linear.len == 0 || st.crop_mode || st.wb_pick {
		st.click_down = false
		return false
	}
	match ev.kind {
		.pointer_down {
			if ev.button == 1 && ev.in_image {
				st.click_down = true
				st.click_x = ev.fx
				st.click_y = ev.fy
			}
		}
		.pointer_up {
			if ev.button == 1 && st.click_down {
				st.click_down = false
				sc := cv.screen_scale()
				dx := (ev.fx - st.click_x) * sc
				dy := (ev.fy - st.click_y) * sc
				if dx * dx + dy * dy <= click_px * click_px {
					toggle_zoom(mut cv, st.click_x, st.click_y)
					return true
				}
			}
		}
		else {}
	}
	return false
}

// KeyWatch - невидимый виджет окна для клавиш, которым мало горячей
// клавиши: удержание «\» (нужно и отпускание - у горячих клавиш vgui
// его нет) и все настраиваемые сочетания (hk_dispatch, hotkeys.v) - по
// scancode, месту клавиши: в русской раскладке SDL отдаёт в keycode букву
// раскладки («з» вместо P), и меню vgui их не узнаёт. Добавляется в окно после корня: события
// получает раньше меню, но после виджета в фокусе (поле ввода свои
// буквы заберёт само).
@[heap]
struct KeyWatch {
mut:
	st &State = unsafe { nil }
}

// Scancode SDL (USB HID): буквы с 4 (A), «\» - 49
const sc_backslash = 49

// printable_key - клавиша печатного символа (пробел, буквы любой
// раскладки, цифры, знаки): не служебная (у стрелок и F-клавиш в
// keycode бит 1 << 30), не Esc, Enter, Tab, Backspace, Delete
fn printable_key(keycode int) bool {
	return keycode >= 32 && keycode != 127 && keycode & (1 << 30) == 0
}

fn (mut k KeyWatch) draw(mut _ vgui.RenderContext) {}

fn (mut k KeyWatch) handle_event(ev &vgui.GuiEvent, app &vgui.App) bool {
	if isnil(k.st) {
		return false
	}
	mut st := k.st
	if ev.typ == .window_focus_lost {
		set_ba_hold(mut st, false) // отпускание «\» в другом окне не придёт
		return false
	}
	if ev.typ != .key_down && ev.typ != .key_up {
		return false
	}
	// Поле ввода в фокусе: печатные клавиши - его. Буквы и цифры поле
	// получает текстом, а key_down отдаёт дальше - и меню поставило бы
	// звёзды (0..5) или флажок, пока набирают угол или пропорцию
	ctx := app.get_active_ctx()
	if ev.typ == .key_down && !isnil(ctx) && ctx.focus.wants_text()
		&& ev.mod_keys & (vgui.sdl_kmod_ctrl | vgui.sdl_kmod_alt) == 0 && printable_key(ev.keycode) {
		return true
	}
	mods := ev.mod_keys & (vgui.sdl_kmod_ctrl | vgui.sdl_kmod_alt | vgui.sdl_kmod_shift)
	if ev.scancode == sc_backslash && mods == 0 {
		set_ba_hold(mut st, ev.typ == .key_down)
		return true
	}
	// Сочетания действий (hotkeys.v) - по месту клавиши, в любой
	// раскладке; меню их уже не получает
	if ev.typ != .key_down {
		return false
	}
	return hk_dispatch(mut st, ev)
}
