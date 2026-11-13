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
// Правки на миниатюрах (24.10.2026). Открытый кадр с правками - из его
// превью: после каждого пересчёта (apply_pipeline) результат уменьшается
// в буфер ленты (thumb_from_rgba, выборка точек, доли мс), миниатюра
// меняется по ходу правки. Остальные правленные кадры (сайдкар с
// current > 0) после быстрого прохода по JPEG камеры проявляются в том же
// фоновом потоке по сайдкару (tone_thumb - путь экспорта в размере
// превью, как левый кадр сравнения, без шумодава и резкости - на 276 px
// их не видно), ~1 с на кадр с пониженным приоритетом.
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
import pipeline
import lens
import i18n

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
	edited bool // есть правки (сайдкар, current > 0)
	mark   Mark // звёзды и флажок отбора (rating.v)
	name   &vgui.Label = unsafe { nil } // подпись: у текущего кадра - жирная
	// Ячейка ленты (миниатюра + подпись): строки ListBox пересобираются
	// по фильтру из этих ячеек (apply_filter)
	cell &vgui.VBox = unsafe { nil }
	// Миниатюра живёт только в пикселях холста (без отдельной копии: ~200 КБ
	// на кадр); отметка «изменён» только добавляется - рисуется поверх
	cv &vgui.Canvas = unsafe { nil }
	// Геометрия, которую показывает (или вот-вот покажет) миниатюра, и
	// номер её расчёта: результат старее показанного отбрасывается
	geom pipeline.Geom
	seq  int
	live bool // показывает превью открытого кадра (с правками), не JPEG камеры
	// edited и mark уже прочитаны из сайдкара (в фоне - HeadsResult, или
	// сразу - ensure_head, когда кадр трогают раньше)
	head bool
	// Что в пикселях холста (strip_thumbs): 0 - ничего (заглушка 3x2, кадр
	// далеко от видимой части ленты), 1 - JPEG камеры, 2 - окончательная
	// (с правками или живая открытого кадра), -1 - файл не читается
	thumb int
}

// HeadsResult - пометки и признаки правок всех кадров папки (из фона,
// по порядку paths); gen - как у ThumbResult
struct HeadsResult {
	gen   int
	heads []SideHead
}

struct ThumbResult {
	gen  int // номер загрузки папки: результаты старой папки отбрасываются
	seq  int // номер расчёта (refresh_thumb): старее показанного - мимо
	idx  int
	pix  []u8
	geom pipeline.Geom
	kind int // Frame.thumb: 1 - JPEG камеры, 2 - с правками, -1 - не вышло
}

// ThumbItem - кадр для воркера миниатюр: нужен JPEG камеры (camera) и/или
// проявка с правками (tone)
struct ThumbItem {
	idx    int
	path   string
	camera bool
	tone   bool
}

// Окно миниатюр ленты (strip_thumbs), в экранах ленты по обе стороны от
// видимой части: считать - 2 (прокрутка и увеличение окна до трёх раз
// не застают пустых ячеек), держать - 4 (туда-обратно не пересчитывает)
const strip_load_screens = 2
const strip_keep_screens = 4
// Видимых ячеек, пока лента не разложена (bounds нулевые)
const strip_vis_guess = 16

// is_raw_file - файл с расширением RAW (без учёта регистра)
fn is_raw_file(name string) bool {
	return os.file_ext(name).to_lower().trim_left('.') in raw_exts
}

// scan_folder - все RAW-файлы папки (полные пути), по имени; depth > 0 -
// и подпапок до этой глубины (1 - только дочерние): сначала файлы самой
// папки, потом подпапки по имени, каждая так же. Скрытые папки (с точки)
// и ссылки на папки пропускаются - ссылка может вести по кругу или в
// уже просмотренное.
fn scan_folder(dir string, depth int) []string {
	names := os.ls(dir) or { return [] }
	mut out := []string{}
	mut subs := []string{}
	for n in names {
		p := os.join_path(dir, n)
		if os.is_dir(p) {
			if depth > 0 && !n.starts_with('.') && !os.is_link(p) {
				subs << p
			}
		} else if is_raw_file(n) {
			out << p
		}
	}
	out.sort()
	subs.sort()
	for d in subs {
		out << scan_folder(d, depth - 1)
	}
	return out
}

// strip_depth - глубина подпапок в ленте по настройкам (0 - только папка)
fn strip_depth(s &Settings) int {
	return if s.strip_subdirs { subdir_depth(s.subdir_depth) } else { 0 }
}

// frame_subdir - подпапка кадра относительно папки ленты ('' - в ней самой)
fn frame_subdir(folder string, path string) string {
	d := os.dir(path)
	if folder == '' || d == folder || !d.starts_with(folder + os.path_separator) {
		return ''
	}
	return d[folder.len + 1..]
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
	fit_thumb_into(mut out, src, w, h, flip, bw, bh)
	return out
}

// fit_thumb_into - то же в готовый буфер out (bw * bh * 4; JPEG камеры
// кадра - буфер вне сборщика, bufown.v)
fn fit_thumb_into(mut out []u8, src []u8, w int, h int, flip int, bw int, bh int) {
	for i in 0 .. bw * bh {
		out[i * 4] = thumb_bg.r
		out[i * 4 + 1] = thumb_bg.g
		out[i * 4 + 2] = thumb_bg.b
		out[i * 4 + 3] = 255
	}
	if w <= 0 || h <= 0 || src.len < w * h * 3 {
		return
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
	return
}

// thumb_geom - геометрия кадра из его сайдкара (как на выходе:
// out_geom); нет сайдкара или не читается - без изменений
fn thumb_geom(path string) pipeline.Geom {
	side := load_side_current(sidecar_path(path)) or { return pipeline.Geom{} }
	if !side.has {
		return pipeline.Geom{}
	}
	return out_geom(&side.state)
}

// thumb_geom_max - наибольшая сторона картинки, по которой миниатюра
// считает геометрию кадра (кадрирование, поворот)
const thumb_geom_max = 1620

// make_thumb - миниатюра RAW-файла с геометрией g (кадрирование и
// поворот из сайдкара): своё открытие LibRaw (воркер не делит хендл с
// GUI), встроенное превью не меньше буфера, поворот по ориентации
// камеры; с геометрией - сначала обрезка во всю величину превью
// (geom_rgba, ближайший пиксель), потом уменьшение усреднением.
fn make_thumb(path string, g pipeline.Geom) ![]u8 {
	mut d := raw.open(path)!
	defer {
		d.close()
	}
	j := d.thumb_min(thumb_w)!
	flip := d.flip()
	// Декодер libjpeg - буфер вне сборщика: у форматов без малого превью
	// это полный JPEG (72 МБ на 24 Мп) на каждую миниатюру
	mut img := raw.decode_jpeg(j)!
	defer {
		img.free()
	}
	src := img.pix
	if g.is_identity() {
		return fit_thumb(src, img.width, img.height, flip, thumb_w, thumb_h)
	}
	// Геометрия - по картинке не больше малого превью Canon (1620 px по
	// длинной стороне): полный JPEG дал бы промежуточные буферы в сотни МБ
	mut ow := if flip & 4 != 0 { img.height } else { img.width }
	mut oh := if flip & 4 != 0 { img.width } else { img.height }
	long := if ow > oh { ow } else { oh }
	if long > thumb_geom_max {
		ow = int(f64(ow) * thumb_geom_max / long + 0.5)
		oh = int(f64(oh) * thumb_geom_max / long + 0.5)
	}
	pix := fit_thumb(src, img.width, img.height, flip, ow, oh)
	cw, ch := g.out_size(ow, oh, true)
	cut := pipeline.geom_rgba(pix, ow, oh, g, true, cw, ch)
	mut rgb := []u8{len: cw * ch * 3}
	for i in 0 .. cw * ch {
		rgb[i * 3] = cut[i * 4]
		rgb[i * 3 + 1] = cut[i * 4 + 1]
		rgb[i * 3 + 2] = cut[i * 4 + 2]
	}
	return fit_thumb(rgb, cw, ch, 0, thumb_w, thumb_h)
}

// heads_worker выполняется в spawn: пометки и правки всех кадров папки
// по сайдкарам - одной посылкой (фильтр ленты пересобирается один раз)
fn heads_worker(done &Done, paths []string, gen int, stop &StopFlag, mut app vgui.App, on_heads fn (HeadsResult)) {
	defer {
		done.set()
	}
	mut heads := []SideHead{cap: paths.len}
	for p in paths {
		if stop.is_set() {
			return
		}
		heads << read_side_head(p)
	}
	post_result(mut app, on_heads, HeadsResult{
		gen:   gen
		heads: heads
	})
}

// thumb_worker выполняется в spawn: миниатюры кадров items (видимая часть
// ленты с запасом, strip_thumbs) по порядку, каждая - в главный поток
// через post_result. Сначала JPEG камеры, вторым проходом - кадры с
// правками (tone_thumb) с пониженным приоритетом: окно и открытый кадр
// важнее. Не читаемый файл - результат kind -1 (больше не просить).
fn thumb_worker(done &Done, items []ThumbItem, db &lens.Database, gen int, seq int, stop &StopFlag, mut app vgui.App, on_done fn (ThumbResult)) {
	defer {
		done.set()
	}
	for it in items {
		if !it.camera {
			continue
		}
		if stop.is_set() {
			return
		}
		g := thumb_geom(it.path)
		pix := make_thumb(it.path, g) or { []u8{} }
		post_result(mut app, on_done, ThumbResult{
			gen:  gen
			seq:  seq
			idx:  it.idx
			pix:  pix
			geom: g
			kind: if pix.len > 0 { 1 } else { -1 }
		})
	}
	mut slow := false
	for it in items {
		if !it.tone {
			continue
		}
		if stop.is_set() {
			return
		}
		e := side_thumb_edit(it.path) or { continue }
		if !slow {
			apply_load(LoadLevel{
				nice: pf_nice
			})
			slow = true
		}
		pix := tone_thumb(it.path, e, db, stop) or { continue }
		post_result(mut app, on_done, ThumbResult{
			gen:  gen
			seq:  seq
			idx:  it.idx
			pix:  pix
			geom: out_geom(&e)
			kind: 2
		})
	}
}

// thumb_one выполняется в spawn: одна миниатюра заново (refresh_thumb):
// с правками из сайдкара - проявкой (tone_thumb), без них - JPEG камеры с
// геометрией g
fn thumb_one(done &Done, path string, g pipeline.Geom, db &lens.Database, stop &StopFlag, gen int, seq int, idx int, mut app vgui.App, on_done fn (ThumbResult)) {
	defer {
		done.set()
	}
	mut pix := []u8{}
	mut geom := g
	mut kind := 1
	if e := side_thumb_edit(path) {
		apply_load(LoadLevel{
			nice: pf_nice
		})
		pix = tone_thumb(path, e, db, stop) or { return }
		geom = out_geom(&e)
		kind = 2
	} else {
		pix = make_thumb(path, g) or { return }
	}
	post_result(mut app, on_done, ThumbResult{
		gen:  gen
		seq:  seq
		idx:  idx
		pix:  pix
		geom: geom
		kind: kind
	})
}

// side_thumb_edit - настройки кадра из сайдкара, если в нём есть правки
// (current > 0); нет сайдкара или правок - none (миниатюра - JPEG камеры)
fn side_thumb_edit(path string) ?EditState {
	side := load_side_current(sidecar_path(path)) or { return none }
	if !side.has || side.current <= 0 {
		return none
	}
	return side.state
}

// tone_thumb - миниатюра с правками: проявка по настройкам e путём
// экспорта в размере превью (develop_full half, как левый кадр сравнения)
// и вписывание в буфер ленты. Шумодав и резкость выключены: на 276 px их
// не видно, а шумодав - самая долгая часть. Отмена - по stop между этапами.
fn tone_thumb(path string, e EditState, db &lens.Database, stop &StopFlag) ![]u8 {
	mut te := e
	te.nr = [4]f32{}
	te.params.sharp.amount = 0
	te.params.sharp.dc_amount = 0
	d := batch_derive(path, te, db)!
	mut img := develop_full(path, d, db,
		half:     true
		progress: StageProgress(PairStop{
			stop: stop
		})
	)!
	defer {
		img.free()
	}
	return fit_thumb(img.rgb, img.width, img.height, 0, thumb_w, thumb_h)
}

// thumb_from_rgba - миниатюра из RGBA-результата превью (w x h, уже в
// ориентации и с геометрией кадра): вписывание в буфер ленты как у
// fit_thumb, по блоку источника - среднее до live_thumb_pts x
// live_thumb_pts точек (полное усреднение 6 Мп - десятки мс на каждый
// пересчёт превью; выборки на 276 px хватает)
const live_thumb_pts = 4

fn thumb_from_rgba(pix []u8, w int, h int) []u8 {
	bw := thumb_w
	bh := thumb_h
	mut out := []u8{len: bw * bh * 4}
	for i in 0 .. bw * bh {
		out[i * 4] = thumb_bg.r
		out[i * 4 + 1] = thumb_bg.g
		out[i * 4 + 2] = thumb_bg.b
		out[i * 4 + 3] = 255
	}
	if w <= 0 || h <= 0 || pix.len < w * h * 4 {
		return out
	}
	sx := f64(bw) / f64(w)
	sy := f64(bh) / f64(h)
	s := if sx < sy { sx } else { sy }
	mut dw := int(f64(w) * s + 0.5)
	mut dh := int(f64(h) * s + 0.5)
	dw = if dw < 1 { 1 } else if dw > bw { bw } else { dw }
	dh = if dh < 1 { 1 } else if dh > bh { bh } else { dh }
	ox := (bw - dw) / 2
	oy := (bh - dh) / 2
	for y in 0 .. dh {
		v0 := y * h / dh
		v1 := math.max((y + 1) * h / dh, v0 + 1)
		vs := math.max((v1 - v0) / live_thumb_pts, 1)
		for x in 0 .. dw {
			u0 := x * w / dw
			u1 := math.max((x + 1) * w / dw, u0 + 1)
			us := math.max((u1 - u0) / live_thumb_pts, 1)
			mut r := 0
			mut g := 0
			mut b := 0
			mut n := 0
			for v := v0; v < v1; v += vs {
				for u := u0; u < u1; u += us {
					k := (v * w + u) * 4
					r += pix[k]
					g += pix[k + 1]
					b += pix[k + 2]
					n++
				}
			}
			d := ((oy + y) * bw + ox + x) * 4
			out[d] = u8(r / n)
			out[d + 1] = u8(g / n)
			out[d + 2] = u8(b / n)
		}
	}
	return out
}

// open_frame_ok - открытый кадр стоит в ленте под frame_idx (при смене
// файла индекс обновляется позже первого пересчёта)
fn open_frame_ok(st &State) bool {
	return st.frame_idx >= 0 && st.frame_idx < st.frames.len
		&& st.frames[st.frame_idx].path == st.raw_path
}

// update_live_thumb - после пересчёта превью (apply_pipeline, чистый
// результат до подсветок): уменьшенная копия для ленты; у кадра с
// правками - сразу на миниатюру (видно по ходу правки)
fn update_live_thumb(mut st State, pix []u8, w int, h int) {
	if !open_frame_ok(st) {
		return
	}
	st.live_thumb = thumb_from_rgba(pix, w, h)
	st.live_gen = st.file_gen
	if st.hist_pos > 0 {
		push_live_thumb(mut st)
	}
}

// push_live_thumb - копия превью открытого кадра на его миниатюру;
// новый номер расчёта - фоновые миниатюры этого кадра её не перекроют
fn push_live_thumb(mut st State) {
	if !open_frame_ok(st) || st.live_thumb.len != thumb_w * thumb_h * 4
		|| st.live_gen != st.file_gen {
		return
	}
	idx := st.frame_idx
	st.thumb_seq++
	st.frames[idx].seq = st.thumb_seq
	st.frames[idx].geom = out_geom(&st.edit)
	st.frames[idx].live = true
	st.frames[idx].thumb = 2
	mut cv := st.frames[idx].cv
	set_thumb_pixels(mut cv, st.live_thumb.clone())
	draw_mark(mut st, idx)
}

// stop_thumbs останавливает воркер миниатюр (смена папки, выход);
// дождаться - wait_thumbs.
fn stop_thumbs(mut st State) {
	if !isnil(st.thumb_stop) {
		mut s := st.thumb_stop
		s.set()
	}
	if !isnil(st.thumb_win_stop) {
		mut s := st.thumb_win_stop
		s.set()
	}
}

fn wait_thumbs(mut st State) {
	stop_thumbs(mut st)
	wait_all(mut st.thumb_threads)
}

// StripCell - ячейка ленты: холст миниатюры, подпись, контейнер и
// замыкание отметок поверх холста
@[heap]
struct StripCell {
mut:
	cv   &vgui.Canvas = unsafe { nil }
	name &vgui.Label  = unsafe { nil }
	cell &vgui.VBox   = unsafe { nil }
}

// strip_cell - ячейка ленты номер idx из запаса st.cells, при нехватке -
// новая. Ячейки переиспользуются при смене папки: у каждой своё замыкание
// on_overlay (рисует отметки кадра idx), а замыкания V не освобождает
// никогда - вместе с захваченным холстом. Новые ячейки на каждую папку
// держали бы все прежние ленты до выхода (~19 МБ на папку из 94 кадров
// плюс текстуры); с запасом память ленты - по самой большой папке.
fn strip_cell(mut st State, idx int) &StripCell {
	if idx < st.cells.len {
		return st.cells[idx]
	}
	mut cv := vgui.canvas(thumb_w, thumb_h)
	clear_thumb(mut cv) // пиксели - когда кадр в видимой части ленты
	// Вписывание с сохранением пропорций (auto_fit): любая высота ленты
	cv.stretch = false
	cv.passive = true // только рисует: щелчок уходит в список
	cv.set_wheel_zoom(false)
	cv.set_pan_buttons(0)
	// Звёзды и флажок - поверх миниатюры, без правки её пикселей
	// (пометка меняется - достаточно перерисовать)
	cv.on_overlay = fn [mut st, idx, cv] (mut ctx vgui.RenderContext) {
		if idx < st.frames.len {
			draw_thumb_marks(mut ctx, cv, st.frames[idx].mark)
		}
	}
	mut name := vgui.label('')
	name.align = .center
	name.font_size = 12
	name.color = st.pal.secondary
	mut cell := vgui.create_vbox_fill()
	cell.set_spacing(4)
	cell.add(cv, flex: 1)
	cell.add(name)
	c := &StripCell{
		cv:   cv
		name: name
		cell: cell
	}
	st.cells << c
	return c
}

// load_folder - новая папка в ленте: список кадров, ячейки с пустыми
// миниатюрами, отметки изменённых и пометки отбора (начало сайдкара,
// read_side_head), строки по фильтру, фоновый расчёт миниатюр. Без
// открытого кадра (cur_path пусто) лента показывается, даже скрытая.
fn load_folder(mut st State, dir string, cur_path string, mut app vgui.App) {
	stop_thumbs(mut st)
	st.thumb_gen++
	st.folder = dir
	paths := scan_folder(dir, strip_depth(st.settings))
	st.frames = []Frame{}
	for p in paths {
		// Ячейка ленты - из запаса (strip_cell): при смене папки не
		// создаётся заново
		sc := strip_cell(mut st, st.frames.len)
		mut cv := sc.cv
		mut name := sc.name
		mut cell := sc.cell
		name.text = os.file_name(p)
		// Кадр из подпапки - её путь в подсказке ячейки
		sub := frame_subdir(dir, p)
		cell.tooltip = if sub != '' { os.join_path(sub, os.file_name(p)) } else { '' }
		name.font_style = .regular
		name.color = st.pal.secondary
		clear_thumb(mut cv)
		// Сайдкары (пометка, правки) читает поток миниатюр - на холодном
		// диске или сетевой папке тысячи открытий файлов заморозили бы
		// окно; открываемый кадр - сразу (фильтр и подпись - по нему)
		head := if p == cur_path { read_side_head(p) } else { SideHead{} }
		st.frames << Frame{
			path:   p
			edited: head.edited
			mark:   head.mark
			head:   p == cur_path
			name:   name
			cv:     cv
			cell:   cell
		}
		draw_mark(mut st, st.frames.len - 1)
	}
	// Ячейки запаса сверх этой папки (была больше) - без пикселей
	for i in st.frames.len .. st.cells.len {
		mut cv := st.cells[i].cv
		clear_thumb(mut cv)
	}
	st.thumb_req = map[int]bool{}
	apply_filter(mut st)
	stop := &StopFlag{}
	st.thumb_stop = stop
	st.thumb_seq++
	wd := &Done{}
	track(mut st.thumb_threads, spawn heads_worker(wd, paths, st.thumb_gen, stop, mut app,
		st.heads_done), wd)
	// Папка без открытого кадра: кадр выбирают в ленте - скрытая целиком
	// (F6) показывается
	if cur_path == '' && paths.len > 0 && !strip_on(st) {
		set_strip_visible(mut st, true)
		strip_thumbs(mut st)
		return
	}
	layout_strip(mut st)
	strip_thumbs(mut st)
}

// take_thumb принимает миниатюру из воркера (главный поток)
fn take_thumb(mut st State, res ThumbResult) {
	if res.gen != st.thumb_gen || res.idx < 0 || res.idx >= st.frames.len
		|| res.seq < st.frames[res.idx].seq {
		return
	}
	if res.kind < 0 {
		st.frames[res.idx].thumb = -1 // не читается - больше не просить
		return
	}
	// JPEG камеры после проявки с правками того же расчёта - мимо
	if res.seq == st.frames[res.idx].seq && res.kind < st.frames[res.idx].thumb {
		return
	}
	st.frames[res.idx].seq = res.seq
	st.frames[res.idx].geom = res.geom
	st.frames[res.idx].live = false
	st.frames[res.idx].thumb = res.kind
	mut cv := st.frames[res.idx].cv
	set_thumb_pixels(mut cv, res.pix)
	draw_mark(mut st, res.idx)
}

// set_thumb_pixels - миниатюра (thumb_w x thumb_h RGBA) в холст ячейки
// (после заглушки размер другой - текстуру холст пересоздаст сам)
fn set_thumb_pixels(mut cv vgui.Canvas, pix []u8) {
	cv.width = thumb_w
	cv.height = thumb_h
	cv.pixels = pix
	cv.mark_dirty()
}

// clear_thumb - холст ячейки без миниатюры: заглушка 3x2 цвета фона (те
// же пропорции - ячейка выглядит, как пустая миниатюра) и без текстуры:
// ~200 КБ пикселей и текстура отдаются
fn clear_thumb(mut cv vgui.Canvas) {
	cv.width = 3
	cv.height = 2
	mut blank := []u8{len: 3 * 2 * 4}
	for i := 0; i < blank.len; i += 4 {
		blank[i] = thumb_bg.r
		blank[i + 1] = thumb_bg.g
		blank[i + 2] = thumb_bg.b
		blank[i + 3] = 255
	}
	cv.pixels = blank
	cv.destroy_texture()
	cv.mark_dirty()
}

// unload_thumb - кадр i ушёл далеко от видимой части ленты: миниатюра
// отдаётся (вернётся - посчитается заново)
fn unload_thumb(mut st State, i int) {
	mut cv := st.frames[i].cv
	if !isnil(cv) {
		clear_thumb(mut cv)
	}
	st.frames[i].thumb = 0
	st.frames[i].live = false
	st.thumb_req.delete(i)
}

// strip_thumbs - миниатюры по видимой части ленты (было - всей папки
// сразу: 2000 кадров - ~400 МБ пикселей и текстур до выхода). Видимые
// строки - по прокрутке и ширине ленты; дальше strip_keep_screens экранов
// миниатюры отдаются (кроме открытого кадра), в пределах
// strip_load_screens недостающие считает воркер - от середины видимой
// части наружу. Зовут: прокрутка вводом (ListBox.on_scroll), center_strip
// (раскладка, смена кадра, фильтр, сплиттеры), пришедшие пометки (кадрам с
// правками - проявка), открытие папки.
fn strip_thumbs(mut st State) {
	if isnil(st.strip) || isnil(st.app) || st.frames.len == 0 {
		return
	}
	strip := st.strip
	n := st.shown.len
	iw := if strip.item_width > 0 { strip.item_width } else { f32(100) }
	vw := strip.bounds.w - 2 * strip.pad
	vis := if vw > 0 { int(vw / iw) + 2 } else { strip_vis_guess }
	mut first := int(strip.scroll_x / iw)
	if first < 0 {
		first = 0
	}
	last := first + vis - 1
	mut rowof := []int{len: st.frames.len, init: -1}
	for r, i in st.shown {
		rowof[i] = r
	}
	keep_lo := first - strip_keep_screens * vis
	keep_hi := last + strip_keep_screens * vis
	for i in 0 .. st.frames.len {
		r := rowof[i]
		if st.frames[i].thumb > 0 && i != st.frame_idx && (r < keep_lo || r > keep_hi) {
			unload_thumb(mut st, i)
		}
	}
	if n == 0 {
		return
	}
	lo := if first - strip_load_screens * vis < 0 { 0 } else { first - strip_load_screens * vis }
	hi := if last + strip_load_screens * vis > n - 1 {
		n - 1
	} else {
		last + strip_load_screens * vis
	}
	if lo > hi {
		return
	}
	mid := (first + (if last < n - 1 { last } else { n - 1 })) / 2
	mut items := []ThumbItem{}
	mut covered := true
	for k in thumb_order(hi - lo + 1, mid - lo) {
		i := st.shown[lo + k]
		f := st.frames[i]
		camera := f.thumb == 0
		tone := f.edited && f.thumb >= 0 && f.thumb < 2 && i != st.frame_idx && !f.live
		if !camera && !tone {
			continue
		}
		items << ThumbItem{
			idx:    i
			path:   f.path
			camera: camera
			tone:   tone
		}
		if !st.thumb_req[i] {
			covered = false
		}
	}
	// Всё нужное уже заказано идущему воркеру - не перезапускать
	if items.len == 0 || covered {
		return
	}
	if !isnil(st.thumb_win_stop) {
		mut s := st.thumb_win_stop
		s.set()
	}
	stop := &StopFlag{}
	st.thumb_win_stop = stop
	st.thumb_req = map[int]bool{}
	for it in items {
		st.thumb_req[it.idx] = true
	}
	mut app := st.app
	wd := &Done{}
	track(mut st.thumb_threads, spawn thumb_worker(wd, items, st.lens_db, st.thumb_gen,
		st.thumb_seq, stop, mut app, st.thumb_done), wd)
}

// take_heads - пометки и правки кадров папки из фона (главный поток):
// кадры, которые уже тронули (head), не трогаются - у них свежее
fn take_heads(mut st State, res HeadsResult) {
	if res.gen != st.thumb_gen || res.heads.len != st.frames.len {
		return
	}
	mut marks := false
	for i, h in res.heads {
		if st.frames[i].head {
			continue
		}
		st.frames[i].head = true
		if h.mark != st.frames[i].mark {
			st.frames[i].mark = h.mark
			marks = true
		}
		if h.edited {
			st.frames[i].edited = true
			draw_mark(mut st, i)
		}
	}
	if marks {
		apply_filter(mut st)
		layout_strip(mut st)
	}
	strip_thumbs(mut st) // кадрам с правками - проявка
}

// ensure_head - пометка и правки кадра i, если их ещё не принёс фон:
// кадр открывают, помечают или правят раньше - читается его сайдкар
fn ensure_head(mut st State, i int) {
	if i < 0 || i >= st.frames.len || st.frames[i].head {
		return
	}
	h := read_side_head(st.frames[i].path)
	st.frames[i].head = true
	st.frames[i].mark = h.mark
	if h.edited && !st.frames[i].edited {
		st.frames[i].edited = true
		draw_mark(mut st, i)
	}
}

// refresh_thumb - миниатюра кадра idx заново с геометрией g (после
// кадрирования или поворота): одна в фоне, ~25 мс
fn refresh_thumb(mut st State, idx int, g pipeline.Geom) {
	if idx < 0 || idx >= st.frames.len || isnil(st.app) {
		return
	}
	st.thumb_seq++
	st.frames[idx].geom = g
	st.frames[idx].seq = st.thumb_seq
	mut app := st.app
	wd := &Done{}
	track(mut st.thumb_threads, spawn thumb_one(wd, st.frames[idx].path, g, st.lens_db, st.thumb_stop,
		st.thumb_gen, st.thumb_seq, idx, mut app, st.thumb_done), wd)
}

// sync_thumb - миниатюра открытого кадра после записи сайдкара (правка,
// откат, вставка настроек): с правками - его превью (push_live_thumb; в
// кадрировании превью без обрезки - миниатюра ждёт выхода из режима), без
// правок (откат к открытию) - снова JPEG камеры под его геометрию
fn sync_thumb(mut st State) {
	if !open_frame_ok(st) {
		return
	}
	if st.hist_pos > 0 {
		if !st.crop_mode {
			push_live_thumb(mut st)
		}
		return
	}
	g := out_geom(&st.edit)
	if g != st.frames[st.frame_idx].geom || st.frames[st.frame_idx].live {
		st.frames[st.frame_idx].live = false
		refresh_thumb(mut st, st.frame_idx, g)
	}
}

// draw_mark - отметка «изменён» (кружок в правом верхнем углу) поверх
// миниатюры, если кадр изменён; холст перерисовывается в любом случае
fn draw_mark(mut st State, idx int) {
	f := st.frames[idx]
	if isnil(f.cv) {
		return
	}
	mut cv := f.cv
	// Заглушка (кадр далеко от видимой части) - отметку нарисует take_thumb
	if f.edited && cv.pixels.len == thumb_w * thumb_h * 4 {
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

// mark_edited - у текущего кадра появились правки (запись сайдкара не
// на «Открыт файл»; одна пометка отбора правкой не считается)
fn mark_edited(mut st State) {
	ensure_head(mut st, st.frame_idx)
	if st.hist_pos == 0 || st.frame_idx < 0 || st.frame_idx >= st.frames.len
		|| st.frames[st.frame_idx].edited {
		return
	}
	st.frames[st.frame_idx].edited = true
	draw_mark(mut st, st.frame_idx)
}

// show_frame - после открытия файла: папка в ленте (новая - загрузить),
// выделение и прокрутка к кадру, счётчик «N из M». Кадр уже в ленте (в
// том числе из подпапки) - лента остаётся прежней.
fn show_frame(mut st State, path string, mut app vgui.App) {
	if isnil(st.strip) {
		return
	}
	dir := os.dir(path)
	if dir != st.folder && !st.frames.any(it.path == path) {
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

// refresh_folder - лента заново из папки (F5, кнопка на полосе): кадры,
// добавленные в папку или убранные из неё за время работы. Открытый кадр
// остаётся открытым (пропал с диска - просто без строки в ленте),
// выделенные кадры - выделенными, фильтр - прежний.
fn refresh_folder(mut st State) {
	if st.folder == '' || isnil(st.strip) || isnil(st.app) {
		return
	}
	sel := strip_selection(st).map(st.frames[it].path)
	mut app := st.app
	load_folder(mut st, st.folder, st.raw_path, mut app)
	st.frame_idx = -1
	for i, f in st.frames {
		if st.raw_path != '' && f.path == st.raw_path {
			st.frame_idx = i
			break
		}
	}
	sync_strip(mut st)
	if sel.len < 2 {
		return
	}
	// Несколько выделенных - снова те же (что остались и проходят
	// фильтр); открытый кадр - последним, чтобы остался текущим
	mut rows := []int{}
	for i, f in st.frames {
		r := row_of(st, i)
		if r >= 0 && f.path in sel && i != st.frame_idx {
			rows << r
		}
	}
	cur := row_of(st, st.frame_idx)
	if cur >= 0 && st.raw_path in sel {
		rows << cur
	}
	if rows.len > 1 {
		mut strip := st.strip
		strip.set_selection(rows)
		strip_info_text(mut st)
		sync_avail(mut st)
	}
}

// reveal_paths - что показать в файловом менеджере («Файл - Показать в
// папке»): кадр под курсором выделения ленты (без выделения - открытый) и
// остальные выделенные из той же папки - менеджер открывает одну папку
fn reveal_paths(st &State) []string {
	sel := strip_selection(st)
	mut head := -1
	if !isnil(st.strip) {
		f := frame_of_row(st, st.strip.selected)
		if f >= 0 && f in sel {
			head = f
		}
	}
	if head < 0 {
		head = if sel.len > 0 { sel.last() } else { st.frame_idx }
	}
	if head < 0 || head >= st.frames.len {
		// Кадр открыт, но не в ленте (пропал из папки) - сам файл
		return if st.raw_path != '' { [st.raw_path] } else { []string{} }
	}
	dir := os.dir(st.frames[head].path)
	mut out := [st.frames[head].path]
	for i in sel {
		p := st.frames[i].path
		if i != head && os.dir(p) == dir {
			out << p
		}
	}
	return out
}

// set_strip_subdirs - кадры подпапок в ленте (вкл/выкл) и их глубина
// (окно «Настройки»): запомнить и перечитать ленту
fn set_strip_subdirs(mut st State, on bool, depth int) {
	d := subdir_depth(depth)
	if on == st.settings.strip_subdirs && d == subdir_depth(st.settings.subdir_depth) {
		return
	}
	st.settings.strip_subdirs = on
	st.settings.subdir_depth = d
	save_settings(st.settings)
	refresh_folder(mut st)
	// Открытый кадр был из подпапки, а она в ленту больше не входит -
	// лента его папки
	if st.frame_idx < 0 && st.raw_path != '' && os.exists(st.raw_path) && !isnil(st.app) {
		mut app := st.app
		show_frame(mut st, st.raw_path, mut app)
	}
	sync_settings_ui(mut st)
}

// sync_strip - выделение ленты на текущем кадре, жирная подпись у него,
// прокрутка - текущий по центру, подпись над лентой.
fn sync_strip(mut st State) {
	if isnil(st.strip) {
		return
	}
	ensure_head(mut st, st.frame_idx) // подпись и отбор - по сайдкару
	mut strip := st.strip
	strip.set_selected(row_of(st, st.frame_idx)) // не прошёл фильтр - без выделения
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
	sync_avail(mut st)
}

// strip_info_text - подпись над лентой: папка, «N из M», при выделении
// нескольких кадров (Ctrl/Shift+щелчок) - «выделено K»
fn strip_info_text(mut st State) {
	if isnil(st.strip_info) || isnil(st.strip) {
		return
	}
	mut info := st.strip_info
	// С фильтром - номер и число кадров фильтра, всего в папке - в скобках
	row := row_of(st, st.frame_idx)
	total := if st.filter != 'all' { i18n.trf(' (в папке {0})', '${st.frames.len}') } else { '' }
	pos := if row >= 0 {
		i18n.trf('{0} из {1}{2}', '${row + 1}', '${st.shown.len}', '${total}')
	} else {
		'${st.shown.len} ${i18n.pl(st.shown.len, 'кадр|кадра|кадров')}${total}'
	}
	mut text := os.file_name(st.folder)
	// Открытый кадр из подпапки - и она (папка/подпапка)
	if st.frame_idx >= 0 && st.frame_idx < st.frames.len {
		sub := frame_subdir(st.folder, st.frames[st.frame_idx].path)
		if sub != '' {
			text = os.join_path(text, sub)
		}
	}
	text += '  ·  ${pos}'
	if st.frame_idx >= 0 && st.frame_idx < st.frames.len {
		mt := mark_text(st.frames[st.frame_idx].mark)
		if mt.len > 0 {
			text += '  ·  ${mt}'
		}
	}
	n := st.strip.get_selection().len
	if n > 1 {
		text += i18n.trf('  ·  выделено {0}', '${n}')
	}
	info.text = text
	// Звёзды над лентой - оценка открытого кадра (set_value - без колбэка)
	if !isnil(st.strip_rating) {
		mut r := st.strip_rating
		r.set_value(if st.frame_idx >= 0 && st.frame_idx < st.frames.len {
			st.frames[st.frame_idx].mark.rating
		} else {
			0
		})
	}
}

// select_all_frames - выделить все кадры ленты (Ctrl+A); текущим
// остаётся открытый кадр - лента не прокручивается к последнему.
// set_selection не зовёт on_select - подпись здесь.
fn select_all_frames(mut st State) {
	if isnil(st.strip) || st.shown.len == 0 {
		return
	}
	// Строки ленты (с фильтром - только его кадры)
	mut idx := []int{len: st.shown.len, init: index}
	cur := row_of(st, st.frame_idx)
	if cur >= 0 {
		// Текущей становится последняя из списка - открытый кадр в конец
		idx.delete(cur)
		idx << cur
	}
	mut strip := st.strip
	strip.set_selection(idx)
	strip_info_text(mut st)
	sync_avail(mut st)
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
		pane = (sp.bounds.h - sp.bar_size) * strip_share(st)
	}
	mut strip := st.strip
	strip.item_width = strip_item_width(pane)
	// Щелчок колеса - один кадр
	strip.scroll_x_speed = strip.item_width
	center_strip(mut st)
}

// center_strip прокручивает ленту так, чтобы редактируемый кадр был по
// центру (у краёв - сколько позволяет лента: лишнее обрежет arrange
// ListBox). Ширина видимой части - по раскладке: сразу после
// перетаскивания горизонтального сплиттера bounds ленты ещё старые,
// поэтому она считается от доли сплиттера «просмотр | панель».
fn center_strip(mut st State) {
	// Ширина, прокрутка или строки ленты могли измениться - миниатюры по
	// видимой части (и когда кадра в ленте нет - фильтр, папка без него)
	defer {
		strip_thumbs(mut st)
	}
	row := row_of(st, st.frame_idx)
	if isnil(st.strip) || row < 0 {
		return
	}
	mut strip := st.strip
	mut view_w := strip.bounds.w - 2 * strip.pad
	if !isnil(st.hsplit) && st.hsplit.bounds.w > 0 {
		sp := st.hsplit
		// Ширина просмотра минус поля панели ленты; без панели сплиттер
		// не в окне, но его ширина - прежняя ширина рабочей области
		bar := if panel_on(st) { sp.bar_size } else { f32(0) }
		view_w = (sp.bounds.w - bar) * viewer_share(st) - 2 * strip_box_pad - 2 * strip.pad
	}
	if view_w <= 0 {
		return
	}
	iw := strip.item_width
	mut x := f32(row) * iw + iw / 2 - view_w / 2
	if x < 0 {
		x = 0
	}
	strip.scroll_x = x
}

// layout_strip собирает область просмотра: без папки или с лентой,
// скрытой целиком (strip_on), - только область снимка
// (view_area); лента открыта - вертикальный сплиттер «снимок |
// полоса + лента» (лента сверху - наоборот, settings.strip_top); скрыта - снимок и под ним панель с одной полосой
// («Развернуть ленту»). Пересборка через clear + add: VBox.remove в vgui
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
	if !isnil(st.m_strip) {
		mut m := st.m_strip
		m.checked = strip_on(st)
	}
	// Без папки или лента скрыта целиком (F6; в полноэкранном режиме -
	// своя видимость, strip_on) - только снимок
	if st.frames.len == 0 || !strip_on(st) {
		v.add(st.view_area, flex: 1)
		return
	}
	sb.add(st.strip_bar)
	top := st.settings.strip_top
	if st.strip_open {
		sb.add(st.strip, flex: 1)
		strip_min := strip_bar_h + 80 + 2 * strip_box_pad
		if top {
			sp.min_first = strip_min
			sp.min_second = view_min_h
			sp.set_first(sb)
			sp.set_second(st.view_area)
		} else {
			sp.min_first = view_min_h
			sp.min_second = strip_min
			sp.set_first(st.view_area)
			sp.set_second(sb)
		}
		v.add(sp, flex: 1)
		fit_strip_items(mut st)
	} else if top {
		v.add(sb)
		v.add(st.view_area, flex: 1)
	} else {
		v.add(st.view_area, flex: 1)
		v.add(sb)
	}
	if !isnil(st.strip_toggle) {
		// Значок - панель со стрелкой к краю окна (свернуть) или от него
		mut b := st.strip_toggle
		side := if top { 'top' } else { 'bottom' }
		b.icon_name = 'panel-${side}-' + if st.strip_open { 'close' } else { 'open' }
		b.tooltip = if st.strip_open { i18n.tr('Свернуть ленту') } else { i18n.tr('Развернуть ленту') }
	}
}

// set_strip_open - свернуть ленту до полосы и развернуть (кнопка на
// полосе), выбор запоминается в настройках; скрыть целиком -
// set_strip_visible (panel.v)
fn set_strip_open(mut st State, open bool) {
	st.strip_open = open
	st.settings.strip_open = open
	save_settings(st.settings)
	layout_strip(mut st)
}
