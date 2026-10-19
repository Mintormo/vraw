module main

// Настоящий 1:1 (detail.v): фрагмент, посчитанный по своему прямоугольнику
// с запасом, совпадает с той же областью полного прохода подготовки сырья
// (объектив, импульсы, шумодав, ореолы, Capture-резкость, геометрия - как
// develop_full). Для скорости «полный кадр» здесь - half-size проявка
// (код от размера не зависит). Без IMG_0991.CR3 или профиля - пропуск.
import os
import time
import raw
import lens
import ai
import pipeline { Region }

fn detail_case() ?(&DetailSrc, &lens.Database) {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('ПРОПУСК: нет IMG_0991.CR3')
		return none
	}
	mut d := raw.open(path) or { return none }
	defer {
		d.close()
	}
	mut img := d.develop(half: true) or { return none }
	defer {
		img.free()
	}
	n := img.width * img.height * 3
	mut dev := []u16{len: n}
	unsafe { vmemcpy(dev.data, img.data_u16(), n * 2) }
	db := lens.load_db() or { return none }
	return &DetailSrc{
		key:  path
		w:    img.width
		h:    img.height
		dev:  dev
		meta: d.meta()
	}, db
}

// detail_full - полный проход той же цепочкой, что develop_full
fn detail_full(src &DetailSrc, c &lens.Corrector, vign f32, job DetailJob) ([]u16, int, int) {
	mut buf := src.dev.clone()
	pb := unsafe { &u16(buf.data) }
	lens_full(pb, src.w, src.h, c, src.meta.focal, src.meta.aperture, vign, 1, job.man)
	if job.nr[0] > 0 {
		pipeline.impulse(pb, src.w, src.h, job.nr[0])
	}
	if job.nr[1] > 0 || job.nr[2] > 0 {
		pipeline.denoise(pb, src.w, src.h, job.nr[1], job.nr[2])
	}
	if job.nr[3] > 0 {
		pipeline.defringe(pb, src.w, src.h, job.nr[3])
	}
	lin := if job.dc.dc_amount > 0 {
		pipeline.deconvolve(pb, src.w, src.h, job.dc, 1.0)
	} else {
		buf
	}
	if job.spots.len > 0 {
		pipeline.spots_apply(unsafe { &u16(lin.data) }, Region{0, 0, src.w, src.h}, src.w,
			src.h, job.spots)
	}
	return pipeline.geom_apply(unsafe { &u16(lin.data) }, src.w, src.h, 3, job.geom, true)
}

// detail_diff - наибольшее расхождение фрагмента с областью полного прохода
fn detail_diff(got []u16, full []u16, ow int, r Region) int {
	want := pipeline.crop_region(unsafe { &u16(full.data) }, ow, 3, r)
	assert got.len == want.len
	mut m := 0
	for i in 0 .. got.len {
		d := int(got[i]) - int(want[i])
		m = if d > m { d } else if -d > m { -d } else { m }
	}
	return m
}

fn test_detail_matches_full() ! {
	src, db := detail_case() or { return }
	c := db.find(src.meta.cam_make, src.meta.cam_model, src.meta.lens) or {
		eprintln('ПРОПУСК: профиль объектива не найден')
		return
	}
	vign := f32(0.5)
	mut ln := make_detail_lens(c, src, vign, 1)
	assert ln.lut.len > 0
	assert !isnil(ln.plan)
	// Всё включено и поворот с кадрированием
	job0 := DetailJob{
		geom: pipeline.Geom{
			angle: 2.5
			x0:    0.05
			y0:    0.08
			x1:    0.97
			y1:    0.93
		}
		nr:   [f32(30), 40, 50, 40]!
		dc:   pipeline.Sharpen{
			dc_amount:   100
			dc_radius:   1.5
			dc_contrast: 10
		}
	}
	mut sw := time.new_stopwatch()
	full, ow, oh := detail_full(src, c, vign, job0)
	t_full := sw.elapsed().milliseconds()
	for r in [Region{ow / 3, oh / 3, 500, 400}, Region{0, 0, 300, 200},
		Region{ow - 400, oh - 300, 400, 300}] {
		sw.restart()
		mut np := ai.NoProgress{}
		got := detail_prep(src, ln, DetailJob{ ...job0, r: r }, DetailAi{})!
		t_frag := sw.elapsed().milliseconds()
		d := detail_diff(got, full, ow, r)
		eprintln('фрагмент ${r.w}x${r.h} в (${r.x}, ${r.y}): расхождение ${d}, ${t_frag} мс (полный кадр ${ow}x${oh} - ${t_full} мс)')
		assert d <= 1, 'r=${r} расхождение ${d}'
	}
	ln.free()
}

// Ручная коррекция объектива: поверх профиля и без него (lens_piece -
// ручной ремап из куска, исправленного профилем)
fn test_detail_manual_lens() ! {
	src, db := detail_case() or { return }
	man := lens.Manual{
		dist:     -30
		vign:     40
		vign_mid: 35
		ca_r:     25
		ca_b:     -40
	}
	job0 := DetailJob{
		geom: pipeline.Geom{
			angle: -1.5
			x0:    0.03
			y0:    0.02
			x1:    0.95
			y1:    0.97
		}
		nr:   [f32(0), 20, 20, 0]!
		man:  man
	}
	c := db.find(src.meta.cam_make, src.meta.cam_model, src.meta.lens) or { unsafe { nil } }
	for use_prof in [false, true] {
		if use_prof && isnil(c) {
			eprintln('ПРОПУСК части с профилем: профиль объектива не найден')
			continue
		}
		cc := if use_prof { c } else { unsafe { &lens.Corrector(nil) } }
		mut ln := if use_prof { make_detail_lens(c, src, 0.5, 1) } else { unsafe { &DetailLens(nil) } }
		full, ow, oh := detail_full(src, cc, 0.5, job0)
		for r in [Region{ow / 3, oh / 3, 400, 300}, Region{0, 0, 250, 200},
			Region{ow - 300, oh - 260, 300, 260}] {
			mut np := ai.NoProgress{}
			got := detail_prep(src, ln, DetailJob{ ...job0, r: r }, DetailAi{})!
			d := detail_diff(got, full, ow, r)
			assert d <= 1, 'профиль ${use_prof}, r=${r}: расхождение ${d}'
		}
		if use_prof {
			ln.free()
		}
	}
}

fn test_detail_no_lens() ! {
	src, _ := detail_case() or { return }
	job := DetailJob{
		geom: pipeline.Geom{
			rot90: 1
		}
		nr:   [f32(0), 30, 30, 0]!
		r:    Region{100, 200, 300, 250}
	}
	full, ow, _ := detail_full(src, unsafe { nil }, 0, job)
	mut np := ai.NoProgress{}
	got := detail_prep(src, unsafe { nil }, job, DetailAi{})!
	assert detail_diff(got, full, ow, job.r) <= 1
}

// Пятна: источник далеко за фрагментом (кусок расширяется до него),
// второе пятно - частично в фрагменте; с поворотом на 90° и шумодавом
fn test_detail_spots() ! {
	src, _ := detail_case() or { return }
	w := f32(src.w)
	h := f32(src.h)
	job := DetailJob{
		geom:  pipeline.Geom{
			rot90: 1
		}
		nr:    [f32(0), 30, 30, 0]!
		r:     Region{100, 200, 300, 250}
		spots: [
			pipeline.Spot{
				x:  0.5
				y:  0.5
				sx: 0.15
				sy: 0.2
				r:  0.03
			},
			pipeline.Spot{
				x:    0.4
				y:    0.45
				sx:   0.6
				sy:   0.8
				r:    0.04
				mode: .clone
			},
		]
	}
	full, ow, oh := detail_full(src, unsafe { nil }, 0, job)
	// Фрагмент - вокруг первого пятна (после поворота на 90° по часовой
	// точка (x, y) кадра - (h - y, x) выхода)
	cx := int(h - 0.5 * h)
	cy := int(0.5 * w)
	r := Region{cx - 150, cy - 120, 300, 240}
	assert r.x >= 0 && r.y >= 0 && r.x + r.w <= ow && r.y + r.h <= oh
	mut np := ai.NoProgress{}
	got := detail_prep(src, unsafe { nil }, DetailJob{ ...job, r: r }, DetailAi{})!
	assert detail_diff(got, full, ow, r) <= 1
	// Без пятен фрагмент другой - пятна действуют
	plain := detail_prep(src, unsafe { nil }, DetailJob{ ...job, r: r, spots: [] }, DetailAi{})!
	assert detail_diff(plain, full, ow, r) > 100
}

// Финальный проход фрагмента с маской и дымкой из «превью» (вдвое меньший
// кадр) против прохода по полному кадру с его собственными маской и
// картой дымки (как develop_full): почти то же самое
fn test_detail_render_close_to_full() {
	src, _ := detail_case() or { return }
	job := DetailJob{
		geom: pipeline.Geom{
			x0: 0.1
			x1: 0.9
		}
		r:    Region{600, 500, 400, 300}
	}
	full, ow, oh := detail_full(src, unsafe { nil }, 0, job)
	p := pipeline.Params{
		exposure:      0.3
		contrast:      0.2
		sh_shadows:    60
		sh_highlights: 40
		clarity:       60
		haze:          30
		dither:        false
	}
	// Полный проход: маска и дымка по полному кадру
	mask_full := pipeline.luma_masks(unsafe { &u16(full.data) }, ow, oh)
	haze_full := pipeline.haze_map(unsafe { &u16(full.data) }, ow, oh)
	mut ref := []u8{len: ow * oh * 4}
	pipeline.apply_image(unsafe { &u16(full.data) }, unsafe { &u16(mask_full.data) }, &haze_full,
		ow, oh, p, 1.0, mut ref, 4)
	// «Превью»: тот же кадр вдвое меньше (среднее 2x2) - маска и дымка
	gw := ow / 2
	gh := oh / 2
	mut small := []u16{len: gw * gh * 3}
	for y in 0 .. gh {
		for x in 0 .. gw {
			for c in 0 .. 3 {
				s := int(full[((2 * y) * ow + 2 * x) * 3 + c]) + full[((2 * y) * ow + 2 * x + 1) * 3 + c] +
					full[((2 * y + 1) * ow + 2 * x) * 3 + c] + full[((2 * y + 1) * ow + 2 * x + 1) * 3 + c]
				small[(y * gw + x) * 3 + c] = u16(s / 4)
			}
		}
	}
	gmask := pipeline.luma_masks(unsafe { &u16(small.data) }, gw, gh)
	ghaze := pipeline.haze_map(unsafe { &u16(small.data) }, gw, gh)
	lin := pipeline.crop_region(unsafe { &u16(full.data) }, ow, 3, job.r)
	got := detail_render(lin, job.r, ow, oh, gmask, gw, gh, &ghaze, p, .off)
	mut maxd := 0
	mut sum := 0
	for j in 0 .. job.r.h {
		for i in 0 .. job.r.w {
			for c in 0 .. 3 {
				a := int(got[(j * job.r.w + i) * 4 + c])
				b := int(ref[((job.r.y + j) * ow + job.r.x + i) * 4 + c])
				d := if a > b { a - b } else { b - a }
				maxd = if d > maxd { d } else { maxd }
				sum += d
			}
		}
	}
	mean := f64(sum) / f64(job.r.w * job.r.h * 3)
	eprintln('финальный проход фрагмента против полного: наибольшее ${maxd}, среднее ${mean:.3f} (8 бит)')
	assert maxd <= 4
	assert mean < 0.5
}

// Поддельная модель: выход зависит от всей плитки и места в ней
struct DtFakeModel {}

fn (f DtFakeModel) run(input []f32, mut output []f32, h int, w int) ! {
	n := h * w
	mut mean := f32(0)
	for v in input {
		mean += v
	}
	mean /= f32(input.len)
	for c in 0 .. 3 {
		for i in 0 .. n {
			output[c * n + i] = input[c * n + i] * (0.7 + 0.3 * mean) + f32(i % w % 5) * 0.002
		}
	}
}

// AI на фрагменте = экспорт: объектив по всему кадру, модель по всему
// кадру, смешение по силе, дальше как всегда. Фрагмент берёт кусок готового
// результата модели (как его считает кнопка AI) - и совпадает с полным
// проходом.
fn test_detail_ai_matches_full() ! {
	src, db := detail_case() or { return }
	c := db.find(src.meta.cam_make, src.meta.cam_model, src.meta.lens) or { return }
	vign := f32(0.5)
	mut ln := make_detail_lens(c, src, vign, 1)
	defer {
		ln.free()
	}
	job0 := DetailJob{
		geom: pipeline.Geom{
			angle: -1.5
		}
		nr:   [f32(0), 30, 30, 20]!
	}
	// Полный проход: объектив, модель, сила 60, шумодав, геометрия
	mut buf := src.dev.clone()
	pb := unsafe { &u16(buf.data) }
	c.vignetting(pb, src.w, src.h, src.meta.focal, src.meta.aperture, vign)
	c.geometry(pb, src.w, src.h, src.meta.focal)
	mut den := []u16{len: buf.len}
	mut np := ai.NoProgress{}
	ai.denoise_with(DtFakeModel{}, pb, src.w, src.h, mut den, mut np)!
	ai.blend(pb, den, 0.6)
	pipeline.denoise(pb, src.w, src.h, 30, 30)
	pipeline.defringe(pb, src.w, src.h, 20)
	full, ow, _ := pipeline.geom_apply(pb, src.w, src.h, 3, job0.geom, true)
	dai := DetailAi{
		full:     den
		fw:       src.w
		fh:       src.h
		strength: 60
	}
	for r in [Region{700, 400, 400, 300}, Region{0, 0, 300, 200}] {
		got := detail_prep(src, ln, DetailJob{ ...job0, r: r }, dai)!
		assert detail_diff(got, full, ow, r) == 0, '${r}'
	}
	// Результат другого размера - ошибка, а не мусор
	if _ := detail_prep(src, ln, DetailJob{ ...job0, r: Region{0, 0, 100, 100} }, DetailAi{
		...dai
		fw: src.w - 2
	})
	{
		assert false, 'чужой размер принят'
	}
}
