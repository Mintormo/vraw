module main

import os
import math
import raw
import lens

// Синтетический кадр w x h: сцена - пятна разной яркости (каждая яркость
// встречается на любом радиусе), ln усиления профиля растёт к краю
const vt_w = 300
const vt_h = 200

fn vt_scene(x int, y int) f64 {
	// Псевдослучайная яркость клеток 10x10 - 2000..30000
	k := u32((x / 10) * 7919 + (y / 10) * 104729)
	r := (k * 1103515245 + 12345) >> 8 & 0xffff
	return 2000.0 + 28000.0 * f64(r) / 65535.0
}

fn vt_lgain(x int, y int) f32 {
	cx := f64(vt_w - 1) / 2
	cy := f64(vt_h - 1) / 2
	r2 := ((x - cx) * (x - cx) + (y - cy) * (y - cy)) / (cx * cx + cy * cy)
	return f32(1.5 * r2)
}

// Регрессия восстанавливает силу: JPEG - гамма от сцены, скорректированной
// с силой 0.6 по известному профилю; наша копия - сцена без коррекции
fn test_vign_fit_synthetic() {
	n := vt_w * vt_h
	mut lin := []u16{len: n * 3}
	mut lg := []f32{len: n}
	mut ref_ := []u8{len: n * 3}
	for y in 0 .. vt_h {
		for x in 0 .. vt_w {
			i := y * vt_w + x
			sc := vt_scene(x, y)
			lg[i] = vt_lgain(x, y)
			for ch in 0 .. 3 {
				lin[i * 3 + ch] = u16(sc)
			}
			cam := sc * math.exp(0.6 * f64(lg[i])) / 65535.0
			t := 255.0 * math.pow(if cam > 1 { 1.0 } else { cam }, 1 / 2.2)
			for ch in 0 .. 3 {
				ref_[i * 3 + ch] = u8(t + 0.5)
			}
		}
	}
	mf := lens.MatchFrame{
		w:     vt_w
		h:     vt_h
		lin:   lin
		lgain: lg
	}
	vr := VignRef{
		ref_: ref_
		use:  []bool{len: n, init: true}
	}
	s := vr.fit(&mf) or {
		assert false, 'нет оценки'
		return
	}
	assert math.abs(s - 0.6) < 0.05, '${s}'
	// Ровное поле: усиление внутри корзин не разбросано - оценки нет
	flat := lens.MatchFrame{
		w:     vt_w
		h:     vt_h
		lin:   lin
		lgain: []f32{len: n}
	}
	if _ := vr.fit(&flat) {
		assert false, 'оценка без спада'
	}
}

// Совмещение: JPEG - тот же кадр, крупнее в 1.08 раза (камера
// кадрирует сильнее) - масштаб находится
fn test_align_zoom() {
	n := vt_w * vt_h
	mut ours := []f32{len: n}
	mut jpeg := []f32{len: n}
	cx := f32(vt_w - 1) / 2
	cy := f32(vt_h - 1) / 2
	z := f32(1.08)
	for y in 0 .. vt_h {
		for x in 0 .. vt_w {
			ours[y * vt_w + x] = f32(vt_scene(x, y))
			// Точка JPEG q показывает место сцены c + (q - c) / z
			sx := int(cx + (f32(x) - cx) / z + 0.5)
			sy := int(cy + (f32(y) - cy) / z + 0.5)
			jpeg[y * vt_w + x] = f32(vt_scene(sx, sy))
		}
	}
	got, ncc := align_zoom(ours, jpeg, vt_w, vt_h)
	assert math.abs(got - z) < 0.006, '${got}'
	assert ncc > 0.8
	same, c1 := align_zoom(ours, ours, vt_w, vt_h)
	assert math.abs(same - 1) < 0.002 && c1 > 0.99
}

// IMG_0817.CR3 (RF 24-50 на 24 мм, f/6.3): по JPEG камеры сила ~0.5 и
// увеличение кадра ~1.085
// (было 0.3 на все объективы - углы неба темнее, чем у камеры)
fn test_vign_match_file() {
	path := os.join_path(@VMODROOT, 'IMG_0817.CR3')
	if !os.exists(path) {
		eprintln('ПРОПУСК: нет IMG_0817.CR3')
		return
	}
	mut db := lens.load_db()!
	defer {
		db.free()
	}
	mut d := raw.open(path)!
	defer {
		d.close()
	}
	m := d.meta()
	corr := db.find(m.cam_make, m.cam_model, m.lens) or {
		eprintln('ПРОПУСК: профиль RF 24-50 не найден в базе lensfun')
		return
	}
	mut img := d.develop(half: true)!
	w := img.width
	h := img.height
	mut lin := []u16{len: w * h * 3}
	unsafe { vmemcpy(lin.data, img.data_u16(), w * h * 6) }
	img.free()
	mut cj := cam_jpeg(mut d)
	defer {
		if mut t := cj {
			t.free()
		}
	}
	lm := lens_match(cj, d.flip(), corr, lin, w, h, m)
	s := lm.vign
	assert s > 0.4 && s < 0.6, '${s}'
	// Кадр «как у камеры»: камера обрезает RF 24-50 на 24 мм на ~8.5%
	assert lm.zoom > 1.06 && lm.zoom < 1.11, '${lm.zoom}'
	// Без JPEG - сила по умолчанию
	assert lens_match(none, d.flip(), corr, lin, w, h, m) == LensMatch{}
}
