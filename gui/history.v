module main

// Неразрушающее редактирование и история правок.
//
// RAW-файл никогда не меняется: всё состояние правки кадра - это EditState
// (тональные параметры, точки кривых, подготовка сырья, чекбоксы). Каждая
// завершённая правка (отпускание ползунка, точки кривой, чекбокс, «Авто»,
// «Сброс») кладёт в историю запись «название + снимок». Откат - это
// restore_edit(снимок): виджеты выставляются под st.suppress, дальше ровно
// те пересчёты, которые нужны (apply / подготовка сырья / перепроявка).
import math
import time
import vgui
import pipeline

// EditState - снимок всех настроек правки кадра. Из него восстанавливается
// и GUI (ползунки, чекбоксы, точки кривых), и проявка (превью, сохранение).
// В params поля curve и tc_* производные: curve - камерная кривая кадра
// при use_curve, tc_* - таблицы из curve_pts (curves_to_params).
struct EditState {
mut:
	params    pipeline.Params
	curve_pts [][]vgui.CurvePoint // точки кривых: 0 - RGB, 1..3 - R, G, B
	highlight int                 // режим пересветов LibRaw (0..9), смена - перепроявка
	lens_corr bool = true         // чекбокс «Коррекция объектива»
	use_curve bool = true         // чекбокс «Камерная кривая»
	nr        [4]f32              // импульсный, яркостный, цветовой шумодав, ореолы (0..100)
}

// neutral_edit - настройки только что открытого файла (запись «Открыт файл»)
fn neutral_edit() EditState {
	return EditState{
		curve_pts: [][]vgui.CurvePoint{len: 4, init: identity_curve()}
	}
}

// clone - глубокая копия: снимок в истории не должен делить массивы с
// живым состоянием (st.edit.curve_pts[ch] = ... меняет внешний массив на месте).
fn (e EditState) clone() EditState {
	mut c := e
	c.params.curve = e.params.curve.clone()
	c.params.tc_rgb = e.params.tc_rgb.clone()
	c.params.tc_r = e.params.tc_r.clone()
	c.params.tc_g = e.params.tc_g.clone()
	c.params.tc_b = e.params.tc_b.clone()
	c.curve_pts = [][]vgui.CurvePoint{}
	for pts in e.curve_pts {
		c.curve_pts << pts.clone()
	}
	return c
}

// HistEntry - запись истории: название для списка и снимок ПОСЛЕ правки
struct HistEntry {
	name  string
	key   string // источник правки (ползунок, кривая...): для склейки шагов
	state EditState
}

// SliderBind - ползунок и его значение в снимке: по списку st.binds
// откат выставляет все ползунки панели.
struct SliderBind {
	sl  &vgui.Slider = unsafe { nil }
	get fn (&EditState) f32 = unsafe { nil }
}

// Шаги одного ползунка колесом или клавишами (каждый - отдельный
// on_change без on_release) склеиваются в одну запись, если идут
// подряд чаще этого интервала.
const hist_merge_ms = i64(1500)

// fmt_signed - число со знаком для названий в истории: «+0.70», «-20»
fn fmt_signed(v f32, digits int) string {
	s := if digits == 0 { '${int(math.round(v))}' } else { '${v:.2f}' }
	return if v > 0 { '+' + s } else { s }
}

fn on_off(v bool) string {
	return if v { 'вкл' } else { 'выкл' }
}

// record добавляет в историю завершённую правку (текущий st.edit).
// merge - одиночный шаг (колесо, клавиши): подряд идущие шаги того же
// источника заменяют последнюю запись, а не плодят сотню. Новая правка
// после отката отрезает «будущие» записи. Правка без изменений (отпустили
// ползунок на том же значении) не записывается.
fn record(mut st State, key string, name string, merge bool) {
	if st.suppress || st.history.len == 0 {
		return
	}
	mut label := name
	mut hkey := key
	mut can_merge := merge
	if st.hist_label.len > 0 {
		// Особое название (кнопка «Авто») - отдельной записью, и следующие
		// шаги того же ползунка к ней не приклеиваются (ключа нет)
		label = st.hist_label
		hkey = ''
		can_merge = false
	}
	if st.history[st.hist_pos].state == st.edit {
		return
	}
	now := time.ticks()
	top := st.history[st.hist_pos]
	if can_merge && st.hist_pos > 0 && st.hist_pos == st.history.len - 1 && top.key == hkey
		&& hkey.len > 0 && st.hist_ms > 0 && now - st.hist_ms < hist_merge_ms {
		st.history[st.hist_pos] = HistEntry{
			name:  label
			key:   hkey
			state: st.edit.clone()
		}
	} else {
		if st.hist_pos < st.history.len - 1 {
			st.history.trim(st.hist_pos + 1)
		}
		st.history << HistEntry{
			name:  label
			key:   hkey
			state: st.edit.clone()
		}
		st.hist_pos = st.history.len - 1
	}
	st.hist_ms = now
	refresh_history(mut st)
	sync_sidecar(mut st)
}

// start_history - новая история файла: одна запись «Открыт файл»
fn start_history(mut st State) {
	st.history = [HistEntry{
		name:  'Открыт файл'
		state: st.edit.clone()
	}]
	st.hist_pos = 0
	st.hist_ms = 0
	refresh_history(mut st)
}

// Цвета строк истории: действующие правки и отменённые («будущее»,
// куда можно вернуться) - приглушённо, как в Photoshop/Lightroom
const hist_color = vgui.Color{220, 220, 224, 255}
const hist_future_color = vgui.Color{110, 110, 116, 255}

// refresh_history перестраивает список: строка на запись, текущая
// выделена, отменённые - серые; список прокручивается к текущей.
fn refresh_history(mut st State) {
	if isnil(st.hist_lb) {
		return
	}
	mut lb := st.hist_lb
	lb.clear()
	for i, e in st.history {
		mut l := vgui.label('${i + 1}. ${e.name}')
		l.color = if i <= st.hist_pos { hist_color } else { hist_future_color }
		lb.add_row_widgets([l])
	}
	lb.set_selected(st.hist_pos)
	// Прокрутка к текущей записи (ensure_visible у ListBox приватный)
	view_h := lb.bounds.h - 2 * lb.pad
	if view_h > 0 {
		top := f32(st.hist_pos) * lb.item_height
		if top < lb.scroll_y {
			lb.scroll_y = top
		} else if top + lb.item_height > lb.scroll_y + view_h {
			lb.scroll_y = top + lb.item_height - view_h
		}
	}
}

// set_edit выставляет снимок в State и во все виджеты правки - без
// пересчётов: ползунки через set_value под st.suppress (их on_change
// обновляют st.edit и подписи), чекбоксы напрямую (set_checked
// on_change не зовёт), кривые - точки + таблицы + редактор.
fn set_edit(mut st State, e EditState) {
	st.suppress = true
	for b in st.binds {
		mut sl := b.sl
		sl.set_value(b.get(&e))
	}
	st.suppress = false
	st.edit = with_derived(e, st.curve)
	if !isnil(st.lens_cb) {
		mut cb := st.lens_cb
		cb.set_checked(e.lens_corr)
	}
	if !isnil(st.crv_cb) {
		mut cb := st.crv_cb
		cb.set_checked(e.use_curve)
	}
	sync_curve_editor(mut st)
}

// restore_edit - откат/возврат к снимку: виджеты (set_edit) и ровно нужные
// пересчёты. Тональные настройки - один apply (~60 мс); подготовка сырья
// (коррекция объектива, шумодав) - фоновый request_prep; другой режим
// пересветов - перепроявка превью (она же запустит подготовку).
fn restore_edit(mut st State, e EditState, mut cv vgui.Canvas, mut hist vgui.Canvas, mut nm vgui.NotificationManager, mut app vgui.App) {
	lens_changed := st.edit.lens_corr != e.lens_corr
	set_edit(mut st, e)
	if st.edit.highlight != st.hl_developed {
		load_preview(mut st, mut cv, mut hist, mut nm, mut app, true)
	} else if lens_changed {
		request_prep(mut st, mut app, true)
	} else if st.nr_applied != st.edit.nr {
		request_prep(mut st, mut app, false)
	}
	// Тон - сразу по текущему сырью; готовая подготовка применит ещё раз
	apply_pipeline(mut st, mut cv, mut hist)
}

// goto_history - переход к записи idx (клик по списку, Ctrl+Z / Ctrl+Shift+Z).
// Записи не удаляются: можно вернуться вперёд, пока не сделана новая правка.
fn goto_history(mut st State, idx int, mut cv vgui.Canvas, mut hist vgui.Canvas, mut nm vgui.NotificationManager, mut app vgui.App) {
	if idx < 0 || idx >= st.history.len {
		return
	}
	if idx == st.hist_pos {
		refresh_history(mut st) // вернуть выделение, если список сдвинул его сам
		return
	}
	st.hist_pos = idx
	st.hist_ms = 0 // после перехода шаги не склеиваются с чужой записью
	restore_edit(mut st, st.history[idx].state, mut cv, mut hist, mut nm, mut app)
	refresh_history(mut st)
	sync_sidecar(mut st)
}
