module main

// Настраиваемые горячие клавиши (окно «Настройки - Горячие клавиши»).
//
// Действие - пункт меню (vgui.MenuItem), зарегистрированный под
// постоянным ключом (hk_add): сочетание по умолчанию - то, что задано
// пункту в коде, своё - из settings.hotkeys («ключ=сочетание», пусто после
// «=» - снято). Сочетание пишется в поле shortcut пункта (меню его
// показывает) в каноническом виде vgui.shortcut_normalize: «Ctrl+Shift+Alt+Клавиша».
//
// Нажатия разбирает KeyWatch (compare.v): имя сочетания строится по месту
// клавиши (scancode, vgui.shortcut_from_event), а не по букве раскладки - в русской
// раскладке SDL отдаёт в keycode «к» вместо R, и меню vgui такие сочетания
// не узнаёт. Найденный пункт срабатывает как из меню (hk_fire), событие
// дальше не идёт.
//
// Клавиши навигации и окна (стрелки, Home/End, Enter, Esc, пробел,
// Tab, удержание «\», Ctrl+Y) не настраиваются - hk_reserved.
import vgui
import i18n

// HotItem - действие: ключ в настройках, раздел (меню) и название для
// окна, сочетание по умолчанию, пункт меню
struct HotItem {
	id    string
	group string // ключ из hk_groups (русский) - переводится только при показе
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
	def := vgui.shortcut_normalize(item.shortcut)
	st.hk << HotItem{
		id:    id
		group: group
		name:  item.text
		def:   def
		item:  item
	}
	sc, ok := hk_override(&st.settings, id)
	n := vgui.shortcut_normalize(sc)
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
	i := hk_find(st, vgui.shortcut_from_event(ev))
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
		return i18n.trf('Сочетание {0} занято навигацией - выберите другое', '${sc}')
	}
	mut msg := ''
	other := hk_find(st, sc)
	if other >= 0 && other != idx {
		o := st.hk[other]
		mut oi := o.item
		oi.shortcut = ''
		st.settings.hotkeys = hk_with(st.settings.hotkeys, o.id, '', o.def)
		msg = i18n.trf('{0} было у «{1}» - там снято', '${sc}', '${o.name}')
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
