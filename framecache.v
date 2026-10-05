module main

// Кэш кадров на время работы программы: при уходе с кадра его сырьё
// (линейные буферы после LibRaw и объектива, маска, камерная кривая и
// цвет, JPEG камеры, результат шумодава и AI) остаётся в памяти; при
// возврате load_worker не запускается - тот же итог загрузки сразу идёт в
// on_load_done, кадр на экране через один apply (~45 мс на 24 Мп), и
// ползунки сразу работают. Правки при этом берутся из сайдкара как
// обычно: что изменилось с тех пор (пересветы, объектив, шумодав),
// on_load_done досчитает так же, как после обычной загрузки.
//
// Буферы не копируются: кэш - ещё один держатель тех же массивов
// (bufown.v: share при записи, drop при вытеснении), они только читаются -
// подготовка сырья пишет в свои копии. Вытесненный кадр сразу отдаёт
// память системе (если его не держит и State). Предел - по
// памяти (настройка, по умолчанию 1.5 ГБ) и числу кадров (frame_cache_max), вытесняется
// давний; на диск не пишется. Кадр 24 Мп ~110-150 МБ.
import lens
import raw

// Кэш включается и ограничивается в настройках (Settings.no_frame_cache,
// frame_cache_mb; окно «Настройки» - «Память»)
const frame_cache_max = 10
const frame_cache_mb_default = 1536
const frame_cache_mbs = [512, 1024, 1536, 3072, 6144]

fn frame_cache_limit(st &State) i64 {
	mb := if st.settings.frame_cache_mb > 0 {
		st.settings.frame_cache_mb
	} else {
		frame_cache_mb_default
	}
	return i64(mb) << 20
}

// frame_trim - кэш в пределах настроек (выключен - пуст)
fn frame_trim(mut st State) {
	if st.settings.no_frame_cache {
		for st.fcache.len > 0 {
			frame_evict(mut st, 0)
		}
		return
	}
	limit := frame_cache_limit(st)
	mut total := i64(0)
	for c in st.fcache {
		total += c.bytes
	}
	for st.fcache.len > 0 && (st.fcache.len > frame_cache_max || total > limit) {
		total -= st.fcache[0].bytes
		frame_evict(mut st, 0)
	}
}

// Запись - в куче, кэш хранит указатели: `<<` структуры с mut-полями-
// массивами V копирует сами массивы (в кучу сборщика) - кэш держал бы
// копии, а настоящие буферы остались бы без держателя навсегда.
@[heap]
struct FrameCache {
mut:
	path       string
	highlight  int  // режим пересветов, которым проявлен dev_linear
	lens_corr  bool // raw_linear - с коррекцией объектива
	corr       &lens.Corrector = unsafe { nil } // из общей базы lensfun
	w          int
	h          int
	dev_linear []u16
	raw_linear []u16
	linear     []u16
	mask       []u16
	look       CamLook
	cam_view   []u8
	nr         [4]f32
	dc         [3]f32
	ai_applied f32
	ai_linear  []u16 // пусто - результата модели нет
	ai_model   string
	bytes      i64
}

// frame_store - сырьё открытого кадра в кэш (перед уходом с него). Только
// устоявшееся: загрузка и подготовка сырья закончены, объектив не ждёт
// пересчёта - иначе буферы не соответствуют записанному в кэш.
fn frame_store(mut st State) {
	if st.settings.no_frame_cache || st.loading || st.raw_path == '' || st.dev_linear.len == 0 || st.linear.len == 0
		|| st.prep_running || st.raw_pending || st.lens_dirty {
		return
	}
	frame_drop(mut st, st.raw_path)
	ai_ok := st.ai_linear.len > 0 && st.ai_raw_gen == st.raw_gen
	mut fc := &FrameCache{
		path:       st.raw_path
		highlight:  st.hl_developed
		lens_corr:  st.edit.lens_corr
		corr:       st.corr
		w:          st.pw
		h:          st.ph
		dev_linear: share(st.dev_linear)
		raw_linear: share(st.raw_linear)
		linear:     share(st.linear)
		mask:       share(st.mask)
		look:       st.look
		cam_view:   share(st.cam_view)
		nr:         st.nr_applied
		dc:         st.dc_applied
		ai_applied: st.ai_applied
		ai_linear:  if ai_ok { share(st.ai_linear) } else { []u16{} }
		ai_model:   if ai_ok { st.ai_lin_model } else { '' }
	}
	fc.bytes = frame_bytes(fc)
	st.fcache << fc
	frame_trim(mut st)
}

// frame_bytes - память кадра в кэше: разные массивы (raw_linear бывает тем
// же массивом, что dev_linear или linear)
fn frame_bytes(fc &FrameCache) i64 {
	mut seen := []voidptr{}
	mut n := i64(0)
	for a in [fc.dev_linear, fc.raw_linear, fc.linear, fc.mask, fc.ai_linear] {
		if a.len > 0 && a.data !in seen {
			seen << a.data
			n += i64(a.len) * 2
		}
	}
	return n + fc.cam_view.len
}

// frame_evict - убрать запись i, отпустив её буферы
fn frame_evict(mut st State, i int) {
	mut c := st.fcache[i]
	drop(mut c.dev_linear)
	drop(mut c.raw_linear)
	drop(mut c.linear)
	drop(mut c.mask)
	drop(mut c.cam_view)
	drop(mut c.ai_linear)
	st.fcache.delete(i)
}

// frame_drop - забыть кадр path
fn frame_drop(mut st State, path string) {
	for i := 0; i < st.fcache.len; i++ {
		if st.fcache[i].path == path {
			frame_evict(mut st, i)
			return
		}
	}
}

// frame_take - сырьё кадра path из кэша как итог загрузки (dev - только что
// открытый хендл LibRaw); запись из кэша уходит (её ссылки переходят в
// итог) - при уходе с кадра она запишется заново, уже с тем, что
// изменилось
fn frame_take(mut st State, path string, dev &raw.Developer) ?LoadResult {
	for i, c in st.fcache {
		if c.path != path {
			continue
		}
		st.fcache.delete(i)
		mut d := unsafe { dev }
		return LoadResult{
			gen:        st.file_gen
			dev:        dev
			corr:       c.corr
			meta:       d.meta()
			highlight:  c.highlight
			lens_corr:  c.lens_corr
			w:          c.w
			h:          c.h
			dev_linear: c.dev_linear
			raw_linear: c.raw_linear
			linear:     c.linear
			mask:       c.mask
			look:       c.look
			cam_view:   c.cam_view
			nr_applied: c.nr
			dc_applied: c.dc
			ai_applied: c.ai_applied
			ai_linear:  c.ai_linear
			ai_model:   c.ai_model
		}
	}
	return none
}
