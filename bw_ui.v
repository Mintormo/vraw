module main

// Раздел «Чёрно-белое» (pipeline/bw.v): флажок режима и микшер - 8
// ползунков яркости диапазонов оттенков (подписи цветом диапазона, как у
// HSL). Сдвиг ползунка микшера в цветном режиме сам включает Ч/Б (как в
// Lightroom) - иначе движение ползунка ничего бы не меняло.
import vgui

fn bw_section(mut st State, lbl_w f32, val_w f32) &vgui.VBox {
	tone_fx := st.tone_fx
	mut cb := vgui.checkbox('Включить')
	cb.on_change = fn [mut st, tone_fx] (v bool) {
		st.edit.params.bw = v
		tone_fx()
		record(mut st, 'bw', 'Чёрно-белое: ${on_off(v)}', false)
	}
	st.bw_cb = cb
	mut rows := []SectionRow{}
	rows << SectionRow{cb}
	for i in 0 .. 8 {
		mut s := edit_slider(mut st, SliderCfg{
			label:  hsl_names[i]
			hname:  'Ч/Б: ${hsl_names[i]}'
			min:    -100
			max:    100
			digits: 0
			get:    fn [i] (e &EditState) f32 {
				return e.params.bw_mix[i]
			}
			set:    fn [mut st, i] (mut e EditState, v f32) {
				e.params.bw_mix[i] = v
				if !st.suppress && v != 0 && !e.params.bw {
					e.params.bw = true
					sync_bw_ui(mut st)
				}
			}
			fx:     tone_fx
		})
		mut lb := s.lb
		st.hsl_labels << lb // цвет диапазона, под тему - paint_ui
		rows << SectionRow{edit_row(mut st, mut s, lbl_w, val_w)}
	}
	mut hint := vgui.label('Яркость цветов кадра в сером. Насыщенность, сочность и HSL в Ч/Б не действуют')
	hint.font_size = 12
	hint.wrap = true
	st.hint_labels << hint
	rows << SectionRow{hint}
	return section(rows)
}

// sync_bw_ui - флажок по st.edit (откат, новый кадр, вставка настроек;
// set_checked не зовёт on_change)
fn sync_bw_ui(mut st State) {
	if isnil(st.bw_cb) {
		return
	}
	mut cb := st.bw_cb
	cb.set_checked(st.edit.params.bw)
}
