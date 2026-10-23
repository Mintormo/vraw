module main

import os
import time
import math
import raw
import pipeline

// Синтетический кадр: люма лог-равномерно от lo до hi (линейно 0..1),
// серый, n пикселей; mask - его «размытая» люма (здесь - сама люма)
fn at_scene(n int, lo f64, hi f64) ([]u16, []u16) {
	mut src := []u16{len: n * 3}
	mut mask := []u16{len: n}
	for i in 0 .. n {
		t := f64(i) / f64(n - 1)
		v := u16(math.min(65535.0, lo * math.pow(hi / lo, t) * 65535.0))
		src[i * 3], src[i * 3 + 1], src[i * 3 + 2] = v, v, v
		mask[i] = v
	}
	return src, mask
}

// at_median - медиана люмы результата с подобранным тоном
fn at_median(src []u16, mask []u16, n int, t ToneSet) f32 {
	p := t.put(pipeline.Params{
		dither: false
	})
	mut pr := new_probe(src, mask, n)
	return pr.measure(p, Metric{ q2: 0.5 })
}

fn test_auto_tone_dark_scene() {
	n := 40000
	// Недодержка на 3 EV: всё не ярче 10% линейно
	src, mask := at_scene(n, 0.005, 0.1)
	t := auto_tone(src, mask, n, pipeline.Params{})
	assert t.exposure > 1.5, '${t}'
	med := at_median(src, mask, n, t)
	assert math.abs(med - at_mid) < 8, 'медиана ${med}, ${t}'
}

fn test_auto_tone_flat_scene() {
	n := 40000
	// Блёклый кадр (туман): узкий диапазон яркостей
	src, mask := at_scene(n, 0.12, 0.25)
	t := auto_tone(src, mask, n, pipeline.Params{})
	assert t.contrast > 0, '${t}'
	// Чёрная точка опущена - туман не начинается с серого
	assert t.blacks < 0, '${t}'
}

fn test_auto_tone_clipped_ignored() {
	n := 40000
	// Половина кадра клипнута в сырье: света по ней не приглушаются
	mut src, mask := at_scene(n, 0.002, 0.2)
	for i in n / 2 .. n {
		src[i * 3], src[i * 3 + 1], src[i * 3 + 2] = 65535, 65535, 65535
	}
	t := auto_tone(src, mask, n, pipeline.Params{})
	assert t.sh_highlights == 0, '${t}'
}

fn test_auto_tone_empty() {
	t := auto_tone([]u16{}, []u16{}, 0, pipeline.Params{})
	assert t == ToneSet{}
}

// Настоящий кадр: подбор укладывается в доли секунды, медиана - у цели
fn test_auto_tone_cr3() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('ПРОПУСК: нет IMG_0991.CR3')
		return
	}
	mut d := raw.open(path) or { panic(err) }
	defer {
		d.close()
	}
	mut img := d.develop(half: true) or { panic(err) }
	defer {
		img.free()
	}
	n := img.width * img.height
	mut src := []u16{len: n * 3}
	unsafe { vmemcpy(src.data, img.data_u16(), n * 6) }
	mask := pipeline.luma_masks(unsafe { &u16(src.data) }, img.width, img.height)
	sw := time.new_stopwatch()
	t := auto_tone(src, mask, n, pipeline.Params{})
	ms := sw.elapsed().milliseconds()
	eprintln('автотон IMG_0991: ${t}, ${ms} мс')
	med := at_median(src, mask, n, t)
	assert math.abs(med - at_mid) < 8, 'медиана ${med}'
}
