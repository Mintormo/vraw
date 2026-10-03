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
		path: path
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
	if !isnil(c) {
		c.vignetting(pb, src.w, src.h, src.meta.focal, src.meta.aperture, vign)
		c.geometry(pb, src.w, src.h, src.meta.focal)
	}
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

fn test_detail_matches_full() {
	src, db := detail_case() or { return }
	c := db.find(src.meta.cam_make, src.meta.cam_model, src.meta.lens) or {
		eprintln('ПРОПУСК: профиль объектива не найден')
		return
	}
	vign := f32(0.5)
	mut ln := make_detail_lens(c, src, vign)
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
		got := detail_prep(src, ln, DetailJob{ ...job0, r: r })
		t_frag := sw.elapsed().milliseconds()
		d := detail_diff(got, full, ow, r)
		eprintln('фрагмент ${r.w}x${r.h} в (${r.x}, ${r.y}): расхождение ${d}, ${t_frag} мс (полный кадр ${ow}x${oh} - ${t_full} мс)')
		assert d <= 1, 'r=${r} расхождение ${d}'
	}
	ln.free()
}

fn test_detail_no_lens() {
	src, _ := detail_case() or { return }
	job := DetailJob{
		geom: pipeline.Geom{
			rot90: 1
		}
		nr:   [f32(0), 30, 30, 0]!
		r:    Region{100, 200, 300, 250}
	}
	full, ow, _ := detail_full(src, unsafe { nil }, 0, job)
	got := detail_prep(src, unsafe { nil }, job)
	assert detail_diff(got, full, ow, job.r) <= 1
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
		haze:          30
		dither:        false
	}
	// Полный проход: маска и дымка по полному кадру
	mask_full := pipeline.blur_luma(unsafe { &u16(full.data) }, ow, oh)
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
	gmask := pipeline.blur_luma(unsafe { &u16(small.data) }, gw, gh)
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
