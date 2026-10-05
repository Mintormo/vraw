module main

import pipeline

// own_live - живых буферов в реестре и их держателей
fn own_live() (int, int) {
	own_mu.@lock()
	n := own_refs.len
	mut r := 0
	for _, v in own_refs {
		r += v
	}
	own_mu.unlock()
	return n, r
}

// Ссылки: share добавляет держателя, drop отпускает; последний - буфер
// уходит из реестра. Массив сборщика share/drop не трогают.
fn test_own_refs() {
	n0, r0 := own_live()
	mut a := own_new[u16](1000)
	a[5] = 7
	mut b := share(a)
	n1, r1 := own_live()
	assert n1 == n0 + 1 && r1 == r0 + 2
	drop(mut a)
	assert a.len == 0 && b[5] == 7 // второй держатель - данные живы
	drop(mut b)
	n2, r2 := own_live()
	assert n2 == n0 && r2 == r0
	mut g := []u16{len: 10}
	_ := share(g)
	drop(mut g)
	n3, _ := own_live()
	assert n3 == n0
	mut c := own_clone[u8]([u8(1), 2, 3])
	assert c == [u8(1), 2, 3]
	drop(mut c)
}

// prep_compute: при любом наборе шагов итог и задание держат ровно свои
// ссылки - после отпускания итога и dev_linear реестр пуст
fn test_prep_ownership() {
	w, h := 64, 48
	n0, r0 := own_live()
	for redo in [true, false] {
		for nr in [f32(0), 30] {
			for dc in [f32(0), 50] {
				mut dev := own_new[u16](w * h * 3)
				for i in 0 .. dev.len {
					dev[i] = u16((i * 37) % 60000)
				}
				mut res := prep_compute(PrepJob{
					src:       share(dev)
					w:         w
					h:         h
					redo_lens: redo
					nr:        [f32(0), nr, nr, 0]!
					dc:        pipeline.Sharpen{
						dc_amount: dc
					}
				})
				assert res.linear.len == w * h * 3 && res.mask.len == w * h
				assert (res.raw_linear.len > 0) == redo
				drop(mut res.raw_linear)
				drop(mut res.linear)
				drop(mut res.mask)
				drop(mut dev)
				n, r := own_live()
				assert n == n0 && r == r0, 'redo ${redo} nr ${nr} dc ${dc}: ${n - n0} буферов'
			}
		}
	}
}
