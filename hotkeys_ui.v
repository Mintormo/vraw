module main

// Вкладка «Горячие клавиши» окна настроек: действия по разделам меню, у
// каждого - кнопка с сочетанием (щелчок - ждать нажатия: новое сочетание,
// Esc - отмена, Backspace/Delete - снять) и сброс к умолчанию. Нажатие
// ловит HkCapture - виджет диалога после корня (события получает первым).
import vgui

// HkRow - ряд действия: кнопка сочетания и сброс
struct HkRow {
	btn   &vgui.Button = unsafe { nil }
	reset &vgui.Button = unsafe { nil }
}

const hk_none = 'нет'
const hk_wait_text = 'Нажмите сочетание...'

// build_hotkeys_tab - содержимое вкладки
fn build_hotkeys_tab(mut st State, mut u SettingsUi, mut dw vgui.Window) &vgui.VBox {
	mut names := st.hk.map(it.name)
	names << hk_groups
	name_w := column_width(mut dw, names, 16)
	mut keys := [hk_wait_text, 'Ctrl+Shift+Alt+PageDown']
	key_w := column_width(mut dw, keys, 24)
	mut list := vgui.create_vbox_fill()
	list.set_spacing(2)
	list.set_padding(4)
	for g in hk_groups {
		list.add(caption(g))
		for i, h in st.hk {
			if h.group != g {
				continue
			}
			idx := i
			mut b := vgui.button(hk_none)
			b.on_click = fn [mut st, mut u, idx] () {
				u.hk_wait = if u.hk_wait == idx { -1 } else { idx }
				u.hk_msg.text = ''
				sync_hotkeys_ui(mut u, st)
			}
			mut r := vgui.button('')
			r.icon_name = 'rotate-ccw'
			r.icon_size = 15
			r.style = .flat
			r.on_click = fn [mut st, mut u, idx] () {
				u.hk_wait = -1
				u.hk_msg.text = hk_set(mut st, idx, st.hk[idx].def)
			}
			mut row := vgui.create_hbox_fill()
			row.set_spacing(6)
			row.add(vgui.label(h.name), min: name_w)
			row.add(b, min: key_w)
			row.add(r, min: icon_slot_w)
			row.add(vgui.create_spacer(), flex: 1)
			list.add(row)
			u.hk_rows << HkRow{
				btn:   b
				reset: r
			}
		}
	}
	mut sb := vgui.scroll_box(0)
	sb.sb_width = 8
	sb.add(list)
	mut msg := vgui.label('')
	u.hk_msg = msg
	mut all := vgui.button('Вернуть все')
	all.on_click = fn [mut st, mut u] () {
		u.hk_wait = -1
		u.hk_msg.text = ''
		hk_reset_all(mut st)
	}
	mut bottom := vgui.create_hbox_fill()
	bottom.set_spacing(8)
	bottom.add(all)
	bottom.add(msg, flex: 1)
	mut v := tab_page()
	mut how := note(mut u, 'Щёлкните по сочетанию и нажмите новое: Esc - отмена, Backspace - снять. Работают в любой раскладке.')
	how.wrap = true
	v.add(how)
	v.add(sb, flex: 1)
	v.add(bottom)
	mut fixed := note(mut u, hk_fixed_note)
	fixed.wrap = true
	v.add(fixed)
	return v
}

// sync_hotkeys_ui - кнопки по текущим сочетаниям; ждущая - подсвечена
fn sync_hotkeys_ui(mut u SettingsUi, st &State) {
	for i, r in u.hk_rows {
		if i >= st.hk.len {
			break
		}
		h := st.hk[i]
		mut b := r.btn
		if u.hk_wait == i {
			b.text = hk_wait_text
			b.style = .accent
		} else {
			b.text = if h.item.shortcut.len > 0 { h.item.shortcut } else { hk_none }
			b.style = .normal
		}
		mut rb := r.reset
		rb.enabled = h.item.shortcut != h.def
	}
}

// HkCapture - ловит нажатие для ждущей кнопки (виджет диалога настроек)
struct HkCapture {
mut:
	st &State      = unsafe { nil }
	u  &SettingsUi = unsafe { nil }
}

fn (mut c HkCapture) draw(mut _ vgui.RenderContext) {}

fn (mut c HkCapture) handle_event(ev &vgui.GuiEvent, _ &vgui.App) bool {
	if isnil(c.u) || c.u.hk_wait < 0 || ev.typ != .key_down {
		return false
	}
	mut u := c.u
	mut st := c.st
	idx := u.hk_wait
	key := hk_key_name(ev.scancode)
	if key.len == 0 {
		return true // модификатор сам по себе - ждать дальше
	}
	mods := ev.mod_keys & (vgui.sdl_kmod_ctrl | vgui.sdl_kmod_alt | vgui.sdl_kmod_shift)
	if mods == 0 && key == 'Escape' {
		u.hk_wait = -1
		u.hk_msg.text = ''
		sync_hotkeys_ui(mut u, st)
		return true
	}
	if mods == 0 && (key == 'Backspace' || key == 'Delete') {
		u.hk_wait = -1
		u.hk_msg.text = hk_set(mut st, idx, '')
		return true
	}
	sc := hk_event_name(ev)
	if hk_is_reserved(sc) {
		u.hk_msg.text = hk_set(mut st, idx, sc) // сообщение «занято», ждём дальше
		return true
	}
	u.hk_wait = -1
	u.hk_msg.text = hk_set(mut st, idx, sc)
	return true
}
