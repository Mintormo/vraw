module ai

// Фрагмент из плиток кэша = та же область прохода по всему кадру, бит в
// бит. Модель - подделка: выход зависит от всей плитки (среднее) и от
// места в ней, так что ошибка в номерах плиток, весах или порядке
// сложения видна.
struct FakeModel {}

fn (f FakeModel) run(input []f32, mut output []f32, h int, w int) ! {
	n := h * w
	mut mean := f32(0)
	for v in input {
		mean += v
	}
	mean /= f32(input.len)
	for c in 0 .. 3 {
		for i in 0 .. n {
			x := i % w
			output[c * n + i] = input[c * n + i] * (0.8 + 0.2 * mean) + f32(x % 7) * 0.001
		}
	}
}

struct Counter {
mut:
	n    int
	stop int // отмена после stop плиток (0 - нет)
}

fn (mut c Counter) step(_ int, _ int) bool {
	c.n++
	return c.stop == 0 || c.n < c.stop
}

fn tt_frame(w int, h int) []u16 {
	mut a := []u16{len: w * h * 3}
	mut s := u32(99)
	for i in 0 .. a.len {
		s = s * 1664525 + 1013904223
		a[i] = u16((i / 3 % w) * 40 + int(s >> 22))
	}
	return a
}

fn tt_crop(a []u16, w int, r Rect) []u16 {
	mut o := []u16{len: r.w * r.h * 3}
	for y in 0 .. r.h {
		for x in 0 .. r.w * 3 {
			o[y * r.w * 3 + x] = a[((r.y + y) * w + r.x) * 3 + x]
		}
	}
	return o
}

fn test_tiles_match_denoise() {
	w, h := 701, 523
	src := tt_frame(w, h)
	mut whole := []u16{len: w * h * 3}
	mut np := NoProgress{}
	denoise_with(FakeModel{}, unsafe { &u16(src.data) }, w, h, mut whole, mut np)!
	mut c := new_tile_cache(w, h)
	defer {
		c.free()
	}
	for r in [Rect{0, 0, w, h}, Rect{100, 50, 300, 200}, Rect{450, 300, 251, 223},
		Rect{224, 224, 1, 1}] {
		t := c.grid.cover(r)
		win := c.grid.window(t)
		piece := tt_crop(src, w, win)
		mut cnt := Counter{}
		before := c.missing(t)
		c.fill(FakeModel{}, t, unsafe { &u16(piece.data) }, win, mut cnt)!
		assert cnt.n == before
		assert c.missing(t) == 0
		got := c.compose(r)!
		assert got == tt_crop(whole, w, r), '${r}'
	}
	// Второй раз - всё из кэша
	t := c.grid.cover(Rect{100, 50, 300, 200})
	assert c.missing(t) == 0
	// Вытеснение
	c.trim(3)
	assert c.len() == 3
}

fn test_tiles_cancel_keeps_done() {
	w, h := 600, 300
	src := tt_frame(w, h)
	mut c := new_tile_cache(w, h)
	defer {
		c.free()
	}
	r := Rect{0, 0, w, h}
	t := c.grid.cover(r)
	mut cnt := Counter{
		stop: 2
	}
	c.fill(FakeModel{}, t, unsafe { &u16(src.data) }, r, mut cnt) or {
		assert err is Cancelled
		assert c.len() == 2
		assert c.missing(t) == t.count() - 2
		if _ := c.compose(r) {
			assert false
		}
		return
	}
	assert false
}
