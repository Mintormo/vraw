module ai

import math
import os

// Плитки покрывают ось целиком, первая с 0, последняя вровень с краем,
// шаг не больше tile - overlap
fn test_positions() {
	assert positions(100) == [0]
	assert positions(256) == [0]
	for n in [257, 300, 480, 481, 1999, 2999, 5999] {
		p := positions(n)
		assert p[0] == 0
		assert p.last() == n - tile
		for i in 1 .. p.len {
			assert p[i] - p[i - 1] <= tile - overlap
			assert p[i] > p[i - 1]
		}
	}
}

// Сумма весов плиток в каждой точке оси - 1 (иначе швы и сдвиг яркости)
fn test_axis_weights_sum_to_one() {
	for n in [200, 257, 300, 481, 1999] {
		pos := positions(n)
		wts := axis_weights(pos, n)
		mut sum := []f32{len: n}
		for i, p in pos {
			for u in 0 .. tile {
				if p + u < n {
					assert wts[i][u] > 0
					sum[p + u] += wts[i][u]
				}
			}
		}
		for x in 0 .. n {
			assert math.abs(sum[x] - 1) < 1e-5
		}
	}
}

// Таблицы гаммы взаимно обратны (с точностью квантования u16)
fn test_srgb_roundtrip() {
	fwd, inv := srgb_luts()
	for v in [0, 1, 10, 100, 1000, 10000, 30000, 65535] {
		back := inv[int(fwd[v] * 65535 + 0.5)]
		assert math.abs(int(back) - v) <= 1 + v / 2000
	}
}

fn test_blend() {
	mut a := [u16(1000), 2000, 0]
	blend(unsafe { &u16(a.data) }, [u16(3000), 2000, 100], 0.5)
	assert a == [u16(2000), 2000, 50]
	blend(unsafe { &u16(a.data) }, [u16(7), 8, 9], 1)
	assert a == [u16(7), 8, 9]
}

// CallCount - прогресс шумодава: считает вызовы
struct CallCount {
mut:
	n int
}

fn (mut c CallCount) step(done int, total int) bool {
	c.n++
	assert done <= total
	return true
}

// StopAtOnce - прогресс, отменяющий шумодав после первой плитки
struct StopAtOnce {}

fn (mut s StopAtOnce) step(_ int, _ int) bool {
	return false
}

// lcg - детерминированный шум для теста
fn lcg(s u32) u32 {
	return s * 1664525 + 1013904223
}

// Каталог: модель - граф .onnx и веса, размеры известны (по ним installed)
fn test_catalog() {
	assert model.files.len > 0
	assert model.files[0].name.ends_with('.onnx')
	assert model.tile_secs > 0
	for f in model.files {
		assert f.size > 0
	}
	// В пустой папке ничего не установлено
	p := places(os.join_path(os.temp_dir(), 'vraw_ai_empty'))
	assert !model.installed(p)
	assert runtime_lib(p) == ''
}

// Настоящая модель (models/ проекта, ORT - в onnxruntime/: tools/fetch_ai.sh)
// на шумном градиенте нечётного размера (две плитки по каждой оси, край
// дополняется): шум падает в разы, средний уровень и градиент сохраняются,
// отмена работает. Без ORT или моделей - пропуск.
fn test_denoise_real_model() ! {
	p := places(@VMODROOT)
	lib := runtime_lib(p)
	if lib == '' {
		eprintln('нет ONNX Runtime в ${p.runtime}, пропуск')
		return
	}
	if !model.installed(p) {
		eprintln('нет модели в ${p.models}, пропуск')
		return
	}
	check_model(model, new_cache(model.path(p), lib))!
}

fn check_model(info ModelInfo, cache &Cache) ! {
	mut c := unsafe { cache }
	m := c.get() or { panic('${info.id}: ${err}') }
	w, h := 301, 270
	mut src := []u16{len: w * h * 3}
	mut clean := []f32{len: w * h * 3}
	mut s := u32(12345)
	for y in 0 .. h {
		for x in 0 .. w {
			base := 4000 + 20000 * f32(x) / f32(w)
			for ch in 0 .. 3 {
				s = lcg(s)
				noise := (f32(s >> 16) / 65536 - 0.5) * 3000
				i := (y * w + x) * 3 + ch
				clean[i] = base
				src[i] = u16(math.max(0, base + noise))
			}
		}
	}
	// Счётчик - по указателю: замыкание захватывает значения копией
	mut calls := CallCount{}
	out := denoise(m, unsafe { &u16(src.data) }, w, h, mut calls)!
	assert calls.n == tile_count(w, h)
	assert calls.n == 4
	mut err_in := f64(0)
	mut err_out := f64(0)
	mut mean_in := f64(0)
	mut mean_out := f64(0)
	for i in 0 .. src.len {
		err_in += math.pow(f64(src[i]) - clean[i], 2)
		err_out += math.pow(f64(out[i]) - clean[i], 2)
		mean_in += src[i]
		mean_out += out[i]
	}
	assert err_out * 4 < err_in, info.id // шум (СКО от чистого) - вдвое меньше и сильнее
	assert math.abs(mean_out - mean_in) / mean_in < 0.03
	// Градиент слева направо сохранился
	left := out[(h / 2 * w + 10) * 3 + 1]
	right := out[(h / 2 * w + w - 10) * 3 + 1]
	assert right > left + 10000
	// Отмена после первой плитки
	mut stop := StopAtOnce{}
	denoise(m, unsafe { &u16(src.data) }, w, h, mut stop) or {
		assert err is Cancelled
		c.free()
		return
	}
	assert false, 'отмена не сработала'
}

