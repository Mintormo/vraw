module main

// Фоновое открытие кадра: окно не замирает при выборе снимка в ленте.
//
// Главный поток (open_file) делает только быстрое: raw.open (~1-6 мс),
// настройки и история из сайдкара, выделение в ленте - и запускает
// load_worker. Воркер:
//   1. встроенное превью камеры (thumb_min, у CR3 1620x1080, ~30 мс) ->
//      сразу на экран (on_preview): кадр виден мгновенно;
//   2. профиль объектива (в общей базе lensfun), проявка превью
//      LibRaw, коррекция объектива и маска (prep_compute, без шумодава),
//      камерная кривая по полному JPEG -> on_done.
// Шумодав из сайдкара досчитывает обычный фоновый request_prep уже после
// загрузки. Быстрое перелистывание: предыдущая загрузка отменяется
// флагом между этапами, её результат отбрасывается по file_gen (dev и
// corr освобождает главный поток - они принадлежат результату).
//
// Воркер владеет своим Developer (не делит его с GUI), пока не отдаст;
// профиль объектива ищется в общей базе st.lens_db (только чтение): во время загрузки st.dev = nil, st.dev_linear пуст - ползунки
// пишут настройки и историю, а пересчёты (проявка, подготовка, apply)
// сразу выходят. load_done сверяет итог с настройками на момент
// окончания и досчитывает разницу (как restore_edit).
import stbi
import vgui
import raw
import lens
import pipeline

struct LoadJob {
	gen       int
	dev       &raw.Developer = unsafe { nil }
	db        &lens.Database = unsafe { nil } // общая база lensfun (nil - без коррекции)
	highlight int
	lens_corr bool
	// Быстрое превью - сразу с геометрией кадра (кадрирование, поворот)
	// и размером итогового превью tw x th (0 - по размеру превью камеры):
	// если холст того же размера, зум и панорама не сбрасываются
	// (сравнение соседних кадров), картинка не прыгает после проявки
	geom pipeline.Geom
	tw   int
	th   int
	stop &StopFlag = unsafe { nil }
}

// LoadPreview - быстрое превью камеры (RGBA w x h) для показа до проявки
struct LoadPreview {
	gen int
	w   int
	h   int
	pix []u8
}

// LoadResult - итог загрузки. dev всегда внутри (даже при ошибке или
// отмене): закрывает или забирает его главный поток.
struct LoadResult {
	gen        int
	err        string // не пусто - кадр не проявился
	dev        &raw.Developer  = unsafe { nil }
	corr       &lens.Corrector = unsafe { nil }
	meta       raw.Meta
	highlight  int
	lens_corr  bool
	w          int
	h          int
	dev_linear []u16
	raw_linear []u16
	linear     []u16
	mask       []u16
	look       CamLook // камерная кривая и насыщенность; пусто - встроенного JPEG нет
}

// load_worker выполняется в spawn; результат - через app.post
fn load_worker(job LoadJob, mut app vgui.App, on_preview fn (LoadPreview), on_done fn (LoadResult)) {
	mut d := job.dev
	meta := d.meta()
	mut res := LoadResult{
		gen:       job.gen
		dev:       d
		meta:      meta
		highlight: job.highlight
		lens_corr: job.lens_corr
	}
	// 1. Быстрое превью
	if pv := quick_preview(mut d, job) {
		app.post(fn [on_preview, pv] () {
			on_preview(pv)
		})
	}
	if job.stop.stop {
		post_load(mut app, on_done, res)
		return
	}
	// 2. Профиль объектива, проявка, подготовка, камерная кривая
	res = LoadResult{
		...res
		corr: job.db.find(meta.cam_make, meta.cam_model, meta.lens) or { unsafe { nil } }
	}
	mut img := d.develop(half: true, highlight: job.highlight) or {
		res = LoadResult{
			...res
			err: 'Ошибка проявки: ${err.msg()}'
		}
		post_load(mut app, on_done, res)
		return
	}
	w := img.width
	h := img.height
	mut dev_linear := []u16{len: w * h * 3}
	unsafe { vmemcpy(dev_linear.data, img.data_u16(), w * h * 6) }
	img.free()
	if job.stop.stop {
		post_load(mut app, on_done, res)
		return
	}
	prep := prep_compute(PrepJob{
		gen:       job.gen
		src:       dev_linear.clone()
		w:         w
		h:         h
		redo_lens: true
		corr:      if job.lens_corr { res.corr } else { unsafe { nil } }
		focal:     meta.focal
		aperture:  meta.aperture
	})
	if job.stop.stop {
		post_load(mut app, on_done, res)
		return
	}
	res = LoadResult{
		...res
		w:          w
		h:          h
		dev_linear: dev_linear
		raw_linear: prep.raw_linear
		linear:     prep.linear
		mask:       prep.mask
		look:       camera_look(mut d, prep.linear, w * h)
	}
	post_load(mut app, on_done, res)
}

fn post_load(mut app vgui.App, on_done fn (LoadResult), res LoadResult) {
	app.post(fn [on_done, res] () {
		on_done(res)
	})
}

// quick_preview - встроенное превью камеры в ориентации кадра, RGBA;
// вписано в холст job.tw x job.th, если он задан
fn quick_preview(mut d raw.Developer, job LoadJob) ?LoadPreview {
	j := d.thumb_min(1000) or { return none }
	mut img := stbi.load_from_memory(j.data, j.len, desired_channels: 3) or { return none }
	defer {
		img.free()
	}
	fl := d.flip()
	ow := if fl & 4 != 0 { img.height } else { img.width }
	oh := if fl & 4 != 0 { img.width } else { img.height }
	src := unsafe { img.data.vbytes(img.width * img.height * 3) }
	pix := fit_thumb(src, img.width, img.height, fl, ow, oh)
	if job.tw <= 0 || job.th <= 0 || (job.geom.is_identity() && job.tw == ow && job.th == oh) {
		return LoadPreview{
			gen: job.gen
			w:   ow
			h:   oh
			pix: pix
		}
	}
	return LoadPreview{
		gen: job.gen
		w:   job.tw
		h:   job.th
		pix: pipeline.geom_rgba(pix, ow, oh, job.geom, true, job.tw, job.th)
	}
}

// CamLook - «как JPEG камеры» для кадра: тоновая кривая (match_curve) и
// множитель насыщенности (match_saturation). Производное, в сайдкар не
// пишется; включается флажком «как JPEG» (EditState.use_curve).
// Наименьший встроенный JPEG для «как JPEG» (300 x 200): на меньшем
// гистограммы и средние слишком шумные
const cam_look_min_px = 60000

struct CamLook {
	curve []f32 // пусто - встроенного JPEG нет
	sat   f32 = 1
}

// camera_look - «как JPEG» кадра: встроенный полный JPEG камеры против
// нейтральной проявки превью linear (npix пикселей): кривая -
// сопоставлением гистограмм, насыщенность - по средней цветности с этой
// кривой. Именно полный JPEG: у CR3 превью 1620x1080 обработано иначе.
// Камеры разные (Canon, Nikon, Sony...) и стили у них разные - поэтому
// всё по встроенному JPEG этого же кадра, а не константами; JPEG меньше
// cam_look_min_px пикселей (бывают крошечные превью) - без подбора.
fn camera_look(mut d raw.Developer, linear []u16, npix int) CamLook {
	tj := d.thumb() or { return CamLook{} }
	mut t := stbi.load_from_memory(tj.data, tj.len, desired_channels: 3) or { return CamLook{} }
	defer {
		t.free()
	}
	if t.width * t.height < cam_look_min_px {
		return CamLook{}
	}
	src := unsafe { &u16(linear.data) }
	curve := pipeline.match_curve(src, npix, t.data, t.width * t.height)
	return CamLook{
		curve: curve
		sat:   pipeline.match_saturation(src, npix, curve, t.data, t.width * t.height)
	}
}

// free_load - закрыть LibRaw отброшенного результата загрузки (профиль
// объектива - из общей базы, освобождать нечего)
fn free_load(res LoadResult) {
	if !isnil(res.dev) {
		mut d := res.dev
		d.close()
	}
}

fn wait_loads(mut st State) {
	if !isnil(st.load_stop) {
		mut s := st.load_stop
		s.stop = true
	}
	for t in st.load_threads {
		t.wait()
	}
	st.load_threads.clear()
}

// set_canvas_size - холст под новый размер (приём Canvas.load_from_surface);
// fit - вписать заново (новый кадр другого размера)
fn set_canvas_size(mut cv vgui.Canvas, w int, h int) {
	cv.width = w
	cv.height = h
	cv.pixels = []u8{len: w * h * 4}
	cv.destroy_texture()
	cv.dirty = true
	cv.fit_to_view()
}
