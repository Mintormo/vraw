module ai

// Нейросетевой шумодав: модель ONNX (SCUNet - в
// catalog.v) через ONNX Runtime.
// Вход и выход - линейный 16-бит RGB, как везде в vraw; модель обучена
// на sRGB, поэтому внутри кадр переводится в sRGB-гамму и обратно.
// Кадр идёт плитками 256x256 с перекрытием 32 (модель тяжёлая - на
// плитке CPU работает быстрее всего; крупные плитки не влезают в кэш),
// швы сглаживаются весами, которые в сумме дают 1.
//
// ONNX Runtime не линкуется: библиотека грузится dlopen при первом
// прогоне (load_runtime) из папки onnxruntime рядом с программой (её
// кладёт туда сборка). Нет библиотеки - vraw работает без AI.
import math
import sync
import bigbuf
import i18n

#flag -I @VMODROOT/ai/include
#flag linux -ldl
#include "@VMODROOT/ai/ort_shim.h"

@[typedef]
struct C.VrModel {}

fn C.vr_ort_load(path &char, err &char, err_len int) int
fn C.vr_model_open(path &char, err &char, err_len int) &C.VrModel
fn C.vr_model_run(m &C.VrModel, input &f32, output &f32, h int, w int, err &char, err_len int) int
fn C.vr_model_close(m &C.VrModel)

pub const tile = 256
pub const overlap = 32

// Model - открытая модель. run потокобезопасен (так устроен ORT Session),
// но vraw гоняет её из одного потока за раз.
@[heap]
pub struct Model {
	ptr &C.VrModel
}

// Cancelled - ошибка «отменено пользователем» (callback прогресса вернул false)
pub struct Cancelled {
	Error
}

pub fn (e Cancelled) msg() string {
	return i18n.tr('отменено')
}

// runtime_mu - загрузка библиотеки ORT один раз за процесс (превью и
// экспорт могут попросить её из разных потоков)
const runtime_mu = sync.new_mutex()

// load_runtime - загрузить ONNX Runtime по пути к библиотеке (runtime_lib)
// (повторный вызов после успеха - ничего не делает). Библиотека остаётся
// в памяти до конца процесса.
pub fn load_runtime(lib string) ! {
	runtime_mu.lock()
	defer {
		runtime_mu.unlock()
	}
	mut err := []u8{len: 512}
	if C.vr_ort_load(&char(lib.str), unsafe { &char(err.data) }, err.len) != 0 {
		return error(i18n.trf('не удалось загрузить ONNX Runtime: {0}', '${unsafe { cstring_to_vstring(&char(err.data)) }}'))
	}
}

// load открывает модель (~1.5 с: разбор графа и оптимизация)
pub fn load(path string) !&Model {
	mut err := []u8{len: 512}
	m := C.vr_model_open(&char(path.str), unsafe { &char(err.data) }, err.len)
	if isnil(m) {
		return error(i18n.trf('не удалось загрузить модель: {0}', '${unsafe { cstring_to_vstring(&char(err.data)) }}'))
	}
	return &Model{
		ptr: m
	}
}

// run - один прогон: input и output по 3*h*w f32 (планарно R, G, B)
pub fn (m &Model) run(input []f32, mut output []f32, h int, w int) ! {
	mut err := []u8{len: 512}
	if C.vr_model_run(m.ptr, input.data, output.data, h, w, unsafe { &char(err.data) }, err.len) != 0 {
		return error(i18n.trf('ошибка модели: {0}', '${unsafe { cstring_to_vstring(&char(err.data)) }}'))
	}
}

// Runner - то, что считает плитку (Model; в тестах - подделка)
pub interface Runner {
	run(input []f32, mut output []f32, h int, w int) !
}

pub fn (m &Model) free() {
	C.vr_model_close(m.ptr)
}

// Cache - модель, загружаемая один раз за запуск при первой надобности
// (превью и экспорт могут попросить её из разных потоков - под мьютексом),
// вместе с библиотекой ORT. Ошибка загрузки запоминается: повторно не
// грузим. На каждую модель каталога - свой Cache.
@[heap]
pub struct Cache {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	model &Model      = unsafe { nil }
	err   string
pub:
	path    string // файл модели .onnx
	runtime string // папка ONNX Runtime (библиотека - runtime_lib)
}

pub fn new_cache(path string, runtime string) &Cache {
	return &Cache{
		path:    path
		runtime: runtime
	}
}

pub fn (mut c Cache) get() !&Model {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	if !isnil(c.model) {
		return c.model
	}
	if c.err != '' {
		return error(c.err)
	}
	load_runtime(c.runtime) or {
		c.err = err.msg()
		return err
	}
	c.model = load(c.path) or {
		c.err = err.msg()
		return err
	}
	return c.model
}

// free - на выходе, после всех потоков, которые пользуются моделью
pub fn (mut c Cache) free() {
	if !isnil(c.model) {
		c.model.free()
		c.model = unsafe { nil }
	}
}

// positions - начала плиток по оси длины n: равномерно, шаг не больше
// tile - overlap, первая с 0, последняя вровень с краем. Кадр меньше
// плитки - одна плитка (недостающее дополняется повтором края).
fn positions(n int) []int {
	if n <= tile {
		return [0]
	}
	cnt := (n - overlap + tile - overlap - 1) / (tile - overlap)
	mut p := []int{len: cnt}
	for i in 0 .. cnt {
		p[i] = int(math.round(f64(i) * f64(n - tile) / f64(cnt - 1)))
	}
	return p
}

// axis_weights - веса плиток по оси: трапеция с линейными скатами длины
// overlap на внутренних краях, нормированная так, чтобы в каждой точке
// сумма весов всех плиток была 1. Вес пикселя - произведение весов по
// осям, поэтому и в 2D сумма равна 1 - буфер сумм весов не нужен.
fn axis_weights(pos []int, n int) [][]f32 {
	mut w := [][]f32{len: pos.len, init: []f32{len: tile}}
	mut cover := []f32{len: n}
	for i, p in pos {
		for u in 0 .. tile {
			mut v := f32(1)
			if i > 0 && u < overlap {
				v = (f32(u) + 0.5) / overlap
			}
			if i < pos.len - 1 && u >= tile - overlap {
				v = f32(math.min(v, (f32(tile - u) - 0.5) / overlap))
			}
			w[i][u] = v
			if p + u < n {
				cover[p + u] += v
			}
		}
	}
	for i, p in pos {
		for u in 0 .. tile {
			if p + u < n {
				w[i][u] /= cover[p + u]
			}
		}
	}
	return w
}

// srgb_luts - таблицы: линейное u16 -> sRGB 0..1 и sRGB (u16-шкала) -> линейное u16
fn srgb_luts() ([]f32, []u16) {
	mut fwd := []f32{len: 65536}
	mut inv := []u16{len: 65536}
	for i in 0 .. 65536 {
		x := f64(i) / 65535.0
		fwd[i] = f32(if x <= 0.0031308 { 12.92 * x } else { 1.055 * math.pow(x, 1.0 / 2.4) - 0.055 })
		l := if x <= 0.04045 { x / 12.92 } else { math.pow((x + 0.055) / 1.055, 2.4) }
		inv[i] = u16(math.min(65535.0, l * 65535.0 + 0.5))
	}
	return fwd, inv
}

// tile_count - сколько плиток будет у кадра w x h (для прогресса и оценок)
pub fn tile_count(w int, h int) int {
	return positions(w).len * positions(h).len
}

// Progress - получатель прогресса шумодава: step зовётся после каждой
// плитки (из потока шумодава) с числом готовых и всего; false - отмена.
// Интерфейс, а не замыкание: V не освобождает замыкания, а его таблица
// замыканий удерживает чужие буферы (PROJECT.md, «Замыкания и память»).
pub interface Progress {
mut:
	step(done int, total int) bool
}

// NoProgress - прогресс не нужен
pub struct NoProgress {}

pub fn (mut p NoProgress) step(_ int, _ int) bool {
	return true
}

// denoise - шумодав всего кадра: src - линейный RGB u16 (w*h*3, только
// чтение - указатель, чтобы экспорт не копировал полный кадр), результат -
// новый буфер того же вида. progress.step - после каждой плитки; false -
// отмена (ошибка Cancelled).
// Память: накопитель f32 на весь кадр (12 байт на пиксель).
pub fn denoise(m &Model, src &u16, w int, h int, mut progress Progress) ![]u16 {
	mut out := []u16{len: w * h * 3}
	denoise_into(m, src, w, h, mut out, mut progress)!
	return out
}

// denoise_into - то же в готовый буфер out (w * h * 3; экспорт даёт буфер
// вне сборщика - bigbuf). Плитки и их сложение - те же функции, что у
// фрагмента (tiles.v): фрагмент 1:1 совпадает с этим проходом бит в бит.
pub fn denoise_into(m &Model, src &u16, w int, h int, mut out []u16, mut progress Progress) ! {
	denoise_with(m, src, w, h, mut out, mut progress)!
}

pub fn denoise_with(m Runner, src &u16, w int, h int, mut out []u16, mut progress Progress) ! {
	g := new_grid(w, h)
	total := g.xs.len * g.ys.len
	mut input := []f32{len: 3 * tile * tile}
	mut output := []f32{len: 3 * tile * tile}
	// Накопитель - вне сборщика (bigbuf): на полном кадре 288 МБ
	mut acc := bigbuf.new_f32(w * h * 3)
	defer {
		bigbuf.free(mut acc)
	}
	frame := Rect{0, 0, w, h}
	mut done := 0
	for j in 0 .. g.ys.len {
		for i in 0 .. g.xs.len {
			g.fill_input(i, j, src, frame, mut input)
			m.run(input, mut output, tile, tile)!
			g.accumulate(i, j, output, mut acc, frame)
			done++
			if !progress.step(done, total) {
				return Cancelled{}
			}
		}
	}
	finish(acc, mut out)
}

// blend - смешение на месте: buf = buf + (den - buf) * strength (0..1).
// Сила AI-шумодава: 1 - чистый результат модели, меньше - часть исходного
// зерна возвращается (обычный приём, «пластиковость» уходит).
// buf - указатель на den.len значений.
pub fn blend(buf &u16, den []u16, strength f32) {
	unsafe {
		if strength >= 1 {
			vmemcpy(buf, den.data, den.len * 2)
			return
		}
		for i in 0 .. den.len {
			a := f32(buf[i])
			buf[i] = u16(a + (f32(den[i]) - a) * strength + 0.5)
		}
	}
}
