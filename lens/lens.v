module lens

import math
import runtime
import bigbuf
import pipeline { Region }

// Обёртка над lensfun: поиск профиля объектива по метаданным кадра и
// коррекция виньетирования на линейном 16-битном RGB-буфере.
// База профилей: системная (/usr/share/lensfun/version_1) плюс
// пользовательские обновления (~/.local/share/lensfun/updates/version_1) -
// lf_db_load подхватывает обе, свежая записывается поверх.
//
// Виньетирование корректируется в ЛИНЕЙНОМ пространстве (до пайплайна) -
// это физическое затемнение, компенсировать его после гаммы неверно.

#flag -llensfun
#include <lensfun/lensfun.h>

// Константы lensfun (значения из lensfun.h)
const lf_pf_f32 = 3 // lfPixelFormat: LF_PF_F32
const lf_modify_tca = 1 // LF_MODIFY_TCA
const lf_modify_vignetting = 2 // LF_MODIFY_VIGNETTING
const lf_modify_distortion = 8 // LF_MODIFY_DISTORTION
const lf_modify_scale = 0x20 // LF_MODIFY_SCALE - без него scale в initialize игнорируется
const lf_rectilinear = 1 // lfLensType: LF_RECTILINEAR
const lf_cr_intensity = 3 // LF_CR_1(INTENSITY) - одноканальный буфер
// Усиление виньетирования: профиль lensfun по радиусу (vign_profile),
// неубывающий (у «полюса» вырожденного полинома - значение до него), с
// мягким потолком (soft_cap: до vign_knee как в профиле, выше плавно, без
// излома, к vign_cap) и ослабленный в лог-домене: g^strength.
// Раньше потолок был жёстким (x8) и карта применялась попиксельно - излом
// на потолке и спад за «полюсом» давали на гладком небе дуги и светлые
// серпы в углах (IMG_0817.CR3, RF 24-50 на 24 мм: профиль x3.5 на 0.85
// радиуса, x16.7 на 0.95, в углу 0).
const vign_knee = f32(8.0)
const vign_cap = f32(16.0)
// Сила коррекции в лог-домене (1.0 - полный профиль) по умолчанию - когда
// подобрать её по JPEG камеры нельзя (match_strength, match.v). У RF 24-50
// профиль перекорректирует уже с 0.7 радиуса: при полной силе края неба
// светлее центра и у углов ореол. 0.3 подобрано на IMG_0817.CR3: яркость
// неба по радиусу - как у JPEG камеры (103..73 против 105..76).
pub const vign_default = f32(0.3)
// Точек радиального профиля (от центра до угла)
const vign_lut_n = 1024

// C-структуры объявлены частично (как в модуле raw): раскладку компилятор
// берёт из <lensfun/lensfun.h>, объявляем только используемые поля.
@[typedef]
pub struct C.lfDatabase {}

@[typedef]
pub struct C.lfCamera {
	CropFactor f32
}

@[typedef]
pub struct C.lfLens {
	Model &char
}

@[typedef]
pub struct C.lfModifier {}

fn C.lf_db_new() &C.lfDatabase
fn C.lf_db_load(db &C.lfDatabase) int
fn C.lf_db_destroy(db &C.lfDatabase)
fn C.lf_db_find_cameras(db &C.lfDatabase, maker &char, model &char) &voidptr
fn C.lf_db_find_lenses_hd(db &C.lfDatabase, cam &C.lfCamera, maker &char, lensname &char, sflags int) &voidptr
fn C.lf_free(data voidptr)
fn C.lf_modifier_new(l &C.lfLens, crop f32, width int, height int) &C.lfModifier
fn C.lf_modifier_destroy(m &C.lfModifier)
fn C.lf_modifier_initialize(m &C.lfModifier, l &C.lfLens, format int, focal f32, aperture f32,
	distance f32, scale f32, targeom int, flags int, reverse int) int
fn C.lf_modifier_apply_color_modification(m &C.lfModifier, pixels voidptr, x f32, y f32,
	width int, height int, comp_role int, row_stride int) int
fn C.lf_modifier_apply_subpixel_geometry_distortion(m &C.lfModifier, xu f32, yu f32,
	width int, height int, res &f32) int
fn C.lf_modifier_get_auto_scale(m &C.lfModifier, reverse int) f32

// Corrector - найденная пара камера+объектив. Указатели cam/lens живут
// внутри db, поэтому база держится открытой всё время жизни Corrector
// и освобождается только в free().
@[heap]
pub struct Corrector {
mut:
	db   &C.lfDatabase = unsafe { nil } // своя база (lens.find); nil - общая (Database.find)
	cam  &C.lfCamera   = unsafe { nil }
	lens &C.lfLens     = unsafe { nil }
	crop f32
pub:
	lens_name string // имя профиля из базы (для статуса GUI)
}

fn find_camera(db &C.lfDatabase, maker string, model string) &C.lfCamera {
	cams := C.lf_db_find_cameras(db, maker.str, model.str)
	if isnil(cams) || isnil(unsafe { cams[0] }) {
		C.lf_free(cams)
		return unsafe { nil }
	}
	cam := unsafe { &C.lfCamera(cams[0]) }
	C.lf_free(cams)
	return cam
}

// Database - база профилей lensfun. Загрузка ~115 мс (XML всех профилей),
// поиск в загруженной - сотые доли мс, база за время работы не меняется:
// GUI грузит её один раз за запуск (load_db) и ищет профили через
// db.find. Поиск и коррекция только читают базу, поэтому одну базу
// можно использовать из нескольких потоков (загрузка кадра, сохранение).
@[heap]
pub struct Database {
mut:
	db &C.lfDatabase = unsafe { nil }
}

// load_db загружает базу lensfun (системная + обновления в
// ~/.local/share/lensfun). Освобождение - free(), после всех Corrector.
pub fn load_db() !&Database {
	db := C.lf_db_new()
	if isnil(db) {
		return error('не удалось создать базу lensfun')
	}
	C.lf_db_load(db)
	return &Database{
		db: db
	}
}

pub fn (mut d Database) free() {
	if !isnil(d.db) {
		C.lf_db_destroy(d.db)
		d.db = unsafe { nil }
	}
}

// find ищет профиль по строкам из EXIF (производитель и модель камеры,
// модель объектива) в загруженной базе. none - камеры или объектива нет.
// Corrector ссылается на базу и её не освобождает: база должна жить
// дольше него.
pub fn (d &Database) find(cam_maker string, cam_model string, lens_model string) ?&Corrector {
	if isnil(d) || isnil(d.db) || lens_model.len == 0 {
		return none
	}
	// LibRaw отдаёт make='Canon', model='EOS R8', а в базе lensfun модель
	// полная ('Canon EOS R8') - матчеру нужно, чтобы запрос покрывал её
	// целиком, поэтому вторая попытка с приклеенным производителем
	// (тот же приём у darktable).
	mut cam := find_camera(d.db, cam_maker, cam_model)
	if isnil(cam) {
		cam = find_camera(d.db, cam_maker, '${cam_maker} ${cam_model}')
	}
	if isnil(cam) {
		return none
	}
	lenses := C.lf_db_find_lenses_hd(d.db, cam, unsafe { nil }, lens_model.str, 0)
	if isnil(lenses) || isnil(unsafe { lenses[0] }) {
		C.lf_free(lenses)
		return none
	}
	lf_lens := unsafe { &C.lfLens(lenses[0]) }
	C.lf_free(lenses)
	return &Corrector{
		cam:       cam
		lens:      lf_lens
		crop:      cam.CropFactor
		lens_name: unsafe { cstring_to_vstring(lf_lens.Model) }
	}
}

// find - разовый поиск со своей базой (тесты, одиночные вызовы): база
// загружается заново (~115 мс) и принадлежит Corrector - освобождается
// его free(). В GUI - load_db один раз и db.find.
pub fn find(cam_maker string, cam_model string, lens_model string) ?&Corrector {
	mut d := load_db() or { return none }
	mut c := d.find(cam_maker, cam_model, lens_model) or {
		d.free()
		return none
	}
	c.db = d.db // Corrector владеет базой
	return c
}

// vignetting компенсирует виньетирование в линейном RGB-буфере u16
// (w*h пикселей, плотная укладка, как отдаёт raw.DevImage.data_u16()).
// Правка на месте. strength - сила в лог-домене: усиление g^strength
// (1 - полный профиль, vign_default - по умолчанию). false - в профиле нет
// данных виньетирования (или они не покрывают эти focal/aperture).
//
// Почему через карту усиления, а не прямое применение к u16: у части
// профилей полином виньетирования вырождается на крайних пикселях угла
// (уходит в ноль и минус - у RF 24-50 проверено), прямая коррекция там
// даёт чёрные углы. Поэтому усиление снимается в f32-буфер, вырожденные
// значения замещаются максимальным корректным, умножаем сами.
pub fn (c &Corrector) vignetting(buf &u16, w int, h int, focal f32, aperture f32, strength f32) bool {
	lut := c.vign_lut(w, h, focal, aperture, strength) or { return false }
	apply_radial_gain(buf, Region{0, 0, w, h}, w, h, lut)
	return true
}

// vign_lut - радиальный профиль усиления кадра w x h (то, что vignetting
// умножает на буфер); none - в профиле нет данных виньетирования. Для
// фрагмента полного кадра: профиль один на кадр, умножение -
// vign_apply_region.
pub fn (c &Corrector) vign_lut(w int, h int, focal f32, aperture f32, strength f32) ?[]f32 {
	if isnil(c.lens) || w <= 0 || h <= 0 {
		return none
	}
	// Диафрагма бывает не записана (мех. объективы) - берём среднюю
	ap := if aperture > 0.1 { aperture } else { f32(8.0) }
	m := C.lf_modifier_new(c.lens, c.crop, w, h)
	if isnil(m) {
		return none
	}
	// distance: расстояние до объекта из EXIF почти никогда не доступно,
	// 1000 м - стандартный дефолт (влияние на виньетку минимально).
	// scale 1.0 = без масштабирования (0.0 включило бы авто-масштаб).
	got := C.lf_modifier_initialize(m, c.lens, lf_pf_f32, focal, ap, 1000.0, 1.0,
		lf_rectilinear, lf_modify_vignetting, 0)
	if got & lf_modify_vignetting == 0 {
		C.lf_modifier_destroy(m)
		return none
	}
	// Карта усиления: коррекция единичного буфера = 1/затемнение
	// (вне сборщика - bigbuf: на полном кадре 96 МБ)
	mut gain := bigbuf.new_f32(w * h)
	defer {
		bigbuf.free(mut gain)
	}
	for i in 0 .. gain.len {
		gain[i] = 1.0
	}
	ok := C.lf_modifier_apply_color_modification(m, gain.data, 0.0, 0.0, w, h,
		lf_cr_intensity, w * int(sizeof(f32)))
	C.lf_modifier_destroy(m)
	if ok == 0 {
		return none
	}
	mut lut := vign_profile(gain, w, h, vign_knee, vign_cap)
	if strength != 1 {
		for i in 0 .. lut.len {
			lut[i] = math.powf(lut[i], strength)
		}
	}
	return lut
}

// vign_apply_region - виньетирование куска r кадра w x h: buf - r.w x r.h
// RGB; усиление - по расстоянию от центра ПОЛНОГО кадра, lut - vign_lut
// того же кадра. Побитово равно той же области после vignetting.
pub fn vign_apply_region(buf &u16, r Region, w int, h int, lut []f32) {
	apply_radial_gain(buf, r, w, h, lut)
}

// vign_profile - радиальный профиль усиления (vign_lut_n точек от центра
// до угла) из карты lensfun w x h: по диагонали к правому нижнему углу
// (модели виньетирования lensfun радиальны), неубывающий (NaN, ноль и
// спад после «полюса» вырожденного полинома - предыдущее значение), с
// мягким потолком soft_cap
fn vign_profile(gain []f32, w int, h int, knee f32, cap f32) []f32 {
	mut lut := []f32{len: vign_lut_n}
	cx := f64(w - 1) / 2
	cy := f64(h - 1) / 2
	mut prev := f32(1)
	mut pole := false
	for i in 0 .. vign_lut_n {
		t := f64(i) / f64(vign_lut_n - 1)
		// Точка диагонали - билинейно: ближайший пиксель давал значению
		// дрожь по радиусу, удержание максимума - микроступеньки (кольца)
		g := map_at(gain, w, h, cx + t * cx, cy + t * cy)
		// «Полюс» вырожденного полинома: NaN, ноль, спад - дальше значение
		// до него (профиль не убывает)
		if pole || !(g >= prev * 0.999 && g < 1e6) {
			pole = true
		} else {
			prev = g
		}
		lut[i] = soft_cap(prev, knee, cap)
	}
	return lut
}

// map_at - значение карты w x h в дробной точке (билинейно)
fn map_at(m []f32, w int, h int, x f64, y f64) f32 {
	x0 := imin(int(x), w - 2)
	y0 := imin(int(y), h - 2)
	fx := f32(x - f64(x0))
	fy := f32(y - f64(y0))
	a := m[y0 * w + x0] * (1 - fx) + m[y0 * w + x0 + 1] * fx
	b := m[(y0 + 1) * w + x0] * (1 - fx) + m[(y0 + 1) * w + x0 + 1] * fx
	return a * (1 - fy) + b * fy
}

// soft_cap - мягкий потолок в лог-домене: до knee как есть, выше -
// knee * (cap/knee)^tanh(...): производная в knee непрерывна, к cap
// подходит асимптотически
@[inline]
fn soft_cap(g f32, knee f32, cap f32) f32 {
	if g <= knee {
		return g
	}
	lk := math.log(f64(knee))
	span := math.log(f64(cap)) - lk
	return f32(math.exp(lk + span * math.tanh((math.log(f64(g)) - lk) / span)))
}

// apply_radial_gain - умножить RGB-буфер на усиление lut по расстоянию
// пикселя от центра (доля полудиагонали), линейная интерполяция профиля.
// buf - кусок r кадра w x h (весь кадр - r = {0, 0, w, h}).
// Строки - в потоки (корень на каждый пиксель полного кадра).
fn apply_radial_gain(buf &u16, r Region, w int, h int, lut []f32) {
	nt := imin(runtime.nr_cpus(), 16)
	step := (r.h + nt - 1) / nt
	mut ts := []thread{}
	for y0 := 0; y0 < r.h; y0 += step {
		ts << spawn radial_rows(buf, r, w, h, lut, y0, imin(r.h, y0 + step))
	}
	for t in ts {
		t.wait()
	}
}

// radial_rows - строки y0..y1 куска r (координаты кадра - r.x + i, r.y + j)
fn radial_rows(buf &u16, r Region, w int, h int, lut []f32, y0 int, y1 int) {
	cx := f64(w - 1) / 2
	cy := f64(h - 1) / 2
	rmax := math.sqrt(cx * cx + cy * cy)
	k := f64(vign_lut_n - 1) / rmax
	for y in y0 .. y1 {
		dy := f64(r.y + y) - cy
		unsafe {
			mut p := &u16(buf) + y * r.w * 3
			for x in r.x .. r.x + r.w {
				dx := f64(x) - cx
				f := math.sqrt(dx * dx + dy * dy) * k
				mut i := int(f)
				if i >= vign_lut_n - 1 {
					i = vign_lut_n - 2
				}
				fr := f32(f - f64(i))
				g := lut[i] + (lut[i + 1] - lut[i]) * fr
				for c in 0 .. 3 {
					v := f32(p[c]) * g
					p[c] = if v > 65535.0 { u16(65535) } else { u16(v) }
				}
				p += 3
			}
		}
	}
}

fn imin(a int, b int) int {
	return if a < b { a } else { b }
}

// bilinear - выборка канала ch кадра w x h в дробной точке (x, y) с
// билинейной интерполяцией; координаты вне кадра прижимаются к краю.
// s - кусок sb кадра (RGB, sb.w x sb.h), в нём должны быть все соседи
// выборки (весь кадр - sb = {0, 0, w, h}).
@[inline]
fn bilinear(s &u16, sb Region, w int, h int, ch int, x f32, y f32) u16 {
	mut fx := x
	mut fy := y
	if !(fx >= 0) { // ловит и NaN
		fx = 0
	} else if fx > f32(w - 1) {
		fx = f32(w - 1)
	}
	if !(fy >= 0) {
		fy = 0
	} else if fy > f32(h - 1) {
		fy = f32(h - 1)
	}
	x0 := int(fx)
	y0 := int(fy)
	x1 := if x0 < w - 1 { x0 + 1 } else { x0 }
	y1 := if y0 < h - 1 { y0 + 1 } else { y0 }
	ax := fx - f32(x0)
	ay := fy - f32(y0)
	r0 := (y0 - sb.y) * sb.w - sb.x
	r1 := (y1 - sb.y) * sb.w - sb.x
	unsafe {
		p00 := f32(s[(r0 + x0) * 3 + ch])
		p10 := f32(s[(r0 + x1) * 3 + ch])
		p01 := f32(s[(r1 + x0) * 3 + ch])
		p11 := f32(s[(r1 + x1) * 3 + ch])
		v := p00 * (1 - ax) * (1 - ay) + p10 * ax * (1 - ay) + p01 * (1 - ax) * ay +
			p11 * ax * ay
		return u16(v + 0.5)
	}
}

// geometry исправляет дисторсию и хроматические аберрации одним
// субпиксельным ремапом (по паре координат на канал - TCA и есть разница
// координат каналов). Правка на месте, буфер как у vignetting().
// scale 0.0 в initialize = авто-масштаб lensfun: после исправления бочки
// кадр остаётся заполненным, а мёртвые углы сенсора (у RF 24-50 круг
// изображения еле накрывает сенсор) уходят за рамку - как делают камера
// и RawTherapee. false - в профиле нет данных дисторсии и TCA.
//
// Вызывать ПОСЛЕ vignetting(): виньетка привязана к исходной геометрии
// сенсора, править её нужно до перемещения пикселей (порядок lensfun).
pub fn (c &Corrector) geometry(buf &u16, w int, h int, focal f32) bool {
	return c.geometry_zoom(buf, w, h, focal, 1)
}

// geometry_zoom - geometry с кадром, увеличенным в zoom раз сверх
// автомасштаба (zoom > 1 - уже, как обрезает кадр камера; см. geometry_plan_zoom)
pub fn (c &Corrector) geometry_zoom(buf &u16, w int, h int, focal f32, zoom f32) bool {
	mut p := c.geometry_plan_zoom(w, h, focal, zoom) or { return false }
	defer {
		p.free()
	}
	// Ремап читает произвольные точки источника - нужна его копия (вне
	// сборщика - bigbuf: на полном кадре 144 МБ)
	mut src := bigbuf.new_u16(w * h * 3)
	defer {
		bigbuf.free(mut src)
	}
	unsafe { vmemcpy(src.data, buf, u64(w) * u64(h) * 3 * 2) }
	full := Region{0, 0, w, h}
	p.remap(unsafe { &u16(src.data) }, full, full, buf)
	return true
}

// GeomPlan - дисторсия + TCA кадра w x h с подобранным масштабом: одна на
// кадр, ремап - любого прямоугольника (remap). Для фрагмента полного
// кадра: source_box - какой кусок источника нужен, remap - сам ремап.
// Освобождать - free().
@[heap]
pub struct GeomPlan {
mut:
	m &C.lfModifier = unsafe { nil }
pub:
	w int
	h int
}

// geometry_plan - план дисторсии + TCA кадра w x h; none - в профиле нет
// данных геометрии
pub fn (c &Corrector) geometry_plan(w int, h int, focal f32) ?&GeomPlan {
	return c.geometry_plan_zoom(w, h, focal, 1)
}

// geometry_plan_zoom - geometry_plan с кадром, увеличенным в zoom раз
// сверх автомасштаба (наименьшего без пустых углов). Камера после
// исправления дисторсии обрезает кадр сильнее (RF 24-50 на 24 мм - на
// 8.5%): zoom подбирается по JPEG камеры (lens_match в loader.v), чтобы
// кадр совпал с камерным; zoom <= 1 - автомасштаб.
pub fn (c &Corrector) geometry_plan_zoom(w int, h int, focal f32, zoom f32) ?&GeomPlan {
	if isnil(c.lens) || w <= 0 || h <= 0 {
		return none
	}
	mut m := c.geometry_modifier(w, h, focal, 0.0)?
	// Авто-масштаб lensfun приблизительный (так и сказано в lensfun.h):
	// бывает чуть меньше нужного, и край кадра берёт точки за пределами
	// источника - после клампа это 3-4 повторённых крайних столбца.
	// Меряем вылет по рамке кадра и доувеличиваем масштаб (обычно
	// хватает одного шага, второй - страховка). Масштаб, которым lensfun
	// пользуется в авторежиме, - effective_scale: lf_modifier_get_auto_scale
	// у lensfun 0.3.4 возвращает 1 (на 105 мм RF 24-105 настоящий - 1.010).
	mut scale := c.effective_scale(m, w, h, focal)
	if scale <= 0 {
		// Масштаб не определяется (циркулярный фишай: картинка - круг в
		// кадре) - как раньше: авторежим lensfun, без увеличения кадра
		return &GeomPlan{
			m: m
			w: w
			h: h
		}
	}
	for _ in 0 .. 2 {
		over := border_overflow(m, w, h)
		if over <= 1.0 {
			break
		}
		scale *= over * 1.001
		C.lf_modifier_destroy(m)
		m = c.geometry_modifier(w, h, focal, scale)?
	}
	if zoom > 1.0005 {
		C.lf_modifier_destroy(m)
		m = c.geometry_modifier(w, h, focal, scale * zoom)?
	}
	return &GeomPlan{
		m: m
		w: w
		h: h
	}
}

pub fn (mut p GeomPlan) free() {
	if !isnil(p.m) {
		C.lf_modifier_destroy(p.m)
		p.m = unsafe { nil }
	}
}

// source_box - кусок источника, из которого remap читает выход r: все
// точки выборки трёх каналов с соседями билинейной интерполяции (после
// прижатия к кадру, как в bilinear)
pub fn (p &GeomPlan) source_box(r Region) Region {
	if r.w <= 0 || r.h <= 0 {
		return Region{}
	}
	// Координаты - всегда полной строки (см. row_coords)
	mut coords := []f32{len: p.w * 2 * 3}
	mut x0 := p.w - 1
	mut y0 := p.h - 1
	mut x1 := 0
	mut y1 := 0
	fw := f32(p.w - 1)
	fh := f32(p.h - 1)
	for y in r.y .. r.y + r.h {
		if !p.row_coords(y, mut coords) {
			continue
		}
		for i := r.x * 6; i < (r.x + r.w) * 6; i += 2 {
			fx := clamp_f(coords[i], fw)
			fy := clamp_f(coords[i + 1], fh)
			ix := int(fx)
			iy := int(fy)
			x0 = imin(x0, ix)
			y0 = imin(y0, iy)
			x1 = imax(x1, imin(ix + 1, p.w - 1))
			y1 = imax(y1, imin(iy + 1, p.h - 1))
		}
	}
	if x1 < x0 || y1 < y0 {
		// lensfun не дал координат - выход читает себя (как полный ремап)
		return r
	}
	return Region{x0, y0, x1 - x0 + 1, y1 - y0 + 1}
}

// remap - выход r (кадр w x h после дисторсии и TCA) в dst (r.w x r.h
// RGB) из куска источника sb (обычно source_box(r) или шире).
// Побитово равно той же области полного ремапа.
pub fn (p &GeomPlan) remap(src &u16, sb Region, r Region, dst &u16) {
	// Координаты построчно (на весь кадр сразу было бы w*h*24 байт -
	// сотни МБ на полном кадре): по 3 пары (x,y) на пиксель - R, G, B.
	mut coords := []f32{len: p.w * 2 * 3}
	unsafe {
		mut d := &u16(dst)
		for y in r.y .. r.y + r.h {
			if !p.row_coords(y, mut coords) {
				d += r.w * 3
				continue
			}
			mut cp := &f32(coords.data) + r.x * 6
			for _ in 0 .. r.w {
				for ch in 0 .. 3 {
					d[ch] = bilinear(src, sb, p.w, p.h, ch, cp[0], cp[1])
					cp += 2
				}
				d += 3
			}
		}
	}
}

// row_coords - координаты источника ВСЕЙ строки y кадра (coords - w * 6),
// фрагмент берёт из них свой кусок. Не короче: lensfun считает точки
// строки накоплением от начальной (строка с x > 0 расходится с полной до
// 0.2 px на RF 24-50) и блоками по 4 точки с отдельным хвостом (у строки
// другой длины иначе считаются последние точки) - фрагмент разошёлся бы
// с полным ремапом.
fn (p &GeomPlan) row_coords(y int, mut coords []f32) bool {
	return C.lf_modifier_apply_subpixel_geometry_distortion(p.m, 0.0, f32(y), p.w, 1,
		&f32(coords.data)) != 0
}

// clamp_f - прижатие координаты к [0, hi] (NaN - к нулю), как в bilinear
@[inline]
fn clamp_f(v f32, hi f32) f32 {
	return if !(v >= 0) { f32(0) } else if v > hi { hi } else { v }
}

// geometry_modifier - модификатор дисторсии + TCA; scale 0 - авто-масштаб
// lensfun. none - в профиле нет данных геометрии.
fn (c &Corrector) geometry_modifier(w int, h int, focal f32, scale f32) ?&C.lfModifier {
	m := C.lf_modifier_new(c.lens, c.crop, w, h)
	if isnil(m) {
		return none
	}
	// Диафрагма и дистанция на геометрию не влияют - ставим типовые.
	// LF_MODIFY_SCALE обязателен: без него lensfun молча не масштабирует
	// (ни авто, ни заданный scale) и край кадра смотрит за источник.
	got := C.lf_modifier_initialize(m, c.lens, lf_pf_f32, focal, 8.0, 1000.0, scale,
		lf_rectilinear, lf_modify_distortion | lf_modify_tca | lf_modify_scale, 0)
	if got & (lf_modify_distortion | lf_modify_tca) == 0 {
		C.lf_modifier_destroy(m)
		return none
	}
	return m
}

// border_overflow - во сколько раз точки источника, в которые смотрит рамка
// кадра (крайние строки и столбцы, все три канала), выходят за источник:
// максимум |s - центр| / полуразмер по обеим осям. <= 1 - всё внутри.
// Около края дисторсия локально почти линейна, поэтому доувеличение
// масштаба в это число раз убирает вылет.
// effective_scale - масштаб, которым на деле пользуется модификатор m
// (авторежим lensfun): явный масштаб, при котором точка у правого края
// середины кадра уходит в ту же точку источника, что у m (двоичный поиск;
// источник сдвигается к центру с ростом масштаба). Проверено по всей базе
// lensfun (1522 объектива с дисторсией, 3 фокусных): совпадает с
// авторежимом точнее 0.05 px; 0 - не определяется (циркулярные фишаи
// Sigma 4.5 и 8 мм: поиск упирается в границы)
fn (c &Corrector) effective_scale(m &C.lfModifier, w int, h int, focal f32) f32 {
	px := f32(w - 1)
	py := f32(h - 1) * 0.5
	mut res := []f32{len: 6}
	if C.lf_modifier_apply_subpixel_geometry_distortion(m, px, py, 1, 1, unsafe { &f32(res.data) }) == 0 {
		return 1
	}
	target := res[2] // зелёный канал
	mut lo := f32(0.5)
	mut hi := f32(2.0)
	for _ in 0 .. 32 {
		mid := (lo + hi) * 0.5
		t := c.geometry_modifier(w, h, focal, mid) or { return 1 }
		ok := C.lf_modifier_apply_subpixel_geometry_distortion(t, px, py, 1, 1, unsafe { &f32(res.data) })
		C.lf_modifier_destroy(t)
		if ok == 0 {
			return 1
		}
		if res[2] > target {
			lo = mid
		} else {
			hi = mid
		}
	}
	a := (lo + hi) * 0.5
	return if a < 0.51 || a > 1.99 { f32(0) } else { a }
}

fn border_overflow(m &C.lfModifier, w int, h int) f32 {
	cx := f32(w - 1) * 0.5
	cy := f32(h - 1) * 0.5
	mut worst := f32(0)
	// Верхняя и нижняя строки, левый и правый столбцы
	fw := f32(w)
	fh := f32(h)
	spans := [[f32(0), 0, fw, 1], [f32(0), fh - 1, fw, 1], [f32(0), 0, 1, fh],
		[fw - 1, 0, 1, fh]]
	for sp in spans {
		n := int(sp[2]) * int(sp[3])
		mut res := []f32{len: n * 6}
		if C.lf_modifier_apply_subpixel_geometry_distortion(m, sp[0], sp[1], int(sp[2]),
			int(sp[3]), unsafe { &f32(res.data) }) == 0 {
			continue
		}
		for i := 0; i < res.len; i += 2 {
			rx := math.abs(res[i] - cx) / cx
			ry := math.abs(res[i + 1] - cy) / cy
			if rx > worst {
				worst = rx
			}
			if ry > worst {
				worst = ry
			}
		}
	}
	return worst
}

// free освобождает базу, если Corrector ею владеет (lens.find); профиль
// из общей базы (Database.find) база не теряет - освобождать нечего.
pub fn (mut c Corrector) free() {
	if !isnil(c.db) {
		C.lf_db_destroy(c.db)
		c.db = unsafe { nil }
	}
	c.cam = unsafe { nil }
	c.lens = unsafe { nil }
}
