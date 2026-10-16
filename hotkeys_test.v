module main

import vgui
import json2

fn hk_state() &State {
	mut st := &State{}
	mut a := vgui.menu_action('Открыть')
	a.shortcut = 'Ctrl+O'
	hk_add(mut st, 'a', 'Файл', mut a)
	mut b := vgui.menu_checkbox('Флажок', false)
	b.shortcut = 'F'
	hk_add(mut st, 'b', 'Вид', mut b)
	mut c := vgui.menu_action('Без сочетания')
	hk_add(mut st, 'c', 'Вид', mut c)
	return st
}

// Назначение: занятое другим снимается там; по умолчанию - запись
// убирается; занятое навигацией не назначается
fn test_hk_set_conflict() {
	mut st := hk_state()
	assert hk_key(st, 'a') == 'Ctrl+O' && hk_key(st, 'b') == 'F' && hk_key(st, 'c') == ''
	msg := hk_set(mut st, 2, 'F')
	assert msg.contains('Флажок')
	assert hk_key(st, 'c') == 'F' && hk_key(st, 'b') == ''
	assert 'c=F' in st.settings.hotkeys && 'b=' in st.settings.hotkeys
	assert hk_set(mut st, 1, 'F').len > 0 // вернули - сняли у «c»
	assert hk_key(st, 'b') == 'F' && hk_key(st, 'c') == ''
	assert !st.settings.hotkeys.any(it.starts_with('b='))
	assert hk_set(mut st, 0, 'Space').contains('занято')
	assert hk_key(st, 'a') == 'Ctrl+O'
	hk_reset_all(mut st)
	assert st.settings.hotkeys.len == 0 && hk_key(st, 'c') == ''
}

// Своё сочетание из настроек - в пункт; снятое - пусто; занятое
// навигацией - по умолчанию
fn test_hk_override_on_start() {
	mut st := &State{}
	st.settings.hotkeys = ['a=ctrl+k', 'b=', 'c=Escape']
	mut a := vgui.menu_action('A')
	a.shortcut = 'Ctrl+O'
	hk_add(mut st, 'a', 'Файл', mut a)
	mut b := vgui.menu_action('B')
	b.shortcut = 'F'
	hk_add(mut st, 'b', 'Файл', mut b)
	mut c := vgui.menu_action('C')
	c.shortcut = 'G'
	hk_add(mut st, 'c', 'Файл', mut c)
	assert a.shortcut == 'Ctrl+K' && b.shortcut == '' && c.shortcut == 'G'
}

// Нажатие срабатывает как пункт меню: флажок переключается; неактивный
// пункт события не берёт
fn test_hk_dispatch() {
	mut st := hk_state()
	ev := vgui.GuiEvent{
		typ:      .key_down
		scancode: 9 // F
		keycode:  int(`а`)
	}
	assert hk_dispatch(mut st, &ev)
	assert st.hk[1].item.checked
	mut it := st.hk[1].item
	it.enabled = false
	assert !hk_dispatch(mut st, &ev)
}

// Настройки переживают перезапуск
fn test_hk_settings_roundtrip() {
	mut s := Settings{}
	s.hotkeys = ['view.full=F11', 'edit.crop=', 'мусор']
	back := settings_from(json2.decode[Settings](json2.encode(s))!)
	assert back.hotkeys == ['view.full=F11', 'edit.crop=']
}
