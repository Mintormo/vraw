module main

// Логика истории правок и сайдкара без окна: виджеты vgui создаются и работают без
// App, а пересчёты (apply_pipeline, load_preview, request_prep) при
// пустом State сразу выходят - проверяются только снимки и записи.
import os
import vgui

// new_state - State с двумя ползунками (экспозиция, яркостный шумодав)
// и списком истории, как в main; открыт «файл» (запись «Открыт файл»).
fn new_state() (&State, &vgui.Slider, &vgui.Slider) {
	mut st := &State{}
	st.edit = neutral_edit()
	noop := fn () {}
	exp := edit_slider(mut st, SliderCfg{
		label: 'Экспозиция'
		min:   -4
		max:   4
		get:   fn (e &EditState) f32 {
			return e.params.exposure
		}
		set:   fn (mut e EditState, v f32) {
			e.params.exposure = v
		}
		fx:    noop
	})
	nrl := edit_slider(mut st, SliderCfg{
		label:  'Яркостный'
		hname:  'Шумодав: яркостный'
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.nr[1]
		}
		set:    fn (mut e EditState, v f32) {
			e.nr[1] = v
		}
		fx:     noop
	})
	st.hist_lb = vgui.list_box()
	st.lens_cb = vgui.checkbox('')
	st.crv_cb = vgui.checkbox('')
	start_history(mut st)
	return st, exp.sl, nrl.sl
}

// drag имитирует перетаскивание: on_change при dragging, затем on_release
fn drag(mut sl vgui.Slider, v f32) {
	sl.dragging = true
	sl.set_value(v)
	sl.dragging = false
	sl.on_release(v)
}

fn jump(mut st State, idx int) {
	mut cv := vgui.canvas(4, 3)
	mut hist := vgui.canvas(4, 3)
	mut nm := vgui.notification_manager_at(.top_left)
	mut app := &vgui.App{}
	goto_history(mut st, idx, mut cv, mut hist, mut nm, mut app)
}

fn names(st &State) []string {
	return st.history.map(it.name)
}

fn test_drag_is_one_entry() {
	mut st, mut exp, _ := new_state()
	drag(mut exp, 0.7)
	assert names(st) == ['Открыт файл', 'Экспозиция +0.70']
	assert st.hist_pos == 1
	assert st.hist_lb.row_count() == 2
	assert st.hist_lb.selected == 1
	// Отпускание без изменения значения - не правка
	exp.on_release(0.7)
	assert st.history.len == 2
}

fn test_steps_merge() {
	mut st, mut exp, mut nrl := new_state()
	// Колесо/клавиши: одиночные on_change подряд - одна запись
	exp.set_value(0.1)
	exp.set_value(0.2)
	exp.set_value(0.3)
	assert names(st) == ['Открыт файл', 'Экспозиция +0.30']
	// Другой ползунок - своя запись; шаги после него не склеиваются
	// с экспозицией
	nrl.set_value(40)
	exp.set_value(0.4)
	assert names(st) == ['Открыт файл', 'Экспозиция +0.30', 'Шумодав: яркостный 40',
		'Экспозиция +0.40']
	// Перетаскивание не склеивается с шагами
	drag(mut exp, -1.0)
	assert st.history.len == 5
	assert st.history[4].name == 'Экспозиция -1.00'
}

fn test_undo_redo_and_truncate() {
	mut st, mut exp, mut nrl := new_state()
	drag(mut exp, 1.0)
	drag(mut nrl, 30)
	drag(mut exp, 2.0)
	assert st.history.len == 4
	// Откат на две записи: ползунки и снимок вернулись
	jump(mut st, 1)
	assert st.hist_pos == 1
	assert exp.value == 1.0
	assert nrl.value == 0
	assert st.edit.params.exposure == 1.0
	assert st.edit.nr[1] == 0
	assert st.history.len == 4 // «будущее» не удалено
	// Вперёд
	jump(mut st, 3)
	assert exp.value == 2.0
	assert nrl.value == 30
	// Откат к открытию и новая правка - будущее отрезано
	jump(mut st, 0)
	assert exp.value == 0
	assert st.edit == st.history[0].state
	drag(mut nrl, 10)
	assert names(st) == ['Открыт файл', 'Шумодав: яркостный 10']
	assert st.hist_pos == 1
}

fn test_step_after_undo_not_merged() {
	mut st, mut exp, _ := new_state()
	exp.set_value(0.5)
	exp.set_value(0.6)
	assert st.history.len == 2
	jump(mut st, 0)
	// Шаг сразу после отката - новая запись, а не замена чужой
	exp.set_value(0.1)
	assert names(st) == ['Открыт файл', 'Экспозиция +0.10']
	jump(mut st, 1)
	jump(mut st, 0)
	jump(mut st, 1)
	exp.set_value(0.2)
	assert st.history.len == 3
}

fn test_snapshot_is_deep() {
	mut st, _, _ := new_state()
	st.edit.curve_pts[1] = [vgui.CurvePoint{0, 0}, vgui.CurvePoint{0.5, 0.7},
		vgui.CurvePoint{1, 1}]
	curves_to_params(mut st)
	record(mut st, 'curve1', 'Кривая R', false)
	assert st.history.len == 2
	assert st.edit.params.tc_r.len == 256
	// Правка живого состояния не меняет снимки
	st.edit.curve_pts[1] = identity_curve()
	assert st.history[1].state.curve_pts[1].len == 3
	assert st.history[0].state.curve_pts[1].len == 2
	// Откат к открытию восстанавливает кривую и таблицы
	jump(mut st, 1)
	jump(mut st, 0)
	assert st.edit.curve_pts[1].len == 2
	assert st.edit.params.tc_r.len == 0
	jump(mut st, 1)
	assert st.edit.curve_pts[1].len == 3
	assert st.edit.params.tc_r.len == 256
}

fn test_checkbox_restore() {
	mut st, _, _ := new_state()
	st.edit.lens_corr = false
	record(mut st, 'lens', 'Коррекция объектива: ${on_off(false)}', false)
	jump(mut st, 0)
	assert st.edit.lens_corr
	assert st.lens_cb.checked
	jump(mut st, 1)
	assert !st.edit.lens_corr
	assert !st.lens_cb.checked
}

fn test_auto_label() {
	mut st, mut exp, _ := new_state()
	st.hist_label = 'Авто-экспозиция ${fmt_signed(1.234, 2)}'
	exp.set_value(1.234)
	st.hist_label = ''
	// Следующий шаг колесом - отдельной записью
	exp.set_value(1.3)
	assert names(st) == ['Открыт файл', 'Авто-экспозиция +1.23', 'Экспозиция +1.30']
}

fn test_no_history_without_file() {
	mut st := &State{}
	st.edit = neutral_edit()
	record(mut st, 'x', 'x', false)
	assert st.history.len == 0
}

// ── Сайдкар ──

fn side_tmp(name string) string {
	dir := os.join_path(os.temp_dir(), 'vraw_sidecar_test')
	os.mkdir_all(dir) or {}
	path := os.join_path(dir, name + sidecar_ext)
	os.rm(path) or {}
	return path
}

fn test_no_file_without_edits() {
	mut st, _, _ := new_state()
	st.side_path = side_tmp('noedit')
	sync_sidecar(mut st)
	assert !os.exists(st.side_path)
	loaded := load_sidecar(st.side_path)!
	assert loaded.history.len == 0
}

fn test_roundtrip() {
	mut st, mut exp, mut nrl := new_state()
	st.side_path = side_tmp('roundtrip')
	drag(mut exp, 0.75)
	assert os.exists(st.side_path) // записан после первой же правки
	drag(mut nrl, 35)
	st.edit.curve_pts[2] = [vgui.CurvePoint{0, 0.1}, vgui.CurvePoint{0.4, 0.5},
		vgui.CurvePoint{1, 1}]
	st.edit.params.hsl_sat[3] = -40
	st.edit.params.eq[4] = 1.5
	st.edit.highlight = 5
	st.edit.lens_corr = false
	curves_to_params(mut st)
	record(mut st, 'mix', 'Разное', false)
	jump(mut st, 2) // откат - позиция тоже в файле
	assert !os.exists(st.side_path + '.tmp')

	text := os.read_file(st.side_path)!
	assert text.contains('"app": "vraw"')
	assert text.contains('Шумодав: яркостный 35')
	loaded := load_sidecar(st.side_path)!
	assert loaded.current == 2
	assert loaded.history.map(it.name) == ['Открыт файл', 'Экспозиция +0.75',
		'Шумодав: яркостный 35', 'Разное']
	// Снимки совпадают с исходными (с производными полями - как в живом State)
	for i, h in loaded.history {
		assert with_derived(h.state, st.curve) == st.history[i].state
	}
	last := loaded.history[3].state
	assert last.curve_pts[2].len == 3
	assert last.params.hsl_sat[3] == -40
	assert last.params.eq[4] == 1.5
	assert last.highlight == 5
	assert !last.lens_corr
	assert last.nr[1] == 35
	assert last.params.exposure == 0.75
}

fn test_loaded_history_no_spurious_record() {
	mut st, mut exp, _ := new_state()
	st.side_path = side_tmp('reload')
	drag(mut exp, 1.25)
	loaded := load_sidecar(st.side_path)!

	// «Повторное открытие»: история из файла, как в open_file
	mut st2, mut exp2, _ := new_state()
	st2.history = loaded.history.map(HistEntry{
		name:  it.name
		key:   it.key
		state: with_derived(it.state, st2.curve)
	})
	st2.hist_pos = loaded.current
	jump(mut st2, 0)
	jump(mut st2, 1)
	assert exp2.value == 1.25
	// Отпускание без изменения - не правка (снимки из файла сравнимы с живым)
	exp2.on_release(1.25)
	assert st2.history.len == 2
}

fn test_broken_files() {
	path := side_tmp('broken')
	os.write_file(path, '{ не json')!
	if _ := load_sidecar(path) {
		assert false, 'испорченный JSON принят'
	}
	os.write_file(path, '{"app": "other", "version": 1, "current": 0, "history": []}')!
	if _ := load_sidecar(path) {
		assert false, 'чужой файл принят'
	}
	// Неверные размеры массивов - ошибка, а не выход за границы
	mut st, mut exp, _ := new_state()
	st.side_path = path
	os.rm(path)!
	drag(mut exp, 0.5)
	text := os.read_file(path)!
	os.write_file(path, text.replace('"nr": [', '"nr": [1, '))!
	if _ := load_sidecar(path) {
		assert false, 'неверный размер nr принят'
	}
}

// ── Браузер папки ──

fn test_thumb_order() {
	assert thumb_order(0, 0) == []int{}
	assert thumb_order(1, 0) == [0]
	assert thumb_order(5, 2) == [2, 3, 1, 4, 0]
	assert thumb_order(4, 0) == [0, 1, 2, 3]
	assert thumb_order(4, 3) == [3, 2, 1, 0]
	assert thumb_order(3, -1) == [0, 1, 2] // кадр не найден - с начала
}

fn test_scan_folder() {
	dir := os.join_path(os.temp_dir(), 'vraw_scan_test')
	os.rmdir_all(dir) or {}
	os.mkdir_all(os.join_path(dir, 'sub.CR3'))! // папка с «RAW»-именем - не кадр
	for n in ['b.CR3', 'a.cr3', 'c.NEF', 'x.jpg', 'a.cr3.vraw.json'] {
		os.write_file(os.join_path(dir, n), '')!
	}
	got := scan_folder(dir).map(os.file_name(it))
	assert got == ['a.cr3', 'b.CR3', 'c.NEF']
	os.rmdir_all(dir) or {}
}

// pixel - цвет точки (x, y) RGBA-буфера ширины w
fn pixel(buf []u8, w int, x int, y int) []u8 {
	k := (y * w + x) * 4
	return buf[k..k + 3]
}

// Источник 4x2: левая половина красная, правая синяя, верхний левый
// пиксель - белый (метка ориентации)
fn sample_src() []u8 {
	mut s := []u8{len: 4 * 2 * 3}
	for y in 0 .. 2 {
		for x in 0 .. 4 {
			k := (y * 4 + x) * 3
			if x < 2 {
				s[k] = 200
			} else {
				s[k + 2] = 200
			}
		}
	}
	s[0], s[1], s[2] = 255, 255, 255
	return s
}

fn test_fit_thumb_plain_and_letterbox() {
	// 4x2 в буфер 8x8: масштаб 2, картинка 8x4 по центру (поля сверху/снизу)
	out := fit_thumb(sample_src(), 4, 2, 0, 8, 8)
	assert out.len == 8 * 8 * 4
	assert pixel(out, 8, 0, 0) == [thumb_bg.r, thumb_bg.g, thumb_bg.b] // поле
	assert pixel(out, 8, 0, 2) == [u8(255), 255, 255] // метка - левый верх картинки
	assert pixel(out, 8, 7, 5) == [u8(0), 0, 200] // правая половина синяя
	assert out[3] == 255 // альфа
}

fn test_fit_thumb_rotations() {
	// 180°: метка уходит в правый нижний угол картинки
	r3 := fit_thumb(sample_src(), 4, 2, 3, 4, 2)
	assert pixel(r3, 4, 3, 1) == [u8(255), 255, 255]
	assert pixel(r3, 4, 0, 0) == [u8(0), 0, 200]
	// 90° по часовой (flip 6): картинка 2x4, метка - правый верх,
	// красная (левая) половина источника - сверху
	r6 := fit_thumb(sample_src(), 4, 2, 6, 2, 4)
	assert pixel(r6, 2, 1, 0) == [u8(255), 255, 255]
	assert pixel(r6, 2, 0, 1) == [u8(200), 0, 0]
	assert pixel(r6, 2, 0, 3) == [u8(0), 0, 200]
	// 90° против часовой (flip 5): метка - левый низ, красное - снизу
	r5 := fit_thumb(sample_src(), 4, 2, 5, 2, 4)
	assert pixel(r5, 2, 0, 3) == [u8(255), 255, 255]
	assert pixel(r5, 2, 1, 2) == [u8(200), 0, 0]
	assert pixel(r5, 2, 1, 0) == [u8(0), 0, 200]
}

fn test_fit_thumb_downscale_averages() {
	// 4x2 -> 2x1: каждый пиксель - среднее блока 2x2
	out := fit_thumb(sample_src(), 4, 2, 0, 2, 1)
	// левый блок: белый + 3 красных = (255+600)/4, 255/4, 255/4
	assert pixel(out, 2, 0, 0) == [u8(213), 63, 63]
	assert pixel(out, 2, 1, 0) == [u8(0), 0, 200]
}

fn test_make_thumb_real() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		return
	}
	pix := make_thumb(path)!
	assert pix.len == thumb_w * thumb_h * 4
	// Кадр 3:2 заполняет буфер 3:2 целиком - полей нет, угол не фон
	assert pixel(pix, thumb_w, 0, 0) != [thumb_bg.r, thumb_bg.g, thumb_bg.b]
}
