module raw

// Обёртка над LibRaw. Ключевое свойство для GUI: один Developer можно
// проявлять повторно с разными параметрами — libraw_unpack выполняется
// один раз, дальше меняются params и перезапускается dcraw_process.

#flag -lraw
#include <libraw/libraw.h>

// Объявляем только те поля C-структур, к которым обращаемся.
// Реальную раскладку C-компилятор берёт из заголовка libraw.
@[typedef]
pub struct C.libraw_output_params_t {
mut:
	half_size      int
	use_camera_wb  int
	no_auto_bright int
	bright         f32
	output_bps     int    // 8 или 16 бит на канал
	gamm           [6]f64 // гамма-кривая; [0]=1,[1]=1 - линейный выход
	highlight      int    // пересветы: 0 клип, 1 без клипа, 2 смешение, 3..9 реконструкция
}

@[typedef]
pub struct C.libraw_data_t {
mut:
	params C.libraw_output_params_t
}

@[typedef]
pub struct C.libraw_processed_image_t {
	height    u16
	width     u16
	colors    u16
	bits      u16
	data_size u32
	data      &u8
}

@[typedef]
pub struct C.libraw_iparams_t {
	make  [64]char
	model [64]char
}

@[typedef]
pub struct C.libraw_imgother_t {
	aperture  f32
	focal_len f32
}

@[typedef]
pub struct C.libraw_lensinfo_t {
	Lens [128]char
}

fn C.libraw_init(flags u32) &C.libraw_data_t
fn C.libraw_open_file(lr &C.libraw_data_t, path &char) int
fn C.libraw_unpack(lr &C.libraw_data_t) int
fn C.libraw_dcraw_process(lr &C.libraw_data_t) int
fn C.libraw_dcraw_make_mem_image(lr &C.libraw_data_t, errc &int) &C.libraw_processed_image_t
fn C.libraw_dcraw_clear_mem(img &C.libraw_processed_image_t)
fn C.libraw_close(lr &C.libraw_data_t)
fn C.libraw_get_iparams(lr &C.libraw_data_t) &C.libraw_iparams_t
fn C.libraw_get_lensinfo(lr &C.libraw_data_t) &C.libraw_lensinfo_t
fn C.libraw_get_imgother(lr &C.libraw_data_t) &C.libraw_imgother_t
fn C.libraw_unpack_thumb(lr &C.libraw_data_t) int
fn C.libraw_dcraw_make_mem_thumb(lr &C.libraw_data_t, errc &int) &C.libraw_processed_image_t
fn C.libraw_strerror(errorcode int) &char

fn err_text(code int) string {
	return unsafe { cstring_to_vstring(&char(C.libraw_strerror(code))) }
}

// Параметры проявки (аналоги ключей dcraw)
@[params]
pub struct DevParams {
pub mut:
	bright        f32 = 1.0 // яркость, 1.0 = как есть
	half          bool // проявка в половинном размере (быстрое превью)
	use_camera_wb bool = true // баланс белого из камеры (-w)
	// linear16: сырьё для собственного пайплайна - 16 бит на канал,
	// линейная гамма, без авто-яркости (bright игнорируется).
	linear16 bool
	// highlight: работа с пересветами (аналог dcraw -H).
	// 0 - клип (дефолт), 1 - без клипа, 2 - смешение (blend),
	// 3..9 - реконструкция (меньше - белее, больше - цветнее).
	highlight int
}

// Developer держит открытый RAW-файл и позволяет проявлять его
// многократно с разными параметрами.
@[heap]
pub struct Developer {
mut:
	lr       &C.libraw_data_t = unsafe { nil }
	unpacked bool
pub:
	path string
}

// Готовый 8-битный RGB-результат проявки. Владеет C-буфером LibRaw —
// после использования обязателен вызов free().
pub struct DevImage {
pub:
	width  int
	height int
	colors int
	bits   int // 8 или 16
mut:
	img &C.libraw_processed_image_t = unsafe { nil }
}

pub fn open(path string) !&Developer {
	lr := C.libraw_init(0)
	if isnil(lr) {
		return error('не удалось инициализировать LibRaw')
	}
	code := C.libraw_open_file(lr, path.str)
	if code != 0 {
		C.libraw_close(lr)
		return error('открытие «${path}»: ${err_text(code)}')
	}
	return &Developer{
		lr:   lr
		path: path
	}
}

pub fn (mut d Developer) develop(p DevParams) !DevImage {
	if isnil(d.lr) {
		return error('файл не открыт')
	}
	unsafe {
		d.lr.params.use_camera_wb = if p.use_camera_wb { 1 } else { 0 }
		d.lr.params.half_size = if p.half { 1 } else { 0 }
		d.lr.params.highlight = p.highlight
		if p.linear16 {
			d.lr.params.output_bps = 16
			d.lr.params.gamm[0] = 1.0
			d.lr.params.gamm[1] = 1.0
			d.lr.params.no_auto_bright = 1
			d.lr.params.bright = 1.0
		} else {
			// Дефолты dcraw: 8 бит, гамма BT.709, авто-яркость
			d.lr.params.output_bps = 8
			d.lr.params.gamm[0] = 1.0 / 2.4
			d.lr.params.gamm[1] = 12.92
			d.lr.params.no_auto_bright = 0
			d.lr.params.bright = p.bright
		}
	}
	if !d.unpacked {
		code := C.libraw_unpack(d.lr)
		if code != 0 {
			return error('распаковка RAW: ${err_text(code)}')
		}
		d.unpacked = true
	}
	code := C.libraw_dcraw_process(d.lr)
	if code != 0 {
		return error('проявка: ${err_text(code)}')
	}
	errc := 0
	img := C.libraw_dcraw_make_mem_image(d.lr, &errc)
	if errc != 0 || isnil(img) {
		return error('получение RGB-изображения: ${err_text(errc)}')
	}
	return DevImage{
		width:  int(img.width)
		height: int(img.height)
		colors: int(img.colors)
		bits:   int(img.bits)
		img:    img
	}
}

// Метаданные кадра для подбора профиля коррекции объектива (lensfun).
// Доступны сразу после open(), проявка не нужна.
pub struct Meta {
pub:
	cam_make  string
	cam_model string
	lens      string // модель объектива из EXIF, например 'RF24-50mm F4.5-6.3 IS STM'
	focal     f32    // фокусное, мм
	aperture  f32    // диафрагма (0, если не записана)
}

pub fn (d &Developer) meta() Meta {
	if isnil(d.lr) {
		return Meta{}
	}
	ip := C.libraw_get_iparams(d.lr)
	li := C.libraw_get_lensinfo(d.lr)
	ot := C.libraw_get_imgother(d.lr)
	return Meta{
		cam_make:  unsafe { cstring_to_vstring(&char(&ip.make[0])) }
		cam_model: unsafe { cstring_to_vstring(&char(&ip.model[0])) }
		lens:      unsafe { cstring_to_vstring(&char(&li.Lens[0])) }
		focal:     ot.focal_len
		aperture:  ot.aperture
	}
}

// thumb - встроенное в RAW превью камеры как поток байт JPEG (Canon кладёт
// полноразмерный JPEG с камерной обработкой). Копия, буфер LibRaw
// освобождается внутри. Проявка не нужна, достаточно open().
pub fn (mut d Developer) thumb() ![]u8 {
	if isnil(d.lr) {
		return error('файл не открыт')
	}
	code := C.libraw_unpack_thumb(d.lr)
	if code != 0 {
		return error('извлечение превью: ${err_text(code)}')
	}
	errc := 0
	img := C.libraw_dcraw_make_mem_thumb(d.lr, &errc)
	if errc != 0 || isnil(img) {
		return error('получение превью: ${err_text(errc)}')
	}
	defer {
		C.libraw_dcraw_clear_mem(img)
	}
	// Поле type в C-структуре недоступно (type - ключевое слово V),
	// поэтому JPEG распознаём по сигнатуре потока.
	if img.data_size < 4 || unsafe { img.data[0] } != 0xff || unsafe { img.data[1] } != 0xd8 {
		return error('встроенное превью - не JPEG')
	}
	mut out := []u8{len: int(img.data_size)}
	unsafe { vmemcpy(out.data, img.data, int(img.data_size)) }
	return out
}

pub fn (im &DevImage) data() &u8 {
	return im.img.data
}

// data_u16 - тот же буфер как 16-битные значения (только при bits == 16).
pub fn (im &DevImage) data_u16() &u16 {
	return unsafe { &u16(im.img.data) }
}

pub fn (mut im DevImage) free() {
	if !isnil(im.img) {
		C.libraw_dcraw_clear_mem(im.img)
		im.img = unsafe { nil }
	}
}

pub fn (mut d Developer) close() {
	if !isnil(d.lr) {
		C.libraw_close(d.lr)
		d.lr = unsafe { nil }
	}
	d.unpacked = false
}
