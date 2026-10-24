module main

// Гистограмма правой панели: холст 256×100 (колонка = бин), растянутый на
// виджет. Виды («Вид - Гистограмма», запоминаются в настройках):
//   - по результату (по умолчанию): каналы R, G, B 8-битного превью;
//   - RAW: по сырью прямо из LibRaw (dev_linear - до коррекции объектива,
//     шумодава, баланса белого и тона), ось - ступени EV от уровня клипа:
//     правая колонка - выбитые каналы (данных там нет, ползунками не
//     вытянуть), слабые линии сетки - через 1 EV;
//   - логарифмическая шкала по высоте: видны и редкие пиксели (несколько
//     выбитых точек, глубокие тени);
//   - линия яркости (люма BT.709) поверх каналов.
// Зоны (не в RAW): при наведении подсвечивается полоса тон-эквалайзера
// («Чёрные», «Тени», «Средние», «Света», «Белые» - узлы на тоновой позиции
// 0, 0.25 .. 1, почти ось 8-битной гистограммы), подсказка - её значение;
// перетаскивание вбок двигает этот ползунок эквалайзера (живой пересчёт,
// запись в историю по отпусканию).
// Треугольники клипа - clipping.v; в RAW правый - выбитые каналы сырья, и
// подсветка пересветов на превью - по сырью (glin), левый - провалы
// результата, как всегда.

import math
import vgui
import i18n

// HistBins - счётчики по 256 колонкам: каналы и люма. Пусто - нет кадра
struct HistBins {
mut:
	r []u32
	g []u32
	b []u32
	y []u32
}

fn (h &HistBins) ok() bool {
	return h.r.len == 256 && h.g.len == 256 && h.b.len == 256 && h.y.len == 256
}

// HistView - состояние гистограммы на экране (State.hv)
struct HistView {
mut:
	res   HistBins // по результату (последний render_histogram)
	raw   HistBins // по сырью (кэш: пересчёт при смене dev_linear)
	raw_k voidptr  // ключ кэша - данные dev_linear
	raw_n int
	raw_g int // и номер файла (адрес буфера может достаться новому кадру)
	marks bool // на холсте нарисованы треугольники клипа
	zone  int = -1 // зона под курсором (-1 - нет)
	// Перетаскивание зоны: ползунок эквалайзера, откуда начали (колонка
	// буфера, дробная) и значение в начале; moved - значение менялось
	drag   bool
	dz     int
	dx0    f32
	dv0    f32
	moved  bool
	eq_sl  []&vgui.Slider // ползунки эквалайзера (main)
	eq_txt []string       // их подписи
}

// Сырьё: уровень клипа (LibRaw с highlight = 0 обрезает каналы на 65535;
// чуть ниже - запас на округления демозаики) и шкала EV
const raw_clip_lvl = 65200
const raw_ev_span = f32(10) // ступеней на колонках 0..254
const raw_col_per_ev = f32(254) / raw_ev_span

// raw_col_lut - колонка RAW-гистограммы для каждого значения u16: 255 -
// клип, 254 - 0 EV, влево по raw_col_per_ev на ступень, темнее - в 0
const raw_col_lut = make_raw_col_lut()

fn make_raw_col_lut() []u8 {
	mut t := []u8{len: 65536}
	for v in 1 .. 65536 {
		if v >= raw_clip_lvl {
			t[v] = 255
			continue
		}
		ev := math.log2(f64(v) / f64(raw_clip_lvl))
		t[v] = u8(math.clamp(254 + int(math.ceil(ev * raw_col_per_ev)), 0, 254))
	}
	return t
}

// Перетаскивание зоны: ступеней эквалайзера на колонку буфера (вся ширина
// гистограммы - 4 EV), шаг значения
const hist_drag_ev_per_col = f32(4) / 256
const hist_drag_step = f32(0.05)

fn hist_tip_default() string {
	return i18n.tr('Наведите на зону - её ползунок эквалайзера, тяните вбок - меняйте. Треугольники: провалы (слева) и пересветы (справа) - щелчок показывает их на снимке, J - оба')
}

fn hist_tip_raw() string {
	return i18n.tr('RAW: данные сенсора, ось - ступени EV до клипа. Правый край - выбитые каналы: эти данные не вытянуть. Правый треугольник показывает их на снимке')
}

// count_result - счётчики по 8-битному RGBA-результату, каждый второй
// пиксель (на форму не влияет, стоимость вдвое ниже)
fn count_result(pixels []u8) HistBins {
	mut h := HistBins{
		r: []u32{len: 256}
		g: []u32{len: 256}
		b: []u32{len: 256}
		y: []u32{len: 256}
	}
	unsafe {
		mut s := &u8(pixels.data)
		pr := &u32(h.r.data)
		pg := &u32(h.g.data)
		pb := &u32(h.b.data)
		py := &u32(h.y.data)
		for _ in 0 .. pixels.len / 8 {
			pr[s[0]]++
			pg[s[1]]++
			pb[s[2]]++
			py[(54 * int(s[0]) + 183 * int(s[1]) + 19 * int(s[2])) >> 8]++
			s += 8
		}
	}
	return h
}

// count_raw - счётчики по линейному 16-битному RGB (3 канала), каждый
// второй пиксель, колонки - raw_col_lut
fn count_raw(lin []u16) HistBins {
	mut h := HistBins{
		r: []u32{len: 256}
		g: []u32{len: 256}
		b: []u32{len: 256}
		y: []u32{len: 256}
	}
	lut := raw_col_lut
	unsafe {
		mut s := &u16(lin.data)
		pr := &u32(h.r.data)
		pg := &u32(h.g.data)
		pb := &u32(h.b.data)
		py := &u32(h.y.data)
		pl := &u8(lut.data)
		for _ in 0 .. lin.len / 6 {
			r := int(s[0])
			g := int(s[1])
			b := int(s[2])
			pr[pl[r]]++
			pg[pl[g]]++
			pb[pl[b]]++
			py[pl[(54 * r + 183 * g + 19 * b) >> 8]]++
			s += 6
		}
	}
	return h
}

// ensure_raw_bins - RAW-счётчики открытого кадра (пересчёт, только если
// сменилось сырьё); false - сырья нет
fn ensure_raw_bins(mut st State) bool {
	if st.dev_linear.len < 3 {
		return false
	}
	k := voidptr(st.dev_linear.data)
	if st.hv.raw.ok() && st.hv.raw_k == k && st.hv.raw_n == st.dev_linear.len
		&& st.hv.raw_g == st.file_gen {
		return true
	}
	st.hv.raw = count_raw(st.dev_linear)
	st.hv.raw_k = k
	st.hv.raw_n = st.dev_linear.len
	st.hv.raw_g = st.file_gen
	return true
}

// hist_raw_on - RAW-вид включён и сырьё есть
fn hist_raw_on(mut st State) bool {
	return st.settings.hist_raw && ensure_raw_bins(mut st)
}

// render_histogram считает гистограмму по 8-битному результату (RGBA-буфер
// холста) и рисует выбранный вид. Возвращает каналы результата - фон
// редактора кривых.
fn render_histogram(mut st State, mut hist vgui.Canvas, pixels []u8) ([]u32, []u32, []u32) {
	st.hv.res = count_result(pixels)
	st.hv.marks = false
	draw_hist_view(mut st, mut hist)
	return st.hv.res.r, st.hv.res.g, st.hv.res.b
}

// draw_hist_view - нарисовать показанный вид по готовым счётчикам
fn draw_hist_view(mut st State, mut hist vgui.Canvas) {
	raw := hist_raw_on(mut st)
	bins := if raw { st.hv.raw } else { st.hv.res }
	if !bins.ok() {
		hist.fill(st.pal.hist[0])
		hist.mark_dirty()
		return
	}
	draw_histogram(mut hist, bins, HistLook{
		log:  st.settings.hist_log
		luma: !st.settings.no_hist_luma
		grid: raw
		zone: if raw { -1 } else { st.hv.zone }
	}, st.pal)
}

// HistLook - как рисовать: шкала, линия яркости, сетка EV, подсвеченная зона
struct HistLook {
	log  bool
	luma bool
	grid bool
	zone int = -1
}

// hist_height - высота столбца в строках холста
fn hist_height(c u32, mx u32, h int, log bool) int {
	if c == 0 {
		return 0
	}
	if log {
		return int(f64(h) * math.log(1 + f64(c)) / math.log(1 + f64(mx)) + 0.5)
	}
	return int(u64(c) * u64(h) / u64(mx))
}

// zone_of - зона эквалайзера по колонке (ближайший узел t = 0, 0.25 .. 1)
fn zone_of(x int) int {
	return int(math.clamp(math.round(f64(x) / 255 * 4), 0, 4))
}

// grid_col - колонка с линией сетки EV (каждая ступень от 0 EV влево)
fn grid_col(x int) bool {
	if x >= 254 {
		return false
	}
	for k in 1 .. int(raw_ev_span) {
		if x == 254 - int(math.round(f32(k) * raw_col_per_ev)) {
			return true
		}
	}
	return false
}

// draw_histogram - столбцы трёх каналов в цветах палитры темы (цвет пикселя
// - по маске каналов, чей столбец его накрывает), фон зоны и сетки, линия
// яркости поверх (с каймой цвета фона - видна и над светлыми столбцами).
// Масштаб - по каналам: люма выше них обрезается сверху.
fn draw_histogram(mut hist vgui.Canvas, b HistBins, look HistLook, p Palette) {
	mut mx := u32(1)
	for i in 0 .. 256 {
		if b.r[i] > mx {
			mx = b.r[i]
		}
		if b.g[i] > mx {
			mx = b.g[i]
		}
		if b.b[i] > mx {
			mx = b.b[i]
		}
	}
	w := hist.width // 256: колонка = бин
	h := hist.height
	zone_bg := p.hist[0].blend(p.hist[7], 0.14)
	grid_bg := p.hist[0].blend(p.hist[7], 0.10)
	line := if p.dark { vgui.Color{255, 255, 255, 255} } else { p.text }
	mut prev_y := -1
	unsafe {
		mut dst := &u8(hist.pixels.data)
		for x in 0 .. w {
			th_r := hist_height(b.r[x], mx, h, look.log)
			th_g := hist_height(b.g[x], mx, h, look.log)
			th_b := hist_height(b.b[x], mx, h, look.log)
			bg := if look.zone >= 0 && zone_of(x) == look.zone {
				zone_bg
			} else if look.grid && grid_col(x) {
				grid_bg
			} else {
				p.hist[0]
			}
			for y in 0 .. h {
				up := h - y // высота столбца, накрывающего строку y
				m := (if th_r >= up { 1 } else { 0 }) | (if th_g >= up { 2 } else { 0 }) | (if th_b >= up {
					4
				} else {
					0
				})
				c := if m == 0 { bg } else { p.hist[m] }
				mut d := dst + (y * w + x) * 4
				d[0] = c.r
				d[1] = c.g
				d[2] = c.b
				d[3] = 255
			}
			if !look.luma {
				continue
			}
			// Линия яркости: строка вершины столбца люмы; от вершины
			// соседней колонки - вертикальный отрезок, чтобы линия была
			// сплошной на крутых склонах
			ty := math.min(hist_height(b.y[x], mx, h, look.log), h)
			yy := math.min(h - ty, h - 1)
			a := if prev_y < 0 { yy } else { math.min(prev_y, yy) }
			z := if prev_y < 0 { yy } else { math.max(prev_y, yy) }
			for y in a - 1 .. z + 2 {
				if y < 0 || y >= h {
					continue
				}
				c := if y == a - 1 || y == z + 1 { p.hist[0] } else { line }
				mut d := dst + (y * w + x) * 4
				d[0] = c.r
				d[1] = c.g
				d[2] = c.b
			}
			prev_y = yy
		}
	}
	hist.mark_dirty()
}

// clear_histogram - пустая гистограмма (кадр закрыт) - фон темы
fn clear_histogram(mut st State, mut hist vgui.Canvas) {
	st.hv.res = HistBins{}
	st.hv.marks = false
	hist.fill(st.pal.hist[0])
	hist.mark_dirty()
}

// show_clip_marks - треугольники клипа: правый - по показанному виду
// (результат или сырьё), левый - провалы результата
fn show_clip_marks(mut st State, mut hist vgui.Canvas) {
	if !st.hv.res.ok() {
		return
	}
	res := st.hv.res
	hi_seen := if hist_raw_on(mut st) {
		st.hv.raw.r[255] + st.hv.raw.g[255] + st.hv.raw.b[255] > 0
	} else {
		res.r[255] + res.g[255] + res.b[255] > 0
	}
	lo_seen := res.r[0] + res.g[0] + res.b[0] > 0
	draw_clip_marks(mut hist, hi_seen, lo_seen, st.clip_hi, st.clip_lo, st.pal)
	st.hv.marks = true
}

// repaint_histogram - перерисовать показанную гистограмму без пересчёта
// (смена темы, вида, зоны под курсором)
fn repaint_histogram(mut st State) {
	if isnil(st.hist_cv) {
		return
	}
	mut hist := st.hist_cv
	if !st.hv.res.ok() {
		clear_histogram(mut st, mut hist)
		return
	}
	marks := st.hv.marks
	draw_hist_view(mut st, mut hist)
	if marks {
		show_clip_marks(mut st, mut hist)
	}
}

// raw_clip_src - сырьё для подсветки пересветов превью в RAW-виде (glin -
// сырьё превью после геометрии, сетка пикселей та же, что у холста); nil -
// подсветка по результату
fn raw_clip_src(mut st State, npix int) &u16 {
	if st.settings.hist_raw && st.glin.len == npix * 3 {
		return unsafe { &u16(st.glin.data) }
	}
	return unsafe { nil }
}

// hist_zone_tip - подсказка зоны: название и значение ползунка
fn hist_zone_tip(st &State, z int) string {
	if z < 0 || z >= st.hv.eq_sl.len {
		return hist_tip_default()
	}
	v := st.hv.eq_sl[z].value
	return i18n.trf('Эквалайзер: {0} {1} EV - тяните влево или вправо', st.hv.eq_txt[z],
		fmt_signed(v, 2))
}

// set_hist_zone - зона под курсором (-1 - нет): подсветка и подсказка
fn set_hist_zone(mut st State, z int) {
	mut hist := st.hist_cv
	if z != st.hv.zone {
		st.hv.zone = z
		repaint_histogram(mut st)
	}
	hist.tooltip = if hist_raw_on(mut st) {
		hist_tip_raw()
	} else if z >= 0 {
		hist_zone_tip(st, z)
	} else {
		hist_tip_default()
	}
}

// hist_input - мышь над гистограммой: треугольники (clipping.v), зоны и
// перетаскивание зоны
fn hist_input(mut st State, ev &vgui.CanvasInputEvent) {
	frame := st.hv.res.ok() && st.hv.eq_sl.len == 5
	raw := st.settings.hist_raw
	match ev.kind {
		.pointer_down {
			if ev.button != 1 {
				return
			}
			match clip_hit_test(ev.x, ev.y, 256) {
				1 {
					set_clip_warn(mut st, !st.clip_hi, st.clip_lo)
					return
				}
				-1 {
					set_clip_warn(mut st, st.clip_hi, !st.clip_lo)
					return
				}
				else {}
			}
			if !frame || raw {
				return
			}
			z := zone_of(ev.x)
			mut sl := st.hv.eq_sl[z]
			if !sl.enabled {
				return
			}
			st.hv.drag = true
			st.hv.dz = z
			st.hv.dx0 = ev.fx
			st.hv.dv0 = sl.value
			st.hv.moved = false
			set_hist_zone(mut st, z)
		}
		.pointer_move {
			if !st.hv.drag {
				return
			}
			mut sl := st.hv.eq_sl[st.hv.dz]
			d := (ev.fx - st.hv.dx0) * hist_drag_ev_per_col
			v := f32(math.round((st.hv.dv0 + d) / hist_drag_step)) * hist_drag_step
			if v == sl.value {
				return
			}
			// edit_slider под hist_drag: значение и подпись, пересчёт -
			// отложенный (defer_fx), без записи в историю
			st.hist_drag = true
			sl.set_value(v)
			st.hist_drag = false
			st.hv.moved = true
			mut hist := st.hist_cv
			hist.tooltip = hist_zone_tip(st, st.hv.dz)
		}
		.pointer_up {
			if !st.hv.drag {
				return
			}
			st.hv.drag = false
			if st.hv.moved {
				mut sl := st.hv.eq_sl[st.hv.dz]
				if !isnil(sl.on_release) {
					sl.on_release(sl.value) // пересчёт и запись в историю
				}
			}
			z := if ev.in_image && frame && !raw { zone_of(ev.x) } else { -1 }
			set_hist_zone(mut st, z)
		}
		.hover, .enter {
			if st.hv.drag {
				return
			}
			z := if frame && !raw && clip_hit_test(ev.x, ev.y, 256) == 0 {
				zone_of(ev.x)
			} else {
				-1
			}
			set_hist_zone(mut st, z)
		}
		.leave {
			if !st.hv.drag {
				set_hist_zone(mut st, -1)
			}
		}
		else {}
	}
}

// set_hist_opt - смена вида гистограммы из меню: запомнить; RAW меняет и
// подсветку пересветов превью - полный пересчёт, остальное - перерисовка
fn set_hist_opt(mut st State, raw_changed bool) {
	save_settings(st.settings)
	if raw_changed && !isnil(st.tone_fx) && st.linear.len > 0 {
		st.tone_fx()
	} else {
		repaint_histogram(mut st)
	}
	if !isnil(st.hist_cv) {
		set_hist_zone(mut st, -1)
	}
}

// hist_menu - подменю «Вид - Гистограмма»: RAW, логарифмическая шкала,
// линия яркости
fn hist_menu(mut st State) (&vgui.MenuItem, []&vgui.MenuItem) {
	mut sub := vgui.menu_submenu(i18n.tr('Гистограмма'))
	mut m_raw := vgui.menu_checkbox(i18n.tr('RAW: данные сенсора'), st.settings.hist_raw)
	m_raw.on_toggle = fn [mut st] (v bool) {
		st.settings.hist_raw = v
		set_hist_opt(mut st, true)
	}
	mut m_log := vgui.menu_checkbox(i18n.tr('Логарифмическая шкала'), st.settings.hist_log)
	m_log.on_toggle = fn [mut st] (v bool) {
		st.settings.hist_log = v
		set_hist_opt(mut st, false)
	}
	mut m_luma := vgui.menu_checkbox(i18n.tr('Линия яркости'), !st.settings.no_hist_luma)
	m_luma.on_toggle = fn [mut st] (v bool) {
		st.settings.no_hist_luma = !v
		set_hist_opt(mut st, false)
	}
	sub.add(m_raw)
	sub.add(m_log)
	sub.add(m_luma)
	return sub, [m_raw, m_log, m_luma]
}
