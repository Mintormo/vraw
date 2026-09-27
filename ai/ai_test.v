module ai

import math

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

struct CallCount {
mut:
	n int
}

// lcg - детерминированный шум для теста
fn lcg(s u32) u32 {
	return s * 1664525 + 1013904223
}

// Настоящая модель на шумном градиенте нечётного размера (две плитки по
// каждой оси, край дополняется): шум падает в разы, средний уровень и
// градиент сохраняются, отмена работает. Без модели - пропуск.
fn test_denoise_real_model() {
	path := find_model()
	if path == '' {
		eprintln('нет модели ${model_name}, пропуск')
		return
	}
	mut c := new_cache(path)
	m := c.get()!
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
	mut calls := &CallCount{}
	out := denoise(m, unsafe { &u16(src.data) }, w, h, fn [mut calls] (done int, total int) bool {
		calls.n++
		assert done <= total
		return true
	})!
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
	assert err_out * 4 < err_in // шум (СКО от чистого) - вдвое меньше и сильнее
	assert math.abs(mean_out - mean_in) / mean_in < 0.03
	// Градиент слева направо сохранился
	left := out[(h / 2 * w + 10) * 3 + 1]
	right := out[(h / 2 * w + w - 10) * 3 + 1]
	assert right > left + 10000
	// Отмена после первой плитки
	denoise(m, unsafe { &u16(src.data) }, w, h, fn (done int, total int) bool {
		return false
	}) or {
		assert err is Cancelled
		c.free()
		return
	}
	assert false, 'отмена не сработала'
}
