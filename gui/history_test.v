module main

// Логика истории правок без окна: виджеты vgui создаются и работают без
// App, а пересчёты (apply_pipeline, load_preview, request_prep) при
// пустом State сразу выходят - проверяются только снимки и записи.
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
