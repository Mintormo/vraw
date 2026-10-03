module main

// Настоящий 1:1: превью - half-size, а при увеличении больше 50% поверх
// него показывается фрагмент ПОЛНОГО кадра. Фрагмент считается той же
// цепочкой, что экспорт (develop_full), но только в своём прямоугольнике:
// объектив (виньетирование, дисторсия + TCA) -> импульсы -> шумодав ->
// ореолы -> Capture-резкость -> кадрирование и поворот. Тон, кривые, HSL,
// резкость - финальный проход по готовому фрагменту (дёшево, на каждый
// ползунок). Маска «Тени/Света» и карта дымки гладкие - берутся из превью
// с увеличением (pipeline.upsample_region, haze_region).
//
// Здесь - только расчёт, без State и vgui: выполняется в фоне.
import raw
import lens
import pipeline { Region }

// Запас вокруг фрагмента для фильтров с окрестностью (вейвлет шумодава
// ~30 px, ореолы ~7, Capture-резкость - итерационная, затухает): внутри
// фрагмента результат равен полному проходу (detail_test.v).
const detail_margin = 96

// DetailSrc - сырьё полного кадра для фрагментов: выход LibRaw полного
// размера (как у экспорта), один на кадр и режим пересветов.
@[heap]
struct DetailSrc {
	path      string
	highlight int
	w         int
	h         int
	dev       []u16 // w x h RGB
	meta      raw.Meta
}

// load_detail_src - полный кадр из файла (~0.6 с): свой LibRaw, годится для
// фонового потока
fn load_detail_src(path string, highlight int) !&DetailSrc {
	mut d := raw.open(path)!
	defer {
		d.close()
	}
	mut img := d.develop(highlight: highlight)!
	defer {
		img.free()
	}
	n := img.width * img.height * 3
	mut dev := []u16{len: n}
	unsafe { vmemcpy(dev.data, img.data_u16(), n * 2) }
	return &DetailSrc{
		path:      path
		highlight: highlight
		w:         img.width
		h:         img.height
		dev:       dev
		meta:      d.meta()
	}
}

// DetailLens - объектив полного кадра: профиль виньетирования (сила vign)
// и план дисторсии + TCA. Один на кадр и настройки объектива; пустой -
// без коррекции (выключена, нет профиля или данных в нём).
@[heap]
struct DetailLens {
	vign f32
	lut  []f32 // пусто - без виньетирования
mut:
	plan &lens.GeomPlan = unsafe { nil } // nil - без дисторсии
}

fn make_detail_lens(c &lens.Corrector, src &DetailSrc, vign f32) &DetailLens {
	if isnil(c) {
		return &DetailLens{
			vign: vign
		}
	}
	lut := c.vign_lut(src.w, src.h, src.meta.focal, src.meta.aperture, vign) or { []f32{} }
	plan := c.geometry_plan(src.w, src.h, src.meta.focal) or { unsafe { nil } }
	return &DetailLens{
		vign: vign
		lut:  lut
		plan: plan
	}
}

fn (mut l DetailLens) free() {
	if !isnil(l.plan) {
		mut p := l.plan
		p.free()
		l.plan = unsafe { nil }
	}
}

// DetailJob - что считать: прямоугольник r выхода (кадр после
// кадрирования и поворота, полный размер) и настройки подготовки сырья
struct DetailJob {
	r      Region
	geom   pipeline.Geom // out_geom кадра
	nr     [4]f32
	dc     pipeline.Sharpen
	margin int = detail_margin
}

// detail_prep - линейное сырьё фрагмента r.w x r.h RGB: то же, что та же
// область полного кадра после подготовки и геометрии (develop_full до
// pipeline.apply). ln - nil или пустой: без коррекции объектива.
fn detail_prep(src &DetailSrc, ln &DetailLens, job DetailJob) []u16 {
	w := src.w
	h := src.h
	// Кусок кадра (после объектива), из которого геометрия читает r, с
	// запасом для фильтров
	p := pipeline.geom_source_box(job.geom, w, h, true, job.r).expand(job.margin, w, h)
	mut buf := []u16{}
	has_lut := !isnil(ln) && ln.lut.len > 0
	if !isnil(ln) && !isnil(ln.plan) {
		// Дисторсия: кусок источника под p, виньетирование по нему, ремап
		sb := ln.plan.source_box(p)
		mut piece := pipeline.crop_region(unsafe { &u16(src.dev.data) }, w, 3, sb)
		if has_lut {
			lens.vign_apply_region(unsafe { &u16(piece.data) }, sb, w, h, ln.lut)
		}
		buf = []u16{len: p.w * p.h * 3}
		ln.plan.remap(unsafe { &u16(piece.data) }, sb, p, unsafe { &u16(buf.data) })
	} else {
		buf = pipeline.crop_region(unsafe { &u16(src.dev.data) }, w, 3, p)
		if has_lut {
			lens.vign_apply_region(unsafe { &u16(buf.data) }, p, w, h, ln.lut)
		}
	}
	pb := unsafe { &u16(buf.data) }
	if job.nr[0] > 0 {
		pipeline.impulse(pb, p.w, p.h, job.nr[0])
	}
	if job.nr[1] > 0 || job.nr[2] > 0 {
		pipeline.denoise(pb, p.w, p.h, job.nr[1], job.nr[2])
	}
	if job.nr[3] > 0 {
		pipeline.defringe(pb, p.w, p.h, job.nr[3])
	}
	lin := if job.dc.dc_amount > 0 {
		pipeline.deconvolve(pb, p.w, p.h, job.dc, 1.0)
	} else {
		buf
	}
	return pipeline.geom_apply_region(unsafe { &u16(lin.data) }, p, w, h, 3, job.geom, true,
		job.r)
}

// detail_render - финальный проход фрагмента (тон, кривые, HSL, дымка,
// резкость - pipeline.apply_image_view) в RGBA r.w x r.h. lin - сырьё
// фрагмента (detail_prep), r - его место в выходе ow x oh. Маска «Тени/
// Света» и карта дымки - превью (gmask и haze размера gw x gh), с
// увеличением: обе гладкие. Резкость - в пикселях полного кадра (scale 1).
fn detail_render(lin []u16, r Region, ow int, oh int, gmask []u16, gw int, gh int, haze &pipeline.HazeMap, p pipeline.Params, view pipeline.SharpView) []u8 {
	mut dst := []u8{len: r.w * r.h * 4}
	if lin.len != r.w * r.h * 3 {
		return dst
	}
	mask := if gmask.len == gw * gh {
		pipeline.upsample_region(gmask, gw, gh, 1, ow, oh, r)
	} else {
		[]u16{}
	}
	hz := pipeline.haze_region(haze, ow, oh, r)
	mp := if mask.len > 0 { unsafe { &u16(mask.data) } } else { unsafe { &u16(nil) } }
	pipeline.apply_image_view(unsafe { &u16(lin.data) }, mp, &hz, r.w, r.h, p, 1.0, view, mut
		dst, 4)
	return dst
}
