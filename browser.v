module main

// Браузер папки: лента миниатюр всех RAW-файлов папки открытого кадра
// под областью просмотра. Щелчок по миниатюре или ←/→, Home/End -
// переход к кадру; правки каждого кадра живут в его сайдкаре (sidecar.v),
// поэтому переключение ничего не теряет: open_file просто открывает
// следующий файл и восстанавливает его правки.
//
// Миниатюры - из встроенного в RAW превью камеры (raw.thumb_min, у CR3 -
// 1620x1080, без демозаики): открытие + извлечение ~2-8 мс, декод ~15 мс,
// уменьшение - единицы мс. Считаются в одном фоновом потоке по порядку
// «от текущего кадра наружу» и по одной отдаются в главный поток через
// app.post(). Кэша на диске нет: ~25 мс на кадр - 100 кадров за ~2.5 с
// в фоне, лента при этом живая.
//
// Лента - горизонтальный vgui.ListBox (list_box_h): элемент - VBox из
// миниатюры (Canvas, вписывание с сохранением пропорций, пассивный) и
// подписи имени файла. Высота ленты меняется вертикальным сплиттером.
// Скрытие ленты - пересборка области просмотра (VBox.clear + add):
// VBox.remove в vgui не работает (сравнивает voidptr интерфейса и всегда
// возвращает false).
import os
import math
import vgui
import raw
import stbi

// Расширения RAW для сканирования папки (без учёта регистра)
const raw_exts = ['cr3', 'cr2', 'crw', 'nef', 'arw', 'dng', 'raf', 'orf', 'rw2']

// Буфер миниатюры: 3:2 (кадр Canon), вдвое больше ячейки - чётко на HiDPI
const thumb_w = 276
const thumb_h = 184
// Лента: высота панели ленты при старте (вертикальный сплиттер), полоса
// над лентой, подпись имени; ширина ячейки подстраивается под высоту
// (strip_item_width) - миниатюра 3:2 растёт вместе с лентой
const strip_pane_h = f32(170)
const strip_bar_h = f32(26)
const strip_name_h = f32(18)
// Поле ListBox ленты: при 4 (по умолчанию) крайняя частично видимая
// миниатюра заезжала на рамку - отсечение vgui расширено на 1 px наружу,
// а поле почти целиком занято самой рамкой и кольцом фокуса
const strip_pad = f32(8)
// Поле панели ленты (strip_box: полоса + лента на фоне палитры pal.viewer)
const strip_box_pad = f32(8)
const thumb_bg = vgui.Color{30, 30, 33, 255}
// Отметка «кадр изменён» (есть сайдкар) - кружок в правом верхнем углу
const mark_color = vgui.Color{240, 160, 60, 255}
const mark_ring = vgui.Color{20, 20, 22, 255}

// Frame - кадр папки в ленте
struct Frame {
	path string
mut:
	edited bool // есть сайдкар правок
	name   &vgui.Label = unsafe { nil } // подпись: у текущего кадра - жирная
	// Миниатюра живёт только в пикселях холста (без отдельной копии: ~200 КБ
	// на кадр); отметка «изменён» только добавляется - рисуется поверх
	cv &vgui.Canvas = unsafe { nil }
}

// StopFlag - флаг остановки фонового воркера миниатюр (смена папки,
// выход). Читается воркером без синхронизации: bool, опоздание на одну
// миниатюру безвредно.
@[heap]
struct StopFlag {
mut:
	stop bool
}

struct ThumbResult {
	gen int // номер загрузки папки: результаты старой папки отбрасываются
	idx int
	pix []u8
}

// is_raw_file - файл с расширением RAW (без учёта регистра)
fn is_raw_file(name string) bool {
	return os.file_ext(name).to_lower().trim_left('.') in raw_exts
}

// scan_folder - все RAW-файлы папки (полные пути), по имени
fn scan_folder(dir string) []string {
	names := os.ls(dir) or { return [] }
	mut out := []string{}
	for n in names {
		p := os.join_path(dir, n)
		if is_raw_file(n) && !os.is_dir(p) {
			out << p
		}
	}
	out.sort()
	return out
}

// thumb_order - порядок расчёта миниатюр: текущий кадр, затем соседи
// через один в обе стороны - видимые в ленте появляются первыми.
fn thumb_order(n int, cur int) []int {
	mut order := []int{cap: n}
	if n == 0 {
		return order
	}
	c := if cur >= 0 && cur < n { cur } else { 0 }
	order << c
	for d in 1 .. n {
		if c + d < n {
			order << c + d
		}
		if c - d >= 0 {
			order << c - d
		}
		if c + d >= n && c - d < 0 {
			break
		}
	}
	return order
}

// fit_thumb вписывает RGB-картинку w x h в буфер RGBA bw x bh (поля -
// thumb_bg) с поворотом по flip LibRaw (3 - 180°, 5 - 90° против часовой,
// 6 - 90° по часовой) и уменьшением усреднением по блоку источника.
fn fit_thumb(src []u8, w int, h int, flip int, bw int, bh int) []u8 {
	mut out := []u8{len: bw * bh * 4}
	for i in 0 .. bw * bh {
		out[i * 4] = thumb_bg.r
		out[i * 4 + 1] = thumb_bg.g
		out[i * 4 + 2] = thumb_bg.b
		out[i * 4 + 3] = 255
	}
	if w <= 0 || h <= 0 || src.len < w * h * 3 {
		return out
	}
	rot := flip & 4 != 0
	ow := if rot { h } else { w } // размеры в ориентации показа
	oh := if rot { w } else { h }
	sx := f64(bw) / f64(ow)
	sy := f64(bh) / f64(oh)
	s := if sx < sy { sx } else { sy }
	mut dw := int(f64(ow) * s + 0.5)
	mut dh := int(f64(oh) * s + 0.5)
	dw = if dw < 1 { 1 } else if dw > bw { bw } else { dw }
	dh = if dh < 1 { 1 } else if dh > bh { bh } else { dh }
	ox := (bw - dw) / 2
	oy := (bh - dh) / 2
	for y in 0 .. dh {
		v0 := y * oh / dh
		mut v1 := (y + 1) * oh / dh
		if v1 <= v0 {
			v1 = v0 + 1
		}
		for x in 0 .. dw {
			u0 := x * ow / dw
			mut u1 := (x + 1) * ow / dw
			if u1 <= u0 {
				u1 = u0 + 1
			}
			mut r := 0
			mut g := 0
			mut b := 0
			for v in v0 .. v1 {
				for u in u0 .. u1 {
					// Точка (u, v) показа -> точка источника
					px, py := match flip {
						3 { w - 1 - u, h - 1 - v }
						5 { w - 1 - v, u }
						6 { v, h - 1 - u }
						else { u, v }
					}
					k := (py * w + px) * 3
					r += src[k]
					g += src[k + 1]
					b += src[k + 2]
				}
			}
			n := (v1 - v0) * (u1 - u0)
			d := ((oy + y) * bw + ox + x) * 4
			out[d] = u8(r / n)
			out[d + 1] = u8(g / n)
			out[d + 2] = u8(b / n)
		}
	}
	return out
}

// make_thumb - миниатюра RAW-файла: своё открытие LibRaw (воркер не
// делит хендл с GUI), встроенное превью не меньше буфера, поворот.
fn make_thumb(path string) ![]u8 {
	mut d := raw.open(path)!
	defer {
		d.close()
	}
	j := d.thumb_min(thumb_w)!
	flip := d.flip()
	mut img := stbi.load_from_memory(j.data, j.len, desired_channels: 3)!
	defer {
		img.free()
	}
	src := unsafe { img.data.vbytes(img.width * img.height * 3) }
	return fit_thumb(src, img.width, img.height, flip, thumb_w, thumb_h)
}

// thumb_worker выполняется в spawn: миниатюры по порядку order, каждая -
// в главный поток через app.post (единственный потокобезопасный вход
// vgui). Не читаемый файл пропускается - остаётся пустая ячейка.
fn thumb_worker(paths []string, order []int, gen int, stop &StopFlag, mut app vgui.App, on_done fn (ThumbResult)) {
	for idx in order {
		if stop.stop {
			return
		}
		pix := make_thumb(paths[idx]) or { continue }
		res := ThumbResult{
			gen: gen
			idx: idx
			pix: pix
		}
		app.post(fn [on_done, res] () {
			on_done(res)
		})
	}
}

// stop_thumbs останавливает воркер миниатюр (смена папки, выход);
// дождаться - wait_thumbs.
fn stop_thumbs(mut st State) {
	if !isnil(st.thumb_stop) {
		mut s := st.thumb_stop
		s.stop = true
	}
}

fn wait_thumbs(mut st State) {
	stop_thumbs(mut st)
	for t in st.thumb_threads {
		t.wait()
	}
	st.thumb_threads.clear()
}

// load_folder - новая папка в ленте: список кадров, ячейки с пустыми
// миниатюрами, отметки изменённых, фоновый расчёт миниатюр.
fn load_folder(mut st State, dir string, cur_path string, mut app vgui.App) {
	stop_thumbs(mut st)
	st.thumb_gen++
	st.folder = dir
	paths := scan_folder(dir)
	st.frames = []Frame{}
	mut strip := st.strip
	strip.clear()
	for p in paths {
		mut cv := vgui.canvas(thumb_w, thumb_h)
		// Вписывание с сохранением пропорций (auto_fit): любая высота ленты
		cv.stretch = false
		cv.enabled = false // пассивный: щелчок уходит в список
		cv.set_wheel_zoom(false)
		cv.set_pan_buttons(0)
		mut name := vgui.label(os.file_name(p))
		name.align = .center
		name.font_size = 12
		name.color = st.pal.secondary
		mut cell := vgui.create_vbox_fill()
		cell.set_spacing(4)
		cell.add(cv, 1)
		cell.add_fixed(name, strip_name_h)
		strip.add_item_widget(cell)
		cv.fill(thumb_bg)
		st.frames << Frame{
			path:   p
			edited: os.exists(sidecar_path(p))
			name:   name
			cv:     cv
		}
		draw_mark(mut st, st.frames.len - 1)
	}
	cur := paths.index(cur_path)
	stop := &StopFlag{}
	st.thumb_stop = stop
	st.thumb_threads << spawn thumb_worker(paths, thumb_order(paths.len, cur), st.thumb_gen,
		stop, mut app, st.thumb_done)
	layout_strip(mut st)
}

// take_thumb принимает миниатюру из воркера (главный поток)
fn take_thumb(mut st State, res ThumbResult) {
	if res.gen != st.thumb_gen || res.idx < 0 || res.idx >= st.frames.len {
		return
	}
	mut cv := st.frames[res.idx].cv
	cv.pixels = res.pix
	draw_mark(mut st, res.idx)
}

// draw_mark - отметка «изменён» (кружок в правом верхнем углу) поверх
// миниатюры, если кадр изменён; холст перерисовывается в любом случае
fn draw_mark(mut st State, idx int) {
	f := st.frames[idx]
	if isnil(f.cv) {
		return
	}
	mut cv := f.cv
	if f.edited {
		draw_dot(mut cv.pixels, thumb_w - 18, 18, 12, mark_ring)
		draw_dot(mut cv.pixels, thumb_w - 18, 18, 9, mark_color)
	}
	cv.mark_dirty()
}

// draw_dot - залитый круг в RGBA-буфере миниатюры (края сглажены)
fn draw_dot(mut pix []u8, cx int, cy int, r int, c vgui.Color) {
	for y in cy - r - 1 .. cy + r + 2 {
		for x in cx - r - 1 .. cx + r + 2 {
			if x < 0 || y < 0 || x >= thumb_w || y >= thumb_h {
				continue
			}
			dx := f32(x - cx)
			dy := f32(y - cy)
			d := f32(r) + 0.5 - math.sqrtf(dx * dx + dy * dy)
			a := if d >= 1 { f32(1) } else if d <= 0 { f32(0) } else { d }
			if a == 0 {
				continue
			}
			k := (y * thumb_w + x) * 4
			pix[k] = u8(f32(pix[k]) * (1 - a) + f32(c.r) * a)
			pix[k + 1] = u8(f32(pix[k + 1]) * (1 - a) + f32(c.g) * a)
			pix[k + 2] = u8(f32(pix[k + 2]) * (1 - a) + f32(c.b) * a)
		}
	}
}

// mark_edited - у текущего кадра появился сайдкар (первая правка)
fn mark_edited(mut st State) {
	if st.frame_idx < 0 || st.frame_idx >= st.frames.len || st.frames[st.frame_idx].edited {
		return
	}
	st.frames[st.frame_idx].edited = true
	draw_mark(mut st, st.frame_idx)
}

// show_frame - после открытия файла: папка в ленте (новая - загрузить),
// выделение и прокрутка к кадру, счётчик «N из M».
fn show_frame(mut st State, path string, mut app vgui.App) {
	if isnil(st.strip) {
		return
	}
	dir := os.dir(path)
	if dir != st.folder {
		load_folder(mut st, dir, path, mut app)
	}
	st.frame_idx = -1
	for i, f in st.frames {
		if f.path == path {
			st.frame_idx = i
			break
		}
	}
	sync_strip(mut st)
}

// sync_strip - выделение ленты на текущем кадре, жирная подпись у него,
// прокрутка - текущий по центру, подпись над лентой.
fn sync_strip(mut st State) {
	if isnil(st.strip) {
		return
	}
	mut strip := st.strip
	strip.set_selected(st.frame_idx)
	for i, f in st.frames {
		if isnil(f.name) {
			continue
		}
		mut l := f.name
		cur := i == st.frame_idx
		// У редактируемого - ярче и жирным (выделение ленты может стоять
		// на другом: одиночный щелчок только выделяет); цвета - из темы
		l.color = if cur { st.pal.text } else { st.pal.secondary }
		l.font_style = if cur { vgui.FontStyle.bold } else { vgui.FontStyle.regular }
	}
	center_strip(mut st)
	strip_info_text(mut st)
}

// strip_info_text - подпись над лентой: папка, «N из M», при выделении
// нескольких кадров (Ctrl/Shift+щелчок) - «выделено K»
fn strip_info_text(mut st State) {
	if isnil(st.strip_info) || isnil(st.strip) {
		return
	}
	mut info := st.strip_info
	pos := if st.frame_idx >= 0 { '${st.frame_idx + 1} из ${st.frames.len}' } else { '${st.frames.len} кадров' }
	mut text := '${os.file_name(st.folder)}  ·  ${pos}'
	n := st.strip.get_selection().len
	if n > 1 {
		text += '  ·  выделено ${n}'
	}
	info.text = text
}

// strip_item_width - ширина ячейки ленты под высоту её панели pane_h
// (полоса + лента): миниатюра 3:2 во всю высоту ячейки над подписью.
// Отступы: 2 x strip_box_pad - поля панели, 4 - между полосой и лентой,
// 2 x strip_pad - поля ListBox, 2 x 6 - поля ячейки, 4 - между
// миниатюрой и подписью.
fn strip_item_width(pane_h f32) f32 {
	thumb := pane_h - 2 * strip_box_pad - strip_bar_h - 4 - 2 * strip_pad - 12 - 4 - strip_name_h
	w := thumb * 1.5 + 12
	return if w < 80 { 80 } else { w }
}

// fit_strip_items - ширина ячеек по текущей высоте панели ленты
// (после перетаскивания сплиттера и при сборке раскладки); редактируемый
// кадр - снова по центру.
fn fit_strip_items(mut st State) {
	if isnil(st.strip) || isnil(st.vsplit) {
		return
	}
	sp := st.vsplit
	mut pane := strip_pane_h
	if sp.bounds.h > 0 {
		pane = (sp.bounds.h - sp.bar_size) * (1 - sp.ratio)
	}
	mut strip := st.strip
	strip.item_width = strip_item_width(pane)
	center_strip(mut st)
}

// center_strip прокручивает ленту так, чтобы редактируемый кадр был по
// центру (у краёв - сколько позволяет лента: лишнее обрежет arrange
// ListBox). Ширина видимой части - по раскладке: сразу после
// перетаскивания горизонтального сплиттера bounds ленты ещё старые,
// поэтому она считается от доли сплиттера «просмотр | панель».
fn center_strip(mut st State) {
	if isnil(st.strip) || st.frame_idx < 0 {
		return
	}
	mut strip := st.strip
	mut view_w := strip.bounds.w - 2 * strip.pad
	if !isnil(st.hsplit) && st.hsplit.bounds.w > 0 {
		sp := st.hsplit
		// Ширина просмотра минус поля панели ленты
		view_w = (sp.bounds.w - sp.bar_size) * sp.ratio - 2 * strip_box_pad - 2 * strip.pad
	}
	if view_w <= 0 {
		return
	}
	iw := strip.item_width
	mut x := f32(st.frame_idx) * iw + iw / 2 - view_w / 2
	if x < 0 {
		x = 0
	}
	strip.scroll_x = x
}

// layout_strip собирает область просмотра: без папки - только область
// снимка (view_area); лента открыта - вертикальный сплиттер «снимок |
// полоса + лента»; скрыта - снимок и под ним панель с одной полосой
// («Показать ленту»). Пересборка через clear + add: VBox.remove в vgui
// не работает.
fn layout_strip(mut st State) {
	if isnil(st.viewer) || isnil(st.strip) || isnil(st.strip_bar) || isnil(st.vsplit)
		|| isnil(st.view_area) {
		return
	}
	mut v := st.viewer
	mut sp := st.vsplit
	mut sb := st.strip_box
	v.clear()
	sp.clear_first()
	sp.clear_second()
	sb.clear()
	if st.frames.len == 0 {
		v.add(st.view_area, 1)
		return
	}
	sb.add_fixed(st.strip_bar, strip_bar_h)
	if st.strip_open {
		sb.add(st.strip, 1)
		sp.set_first(st.view_area)
		sp.set_second(sb)
		v.add(sp, 1)
		fit_strip_items(mut st)
	} else {
		v.add(st.view_area, 1)
		v.add_fixed(sb, strip_bar_h + 2 * strip_box_pad)
	}
	if !isnil(st.strip_toggle) {
		mut b := st.strip_toggle
		b.text = if st.strip_open { 'Скрыть ленту' } else { 'Показать ленту' }
	}
	if !isnil(st.m_strip) {
		mut m := st.m_strip
		m.checked = st.strip_open
	}
}

// set_strip_open - показать/скрыть ленту (кнопка на полосе, меню «Вид»),
// выбор запоминается в настройках
fn set_strip_open(mut st State, open bool) {
	st.strip_open = open
	st.settings.strip_open = open
	save_settings(st.settings)
	layout_strip(mut st)
}
