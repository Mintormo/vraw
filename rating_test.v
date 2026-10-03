module main

// Отбор (rating.v) и до/после (compare.v) без окна: пометки в сайдкарах
// во временной папке, лента - ListBox без App, холст - без отрисовки
// (поля вида задаются руками).
import os
import vgui

fn rt_dir(name string) string {
	dir := os.join_path(os.temp_dir(), 'vraw_rating_test', name)
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

// rt_folder - State с лентой из n «кадров» (файлы-пустышки: LibRaw не
// нужен - пометки живут только в сайдкарах)
fn rt_folder(dir string, n int) &State {
	mut st := &State{}
	st.edit = neutral_edit()
	mut strip := vgui.list_box_h(100)
	strip.multi_select = true
	st.strip = strip
	for i in 0 .. n {
		p := os.join_path(dir, 'IMG_${i}.CR3')
		os.write_file(p, 'raw') or { panic(err) }
		st.frames << Frame{
			path: p
			cell: vgui.create_vbox_fill()
		}
	}
	apply_filter(mut st)
	return st
}

fn test_mark_passes() {
	blank := Mark{}
	pick3 := Mark{3, 1}
	rej5 := Mark{5, -1}
	assert mark_passes(blank, 'all') && mark_passes(rej5, 'all')
	assert mark_passes(pick3, 'picked') && !mark_passes(blank, 'picked')
	assert mark_passes(blank, 'unrejected') && !mark_passes(rej5, 'unrejected')
	assert mark_passes(rej5, 'rejected') && !mark_passes(pick3, 'rejected')
	assert mark_passes(pick3, 'r3') && !mark_passes(pick3, 'r4') && mark_passes(rej5, 'r5')
	assert !mark_passes(blank, 'r1')
	assert filter_keys.len == filter_names.len
	assert mark_text(Mark{}) == ''
	assert mark_text(Mark{1, 0}) == '1 звезда'
	assert mark_text(Mark{5, -1}) == '5 звёзд, отклонён'
}

// Пометка в сайдкаре: запись и чтение, быстрое начало файла, старый
// формат («current» после настроек) - полным разбором
fn test_side_mark_roundtrip() {
	dir := rt_dir('roundtrip')
	raw_path := os.join_path(dir, 'A.CR3')
	side := sidecar_path(raw_path)
	// Нет сайдкара - нет пометки; снятая пометка сайдкар не создаёт
	assert read_side_head(raw_path) == SideHead{}
	write_mark(raw_path, Mark{})!
	assert !os.exists(side)
	// Пометка неоткрытого кадра - новый сайдкар с «Открыт файл»
	write_mark(raw_path, Mark{4, 1})!
	l := load_sidecar(side)!
	assert l.mark == Mark{4, 1}
	assert l.history.len == 1 && l.history[0].name == 'Открыт файл'
	h := read_side_head(raw_path)
	assert h.mark == Mark{4, 1} && !h.edited
	// Правка - пометка сохраняется, «изменён» - по current
	mut e := neutral_edit()
	e.params.exposure = 1
	hist := [l.history[0], HistEntry{
		name:  'Экспозиция'
		state: e
	}]
	write_atomic(side, encode_history(hist, 1, Mark{2, -1}))!
	h2 := read_side_head(raw_path)
	assert h2.mark == Mark{2, -1} && h2.edited
	// Быстрое чтение: пометка и позиция - в первых строках файла
	text := os.read_file(side)!
	assert text.index('"rating"')? < 100 && text.index('"current"')? < 100
	// write_mark не трогает историю
	write_mark(raw_path, Mark{5, 0})!
	l2 := load_sidecar(side)!
	assert l2.mark == Mark{5, 0} && l2.current == 1 && l2.history.len == 2
	assert l2.history[1].state.params.exposure == 1
	// Старый файл: «current» далеко - полный разбор; без пометки - нули
	old := os.read_file(side)!.replace('"rating": 5,', '').replace('"flag": 0,', '').replace('"current": 1,',
		'')
	os.write_file(side, old.replace('"history":', '"current": 1,\n  "history":'))!
	h3 := read_side_head(raw_path)
	assert h3.mark == Mark{} && h3.edited
	// Мусор вместо пометки - в пределах
	assert clamp_mark(9, -7) == Mark{5, -1}
	if _ := head_int('"rating": 12', 'rating') {
		assert false // число у края прочитанного - не верим
	}
	assert head_int('"rating": 3,', 'rating')? == 3
	assert head_int('"flag": -1,', 'flag')? == -1
}

// Вставка настроек в неоткрытый кадр пометку не теряет
fn test_paste_keeps_mark() {
	dir := rt_dir('paste')
	raw_path := os.join_path(dir, 'B.CR3')
	write_mark(raw_path, Mark{3, 1})!
	mut src := neutral_edit()
	src.params.exposure = 0.5
	assert paste_to_file(raw_path, src, ['tone'], 'Вставка')!
	assert load_sidecar(sidecar_path(raw_path))!.mark == Mark{3, 1}
}

// Открытый кадр: пометка без правок создаёт сайдкар (одна запись)
fn test_open_frame_mark_sidecar() {
	dir := rt_dir('open')
	mut st := rt_folder(dir, 3)
	st.frame_idx = 1
	st.side_path = sidecar_path(st.frames[1].path)
	start_history(mut st)
	sync_sidecar(mut st)
	assert !os.exists(st.side_path) // без правок и пометки - нет файла
	set_rating(mut st, 3)
	assert st.mark == Mark{3, 0}
	assert st.frames[1].mark == Mark{3, 0}
	assert load_sidecar(st.side_path)!.mark == Mark{3, 0}
	assert !st.frames[1].edited // пометка - не правка
	set_flag(mut st, -1)
	assert load_sidecar(st.side_path)!.mark == Mark{3, -1}
}

// Выделенные в ленте - пометка им, а не открытому; фильтр, строки,
// соседи, экспорт «по фильтру»
fn test_marks_filter_strip() {
	dir := rt_dir('filter')
	mut st := rt_folder(dir, 5)
	st.frame_idx = 0
	st.side_path = sidecar_path(st.frames[0].path)
	start_history(mut st)
	assert st.shown == [0, 1, 2, 3, 4]
	mut strip := st.strip
	strip.set_selection([1, 3])
	set_flag(mut st, 1)
	assert st.frames[1].mark.flag == 1 && st.frames[3].mark.flag == 1
	assert st.frames[0].mark.flag == 0
	assert read_side_head(st.frames[3].path).mark.flag == 1
	// Фильтр «отобранные»: строки - кадры 1 и 3
	set_filter(mut st, 'picked')
	assert st.shown == [1, 3]
	assert row_of(st, 3) == 1 && row_of(st, 0) == -1
	assert frame_of_row(st, 1) == 3 && frame_of_row(st, 5) == -1
	assert st.strip.rows.len == 2
	// Соседи - среди кадров фильтра (открытый может в него не входить)
	assert next_shown(st, 0, 1) == 1
	assert next_shown(st, 1, 1) == 3
	assert next_shown(st, 3, 1) == -1
	assert next_shown(st, 2, -1) == 1
	// Выделение ленты - строки; кадры - через фильтр
	strip.set_selection([1])
	assert strip_selection(st) == [3]
	assert export_target_paths(st, 'shown') == [st.frames[1].path, st.frames[3].path]
	assert export_target_paths(st, 'all').len == 5
	// Пометка выпадает из фильтра - строки пересобраны
	set_flag(mut st, 0) // выделен кадр 3
	assert st.shown == [1]
	set_filter(mut st, 'all')
	assert st.shown.len == 5
	// Лента читает пометки при открытии папки
	assert read_side_head(st.frames[1].path).mark.flag == 1
}

// RtLog - переходы к кадрам (замыкание захватывает значения копией -
// список по указателю)
@[heap]
struct RtLog {
mut:
	v []int
}

// «Переходить к следующему»: после пометки открытого - следующий кадр
// фильтра
fn test_auto_advance() {
	dir := rt_dir('advance')
	mut st := rt_folder(dir, 4)
	st.frame_idx = 1
	st.side_path = sidecar_path(st.frames[1].path)
	start_history(mut st)
	mut log := &RtLog{}
	st.goto_frame = fn [mut log] (i int) {
		log.v << i
	}
	set_rating(mut st, 2)
	assert log.v.len == 0 // флажок выключен
	st.settings.auto_advance = true
	set_rating(mut st, 3)
	assert log.v == [2]
	// Выделен другой кадр - пометка ему, без перехода
	mut strip := st.strip
	strip.set_selection([0, 3])
	set_rating(mut st, 1)
	assert log.v == [2]
}

// Шторка: «до» левее линии, «после» правее; удержание - всё «до»
fn test_ba_compose() {
	mut st := &State{}
	st.gw = 4
	st.gh = 2
	st.ba_before = []u8{len: 32, init: 10}
	st.ba_after = []u8{len: 32, init: 200}
	mut cv := vgui.canvas(4, 2)
	st.ba_split = true
	st.ba_pos = 0.5
	ba_compose(mut st, mut cv)
	for y in 0 .. 2 {
		for x in 0 .. 4 {
			v := cv.pixels[(y * 4 + x) * 4]
			assert v == if x < 2 { u8(10) } else { u8(200) }
		}
	}
	st.ba_pos = 0
	ba_compose(mut st, mut cv)
	assert cv.pixels.all(it == 200)
	st.ba_hold = true
	ba_compose(mut st, mut cv)
	assert cv.pixels.all(it == 10)
	// Не тот размер буферов - холст не трогается
	st.ba_after = []u8{len: 8}
	cv.pixels = []u8{len: 32, init: 7}
	ba_compose(mut st, mut cv)
	assert cv.pixels.all(it == 7)
}

// Увеличение в точку: точка буфера остаётся на месте экрана; повторно -
// «вписать»
fn test_zoom_at_point() {
	mut cv := vgui.canvas(2000, 1000)
	cv.bounds = vgui.Rect{100, 50, 800, 600}
	// Вписан: 800 / 2000 = 0.4, по вертикали поля
	cv.disp_x = 100
	cv.disp_y = f32(50 + (600 - 400) / 2)
	cv.disp_w = 800
	cv.disp_h = 400
	sx, sy := cv.buf_to_screen(1500, 400)
	toggle_zoom(mut cv, 1500, 400)
	// 100% - настоящие: пиксель полного кадра (зум превью half-size - 2)
	assert !cv.auto_fit && cv.zoom == zoom_one
	// Точка (1500, 400) после 100% - там же на экране
	nx := cv.bounds.x - cv.scroll_x + 1500 * zoom_one
	ny := cv.bounds.y - cv.scroll_y + 400 * zoom_one
	assert nx == sx && ny == sy
	toggle_zoom(mut cv, 0, 0)
	assert cv.auto_fit
}

// Клавиши: удержание «\» - «до» и обратно; P в русской раскладке
// (keycode «з») - по месту клавиши
fn test_key_watch() {
	dir := rt_dir('keys')
	mut st := rt_folder(dir, 2)
	st.frame_idx = 0
	st.side_path = sidecar_path(st.frames[0].path)
	start_history(mut st)
	mut k := &KeyWatch{
		st: st
	}
	app := &vgui.App{}
	assert k.handle_event(&vgui.GuiEvent{ typ: .key_down, keycode: `\\`, scancode: sc_backslash },
		app)
	assert st.ba_hold
	assert k.handle_event(&vgui.GuiEvent{ typ: .key_up, keycode: `\\`, scancode: sc_backslash },
		app)
	assert !st.ba_hold
	// Латинская P - дело меню, KeyWatch не трогает
	assert !k.handle_event(&vgui.GuiEvent{ typ: .key_down, keycode: `p`, scancode: 19 }, app)
	assert st.frames[0].mark.flag == 0
	// Русская раскладка: «з» на месте P
	assert k.handle_event(&vgui.GuiEvent{ typ: .key_down, keycode: 0x437, scancode: 19 }, app)
	assert st.frames[0].mark.flag == 1
	// С Ctrl - не наше
	assert !k.handle_event(&vgui.GuiEvent{
		typ:      .key_down
		keycode:  0x447
		scancode: 27
		mod_keys: vgui.sdl_kmod_ctrl
	}, app)
	assert st.frames[0].mark.flag == 1
	// Окно потеряло фокус при зажатой «\» - «до» снимается
	k.handle_event(&vgui.GuiEvent{ typ: .key_down, scancode: sc_backslash }, app)
	k.handle_event(&vgui.GuiEvent{ typ: .window_focus_lost }, app)
	assert !st.ba_hold
}
