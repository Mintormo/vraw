module main

// Масштаб интерфейса (vgui: Window.set_ui_scale) - шрифты, ползунки,
// кнопки крупнее или мельче. Выбор - только «Правка - Настройки - Общие»
// (числом в процентах), хранится в settings.json (ui_scale, %).
// Окно при смене масштаба остаётся того же размера на экране: меняется
// лишь его логическая ширина (vgui сам растянул бы окно в s раз - за край
// экрана). Диалоги берут масштаб главного окна при показе (show_dialog,
// dlgfit.v), открытое окно настроек - пересчитывается здесь.
import vgui

// масштаб - в этих пределах, %
const ui_scale_min = 50
const ui_scale_max = 300

// ui_scale_pct - масштаб из настроек: вне пределов (0 - старый
// settings.json без поля, чужое) - 100%
fn ui_scale_pct(pct int) int {
	return if pct >= ui_scale_min && pct <= ui_scale_max { pct } else { 100 }
}

// set_window_scale - масштаб окна при том же размере на экране
fn set_window_scale(mut w vgui.Window, s f32) {
	old := if w.ctx.ui_scale > 0 { w.ctx.ui_scale } else { f32(1) }
	if s == old {
		return
	}
	// config.width/height - логический размер; физический = логический ×
	// масштаб. Логический под новый масштаб - set_ui_scale оставит окно
	// прежней величины
	w.config.width = int(f32(w.config.width) * old / s + 0.5)
	w.config.height = int(f32(w.config.height) * old / s + 0.5)
	w.set_ui_scale(s)
	w.invalidate_all()
}

// scaled_strip_ratio - доля сплиттера ленты, при которой лента остаётся
// прежней логической высоты, когда масштаб вырос в k раз: логическая
// высота окна уменьшилась в k раз, доля ленты - вырастает (иначе
// миниатюрам остаётся полоска между подписью и полями). Меню и поля
// не учтены - ошибка в несколько процентов.
fn scaled_strip_ratio(ratio f32, top bool, k f32) f32 {
	part := if top { ratio } else { 1 - ratio }
	mut sf := part * k
	sf = if sf < 0.05 { 0.05 } else if sf > 0.6 { 0.6 } else { sf }
	return if top { sf } else { 1 - sf }
}

// apply_ui_scale - выбран масштаб pct, %: главное окно, лента, окно
// настроек, запомнить
fn apply_ui_scale(mut st State, pct_in int) {
	pct := if pct_in < ui_scale_min {
		ui_scale_min
	} else if pct_in > ui_scale_max {
		ui_scale_max
	} else {
		pct_in
	}
	old_pct := ui_scale_pct(st.settings.ui_scale)
	st.settings.ui_scale = pct
	if pct != old_pct {
		save_settings(st.settings)
		s := f32(pct) / 100
		mut w := st.win
		set_window_scale(mut w, s)
		if !isnil(st.vsplit) {
			mut sp := st.vsplit
			sp.ratio = scaled_strip_ratio(sp.ratio, st.settings.strip_top, f32(pct) / f32(old_pct))
		}
		// Окно настроек живёт до выхода и может быть открыто сейчас
		// (выбор из него); остальные диалоги догонят масштаб при показе
		if !isnil(st.sui) {
			mut d := st.sui.dlg
			if d.is_open() {
				rescale_dialog(mut d, st.sui.scroll, st.win, s, 0, 0)
			}
		}
	}
	sync_settings_ui(mut st)
}
