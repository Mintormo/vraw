module main

// Ручная коррекция объектива в секции «Коррекция» (lens/manual.v):
// дисторсия, хроматические аберрации по каналам, виньетирование. Для
// объективов без профиля в lensfun и для доводки поверх профиля. Как и
// профиль, правит линейное сырьё до пайплайна: отпускание ползунка -
// фоновая подготовка сырья заново (request_prep с коррекцией объектива,
// ~0.6 с на превью), по ходу перетаскивания снимок не меняется.
import vgui
import i18n

// lens_manual_rows - ряды ручной коррекции (подпись, ползунки, подсказка)
fn lens_manual_rows(mut st State, lbl_w f32, val_w f32) []SectionRow {
	fx := fn [mut st] () {
		if st.dev_linear.len == 0 || isnil(st.app) {
			return
		}
		mut app := st.app
		request_prep(mut st, mut app, true)
	}
	mut man_caption := vgui.label(i18n.tr('Вручную'))
	man_caption.font_style = .bold
	mut dist := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Дисторсия')
		hname:  i18n.tr('Объектив: дисторсия')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.lman.dist
		}
		set:    fn (mut e EditState, v f32) {
			e.lman.dist = v
		}
		fx:     fx
	})
	mut ca_r := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('ХА: красный')
		hname:  i18n.tr('Объектив: ХА красный/голубой')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.lman.ca_r
		}
		set:    fn (mut e EditState, v f32) {
			e.lman.ca_r = v
		}
		fx:     fx
	})
	mut ca_b := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('ХА: синий')
		hname:  i18n.tr('Объектив: ХА синий/жёлтый')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.lman.ca_b
		}
		set:    fn (mut e EditState, v f32) {
			e.lman.ca_b = v
		}
		fx:     fx
	})
	mut vign := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Виньетка')
		hname:  i18n.tr('Объектив: виньетирование')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.lman.vign
		}
		set:    fn (mut e EditState, v f32) {
			e.lman.vign = v
		}
		fx:     fx
	})
	mut mid := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Средняя точка')
		hname:  i18n.tr('Объектив: средняя точка')
		min:    0
		max:    100
		def:    50
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.lman.vign_mid
		}
		set:    fn (mut e EditState, v f32) {
			e.lman.vign_mid = v
		}
		fx:     fx
	})
	mut hint := vgui.label(i18n.tr('Дисторсия: плюс убирает бочку, минус - подушку'))
	st.hint_labels << hint
	hint.font_size = 12
	return [
		SectionRow{vgui.separator()},
		SectionRow{man_caption},
		SectionRow{edit_row(mut st, mut dist, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut ca_r, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut ca_b, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut vign, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut mid, lbl_w, val_w)},
		SectionRow{hint},
	]
}
