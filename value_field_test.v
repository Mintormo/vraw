module main

// Поле значения ползунка (value_field.v): границы и число - в единицах поля
// (через NumConv), текст - как у подписи ползунка, правка поля двигает
// ползунок, а ползунок - поле (без колбэков поля).

import vgui

fn test_value_field_conv_and_sync() {
	mut sl := vgui.slider_horizontal(0, 1, 0.5)
	// Поле - в процентах: ползунок 0..1, число 0..100
	conv := NumConv{
		digits: 0
		to:     fn (v f32) f32 {
			return v * 100
		}
		from:   fn (n f32) f32 {
			return n / 100
		}
	}
	text := fn (v f32) string {
		return '${int(v * 100 + 0.5)}%'
	}
	mut vf := value_field(mut sl, conv, text)
	assert vf.min == 0 && vf.max == 100
	assert vf.value == 50
	assert vf.text() == '50%'
	// Поле -> ползунок (как ввод с клавиатуры: on_change вне протяжки)
	vf.on_change(25)
	assert sl.value == 0.25
	// Ползунок -> поле (show_value в on_change ползунка): колбэков поля нет
	mut calls := &FieldDrag{}
	vf.on_commit = fn [mut calls] (_ f64) {
		calls.active = true
	}
	show_value(mut vf, conv, 0.75)
	assert vf.value == 75 && !calls.active
}

fn test_value_field_plain_numbers() {
	mut sl := vgui.slider_horizontal(1, 100, 35)
	mut vf := value_field(mut sl, NumConv{ digits: 0 }, unsafe { nil })
	assert vf.text() == '35'
	assert vf.step >= 1, 'целые - шаг не меньше 1'
}
