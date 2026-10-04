module bigbuf

import os

fn test_alloc_and_free() {
	mut a := new_f32(1000)
	assert a.len == 1000
	assert is_big(a)
	assert a[0] == 0 && a[999] == 0
	a[5] = 2.5
	assert a[5] == 2.5
	c := a.clone() // обычный массив сборщика
	assert !is_big(c) && c[5] == 2.5
	free(mut a)
	assert a.len == 0
	// пустой и обычный массивы: free не трогает чужую память
	mut e := new_u16(0)
	assert !is_big(e)
	free(mut e)
	mut g := []u8{len: 10}
	assert !is_big(g)
	free(mut g)
	assert g.len == 0
}

// Память возвращается системе: 10 раз по 200 МБ (все страницы тронуты)
// без роста RSS
fn test_returns_memory() {
	before := rss_mb()
	for _ in 0 .. 10 {
		mut b := new_u8(200 << 20)
		for i := 0; i < b.len; i += 4096 {
			b[i] = 1
		}
		free(mut b)
	}
	assert rss_mb() - before < 20
}

fn rss_mb() int {
	s := os.read_file('/proc/self/status') or { return 0 }
	for l in s.split_into_lines() {
		if l.starts_with('VmRSS:') {
			return l.all_after(':').trim_space().all_before(' ').int() / 1024
		}
	}
	return 0
}
