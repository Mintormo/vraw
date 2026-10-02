module main

// Экспорт: проявка RAW-файла в полном размере по настройкам кадра.
// Выполняется в фоновом потоке (save_worker) - поэтому без vgui и без
// общего состояния: свой LibRaw, всё нужное приходит копией в EditState.
//
// Порядок - как в превью: LibRaw (демозаика, камерный ББ, режим
// пересветов) -> коррекция объектива (виньетирование, затем дисторсия +
// TCA) -> AI-шумодав -> импульсы -> шумодав -> ореолы -> Capture-резкость
// -> маска -> кадрирование и поворот (сырьё и маска) -> pipeline -> размер
// «Тени/Света» -> pipeline.apply (тон, кривые, HSL) -> 8 бит.
import raw
import lens
import pipeline
import ai
import imgio

// correct_lens - коррекция объектива на месте (виньетирование с силой vign
// строго до дисторсии: ремап двигает пиксели); false - профиля нет
fn correct_lens(buf &u16, w int, h int, m raw.Meta, db &lens.Database, vign f32) bool {
	if isnil(db) {
		return false
	}
	c := db.find(m.cam_make, m.cam_model, m.lens) or { return false }
	c.vignetting(buf, w, h, m.focal, m.aperture, vign)
	c.geometry(buf, w, h, m.focal)
	return true
}

// Image - проявленный 8-битный RGB-кадр
struct Image {
	width  int
	height int
	rgb    []u8 // width * height * 3
}

// ExportStage - этапы проявки полного кадра, в порядке выполнения.
// Диалог экспорта показывает текущий и общую долю по весам (export_plan).
enum ExportStage {
	decode
	lens
	ai
	impulse
	denoise
	defringe
	capture
	tone
	write // запись файла - в save_worker, после develop_full
}

fn stage_title(s ExportStage) string {
	return match s {
		.decode { 'Демозаика (LibRaw)' }
		.lens { 'Коррекция объектива' }
		.ai { 'AI-шумодав' }
		.impulse { 'Импульсный шум' }
		.denoise { 'Шумодав' }
		.defringe { 'Ореолы' }
		.capture { 'Capture-резкость' }
		.tone { 'Тон и цвет' }
		.write { 'Запись файла' }
	}
}

// StagePlan - этапы экспорта для настроек кадра и их веса (примерные
// секунды на 24 Мп в рабочей сборке, см. замеры в PROJECT.md)
struct StagePlan {
	stages  []ExportStage
	weights []f64
}

// write_secs - примерное время записи кадра 24 Мп (замер, -prod): PNG и
// TIFF - сжатие Deflate, GIF - палитра и дизеринг, BMP и QOI - почти
// ничего
fn write_secs(f imgio.Format) f64 {
	return match f {
		.jpeg { 0.7 }
		.png { 4.1 }
		.tiff { 3.4 }
		.bmp { 0.1 }
		.qoi { 0.35 }
		.gif { 1.4 }
	}
}

// export_plan - какие этапы пройдёт develop_full с настройками e (условия -
// те же, что в нём) и запись файла формата f; ai_secs - оценка AI по
// полному кадру
fn export_plan(e EditState, ai_secs f64, f imgio.Format) StagePlan {
	mut st := [ExportStage.decode]
	mut w := [0.6]
	if e.lens_corr {
		st << .lens
		w << 2.8
	}
	if e.ai > 0 {
		st << .ai
		w << ai_secs
	}
	if e.nr[0] > 0 {
		st << .impulse
		w << 4.0
	}
	if e.nr[1] > 0 || e.nr[2] > 0 {
		st << .denoise
		w << 4.0
	}
	if e.nr[3] > 0 {
		st << .defringe
		w << 2.0
	}
	if e.params.sharp.dc_amount > 0 {
		st << .capture
		w << 2.6
	}
	st << .tone
	w << 1.6
	st << .write
	w << write_secs(f)
	return StagePlan{
		stages:  st
		weights: w
	}
}

// ExportCancelled - экспорт отменён (progress вернул false)
struct ExportCancelled {
	Error
}

fn (e ExportCancelled) msg() string {
	return 'экспорт отменён'
}

// ExportOpts - модель AI-шумодава (общая, грузится один раз) и прогресс:
// progress(этап, done, total) зовётся в начале каждого этапа (0, 0) и
// после каждой плитки AI; false - отмена, develop_full вернёт
// ExportCancelled. Без модели кадр с включённым AI не проявляется -
// ошибка, а не молча другой результат. progress по умолчанию nil (без
// прогресса): анонимная функция значением по умолчанию в @[params]-поле
// ломает C-кодоген V.
@[params]
struct ExportOpts {
	ai_cache &ai.Cache = unsafe { nil }
	progress fn (ExportStage, int, int) bool = unsafe { nil }
	size     ExportSize // размер на выход (окно «Экспорт»); пусто - как есть
}

fn no_progress(_ ExportStage, _ int, _ int) bool {
	return true
}

// develop_full - проявка RAW-файла по настройкам кадра e в 8-битный RGB
// полного размера. e - с производными полями (камерная кривая и таблицы
// кривых в params, как у живого st.edit); db - база lensfun (nil - без
// коррекции объектива). Свой LibRaw (открывает и закрывает файл сам) -
// годится для фонового потока. AI-шумодав (e.ai > 0) - модель по всему
// кадру, ~2.5 мин на 24 Мп. Отмена проверяется между этапами и между
// плитками AI.
fn develop_full(path string, e EditState, db &lens.Database, o ExportOpts) !Image {
	progress := if isnil(o.progress) { no_progress } else { o.progress }
	if !progress(.decode, 0, 0) {
		return ExportCancelled{}
	}
	mut d := raw.open(path)!
	defer {
		d.close()
	}
	mut img := d.develop(highlight: e.highlight)!
	defer {
		img.free()
	}
	w := img.width
	h := img.height
	buf := img.data_u16()
	if e.lens_corr {
		if !progress(.lens, 0, 0) {
			return ExportCancelled{}
		}
		correct_lens(buf, w, h, d.meta(), db, e.vign)
	}
	// AI - как в превью: по сырью после объектива, до импульсов и вейвлета
	if e.ai > 0 {
		if isnil(o.ai_cache) {
			return error('AI-шумодав недоступен')
		}
		if !progress(.ai, 0, 0) {
			return ExportCancelled{}
		}
		mut cache := unsafe { o.ai_cache }
		model := cache.get()!
		den := ai.denoise(model, buf, w, h, fn [progress] (done int, total int) bool {
			return progress(.ai, done, total)
		}) or {
			if err is ai.Cancelled {
				return ExportCancelled{}
			}
			return err
		}
		ai.blend(buf, den, e.ai / 100)
	}
	if e.nr[0] > 0 {
		if !progress(.impulse, 0, 0) {
			return ExportCancelled{}
		}
		pipeline.impulse(buf, w, h, e.nr[0])
	}
	if e.nr[1] > 0 || e.nr[2] > 0 {
		if !progress(.denoise, 0, 0) {
			return ExportCancelled{}
		}
		pipeline.denoise(buf, w, h, e.nr[1], e.nr[2])
	}
	if e.nr[3] > 0 {
		if !progress(.defringe, 0, 0) {
			return ExportCancelled{}
		}
		pipeline.defringe(buf, w, h, e.nr[3])
	}
	// Capture-резкость - как в превью: после шумодава; маска «Тени/Света» -
	// по сырью до неё
	mut dc := []u16{}
	if e.params.sharp.dc_amount > 0 {
		if !progress(.capture, 0, 0) {
			return ExportCancelled{}
		}
		dc = pipeline.deconvolve(buf, w, h, e.params.sharp, 1.0)
	}
	if !progress(.tone, 0, 0) {
		return ExportCancelled{}
	}
	mask0 := pipeline.blur_luma(buf, w, h)
	mut src := if dc.len > 0 { unsafe { &u16(dc.data) } } else { buf }
	// Кадрирование и поворот - как в превью: после подготовки сырья, сырьё
	// и маска «Тени/Света» одной геометрией
	mut gw := w
	mut gh := h
	mut glin := []u16{}
	mask := if e.geom.is_identity() {
		mask0
	} else {
		m, _, _ := pipeline.geom_apply(unsafe { &u16(mask0.data) }, w, h, 1, out_geom(&e), true)
		m
	}
	if !e.geom.is_identity() {
		glin, gw, gh = pipeline.geom_apply(src, w, h, 3, out_geom(&e), true)
		src = unsafe { &u16(glin.data) }
	}
	// Карта дымки - по кадру после кадрирования (рабочая копия та же
	// ~1024 px, что у превью, - карты совпадают)
	haze := if e.params.haze != 0 { pipeline.haze_map(src, gw, gh) } else { pipeline.HazeMap{} }
	mut rgb := []u8{len: gw * gh * 3}
	pipeline.apply_image(src, unsafe { &u16(mask.data) }, &haze, gw, gh, e.params, 1.0, mut
		rgb, 3)
	// Размер на выход (окно «Экспорт»): только уменьшение
	fw, fh := export_dims(o.size, gw, gh)
	if fw != gw || fh != gh {
		rgb = pipeline.resize_rgb(rgb, gw, gh, fw, fh)
	}
	return Image{
		width:  fw
		height: fh
		rgb:    rgb
	}
}
