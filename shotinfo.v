module main

// Сведения о съёмке (18.10.2026): две строки поверх снимка внизу слева -
// экспозиция (ISO, выдержка, диафрагма, фокусное) и камера, объектив,
// дата (raw.Meta открытого кадра; чего нет в EXIF - пропускается).
// «Вид - Сведения о съёмке» (I), запоминается (Settings.no_info).
import time
import vgui
import raw
import i18n

// shot_exposure - «ISO 5000 · 1/60 с · f/5.6 · 35 мм»
fn shot_exposure(m raw.Meta) string {
	mut parts := []string{}
	if m.iso > 0 {
		parts << 'ISO ${int(m.iso + 0.5)}'
	}
	if m.shutter > 0 {
		parts << fmt_shutter(m.shutter)
	}
	if m.aperture > 0 {
		parts << 'f/${trim_zero(m.aperture)}'
	}
	if m.focal > 0 {
		parts << i18n.trf('{0} мм', '${int(m.focal + 0.5)}')
	}
	return parts.join(' · ')
}

// shot_camera - «Canon EOS R8 · RF24-50mm F4.5-6.3 IS STM · 17.10.2026 14:32»
fn shot_camera(m raw.Meta) string {
	mut parts := []string{}
	cam := if m.cam_model.starts_with(m.cam_make) || m.cam_make == '' {
		m.cam_model
	} else {
		'${m.cam_make} ${m.cam_model}'
	}
	if cam.trim_space() != '' {
		parts << cam.trim_space()
	}
	if m.lens != '' {
		parts << m.lens
	}
	if m.shot > 0 {
		parts << time.unix(m.shot).local().custom_format('DD.MM.YYYY HH:mm')
	}
	return parts.join(' · ')
}

// fmt_shutter - выдержка: длинная - секунды («2 с», «1.3 с»), короткая -
// доля «1/250 с»
fn fmt_shutter(s f32) string {
	if s >= 0.3 {
		return i18n.trf('{0} с', trim_zero(s))
	}
	return i18n.trf('{0} с', '1/${int(1 / s + 0.5)}')
}

// trim_zero - число с одним знаком после точки без «.0»: 5.6, 8, 1.3
fn trim_zero(v f32) string {
	t := '${v:.1f}'
	return if t.ends_with('.0') { t[..t.len - 2] } else { t }
}

// set_show_info - показ сведений (меню «Вид»), запоминается
fn set_show_info(mut st State, v bool) {
	st.settings.no_info = !v
	save_settings(st.settings)
	if !isnil(st.cv) {
		mut cv := st.cv
		cv.mark_dirty()
	}
}

// info_overlay - строки сведений внизу слева холста (из on_overlay)
fn info_overlay(st &State, mut ctx vgui.RenderContext) {
	if st.settings.no_info || isnil(st.cv) || st.raw_path == '' || st.crop_mode {
		return
	}
	cv := st.cv
	lines := [shot_exposure(st.meta), shot_camera(st.meta)].filter(it != '')
	// над горизонтальной полосой прокрутки (при увеличении)
	mut y := cv.bounds.y + cv.bounds.h - 16 - 24 * f32(lines.len)
	for l in lines {
		ba_label(mut ctx, l, cv.bounds.x + 10, y)
		y += 24
	}
}
