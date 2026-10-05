module main

// Оверлей загрузки кадра: пока кадр проявляется (load_worker), на месте
// снимка - кольцо прогресса и надпись «Обработка». Встроенный JPEG камеры
// вместо него не показывается: он обработан иначе, чем наша проявка, и
// смена картинки бросалась в глаза (JPEG отдельно - «Вид - JPEG камеры»,
// camjpeg.v). Прогресс - по этапам воркера (LoadProgress, доли
// load_p_*): кольцо продвигается рывками раз в ~0.1-0.3 с.
import vgui

const load_ring_r = f32(28)

// LoadOverlay - слой view_stack поверх холста и заглушки
@[heap]
struct LoadOverlay {
mut:
	stack &vgui.Stack       = unsafe { nil }
	ring  &vgui.ProgressBar = unsafe { nil }
	label &vgui.Label       = unsafe { nil }
}

fn make_load_overlay() &LoadOverlay {
	mut ring := vgui.progress_circular()
	ring.radius = load_ring_r
	ring.thickness = 5
	mut label := vgui.label('Обработка')
	label.align = .center
	mut col := vgui.create_vbox_fill()
	col.set_spacing(12)
	col.add(ring, align: .center)
	col.add(label)
	mut center := vgui.create_centered(200, 2 * load_ring_r + 40)
	center.set_child(col)
	mut stack := &vgui.Stack{}
	stack.add(center)
	stack.visible = false
	return &LoadOverlay{
		stack: stack
		ring:  ring
		label: label
	}
}

// show_loading - оверлей вместо снимка (кадр открывается) или снимок
// вместо оверлея (готово); заглушку прячет. Холст на время загрузки
// скрыт - старый кадр не путается с новым.
fn show_loading(mut st State, on bool) {
	if isnil(st.load_ov) || isnil(st.cv) {
		return
	}
	mut ov := st.load_ov
	mut cv := st.cv
	ov.stack.visible = on
	if on {
		mut ring := ov.ring
		ring.set_value(0)
		cv.visible = false
		// Гистограмма прежнего кадра - не к этому
		if !isnil(st.hist_cv) {
			mut hist := st.hist_cv
			clear_histogram(mut st, mut hist)
		}
		if !isnil(st.holder) {
			mut ph := st.holder.stack
			ph.visible = false
		}
	}
	sync_view_bg(mut st)
}

// set_load_progress - доля загрузки на кольце (только растёт: доставка
// посылок по порядку, но на всякий случай)
fn set_load_progress(mut st State, p LoadProgress) {
	if p.gen != st.file_gen || !st.loading || isnil(st.load_ov) {
		return
	}
	mut ring := st.load_ov.ring
	if p.v > ring.value {
		ring.set_value(p.v)
	}
}
