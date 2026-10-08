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
import lens

// EditState - снимок всех настроек правки кадра. Из него восстанавливается
// и GUI (ползунки, чекбоксы, точки кривых), и проявка (превью, сохранение).
// В params поля curve и tc_* производные: curve - камерная кривая кадра
// при use_curve, tc_* - таблицы из curve_pts (curves_to_params).
struct EditState {
mut:
	params    pipeline.Params
	curve_pts [][]vgui.CurvePoint // точки кривых: 0 - RGB, 1..3 - R, G, B
	lens_corr bool = true // чекбокс «Коррекция объектива»
	use_curve bool = true // чекбокс «Камерная кривая»
	nr        [4]f32 // импульсный, яркостный, цветовой шумодав, ореолы (0..100)
	ai        f32    // AI-шумодав: сила 1..100, 0 - выключен (ai_nr.v)
	ai_model  string // id модели, которой посчитан AI (ai.models), при ai > 0
	// Баланс белого (wb_ui.v): режим - ключ из wb_modes ('' - «как снято»,
	// тогда температура и оттенок не используются и равны 0), температура
	// K и оттенок источника. Матрица в params.wb - производная (with_derived).
	wb_mode string
	wb_temp f32
	wb_tint f32
	// Кадрирование и поворот (crop.v): геометрия (ориентация, угол, рамка
	// в долях кадра), ограничение рамки - пропорция (ключ crop_aspects,
	// '' - свободно; своя - crop_aw:crop_ah; portrait - вертикальная).
	// Размер на выход - не кадра, а экспорта (Settings, export_setup.v)
	geom          pipeline.Geom
	crop_aspect   string
	crop_aw       int = 3
	crop_ah       int = 2
	crop_portrait bool
	// Сила коррекции виньетирования кадра «как JPEG камеры» (CamLook.vign) -
	// производное, как params.curve (with_derived), в сайдкар не пишется
	vign f32 = lens.vign_default
	// Увеличение кадра «как у камеры» после исправления дисторсии
	// (CamLook.zoom) - тоже производное, в сайдкар не пишется
	lens_zoom f32 = 1
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
	c.params.cam_hue = e.params.cam_hue.clone()
	c.params.cam_hsat = e.params.cam_hsat.clone()
	c.params.tc_rgb = e.params.tc_rgb.clone()
	c.params.tc_r = e.params.tc_r.clone()
	c.params.tc_g = e.params.tc_g.clone()
	c.params.tc_b = e.params.tc_b.clone()
	c.params.masks = e.params.masks.map(it.copy())
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
	sl  &vgui.Slider        = unsafe { nil }
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
	if st.history[st.hist_pos].state == st.edit {
		return
	}
	now := time.ticks()
	top := st.history[st.hist_pos]
	if merge && st.hist_pos > 0 && st.hist_pos == st.history.len - 1 && top.key == key
		&& key.len > 0 && st.hist_ms > 0 && now - st.hist_ms < hist_merge_ms {
		st.history[st.hist_pos] = HistEntry{
			name:  name
			key:   key
			state: st.edit.clone()
		}
	} else {
		if st.hist_pos < st.history.len - 1 {
			st.history.trim(st.hist_pos + 1)
		}
		st.history << HistEntry{
			name:  name
			key:   key
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

// Цвета строк истории - из палитры темы (themes.v): действующие правки -
// обычным текстом, отменённые («будущее», куда можно вернуться) -
// приглушённо, как в Photoshop/Lightroom; текущая запись - ярче и жирным
// (выделение списка может стоять на другой строке: одиночный щелчок
// только выделяет)

// refresh_history перестраивает список: строка на запись, текущая
// жирная и выделена, отменённые - серые; список прокручивается к текущей.
fn refresh_history(mut st State) {
	if isnil(st.hist_lb) {
		return
	}
	mut lb := st.hist_lb
	lb.clear()
	bi := ba_index(st)
	for i, e in st.history {
		// Запись «до» сравнения (compare.v), если выбрана не первая
		tag := if i == bi && bi > 0 { '  · до' } else { '' }
		mut l := vgui.label('${i + 1}. ${e.name}${tag}')
		l.color = if i == st.hist_pos {
			st.pal.text
		} else if i < st.hist_pos {
			st.pal.secondary
		} else {
			st.pal.disabled
		}
		if i == st.hist_pos {
			l.font_style = .bold
		}
		lb.add_row_widgets([l])
	}
	lb.set_selected(st.hist_pos)
	sync_ba_ui(mut st)
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
	st.edit = with_derived(e, st.look, st.cam)
	if !isnil(st.lens_cb) {
		mut cb := st.lens_cb
		cb.set_checked(e.lens_corr)
	}
	if !isnil(st.crv_cb) {
		mut cb := st.crv_cb
		cb.set_checked(e.use_curve)
	}
	if !isnil(st.sharp_rgb_cb) {
		mut cb := st.sharp_rgb_cb
		cb.set_checked(e.params.sharp.rgb)
	}
	sync_curve_editor(mut st)
	sync_wb_mode(mut st)
	sync_crop_ui(mut st)
	sync_mask_ui(mut st)
	sync_grade_ui(mut st)
}

// restore_edit - откат/возврат к снимку: виджеты (set_edit) и ровно нужные
// пересчёты. Тональные настройки - один apply (~60 мс); подготовка сырья
// (коррекция объектива, шумодав) - фоновый request_prep.
fn restore_edit(mut st State, e EditState, mut cv vgui.Canvas, mut hist vgui.Canvas, mut app vgui.App) {
	lens_changed := st.edit.lens_corr != e.lens_corr
	set_edit(mut st, e)
	if lens_changed {
		request_prep(mut st, mut app, true)
	} else if prep_stale(st) {
		request_prep(mut st, mut app, false)
	}
	// Тон - сразу по текущему сырью; готовая подготовка применит ещё раз
	apply_pipeline(mut st, mut cv, mut hist)
	// Откат к снимку с AI: результат модели в памяти - мгновенно, иначе прогон
	ai_check(mut st, mut app)
}

// goto_history - переход к записи idx (двойной щелчок или Enter в списке,
// Ctrl+Z / Ctrl+Shift+Z).
// Записи не удаляются: можно вернуться вперёд, пока не сделана новая правка.
fn goto_history(mut st State, idx int, mut cv vgui.Canvas, mut hist vgui.Canvas, mut app vgui.App) {
	if idx < 0 || idx >= st.history.len {
		return
	}
	if idx == st.hist_pos {
		refresh_history(mut st) // вернуть выделение, если список сдвинул его сам
		return
	}
	st.hist_pos = idx
	st.hist_ms = 0 // после перехода шаги не склеиваются с чужой записью
	restore_edit(mut st, st.history[idx].state, mut cv, mut hist, mut app)
	refresh_history(mut st)
	sync_sidecar(mut st)
}
