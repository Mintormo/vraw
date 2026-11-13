module main

// Секции панели правки: ползунки, чекбоксы и подписи разделов, каждый
// раздел - своя функция, возвращает ряды секции (SectionRow); в аккордеон
// их кладёт main (app.v). Вынесено из main() 13.11.2026 (аудит, п. 11).
import vgui
import i18n

// prep_fx_fn - пересчёт подготовки сырья по отпусканию ползунка (шумодав,
// ореолы, Capture-резкость): LibRaw и коррекция объектива не
// перезапускаются - сырьё в raw_linear. Отпускание на уже применённом
// значении ничего не пересчитывает.
fn prep_fx_fn(mut st State, mut app vgui.App) fn () {
	return fn [mut st, mut app] () {
		if prep_stale(st) {
			request_prep(mut st, mut app, false)
		}
	}
}

// lens_nr_rows - секции «Коррекция» (объектив lensfun, ручная коррекция,
// профиль проявки) и «Шумодав и ореолы»
fn lens_nr_rows(mut st State, mut app vgui.App, lbl_w f32, val_w f32) ([]SectionRow, []SectionRow) {
	// Шумодав и ореолы - подготовка сырья (~1 с на превью, в фоне)
	prep_fx := prep_fx_fn(mut st, mut app)
	// Коррекция объектива (lensfun): применяется к линейному сырью до
	// пайплайна. Переключение пересчитывает сырьё из dev_linear (без
	// LibRaw) в фоне, ~0.6 с + шумодав - окно не замирает.
	// Подпись под чекбоксом - найденный профиль.
	mut lens_cb := vgui.checkbox(i18n.tr('Коррекция объектива'))
	lens_cb.checked = true
	lens_cb.on_change = fn [mut st, mut app] (v bool) {
		st.edit.lens_corr = v
		request_prep(mut st, mut app, true)
		record(mut st, 'lens', i18n.trf('Коррекция объектива: {0}', '${on_off(v)}'), false)
	}
	st.lens_cb = lens_cb
	mut lens_lb := vgui.label(i18n.tr(lens_no_info))
	st.secondary_labels << lens_lb

	// «Как JPEG камеры»: тональная кривая и множитель насыщенности,
	// подогнанные под встроенный JPEG (CamLook). Без них нейтральная
	// проявка - чистая гамма 2.2, темнее и блёклее камерного JPEG. Кривая
	// сидит в flut, насыщенность - множитель, поэтому переключение -
	// мгновенное (обычный apply, перепроявка не нужна). Ползунок
	// «Насыщенность» - относительно камерной (1.00 - как у камеры).
	// Профиль проявки (profile.v): нейтральный, как JPEG камеры, стили
	prof_row := profile_row(mut st, lbl_w)

	// Шумодав и ореолы: в «Сброс» не входят (подготовка сырья, не тон)
	mut imp := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Импульсный')
		hname:  i18n.tr('Импульсный шум')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.nr[0]
		}
		set:    fn (mut e EditState, v f32) {
			e.nr[0] = v
		}
		fx:     prep_fx
	})
	mut nrl := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Яркостный')
		hname:  i18n.tr('Шумодав: яркостный')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.nr[1]
		}
		set:    fn (mut e EditState, v f32) {
			e.nr[1] = v
		}
		fx:     prep_fx
	})
	mut nrc := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Цветовой')
		hname:  i18n.tr('Шумодав: цветовой')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.nr[2]
		}
		set:    fn (mut e EditState, v f32) {
			e.nr[2] = v
		}
		fx:     prep_fx
	})
	mut df := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Ореолы')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.nr[3]
		}
		set:    fn (mut e EditState, v f32) {
			e.nr[3] = v
		}
		fx:     prep_fx
	})

	st.lens_lb = lens_lb
	mut lens_rows := [SectionRow{lens_cb}, SectionRow{lens_lb}]
	lens_rows << lens_manual_rows(mut st, lbl_w, val_w)
	lens_rows << SectionRow{vgui.separator()}
	lens_rows << SectionRow{prof_row}
	return lens_rows, [
		SectionRow{edit_row(mut st, mut imp, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut nrl, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut nrc, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut df, lbl_w, val_w)},
	]
}

// tone_rows - «Экспозиция и тон» (без ряда «Автотон» - его добавляет
// main), «Тени/Света» и «Тон-эквалайзер»
fn tone_rows(mut st State, lbl_w f32, val_w f32) ([]SectionRow, []SectionRow, []SectionRow) {
	tone_fx := st.tone_fx
	// Тональные ползунки: пайплайн (~60 мс на превью) - по отпусканию,
	// чтобы драг не подтормаживал; при перетаскивании только подпись.
	mut exp := edit_slider(mut st, SliderCfg{
		label: i18n.tr('Экспозиция')
		min:   -4
		max:   4
		get:   fn (e &EditState) f32 {
			return e.params.exposure
		}
		set:   fn (mut e EditState, v f32) {
			e.params.exposure = v
		}
		fx:    tone_fx
	})
	mut sh := edit_slider(mut st, SliderCfg{
		label: i18n.tr('Тени')
		min:   -4
		max:   4
		get:   fn (e &EditState) f32 {
			return e.params.shadows
		}
		set:   fn (mut e EditState, v f32) {
			e.params.shadows = v
		}
		fx:    tone_fx
	})
	mut con := edit_slider(mut st, SliderCfg{
		label: i18n.tr('Контраст')
		min:   -4
		max:   4
		get:   fn (e &EditState) f32 {
			return e.params.contrast
		}
		set:   fn (mut e EditState, v f32) {
			e.params.contrast = v
		}
		fx:    tone_fx
	})
	// Чёткость (Clarity, pipeline/clarity.v) - локальный контраст средних
	// деталей; минус смягчает
	mut clr := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Чёткость')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.params.clarity
		}
		set:    fn (mut e EditState, v f32) {
			e.params.clarity = v
		}
		fx:     tone_fx
	})
	// Текстура (pipeline/texture.v) - средняя детализация: листва, кора,
	// ткань; минус смягчает (кожа)
	mut txr := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Текстура')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.params.texture
		}
		set:    fn (mut e EditState, v f32) {
			e.params.texture = v
		}
		fx:     tone_fx
	})
	// Сочность - бережная насыщенность (pipeline.vibrance_pixel): блёклые
	// цвета сильнее насыщенных, тона кожи защищены
	mut vib := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Сочность')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.params.vibrance
		}
		set:    fn (mut e EditState, v f32) {
			e.params.vibrance = v
		}
		fx:     tone_fx
	})
	mut sat := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Насыщенность')
		max:    4
		def:    1
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.saturation
		}
		set:    fn (mut e EditState, v f32) {
			e.params.saturation = v
		}
		fx:     tone_fx
	})

	// «Тени/Света» как в RawTherapee: маска по РАЗМЫТОЙ люме (blur_luma),
	// поэтому подъём теней сохраняет локальный контраст и не даёт плоской
	// картинки, а приглушение светов не серит мелкие блики.
	mut hlt := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Света')
		hname:  i18n.tr('Тени/Света: света')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sh_highlights
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sh_highlights = v
		}
		fx:     tone_fx
	})
	mut sht := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Тени')
		hname:  i18n.tr('Тени/Света: тени')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sh_shadows
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sh_shadows = v
		}
		fx:     tone_fx
	})

	// Тон-эквалайзер: пять полос по яркости
	eq_names := [i18n.tr('Чёрные'), i18n.tr('Тени'), i18n.tr('Средние'), i18n.tr('Света'), i18n.tr('Белые')]
	mut eq_rows := []&vgui.HBox{}
	for i in 0 .. 5 {
		mut s := edit_slider(mut st, SliderCfg{
			label: eq_names[i]
			hname: i18n.trf('Эквалайзер: {0}', '${eq_names[i]}')
			min:   -4
			max:   4
			get:   fn [i] (e &EditState) f32 {
				return e.params.eq[i]
			}
			set:   fn [i] (mut e EditState, v f32) {
				e.params.eq[i] = v
			}
			fx:    tone_fx
		})
		eq_rows << edit_row(mut st, mut s, lbl_w, val_w)
		// зоны гистограммы ведут эти ползунки (histogram.v)
		st.hv.eq_sl << s.sl
		st.hv.eq_txt << eq_names[i]
	}

	tone := [
		SectionRow{edit_row(mut st, mut exp, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut sh, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut con, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut txr, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut clr, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut vib, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut sat, lbl_w, val_w)},
	]
	shadows := [
		SectionRow{edit_row(mut st, mut hlt, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut sht, lbl_w, val_w)},
	]
	mut eq_items := []SectionRow{}
	for row in eq_rows {
		eq_items << SectionRow{row}
	}
	return tone, shadows, eq_items
}

// curve_rows - «Кривые»: кнопки каналов, редактор, подсказка
fn curve_rows(mut st State, mut cv vgui.Canvas, mut hist vgui.Canvas) []SectionRow {
	// ── Кривые: кнопки каналов, редактор, подсказка ──
	// Картинка пересчитывается при отпускании точки (on_release), как и
	// у ползунков; кривые других каналов видны в редакторе призраками.
	mut ed := vgui.curve_editor()
	st.curve_ed = ed
	ed.on_release = fn [mut st, mut cv, mut hist, mut ed] () {
		st.edit.curve_pts[st.curve_ch] = ed.points.clone()
		curves_to_params(mut st)
		apply_pipeline(mut st, mut cv, mut hist)
		record(mut st, 'curve${st.curve_ch}', i18n.trf('Кривая {0}', '${curve_names[st.curve_ch]}'), false)
	}
	// Обработчик ставится на только что созданную кнопку. НЕ через
	// `mut b := массив[c]; b.on_click = fn ...` - это ошибка компилятора V:
	// замыкание, присвоенное так в цикле, указывает на чужой контекст
	// (кнопки молча не работали). Стили - по индексу st.curve_btns[j].
	mut ch_row := vgui.create_hbox_fill()
	ch_row.set_spacing(6)
	for c in 0 .. 4 {
		mut b := vgui.button(curve_names[c])
		b.style = if c == 0 { vgui.ButtonStyle.accent } else { vgui.ButtonStyle.outline }
		b.on_click = fn [mut st, c] () {
			st.curve_ch = c
			for j in 0 .. st.curve_btns.len {
				st.curve_btns[j].style = if j == c {
					vgui.ButtonStyle.accent
				} else {
					vgui.ButtonStyle.outline
				}
			}
			sync_curve_editor(mut st)
		}
		st.curve_btns << b
		ch_row.add(b, flex: 1)
	}
	mut curve_reset := reset_button(i18n.tr('Сбросить кривую канала'))
	curve_reset.on_click = fn [mut st, mut cv, mut hist] () {
		st.edit.curve_pts[st.curve_ch] = identity_curve()
		curves_to_params(mut st)
		sync_curve_editor(mut st)
		apply_pipeline(mut st, mut cv, mut hist)
		record(mut st, 'curve${st.curve_ch}', i18n.trf('Кривая {0}: сброс', '${curve_names[st.curve_ch]}'),
			false)
	}
	ch_row.add(curve_reset)
	mut curve_hint := vgui.label(i18n.tr('Щелчок - точка, правая кнопка - удалить, двойной - сброс'))
	st.hint_labels << curve_hint
	curve_hint.font_size = 12
	sync_curve_editor(mut st)

	return [SectionRow{ch_row}, SectionRow{ed}, SectionRow{curve_hint}]
}

// hsl_rows - «HSL»: вкладки «Оттенок / Насыщенность / Яркость»
fn hsl_rows(mut st State, lbl_w f32, val_w f32) []SectionRow {
	tone_fx := st.tone_fx
	// ── HSL: вкладки «Оттенок / Насыщенность / Яркость», 8 диапазонов ──
	mut hsl_tabs := vgui.tab_box()
	for m in 0 .. 3 {
		mut rows := []SectionRow{}
		for i in 0 .. 8 {
			mut s := edit_slider(mut st, SliderCfg{
				label:  i18n.tr(hsl_names[i])
				hname:  'HSL ${i18n.tr(hsl_modes[m]).to_lower()}: ${i18n.tr(hsl_names[i])}'
				min:    -100
				max:    100
				digits: 0
				get:    fn [m, i] (e &EditState) f32 {
					return match m {
						0 { e.params.hsl_hue[i] }
						1 { e.params.hsl_sat[i] }
						else { e.params.hsl_lum[i] }
					}
				}
				set:    fn [m, i] (mut e EditState, v f32) {
					match m {
						0 { e.params.hsl_hue[i] = v }
						1 { e.params.hsl_sat[i] = v }
						else { e.params.hsl_lum[i] = v }
					}
				}
				fx:     tone_fx
			})
			mut lb := s.lb
			st.hsl_labels << lb // цвет диапазона, под тему - paint_ui
			rows << SectionRow{edit_row(mut st, mut s, lbl_w, val_w)}
		}
		hsl_tabs.add_tab(i18n.tr(hsl_modes[m]), section(rows))
	}

	return [SectionRow{hsl_tabs}]
}

// sharp_rows - «Резкость»: Capture-резкость (деконволюция) и нерезкое
// маскирование
fn sharp_rows(mut st State, mut app vgui.App, lbl_w f32, val_w f32) []SectionRow {
	tone_fx := st.tone_fx
	prep_fx := prep_fx_fn(mut st, mut app)
	// ── Резкость: unsharp mask по люме (pipeline/sharpen.v) - последний
	// шаг пайплайна, тональный пересчёт по отпусканию. Радиус - в
	// пикселях полного кадра (на превью половинного размера - вдвое меньше)
	mut sh_amount := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Величина')
		hname:  i18n.tr('Резкость: величина')
		max:    150
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sharp.amount
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.amount = v
		}
		fx:     tone_fx
		drag_view: .detail
	})
	mut sh_radius := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Радиус')
		hname:  i18n.tr('Резкость: радиус')
		min:    0.5
		max:    3
		def:    1
		signed: false
		show:   fn (v f32) string {
			return '${v:.2f} px'
		}
		get:    fn (e &EditState) f32 {
			return e.params.sharp.radius
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.radius = v
		}
		fx:     tone_fx
		drag_view: .detail
	})
	mut sh_detail := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Порог')
		hname:  i18n.tr('Резкость: порог')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sharp.detail
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.detail = v
		}
		fx:     tone_fx
		drag_view: .detail
	})
	mut sh_mask := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Маска краёв')
		hname:  i18n.tr('Резкость: маска краёв')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sharp.masking
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.masking = v
		}
		fx:     tone_fx
		drag_view: .mask
	})
	// По каналам RGB - правка кадра (история, сайдкар)
	mut sh_rgb_cb := vgui.checkbox(i18n.tr('По каналам RGB'))
	sh_rgb_cb.on_change = fn [mut st, tone_fx] (v bool) {
		st.edit.params.sharp.rgb = v
		tone_fx()
		record(mut st, 'sharp_rgb', i18n.trf('Резкость по каналам RGB: {0}', '${on_off(v)}'), false)
	}
	st.sharp_rgb_cb = sh_rgb_cb
	// Маска краёв вместо снимка - вид, не правка (в историю не пишется)
	mut sh_show_cb := vgui.checkbox(i18n.tr('Показать маску краёв'))
	sh_show_cb.on_change = fn [mut st, tone_fx] (v bool) {
		st.sharp_show = v
		tone_fx()
	}
	mut sharp_hint := vgui.label(i18n.tr('Оценивать в 100%. Alt при перетаскивании - маска или детали'))
	st.hint_labels << sharp_hint
	sharp_hint.font_size = 12
	// ── Capture-резкость: деконволюция Ричардсона-Люси по линейному сырью
	// (pipeline/deconv.v) - подготовка сырья, как шумодав: пересчёт в фоне
	// по отпусканию (prep_fx)
	mut dc_amount := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Сила')
		hname:  i18n.tr('Capture-резкость: сила')
		max:    100
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sharp.dc_amount
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.dc_amount = v
		}
		fx:     prep_fx
	})
	mut dc_radius := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Радиус')
		hname:  i18n.tr('Capture-резкость: радиус')
		min:    0.4
		max:    1.5
		def:    0.75
		signed: false
		show:   fn (v f32) string {
			return '${v:.2f} px'
		}
		get:    fn (e &EditState) f32 {
			return e.params.sharp.dc_radius
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.dc_radius = v
		}
		fx:     prep_fx
	})
	mut dc_contrast := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Порог')
		hname:  i18n.tr('Capture-резкость: порог')
		max:    100
		def:    10
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.sharp.dc_contrast
		}
		set:    fn (mut e EditState, v f32) {
			e.params.sharp.dc_contrast = v
		}
		fx:     prep_fx
	})
	mut usm_caption := vgui.label(i18n.tr('Нерезкое маскирование'))
	usm_caption.font_style = .bold
	mut dc_caption := vgui.label(i18n.tr('Capture-резкость (деконволюция)'))
	dc_caption.font_style = .bold
	mut dc_hint := vgui.label(i18n.tr('Возвращает резкость оптики; порог бережёт ровное и шум'))
	st.hint_labels << dc_hint
	dc_hint.font_size = 12
	return [
		SectionRow{dc_caption},
		SectionRow{edit_row(mut st, mut dc_amount, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut dc_radius, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut dc_contrast, lbl_w, val_w)},
		SectionRow{dc_hint},
		SectionRow{vgui.separator()},
		SectionRow{usm_caption},
		SectionRow{edit_row(mut st, mut sh_amount, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut sh_radius, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut sh_detail, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut sh_mask, lbl_w, val_w)},
		SectionRow{sh_rgb_cb},
		SectionRow{sh_show_cb},
		SectionRow{sharp_hint},
	]
}

// haze_rows - «Удаление дымки»
fn haze_rows(mut st State, lbl_w f32, val_w f32) []SectionRow {
	tone_fx := st.tone_fx
	// ── Удаление дымки (как в RawTherapee): тёмный канал, pipeline/dehaze.v.
	// Карта дымки - по сырью кадра, сила и глубина - живые (apply)
	mut hz_str := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Сила')
		hname:  i18n.tr('Дымка: сила')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.params.haze
		}
		set:    fn (mut e EditState, v f32) {
			e.params.haze = v
		}
		fx:     tone_fx
	})
	mut hz_depth := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Глубина')
		hname:  i18n.tr('Дымка: глубина')
		max:    100
		def:    25
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.haze_depth
		}
		set:    fn (mut e EditState, v f32) {
			e.params.haze_depth = v
		}
		fx:     tone_fx
	})
	// Карта глубины вместо снимка - вид, не правка (в историю не пишется)
	mut hz_map_cb := vgui.checkbox(i18n.tr('Показать карту глубины'))
	hz_map_cb.on_change = fn [mut st, tone_fx] (v bool) {
		st.haze_show = v
		tone_fx()
	}
	mut hz_hint := vgui.label(i18n.tr('Минус - добавить дымку; глубина - насколько близко к камере'))
	st.hint_labels << hz_hint
	hz_hint.font_size = 12

	return [
		SectionRow{edit_row(mut st, mut hz_str, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut hz_depth, lbl_w, val_w)},
		SectionRow{hz_map_cb},
		SectionRow{hz_hint},
	]
}

// fx_rows - «Эффекты»: виньетка после кадрирования и зерно
fn fx_rows(mut st State, lbl_w f32, val_w f32) []SectionRow {
	tone_fx := st.tone_fx
	// ── Эффекты (pipeline/effects.v): виньетка после кадрирования и
	// плёночное зерно - по тону в конце проявки, живые (apply)
	mut vig_caption := vgui.label(i18n.tr('Виньетка'))
	vig_caption.font_style = .bold
	mut grain_caption := vgui.label(i18n.tr('Зерно'))
	grain_caption.font_style = .bold
	mut vig_amt := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Величина')
		hname:  i18n.tr('Виньетка')
		min:    -100
		max:    100
		def:    0
		digits: 0
		signed: true
		get:    fn (e &EditState) f32 {
			return e.params.fx.vig_amount
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.vig_amount = v
		}
		fx:     tone_fx
	})
	mut vig_mid := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Средняя точка')
		hname:  i18n.tr('Виньетка: средняя точка')
		min:    0
		max:    100
		def:    50
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.fx.vig_mid
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.vig_mid = v
		}
		fx:     tone_fx
	})
	mut vig_rnd := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Округлость')
		hname:  i18n.tr('Виньетка: округлость')
		min:    -100
		max:    100
		def:    0
		digits: 0
		signed: true
		get:    fn (e &EditState) f32 {
			return e.params.fx.vig_round
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.vig_round = v
		}
		fx:     tone_fx
	})
	mut vig_fth := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Растушёвка')
		hname:  i18n.tr('Виньетка: растушёвка')
		min:    0
		max:    100
		def:    50
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.fx.vig_feather
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.vig_feather = v
		}
		fx:     tone_fx
	})
	mut grn_amt := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Величина')
		hname:  i18n.tr('Зерно')
		min:    0
		max:    100
		def:    0
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.fx.grain
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.grain = v
		}
		fx:     tone_fx
	})
	mut grn_size := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Размер')
		hname:  i18n.tr('Зерно: размер')
		min:    0
		max:    100
		def:    25
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.fx.grain_size
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.grain_size = v
		}
		fx:     tone_fx
	})
	mut grn_rough := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Грубость')
		hname:  i18n.tr('Зерно: грубость')
		min:    0
		max:    100
		def:    50
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.fx.grain_rough
		}
		set:    fn (mut e EditState, v f32) {
			e.params.fx.grain_rough = v
		}
		fx:     tone_fx
	})
	mut fx_hint := vgui.label(i18n.tr('Минус - тёмные края, плюс - светлые; зерно точно видно на 1:1'))
	st.hint_labels << fx_hint
	fx_hint.font_size = 12

	return [
		SectionRow{vig_caption},
		SectionRow{edit_row(mut st, mut vig_amt, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut vig_mid, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut vig_rnd, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut vig_fth, lbl_w, val_w)},
		SectionRow{vgui.separator()},
		SectionRow{grain_caption},
		SectionRow{edit_row(mut st, mut grn_amt, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut grn_size, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut grn_rough, lbl_w, val_w)},
		SectionRow{fx_hint},
	]
}

// history_rows - «История»: список записей, «до» для сравнения, очистка
// истории, подсказка с сочетаниями отмены
fn history_rows(mut st State, mut app vgui.App, win &vgui.Window, mut cv vgui.Canvas, mut hist vgui.Canvas) []SectionRow {
	// ── История правок: список, текущая запись выделена ──
	// Щелчок (или стрелки в списке) - откат к записи, более поздняя -
	// возврат вперёд; новая правка после отката отрезает «будущее».
	mut hist_lb := vgui.list_box()
	hist_lb.item_height = 22
	// Одна колонка без заголовка: строки - цветные подписи (отменённые
	// правки серые), а ячейки-виджеты вертикальный список рисует только
	// по колонкам
	hist_lb.add_column('', 360)
	hist_lb.show_header = false // add_column включает заголовок
	// Одиночный щелчок (и стрелки) только выделяет запись; переход -
	// двойным щелчком или Enter (on_dbl_click зовётся на оба)
	hist_lb.on_dbl_click = fn [mut st, mut cv, mut hist, mut app] (idx int, text string) {
		goto_history(mut st, idx, mut cv, mut hist, mut app)
	}
	st.hist_lb = hist_lb
	// «До» для сравнения (compare.v) - выделенная запись: подпись, кнопка
	// и сброс к первой записи
	mut ba_lb := vgui.label(i18n.tr('До: первая запись'))
	st.secondary_labels << ba_lb
	st.ba_lb = ba_lb
	mut b_ba := icon_button('git-compare', i18n.tr('Выделенная запись - «до» для сравнения'))
	st.hk_texts << fn [st, mut b_ba] () {
		keys := [hk_key(st, 'view.split'), hk_key(st, 'view.sbs')]
		mut t := i18n.tr('Выделенная запись - «до» для сравнения')
		if keys[0].len > 0 || keys[1].len > 0 {
			mut parts := []string{}
			if keys[0].len > 0 {
				parts << i18n.trf('шторка {0}', '${keys[0]}')
			}
			if keys[1].len > 0 {
				parts << i18n.trf('бок о бок {0}', '${keys[1]}')
			}
			t += ' (${parts.join(', ')})'
		}
		b_ba.tooltip = t
	}
	b_ba.on_click = fn [mut st] () {
		if isnil(st.hist_lb) {
			return
		}
		set_ba_ref(mut st, st.hist_lb.selected)
	}
	mut b_ba0 := reset_button(i18n.tr('«До» - первая запись'))
	b_ba0.on_click = fn [mut st] () {
		set_ba_ref(mut st, 0)
	}
	// Очистка истории: все правки удаляются, кадр - исходный (history.v), с
	// вопросом - вернуть нельзя
	mut b_clr := icon_button('eraser', i18n.tr('Очистить историю: удалить все правки кадра'))
	b_clr.on_click = fn [mut st, win, mut cv, mut hist, mut app] () {
		if !history_clearable(st) {
			return
		}
		answer := vgui.message_box(win, mut app, vgui.MessageBoxConfig{
			title:          i18n.tr('Очистить историю')
			message:        i18n.tr('Удалить все правки кадра и историю? Кадр вернётся к исходному виду, вернуть правки будет нельзя.')
			kind:           .warning
			buttons:        [i18n.tr('Очистить'), i18n.tr('Отмена')]
			default_button: 1
			cancel_button:  1
		})
		if answer == 0 {
			clear_history(mut st, mut cv, mut hist, mut app)
		}
	}
	st.hist_clear = b_clr
	mut ba_row := vgui.create_hbox_fill()
	ba_row.set_spacing(6)
	ba_row.add(ba_lb, flex: 1)
	ba_row.add(b_ba)
	ba_row.add(b_ba0)
	ba_row.add(b_clr)
	mut hist_hint := vgui.label(i18n.tr('Двойной щелчок - перейти'))
	st.hint_labels << hist_hint
	hist_hint.font_size = 12
	st.hk_texts << fn [st, mut hist_hint] () {
		keys := [hk_key(st, 'edit.undo'), hk_key(st, 'edit.redo')].filter(it.len > 0)
		hist_hint.text = i18n.tr('Двойной щелчок - перейти') + if keys.len > 0 {
			', ${keys.join(' / ')}'
		} else {
			''
		}
	}
	return [SectionRow{hist_lb}, SectionRow{ba_row}, SectionRow{hist_hint}]
}

// PanelItems - ряды секций панели (собирает main функциями этого файла и
// build_*_section других)
struct PanelItems {
	lens      []SectionRow
	crop      []SectionRow
	wb        []SectionRow
	tone      []SectionRow
	haze      []SectionRow
	shadows   []SectionRow
	eq        []SectionRow
	curves    []SectionRow
	hsl       []SectionRow
	pcolor    []SectionRow
	masks     []SectionRow
	spots     []SectionRow
	nr        []SectionRow
	sharp     []SectionRow
	fx        []SectionRow
	history   []SectionRow
}

// build_panel - правая панель: гистограмма сверху, под ней в прокрутке
// аккордеон секций (порядок и скрытые - по настройкам, layout_panel); ряд
// «Автотон» - первым в «Экспозиции и тоне». Зовётся после меню: подписи с
// сочетаниями (hk_refresh) - когда все действия уже зарегистрированы.
fn build_panel(mut st State, mut ph Placeholder, mut hist vgui.Canvas, auto_tone_fn fn (), p PanelItems, lbl_w f32, val_w f32) &vgui.VBox {
	// Ряд «Автотон» - кнопка по своей ширине, слева
	mut b_autotone := vgui.button(i18n.tr('Автотон'))
	b_autotone.icon_name = 'wand-sparkles'
	b_autotone.icon_size = 15
	b_autotone.on_click = auto_tone_fn
	b_autotone.tooltip = i18n.tr('Экспозиция, контраст, тени/света, чёрные и белые по гистограмме')
	st.hk_texts << fn [st, mut b_autotone] () {
		b_autotone.tooltip = i18n.tr('Экспозиция, контраст, тени/света, чёрные и белые по гистограмме') +
			hk_paren(st, 'edit.autotone')
	}
	st.hk_texts << fn [mut st, mut ph] () {
		ko := hk_key(st, 'file.open')
		kd := hk_key(st, 'file.open_dir')
		mut parts := []string{}
		if ko.len > 0 {
			parts << i18n.trf('{0} - файл', '${ko}')
		}
		if kd.len > 0 {
			parts << i18n.trf('{0} - папка', '${kd}')
		}
		ph.open_hint = if parts.len > 0 {
			i18n.trf('Меню «Файл»: {0}', '${parts.join(', ')}')
		} else {
			i18n.tr('Меню «Файл» - открыть файл или папку')
		}
		set_placeholder_text(mut ph, st.frames.len > 0)
	}
	// Подписи по сочетаниям - все действия уже зарегистрированы
	hk_refresh(mut st)
	mut at_row := vgui.create_hbox_fill()
	at_row.add(b_autotone)
	at_row.add(vgui.label(''), flex: 1)
	// Гистограмма и кнопки файлов закреплены сверху, кнопки вида - снизу;
	// всё остальное (чекбоксы и ползунки) прокручивается в ScrollBox
	// с тонким ползунком. Высота контента считается автоматически
	// (scroll_box(0) суммирует add_fixed внутреннего VBox).
	// Инструменты сгруппированы в аккордеон: секции открываются
	// независимо (multi), каждая высотой по содержимому (fit_content) -
	// аккордеон целиком прокручивается в ScrollBox.
	mut acc := vgui.accordion_multi()
	acc.fit_content = true
	acc.spacing = 4
	acc.header_height = 30
	panel_add(mut st, 'lens', section(p.lens))
	panel_add(mut st, 'crop', section(p.crop))
	panel_add(mut st, 'wb', section(p.wb))
	mut tone_items := [SectionRow{at_row}]
	tone_items << p.tone
	panel_add(mut st, 'tone', section(tone_items))
	panel_add(mut st, 'haze', section(p.haze))
	panel_add(mut st, 'shadows', section(p.shadows))
	panel_add(mut st, 'eq', section(p.eq))
	panel_add(mut st, 'curves', section(p.curves))
	panel_add(mut st, 'hsl', section(p.hsl))
	panel_add(mut st, 'pcolor', section(p.pcolor))
	panel_add(mut st, 'bw', bw_section(mut st, lbl_w, val_w))
	panel_add(mut st, 'grade', grade_section(mut st, lbl_w, val_w))
	panel_add(mut st, 'masks', section(p.masks))
	panel_add(mut st, 'spots', section(p.spots))
	// Раскрытая секция «Градиентные фильтры» показывает метки всех
	// фильтров на снимке (индекс секции - layout_panel)
	acc.on_change = fn [mut st] (idx int, open bool) {
		if !isnil(st.mask_ui) && idx == st.mask_ui.acc_idx {
			mask_redraw(st)
		}
	}
	panel_add(mut st, 'nr', section(p.nr))
	panel_add(mut st, 'sharp', section(p.sharp))
	panel_add(mut st, 'fx', section(p.fx))
	// История - последней секцией (по умолчанию): 8 строк списка и подсказка
	panel_add(mut st, 'history', section(p.history))

	// Секции - по настройкам: порядок и скрытые разделы (panel.v)
	st.acc = acc
	layout_panel(mut st)

	mut scroll := vgui.scroll_box(0)
	scroll.sb_width = 8
	scroll.add(acc)

	// Правая панель - свой фон и внутренние отступы: гистограмма сверху,
	// инструменты в прокрутке. Открытие, экспорт, масштаб и «Сбросить
	// тон» - в меню вверху окна.
	mut right := vgui.create_vbox_fill()
	right.set_spacing(6)
	right.set_padding(10)
	st.right = right
	right.add(hist)
	right.add(scroll, flex: 1)
	return right
}
