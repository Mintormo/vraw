module main

// Точечный цвет (pipeline/pcolor.v): раздел «Точечный цвет», пипетка.
//
// Точки кадра - в EditState.params.pcolor (история, сайдкар, группа
// копирования «HSL»), не больше pipeline.pcolor_max. Пипетка (кнопка
// раздела): щелчок по снимку - новая точка с цветом пятна 9x9 под
// курсором (как его видит точечный цвет: тон после HSL, до точечного
// цвета и цветокоррекции - pc_sample), она же выделяется. Ползунки
// «Оттенок», «Насыщенность», «Яркость», «Диапазон» правят выделенную;
// стрелки - соседняя точка, «×» - удалить выделенную, корзина - все.
// В Ч/Б точечный цвет не действует (как HSL) - пипетка выключена.
import math
import vgui
import pipeline
import i18n

const pc_pick_r = 4 // пятно пипетки - (2r+1)² пикселей превью
const pc_min_sat = f32(0.05) // серее - оттенка нет, точку не ставим

// PcUi - виджеты раздела (sync_pc_ui выставляет их по st.edit)
@[heap]
struct PcUi {
mut:
	pick_btn &vgui.Button = unsafe { nil }
	clr_btn  &vgui.Button = unsafe { nil }
	del_btn  &vgui.Button = unsafe { nil }
	prev_btn &vgui.Button = unsafe { nil }
	next_btn &vgui.Button = unsafe { nil }
	count_lb &vgui.Label  = unsafe { nil }
	swatch   &vgui.Canvas = unsafe { nil }
	sliders  []&vgui.Slider
}

fn pc_valid(st &State) bool {
	return st.pc_sel >= 0 && st.pc_sel < st.edit.params.pcolor.len
}

// set_pc_pick - режим пипетки: кнопка подсвечена, на снимке - кольцо
// пятна; щелчок по цвету - новая точка. Другие режимы снимка - выключаются
fn set_pc_pick(mut st State, on bool) {
	mut v := on
	if v && (st.linear.len == 0 || st.suppress) {
		v = false
	}
	if v && st.edit.params.pcolor.len >= pipeline.pcolor_max {
		v = false
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_warning(i18n.trf('Точечный цвет: не больше {0} цветов', '${pipeline.pcolor_max}'))
		}
	}
	if v == st.pc_pick {
		sync_pc_ui(mut st)
		return
	}
	st.pc_pick = v
	if v {
		if st.wb_pick {
			set_wb_pick(mut st, false)
		}
		if st.mask_pick {
			set_mask_pick(mut st, false)
		}
		if st.spot_mode {
			set_spot_mode(mut st, false)
		}
		if st.crop_mode {
			set_crop_mode(mut st, false)
		}
	}
	if !isnil(st.cv) {
		mut cv := st.cv
		cv.brush_cursor = v
		cv.brush_radius = pc_pick_r
		cv.brush_min_px = 7
		cv.brush_ring = true
	}
	sync_pc_ui(mut st)
}

// pc_leave - смена или закрытие кадра: выделение и пипетка сброшены
fn pc_leave(mut st State) {
	st.pc_sel = -1
	if st.pc_pick {
		set_pc_pick(mut st, false)
	}
	sync_pc_ui(mut st)
}

// pc_sample - центр новой точки по пятну превью вокруг (x, y): пятно
// сырья после геометрии (st.glin) проявляется настройками кадра без
// точечного цвета и цветокоррекции (они после HSL - цвет, который видит
// точечный цвет), фильтры - по месту пятна; среднее тона -> оттенок,
// насыщенность, яркость
fn pc_sample(st &State, x int, y int) ?pipeline.PointColor {
	if st.glin.len != st.gw * st.gh * 3 || st.glin.len == 0 {
		return none
	}
	x0 := int(math.max(0, x - pc_pick_r))
	y0 := int(math.max(0, y - pc_pick_r))
	x1 := int(math.min(st.gw, x + pc_pick_r + 1))
	y1 := int(math.min(st.gh, y + pc_pick_r + 1))
	pw := x1 - x0
	ph := y1 - y0
	if pw <= 0 || ph <= 0 {
		return none
	}
	n := pw * ph
	mut src := []u16{len: n * 3}
	has_mask := st.gmask.len == st.gw * st.gh * pipeline.mask_ch
	mut msk := []u16{len: if has_mask { n * pipeline.mask_ch } else { 0 }}
	for yy in y0 .. y1 {
		for xx in x0 .. x1 {
			i := (yy - y0) * pw + xx - x0
			k := yy * st.gw + xx
			for c in 0 .. 3 {
				src[i * 3 + c] = st.glin[k * 3 + c]
			}
			if has_mask {
				for c in 0 .. pipeline.mask_ch {
					msk[i * pipeline.mask_ch + c] = st.gmask[k * pipeline.mask_ch + c]
				}
			}
		}
	}
	mut p := st.edit.params
	p.pcolor = []pipeline.PointColor{}
	p.grade = pipeline.Grade{}
	p.dither = false
	if p.masks.len > 0 && st.pw > 0 && st.ph > 0 {
		p = with_lmap(p, view_map(st).region(x0, y0, pw))
	}
	mut out := []u8{len: n * 3}
	pipeline.apply(unsafe { &u16(src.data) }, if has_mask {
		unsafe { &u16(msk.data) }
	} else {
		unsafe { nil }
	}, n, p, mut out, 3)
	mut sr := 0.0
	mut sg := 0.0
	mut sb := 0.0
	for i in 0 .. n {
		sr += f64(out[i * 3])
		sg += f64(out[i * 3 + 1])
		sb += f64(out[i * 3 + 2])
	}
	return pipeline.rgb_point(f32(sr / n), f32(sg / n), f32(sb / n))
}

// pc_pick_at - пипетка: новая точка с цветом под курсором (x, y - пиксели
// превью), выделяется
fn pc_pick_at(mut st State, x int, y int) {
	set_pc_pick(mut st, false)
	c := pc_sample(st, x, y) or { return }
	if c.sat < pc_min_sat {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_warning(i18n.tr('Точечный цвет: здесь серое - выберите цветное место'))
		}
		return
	}
	st.edit.params.pcolor << c
	st.pc_sel = st.edit.params.pcolor.len - 1
	pc_changed(mut st, 'pc_add', i18n.trf('Точечный цвет {0}: добавлен', '${st.pc_sel + 1}'))
}

// pc_changed - правка точек: пересчёт и запись в истории
fn pc_changed(mut st State, key string, name string) {
	sync_pc_ui(mut st)
	if !isnil(st.tone_fx) {
		st.tone_fx()
	}
	record(mut st, key, name, false)
}

fn delete_pc(mut st State) {
	if !pc_valid(st) {
		return
	}
	n := st.pc_sel + 1
	st.edit.params.pcolor.delete(st.pc_sel)
	st.pc_sel = if st.pc_sel < st.edit.params.pcolor.len {
		st.pc_sel
	} else {
		st.edit.params.pcolor.len - 1
	}
	pc_changed(mut st, 'pc_del', i18n.trf('Точечный цвет {0}: удалён', '${n}'))
}

fn clear_pc(mut st State) {
	if st.edit.params.pcolor.len == 0 {
		return
	}
	st.edit.params.pcolor = []pipeline.PointColor{}
	st.pc_sel = -1
	pc_changed(mut st, 'pc_clear', i18n.tr('Точечный цвет: удалены все'))
}

// select_pc - выделить точку idx (по кругу), ползунки - по ней
fn select_pc(mut st State, idx int) {
	n := st.edit.params.pcolor.len
	st.pc_sel = if n == 0 { -1 } else { (idx % n + n) % n }
	sync_pc_ui(mut st)
}

// pc_color - цвет центра точки для образца (HSV -> RGB)
fn pc_color(c pipeline.PointColor) vgui.Color {
	h := f64(c.hue) / 60
	s := f64(c.sat)
	v := f64(c.val) * 255
	sec := int(h) % 6
	f := h - math.floor(h)
	p := v * (1 - s)
	q := v * (1 - s * f)
	t := v * (1 - s * (1 - f))
	r, g, b := match sec {
		0 { v, t, p }
		1 { q, v, p }
		2 { p, v, t }
		3 { p, q, v }
		4 { t, p, v }
		else { v, p, q }
	}
	return vgui.Color{u8(math.round(r)), u8(math.round(g)), u8(math.round(b)), 255}
}

// sync_pc_ui - подпись, кнопки, образец цвета и ползунки по st.edit
fn sync_pc_ui(mut st State) {
	// Выделение влияет только на ползунки панели (на снимке точек не
	// видно) - есть точки, выделена одна из них: иначе единственную точку
	// открытого заново кадра нечем выбрать
	if st.pc_sel >= st.edit.params.pcolor.len || (st.pc_sel < 0 && st.edit.params.pcolor.len > 0) {
		st.pc_sel = if st.pc_sel < 0 { 0 } else { st.edit.params.pcolor.len - 1 }
	}
	if isnil(st.pc_ui) {
		return
	}
	mut u := st.pc_ui
	n := st.edit.params.pcolor.len
	valid := pc_valid(st)
	mut pb := u.pick_btn
	pb.style = if st.pc_pick { vgui.ButtonStyle.accent } else { vgui.ButtonStyle.outline }
	pb.enabled = !st.edit.params.bw && n < pipeline.pcolor_max
	mut cl := u.count_lb
	cl.text = if n == 0 {
		i18n.tr('Цветов нет')
	} else if valid {
		i18n.trf('Цвет {0} из {1}', '${st.pc_sel + 1}', '${n}')
	} else {
		'${n} ${i18n.pl(n, 'цвет|цвета|цветов')}'
	}
	mut db := u.del_btn
	db.enabled = valid
	mut cb := u.clr_btn
	cb.enabled = n > 0
	mut pv := u.prev_btn
	pv.enabled = n > 1
	mut nx := u.next_btn
	nx.enabled = n > 1
	mut sw := u.swatch
	sw.fill(if valid { pc_color(st.edit.params.pcolor[st.pc_sel]) } else { st.pal.clip_idle })
	sw.mark_dirty()
	// Ползунки выделенной - по снимку (их get читает st.pc_sel)
	was := st.suppress
	st.suppress = true
	for b in st.binds {
		if b.sl in u.sliders {
			mut sl := b.sl
			sl.set_value(b.get(&st.edit))
		}
	}
	st.suppress = was
	for mut sl in u.sliders {
		set_slider_enabled(st, mut sl, valid && !st.edit.params.bw)
	}
}

// pc_slider - ползунок выделенной точки (which: 0 - оттенок,
// 1 - насыщенность, 2 - яркость, 3 - диапазон); без выделения - не действует
fn pc_slider(mut st State, label string, which int, lbl_w f32, val_w f32) &vgui.HBox {
	mut s := edit_slider(mut st, SliderCfg{
		label:  label
		hname:  i18n.trf('Точечный цвет: {0}', label.to_lower())
		min:    if which == 3 { f32(0) } else { f32(-100) }
		max:    100
		def:    if which == 3 { f32(50) } else { f32(0) }
		digits: 0
		signed: which != 3
		get:    fn [mut st, which] (e &EditState) f32 {
			i := st.pc_sel
			if i >= 0 && i < e.params.pcolor.len {
				c := e.params.pcolor[i]
				return [c.dhue, c.dsat, c.dlum, c.range][which]
			}
			return if which == 3 { f32(50) } else { f32(0) }
		}
		set:    fn [mut st, which] (mut e EditState, v f32) {
			i := st.pc_sel
			if i < 0 || i >= e.params.pcolor.len {
				return
			}
			match which {
				0 { e.params.pcolor[i].dhue = v }
				1 { e.params.pcolor[i].dsat = v }
				2 { e.params.pcolor[i].dlum = v }
				else { e.params.pcolor[i].range = v }
			}
		}
		fx:     fn [mut st] () {
			st.tone_fx()
		}
	})
	if !isnil(st.pc_ui) {
		mut u := st.pc_ui
		u.sliders << s.sl
	}
	return edit_row(mut st, mut s, lbl_w, val_w)
}

fn build_pc_section(mut st State, lbl_w f32, val_w f32) []SectionRow {
	mut u := &PcUi{}
	st.pc_ui = u
	mut rows := []SectionRow{}

	mut pick := vgui.button(i18n.tr('Выбрать цвет'))
	pick.icon_name = 'pipette'
	pick.style = .outline
	pick.tooltip = i18n.tr('Пипетка: щёлкните по цвету на снимке')
	pick.on_click = fn [mut st] () {
		set_pc_pick(mut st, !st.pc_pick)
	}
	u.pick_btn = pick
	mut clr := icon_button('trash-2', i18n.tr('Удалить все цвета'))
	clr.on_click = fn [mut st] () {
		clear_pc(mut st)
	}
	u.clr_btn = clr
	mut pick_row := vgui.create_hbox_fill()
	pick_row.set_spacing(6)
	pick_row.add(pick, flex: 1)
	pick_row.add(clr)
	rows << SectionRow{pick_row}

	// Выделенная точка: образец цвета, подпись, соседние, удалить
	mut sw := vgui.canvas(1, 1)
	sw.stretch = true
	sw.take_keys = false
	u.swatch = sw
	mut count := vgui.label(i18n.tr('Цветов нет'))
	st.secondary_labels << count
	u.count_lb = count
	mut prev := icon_button('chevron-left', i18n.tr('Предыдущий цвет'))
	prev.on_click = fn [mut st] () {
		select_pc(mut st, st.pc_sel - 1)
	}
	u.prev_btn = prev
	mut next := icon_button('chevron-right', i18n.tr('Следующий цвет'))
	next.on_click = fn [mut st] () {
		select_pc(mut st, st.pc_sel + 1)
	}
	u.next_btn = next
	mut del := icon_button('x', i18n.tr('Удалить цвет'))
	del.on_click = fn [mut st] () {
		delete_pc(mut st)
	}
	u.del_btn = del
	mut sel_row := vgui.create_hbox_fill()
	sel_row.set_spacing(6)
	sel_row.add(sw, min: 22, max: 22)
	sel_row.add(count, flex: 1)
	sel_row.add(prev)
	sel_row.add(next)
	sel_row.add(del)
	rows << SectionRow{sel_row}

	rows << SectionRow{pc_slider(mut st, i18n.tr('Оттенок'), 0, lbl_w, val_w)}
	rows << SectionRow{pc_slider(mut st, i18n.tr('Насыщенность'), 1, lbl_w, val_w)}
	rows << SectionRow{pc_slider(mut st, i18n.tr('Яркость'), 2, lbl_w, val_w)}
	rows << SectionRow{pc_slider(mut st, i18n.tr('Диапазон'), 3, lbl_w, val_w)}

	mut hint := vgui.label(i18n.tr('Пипеткой выберите цвет на снимке - правки только для него'))
	hint.font_size = 12
	st.hint_labels << hint
	rows << SectionRow{hint}
	sync_pc_ui(mut st)
	return rows
}
