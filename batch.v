module main

// Пакетный экспорт: несколько кадров за раз (выделенные в ленте или вся
// папка) с настройками окна «Экспорт». У каждого кадра - свои правки из
// сайдкара (нет сайдкара - нейтральные), у открытого - текущие из окна.
//
// Один фоновый поток проявляет кадры по очереди: полный кадр 24 Мп в u16
// ~145 МБ плюс копии на шумодав и коррекцию - параллельная проявка
// упирается в память, а по времени кадр и так грузит все ядра в
// многопоточных этапах. Ошибка кадра не останавливает пакет; отмена -
// весь пакет. Прогресс - тот же диалог экспорта (export_ui.v): «Кадр 3
// из 12», этап кадра, общая полоса.
//
// Камерная кривая в сайдкаре не хранится - для неоткрытого кадра она
// считается как у загрузчика (loader.v): по превью ПОЛОВИННОГО размера
// с пересветами и коррекцией объектива кадра, без шумодава. По полному
// кадру кривая заметно другая (IMG_0817: до 11 из 255 в средних тонах).
import os
import time
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
	no_ai     []bool // у кадра AI есть, но при экспорте отключён
	ctl       &ExportCtl = unsafe { nil }
	on_stage  fn (&ExportCtl, ExportStage, int, int, f64) = unsafe { nil }
	on_frame  fn (&ExportCtl, BatchFrame) = unsafe { nil }
}

// BatchFrame - начало очередного кадра (в главный поток)
struct BatchFrame {
	idx        int
	src        string
	dst        string
	plan       StagePlan
	ai_skipped bool
}

// batch_derive - производные поля настроек неоткрытого кадра: цвет
// камеры (баланс белого) и камерная кривая (если включена)
fn batch_derive(path string, e EditState, db &lens.Database) !EditState {
	mut d := raw.open(path)!
	defer {
		d.close()
	}
	cam := cam_color(d.color())
	mut curve := []f32{}
	if e.use_curve {
		mut img := d.develop(half: true, highlight: e.highlight)!
		w := img.width
		h := img.height
		mut lin := []u16{len: w * h * 3}
		unsafe { vmemcpy(lin.data, img.data_u16(), w * h * 6) }
		img.free()
		if e.lens_corr {
			correct_lens(unsafe { &u16(lin.data) }, w, h, d.meta(), db)
		}
		curve = camera_curve(mut d, lin, w * h)
	}
	return with_derived(e, curve, cam)
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

// batch_worker выполняется в spawn: кадры по очереди; итог - report
fn batch_worker(job BatchJob, mut app vgui.App, on_done fn (SaveOutcome, string)) {
	sw := time.new_stopwatch()
	mut c := unsafe { job.ctl }
	progress := export_progress_fn(mut app, job.ctl, job.on_stage)
	mut saved := 0
	mut failed := []string{}
	mut cancelled := false
	n := job.items.len
	for i, it in job.items {
		if c.cancel {
			cancelled = true
			break
		}
		name := os.file_name(it.src)
		e0 := it.edit
		ai_secs := if e0.ai > 0 { job.ai_secs[e0.ai_model] or { 0 } } else { 0 }
		// Путь - здесь, а не заранее: «добавить номер» видит файлы,
		// записанные этим же пакетом (IMG.CR3 и IMG.DNG -> IMG, IMG-2)
		dst := export_path(&job.settings, it.src, job.format)
		fr := BatchFrame{
			idx:        i
			src:        it.src
			dst:        dst
			plan:       export_plan(e0, ai_secs, job.format)
			ai_skipped: i < job.no_ai.len && job.no_ai[i]
		}
		on_frame := job.on_frame
		ctl := job.ctl
		app.post(fn [on_frame, ctl, fr] () {
			on_frame(ctl, fr)
		})
		c.t1 = 0 // оценка AI - заново для каждого кадра
		c.n1 = 0
		if !progress(.decode, 0, 0) {
			cancelled = true
			break
		}
		e := if it.derived {
			e0
		} else {
			batch_derive(it.src, e0, job.db) or {
				failed << '${name}: ${err.msg()}'
				continue
			}
		}
		img := develop_full(it.src, e, job.db,
			ai_cache: if e.ai > 0 { job.ai_caches[e.ai_model] or { unsafe { nil } } } else { unsafe { nil } }
			progress: progress
			size:     job.settings.export_size_opts()
		) or {
			if err is ExportCancelled {
				cancelled = true
				break
			}
			failed << '${name}: ${err.msg()}'
			continue
		}
		if !progress(.write, 0, 0) {
			cancelled = true
			break
		}
		imgio.write(dst, job.format, img.width, img.height, img.rgb,
			quality: job.settings.jpeg_quality
		) or {
			failed << '${name}: не удалось сохранить (${err})'
			continue
		}
		saved++
	}
	sec := f64(sw.elapsed().milliseconds()) / 1000.0
	res, msg := batch_outcome(n, saved, failed, cancelled, job.format, sec)
	report(mut app, on_done, res, msg)
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
