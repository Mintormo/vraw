module main

// Диалог экспорта: что проявляется и куда, текущий этап («Этап 3 из 6:
// Шумодав»), общая полоса прогресса по весам этапов (export_plan), время
// и отмена. Открывается при старте экспорта; закрыть можно в любой момент -
// экспорт идёт дальше в фоне, «Файл - Экспорт JPEG...» открывает диалог
// снова. Итог - в диалоге, если он открыт, иначе тостом в главном окне.
// Создаётся при первом экспорте и живёт до выхода: закрытие только прячет.
import os
import time
import vgui

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
	plan    StagePlan
	stage   ExportStage
	done    int // плитки AI
	total   int
	eta     f64 = -1 // AI: секунд до конца, < 0 - неизвестно
	started i64 // unix мс
}

// fraction - общая доля готового по весам этапов
fn (c &ExportCtl) fraction() f64 {
	mut all := 0.0
	mut ready := 0.0
	for i, s in c.plan.stages {
		w := c.plan.weights[i]
		all += w
		if int(s) < int(c.stage) {
			ready += w
		} else if s == c.stage && c.total > 0 {
			ready += w * f64(c.done) / f64(c.total)
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

const exp_w = 560
const exp_h = 250
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
		title:     'Экспорт JPEG'
		width:     exp_w
		height:    exp_h
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
	bar_row.add(bar, 1)
	bar_row.add_fixed(pct, 48)
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
	btn_row.add(vgui.create_spacer(), 1)
	btn_row.add_fixed(btn, set_btn_w)

	mut body := vgui.create_vbox_fill()
	body.set_padding(16)
	body.set_spacing(6)
	body.add_fixed(files, set_note_h)
	body.add_fixed(folder.label, set_note_h)
	body.add_fixed(vgui.create_spacer(), 8)
	body.add_fixed(stage, set_note_h + 2)
	body.add_fixed(bar_row, set_row_h)
	body.add_fixed(timing, set_note_h)
	body.add(vgui.create_spacer(), 1)
	body.add_fixed(btn_row, 30)

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
	c := st.exp
	mut f := u.files
	f.text = '${os.file_name(c.src)}  ->  ${os.file_name(c.dst)}'
	u.folder.set('Папка: ', os.dir(c.dst))
	paint_export(mut st)
	mut b := u.btn
	b.text = 'Отменить'
	b.style = .normal
	b.enabled = true
	sync_export_ui(mut st)
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
	mut name := stage_title(c.stage)
	if c.stage == .ai {
		name = if c.total == 0 {
			'${name} - загрузка модели...'
		} else {
			'${name} - плитка ${c.done} из ${c.total}'
		}
	}
	s.text = 'Этап ${c.stage_no()} из ${c.plan.stages.len}: ${name}'
	frac := c.fraction()
	mut bar := u.bar
	bar.set_value(f32(frac))
	mut p := u.pct
	p.text = '${int(frac * 100)}%'
	elapsed := f64(time.now().unix_milli() - c.started) / 1000
	mut t := 'прошло ${fmt_secs(elapsed)}'
	// Оставшееся: на AI - по плиткам (это почти всё время), иначе - по
	// весам этапов, когда накопилось на что опереться
	if c.stage == .ai && c.eta >= 0 {
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

// export_progress_fn - обратный вызов develop_full (в потоке воркера):
// этап и плитки AI - в главный поток через app.post, false - отмена
fn export_progress_fn(mut app vgui.App, ctl &ExportCtl, on_progress fn (&ExportCtl, ExportStage, int, int, f64)) fn (ExportStage, int, int) bool {
	return fn [mut app, ctl, on_progress] (stage ExportStage, done int, total int) bool {
		mut c := unsafe { ctl }
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
		app.post(fn [on_progress, ctl, stage, done, total, eta] () {
			on_progress(ctl, stage, done, total, eta)
		})
		return !c.cancel
	}
}
