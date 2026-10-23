module main

import json2

// Порядок разделов из настроек: чужие ключи и повторы отбрасываются,
// недостающие (новый раздел) встают на место по умолчанию
fn test_panel_order_from() {
	def := panel_default_order()
	assert panel_order_from([]) == def
	assert panel_order_from(['bogus', 'history', 'history']).len == def.len
	// Недостающие - за своими предшественниками по умолчанию
	assert panel_order_from(['history']) == def
	assert panel_order_from(['history', 'lens'])[0] == 'history'
	// Нет раздела «Кривые» - встаёт за «Тон-эквалайзером», как по умолчанию
	mut saved := def.filter(it != 'curves')
	saved = panel_move(saved, 'eq', -3)
	back := panel_order_from(saved)
	assert back[back.index('eq') + 1] == 'curves'
	assert back.len == def.len
}

fn test_panel_move_and_shown() {
	def := panel_default_order()
	up := panel_move(def, 'crop', -1)
	assert up[0] == 'crop' && up[1] == 'lens'
	// У края - без изменений
	assert panel_move(def, 'lens', -1) == def
	assert panel_move(def, 'history', 1) == def
	assert panel_move(def, 'bogus', 1) == def
	shown := panel_shown(def, ['crop', 'history'])
	assert shown.len == def.len - 2
	assert 'crop' !in shown && 'history' !in shown
	assert panel_keys_from(['crop', 'bogus', 'crop']) == ['crop']
}

// Раскладка переживает перезапуск; старый settings.json без полей - всё
// видно, панель справа, порядок по умолчанию
fn test_panel_settings_roundtrip() {
	mut s := Settings{}
	s.no_panel = true
	s.no_strip = true
	s.panel_left = true
	s.strip_top = true
	s.fs_panel = true
	s.fs_strip = true
	s.panel_order = panel_move(panel_default_order(), 'history', -(panel_sections.len - 1))
	s.panel_hidden = ['crop', 'fx']
	back := settings_from(json2.decode[Settings](json2.encode(s))!)
	assert back.no_panel && back.no_strip && back.panel_left && back.strip_top && back.fs_panel && back.fs_strip
	assert back.panel_order[0] == 'history'
	assert back.panel_hidden == ['crop', 'fx']
	old := settings_from(json2.decode[Settings]('{"theme": "dark"}')!)
	assert !old.no_panel && !old.no_strip && !old.panel_left && !old.strip_top && !old.fs_panel && !old.fs_strip
	assert old.panel_order == panel_default_order()
	assert old.panel_hidden.len == 0
}
