module main

// Диалог экспорта: что проявляется и куда, текущий этап («Этап 3 из 6:
// Шумодав»), общая полоса прогресса по весам этапов (export_plan), время
// и отмена. Открывается при старте экспорта; закрыть можно в любой момент -
// экспорт идёт дальше в фоне, «Файл - Экспорт...» открывает диалог
// снова. Итог - в диалоге, если он открыт, иначе тостом в главном окне.
// Создаётся при первом экспорте и живёт до выхода: закрытие только прячет.
import os
import math
import time
import vgui
import imgio

// ExportCtl - один экспорт. cancel пишет главный поток, читает воркер
// между этапами и плитками AI (опоздание на плитку безвредно, как у
// AiCtl). t1/n1 - время и номер первой готовой плитки AI (пишет только
// воркер) - для оценки оставшегося времени. Остальное - главный поток.
@[heap]
struct ExportCtl {
mut:
	cancel  bool
	t1      i64
	n1      int
	src     string
	dst     string
	fmt     imgio.Format
	// AI у кадра включён, но при экспорте отключён в настройках
	ai_skipped bool
	plan    StagePlan
	stage   ExportStage
	done    int // плитки AI
	total   int
	eta     f64 = -1 // AI: секунд до конца, < 0 - неизвестно
	started i64 // unix мс
	// Пакет (batch.v): кадров всего (у одиночного экспорта 1), готовых,
	// кадры в работе (по номеру) и нагрузка - всё пишет главный поток
	n        int = 1
	finished int
	frames   map[int]FrameProg
	load     string
}

// FrameProg - кадр пакета в работе: имя, план этапов и где он сейчас
struct FrameProg {
	name  string
	plan  StagePlan
	stage ExportStage
	done  int
	total int
}

// fraction - общая доля готового: у пакета - готовые кадры плюс доли
// кадров в работе (кадры считаются равными: этапы у них разные, а время
// большей частью одно - демозаика, тон, запись)
fn (c &ExportCtl) fraction() f64 {
	if c.n <= 1 {
		return plan_fraction(c.plan, c.stage, c.done, c.total)
	}
	mut f := f64(c.finished)
	for _, p in c.frames {
		f += plan_fraction(p.plan, p.stage, p.done, p.total)
	}
	return math.min(1.0, f / f64(c.n))
}

// plan_fraction - доля готового кадра по весам этапов плана
fn plan_fraction(plan StagePlan, stage ExportStage, done int, total int) f64 {
	mut all := 0.0
	mut ready := 0.0
	for i, s in plan.stages {
		w := plan.weights[i]
		all += w
		if int(s) < int(stage) {
			ready += w
		} else if s == stage && total > 0 {
			ready += w * f64(done) / f64(total)
		}
	}
	return if all > 0 { ready / all } else { 0 }
}

// stage_no - номер текущего этапа (с 1)
fn (c &ExportCtl) stage_no() int {
	i := c.plan.stages.index(c.stage)
	return if i < 0 { 1 } else { i + 1 }
}

@[heap]
struct ExportUi {
mut:
	dlg     &vgui.Dialog      = unsafe { nil }
	files   &vgui.Label       = unsafe { nil }
	stage   &vgui.Label       = unsafe { nil }
	bar     &vgui.ProgressBar = unsafe { nil }
	pct     &vgui.Label       = unsafe { nil }
	timing  &vgui.Label       = unsafe { nil }
	folder  PathNote // папка назначения, полный путь - в подсказке
	btn     &vgui.Button      = unsafe { nil }
	notes   []&vgui.Label
}

const exp_path_max = 66 // символов в строке пути (ширина окна минус поля)

// show_export - открыть диалог (создать при первом вызове)
fn show_export(mut st State, mut app vgui.App, parent &vgui.Window) {
	if isnil(st.eui) {
		build_export_ui(mut st, mut app, parent) or {
			if !isnil(st.nm) {
				mut nm := st.nm
				nm.show_error('Не удалось открыть окно экспорта: ${err.msg()}')
			}
			return
		}
	}
	paint_export(mut st)
	mut d := st.eui.dlg
	if !d.is_open() {
		d.show_scaled(parent)
	}
}

// export_open - диалог экспорта сейчас на экране
fn export_open(st &State) bool {
	return !isnil(st.eui) && st.eui.dlg.is_open()
}

fn build_export_ui(mut st State, mut app vgui.App, parent &vgui.Window) ! {
	mut u := &ExportUi{}
	mut dlg := vgui.create_dialog(
		title:     'Экспорт'
		parent:    unsafe { parent }
		theme:     parent.ctx.theme
		font_path: parent.config.font_path
		mono_path: parent.config.mono_path
		font_data: parent.config.font_data
		mono_data: parent.config.mono_data
		font_size: parent.config.font_size
		mono_size: parent.config.mono_size
		ui_scale:  parent.ctx.ui_scale
	)!
	u.dlg = dlg

	mut files := vgui.label('')
	u.files = files
	u.notes << files
	mut stage := vgui.label('')
	stage.font_style = .bold
	u.stage = stage
	mut bar := vgui.progress_bar_linear()
	bar.thickness = 8
	u.bar = bar
	mut pct := value_label('')
	u.pct = pct
	mut bar_row := vgui.create_hbox_fill()
	bar_row.set_spacing(8)
	bar_row.add(bar, flex: 1)
	bar_row.add(pct, min: column_width(mut dlg.win, ['100%'], 8))
	mut timing := vgui.label('')
	u.timing = timing
	u.notes << timing
	folder := path_note('Папка: ', '', exp_path_max)
	u.folder = folder
	u.notes << folder.label

	// Одна кнопка: во время экспорта - «Отменить», после - «Закрыть»
	mut btn := vgui.button('Отменить')
	btn.on_click = fn [mut st, mut dlg] () {
		if !isnil(st.exp) {
			mut c := st.exp
			c.cancel = true
			if !isnil(st.eui) {
				mut s := st.eui.stage
				s.text = 'Отмена...'
				mut b := st.eui.btn
				b.enabled = false
			}
			return
		}
		dlg.close_with_result(0)
	}
	u.btn = btn
	mut btn_row := vgui.create_hbox_fill()
	btn_row.add(vgui.create_spacer(), flex: 1)
	btn_row.add(btn, min: 100)

	mut body := vgui.create_vbox_fill()
	body.set_padding(16)
	body.set_spacing(6)
	body.add(files)
	body.add(folder.label)
	body.add(stage)
	body.add(bar_row)
	body.add(timing)
	body.add(vgui.create_spacer(), flex: 1)
	body.add(btn_row)

	dlg.add_widget(body)
	dlg.add_widget(folder.tip) // после корня: рисуется поверх
	app.add_dialog(dlg)
	st.eui = u
}

// export_started - новый экспорт: диалог в состояние «идёт»
fn export_started(mut st State) {
	if isnil(st.eui) || isnil(st.exp) {
		return
	}
	mut u := st.eui
	sync_export_files(mut st)
	paint_export(mut st)
	mut b := u.btn
	b.text = 'Отменить'
	b.style = .normal
	b.enabled = true
	sync_export_ui(mut st)
}

// sync_export_files - что проявляется и куда (у пакета - сколько готово
// и какие кадры в работе)
fn sync_export_files(mut st State) {
	if isnil(st.eui) || isnil(st.exp) {
		return
	}
	mut u := st.eui
	c := st.exp
	mut f := u.files
	if c.n > 1 {
		f.text = 'Готово ${c.finished} из ${c.n} ${plural(c.n, 'кадра', 'кадров', 'кадров')}  ·  нагрузка: ${load_title(c.load)}'
	} else {
		no_ai := if c.ai_skipped { '  ·  без AI-шумодава' } else { '' }
		f.text = '${os.file_name(c.src)}  ->  ${os.file_name(c.dst)}${no_ai}'
	}
	if c.dst != '' {
		u.folder.set('Папка: ', os.dir(c.dst))
	}
}

// batch_event - событие пакета из воркера (через app.post): кадр начат,
// сменил этап, закончен
fn batch_event(mut st State, ctl &ExportCtl, ev BatchEvent) {
	mut c := unsafe { ctl }
	match ev.kind {
		.start {
			c.frames[ev.idx] = FrameProg{
				name: os.file_name(ev.src)
				plan: ev.plan
			}
			c.dst = ev.dst
		}
		.stage {
			if p := c.frames[ev.idx] {
				c.frames[ev.idx] = FrameProg{
					...p
					stage: ev.stage
					done:  ev.done
					total: ev.total
				}
			}
		}
		.end {
			c.frames.delete(ev.idx)
			c.finished++
		}
	}
	if st.exp == ctl {
		sync_export_files(mut st)
		sync_export_ui(mut st)
	}
}

// stage_text - этап словами («AI-шумодав - плитка 3 из 40», «Запись PNG»)
fn stage_text(stage ExportStage, done int, total int, f imgio.Format) string {
	name := stage_title(stage)
	return match stage {
		.ai {
			if total == 0 { '${name} - загрузка модели...' } else { '${name} - плитка ${done} из ${total}' }
		}
		.write {
			if f == .gif { 'Палитра и запись GIF' } else { 'Запись ${f.name()}' }
		}
		else {
			name
		}
	}
}

// batch_stage_text - что идёт в пакете: один кадр - его этап, несколько -
// их имена
fn batch_stage_text(c &ExportCtl) string {
	mut idx := c.frames.keys()
	idx.sort()
	if idx.len == 0 {
		return 'Подготовка...'
	}
	if idx.len == 1 {
		p := c.frames[idx[0]] or { return '' }
		return '${p.name}: ${stage_text(p.stage, p.done, p.total, c.fmt)}'
	}
	names := idx.map(c.frames[it] or { FrameProg{} }.name)
	return 'В работе ${idx.len} ${plural(idx.len, 'кадр', 'кадра', 'кадров')}: ${names.join(', ')}'
}

// sync_export_ui - этап, полоса и время по st.exp (главный поток)
fn sync_export_ui(mut st State) {
	if isnil(st.eui) || isnil(st.exp) {
		return
	}
	mut u := st.eui
	c := st.exp
	if c.cancel {
		return // «Отмена...» уже написано
	}
	mut s := u.stage
	s.text = if c.n > 1 {
		batch_stage_text(c)
	} else {
		'Этап ${c.stage_no()} из ${c.plan.stages.len}: ${stage_text(c.stage, c.done, c.total, c.fmt)}'
	}
	frac := c.fraction()
	mut bar := u.bar
	bar.set_value(f32(frac))
	mut p := u.pct
	p.text = '${int(frac * 100)}%'
	elapsed := f64(time.now().unix_milli() - c.started) / 1000
	mut t := 'прошло ${fmt_secs(elapsed)}'
	// Оставшееся: на AI - по плиткам (это почти всё время), иначе - по
	// весам этапов, когда накопилось на что опереться
	if c.n <= 1 && c.stage == .ai && c.eta >= 0 {
		t += ' · ${fmt_eta(c.eta)}'
	} else if frac > 0.15 && elapsed > 2 {
		t += ' · ${fmt_eta(elapsed / frac - elapsed)}'
	}
	mut tl := u.timing
	tl.text = t
}

// export_finished - итог экспорта: в открытом диалоге - текстом, в
// закрытом - тостом. false - диалог закрыт (итог надо показать тостом).
fn export_finished(mut st State, res SaveOutcome, msg string) bool {
	if isnil(st.eui) {
		return false
	}
	mut u := st.eui
	mut b := u.btn
	b.text = 'Закрыть'
	b.style = .accent
	b.enabled = true
	mut s := u.stage
	s.text = match res {
		.saved { 'Готово' }
		.failed { 'Ошибка' }
		.cancelled { 'Экспорт отменён' }
	}
	if res == .saved {
		mut bar := u.bar
		bar.set_value(1)
		mut p := u.pct
		p.text = '100%'
	}
	// Строка времени - итогом: путь уже в диалоге, из «Сохранено: путь
	// (детали)» остаются детали; ошибка - красным
	mut t := u.timing
	t.text = if res == .saved && msg.contains(' (') {
		msg.all_after(' (').trim_right(')')
	} else {
		msg
	}
	if res == .failed {
		t.color = vgui.Color{235, 90, 80, 255}
	}
	return export_open(st)
}

// fmt_secs - «8 с» / «2 мин 05 с»
fn fmt_secs(sec f64) string {
	s := int(sec)
	if s < 60 {
		return '${s} с'
	}
	return '${s / 60} мин ${s % 60:02} с'
}

// paint_export - цвета вторичных подписей по теме
fn paint_export(mut st State) {
	if isnil(st.eui) {
		return
	}
	mut u := st.eui
	for i in 0 .. u.notes.len {
		u.notes[i].color = st.pal.secondary
	}
}

// ExportPoster - прогресс develop_full (в потоке воркера): этап и плитки
// AI - в главный поток (post_result, без замыканий - post.v)
struct ExportPoster {
mut:
	app         &vgui.App = unsafe { nil }
	ctl         &ExportCtl = unsafe { nil }
	on_progress fn (&ExportCtl, ExportStage, int, int, f64) = unsafe { nil }
}

// ExportTick - одно сообщение о прогрессе экспорта
struct ExportTick {
	on_progress fn (&ExportCtl, ExportStage, int, int, f64) = unsafe { nil }
	ctl         &ExportCtl = unsafe { nil }
	stage       ExportStage
	done        int
	total       int
	eta         f64
}

fn deliver_export_tick(t ExportTick) {
	t.on_progress(t.ctl, t.stage, t.done, t.total, t.eta)
}

fn (mut p ExportPoster) stage(stage ExportStage, done int, total int) bool {
	mut c := p.ctl
	mut eta := f64(-1)
	if stage == .ai && done > 0 {
		now := time.now().unix_milli()
		if c.t1 == 0 {
			c.t1 = now
			c.n1 = done
		} else if done > c.n1 {
			eta = f64(now - c.t1) / 1000 / f64(done - c.n1) * f64(total - done)
		}
	}
	mut app := p.app
	post_result(mut app, deliver_export_tick, ExportTick{
		on_progress: p.on_progress
		ctl:         p.ctl
		stage:       stage
		done:        done
		total:       total
		eta:         eta
	})
	return !c.cancel
}
