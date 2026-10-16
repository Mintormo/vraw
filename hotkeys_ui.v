module main

// Вкладка «Горячие клавиши» окна настроек: действия по разделам меню, у
// каждого - поле сочетания vgui.ShortcutInput (щелчок - ждать нажатия:
// новое сочетание, Esc - отмена, Backspace/Delete - снять, занятые
// навигацией - отказ) и сброс к умолчанию. Сочетание поле пишет по месту
// клавиши - в том же виде, что vgui.shortcut_from_event у KeyWatch.
import vgui
import i18n

// HkRow - ряд действия: поле сочетания и сброс
struct HkRow {
	input &vgui.ShortcutInput = unsafe { nil }
	reset &vgui.Button        = unsafe { nil }
}

const hk_none = 'нет'
const hk_wait_text = 'Нажмите сочетание...'

// build_hotkeys_tab - содержимое вкладки
fn build_hotkeys_tab(mut st State, mut u SettingsUi, mut dw vgui.Window) &vgui.VBox {
	mut names := st.hk.map(it.name)
	names << i18n.tr_all(hk_groups)
	name_w := column_width(mut dw, names, 16)
	mut keys := [i18n.tr(hk_wait_text), 'Ctrl+Shift+Alt+PageDown']
	key_w := column_width(mut dw, keys, 24)
	mut list := vgui.create_vbox_fill()
	list.set_spacing(2)
	list.set_padding(4)
	for g in hk_groups {
		list.add(caption(i18n.tr(g)))
		for i, h in st.hk {
			if h.group != g {
				continue
			}
			idx := i
			mut si := vgui.shortcut_input(h.item.shortcut)
			si.empty_text = i18n.tr(hk_none)
			si.wait_text = i18n.tr(hk_wait_text)
			si.reserved = hk_reserved.clone()
			// Замыкания - через локальные переменные (CLAUDE.md, грабли V)
			on_wait := fn [mut u] (waiting bool) {
				if waiting {
					u.hk_msg.text = ''
				}
			}
			si.on_wait = on_wait
			// Новое сочетание ('' - снято) или занятое навигацией: hk_set
			// назначает или объясняет, почему нельзя
			on_set := fn [mut st, mut u, idx] (sc string) {
				u.hk_msg.text = hk_set(mut st, idx, sc)
			}
			si.on_change = on_set
			si.on_reject = on_set
			mut r := vgui.button('')
			r.icon_name = 'rotate-ccw'
			r.icon_size = 15
			r.style = .flat
			r.on_click = fn [mut st, mut u, idx] () {
				hk_cancel_wait(mut u)
				u.hk_msg.text = hk_set(mut st, idx, st.hk[idx].def)
			}
			mut row := vgui.create_hbox_fill()
			row.set_spacing(6)
			row.add(vgui.label(h.name), min: name_w)
			row.add(si, min: key_w)
			row.add(r, min: icon_slot_w)
			row.add(vgui.create_spacer(), flex: 1)
			list.add(row)
			u.hk_rows << HkRow{
				input: si
				reset: r
			}
		}
	}
	mut sb := vgui.scroll_box(0)
	sb.sb_width = 8
	sb.add(list)
	mut msg := vgui.label('')
	u.hk_msg = msg
	mut all := vgui.button(i18n.tr('Вернуть все'))
	all.on_click = fn [mut st, mut u] () {
		hk_cancel_wait(mut u)
		u.hk_msg.text = ''
		hk_reset_all(mut st)
	}
	mut bottom := vgui.create_hbox_fill()
	bottom.set_spacing(8)
	bottom.add(all)
	bottom.add(msg, flex: 1)
	mut v := tab_page()
	mut how := note(mut u, i18n.tr('Щёлкните по сочетанию и нажмите новое: Esc - отмена, Backspace - снять. Работают в любой раскладке.'))
	how.wrap = true
	v.add(how)
	v.add(sb, flex: 1)
	v.add(bottom)
	mut fixed := note(mut u, i18n.tr(hk_fixed_note))
	fixed.wrap = true
	v.add(fixed)
	return v
}

// sync_hotkeys_ui - поля по текущим сочетаниям (ждущее нажатия не трогать)
fn sync_hotkeys_ui(mut u SettingsUi, st &State) {
	for i, r in u.hk_rows {
		if i >= st.hk.len {
			break
		}
		h := st.hk[i]
		mut si := r.input
		if !si.is_waiting() {
			si.set_shortcut(h.item.shortcut)
		}
		mut rb := r.reset
		rb.enabled = h.item.shortcut != h.def
	}
}

// hk_cancel_wait - прервать ожидание нажатия во всех полях вкладки
fn hk_cancel_wait(mut u SettingsUi) {
	for r in u.hk_rows {
		mut si := r.input
		si.cancel()
	}
}
