module main

// Поле значения ползунка панели - vgui.NumberField справа от ползунка (вместо
// прежних подписи значения и кнопки-карандаша с полем ввода, numedit.v):
// щелчок по нему - ввод точного числа (целого или дробного, через точку или
// запятую; Enter - применить, Esc - отмена, щелчок мимо - применить),
// протяжка мышью влево-вправо - быстрая правка (Shift - точнее). Число вне
// диапазона ползунка прижимается к краю.
//
// Поле и ползунок зеркалят друг друга: ползунок -> поле - в его on_change
// (vf.set_value, колбэков поля не зовёт), поле -> ползунок - здесь
// (Slider.set_value: on_change ползунка сам пишет настройку, подпись,
// пересчитывает и кладёт шаг в историю). Протяжка поля ведётся как
// перетаскивание ползунка: на время set_value ползунок помечен dragging -
// пересчёт и запись в историю его on_change откладывает до on_release,
// который зовёт on_commit поля. Иначе каждый шаг протяжки пересчитывал бы
// снимок целиком.

import vgui

// NumConv - число в поле <-> значение ползунка. По умолчанию число и есть
// значение; у температуры ползунок - положение на шкале, а в поле - кельвины.
// digits - знаков после запятой в поле.
struct NumConv {
	digits int = 2
	to     fn (f32) f32 = unsafe { nil } // значение ползунка -> число в поле
	from   fn (f32) f32 = unsafe { nil } // число в поле -> значение ползунка
}

fn (c NumConv) num_of(v f32) f32 {
	return if isnil(c.to) { v } else { c.to(v) }
}

fn (c NumConv) value_of(n f32) f32 {
	return if isnil(c.from) { n } else { c.from(n) }
}

// FieldDrag - шла ли протяжка поля (в куче: замыкание V захватывает копию
// переменной)
@[heap]
struct FieldDrag {
mut:
	active bool
}

// value_field - поле значения ползунка sl: границы - границы ползунка в
// числах поля, текст - text(значение ползунка) (nil - число с conv.digits
// знаками). Протяжка всего диапазона - около 400 px.
fn value_field(mut sl vgui.Slider, conv NumConv, text fn (f32) string) &vgui.NumberField {
	a := conv.num_of(sl.min)
	b := conv.num_of(sl.max)
	lo, hi := if a <= b { a, b } else { b, a }
	mut vf := vgui.number_field(
		value:  conv.num_of(sl.value)
		min:    lo
		max:    hi
		digits: conv.digits
	)
	vf.step = f64(hi - lo) / 50
	if conv.digits == 0 && vf.step < 1 {
		vf.step = 1
	}
	vf.show_fill = false // долю показывает сам ползунок
	vf.align = .right
	if !isnil(text) {
		vf.format = fn [text, conv] (n f64) string {
			return text(conv.value_of(f32(n)))
		}
	}
	mut fdrag := &FieldDrag{}
	vf.on_change = fn [mut sl, conv, mut fdrag, vf] (n f64) {
		v := conv.value_of(f32(n))
		if vf.is_dragging() {
			// Как перетаскивание ползунка: без пересчёта на каждом шаге
			fdrag.active = true
			sl.dragging = true
			sl.set_value(v)
			sl.dragging = false
		} else {
			sl.set_value(v)
		}
	}
	vf.on_commit = fn [mut sl, mut fdrag] (_ f64) {
		if !fdrag.active {
			return
		}
		fdrag.active = false
		if !isnil(sl.on_release) {
			sl.on_release(sl.value)
		}
	}
	return vf
}

// show_value - ползунок сменил значение: число в поле (без колбэков поля)
fn show_value(mut vf vgui.NumberField, conv NumConv, v f32) {
	vf.set_value(conv.num_of(v))
}
