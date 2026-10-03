module main

// Пакетный экспорт: несколько кадров за раз (выделенные в ленте или вся
// папка) с настройками окна «Экспорт». У каждого кадра - свои правки из
// сайдкара (нет сайдкара - нейтральные), у открытого - текущие из окна.
//
// Координатор (batch_worker) раздаёт кадры потокам: одновременно не
// больше, чем позволяет нагрузка (load_level: 1-3 кадра; полный кадр
// 24 Мп в u16 ~145 МБ плюс копии - упор в память), кадр с AI-шумодавом -
// всегда один (модель и так занимает все ядра и много памяти). Замер
// (-prod, 3 кадра, шумодав): по одному 9.4 с, по два 6.7 с, по три
// 4.7 с - большая часть этапов однопоточна. Потоки экспорта - с
// пониженным приоритетом (nice), у «фоновой» нагрузки ещё и OpenMP
// LibRaw на четверть ядер: дольше, но компьютер свободен. Ошибка кадра
// не останавливает пакет; отмена - весь пакет. Прогресс - тот же диалог
// экспорта (export_ui.v): сколько готово, какие кадры в работе, общая
// полоса.
//
// Камерная кривая в сайдкаре не хранится - для неоткрытого кадра она
// считается как у загрузчика (loader.v): по превью ПОЛОВИННОГО размера
// с пересветами и коррекцией объектива кадра, без шумодава. По полному
// кадру кривая заметно другая (IMG_0817: до 11 из 255 в средних тонах).
import os
import time
import math
import runtime
import vgui
import raw
import lens
import ai
import imgio

// BatchItem - кадр пакета: настройки (derived - уже с производными
// полями: открытый кадр, как в окне)
struct BatchItem {
	src     string
	derived bool
mut:
	edit EditState
}

struct BatchJob {
	items    []BatchItem
	settings Settings // снимок: папка, имя, «файл есть», размер, качество
	format   imgio.Format
	db       &lens.Database = unsafe { nil }
	// AI-шумодав: модели кадров (общие, только чтение) и оценки секунд
	ai_caches map[string]&ai.Cache
	ai_secs   map[string]f64
	ctl       &ExportCtl                  = unsafe { nil }
	on_event  fn (&ExportCtl, BatchEvent) = unsafe { nil }
}

enum BatchEventKind {
	start
	stage
	end
}

// BatchEvent - кадр пакета начат / сменил этап / закончен (в главный поток)
struct BatchEvent {
	kind  BatchEventKind
	idx   int
	src   string
	dst   string
	plan  StagePlan
	stage ExportStage
	done  int
	total int
}

// BatchDone - итог кадра (поток кадра -> координатор)
struct BatchDone {
	idx       int
	err       string // не пусто - ошибка кадра
	cancelled bool
}

// ── Нагрузка ──

#include <sys/resource.h>
#include <unistd.h>
#include <omp.h>
#flag -lgomp

fn C.setpriority(which int, who u32, prio int) int
fn C.gettid() int
fn C.omp_set_num_threads(n int)

// Нагрузка экспорта: ключи (Settings.export_load) и названия
const load_keys = ['low', 'normal', 'high']
const load_names = ['Фоновая', 'Обычная', 'Максимальная']
const load_notes = [
	'По одному кадру, низкий приоритет - другие программы не тормозят',
	'2 кадра одновременно, приоритет ниже других программ',
	'3 кадра одновременно - быстрее всего, компьютер занят',
]

fn load_title(key string) string {
	return match key {
		'low' { 'фоновая' }
		'high' { 'максимальная' }
		else { 'обычная' }
	}
}

// LoadLevel - что значит нагрузка: кадров одновременно, nice потоков
// экспорта (0..19, больше - уступчивее), потоков OpenMP LibRaw (0 - все)
struct LoadLevel {
	par  int
	nice int
	omp  int
}

fn load_level(key string) LoadLevel {
	return match key {
		'low' { LoadLevel{1, 19, math.max(1, runtime.nr_cpus() / 4)} }
		'high' { LoadLevel{3, 0, 0} }
		else { LoadLevel{2, 10, 0} }
	}
}

// apply_load - приоритет и OpenMP вызывающего потока; потоки, которые он
// создаст (деконволюция, резкость, OpenMP LibRaw), наследуют приоритет.
// Повысить приоритет без прав нельзя - только понизить, поэтому вызывать
// лишь в потоках экспорта, не в главном.
fn apply_load(l LoadLevel) {
	if l.nice > 0 {
		C.setpriority(0, u32(C.gettid()), l.nice) // 0 - PRIO_PROCESS: для потока по tid
	}
	if l.omp > 0 {
		C.omp_set_num_threads(l.omp)
	}
}

// batch_derive - производные поля настроек неоткрытого кадра: цвет
// камеры (баланс белого), сила коррекции виньетирования (при коррекции
// объектива) и камерная кривая (если включена) - как в загрузчике окна
fn batch_derive(path string, e EditState, db &lens.Database) !EditState {
	mut d := raw.open(path)!
	defer {
		d.close()
	}
	cam := cam_color(d.color())
	mut look := CamLook{}
	if e.use_curve || e.lens_corr {
		mut img := d.develop(half: true, highlight: e.highlight)!
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
		mut vign := lens.vign_default
		if e.lens_corr {
			m := d.meta()
			corr := db.find(m.cam_make, m.cam_model, m.lens) or { unsafe { nil } }
			vign = vign_match(cj, d.flip(), corr, lin, w, h, m)
			correct_lens(unsafe { &u16(lin.data) }, w, h, m, db, vign)
		}
		if e.use_curve {
			look = camera_look(cj, lin, w * h, vign)
		} else {
			look = CamLook{
				vign: vign
			}
		}
	}
	return with_derived(e, look, cam)
}

// batch_items - кадры пакета по путям: открытый - текущие настройки окна,
// остальные - из сайдкара; AI выключен при экспорте - ai = 0. Второй
// результат - кадры, чей сайдкар не прочитался (они проявятся
// нейтрально - лучше, чем молча пропустить).
fn batch_items(st &State, paths []string) ([]BatchItem, []string) {
	open_path := if st.history.len > 0 && st.side_path.len > 0 {
		st.side_path.all_before_last(sidecar_ext)
	} else {
		''
	}
	mut items := []BatchItem{}
	mut bad := []string{}
	for p in paths {
		mut it := if p == open_path {
			BatchItem{
				src:     p
				edit:    st.edit.clone()
				derived: true
			}
		} else {
			side := load_sidecar(sidecar_path(p)) or {
				bad << os.file_name(p)
				LoadedSidecar{}
			}
			BatchItem{
				src:  p
				edit: if side.history.len > 0 {
					side.history[side.current].state
				} else {
					neutral_edit()
				}
			}
		}
		items << it
	}
	return items, bad
}

// BatchTally - счёт итогов кадров у координатора
struct BatchTally {
mut:
	saved     int
	failed    []string
	cancelled bool
}

fn (mut t BatchTally) add(r BatchDone) {
	if r.cancelled {
		t.cancelled = true
	} else if r.err != '' {
		t.failed << r.err
	} else {
		t.saved++
	}
}

// batch_worker выполняется в spawn: координатор - кадры потокам
// (batch_frame_job), не больше level.par одновременно, AI - по одному;
// итог - report
fn batch_worker(job BatchJob, mut app vgui.App, on_done fn (SaveOutcome, string)) {
	sw := time.new_stopwatch()
	level := load_level(job.settings.export_load)
	apply_load(level)
	c := job.ctl
	n := job.items.len
	ch := chan BatchDone{cap: n}
	mut threads := []thread{}
	mut tally := BatchTally{}
	mut running := 0
	// Пути - здесь и заранее занятые: два кадра одновременно с одним
	// именем (IMG.CR3 и IMG.DNG) иначе получили бы один файл
	mut taken := map[string]bool{}
	for i, it in job.items {
		alone := it.edit.ai > 0
		for running > 0 && (running >= level.par || alone) {
			tally.add(<-ch)
			running--
		}
		if c.cancel || tally.cancelled {
			break
		}
		dst := export_path_taken(&job.settings, it.src, job.format, taken, NameInfo{
			num:   i + 1
			count: n
		})
		taken[dst] = true
		e0 := it.edit
		ai_secs := if e0.ai > 0 { job.ai_secs[e0.ai_model] or { 0 } } else { 0 }
		post_batch(mut app, job, BatchEvent{
			kind: .start
			idx:  i
			src:  it.src
			dst:  dst
			plan: export_plan(e0, ai_secs, job.format)
		})
		cache := if e0.ai > 0 {
			job.ai_caches[e0.ai_model] or { unsafe { nil } }
		} else {
			unsafe { nil }
		}
		threads << spawn batch_frame_job(job, i, dst, cache, level, mut app, ch)
		running++
		if alone {
			tally.add(<-ch)
			running--
		}
	}
	for running > 0 {
		tally.add(<-ch)
		running--
	}
	for t in threads {
		t.wait()
	}
	sec := f64(sw.elapsed().milliseconds()) / 1000.0
	res, msg := batch_outcome(n, tally.saved, tally.failed, tally.cancelled || c.cancel,
		job.format, sec)
	report(mut app, on_done, res, msg)
}

fn post_batch(mut app vgui.App, job BatchJob, ev BatchEvent) {
	on_event := job.on_event
	ctl := job.ctl
	app.post(fn [on_event, ctl, ev] () {
		on_event(ctl, ev)
	})
}

// batch_frame_job выполняется в spawn: один кадр пакета - производные
// поля, проявка, запись; итог - в канал координатору (и событие «кадр
// закончен» в главный поток)
fn batch_frame_job(job BatchJob, i int, dst string, cache &ai.Cache, level LoadLevel, mut app vgui.App, ch chan BatchDone) {
	apply_load(level)
	it := job.items[i]
	name := os.file_name(it.src)
	ctl := job.ctl
	progress := fn [mut app, job, i, ctl] (stage ExportStage, done int, total int) bool {
		post_batch(mut app, job, BatchEvent{
			kind:  .stage
			idx:   i
			stage: stage
			done:  done
			total: total
		})
		return !ctl.cancel
	}
	r := batch_frame_run(it, dst, job, cache, progress) or {
		if err is ExportCancelled {
			BatchDone{
				idx:       i
				cancelled: true
			}
		} else {
			BatchDone{
				idx: i
				err: '${name}: ${err.msg()}'
			}
		}
	}
	post_batch(mut app, job, BatchEvent{
		kind: .end
		idx:  i
	})
	ch <- r
}

// batch_frame_run - проявка и запись кадра; ExportCancelled - отмена
fn batch_frame_run(it BatchItem, dst string, job BatchJob, cache &ai.Cache, progress fn (ExportStage, int, int) bool) !BatchDone {
	if !progress(.decode, 0, 0) {
		return ExportCancelled{}
	}
	e := if it.derived { it.edit } else { batch_derive(it.src, it.edit, job.db)! }
	img := develop_full(it.src, e, job.db,
		ai_cache: cache
		progress: progress
		size:     job.settings.export_size_opts()
	)!
	if !progress(.write, 0, 0) {
		return ExportCancelled{}
	}
	write_image(dst, job.format, img, job.settings.jpeg_quality, &job.settings) or {
		return error('не удалось сохранить (${err})')
	}
	return BatchDone{}
}

// batch_outcome - итог пакета: вид уведомления и текст
fn batch_outcome(n int, saved int, failed []string, cancelled bool, f imgio.Format, sec f64) (SaveOutcome, string) {
	done := 'сохранено ${saved} из ${n} ${plural(n, 'кадра', 'кадров', 'кадров')}'
	if cancelled {
		return SaveOutcome.cancelled, 'Экспорт отменён: ${done}'
	}
	if failed.len > 0 {
		more := if failed.len > 1 { ' (и ещё ${failed.len - 1})' } else { '' }
		return SaveOutcome.failed, 'Экспорт: ${done}. Ошибка - ${failed[0]}${more}'
	}
	return SaveOutcome.saved, 'Экспорт: ${done} - ${f.name()}, ${fmt_secs(sec)}'
}
