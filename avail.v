module main

import vgui

// Доступность элементов интерфейса: пункт меню или виджет панели активен,
// только когда им можно что-то сделать. Пункты меню - со своим условием
// (Need, avail_add); панель правки без кадра - неактивна целиком
// (set_panel_live). Пересчёт - sync_avail после смены состояния: кадр
// открыт, загружен, закрыт; история; выделение в ленте; буфер настроек;
// сравнение; меню пресетов. Неактивный пункт не срабатывает и по
// горячей клавише (hk_fire).

// Need - условие доступности пункта меню
enum Need {
	frame  // открыт кадр (и пока загружается): правки, вид снимка
	pixels // превью кадра готово: автотон, пипетка, кадрирование, пятна
	target // есть что пометить: выделенные в ленте или открытый кадр
	frames // в ленте есть кадры
	export // идёт экспорт (снова его диалог) или есть что проявить
	undo
	redo
	paste  // настройки скопированы и есть куда вставить (presets.v)
	preset // есть куда применить пресет: открытый кадр или выделенные
	pair   // сравнение: включено или есть второй кадр
	swap   // сравнение включено
	mask   // у кадра есть градиентные фильтры (или заливка уже включена)
}

// AvailItem - пункт меню и его условие
struct AvailItem {
	item &vgui.MenuItem
	need Need
}

// frame_open - кадр открыт: загружается или загружен (во время загрузки
// ползунки пишут настройки и историю - loader.v). Не открылся - false.
fn frame_open(st &State) bool {
	return st.raw_path.len > 0 && (st.loading || !isnil(st.dev))
}

// frame_ready - превью кадра готово (сырьё пайплайна в памяти)
fn frame_ready(st &State) bool {
	return frame_open(st) && !st.loading && st.linear.len > 0
}

fn need_met(st &State, n Need) bool {
	return match n {
		.frame { frame_open(st) }
		.pixels { frame_ready(st) }
		.target { mark_targets(st).len > 0 }
		.frames { st.frames.len > 0 }
		.export { !isnil(st.exp) || frame_open(st) || st.frames.len > 0 }
		.undo { frame_open(st) && st.hist_pos > 0 }
		.redo { frame_open(st) && st.hist_pos < st.history.len - 1 }
		.paste { st.clip_groups.len > 0 && paste_targets(st).len > 0 }
		.preset { paste_targets(st).len > 0 }
		.pair { st.pair_on || (frame_ready(st) && pair_candidate(st).len > 0) }
		.swap { st.pair_on }
		.mask { st.mask_show || (frame_open(st) && st.edit.params.masks.len > 0) }
	}
}

// avail_add - пункты меню с условием n (доступность - sync_avail)
fn avail_add(mut st State, n Need, items []&vgui.MenuItem) {
	for it in items {
		st.avail << AvailItem{
			item: it
			need: n
		}
	}
}

// sync_avail - доступность пунктов меню и панели по состоянию
fn sync_avail(mut st State) {
	for a in st.avail {
		mut it := unsafe { a.item }
		it.enabled = need_met(st, a.need)
	}
	// Меню «Пресеты» пересобирается (rebuild_presets_menu) - свои списки
	apply := need_met(st, .preset)
	for it in st.m_presets {
		mut m := unsafe { it }
		m.enabled = apply
	}
	if !isnil(st.m_preset_save) {
		mut m := st.m_preset_save
		m.enabled = frame_open(st)
	}
	set_panel_live(mut st, frame_open(st))
}

// set_panel_live - разделы панели правки (все, и скрытые) активны или
// нет. Обход дерева - только при смене; при включении виджеты с
// условной доступностью (объектив, кадрирование, фильтры, пятна, AI)
// получают её заново от своих sync_*: обход включил их все.
fn set_panel_live(mut st State, on bool) {
	// Панели ещё нет (меню пресетов строится раньше) - запомнить нечего
	if on == st.panel_live || st.sec_w.len == 0 {
		return
	}
	st.panel_live = on
	for w in st.sec_w {
		if !isnil(w) {
			set_controls_enabled(w, on)
		}
	}
	if !on {
		return
	}
	if !isnil(st.lens_cb) {
		mut cb := st.lens_cb
		cb.enabled = !isnil(st.corr)
	}
	sync_crop_ui(mut st)
	sync_mask_ui(mut st)
	sync_spot_ui(mut st)
	sync_ai_ui(mut st)
}

// set_controls_enabled - enabled у всех элементов управления поддерева.
// Вкладки (TabBox) и аккордеон не трогаются: разделы открываются и без
// кадра.
fn set_controls_enabled(root &vgui.Widget, on bool) {
	vgui.walk_widgets(root, fn [on] (x &vgui.Widget) {
		mut w := unsafe { x }
		if mut w is vgui.Slider {
			w.enabled = on
		} else if mut w is vgui.Button {
			w.enabled = on
		} else if mut w is vgui.CheckBox {
			w.enabled = on
		} else if mut w is vgui.ComboBox {
			w.enabled = on
		} else if mut w is vgui.Spinbox {
			w.enabled = on
		} else if mut w is vgui.TextInput {
			w.enabled = on
		} else if mut w is vgui.CurveEditor {
			w.enabled = on
		} else if mut w is vgui.Canvas {
			w.enabled = on
		} else if mut w is vgui.ListBox {
			w.enabled = on
		}
	})
}
