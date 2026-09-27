module ai

// Нейросетевой шумодав: модель ONNX (NAFNet-SIDD) через ONNX Runtime.
// Вход и выход - линейный 16-бит RGB, как везде в vraw; модель обучена
// на sRGB, поэтому внутри кадр переводится в sRGB-гамму и обратно.
// Кадр идёт плитками 256x256 с перекрытием 32 (модель тяжёлая - на
// плитке CPU работает быстрее всего; крупные плитки не влезают в кэш),
// швы сглаживаются весами, которые в сумме дают 1.
//
// ONNX Runtime - официальная сборка с GitHub в ~/soft/onnxruntime
// (в apt её нет); путь к библиотеке вшит в бинарник (rpath).
import math
import os
import sync

#flag -I $env('HOME')/soft/onnxruntime/include
#flag -L $env('HOME')/soft/onnxruntime/lib
#flag -Wl,-rpath,$env('HOME')/soft/onnxruntime/lib
#flag -lonnxruntime
#include "@VMODROOT/ai/ort_shim.h"

@[typedef]
struct C.VrModel {}

fn C.vr_model_open(path &char, err &char, err_len int) &C.VrModel
fn C.vr_model_run(m &C.VrModel, input &f32, output &f32, h int, w int, err &char, err_len int) int
fn C.vr_model_close(m &C.VrModel)

pub const model_name = 'nafnet_sidd_w32.onnx'
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
	return 'отменено'
}

// find_model - путь к файлу модели: папка models рядом с программой,
// затем ~/.local/share/vraw/models; пусто - не найдена
pub fn find_model() string {
	for dir in [os.join_path(os.dir(os.executable()), 'models'),
		os.join_path(os.home_dir(), '.local', 'share', 'vraw', 'models')] {
		p := os.join_path(dir, model_name)
		if os.is_file(p) {
			return p
		}
	}
	return ''
}

// load открывает модель (~1.5 с: разбор графа и оптимизация)
pub fn load(path string) !&Model {
	mut err := []u8{len: 512}
	m := C.vr_model_open(&char(path.str), unsafe { &char(err.data) }, err.len)
	if isnil(m) {
		return error('не удалось загрузить модель: ${unsafe { cstring_to_vstring(&char(err.data)) }}')
	}
	return &Model{
		ptr: m
	}
}

// run - один прогон: input и output по 3*h*w f32 (планарно R, G, B)
pub fn (m &Model) run(input []f32, mut output []f32, h int, w int) ! {
	mut err := []u8{len: 512}
	if C.vr_model_run(m.ptr, input.data, output.data, h, w, unsafe { &char(err.data) }, err.len) != 0 {
		return error('ошибка модели: ${unsafe { cstring_to_vstring(&char(err.data)) }}')
	}
}

pub fn (m &Model) free() {
	C.vr_model_close(m.ptr)
}

// Cache - модель, загружаемая один раз за запуск при первой надобности
// (превью и экспорт могут попросить её из разных потоков - под мьютексом).
// Ошибка загрузки запоминается: повторно не грузим.
@[heap]
pub struct Cache {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	model &Model      = unsafe { nil }
	err   string
pub:
	path string // пусто - модель не найдена
}

pub fn new_cache(path string) &Cache {
	return &Cache{
		path: path
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
	if c.path == '' {
		return error('модель ${model_name} не найдена')
	}
	if c.err != '' {
		return error(c.err)
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

// denoise - шумодав всего кадра: src - линейный RGB u16 (w*h*3, только
// чтение - указатель, чтобы экспорт не копировал полный кадр), результат -
// новый буфер того же вида. progress зовётся после каждой плитки (из этого
// же потока) с числом готовых и всего; false - отмена (ошибка Cancelled).
// Память: накопитель f32 на весь кадр (12 байт на пиксель).
pub fn denoise(m &Model, src &u16, w int, h int, progress fn (done int, total int) bool) ![]u16 {
	fwd, inv := srgb_luts()
	xs := positions(w)
	ys := positions(h)
	wx := axis_weights(xs, w)
	wy := axis_weights(ys, h)
	total := xs.len * ys.len
	plane := tile * tile
	mut input := []f32{len: 3 * plane}
	mut output := []f32{len: 3 * plane}
	mut acc := []f32{len: w * h * 3}
	mut done := 0
	for j, y0 in ys {
		for i, x0 in xs {
			// Плитка в sRGB, планарно; за краем кадра - повтор крайнего пикселя
			for ty in 0 .. tile {
				sy := math.min(y0 + ty, h - 1)
				for tx in 0 .. tile {
					sx := math.min(x0 + tx, w - 1)
					s := (sy * w + sx) * 3
					o := ty * tile + tx
					unsafe {
						input[o] = fwd[src[s]]
						input[plane + o] = fwd[src[s + 1]]
						input[2 * plane + o] = fwd[src[s + 2]]
					}
				}
			}
			m.run(input, mut output, tile, tile)!
			for ty in 0 .. tile {
				yy := y0 + ty
				if yy >= h {
					break
				}
				ky := wy[j][ty]
				for tx in 0 .. tile {
					xx := x0 + tx
					if xx >= w {
						break
					}
					k := ky * wx[i][tx]
					d := (yy * w + xx) * 3
					o := ty * tile + tx
					acc[d] += k * output[o]
					acc[d + 1] += k * output[plane + o]
					acc[d + 2] += k * output[2 * plane + o]
				}
			}
			done++
			if !progress(done, total) {
				return Cancelled{}
			}
		}
	}
	mut out := []u16{len: acc.len}
	for n, v in acc {
		g := if v <= 0 { 0 } else if v >= 1 { 65535 } else { int(v * 65535 + 0.5) }
		out[n] = inv[g]
	}
	return out
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
