module main

// Ввод точного значения ползунка панели. В ряду slider_row справа от
// значения - кнопка-карандаш: по щелчку на месте подписи значения
// появляется поле, в которое можно набрать только число (целое или
// дробное, через точку или запятую). Enter - применить (через
// Slider.set_value: on_change ползунка сам пишет настройку, подпись,
// пересчитывает и кладёт шаг в историю, как клавиша или «×»); Esc или
// щелчок мимо поля - отмена. Число вне диапазона ползунка прижимается к
// краю.
//
// Ячейка значения - vgui.Stack из подписи, поля и сторожа ValueEdit.
// Отдельного события «поле потеряло фокус» у vgui.TextInput нет, поэтому
// сторож, как Spinbox в vgui, ловит переход «был фокус - нет фокуса» в
// своём draw (Stack рисует его после поля, поле к этому моменту уже
// сверило фокус) и закрывает поле.

import math
import strconv
import vgui
import i18n

// NumConv - число в поле ввода <-> значение ползунка. По умолчанию число и
// есть значение; у температуры ползунок - положение на шкале, а вводят
// кельвины. digits - знаков после запятой в поле при открытии.
struct NumConv {
	digits int = 2
	to     fn (f32) f32 = unsafe { nil } // значение ползунка -> число в поле
	from   fn (f32) f32 = unsafe { nil } // введённое число -> значение ползунка
}

// ValueEdit - сторож поля ввода значения (лист дерева виджетов: места не
// занимает, ничего не рисует). type_tag первым полем - общий заголовок
// виджетов vgui (widget_tag.v).
@[heap]
struct ValueEdit {
mut:
	type_tag    int
	st          &State          = unsafe { nil }
	sl          &vgui.Slider    = unsafe { nil }
	vl          &vgui.Label     = unsafe { nil }
	ti          &vgui.TextInput = unsafe { nil }
	conv        NumConv
	open        bool
	was_focused bool
}

fn (mut e ValueEdit) draw(mut _ vgui.RenderContext) {
	if !e.open {
		return
	}
	if e.ti.focused {
		e.was_focused = true
	} else if e.was_focused {
		e.close()
	}
}

fn (mut e ValueEdit) handle_event(_ &vgui.GuiEvent, _ &vgui.App) bool {
	return false
}

// Сторож места в ряду не просит (без measure Stack взял бы его bounds и
// растянул ячейку)
fn (e &ValueEdit) measure(_ &vgui.RenderContext) vgui.SizeHint {
	return vgui.SizeHint{}
}

// start - открыть поле: текущее значение числом, выделено целиком (набор
// заменяет его), фокус в поле
fn (mut e ValueEdit) start() {
	if e.open {
		return
	}
	v := if isnil(e.conv.to) { e.sl.value } else { e.conv.to(e.sl.value) }
	text := num_text(v, e.conv.digits)
	mut ti := e.ti
	ti.set_text(text)
	ti.sel_a = 0
	ti.sel_b = ti.buf.len
	ti.visible = true
	mut vl := e.vl
	vl.visible = false
	e.open = true
	e.was_focused = false
	if !isnil(e.st.win) {
		mut win := e.st.win
		win.set_default_focus_text_input(ti)
		win.invalidate_all()
	}
}

// close - вернуть подпись значения на место поля
fn (mut e ValueEdit) close() {
	if !e.open {
		return
	}
	e.open = false
	e.was_focused = false
	mut ti := e.ti
	if !isnil(e.st.win) {
		mut win := e.st.win
		if ti.focused {
			win.ctx.focus.blur_current()
			ti.focused = false
		}
		win.sync_text_input()
		win.invalidate_all()
	}
	ti.visible = false
	mut vl := e.vl
	vl.visible = true
}

// submit - Enter в поле: число -> значение ползунка. Пустое поле или
// одинокий знак - как отмена.
fn (mut e ValueEdit) submit(s string) {
	n := parse_num(s) or {
		e.close()
		return
	}
	e.close()
	v := if isnil(e.conv.from) { n } else { e.conv.from(n) }
	mut sl := e.sl
	sl.set_value(v)
}

// num_text - число для поля: digits знаков после запятой, без хвостовых
// нулей («1.50» -> «1.5», «2.00» -> «2»)
fn num_text(v f32, digits int) string {
	if digits <= 0 {
		return '${int(math.round(v))}'
	}
	mut s := match digits {
		1 { '${v:.1f}' }
		2 { '${v:.2f}' }
		else { '${v:.3f}' }
	}
	if s.contains('.') {
		s = s.trim_right('0').trim_right('.')
	}
	if s == '-0' {
		s = '0'
	}
	return s
}

// num_prefix_ok - строка годится как (недописанное) число: знак в начале,
// цифры, одна точка или запятая
fn num_prefix_ok(s string) bool {
	mut sep := false
	for i, c in s {
		if (c == `-` || c == `+`) && i == 0 {
			continue
		}
		if c == `.` || c == `,` {
			if sep {
				return false
			}
			sep = true
			continue
		}
		if !c.is_digit() {
			return false
		}
	}
	return true
}

// parse_num - введённое число (запятая = точка); none - не число
fn parse_num(s string) ?f32 {
	t := s.trim_space().replace(',', '.')
	if !num_prefix_ok(t) {
		return none
	}
	mut digits := false
	for c in t {
		if c.is_digit() {
			digits = true
			break
		}
	}
	if !digits {
		return none
	}
	v := strconv.atof64(t) or { return none }
	return f32(v)
}

// value_cell - ячейка значения ряда: подпись vl, поле ввода и сторож в
// одном Stack, плюс кнопка-карандаш, открывающая поле
fn value_cell(mut st State, mut sl vgui.Slider, vl &vgui.Label, conv NumConv) (&vgui.Stack, &vgui.Button) {
	mut ti := vgui.text_input('')
	ti.visible = false
	ti.max_len = 12
	// Ширина - колонка значения (min ряда); без chars поле растягивается
	// и отнимает место у ползунка
	ti.chars = 1
	ti.accept = num_prefix_ok
	mut e := &ValueEdit{
		st:   st
		sl:   sl
		vl:   unsafe { vl }
		ti:   ti
		conv: conv
	}
	ti.on_submit = fn [mut e] (s string) {
		e.submit(s)
	}
	mut cell := vgui.stack()
	cell.add(vl)
	cell.add(ti)
	cell.add(e)
	mut b := icon_button('pencil', i18n.tr('Ввести значение: Enter - применить, Esc - отмена'))
	b.on_click = fn [mut e] () {
		e.start()
	}
	return cell, b
}
