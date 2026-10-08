module main

// Фоновое открытие кадра: окно не замирает при выборе снимка в ленте.
//
// Главный поток (open_file) делает только быстрое: raw.open (~1-6 мс),
// настройки и история из сайдкара, выделение в ленте - и запускает
// load_worker; на месте снимка - оверлей «Обработка» с вращающимся
// кольцом (loading.v). Встроенный JPEG камеры при открытии не показывается: он
// обработан иначе, и смена картинки на проявку RAW бросалась в глаза; его
// можно посмотреть отдельно («Вид - JPEG камеры», camjpeg.v). Воркер
// (кадр 24 Мп, -prod, всего ~0.75 с):
//   профиль объектива (в общей базе lensfun), проявка превью LibRaw
//   (~160 мс), полный JPEG камеры (~160 мс), сила виньетирования и кадр
//   «как у камеры» по нему (~70 мс), коррекция объектива и маска
//   (prep_compute без шумодава, ~265 мс), камерная кривая и цвет по тому
//   же JPEG (~80 мс) и JPEG для показа -> on_done.
// Шумодав из сайдкара досчитывает обычный фоновый request_prep уже после
// загрузки. Быстрое перелистывание: предыдущая загрузка отменяется
// флагом между этапами, её результат отбрасывается по file_gen (dev и
// corr освобождает главный поток - они принадлежат результату).
//
// Воркер владеет своим Developer (не делит его с GUI), пока не отдаст;
// профиль объектива ищется в общей базе st.lens_db (только чтение): во время загрузки st.dev = nil, st.dev_linear пуст - ползунки
// пишут настройки и историю, а пересчёты (проявка, подготовка, apply)
// сразу выходят. load_done сверяет итог с настройками на момент
// окончания и досчитывает разницу (как restore_edit).
import math
import vgui
import raw
import lens
import pipeline
import i18n

struct LoadJob {
	gen       int
	dev       &raw.Developer = unsafe { nil }
	db        &lens.Database = unsafe { nil } // общая база lensfun (nil - без коррекции)
	lens_corr bool
	man       lens.Manual // ручная коррекция объектива
	stop &StopFlag = unsafe { nil }
}


// LoadResult - итог загрузки. dev всегда внутри (даже при ошибке или
// отмене): закрывает или забирает его главный поток.
struct LoadResult {
mut:
	gen        int
	err        string // не пусто - кадр не проявился
	dev        &raw.Developer  = unsafe { nil }
	corr       &lens.Corrector = unsafe { nil }
	meta       raw.Meta
	lens_corr  bool
	man        lens.Manual // с какой ручной коррекцией raw_linear
	w          int
	h          int
	dev_linear []u16
	raw_linear []u16
	linear     []u16
	mask       []u16
	look       CamLook // камерная кривая, насыщенность и виньетка; кривая пуста - JPEG нет
	// JPEG камеры для показа («Вид - JPEG камеры»): RGBA w x h в
	// ориентации кадра, как превью до геометрии; пусто - JPEG нет
	cam_view []u8
	// Из кэша кадров (framecache.v): что уже сделано с linear и результат
	// модели AI; у обычной загрузки - нули и пусто
	nr_applied [4]f32
	dc_applied [3]f32
	ai_applied f32
	ai_linear  []u16
	ai_model   string
}

// load_worker выполняется в spawn; результат - через app.post
fn load_worker(job LoadJob, mut app vgui.App, on_done fn (LoadResult)) {
	post_load(mut app, on_done, load_compute(job))
}

// load_compute - вся загрузка кадра (в потоке воркера; им же пользуется
// предзагрузка соседа, prefetch.v)
fn load_compute(job LoadJob) LoadResult {
	mut d := job.dev
	meta := d.meta()
	mut res := LoadResult{
		gen:       job.gen
		dev:       d
		meta:      meta
		lens_corr: job.lens_corr
		man:       job.man
	}
	// Профиль объектива, проявка, подготовка, камерная кривая
	res = LoadResult{
		...res
		corr: job.db.find(meta.cam_make, meta.cam_model, meta.lens) or { unsafe { nil } }
	}
	mut img := d.develop(half: true) or {
		res = LoadResult{
			...res
			err: i18n.trf('Ошибка проявки: {0}', '${err.msg()}')
		}
		return res
	}
	w := img.width
	h := img.height
	// Буферы кадра - вне сборщика, с владельцем (bufown.v): ссылка у
	// воркера, с итогом переходит в главный поток
	mut dev_linear := own_new[u16](w * h * 3)
	unsafe { vmemcpy(dev_linear.data, img.data_u16(), w * h * 6) }
	img.free()
	if job.stop.stop {
		drop(mut dev_linear)
		return res
	}
	// Полный JPEG камеры - один раз на силу виньетки и камерную кривую.
	// Сила - по профилю кадра, даже если коррекция выключена: включат -
	// не перепроявлять
	mut cj := cam_jpeg(mut d)
	defer {
		if mut t := cj {
			t.free()
		}
	}
	lm := lens_match(cj, d.flip(), res.corr, dev_linear, w, h, meta)
	vign := lm.vign
	// Задание забирает свою ссылку на dev_linear (prep_compute отпустит)
	mut prep := prep_compute(PrepJob{
		gen:       job.gen
		src:       share(dev_linear)
		w:         w
		h:         h
		redo_lens: true
		corr:      if job.lens_corr { res.corr } else { unsafe { nil } }
		focal:     meta.focal
		aperture:  meta.aperture
		vign:      vign
		zoom:      lm.zoom
		man:       job.man
	})
	if job.stop.stop {
		drop(mut dev_linear)
		drop(mut prep.raw_linear)
		drop(mut prep.linear)
		drop(mut prep.mask)
		return res
	}
	res = LoadResult{
		...res
		w:          w
		h:          h
		dev_linear: dev_linear
		raw_linear: prep.raw_linear
		linear:     prep.linear
		mask:       prep.mask
		look:       CamLook{
			...camera_look(cj, d.flip(), prep.linear, w, h, vign)
			zoom: lm.zoom
		}
		cam_view:   cam_view(cj, d.flip(), w, h)
	}
	return res
}

// cam_view - JPEG камеры для показа: вписан в размер превью w x h в
// ориентации кадра (RGBA, вне сборщика - одна ссылка); без JPEG - пусто
fn cam_view(cj ?raw.Jpeg, flip int, w int, h int) []u8 {
	t := cj or { return []u8{} }
	mut out := own_new[u8](w * h * 4)
	fit_thumb_into(mut out, t.pix, t.width,
		t.height, flip, w, h)
	return out
}

fn post_load(mut app vgui.App, on_done fn (LoadResult), res LoadResult) {
	post_result(mut app, on_done, res)
}

// CamLook - «как JPEG камеры» для кадра: тоновая кривая (match_curve),
// множитель насыщенности (match_saturation) и сила коррекции
// виньетирования (vign_match). Производное, в сайдкар не пишется; кривая
// и насыщенность включаются флажком «как JPEG» (EditState.use_curve),
// сила виньетки - при коррекции объектива.
// Наименьший встроенный JPEG для «как JPEG» (300 x 200): на меньшем
// гистограммы и средние слишком шумные
const cam_look_min_px = 60000

struct CamLook {
	curve []f32 // пусто - встроенного JPEG нет
	sat   f32 = 1
	// Цвет «как JPEG» (pipeline.match_hues): сдвиг оттенка и множитель
	// насыщенности по ячейкам оттенок × яркость × насыщенность; пусто -
	// нет (или подгонка не помогла)
	hue  []f32
	hsat []f32
	vign  f32 = lens.vign_default
	zoom  f32 = 1 // кадр «как у камеры»: увеличение сверх автомасштаба lensfun
}

// cam_jpeg - встроенный полный JPEG камеры, декодированный в RGB (в
// ориентации сенсора, вне сборщика - raw.decode_jpeg; освобождает
// вызывающий - free()). Именно полный:
// у CR3 превью 1620x1080 обработано иначе. Камеры разные (Canon, Nikon,
// Sony...) и стили у них разные - поэтому «как JPEG» всё по встроенному
// JPEG этого же кадра, а не константами; JPEG меньше cam_look_min_px
// пикселей (бывают крошечные превью) - none.
fn cam_jpeg(mut d raw.Developer) ?raw.Jpeg {
	tj := d.thumb() or { return none }
	mut t := raw.decode_jpeg(tj) or { return none }
	if t.width * t.height < cam_look_min_px {
		t.free()
		return none
	}
	return t
}

// camera_look - «как JPEG» кадра: JPEG камеры cj против нейтральной
// проявки превью linear (npix пикселей, после коррекции объектива с силой
// vign): кривая - сопоставлением гистограмм, насыщенность - по средней
// цветности с этой кривой
fn camera_look(cj ?raw.Jpeg, flip int, linear []u16, w int, h int, vign f32) CamLook {
	t := cj or {
		return CamLook{
			vign: vign
		}
	}
	npix := w * h
	src := unsafe { &u16(linear.data) }
	ref_ := unsafe { &u8(t.pix.data) }
	curve := pipeline.match_curve(src, npix, ref_, t.width * t.height)
	sat := pipeline.match_saturation(src, npix, curve, ref_, t.width * t.height)
	hue, hsat := camera_hues(t, flip, linear, w, h, curve, sat)
	return CamLook{
		curve: curve
		sat:   sat
		hue:   hue
		hsat:  hsat
		vign:  vign
	}
}

// camera_hues - цвет «как JPEG» (pipeline.match_hues): рабочая копия
// кадра (длинная сторона lens.match_side) с камерной кривой и
// насыщенностью против JPEG, вписанного в тот же размер. Кадр уже совмещён
// с JPEG (коррекция объектива с увеличением «как у камеры»); JPEG другой
// пропорции - без цвета.
fn camera_hues(t raw.Jpeg, flip int, linear []u16, w int, h int, curve []f32, sat f32) ([]f32, []f32) {
	ow := if flip & 4 != 0 { t.height } else { t.width }
	oh := if flip & 4 != 0 { t.width } else { t.height }
	if math.abs(f64(ow) * h / (f64(oh) * w) - 1) > 0.01 {
		return []f32{}, []f32{}
	}
	sw, sh := lens.match_dims(w, h)
	small := lens.downscale(unsafe { &u16(linear.data) }, w, h, sw, sh)
	mut ours := []u8{len: sw * sh * 4}
	pipeline.apply(unsafe { &u16(small.data) }, unsafe { nil }, sw * sh, pipeline.Params{
		curve:   curve
		cam_sat: sat
		dither:  false
	}, mut ours, 4)
	ref_ := fit_thumb(t.pix, t.width, t.height,
		flip, sw, sh)
	return pipeline.match_hues(unsafe { &u8(ours.data) }, 4, unsafe { &u8(ref_.data) }, 4,
		sw, sh)
}

// LensMatch - коррекция объектива «как у камеры» по JPEG кадра: сила
// виньетирования и увеличение кадра сверх автомасштаба lensfun (камера
// после исправления дисторсии обрезает сильнее)
struct LensMatch {
	vign f32 = lens.vign_default
	zoom f32 = 1
}

// Наибольшее увеличение кадра «как у камеры»: больше - скорее ошибка
// совмещения, чем обрезка камеры (RF 24-50 на 24 мм - 1.085)
const frame_zoom_max = f32(1.2)

// lens_match - коррекция объектива «как JPEG камеры». Сила
// виньетирования: спад яркости к краю после коррекции - как у камеры.
// Рабочая копия кадра после geometry (lens.match_frame), JPEG совмещается
// с ней по масштабу (VignRef), сила - регрессией по точкам (VignRef.fit).
// Увеличение кадра - тот же масштаб совмещения (align_zoom): камерный кадр
// уже нашего (автомасштаб lensfun) на столько же; меньше 1 не бывает
// (иначе пустые углы), совсем мало - 1. src - линейная проявка w x h без
// коррекции объектива, flip - ориентация кадра (JPEG лежит в ориентации
// сенсора). Без профиля, JPEG, при обрезанном под другую пропорцию JPEG
// или без надёжной оценки - LensMatch{} (lens.vign_default, без
// увеличения). Порядок: сначала это, потом камерная кривая (виньетка
// меняет гистограмму).
fn lens_match(cj ?raw.Jpeg, flip int, corr &lens.Corrector, src []u16, w int, h int, m raw.Meta) LensMatch {
	t := cj or { return LensMatch{} }
	if isnil(corr) {
		return LensMatch{}
	}
	ow := if flip & 4 != 0 { t.height } else { t.width }
	oh := if flip & 4 != 0 { t.width } else { t.height }
	// JPEG обрезан под другую пропорцию - точки не совпадут
	if math.abs(f64(ow) * h / (f64(oh) * w) - 1) > 0.01 {
		return LensMatch{}
	}
	mf := corr.match_frame(unsafe { &u16(src.data) }, w, h, m.focal, m.aperture) or {
		return LensMatch{}
	}
	rgba := fit_thumb(t.pix, t.width, t.height,
		flip, mf.w, mf.h)
	vr := VignRef.new(rgba, mf) or { return LensMatch{} }
	z := vr.zoom
	return LensMatch{
		vign: vr.fit(mf) or { lens.vign_default }
		zoom: if z < 1.002 { f32(1) } else if z > frame_zoom_max { frame_zoom_max } else { z }
	}
}

// VignRef - JPEG камеры для vign_match, совмещённый с рабочей копией
// кадра. Камера после исправления дисторсии кадрирует сильнее
// авто-масштаба lensfun (RF 24-50 на 24 мм: JPEG крупнее на 8 %, у края
// кадра - десятки пикселей рабочей копии), поэтому JPEG сначала
// масштабируется к нашему кадру (align_zoom); точки за кадром JPEG (и
// полоса vign_edge у его края) и пересвеченные в JPEG (канал от 250 -
// тоновое плечо и клип камеры) не сравниваются.
struct VignRef {
	ref_ []u8   // RGB, совмещённый с рабочей копией
	use  []bool // точка сравнивается
	zoom f32    // масштаб совмещения (align_zoom): камерный кадр уже нашего в zoom раз
}

// Полоса у края JPEG, которая не сравнивается (fit_thumb может оставить
// там пиксель фона)
const vign_edge = f32(2)

// Точки для регрессии: люма JPEG vign_lo..vign_hi, наш канал не у клипа,
// наша люма не ниже vign_floor (шум и чёрная точка)
const vign_lo = 16
const vign_hi = 235
const vign_clip = 64000
const vign_floor = 64.0
// Минимум точек и разброс ln усиления внутри корзин (СКО): меньше - сцена
// не позволяет отличить виньетку от содержимого (длиннофокусник без спада)
const vign_min_n = 4000
const vign_min_spread = 0.03
// Верхний предел силы: чуть больше полного профиля
const vign_s_max = f32(1.2)

// Предел корреляции совмещения: ниже - JPEG не тот кадр или сильно другой
const vign_min_ncc = 0.6

fn VignRef.new(rgba []u8, mf &lens.MatchFrame) ?VignRef {
	w := mf.w
	h := mf.h
	n := w * h
	// Люма JPEG и наша (гамма; кривая камеры на совмещение почти не влияет)
	mut jl := []f32{len: n}
	mut ol := []f32{len: n}
	ours := mf.with_strength(lens.vign_default)
	for i in 0 .. n {
		jl[i] = 0.2126 * f32(rgba[i * 4]) + 0.7152 * f32(rgba[i * 4 + 1]) + 0.0722 * f32(rgba[i * 4 + 2])
		y := (0.2126 * f32(ours[i * 3]) + 0.7152 * f32(ours[i * 3 + 1]) + 0.0722 * f32(ours[i * 3 + 2])) / 65535.0
		ol[i] = f32(math.pow(f64(y), 1 / 2.2))
	}
	z, ncc := align_zoom(ol, jl, w, h)
	if ncc < vign_min_ncc {
		return none
	}
	mut ref_ := []u8{len: n * 3}
	mut use := []bool{len: n}
	cx := f32(w - 1) / 2
	cy := f32(h - 1) / 2
	for y in 0 .. h {
		for x in 0 .. w {
			// Точка JPEG, в которой то же место сцены
			qx := cx + (f32(x) - cx) * z
			qy := cy + (f32(y) - cy) * z
			if qx < vign_edge || qy < vign_edge || qx > f32(w - 1) - vign_edge
				|| qy > f32(h - 1) - vign_edge {
				continue
			}
			i := y * w + x
			mut clip := false
			for ch in 0 .. 3 {
				v := sample_rgba(rgba, w, h, ch, qx, qy)
				ref_[i * 3 + ch] = u8(v + 0.5)
				clip = clip || v >= 250
			}
			use[i] = !clip
		}
	}
	return VignRef{
		ref_: ref_
		use:  use
		zoom: z
	}
}

// align_zoom - масштаб JPEG относительно нашего кадра (оба w x h, люма):
// точка нашего кадра p - это точка JPEG c + (p - c)·z. Перебор z по
// корреляции люм (грубо, потом точнее); второй результат - корреляция.
fn align_zoom(ours []f32, jpeg []f32, w int, h int) (f32, f64) {
	mut best := f32(1)
	mut best_c := zoom_ncc(ours, jpeg, w, h, 1)
	for i in 0 .. 41 {
		z := f32(0.85) + f32(i) * 0.01
		c := zoom_ncc(ours, jpeg, w, h, z)
		if c > best_c {
			best, best_c = z, c
		}
	}
	z0 := best
	for i in -10 .. 11 {
		z := z0 + f32(i) * 0.001
		c := zoom_ncc(ours, jpeg, w, h, z)
		if c > best_c {
			best, best_c = z, c
		}
	}
	return best, best_c
}

// zoom_ncc - нормированная корреляция нашей люмы и JPEG при масштабе z
// по общей области (каждая вторая точка - для скорости хватает)
fn zoom_ncc(ours []f32, jpeg []f32, w int, h int, z f32) f64 {
	cx := f32(w - 1) / 2
	cy := f32(h - 1) / 2
	mut n := 0.0
	mut sa := 0.0
	mut sb := 0.0
	mut saa := 0.0
	mut sbb := 0.0
	mut sab := 0.0
	for y := 0; y < h; y += 2 {
		qy := cy + (f32(y) - cy) * z
		if qy < 0 || qy > f32(h - 1) {
			continue
		}
		for x := 0; x < w; x += 2 {
			qx := cx + (f32(x) - cx) * z
			if qx < 0 || qx > f32(w - 1) {
				continue
			}
			a := f64(ours[y * w + x])
			b := f64(sample_f32(jpeg, w, h, qx, qy))
			n += 1
			sa += a
			sb += b
			saa += a * a
			sbb += b * b
			sab += a * b
		}
	}
	if n < 100 {
		return -1
	}
	va := saa - sa * sa / n
	vb := sbb - sb * sb / n
	if va <= 0 || vb <= 0 {
		return -1
	}
	return (sab - sa * sb / n) / math.sqrt(va * vb)
}

// sample_f32 - билинейная выборка карты w x h (точка внутри кадра)
fn sample_f32(m []f32, w int, h int, x f32, y f32) f32 {
	x0 := if int(x) < w - 1 { int(x) } else { w - 2 }
	y0 := if int(y) < h - 1 { int(y) } else { h - 2 }
	fx := x - f32(x0)
	fy := y - f32(y0)
	a := m[y0 * w + x0] * (1 - fx) + m[y0 * w + x0 + 1] * fx
	b := m[(y0 + 1) * w + x0] * (1 - fx) + m[(y0 + 1) * w + x0 + 1] * fx
	return a * (1 - fy) + b * fy
}

// sample_rgba - билинейная выборка канала ch из RGBA w x h
fn sample_rgba(m []u8, w int, h int, ch int, x f32, y f32) f32 {
	x0 := if int(x) < w - 1 { int(x) } else { w - 2 }
	y0 := if int(y) < h - 1 { int(y) } else { h - 2 }
	fx := x - f32(x0)
	fy := y - f32(y0)
	p00 := f32(m[(y0 * w + x0) * 4 + ch])
	p10 := f32(m[(y0 * w + x0 + 1) * 4 + ch])
	p01 := f32(m[((y0 + 1) * w + x0) * 4 + ch])
	p11 := f32(m[((y0 + 1) * w + x0 + 1) * 4 + ch])
	return (p00 * (1 - fx) + p10 * fx) * (1 - fy) + (p01 * (1 - fx) + p11 * fx) * fy
}

// fit - сила регрессией по совмещённым точкам, без тоновой кривой: JPEG -
// глобальная монотонная кривая от линейной яркости (со спадом «по-
// камерному»), поэтому точки с одинаковым тоном JPEG имели одинаковую
// линейную яркость, и внутри такой группы (корзина люмы JPEG) наша
// яркость с коррекцией y + s·l постоянна; всё, что меняется с радиусом, -
// недо- или перекоррекция. Регрессия с фиксированными эффектами корзин:
// s = -Σ(y-ȳ)(l-l̄) / Σ(l-l̄)², средние - по корзине; y - ln нашей люмы
// без коррекции, l - ln усиления полного профиля в точке. Содержимое
// сцены сокращается: небо в центре и тень у края не дают ложного спада,
// как дало бы сравнение средних по кольцам. Сравнение с JPEG ПОСЛЕ нашей
// камерной кривой (ровность разницы по кольцам) пробовали - кривая по
// гистограммам скачет от малой смены силы, оценка рваная. none - мало
// точек или разброса усиления (длиннофокусник без спада).
fn (r &VignRef) fit(mf &lens.MatchFrame) ?f32 {
	mut n := []f64{len: 256}
	mut sy := []f64{len: 256}
	mut sl := []f64{len: 256}
	mut syl := []f64{len: 256}
	mut sll := []f64{len: 256}
	for i in 0 .. mf.w * mf.h {
		if !r.use[i] {
			continue
		}
		jl := int(0.2126 * f64(r.ref_[i * 3]) + 0.7152 * f64(r.ref_[i * 3 + 1]) +
			0.0722 * f64(r.ref_[i * 3 + 2]) + 0.5)
		if jl < vign_lo || jl > vign_hi {
			continue
		}
		pr := mf.lin[i * 3]
		pg := mf.lin[i * 3 + 1]
		pb := mf.lin[i * 3 + 2]
		if pr >= vign_clip || pg >= vign_clip || pb >= vign_clip {
			continue
		}
		yl := 0.2126 * f64(pr) + 0.7152 * f64(pg) + 0.0722 * f64(pb)
		if yl < vign_floor {
			continue
		}
		y := math.log(yl)
		l := f64(mf.lgain[i])
		n[jl] += 1
		sy[jl] += y
		sl[jl] += l
		syl[jl] += y * l
		sll[jl] += l * l
	}
	mut tot := 0.0
	mut cyl := 0.0
	mut cll := 0.0
	for k in 0 .. 256 {
		if n[k] < 2 {
			continue
		}
		tot += n[k]
		cyl += syl[k] - sy[k] * sl[k] / n[k]
		cll += sll[k] - sl[k] * sl[k] / n[k]
	}
	if tot < vign_min_n || cll <= 0 || math.sqrt(cll / tot) < vign_min_spread {
		return none
	}
	s := f32(-cyl / cll)
	return if s < 0 {
		f32(0)
	} else if s > vign_s_max {
		vign_s_max
	} else {
		s
	}
}

// free_load - закрыть LibRaw отброшенного результата загрузки (профиль
// объектива - из общей базы, освобождать нечего)
// free_load - итог загрузки не нужен (отменена, ошибка, чужой кадр):
// закрыть LibRaw и отпустить буферы
fn free_load(res LoadResult) {
	if !isnil(res.dev) {
		mut d := res.dev
		d.close()
	}
	mut r := res
	drop(mut r.dev_linear)
	drop(mut r.raw_linear)
	drop(mut r.linear)
	drop(mut r.mask)
	drop(mut r.cam_view)
	drop(mut r.ai_linear)
}

fn wait_loads(mut st State) {
	if !isnil(st.load_stop) {
		mut s := st.load_stop
		s.stop = true
	}
	prefetch_cancel(mut st) // предзагрузка соседа - в тех же потоках
	for t in st.load_threads {
		t.wait()
	}
	st.load_threads.clear()
}

// set_canvas_size - холст под новый размер (приём Canvas.load_from_surface);
// fit - вписать заново (новый кадр другого размера)
fn set_canvas_size(mut cv vgui.Canvas, w int, h int) {
	cv.width = w
	cv.height = h
	cv.pixels = []u8{len: w * h * 4}
	cv.destroy_texture()
	cv.dirty = true
	cv.fit_to_view()
}
