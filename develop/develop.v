module develop

// Проявка кадра по настройкам (Settings): общая для GUI (экспорт) и CLI.
// Одна функция на оба пути - экспорт из окна и `vraw файл.CR3` с
// сайдкаром дают одинаковый JPEG по построению.
//
// Порядок - как в превью GUI: LibRaw (демозаика, камерный ББ, режим
// пересветов) -> коррекция объектива (виньетирование, затем дисторсия +
// TCA) -> импульсы -> шумодав -> ореолы -> маска «Тени/Света» ->
// pipeline.apply (тон, кривые, HSL) -> 8 бит.
import stbi
import raw
import lens
import pipeline

// params - параметры пайплайна из настроек; cam_curve - камерная кривая
// кадра (256 узлов, пусто - нет), применяется при use_curve
pub fn (s Settings) params(cam_curve []f32) pipeline.Params {
	mut p := pipeline.Params{
		exposure:      s.exposure
		shadows:       s.shadows
		contrast:      s.contrast
		saturation:    s.saturation
		sh_shadows:    s.sh_shadows
		sh_highlights: s.sh_highlights
		curve:         if s.use_curve { cam_curve.clone() } else { []f32{} }
		tc_rgb:        tone_lut(s.curves[0])
		tc_r:          tone_lut(s.curves[1])
		tc_g:          tone_lut(s.curves[2])
		tc_b:          tone_lut(s.curves[3])
	}
	for i in 0 .. 5 {
		p.eq[i] = s.eq[i]
	}
	for i in 0 .. 8 {
		p.hsl_hue[i] = s.hsl_hue[i]
		p.hsl_sat[i] = s.hsl_sat[i]
		p.hsl_lum[i] = s.hsl_lum[i]
	}
	return p
}

// correct_lens - коррекция объектива на месте (виньетирование строго до
// дисторсии: ремап двигает пиксели); false - профиля нет
pub fn correct_lens(buf &u16, w int, h int, m raw.Meta, db &lens.Database) bool {
	if isnil(db) {
		return false
	}
	c := db.find(m.cam_make, m.cam_model, m.lens) or { return false }
	c.vignetting(buf, w, h, m.focal, m.aperture)
	c.geometry(buf, w, h, m.focal)
	return true
}

// match_camera - камерная кривая: встроенный полный JPEG камеры +
// гистограммное сопоставление с нейтральной проявкой linear (npix
// пикселей). Именно полный JPEG: у CR3 превью 1620x1080 обработано иначе.
// Пусто - встроенного JPEG нет.
pub fn match_camera(mut d raw.Developer, linear &u16, npix int) []f32 {
	tj := d.thumb() or { return []f32{} }
	mut t := stbi.load_from_memory(tj.data, tj.len, desired_channels: 3) or { return []f32{} }
	defer {
		t.free()
	}
	return pipeline.match_curve(linear, npix, t.data, t.width * t.height)
}

// camera_curve - камерная кривая так же, как её строит GUI при открытии
// кадра: по превью ПОЛОВИННОГО размера (режим пересветов и коррекция
// объектива - из настроек, без шумодава). По полному кадру кривая
// заметно другая (IMG_0817: до 11 из 255), поэтому именно так - для
// сайдкаров без записанной кривой (camera_curve в файле).
pub fn camera_curve(mut d raw.Developer, s Settings, db &lens.Database) []f32 {
	mut img := d.develop(half: true, linear16: true, highlight: s.highlight) or { return []f32{} }
	defer {
		img.free()
	}
	if s.lens_corr {
		correct_lens(img.data_u16(), img.width, img.height, d.meta(), db)
	}
	return match_camera(mut d, img.data_u16(), img.width * img.height)
}

// Image - проявленный 8-битный RGB-кадр
pub struct Image {
pub:
	width  int
	height int
	rgb    []u8 // width * height * 3
}

@[params]
pub struct FullParams {
pub:
	// Камерная кривая: 256 узлов - готовая (из сайдкара / превью GUI);
	// пусто - посчитать по превью половинного размера (camera_curve)
	cam_curve []f32
	db        &lens.Database = unsafe { nil } // база lensfun; nil - без коррекции объектива
	half      bool // проявить в половинном размере
}

// full - проявка RAW-файла по настройкам в 8-битный RGB. Свой LibRaw
// (открывает и закрывает файл сам) - годится для фонового потока.
pub fn full(path string, s Settings, fp FullParams) !Image {
	s.validate()!
	mut d := raw.open(path)!
	defer {
		d.close()
	}
	mut cam := fp.cam_curve.clone()
	if s.use_curve && cam.len != 256 {
		cam = camera_curve(mut d, s, fp.db)
	}
	mut img := d.develop(half: fp.half, linear16: true, highlight: s.highlight)!
	defer {
		img.free()
	}
	w := img.width
	h := img.height
	buf := img.data_u16()
	if s.lens_corr {
		correct_lens(buf, w, h, d.meta(), fp.db)
	}
	if s.nr[0] > 0 {
		pipeline.impulse(buf, w, h, s.nr[0])
	}
	if s.nr[1] > 0 || s.nr[2] > 0 {
		pipeline.denoise(buf, w, h, s.nr[1], s.nr[2])
	}
	if s.nr[3] > 0 {
		pipeline.defringe(buf, w, h, s.nr[3])
	}
	mask := pipeline.blur_luma(buf, w, h)
	mut rgb := []u8{len: w * h * 3}
	pipeline.apply(buf, unsafe { &u16(mask.data) }, w * h, s.params(cam), mut rgb, 3)
	return Image{
		width:  w
		height: h
		rgb:    rgb
	}
}
