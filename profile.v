module main

// Профиль проявки - список «Профиль» в разделе «Коррекция»: основа
// (нейтральная проявка или «как JPEG камеры» - камерная кривая, насыщенность
// и таблица цвета кадра, CamLook) и стиль поверх неё (pipeline/style.v:
// портрет, пейзаж, яркий). В EditState - use_curve и profile; стиль всегда
// на основе «как JPEG камеры» (у кадра без встроенного JPEG она - нейтральная
// проявка). Переключение - обычный apply: всё в таблицах пайплайна.
import vgui
import pipeline

// profile_names - пункты списка: 0 - нейтральный, 1 - как JPEG камеры,
// дальше - стили pipeline.style_keys
fn profile_names() []string {
	mut a := ['Нейтральный', 'Как JPEG камеры']
	a << pipeline.style_names
	return a
}

// profile_idx - пункт списка по настройкам кадра
fn profile_idx(e &EditState) int {
	if !e.use_curve {
		return 0
	}
	i := pipeline.style_keys.index(e.profile)
	return if i < 0 { 1 } else { i + 2 }
}

// set_profile - выбран пункт idx: основа и стиль, пересчёт, запись
fn set_profile(mut st State, idx int) {
	if idx < 0 || idx >= 2 + pipeline.style_keys.len {
		return
	}
	st.edit.use_curve = idx > 0
	st.edit.profile = if idx >= 2 { pipeline.style_keys[idx - 2] } else { '' }
	st.edit = with_derived(st.edit, st.look, st.cam)
	st.tone_fx()
	record(mut st, 'profile', 'Профиль: ${profile_names()[idx]}', false)
}

// profile_row - ряд «Профиль» со списком
fn profile_row(mut st State, lbl_w f32) &vgui.HBox {
	mut cb := vgui.combo_box()
	cb.set_items(profile_names())
	cb.set_selected(1)
	cb.on_change = fn [mut st] (idx int, _ string) {
		set_profile(mut st, idx)
	}
	st.prof_cb = cb
	mut row := vgui.create_hbox_fill()
	row.set_spacing(6)
	row.add(vgui.label('Профиль'), min: lbl_w)
	row.add(cb, flex: 1)
	return row
}

// sync_profile - выбранный пункт по снимку (set_selected не зовёт on_change)
fn sync_profile(mut st State, e &EditState) {
	if isnil(st.prof_cb) {
		return
	}
	mut cb := st.prof_cb
	cb.set_selected(profile_idx(e))
}
