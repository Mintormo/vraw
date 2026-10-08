module main

// Настраиваемые горячие клавиши (окно «Настройки - Горячие клавиши»).
//
// Действие - пункт меню (vgui.MenuItem), зарегистрированный под
// постоянным ключом (hk_add): сочетание по умолчанию - то, что задано
// пункту в коде, своё - из settings.hotkeys («ключ=сочетание», пусто после
// «=» - снято). Сочетание пишется в поле shortcut пункта (меню его
// показывает) в каноническом виде hk_norm: «Ctrl+Shift+Alt+Клавиша».
//
// Нажатия разбирает KeyWatch (compare.v): имя сочетания строится по месту
// клавиши (scancode, hk_event_name), а не по букве раскладки - в русской
// раскладке SDL отдаёт в keycode «к» вместо R, и меню vgui такие сочетания
// не узнаёт. Найденный пункт срабатывает как из меню (hk_fire), событие
// дальше не идёт.
//
// Клавиши навигации и окна (стрелки, Home/End, Enter, Esc, пробел,
// Tab, удержание «\», Ctrl+Y) не настраиваются - hk_reserved.
import vgui

// HotItem - действие: ключ в настройках, раздел (меню) и название для
// окна, сочетание по умолчанию, пункт меню
struct HotItem {
	id    string
	group string
	name  string
	def   string
	item  &vgui.MenuItem = unsafe { nil }
}

// Разделы окна - в порядке меню
const hk_groups = ['Файл', 'Правка', 'Отбор', 'Вид']

// Не настраиваются: заняты навигацией и окнами (bind_hotkey, KeyWatch)
const hk_reserved = ['Left', 'Right', 'Up', 'Down', 'Home', 'End', 'Enter', 'Escape', 'Space',
	'Tab', 'Backspace', 'Delete', '\\', 'Ctrl+Y']

// hk_fixed_note - что не меняется (подпись в окне)
const hk_fixed_note = 'Не меняются: стрелки влево/вправо, Home/End - кадры ленты; Enter, Esc; пробел - 100% / вписать; «\\» (удерживать) - до/после; Ctrl+Y - вернуть'

// Места клавиш (scancode SDL, USB HID) -> имя в сочетании
const hk_sc_names = {
	45: '-'
	46: '='
	47: '['
	48: ']'
	49: '\\'
	51: ';'
	52: "'"
	53: '`'
	54: ','
	55: '.'
	56: '/'
	40: 'Enter'
	41: 'Escape'
	42: 'Backspace'
	43: 'Tab'
	44: 'Space'
	73: 'Insert'
	74: 'Home'
	75: 'PageUp'
	76: 'Delete'
	77: 'End'
	78: 'PageDown'
	79: 'Right'
	80: 'Left'
	81: 'Down'
	82: 'Up'
}

// hk_key_name - имя клавиши по месту (scancode); '' - не клавиша сочетания
// (модификаторы, неизвестные)
fn hk_key_name(sc int) string {
	if sc >= 4 && sc <= 29 {
		return u8(`A` + sc - 4).ascii_str()
	}
	if sc >= 30 && sc <= 38 {
		return u8(`1` + sc - 30).ascii_str()
	}
	if sc == 39 {
		return '0'
	}
	if sc >= 58 && sc <= 69 {
		return 'F${sc - 57}'
	}
	return hk_sc_names[sc] or { '' }
}

// hk_compose - каноническое сочетание: модификаторы в порядке Ctrl, Shift,
// Alt и клавиша
fn hk_compose(ctrl bool, shift bool, alt bool, key string) string {
	if key.len == 0 {
		return ''
	}
	mut s := ''
	if ctrl {
		s += 'Ctrl+'
	}
	if shift {
		s += 'Shift+'
	}
	if alt {
		s += 'Alt+'
	}
	return s + key
}

// hk_event_name - сочетание нажатия (по месту клавиши); '' - не сочетание
fn hk_event_name(ev &vgui.GuiEvent) string {
	return hk_compose(ev.mod_keys & vgui.sdl_kmod_ctrl != 0, ev.mod_keys & vgui.sdl_kmod_shift != 0,
		ev.mod_keys & vgui.sdl_kmod_alt != 0, hk_key_name(ev.scancode))
}

// hk_norm - сочетание из текста (настройки, код) в каноническом виде:
// регистр и порядок модификаторов не важны; неизвестная клавиша - ''
fn hk_norm(s string) string {
	mut ctrl := false
	mut shift := false
	mut alt := false
	mut key := ''
	for p in s.split('+') {
		t := p.trim_space()
		match t.to_lower() {
			'ctrl' { ctrl = true }
			'shift' { shift = true }
			'alt' { alt = true }
			'' {}
			else { key = hk_canon_key(t) }
		}
	}
	// «Ctrl++» - клавиша «+» не поддерживается (её место - «=»)
	return hk_compose(ctrl, shift, alt, key)
}

// hk_canon_key - имя клавиши как у hk_key_name (буквы - заглавные)
fn hk_canon_key(t string) string {
	if t.len == 1 {
		c := t[0]
		if c >= `a` && c <= `z` {
			return u8(c - 32).ascii_str()
		}
		if (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) {
			return t
		}
	}
	l := t.to_lower()
	if l.len >= 2 && l.len <= 3 && l[0] == `f` {
		n := l[1..].int()
		if n >= 1 && n <= 12 && '${n}' == l[1..] {
			return 'F${n}'
		}
	}
	for _, name in hk_sc_names {
		if name.to_lower() == l {
			return name
		}
	}
	return match l {
		'esc' { 'Escape' }
		'return' { 'Enter' }
		'del' { 'Delete' }
		else { '' }
	}
}

// hk_is_reserved - сочетание занято навигацией (не назначается)
fn hk_is_reserved(sc string) bool {
	return sc in hk_reserved
}

// hk_override - своё сочетание действия из настроек: (сочетание, есть ли)
fn hk_override(s &Settings, id string) (string, bool) {
	for e in s.hotkeys {
		i := e.index('=') or { continue }
		if e[..i] == id {
			return e[i + 1..], true
		}
	}
	return '', false
}

// hk_with - настройки сочетаний с действием id = sc (sc == def - запись
// убирается: по умолчанию)
fn hk_with(list []string, id string, sc string, def string) []string {
	mut out := list.filter(!it.starts_with(id + '='))
	if sc != def {
		out << '${id}=${sc}'
	}
	return out
}

// hk_add - зарегистрировать пункт меню как действие: по умолчанию - его
// сочетание из кода, своё из настроек - сразу в пункт
fn hk_add(mut st State, id string, group string, mut item vgui.MenuItem) {
	def := hk_norm(item.shortcut)
	st.hk << HotItem{
		id:    id
		group: group
		name:  item.text
		def:   def
		item:  item
	}
	sc, ok := hk_override(&st.settings, id)
	n := hk_norm(sc)
	item.shortcut = if ok && !hk_is_reserved(n) { n } else { def }
}

// hk_key - текущее сочетание действия ('' - нет)
fn hk_key(st &State, id string) string {
	for h in st.hk {
		if h.id == id {
			return h.item.shortcut
		}
	}
	return ''
}

// hk_paren - « (F8)» для подписей; без сочетания - пусто
fn hk_paren(st &State, id string) string {
	k := hk_key(st, id)
	return if k.len > 0 { ' (${k})' } else { '' }
}

// hk_find - действие с сочетанием sc (-1 - нет)
fn hk_find(st &State, sc string) int {
	if sc.len == 0 {
		return -1
	}
	for i, h in st.hk {
		if h.item.shortcut == sc {
			return i
		}
	}
	return -1
}

// hk_fire - сработать как пункт меню: флажок переключается, затем
// on_toggle; неактивный пункт - false (событие идёт дальше)
fn hk_fire(mut item vgui.MenuItem) bool {
	if !item.enabled {
		return false
	}
	if item.kind == .checkbox {
		item.checked = !item.checked
		if !isnil(item.on_toggle) {
			item.on_toggle(item.checked)
		}
	} else if !isnil(item.on_click) {
		item.on_click()
	}
	return true
}

// hk_dispatch - нажатие в главном окне (KeyWatch): действие с таким
// сочетанием срабатывает; true - событие забрано
fn hk_dispatch(mut st State, ev &vgui.GuiEvent) bool {
	i := hk_find(st, hk_event_name(ev))
	if i < 0 {
		return false
	}
	mut it := st.hk[i].item
	return hk_fire(mut it)
}

// hk_set - назначить действию idx сочетание sc ('' - снять). Сочетание
// другого действия снимается с него; ответ - сообщение для окна ('' -
// без замечаний)
fn hk_set(mut st State, idx int, sc string) string {
	if idx < 0 || idx >= st.hk.len {
		return ''
	}
	if hk_is_reserved(sc) {
		return 'Сочетание ${sc} занято навигацией - выберите другое'
	}
	mut msg := ''
	other := hk_find(st, sc)
	if other >= 0 && other != idx {
		o := st.hk[other]
		mut oi := o.item
		oi.shortcut = ''
		st.settings.hotkeys = hk_with(st.settings.hotkeys, o.id, '', o.def)
		msg = '${sc} было у «${o.name}» - там снято'
	}
	h := st.hk[idx]
	mut it := h.item
	it.shortcut = sc
	st.settings.hotkeys = hk_with(st.settings.hotkeys, h.id, sc, h.def)
	save_settings(st.settings)
	hk_refresh(mut st)
	return msg
}

// hk_reset_all - все сочетания по умолчанию
fn hk_reset_all(mut st State) {
	for h in st.hk {
		mut it := h.item
		it.shortcut = h.def
	}
	st.settings.hotkeys = []string{}
	save_settings(st.settings)
	hk_refresh(mut st)
}

// hk_refresh - подписи со вписанными сочетаниями (подсказки, заглушка,
// окно настроек) - после любой смены
fn hk_refresh(mut st State) {
	for f in st.hk_texts {
		f()
	}
	if !isnil(st.sui) {
		mut u := st.sui
		sync_hotkeys_ui(mut u, st)
		sync_hk_texts(mut u, st)
	}
}
