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
const lf_modify_scale = 0x20 // LF_MODIFY_SCALE - без него scale в initialize игнорируется
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
		mut p := &u16(buf)
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
	mut m := c.geometry_modifier(w, h, focal, 0.0) or { return false }
	// Авто-масштаб lensfun приблизительный (так и сказано в lensfun.h):
	// бывает чуть меньше нужного, и край кадра берёт точки за пределами
	// источника - после клампа это 3-4 повторённых крайних столбца.
	// Меряем вылет по рамке кадра и доувеличиваем масштаб (обычно
	// хватает одного шага, второй - страховка).
	for _ in 0 .. 2 {
		over := border_overflow(m, w, h)
		if over <= 1.0 {
			break
		}
		scale := C.lf_modifier_get_auto_scale(m, 0) * over * 1.001
		C.lf_modifier_destroy(m)
		m = c.geometry_modifier(w, h, focal, scale) or { return false }
	}
	// Ремап читает произвольные точки источника - нужна его копия.
	mut src := []u16{len: w * h * 3}
	unsafe { vmemcpy(src.data, buf, u64(w) * u64(h) * 3 * 2) }
	// Координаты построчно (на весь кадр сразу было бы w*h*24 байт -
	// сотни МБ на полном кадре): по 3 пары (x,y) на пиксель - R, G, B.
	mut coords := []f32{len: w * 2 * 3}
	sp := unsafe { &u16(src.data) }
	unsafe {
		mut dst := &u16(buf)
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
