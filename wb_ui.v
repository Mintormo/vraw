module main

// Баланс белого в окне: секция «Баланс белого» правой панели.
//
// Настройки кадра - EditState.wb_mode/wb_temp/wb_tint (история, сайдкар);
// матрица для пайплайна - производное поле params.wb (wb_derive по цвету
// камеры кадра st.cam, pipeline/wb.v). Режим «как снято» ('') - матрицы
// нет, ползунки показывают температуру и оттенок камерного ББ (st.shot_*).
// Всё - тональная правка: пересчёт - обычный apply (живые ползунки по
// отпусканию), LibRaw не перепроявляется.
import vgui
import pipeline
import i18n

// Режимы: ключ (в EditState и сайдкаре), название, температура и оттенок
// пресета (Adobe: дневной свет 5500/+10 и т.д.)
const wb_modes = ['', 'auto', 'daylight', 'cloudy', 'shade', 'tungsten', 'fluorescent', 'flash',
	'custom']
const wb_names = ['Как снято', 'Авто', 'Дневной свет', 'Облачно', 'Тень', 'Лампа накаливания',
	'Люминесцентная', 'Вспышка', 'Свой']
const wb_preset_temp = [f32(0), 0, 5500, 6500, 7500, 2850, 3800, 5500, 0]
const wb_preset_tint = [f32(0), 0, 10, 10, 10, 0, 21, 0, 0]

// Половина пятна пипетки: среднее 9x9 пикселей превью
const wb_pick_r = 4

// Положение ползунка температуры 0..1000 - равномерно в майредах (так
// равномерно и восприятие): слева 2000 K, справа 12000 K
const wb_pos_max = f32(1000)

fn temp_to_pos(t f32) f32 {
	lo := 1e6 / pipeline.wb_temp_min
	hi := 1e6 / pipeline.wb_temp_max
	return (lo - 1e6 / t) / (lo - hi) * wb_pos_max
}

fn pos_to_temp(p f32) f32 {
	lo := 1e6 / pipeline.wb_temp_min
	hi := 1e6 / pipeline.wb_temp_max
	return f32(1e6 / (lo - p / wb_pos_max * (lo - hi)))
}

// Температура на ползунке с шагом 50 K - как в Lightroom
fn temp_text(t f32) string {
	return '${int(t / 50 + 0.5) * 50} K'
}

fn wb_mode_idx(mode string) int {
	i := wb_modes.index(mode)
	return if i < 0 { 0 } else { i }
}

// wb_derive - матрица ББ в params по настройкам снимка и цвету камеры
fn wb_derive(mut e EditState, cam pipeline.CamColor) {
	if e.wb_mode == '' || e.wb_temp <= 0 {
		e.params.wb_on = false
		e.params.wb = pipeline.WbXform{}
		return
	}
	e.params.wb_on = true
	e.params.wb = cam.wb_xform(e.wb_temp, e.wb_tint)
}

// wb_values - температура и оттенок, которые показывает панель: у «как
// снято» - камерные
fn wb_values(st &State, e &EditState) (f32, f32) {
	if e.wb_mode == '' {
		return st.shot_temp, st.shot_tint
	}
	return e.wb_temp, e.wb_tint
}

// set_cam_color - цвет камеры открытого кадра (raw.open, до set_edit)
fn set_cam_color(mut st State, c pipeline.CamColor) {
	st.cam = c
	st.shot_temp, st.shot_tint = c.as_shot()
}

// set_wb - новые настройки ББ (режим, пипетка): снимок, матрица, ползунки
// под suppress, выбор в списке, apply и запись в историю
fn set_wb(mut st State, mode string, t f32, tint f32, name string) {
	st.edit.wb_mode = mode
	st.edit.wb_temp = if mode == '' { f32(0) } else { t }
	st.edit.wb_tint = if mode == '' { f32(0) } else { tint }
	wb_derive(mut st.edit, st.cam)
	sync_wb_sliders(mut st)
	sync_wb_mode(mut st)
	st.tone_fx()
	record(mut st, 'wb', i18n.trf('Баланс белого: {0}', '${name}'), false)
}

// sync_wb_sliders - ползунки по st.edit (без пересчётов и записей)
fn sync_wb_sliders(mut st State) {
	if isnil(st.wb_temp_sl) {
		return
	}
	t, tint := wb_values(st, &st.edit)
	st.suppress = true
	mut ts := st.wb_temp_sl
	ts.set_value(temp_to_pos(t))
	mut tn := st.wb_tint_sl
	tn.set_value(tint)
	st.suppress = false
}

// sync_wb_mode - выбранный режим в списке (set_selected не зовёт on_change)
fn sync_wb_mode(mut st State) {
	if isnil(st.wb_cb) {
		return
	}
	mut cb := st.wb_cb
	cb.set_selected(wb_mode_idx(st.edit.wb_mode))
}

// set_wb_pick - режим пипетки: кнопка подсвечена, на снимке - кружок
// пятна; щелчок левой кнопкой по нейтрали задаёт ББ
fn set_wb_pick(mut st State, on bool) {
	st.wb_pick = on
	if !isnil(st.wb_pick_btn) {
		mut b := st.wb_pick_btn
		b.style = if on { vgui.ButtonStyle.accent } else { vgui.ButtonStyle.flat }
	}
	if !isnil(st.cv) {
		mut cv := st.cv
		cv.brush_cursor = on
		cv.brush_radius = wb_pick_r
		// Пятно 9x9 превью при вписанном кадре - 2-3 экранных пикселя:
		// кольцо не меньше 7 px, без заливки - видно, что под ним
		cv.brush_min_px = 7
		cv.brush_ring = true
	}
}

// wb_pick_at - пипетка: среднее пятна превью «как снято» после геометрии
// (st.glin - то, что на холсте) ->
// температура и оттенок, при которых оно серое
fn wb_pick_at(mut st State, x int, y int) {
	if st.glin.len != st.gw * st.gh * 3 || st.glin.len == 0 {
		return
	}
	mut sr := 0.0
	mut sg := 0.0
	mut sb := 0.0
	mut mx := 0
	mut n := 0
	for yy in y - wb_pick_r .. y + wb_pick_r + 1 {
		for xx in x - wb_pick_r .. x + wb_pick_r + 1 {
			if xx < 0 || yy < 0 || xx >= st.gw || yy >= st.gh {
				continue
			}
			i := (yy * st.gw + xx) * 3
			for c in 0 .. 3 {
				if int(st.glin[i + c]) > mx {
					mx = int(st.glin[i + c])
				}
			}
			sr += f64(st.glin[i])
			sg += f64(st.glin[i + 1])
			sb += f64(st.glin[i + 2])
			n++
		}
	}
	set_wb_pick(mut st, false)
	if n == 0 || sg / n < 64 || mx >= 65000 {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_warning(i18n.tr('Пипетка: место слишком тёмное или пересвеченное - выберите серое'))
		}
		return
	}
	t, tint := st.cam.neutral_temp_tint(sr, sg, sb)
	set_wb(mut st, 'custom', t, tint, i18n.tr('пипетка'))
}

// wb_auto - «Авто»: серый мир по превью (без чёрного и пересветов)
fn wb_auto(st &State) (f32, f32) {
	// По кадру после кадрирования (glin), до первого apply - по всему
	if st.glin.len > 0 && st.glin.len == st.gw * st.gh * 3 {
		r, g, b := pipeline.gray_world(unsafe { &u16(st.glin.data) }, st.gw * st.gh)
		return st.cam.neutral_temp_tint(r, g, b)
	}
	r, g, b := pipeline.gray_world(unsafe { &u16(st.linear.data) }, st.pw * st.ph)
	return st.cam.neutral_temp_tint(r, g, b)
}

// build_wb_section - ряды секции «Баланс белого»: режим и пипетка,
// температура, оттенок, подсказка
fn build_wb_section(mut st State, lbl_w f32, val_w f32) []SectionRow {
	mut cb := vgui.combo_box()
	cb.set_items(i18n.tr_all(wb_names))
	cb.set_selected(0)
	cb.on_change = fn [mut st] (idx int, text string) {
		if idx < 0 || idx >= wb_modes.len {
			return
		}
		mode := wb_modes[idx]
		mut t, mut tint := wb_values(st, &st.edit)
		match mode {
			'' {}
			'auto' {
				if st.linear.len == 0 {
					sync_wb_mode(mut st) // кадр ещё не проявлен
					return
				}
				t, tint = wb_auto(st)
			}
			'custom' {}
			else {
				t = wb_preset_temp[idx]
				tint = wb_preset_tint[idx]
			}
		}
		set_wb(mut st, mode, t, tint, text)
	}
	st.wb_cb = cb
	mut pick := icon_button('pipette', i18n.tr('Пипетка: щёлкните по серому или белому на снимке'))
	pick.on_click = fn [mut st] () {
		set_wb_pick(mut st, !st.wb_pick && st.linear.len > 0)
	}
	st.wb_pick_btn = pick
	st.hk_texts << fn [st, mut pick] () {
		pick.tooltip = i18n.tr('Пипетка: щёлкните по серому или белому на снимке') +
			hk_paren(st, 'edit.wb_pick')
	}
	mut mode_lb := vgui.label(i18n.tr('Режим'))
	mut mode_row := vgui.create_hbox_fill()
	mode_row.set_spacing(6)
	mode_row.add(mode_lb, min: lbl_w)
	mode_row.add(cb, flex: 1)
	mode_row.add(pick)

	// Движение ползунка - режим «Свой» (список обновит fx); второе
	// значение берётся из показанного (у «как снято» - камерного)
	wb_fx := fn [mut st] () {
		sync_wb_mode(mut st)
		st.tone_fx()
	}
	mut temp := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Температура')
		hname:  i18n.tr('Баланс белого: температура')
		max:    wb_pos_max
		def:    temp_to_pos(5000)
		digits: 0
		show:   fn (v f32) string {
			return temp_text(pos_to_temp(v))
		}
		get:    fn [st] (e &EditState) f32 {
			t, _ := wb_values(st, e)
			return temp_to_pos(t)
		}
		set:    fn [mut st] (mut e EditState, v f32) {
			if st.suppress {
				return
			}
			_, tint := wb_values(st, e)
			e.wb_mode = 'custom'
			e.wb_temp = pos_to_temp(v)
			e.wb_tint = tint
			wb_derive(mut e, st.cam)
		}
		fx:     wb_fx
	})
	mut tint := edit_slider(mut st, SliderCfg{
		label:  i18n.trc('ББ', 'Оттенок')
		hname:  i18n.tr('Баланс белого: оттенок')
		min:    -pipeline.wb_tint_max
		max:    pipeline.wb_tint_max
		digits: 0
		get:    fn [st] (e &EditState) f32 {
			_, tn := wb_values(st, e)
			return tn
		}
		set:    fn [mut st] (mut e EditState, v f32) {
			if st.suppress {
				return
			}
			t, _ := wb_values(st, e)
			e.wb_mode = 'custom'
			e.wb_temp = t
			e.wb_tint = v
			wb_derive(mut e, st.cam)
		}
		fx:     wb_fx
	})
	st.wb_temp_sl = temp.sl
	st.wb_tint_sl = tint.sl
	// Сброс ползунка - «как снято» (а не 5000 K / 0)
	mut t_reset := reset_button(i18n.tr('Как снято'))
	t_reset.on_click = fn [mut st] () {
		set_wb(mut st, '', 0, 0, i18n.tr(wb_names[0]))
	}
	mut temp_row := vgui.create_hbox_fill()
	temp_row.set_spacing(6)
	temp_row.add(temp.lb, min: lbl_w)
	temp_row.add(temp.sl, flex: 1)
	temp_row.add(temp.vl, min: val_w)
	temp_row.add(t_reset)
	mut n_reset := reset_button(i18n.tr('Как снято'))
	n_reset.on_click = fn [mut st] () {
		set_wb(mut st, '', 0, 0, i18n.tr(wb_names[0]))
	}
	mut tint_row := vgui.create_hbox_fill()
	tint_row.set_spacing(6)
	tint_row.add(tint.lb, min: lbl_w)
	tint_row.add(tint.sl, flex: 1)
	tint_row.add(tint.vl, min: val_w)
	tint_row.add(n_reset)
	mut hint := vgui.label(i18n.tr('Оттенок: минус - зеленее, плюс - пурпурнее'))
	hint.font_size = 12
	st.hint_labels << hint
	return [SectionRow{mode_row}, SectionRow{temp_row}, SectionRow{tint_row},
		SectionRow{hint}]
}
