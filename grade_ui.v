module main

// Раздел «Цветокоррекция» (pipeline/grade.v): вкладки «Тени / Средние /
// Света / Общий» - в каждой цветовой круг и ползунки «Оттенок»,
// «Насыщенность», «Яркость» зоны; под вкладками - «Смешение» и «Баланс».
//
// Круг - vgui.Canvas с растяжкой (stretch): высота буфера постоянная
// (grade_wheel_h), ширина подгоняется под ширину холста (fit_wheel через
// app.post - не во время рисования), поэтому круг рисуется пиксель в
// пиксель. Щелчок и перетаскивание (on_stroke, левая кнопка) ставят
// оттенок (угол, красный справа, против часовой стрелки) и насыщенность
// (расстояние от центра); снимок пересчитывается по ходу (defer_fx),
// запись в истории - по отпусканию. on_input холсту не задан: колесо мыши
// над кругом прокручивает панель.
import math
import vgui
import pipeline
import i18n

const grade_wheel_h = 168 // высота буфера круга, px
const grade_wheel_r = f32(78) // радиус круга, px
const grade_hist_names = ['тени', 'средние', 'света', 'общий']

// GradeWheel - цветовой круг зоны z и её ползунки (выставляются при
// перетаскивании по кругу)
@[heap]
struct GradeWheel {
mut:
	st     &State       = unsafe { nil }
	cv     &vgui.Canvas = unsafe { nil }
	zone   int
	hue    &vgui.Slider = unsafe { nil }
	sat    &vgui.Slider = unsafe { nil }
	drag   bool // перетаскивание началось на круге
	resize bool // подгонка ширины уже поставлена в app.post
	fit    fn () = unsafe { nil } // приёмник app.post (создан один раз)
}

// grade_wheel_color - цвет круга в точке: серый, сдвинутый по оттенку
// так же, как сдвигает кадр цветокоррекция (pipeline.grade_chroma)
fn grade_wheel_color(deg f32, s f32) (u8, u8, u8) {
	r, g, b := pipeline.grade_chroma(deg)
	k := s * 150
	return clamp_u8(132 + r * k), clamp_u8(132 + g * k), clamp_u8(132 + b * k)
}

// paint - круг и метка текущего цвета зоны по st.edit
fn (mut w GradeWheel) paint() {
	mut cv := w.cv
	bw := cv.width
	bh := cv.height
	if bw <= 0 || bh <= 0 || cv.pixels.len < bw * bh * 4 {
		return
	}
	z := w.st.edit.params.grade.zones[w.zone]
	cx := f32(bw) / 2
	cy := f32(bh) / 2
	rr := grade_wheel_r
	a := z.hue * math.pi / 180
	sv := clamp01f(z.sat / 100)
	mx := cx + f32(math.cos(a)) * sv * rr
	my := cy - f32(math.sin(a)) * sv * rr
	for y in 0 .. bh {
		for x in 0 .. bw {
			i := (y * bw + x) * 4
			dx := f32(x) + 0.5 - cx
			dy := f32(y) + 0.5 - cy
			d := f32(math.sqrt(dx * dx + dy * dy))
			mut r := u8(0)
			mut g := u8(0)
			mut b := u8(0)
			mut al := f32(0)
			if d < rr + 1 {
				deg := f32(math.atan2(-dy, dx) * 180 / math.pi)
				r, g, b = grade_wheel_color(deg, d / rr)
				al = clamp01f(rr + 0.5 - d)
			}
			// Метка: светлое кольцо с тёмной каймой
			md := f32(math.sqrt((f32(x) + 0.5 - mx) * (f32(x) + 0.5 - mx) +
				(f32(y) + 0.5 - my) * (f32(y) + 0.5 - my)))
			if md < 8.5 {
				if md >= 4.5 && md < 7 {
					r, g, b = 245, 245, 245
					al = 1
				} else if md >= 3.5 && md < 8.5 {
					r, g, b = 20, 20, 20
					al = math.max(al, f32(0.85))
				}
			}
			cv.pixels[i] = r
			cv.pixels[i + 1] = g
			cv.pixels[i + 2] = b
			cv.pixels[i + 3] = u8(al * 255)
		}
	}
	cv.mark_dirty()
}

// stroke - щелчок и перетаскивание по кругу (phase: 0 - нажатие, 1 -
// движение, 2 - отпускание)
fn (mut w GradeWheel) stroke(phase int, x int, y int) {
	mut st := w.st
	cx := f32(w.cv.width) / 2
	cy := f32(w.cv.height) / 2
	dx := f32(x) + 0.5 - cx
	dy := f32(y) + 0.5 - cy
	d := f32(math.sqrt(dx * dx + dy * dy))
	if phase == 0 {
		// Мимо круга - не правка (поле вокруг него)
		w.drag = d <= grade_wheel_r + 10
	}
	if !w.drag {
		return
	}
	if phase == 2 {
		w.drag = false
		st.tone_fx()
		z := st.edit.params.grade.zones[w.zone]
		key := i18n.trf('Цветокоррекция: {0}', i18n.tr(grade_hist_names[w.zone]))
		record(mut st, key, '${key} ${int(z.hue)}°, ${int(z.sat)}', false)
		return
	}
	mut hue := f32(math.atan2(-dy, dx) * 180 / math.pi)
	if hue < 0 {
		hue += 360
	}
	sat := f32(math.round(clamp01f(d / grade_wheel_r) * 100))
	st.edit.params.grade.zones[w.zone].hue = f32(math.round(hue))
	st.edit.params.grade.zones[w.zone].sat = sat
	st.suppress = true
	mut hs := w.hue
	hs.set_value(f32(math.round(hue)))
	mut ss := w.sat
	ss.set_value(sat)
	st.suppress = false
	w.paint()
	defer_fx(mut st, st.tone_fx)
}

// check_size - ширина холста изменилась (панель, окно): подогнать буфер
// после кадра (on_overlay вызывается во время рисования)
fn (mut w GradeWheel) check_size() {
	bw := int(w.cv.bounds.w + 0.5)
	if bw <= 0 || bw == w.cv.width || w.resize || isnil(w.st.app) {
		return
	}
	w.resize = true
	mut app := w.st.app
	app.post(w.fit)
}

fn (mut w GradeWheel) fit_width() {
	w.resize = false
	bw := int(w.cv.bounds.w + 0.5)
	if bw <= 0 || bw == w.cv.width {
		return
	}
	mut cv := w.cv
	set_canvas_size(mut cv, bw, grade_wheel_h)
	w.paint()
}

// make_grade_wheel - холст круга зоны z (ползунки - grade_zone_rows)
fn make_grade_wheel(mut st State, z int) &GradeWheel {
	mut cv := vgui.canvas(int(2 * grade_wheel_r) + 8, grade_wheel_h)
	cv.stretch = true
	cv.set_wheel_zoom(false)
	cv.set_pan_buttons(0)
	cv.take_keys = false
	mut w := &GradeWheel{
		st:   st
		cv:   cv
		zone: z
	}
	w.fit = fn [mut w] () {
		w.fit_width()
	}
	cv.on_stroke = fn [mut w] (phase int, x int, y int) {
		w.stroke(phase, x, y)
	}
	cv.on_overlay = fn [mut w] (mut _ vgui.RenderContext) {
		w.check_size()
	}
	w.paint()
	st.grade_wheels << w
	return w
}

// sync_grade_ui - круги по st.edit (откат, новый файл, вставка настроек;
// ползунки выставляет set_edit по st.binds)
fn sync_grade_ui(mut st State) {
	for w in st.grade_wheels {
		mut ww := unsafe { w }
		ww.paint()
	}
}

// grade_section - содержимое раздела «Цветокоррекция»
fn grade_section(mut st State, lbl_w f32, val_w f32) &vgui.VBox {
	tone_fx := st.tone_fx
	mut tabs := vgui.tab_box()
	for z in 0 .. pipeline.grade_zones {
		mut w := make_grade_wheel(mut st, z)
		hn := i18n.trf('Цветокоррекция {0}', i18n.tr(grade_hist_names[z]))
		mut hue := edit_slider(mut st, SliderCfg{
			label:  i18n.tr('Оттенок')
			hname:  i18n.trf('{0}: оттенок', '${hn}')
			max:    360
			digits: 0
			signed: false
			show:   fn (v f32) string {
				return '${int(v)}°'
			}
			get:    fn [z] (e &EditState) f32 {
				return e.params.grade.zones[z].hue
			}
			set:    fn [z, mut w] (mut e EditState, v f32) {
				e.params.grade.zones[z].hue = v
				w.paint()
			}
			fx:     tone_fx
		})
		mut sat := edit_slider(mut st, SliderCfg{
			label:  i18n.tr('Насыщенность')
			hname:  i18n.trf('{0}: насыщенность', '${hn}')
			max:    100
			digits: 0
			signed: false
			get:    fn [z] (e &EditState) f32 {
				return e.params.grade.zones[z].sat
			}
			set:    fn [z, mut w] (mut e EditState, v f32) {
				e.params.grade.zones[z].sat = v
				w.paint()
			}
			fx:     tone_fx
		})
		mut lum := edit_slider(mut st, SliderCfg{
			label:  i18n.tr('Яркость')
			hname:  i18n.trf('{0}: яркость', '${hn}')
			min:    -100
			max:    100
			digits: 0
			get:    fn [z] (e &EditState) f32 {
				return e.params.grade.zones[z].lum
			}
			set:    fn [z] (mut e EditState, v f32) {
				e.params.grade.zones[z].lum = v
			}
			fx:     tone_fx
		})
		w.hue = hue.sl
		w.sat = sat.sl
		tabs.add_tab(i18n.tr(pipeline.grade_names[z]), section([
			SectionRow{w.cv},
			SectionRow{edit_row(mut st, mut hue, lbl_w, val_w)},
			SectionRow{edit_row(mut st, mut sat, lbl_w, val_w)},
			SectionRow{edit_row(mut st, mut lum, lbl_w, val_w)},
		]))
	}
	mut blend := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Смешение')
		hname:  i18n.tr('Цветокоррекция: смешение')
		max:    100
		def:    50
		digits: 0
		signed: false
		get:    fn (e &EditState) f32 {
			return e.params.grade.blend
		}
		set:    fn (mut e EditState, v f32) {
			e.params.grade.blend = v
		}
		fx:     tone_fx
	})
	mut bal := edit_slider(mut st, SliderCfg{
		label:  i18n.tr('Баланс')
		hname:  i18n.tr('Цветокоррекция: баланс')
		min:    -100
		max:    100
		digits: 0
		get:    fn (e &EditState) f32 {
			return e.params.grade.balance
		}
		set:    fn (mut e EditState, v f32) {
			e.params.grade.balance = v
		}
		fx:     tone_fx
	})
	mut hint := vgui.label(i18n.tr('Круг: угол - оттенок, от центра - насыщенность'))
	st.hint_labels << hint
	hint.font_size = 12
	return section([
		SectionRow{tabs},
		SectionRow{edit_row(mut st, mut blend, lbl_w, val_w)},
		SectionRow{edit_row(mut st, mut bal, lbl_w, val_w)},
		SectionRow{hint},
	])
}
