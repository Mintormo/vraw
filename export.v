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
import time
import raw
import lens
import pipeline
import ai
import bigbuf
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

// Image - проявленный 8-битный RGB-кадр и метаданные RAW (для EXIF)
// Image - готовый кадр экспорта; rgb бывает вне сборщика (bigbuf) -
// после записи освобождать free()
struct Image {
	width  int
	height int
mut:
	rgb  []u8 // width * height * 3
	meta raw.Meta
}

fn (mut im Image) free() {
	bigbuf.free(mut im.rgb)
}

// exif_time - дата для EXIF: «ГГГГ:ММ:ДД чч:мм:сс»
fn exif_time(t time.Time) string {
	return t.custom_format('YYYY:MM:DD HH:mm:ss')
}

// export_exif - EXIF готового файла по метаданным RAW. Модель - полная,
// как пишет сама камера («Canon EOS R8»: LibRaw отдаёт «EOS R8»); дата
// съёмки - часы камеры (LibRaw переводит EXIF mktime'ом, см. raw.Meta),
// дата записи - сейчас.
fn export_exif(m raw.Meta, copyright string) imgio.Exif {
	model := if m.cam_make.len > 0 && !m.cam_model.starts_with(m.cam_make) {
		'${m.cam_make} ${m.cam_model}'
	} else {
		m.cam_model
	}
	return imgio.Exif{
		make:      m.cam_make
		model:     model
		lens_make: m.lens_make
		lens:      m.lens
		date:      if m.shot > 0 { exif_time(time.unix(m.shot).local()) } else { '' }
		modified:  exif_time(time.now())
		exposure:  m.shutter
		fnumber:   m.aperture
		focal:     m.focal
		iso:       int(m.iso + 0.5)
		artist:    m.artist
		copyright: copyright
	}
}

// write_image - кадр в файл; EXIF - если включён и формат его держит
fn write_image(path string, f imgio.Format, img Image, quality int, s &Settings) ! {
	if !s.export_no_exif && f.has_exif() {
		e := export_exif(img.meta, s.exif_copyright)
		imgio.write(path, f, img.width, img.height, img.rgb, quality: quality, exif: &e)!
		return
	}
	imgio.write(path, f, img.width, img.height, img.rgb, quality: quality)!
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

// StageProgress - прогресс экспорта: stage(этап, done, total) зовётся в
// начале каждого этапа (0, 0) и после каждой плитки AI; false - отмена.
// Интерфейс, а не замыкание (post.v: замыкания V держат чужие буферы).
interface StageProgress {
mut:
	stage(s ExportStage, done int, total int) bool
}

// NoStage - прогресс не нужен
struct NoStage {}

fn (mut n NoStage) stage(_ ExportStage, _ int, _ int) bool {
	return true
}

// AiStage - прогресс AI-шумодава как этап .ai прогресса экспорта
struct AiStage {
mut:
	p StageProgress
}

fn (mut a AiStage) step(done int, total int) bool {
	return a.p.stage(.ai, done, total)
}

// ExportOpts - модель AI-шумодава (общая, грузится один раз) и прогресс
// (StageProgress; none - без прогресса); false из него - отмена,
// develop_full вернёт ExportCancelled. Без модели кадр с включённым AI не
// проявляется - ошибка, а не молча другой результат.
@[params]
struct ExportOpts {
	ai_cache &ai.Cache = unsafe { nil }
	progress ?StageProgress
	size     ExportSize // размер на выход (окно «Экспорт»); пусто - как есть
}

// develop_full - проявка RAW-файла по настройкам кадра e в 8-битный RGB
// полного размера. e - с производными полями (камерная кривая и таблицы
// кривых в params, как у живого st.edit); db - база lensfun (nil - без
// коррекции объектива). Свой LibRaw (открывает и закрывает файл сам) -
// годится для фонового потока. AI-шумодав (e.ai > 0) - модель по всему
// кадру, ~2.5 мин на 24 Мп. Отмена проверяется между этапами и между
// плитками AI.
fn develop_full(path string, e EditState, db &lens.Database, o ExportOpts) !Image {
	mut progress := o.progress or { StageProgress(NoStage{}) }
	if !progress.stage(.decode, 0, 0) {
		return ExportCancelled{}
	}
	mut d := raw.open(path)!
	mut img := d.develop(highlight: e.highlight) or {
		d.close()
		return err
	}
	// LibRaw больше не нужен: его внутренние буферы (сырьё и 4-канальный
	// кадр, ~240 МБ на 24 Мп) - отпустить сразу, не держать весь экспорт.
	// Готовое изображение img - отдельный блок, живёт до img.free()
	meta := d.meta()
	d.close()
	// Промежуточные результаты - вне сборщика (bigbuf) и освобождаются, как
	// только не нужны (пик памяти); defer - страховка ранних выходов
	// (отмена, ошибка): повторный free безвреден
	mut den := []u16{}
	mut mask0 := []u16{}
	mut dc := []u16{}
	mut glin := []u16{}
	mut gmask := []u16{}
	mut haze := pipeline.HazeMap{}
	defer {
		img.free()
		bigbuf.free(mut den)
		bigbuf.free(mut mask0)
		bigbuf.free(mut dc)
		bigbuf.free(mut glin)
		bigbuf.free(mut gmask)
		haze.free()
	}
	w := img.width
	h := img.height
	buf := img.data_u16()
	if e.lens_corr {
		if !progress.stage(.lens, 0, 0) {
			return ExportCancelled{}
		}
		correct_lens(buf, w, h, meta, db, e.vign)
	}
	// AI - как в превью: по сырью после объектива, до импульсов и вейвлета
	if e.ai > 0 {
		if isnil(o.ai_cache) {
			return error('AI-шумодав недоступен')
		}
		if !progress.stage(.ai, 0, 0) {
			return ExportCancelled{}
		}
		mut cache := unsafe { o.ai_cache }
		model := cache.get()!
		mut ap := AiStage{
			p: progress
		}
		den = bigbuf.new_u16(w * h * 3)
		ai.denoise_into(model, buf, w, h, mut den, mut ap) or {
			if err is ai.Cancelled {
				return ExportCancelled{}
			}
			return err
		}
		ai.blend(buf, den, e.ai / 100)
		bigbuf.free(mut den)
	}
	if e.nr[0] > 0 {
		if !progress.stage(.impulse, 0, 0) {
			return ExportCancelled{}
		}
		pipeline.impulse(buf, w, h, e.nr[0])
	}
	if e.nr[1] > 0 || e.nr[2] > 0 {
		if !progress.stage(.denoise, 0, 0) {
			return ExportCancelled{}
		}
		pipeline.denoise(buf, w, h, e.nr[1], e.nr[2])
	}
	if e.nr[3] > 0 {
		if !progress.stage(.defringe, 0, 0) {
			return ExportCancelled{}
		}
		pipeline.defringe(buf, w, h, e.nr[3])
	}
	// Маска «Тени/Света» - как в превью: по сырью после шумодава, до
	// Capture-резкости
	mask0 = bigbuf.new_u16(w * h)
	pipeline.blur_luma_into(buf, w, h, mut mask0)
	mut src := unsafe { &u16(buf) }
	if e.params.sharp.dc_amount > 0 {
		if !progress.stage(.capture, 0, 0) {
			return ExportCancelled{}
		}
		dc = bigbuf.new_u16(w * h * 3)
		pipeline.deconvolve_into(buf, w, h, e.params.sharp, 1.0, mut dc)
		src = unsafe { &u16(dc.data) }
		img.free() // сырьё дальше не нужно
	}
	if !progress.stage(.tone, 0, 0) {
		return ExportCancelled{}
	}
	// Кадрирование и поворот - как в превью: после подготовки сырья, сырьё
	// и маска «Тени/Света» одной геометрией
	mut gw := w
	mut gh := h
	mut mask := unsafe { &u16(mask0.data) }
	if !e.geom.is_identity() {
		g := out_geom(&e)
		ow, oh := g.out_size(w, h, true)
		glin = bigbuf.new_u16(ow * oh * 3)
		gw, gh = pipeline.geom_apply_into(src, w, h, 3, g, true, mut glin)
		src = unsafe { &u16(glin.data) }
		bigbuf.free(mut dc)
		img.free()
		gmask = bigbuf.new_u16(ow * oh)
		pipeline.geom_apply_into(unsafe { &u16(mask0.data) }, w, h, 1, g, true, mut gmask)
		mask = unsafe { &u16(gmask.data) }
		bigbuf.free(mut mask0)
	}
	// Карта дымки - по кадру после кадрирования (рабочая копия та же
	// ~1024 px, что у превью, - карты совпадают)
	if e.params.haze != 0 {
		haze = pipeline.haze_map_big(src, gw, gh)
	}
	mut rgb := bigbuf.new_u8(gw * gh * 3)
	pipeline.apply_image(src, mask, &haze, gw, gh, e.params, 1.0, mut rgb, 3)
	// Размер на выход (окно «Экспорт»): только уменьшение, с резкостью на
	// выход (она - только при уменьшении)
	fw, fh := export_dims(o.size, gw, gh)
	if fw != gw || fh != gh {
		small := pipeline.resize_rgb_sharp(rgb, gw, gh, fw, fh, o.size.sharp)
		bigbuf.free(mut rgb)
		return Image{
			width:  fw
			height: fh
			rgb:    small
			meta:   meta
		}
	}
	return Image{
		width:  fw
		height: fh
		rgb:    rgb
		meta:   meta
	}
}
