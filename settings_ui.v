module main

// Окно «Настройки» (меню «Правка - Настройки...»): оформление (тема, фон
// вокруг снимка - те же, что в меню «Вид»), AI-шумодав: скачивание ONNX
// Runtime и моделей в папки рядом с программой, выбор модели для новых
// прогонов. Настройки экспорта - в окне «Экспорт» (export_setup.v). Диалог создаётся при первом открытии и живёт до выхода:
// закрытие только прячет. Скачивание идёт в фоне (dl_worker) - окно можно
// закрыть и работать дальше, итог - тостом в главном окне.
import vgui
import ai
import imgio

// DlCtl - одно скачивание (ORT и/или модель). cancel пишет главный поток,
// читает воркер между порциями данных; posted - только воркер (сколько
// уже сообщено, чтобы не заваливать главный поток); done/total - главный
// поток (для показа).
@[heap]
struct DlCtl {
mut:
	cancel bool
	model  string // id модели, пусто - только ONNX Runtime
	what   string // подпись: что качаем
	posted i64
	done   i64
	total  i64
}

struct DlResult {
	ctl       &DlCtl = unsafe { nil }
	err       string
	cancelled bool
}

// ModelRow - строка модели в окне
struct ModelRow {
	id    string
	radio &vgui.RadioButton = unsafe { nil }
	state &vgui.Label       = unsafe { nil }
	btn   &vgui.Button      = unsafe { nil }
}

@[heap]
struct SettingsUi {
mut:
	dlg      &vgui.Dialog      = unsafe { nil }
	theme_cb &vgui.ComboBox    = unsafe { nil }
	bg_cb    &vgui.ComboBox    = unsafe { nil }
	rt_state &vgui.Label       = unsafe { nil }
	rt_btn   &vgui.Button      = unsafe { nil }
	rows     []ModelRow
	dl_box   &vgui.Stack       = unsafe { nil } // прогресс (скрыт без скачивания)
	dl_bar   &vgui.ProgressBar = unsafe { nil }
	dl_text  &vgui.Label       = unsafe { nil }
	dl_stop  &vgui.Button      = unsafe { nil }
	notes    []&vgui.Label // вторичные подписи - цвет по теме
}

// fmt_title - формат в списке настроек: название и что это
fn fmt_title(f imgio.Format) string {
	return match f {
		.jpeg { 'JPEG - компактный' }
		.png { 'PNG - без потерь' }
		.tiff { 'TIFF - для других программ' }
		.bmp { 'BMP - без сжатия' }
		.qoi { 'QOI - без потерь, быстрый' }
		.gif { 'GIF - 256 цветов' }
	}
}

const set_path_max = 76 // символов в строке пути (ширина окна минус поля)

fn fmt_mb(bytes i64) string {
	return '${f64(bytes) / 1e6:.0f} МБ'
}

// show_settings - открыть окно настроек (создать при первом вызове)
fn show_settings(mut st State, mut app vgui.App, parent &vgui.Window) {
	if isnil(st.sui) {
		build_settings(mut st, mut app, parent) or {
			if !isnil(st.nm) {
				mut nm := st.nm
				nm.show_error('Не удалось открыть настройки: ${err.msg()}')
			}
			return
		}
	}
	mut u := st.sui
	st.del_armed = ''
	sync_settings_ui(mut st)
	mut d := u.dlg
	if !d.is_open() {
		d.show_scaled(parent)
	}
}

// caption - жирный заголовок раздела
fn caption(text string) &vgui.Label {
	mut l := vgui.label(text)
	l.font_style = .bold
	return l
}

// note - вторичная подпись (цвет - по теме, paint_settings)
fn note(mut u SettingsUi, text string) &vgui.Label {
	mut l := vgui.label(text)
	u.notes << l
	return l
}

// PathNote - вторичная подпись с путём: длинный путь обрезается
// многоточием в начале (важен конец пути), полный - в подсказке при
// наведении. Подсказку добавить в окно после корня (tip).
struct PathNote {
	label &vgui.Label   = unsafe { nil }
	tip   &vgui.Tooltip = unsafe { nil }
	max   int // символов подписи вместе с префиксом - по ширине окна
}

const path_tip_line = 60 // символов в строке подсказки с путём

fn path_note(prefix string, path string, max int) PathNote {
	mut t := vgui.tooltip('')
	// Перенос подсказки vgui - только по пробелам, в пути их обычно нет:
	// строки режет path_tip, ширина - с запасом под них
	t.max_width = 560
	p := PathNote{
		label: vgui.label('')
		tip:   t
		max:   max
	}
	p.set(prefix, path)
	t.attach(p.label)
	return p
}

fn (p PathNote) set(prefix string, path string) {
	mut l := p.label
	l.text = prefix + elide_left(path, p.max - prefix.runes().len)
	mut t := p.tip
	t.set_text(path_tip(path))
}

// elide_left - длинная строка с многоточием в начале
fn elide_left(s string, max int) string {
	r := s.runes()
	return if r.len <= max || max < 4 { s } else { '...' + r[r.len - max + 3..].string() }
}

// path_tip - путь строками не длиннее path_tip_line, разрыв после
// разделителя папок: «/» или «\» (на будущее - Windows). Имя папки
// длиннее строки не режется.
fn path_tip(path string) string {
	// Части пути - каждая с разделителем на конце (у последней его нет)
	mut parts := []string{}
	mut part := []rune{}
	for r in path.runes() {
		part << r
		if r == `/` || r == `\\` {
			parts << part.string()
			part.clear()
		}
	}
	if part.len > 0 {
		parts << part.string()
	}
	mut lines := []string{}
	mut line := ''
	for p in parts {
		if line.runes().len + p.runes().len > path_tip_line && line.len > 0 {
			lines << line
			line = ''
		}
		line += p
	}
	lines << line
	return lines.join('\n')
}

// indented - виджет с отступом слева (под текстом переключателя)
fn indented(w &vgui.Widget, pad f32) &vgui.HBox {
	mut row := vgui.create_hbox_fill()
	row.set_spacing(0)
	row.add(vgui.label(''), min: pad) // pad - колонка подписей окна (по тексту)
	row.add(w, flex: 1)
	return row
}

// labeled - «подпись | виджет» для рядов оформления; col - колонка
// подписей (по самой длинной), w_min - общая ширина виджетов колонки
fn labeled(text string, w &vgui.Widget, col f32, w_min f32) &vgui.HBox {
	mut row := vgui.create_hbox_fill()
	row.set_spacing(8)
	row.add(vgui.label(text), min: col)
	row.add(w, min: w_min)
	row.add(vgui.create_spacer(), flex: 1)
	return row
}

fn build_settings(mut st State, mut app vgui.App, parent &vgui.Window) ! {
	mut u := &SettingsUi{}
	mut dlg := vgui.create_dialog(
		title:     'Настройки'
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

	// ── Оформление ──
	mut theme_cb := vgui.combo_box()
	theme_cb.set_items(theme_names)
	theme_cb.on_change = fn [mut st, mut app] (i int, _ string) {
		apply_theme(mut st, mut app, i)
	}
	u.theme_cb = theme_cb
	mut bg_cb := vgui.combo_box()
	bg_cb.set_items(bg_names)
	bg_cb.on_change = fn [mut st] (i int, _ string) {
		set_viewer_bg(mut st, i)
	}
	u.bg_cb = bg_cb

	// ── AI-шумодав: движок ──
	// Колонки состояния и кнопок у строк ORT и моделей - по самым длинным
	// их текстам (шрифтом окна): кнопки стоят ровной колонкой
	mut dw := &dlg.win
	state_col := column_width(mut dw, ['установлен', 'нет · 11.0 МБ', 'скачана · 117.0 МБ',
		'нет в папке моделей'], 8)
	btn_col := column_width(mut dw, ['Скачать', 'Удалить', 'Точно?', 'Готов'], 0) +
		2 * vgui.measure_pad_x
	look_col := column_width(mut dw, ['Тема', 'Фон вокруг снимка'], 8)
	// Списки оформления - одной ширины, по самому длинному пункту обоих
	// (24 - стрелка ComboBox, как в его measure)
	mut look_items := theme_names.clone()
	look_items << bg_names
	look_w := column_width(mut dw, look_items, 0) +
		2 * theme_cb.pad + 24
	mut rt_btn := vgui.button('Скачать')
	rt_btn.on_click = fn [mut st, mut app] () {
		start_download(mut st, mut app, '')
	}
	u.rt_btn = rt_btn
	mut rt_state := vgui.label('')
	u.rt_state = rt_state
	mut rt_row := vgui.create_hbox_fill()
	rt_row.set_spacing(8)
	rt_row.add(vgui.label('ONNX Runtime ${ai.runtime_version}'), flex: 1)
	rt_row.add(rt_state, min: state_col)
	rt_row.add(rt_btn, min: btn_col)

	mut body := vgui.create_vbox_fill()
	body.set_padding(16)
	body.set_spacing(6)
	body.add(caption('Оформление'))
	body.add(labeled('Тема', theme_cb, look_col, look_w))
	body.add(labeled('Фон вокруг снимка', bg_cb, look_col, look_w))

	body.add(caption('AI-шумодав'))
	body.add(rt_row)
	body.add(note(mut u, 'Движок нейросетей (открытый, MIT) - нужен всем моделям'))
	body.add(vgui.label('Модель (для новых прогонов; кадр помнит свою):'))

	// ── Модели каталога: переключатель, состояние, кнопка ──
	for info in ai.models {
		id := info.id
		mut radio := vgui.radio_button(info.title)
		radio.radio_group = 'ai_model'
		radio.on_change = fn [mut st, id] (v bool) {
			if v && st.settings.ai_model != id {
				st.settings.ai_model = id
				save_settings(st.settings)
				sync_ai_ui(mut st)
				sync_settings_ui(mut st)
			}
		}
		mut state := vgui.label('')
		// Одна кнопка: нет модели - «Скачать», есть - «Удалить» (вторым
		// нажатием: первое спрашивает «Точно?»)
		mut btn := vgui.button('Скачать')
		btn.on_click = fn [mut st, mut app, id] () {
			info := ai.find_model_info(id) or { return }
			if !info.installed(st.ai_places) {
				start_download(mut st, mut app, id)
			} else if st.del_armed == id {
				delete_model(mut st, info)
			} else {
				st.del_armed = id
				sync_settings_ui(mut st)
			}
		}
		mut row := vgui.create_hbox_fill()
		row.set_spacing(8)
		row.add(radio, flex: 1)
		row.add(state, min: state_col)
		row.add(btn, min: btn_col)
		body.add(row)
		body.add(indented(note(mut u, info.note), radio.circle_size + radio.gap))
		u.rows << ModelRow{
			id:    id
			radio: radio
			state: state
			btn:   btn
		}
	}

	// ── Прогресс скачивания ──
	mut dl_text := vgui.label('')
	u.dl_text = dl_text
	mut dl_bar := vgui.progress_bar_linear()
	dl_bar.thickness = 6
	u.dl_bar = dl_bar
	mut dl_stop := vgui.button('Отменить')
	dl_stop.on_click = fn [mut st] () {
		if !isnil(st.dl) {
			mut c := st.dl
			c.cancel = true
			if !isnil(st.sui) {
				mut t := st.sui.dl_text
				t.text = 'Отмена...'
			}
		}
	}
	u.dl_stop = dl_stop
	mut bar_row := vgui.create_hbox_fill()
	bar_row.set_spacing(8)
	bar_row.add(dl_bar, flex: 1)
	bar_row.add(dl_stop, min: btn_col)
	mut dl_v := vgui.create_vbox_fill()
	dl_v.set_spacing(4)
	dl_v.add(dl_text)
	dl_v.add(bar_row)
	u.dl_box = layer(dl_v)
	body.add(u.dl_box)

	// ── Где что лежит, закрыть ──
	body.add(vgui.create_spacer(), flex: 1)
	paths := [path_note('Настройки: ', settings_path(), set_path_max),
		path_note('Модели: ', st.ai_places.models, set_path_max)]
	for p in paths {
		u.notes << p.label
		body.add(p.label)
	}
	mut close := vgui.button('Закрыть')
	close.style = .accent
	close.on_click = fn [mut dlg] () {
		dlg.close_with_result(0)
	}
	mut close_row := vgui.create_hbox_fill()
	close_row.add(vgui.create_spacer(), flex: 1)
	close_row.add(close, min: btn_col)
	body.add(close_row)

	dlg.add_widget(body)
	// Подсказки - после корня: рисуются поверх
	for p in paths {
		dlg.add_widget(p.tip)
	}
	app.add_dialog(dlg)
	st.sui = u
	paint_settings(mut st)
}

// sync_settings_ui - окно по состоянию: выбранные тема и фон, модель,
// что скачано, идёт ли скачивание
fn sync_settings_ui(mut st State) {
	if isnil(st.sui) {
		return
	}
	mut u := st.sui
	mut tcb := u.theme_cb
	tcb.set_selected(theme_index(st.settings.theme))
	mut bcb := u.bg_cb
	bcb.set_selected(bg_index(st.settings.viewer_bg))
	busy := !isnil(st.dl)
	p := st.ai_places
	have_rt := ai.runtime_lib(p) != ''
	mut rs := u.rt_state
	rs.text = if have_rt { 'установлен' } else { 'нет · ${fmt_mb(ai.runtime_file.size)}' }
	mut rb := u.rt_btn
	rb.enabled = !have_rt && !busy
	rb.text = if have_rt { 'Готов' } else { 'Скачать' }
	for r in u.rows {
		info := ai.find_model_info(r.id) or { continue }
		ok := info.installed(p)
		mut radio := r.radio
		radio.selected = st.settings.ai_model == r.id
		mut s := r.state
		mut b := r.btn
		if ok {
			s.text = 'скачана · ${fmt_mb(info.size())}'
			armed := st.del_armed == r.id
			b.text = if armed { 'Точно?' } else { 'Удалить' }
			b.style = if armed { .danger } else { .normal }
			// Пока идёт скачивание или прогон AI - модель может быть в работе
			b.enabled = !busy && isnil(st.ai_prev) && isnil(st.exp)
		} else if info.downloadable() {
			// Вместе с моделью докачается и движок, если его нет
			extra := if have_rt { i64(0) } else { ai.runtime_file.size }
			s.text = fmt_mb(info.size() + extra)
			b.text = 'Скачать'
			b.style = .normal
			b.enabled = !busy
		} else {
			s.text = 'нет в папке моделей'
			b.text = 'Скачать'
			b.style = .normal
			b.enabled = false
		}
	}
	mut box := u.dl_box
	box.visible = busy
	if busy {
		c := st.dl
		mut bar := u.dl_bar
		bar.set_value(if c.total > 0 { f32(f64(c.done) / f64(c.total)) } else { 0 })
		if !c.cancel {
			mut t := u.dl_text
			t.text = 'Скачивание: ${c.what} · ${fmt_mb(c.done)} из ${fmt_mb(c.total)}'
		}
	}
}

// paint_settings - цвета окна по теме (при создании и смене темы)
fn paint_settings(mut st State) {
	if isnil(st.sui) {
		return
	}
	mut u := st.sui
	for i in 0 .. u.notes.len {
		u.notes[i].color = st.pal.secondary
	}
}

// delete_model - удалить скачанную модель (подтверждено вторым нажатием).
// Кэш модели забывается: загруженная в память модель досчитает, что
// начато, а новый прогон увидит «не скачана» (или скачанную заново).
fn delete_model(mut st State, info ai.ModelInfo) {
	st.del_armed = ''
	ai.remove_model(st.ai_places, info) or {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_error('Не удалось удалить ${info.title}: ${err.msg()}')
		}
	}
	st.ai_caches.delete(info.id)
	if !isnil(st.nm) && !info.installed(st.ai_places) {
		mut nm := st.nm
		nm.show_info('Модель ${info.title} удалена')
	}
	sync_settings_ui(mut st)
	sync_ai_ui(mut st)
}

// start_download - скачать модель (с движком, если его нет) или только
// движок (model пусто). Одно скачивание за раз.
fn start_download(mut st State, mut app vgui.App, model string) {
	if !isnil(st.dl) {
		return
	}
	st.del_armed = ''
	need_rt := ai.runtime_lib(st.ai_places) == ''
	mut parts := []string{}
	mut total := i64(0)
	if need_rt {
		parts << 'ONNX Runtime'
		total += ai.runtime_file.size
	}
	if model != '' {
		info := ai.find_model_info(model) or { return }
		parts << info.title
		total += info.size()
	}
	if parts.len == 0 {
		return
	}
	ctl := &DlCtl{
		model: model
		what:  parts.join(' + ')
		total: total
	}
	st.dl = ctl
	st.dl_threads << spawn dl_worker(st.ai_places, need_rt, ctl, mut app, st.dl_progress,
		st.dl_done)
	sync_settings_ui(mut st)
}

// DlTick - одно сообщение о прогрессе скачивания (post_result, post.v)
struct DlTick {
	on_progress fn (&DlCtl, i64) = unsafe { nil }
	ctl         &DlCtl = unsafe { nil }
	all         i64
}

fn deliver_dl_tick(t DlTick) {
	t.on_progress(t.ctl, t.all)
}

// dl_progress_fn - прогресс одной части задания (base - байт до неё) в
// главный поток; сообщается не чаще, чем раз в ~0.5 МБ
fn dl_progress_fn(mut app vgui.App, ctl &DlCtl, base i64, on_progress fn (&DlCtl, i64)) fn (i64, i64) bool {
	return fn [mut app, ctl, base, on_progress] (done i64, _ i64) bool {
		mut c := unsafe { ctl }
		all := base + done
		if all - c.posted >= 500_000 || all == c.total {
			c.posted = all
			post_result(mut app, deliver_dl_tick, DlTick{
				on_progress: on_progress
				ctl:         ctl
				all:         all
			})
		}
		return !c.cancel
	}
}

// dl_worker - скачивание в spawn: без State и vgui, кроме app.post
fn dl_worker(p ai.Places, need_rt bool, ctl &DlCtl, mut app vgui.App, on_progress fn (&DlCtl, i64), on_done fn (DlResult)) {
	mut res := DlResult{
		ctl: ctl
	}
	mut base := i64(0)
	mut failed := false
	if need_rt {
		ai.install_runtime(p, dl_progress_fn(mut app, ctl, base, on_progress)) or {
			res = DlResult{
				...res
				err:       err.msg()
				cancelled: err is ai.Cancelled
			}
			failed = true
		}
		base += ai.runtime_file.size
	}
	if !failed && ctl.model != '' {
		if info := ai.find_model_info(ctl.model) {
			ai.install_model(p, info, dl_progress_fn(mut app, ctl, base, on_progress)) or {
				res = DlResult{
					...res
					err:       err.msg()
					cancelled: err is ai.Cancelled
				}
			}
		}
	}
	post_result(mut app, on_done, res)
}

// dl_take - итог скачивания (главный поток)
fn dl_take(mut st State, res DlResult) {
	st.dl = unsafe { nil }
	if !isnil(st.nm) {
		mut nm := st.nm
		if res.cancelled {
			nm.show_warning('Скачивание отменено')
		} else if res.err != '' {
			nm.show_error('Не удалось скачать: ${res.err}')
		} else {
			nm.show_success('Скачано: ${res.ctl.what}')
		}
	}
	sync_settings_ui(mut st)
	sync_ai_ui(mut st)
}
