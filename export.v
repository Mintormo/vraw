module main

// Экспорт: проявка RAW-файла в полном размере по настройкам кадра.
// Выполняется в фоновом потоке (save_worker) - поэтому без vgui и без
// общего состояния: свой LibRaw, всё нужное приходит копией в EditState.
//
// Порядок - как в превью: LibRaw (демозаика, камерный ББ, клип
// пересветов) -> коррекция объектива (виньетирование, затем дисторсия +
// TCA) -> импульсы -> шумодав -> ореолы -> Capture-резкость
// -> маска -> кадрирование и поворот (сырьё и маска) -> pipeline -> размер
// «Тени/Света» -> pipeline.apply (тон, кривые, HSL) -> 8 бит (TIFF и PNG
// - по умолчанию 16, ExportOpts.bits16).
import time
import raw
import lens
import pipeline
import bigbuf
import imgio
import i18n

// lens_full - коррекция объектива всего кадра на месте: профиль c (nil -
// без него; виньетирование с силой vign, кадр увеличен в zoom раз - «как
// у камеры») и ручная man (lens/manual.v). Виньетирование (профиля, затем
// ручное) - строго до ремапов, по геометрии сенсора; ремап профиля, затем
// ручной - доводка уже исправленного кадра. Тот же порядок - у фрагмента
// 1:1 (lens_piece, detail.v)
fn lens_full(buf &u16, w int, h int, c &lens.Corrector, focal f32, aperture f32, vign f32, zoom f32, man lens.Manual) {
	if !isnil(c) {
		c.vignetting(buf, w, h, focal, aperture, vign)
	}
	lens.manual_vignetting(buf, w, h, man)
	if !isnil(c) {
		c.geometry_zoom(buf, w, h, focal, zoom)
	}
	lens.manual_geometry(buf, w, h, man)
}

// correct_lens - коррекция объектива на месте по профилю из базы db
// (если есть, use_prof) и ручная man (lens_full)
fn correct_lens(buf &u16, w int, h int, m raw.Meta, db &lens.Database, use_prof bool, vign f32, zoom f32, man lens.Manual) {
	mut c := unsafe { &lens.Corrector(nil) }
	if use_prof && !isnil(db) {
		c = db.find(m.cam_make, m.cam_model, m.lens) or { unsafe { nil } }
	}
	lens_full(buf, w, h, c, m.focal, m.aperture, vign, zoom, man)
}

// Image - готовый кадр экспорта (RGB) и метаданные RAW (для EXIF); rgb
// бывает вне сборщика (bigbuf) - после записи освобождать free()
struct Image {
	width  int
	height int
	bits16 bool // rgb - u16 на канал (pipeline.stride16)
mut:
	rgb  []u8 // width * height * 3 байт (bits16 - * 6)
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

// write_image - кадр в файл; EXIF - если включён и формат его держит;
// ICC-профиль sRGB - всегда, где формат его держит (те же JPEG, PNG,
// TIFF): это не личные данные, а описание цвета кадра
fn write_image(path string, f imgio.Format, img Image, quality int, s &Settings) ! {
	icc := if f.has_exif() { imgio.srgb_icc() } else { []u8{} }
	if !s.export_no_exif && f.has_exif() {
		e := export_exif(img.meta, s.exif_copyright)
		imgio.write(path, f, img.width, img.height, img.rgb,
			quality: quality
			exif:    &e
			icc:     icc
			bits16:  img.bits16
		)!
		return
	}
	imgio.write(path, f, img.width, img.height, img.rgb,
		quality: quality
		icc:     icc
		bits16:  img.bits16
	)!
}

// ExportStage - этапы проявки полного кадра, в порядке выполнения.
// Диалог экспорта показывает текущий и общую долю по весам (export_plan).
enum ExportStage {
	decode
	lens
	impulse
	denoise
	defringe
	capture
	tone
	write // запись файла - в save_worker, после develop_full
}

fn stage_title(s ExportStage) string {
	return match s {
		.decode { i18n.tr('Демозаика (LibRaw)') }
		.lens { i18n.tr('Коррекция объектива') }
		.impulse { i18n.tr('Импульсный шум') }
		.denoise { i18n.tr('Шумодав') }
		.defringe { i18n.tr('Ореолы') }
		.capture { i18n.tr('Capture-резкость') }
		.tone { i18n.tr('Тон и цвет') }
		.write { i18n.tr('Запись файла') }
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
// те же, что в нём) и запись файла формата f
fn export_plan(e EditState, f imgio.Format) StagePlan {
	mut st := [ExportStage.decode]
	mut w := [0.6]
	if e.lens_corr || e.lman.active() {
		st << .lens
		w << 2.8
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
	return i18n.tr('экспорт отменён')
}

// StageProgress - прогресс экспорта: stage(этап, done, total) зовётся в
// в начале каждого этапа (done, total - доля этапа, сейчас всегда 0, 0);
// false - отмена.
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

// ExportOpts - прогресс (StageProgress; none - без прогресса; false из
// него - отмена, develop_full вернёт ExportCancelled) и настройки вывода
@[params]
struct ExportOpts {
	progress ?StageProgress
	size     ExportSize // размер на выход (окно «Экспорт»); пусто - как есть
	half     bool       // половинный размер, как превью (левый кадр сравнения, pair.v)
	bits16   bool       // 16 бит на канал (Settings.export_bits16)
	demosaic int = -1   // алгоритм демозаики LibRaw (Settings.demosaic_qual)
}

// develop_full - проявка RAW-файла по настройкам кадра e в 8-битный (с
// o.bits16 - 16-битный) RGB полного размера. e - с производными полями (камерная кривая и таблицы
// кривых в params, как у живого st.edit); db - база lensfun (nil - без
// коррекции объектива). Свой LibRaw (открывает и закрывает файл сам) -
// годится для фонового потока. Отмена проверяется между этапами.
fn develop_full(path string, e EditState, db &lens.Database, o ExportOpts) !Image {
	mut progress := o.progress or { StageProgress(NoStage{}) }
	// Масштаб радиусов (Capture-резкость, резкость, чёткость) - как у превью
	scale := if o.half { preview_scale } else { f32(1.0) }
	if !progress.stage(.decode, 0, 0) {
		return ExportCancelled{}
	}
	mut d := raw.open(path)!
	mut img := d.develop(half: o.half, demosaic: o.demosaic) or {
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
	mut mask0 := []u16{}
	mut dc := []u16{}
	mut glin := []u16{}
	mut gmask := []u16{}
	mut haze := pipeline.HazeMap{}
	defer {
		img.free()
		bigbuf.free(mut mask0)
		bigbuf.free(mut dc)
		bigbuf.free(mut glin)
		bigbuf.free(mut gmask)
		haze.free()
	}
	w := img.width
	h := img.height
	buf := img.data_u16()
	if e.lens_corr || e.lman.active() {
		if !progress.stage(.lens, 0, 0) {
			return ExportCancelled{}
		}
		correct_lens(buf, w, h, meta, db, e.lens_corr, e.vign, e.lens_zoom, e.lman)
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
	mask0 = bigbuf.new_u16(w * h * pipeline.mask_ch)
	pipeline.luma_masks_into(buf, w, h, mut mask0)
	mut src := unsafe { &u16(buf) }
	if e.params.sharp.dc_amount > 0 {
		if !progress.stage(.capture, 0, 0) {
			return ExportCancelled{}
		}
		dc = bigbuf.new_u16(w * h * 3)
		pipeline.deconvolve_into(buf, w, h, e.params.sharp, scale, mut dc)
		src = unsafe { &u16(dc.data) }
		img.free() // сырьё дальше не нужно
	}
	if !progress.stage(.tone, 0, 0) {
		return ExportCancelled{}
	}
	// Удаление пятен - как в превью: после подготовки, до геометрии
	if e.spots.len > 0 {
		pipeline.spots_apply(src, pipeline.Region{0, 0, w, h}, w, h, e.spots)
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
		gmask = bigbuf.new_u16(ow * oh * pipeline.mask_ch)
		pipeline.geom_apply_into(unsafe { &u16(mask0.data) }, w, h, pipeline.mask_ch, g, true, mut
			gmask)
		mask = unsafe { &u16(gmask.data) }
		bigbuf.free(mut mask0)
	}
	// Карта дымки - по кадру после кадрирования (рабочая копия та же
	// ~1024 px, что у превью, - карты совпадают)
	if e.params.haze != 0 {
		haze = pipeline.haze_map_big(src, gw, gh)
	}
	stride := if o.bits16 { pipeline.stride16 } else { 3 }
	mut rgb := bigbuf.new_u8(gw * gh * stride)
	// Градиентные фильтры - по пикселям кадра после геометрии
	ep := with_lmap(e.params, pipeline.mask_map(out_geom(&e), w, h, true, gw, gh))
	pipeline.apply_image(src, mask, &haze, gw, gh, ep, scale, mut rgb, stride)
	// Размер на выход (окно «Экспорт»): только уменьшение, с резкостью на
	// выход (она - только при уменьшении)
	fw, fh := export_dims(o.size, gw, gh)
	if fw != gw || fh != gh {
		small := if o.bits16 {
			pipeline.resize_rgb16_sharp(rgb, gw, gh, fw, fh, o.size.sharp)
		} else {
			pipeline.resize_rgb_sharp(rgb, gw, gh, fw, fh, o.size.sharp)
		}
		bigbuf.free(mut rgb)
		return Image{
			width:  fw
			height: fh
			bits16: o.bits16
			rgb:    small
			meta:   meta
		}
	}
	return Image{
		width:  fw
		height: fh
		bits16: o.bits16
		rgb:    rgb
		meta:   meta
	}
}
