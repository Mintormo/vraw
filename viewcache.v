module main

// Кэш проявленных кадров на время работы программы: при уходе с кадра
// его картинка превью (холст, RGBA) запоминается; при возврате она сразу
// на экране вместо оверлея «Обработка», а фоновая загрузка (load_worker)
// идёт как обычно и по окончании незаметно подменяет её той же проявкой
// (ползунки до того только пишут правки). Картинка годится, только если
// правки кадра с тех пор те же (ключ - EditState без производных полей:
// сайдкар мог поменять пакет или вставка настроек). Последние
// view_cache_max кадров, буферы вне сборщика (bigbuf, ~24 МБ на кадр 24
// Мп), на диск не пишется.
import bigbuf
import lens
import pipeline

const view_cache_max = 8

struct ViewCache {
	path string
	key  EditState
	w    int
	h    int
mut:
	pix []u8 // bigbuf
}

// edit_key - правки без производных полей (with_derived): по ним и
// сравниваются снимки кэша
fn edit_key(e EditState) EditState {
	mut k := e.clone()
	k.params.curve = []f32{}
	k.params.cam_sat = 1
	k.params.cam_hue = []f32{}
	k.params.cam_hsat = []f32{}
	k.params.tc_rgb = []f32{}
	k.params.tc_r = []f32{}
	k.params.tc_g = []f32{}
	k.params.tc_b = []f32{}
	k.params.wb_on = false
	k.params.wb = pipeline.WbXform{}
	k.vign = lens.vign_default
	k.lens_zoom = 1
	return k
}

// cache_store - запомнить картинку открытого кадра (перед уходом с него).
// Только полностью загруженный кадр в обычном виде: не в кадрировании,
// не до/после, не JPEG камеры, не показ дымки или резкости, AI (если
// включён) уже посчитан.
fn cache_store(mut st State) {
	if isnil(st.cv) || st.loading || st.raw_path == '' || st.linear.len == 0 || st.crop_mode
		|| st.haze_show || st.sharp_show || ba_active(st) || jpeg_active(st)
		|| (st.edit.ai > 0 && st.ai_applied == 0) {
		return
	}
	cv := st.cv
	n := cv.width * cv.height * 4
	if cv.pixels.len != n || n == 0 {
		return
	}
	cache_drop(mut st, st.raw_path)
	mut pix := bigbuf.new_u8(n)
	unsafe { vmemcpy(pix.data, cv.pixels.data, n) }
	st.vcache << ViewCache{
		path: st.raw_path
		key:  edit_key(st.edit)
		w:    cv.width
		h:    cv.height
		pix:  pix
	}
	for st.vcache.len > view_cache_max {
		mut old := st.vcache[0]
		bigbuf.free(mut old.pix)
		st.vcache.delete(0)
	}
}

// cache_drop - забыть снимок кадра path (буфер - системе)
fn cache_drop(mut st State, path string) {
	for i := 0; i < st.vcache.len; i++ {
		if st.vcache[i].path == path {
			mut old := st.vcache[i]
			bigbuf.free(mut old.pix)
			st.vcache.delete(i)
			return
		}
	}
}

// cache_show - открытие кадра path (правки из сайдкара уже в st.edit):
// снимок с теми же правками - на холст и гистограмму, true; нет - false
// (тогда оверлей «Обработка»)
fn cache_show(mut st State, path string) bool {
	if isnil(st.cv) {
		return false
	}
	key := edit_key(st.edit)
	for i, c in st.vcache {
		if c.path != path {
			continue
		}
		if c.key != key {
			return false
		}
		mut cv := st.cv
		if cv.width != c.w || cv.height != c.h {
			set_canvas_size(mut cv, c.w, c.h)
		}
		unsafe { vmemcpy(cv.pixels.data, c.pix.data, c.w * c.h * 4) }
		cv.mark_dirty()
		if !isnil(st.hist_cv) {
			mut hist := st.hist_cv
			render_histogram(mut st, mut hist, cv.pixels)
		}
		// Свежий - в конец (вытесняется последним)
		e := st.vcache[i]
		st.vcache.delete(i)
		st.vcache << e
		if !isnil(st.load_ov) {
			mut ov := st.load_ov
			ov.stack.visible = false
		}
		if !isnil(st.holder) {
			mut ph := st.holder.stack
			ph.visible = false
		}
		cv.visible = true
		sync_view_bg(mut st)
		return true
	}
	return false
}
