module main

// Экспорт: проявка RAW-файла в полном размере по настройкам кадра.
// Выполняется в фоновом потоке (save_worker) - поэтому без vgui и без
// общего состояния: свой LibRaw, всё нужное приходит копией в EditState.
//
// Порядок - как в превью: LibRaw (демозаика, камерный ББ, режим
// пересветов) -> коррекция объектива (виньетирование, затем дисторсия +
// TCA) -> импульсы -> шумодав -> ореолы -> маска «Тени/Света» ->
// pipeline.apply (тон, кривые, HSL) -> 8 бит.
import raw
import lens
import pipeline

// correct_lens - коррекция объектива на месте (виньетирование строго до
// дисторсии: ремап двигает пиксели); false - профиля нет
fn correct_lens(buf &u16, w int, h int, m raw.Meta, db &lens.Database) bool {
	if isnil(db) {
		return false
	}
	c := db.find(m.cam_make, m.cam_model, m.lens) or { return false }
	c.vignetting(buf, w, h, m.focal, m.aperture)
	c.geometry(buf, w, h, m.focal)
	return true
}

// Image - проявленный 8-битный RGB-кадр
struct Image {
	width  int
	height int
	rgb    []u8 // width * height * 3
}

// develop_full - проявка RAW-файла по настройкам кадра e в 8-битный RGB
// полного размера. e - с производными полями (камерная кривая и таблицы
// кривых в params, как у живого st.edit); db - база lensfun (nil - без
// коррекции объектива). Свой LibRaw (открывает и закрывает файл сам) -
// годится для фонового потока.
fn develop_full(path string, e EditState, db &lens.Database) !Image {
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
		correct_lens(buf, w, h, d.meta(), db)
	}
	if e.nr[0] > 0 {
		pipeline.impulse(buf, w, h, e.nr[0])
	}
	if e.nr[1] > 0 || e.nr[2] > 0 {
		pipeline.denoise(buf, w, h, e.nr[1], e.nr[2])
	}
	if e.nr[3] > 0 {
		pipeline.defringe(buf, w, h, e.nr[3])
	}
	mask := pipeline.blur_luma(buf, w, h)
	mut rgb := []u8{len: w * h * 3}
	pipeline.apply(buf, unsafe { &u16(mask.data) }, w * h, e.params, mut rgb, 3)
	return Image{
		width:  w
		height: h
		rgb:    rgb
	}
}
