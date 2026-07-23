module lens

import math

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
const lf_rectilinear = 1 // lfLensType: LF_RECTILINEAR
const lf_cr_intensity = 3 // LF_CR_1(INTENSITY) - одноканальный буфер
// Потолок СЫРОГО усиления профиля - ×8 (3 EV): сильнее виньетка у реальных
// объективов не бывает, а вырожденный полином профиля по дороге к нулю
// проходит через любые значения (у RF 24-50 в углу - ×60 и больше). Это
// потолок значения g ДО смягчения; в кадр попадает уже g^vign_strength,
// поэтому эффективный максимум применяемого усиления - 8^0.3 ≈ ×1.87 (~0.9 EV).
const gain_cap = f32(8.0)
// Сила коррекции в ЛОГ-домене усиления (g_applied = g^vign_strength),
// 1.0 = полное усиление профиля (как раньше). У вырожденных профилей
// (RF 24-50 на 24 мм) полином виньетирования в углу растёт настолько
// резко, что даже под потолком gain_cap реальные (не обрезанные до cap)
// значения усиления в переходной зоне (не в самом углу, а чуть ближе
// к центру) поднимают светлое небо ВЫШЕ яркости центра кадра -
// "вывернутая виньетка" (видна как светлое кольцо-ореол вокруг угла).
// 0.3 подобрано измерением на IMG_0817.CR3 (RF24-50 24мм f/6.3, небо
// в верхнем углу): при 1.0 угол ярче центра в ~1.2 раза, при 0.3 угол
// остаётся заметно (в ~1.6 раза) ярче некорректированного, но не выше
// центра кадра нигде вдоль перехода угол->центр.
const vign_strength = f32(0.3)

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

// Corrector - найденная пара камера+объектив. Указатели cam/lens живут
// внутри db, поэтому база держится открытой всё время жизни Corrector
// и освобождается только в free().
@[heap]
pub struct Corrector {
mut:
	db   &C.lfDatabase = unsafe { nil }
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

// find ищет профиль по строкам из EXIF (производитель и модель камеры,
// модель объектива). none - камеры или объектива нет в базе lensfun.
pub fn find(cam_maker string, cam_model string, lens_model string) ?&Corrector {
	if lens_model.len == 0 {
		return none
	}
	db := C.lf_db_new()
	if isnil(db) {
		return none
	}
	C.lf_db_load(db)

	// LibRaw отдаёт make='Canon', model='EOS R8', а в базе lensfun модель
	// полная ('Canon EOS R8') - матчеру нужно, чтобы запрос покрывал её
	// целиком, поэтому вторая попытка с приклеенным производителем
	// (тот же приём у darktable).
	mut cam := find_camera(db, cam_maker, cam_model)
	if isnil(cam) {
		cam = find_camera(db, cam_maker, '${cam_maker} ${cam_model}')
	}
	if isnil(cam) {
		C.lf_db_destroy(db)
		return none
	}

	lenses := C.lf_db_find_lenses_hd(db, cam, unsafe { nil }, lens_model.str, 0)
	if isnil(lenses) || isnil(unsafe { lenses[0] }) {
		C.lf_free(lenses)
		C.lf_db_destroy(db)
		return none
	}
	lf_lens := unsafe { &C.lfLens(lenses[0]) }
	C.lf_free(lenses)

	return &Corrector{
		db:        db
		cam:       cam
		lens:      lf_lens
		crop:      cam.CropFactor
		lens_name: unsafe { cstring_to_vstring(lf_lens.Model) }
	}
}

// vignetting компенсирует виньетирование в линейном RGB-буфере u16
// (w*h пикселей, плотная укладка, как отдаёт raw.DevImage.data_u16()).
// Правка на месте. false - в профиле нет данных виньетирования
// (или они не покрывают эти focal/aperture).
//
// Почему через карту усиления, а не прямое применение к u16: у части
// профилей полином виньетирования вырождается на крайних пикселях угла
// (уходит в ноль и минус - у RF 24-50 проверено), прямая коррекция там
// даёт чёрные углы. Поэтому усиление снимается в f32-буфер, вырожденные
// значения замещаются максимальным корректным, умножаем сами.
pub fn (c &Corrector) vignetting(buf &u16, w int, h int, focal f32, aperture f32) bool {
	if isnil(c.lens) || w <= 0 || h <= 0 {
		return false
	}
	// Диафрагма бывает не записана (мех. объективы) - берём среднюю
	ap := if aperture > 0.1 { aperture } else { f32(8.0) }
	m := C.lf_modifier_new(c.lens, c.crop, w, h)
	if isnil(m) {
		return false
	}
	// distance: расстояние до объекта из EXIF почти никогда не доступно,
	// 1000 м - стандартный дефолт (влияние на виньетку минимально).
	// scale 1.0 = без масштабирования (0.0 включило бы авто-масштаб).
	got := C.lf_modifier_initialize(m, c.lens, lf_pf_f32, focal, ap, 1000.0, 1.0,
		lf_rectilinear, lf_modify_vignetting, 0)
	if got & lf_modify_vignetting == 0 {
		C.lf_modifier_destroy(m)
		return false
	}
	// Карта усиления: коррекция единичного буфера = 1/затемнение
	mut gain := []f32{len: w * h, init: 1.0}
	ok := C.lf_modifier_apply_color_modification(m, gain.data, 0.0, 0.0, w, h,
		lf_cr_intensity, w * int(sizeof(f32)))
	C.lf_modifier_destroy(m)
	if ok == 0 {
		return false
	}
	unsafe {
		mut p := buf
		mut gp := &f32(gain.data)
		for _ in 0 .. w * h {
			mut g := *gp
			if !(g > 0 && g <= gain_cap) { // ловит и NaN/inf/отрицательные
				g = gain_cap
			}
			// Смягчение в лог-домене: g^strength, strength<1 - против
			// перекоррекции вырожденных профилей (см. vign_strength).
			// g >= 1 по построению профиля lensfun (карта - усиление,
			// не затемнение), поэтому powf монотонна и результат >= 1.
			g = math.powf(g, vign_strength)
			for k in 0 .. 3 {
				v := f32(p[k]) * g
				p[k] = if v > 65535.0 { u16(65535) } else { u16(v) }
			}
			p += 3
			gp += 1
		}
	}
	return true
}

// bilinear - выборка канала ch из плотного RGB-буфера u16 в дробной
// точке (x, y) с билинейной интерполяцией; координаты вне кадра
// прижимаются к краю.
@[inline]
fn bilinear(s &u16, w int, h int, ch int, x f32, y f32) u16 {
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
	unsafe {
		p00 := f32(s[(y0 * w + x0) * 3 + ch])
		p10 := f32(s[(y0 * w + x1) * 3 + ch])
		p01 := f32(s[(y1 * w + x0) * 3 + ch])
		p11 := f32(s[(y1 * w + x1) * 3 + ch])
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
	if isnil(c.lens) || w <= 0 || h <= 0 {
		return false
	}
	m := C.lf_modifier_new(c.lens, c.crop, w, h)
	if isnil(m) {
		return false
	}
	// Диафрагма и дистанция на геометрию не влияют - ставим типовые.
	got := C.lf_modifier_initialize(m, c.lens, lf_pf_f32, focal, 8.0, 1000.0, 0.0,
		lf_rectilinear, lf_modify_distortion | lf_modify_tca, 0)
	if got & (lf_modify_distortion | lf_modify_tca) == 0 {
		C.lf_modifier_destroy(m)
		return false
	}
	// Ремап читает произвольные точки источника - нужна его копия.
	mut src := []u16{len: w * h * 3}
	unsafe { vmemcpy(src.data, buf, u64(w) * u64(h) * 3 * 2) }
	// Координаты построчно (на весь кадр сразу было бы w*h*24 байт -
	// сотни МБ на полном кадре): по 3 пары (x,y) на пиксель - R, G, B.
	mut coords := []f32{len: w * 2 * 3}
	sp := unsafe { &u16(src.data) }
	unsafe {
		mut dst := buf
		for y in 0 .. h {
			if C.lf_modifier_apply_subpixel_geometry_distortion(m, 0.0, f32(y), w, 1,
				&f32(coords.data)) == 0 {
				dst += w * 3
				continue
			}
			mut cp := &f32(coords.data)
			for _ in 0 .. w {
				for ch in 0 .. 3 {
					dst[ch] = bilinear(sp, w, h, ch, cp[0], cp[1])
					cp += 2
				}
				dst += 3
			}
		}
	}
	C.lf_modifier_destroy(m)
	return true
}

pub fn (mut c Corrector) free() {
	if !isnil(c.db) {
		C.lf_db_destroy(c.db)
		c.db = unsafe { nil }
		c.cam = unsafe { nil }
		c.lens = unsafe { nil }
	}
}
