module main

// Окно «Настройки» (меню «Правка - Настройки...»), вкладки: «Общие» -
// оформление (тема и фон вокруг снимка - те же, что в меню «Вид»;
// масштаб интерфейса), память
// (кэш кадров, framecache.v); «Интерфейс» - панель инструментов и лента
// кадров (panel.v); «Разделы панели» - какие и в каком порядке; «Горячие
// клавиши». AI-шумодаву настраивать нечего: модель и ONNX Runtime идут
// вместе с vraw. Настройки экспорта - в окне «Экспорт» (export_setup.v).
// Диалог создаётся при первом открытии и живёт до выхода: закрытие только
// прячет.
import vgui
import imgio
import i18n

@[heap]
struct SettingsUi {
mut:
	dlg      &vgui.Dialog      = unsafe { nil }
	scroll   &vgui.ScrollBox = unsafe { nil } // корень: содержимое в прокрутке (dlgfit.v)
	theme_cb &vgui.ComboBox    = unsafe { nil }
	bg_cb    &vgui.ComboBox    = unsafe { nil }
	scale_sp &vgui.Spinbox     = unsafe { nil } // свой, %
	cache_ck &vgui.CheckBox    = unsafe { nil }
	cache_cb &vgui.ComboBox    = unsafe { nil }
	aicache_ck &vgui.CheckBox = unsafe { nil } // кэш AI на диске (aicache.v)
	demosaic_cb &vgui.ComboBox = unsafe { nil } // демозаика полного кадра
	// сколько помнить недавних файлов и папок (recent.v)
	rfiles_cb &vgui.ComboBox = unsafe { nil }
	rdirs_cb  &vgui.ComboBox = unsafe { nil }
	notes    []&vgui.Label // вторичные подписи - цвет по теме
	// Интерфейс (panel.v): панель, её сторона, лента, разделы панели
	panel_ck &vgui.CheckBox = unsafe { nil }
	side_cb  &vgui.ComboBox = unsafe { nil }
	strip_ck &vgui.CheckBox = unsafe { nil }
	top_cb   &vgui.ComboBox = unsafe { nil }
	fs_panel &vgui.CheckBox = unsafe { nil }
	fs_strip &vgui.CheckBox = unsafe { nil }
	sec_box  &vgui.VBox     = unsafe { nil } // ряды разделов по порядку
	sec_rows []SecRow // по индексу panel_sections
	// Горячие клавиши (hotkeys_ui.v): ряды по индексу st.hk, ждущий
	// нажатия ряд (-1 - нет), сообщение
	hk_rows []HkRow
	hk_msg  &vgui.Label = unsafe { nil }
	// подписи со вписанными сочетаниями (полноэкранный режим, F8 и F6)
	fs_cap  &vgui.Label = unsafe { nil }
	fs_note &vgui.Label = unsafe { nil }
}

// SecRow - ряд раздела панели в окне: показывать ли, вверх, вниз
struct SecRow {
	row  &vgui.HBox     = unsafe { nil }
	ck   &vgui.CheckBox = unsafe { nil }
	up   &vgui.Button   = unsafe { nil }
	down &vgui.Button   = unsafe { nil }
}

// fmt_title - формат в списке настроек: название и что это
fn fmt_title(f imgio.Format) string {
	return match f {
		.jpeg { i18n.tr('JPEG - компактный') }
		.png { i18n.tr('PNG - без потерь') }
		.tiff { i18n.tr('TIFF - для других программ') }
		.bmp { i18n.tr('BMP - без сжатия') }
		.qoi { i18n.tr('QOI - без потерь, быстрый') }
		.gif { i18n.tr('GIF - 256 цветов') }
	}
}

const set_path_max = 76 // символов в строке пути (ширина окна минус поля)
// show_settings - открыть окно настроек (создать при первом вызове)
fn show_settings(mut st State, mut app vgui.App, parent &vgui.Window) {
	if isnil(st.sui) {
		build_settings(mut st, mut app, parent) or {
			if !isnil(st.nm) {
				mut nm := st.nm
				nm.show_error(i18n.trf('Не удалось открыть настройки: {0}', '${err.msg()}'))
			}
			return
		}
	}
	mut u := st.sui
	hk_cancel_wait(mut u)
	u.hk_msg.text = ''
	sync_settings_ui(mut st)
	mut d := u.dlg
	if !d.is_open() {
		d.show()
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
// многоточием в начале (важен конец пути), полный - в подсказке подписи
// (поле tooltip, показывает окно vgui).
struct PathNote {
	label &vgui.Label = unsafe { nil }
	max   int // символов подписи вместе с префиксом - по ширине окна
}

const path_tip_line = 60 // символов в строке подсказки с путём

fn path_note(prefix string, path string, max int) PathNote {
	p := PathNote{
		label: vgui.label('')
		max:   max
	}
	p.set(prefix, path)
	return p
}

// set - подпись и подсказка. Перенос подсказки vgui - только по пробелам, в
// пути их обычно нет: строки режет path_tip, а строка без пробелов шире
// подсказки просто раздвигает её окно.
fn (p PathNote) set(prefix string, path string) {
	mut l := p.label
	l.text = prefix + elide_left(path, p.max - prefix.runes().len)
	l.tooltip = path_tip(path)
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
		title:     i18n.tr('Настройки')
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
	theme_cb.set_items(i18n.tr_all(theme_names))
	theme_cb.on_change = fn [mut st, mut app] (i int, _ string) {
		apply_theme(mut st, mut app, i)
	}
	u.theme_cb = theme_cb
	mut bg_cb := vgui.combo_box()
	bg_cb.set_items(i18n.tr_all(bg_names))
	bg_cb.on_change = fn [mut st] (i int, _ string) {
		set_viewer_bg(mut st, i)
	}
	u.bg_cb = bg_cb
	// Масштаб интерфейса - числом;
	// применяется кнопкой или Enter, не на каждую
	// цифру: при наборе «125» сначала пришло бы «1», а окно настроек
	// меняет размер под курсором
	mut scale_sp := vgui.spinbox()
	scale_sp.set_range(ui_scale_min, ui_scale_max)
	scale_sp.step = 5
	mut scale_ti := scale_sp.text_input
	scale_ti.max_len = 3 // больше ui_scale_max не набрать
	scale_ti.on_submit = fn [mut st] (_ string) {
		apply_scale_field(mut st)
	}
	u.scale_sp = scale_sp
	mut scale_ok := vgui.button(i18n.tr('Применить'))
	scale_ok.on_click = fn [mut st] () {
		apply_scale_field(mut st)
	}

	// ── Память: кэш кадров ──
	mut cache_ck := vgui.checkbox(i18n.tr('Держать недавние кадры в памяти'))
	cache_ck.on_change = fn [mut st] (v bool) {
		st.settings.no_frame_cache = !v
		frame_trim(mut st)
		save_settings(st.settings)
		sync_settings_ui(mut st)
	}
	u.cache_ck = cache_ck
	mut cache_cb := vgui.combo_box()
	cache_cb.set_items(frame_cache_mbs.map(fmt_cache_mb(it)))
	cache_cb.on_change = fn [mut st] (i int, _ string) {
		if i >= 0 && i < frame_cache_mbs.len {
			st.settings.frame_cache_mb = frame_cache_mbs[i]
			frame_trim(mut st)
			save_settings(st.settings)
		}
	}
	u.cache_cb = cache_cb
	// Кэш результата AI рядом со снимками (aicache.v)
	mut aicache_ck := vgui.checkbox(i18n.tr('Хранить результат AI-шумодава рядом со снимками'))
	aicache_ck.on_change = fn [mut st] (v bool) {
		st.settings.no_ai_cache = !v
		save_settings(st.settings)
	}
	u.aicache_ck = aicache_ck
	// Демозаика полного кадра (Settings.demosaic): 1:1 пересчитывается
	// сразу, экспорт - со следующего
	mut demosaic_cb := vgui.combo_box()
	demosaic_cb.set_items(demosaic_names)
	demosaic_cb.on_change = fn [mut st] (i int, _ string) {
		if i < 0 || i >= demosaic_keys.len || demosaic_keys[i] == st.settings.demosaic {
			return
		}
		st.settings.demosaic = demosaic_keys[i]
		save_settings(st.settings)
		detail_check(mut st)
	}
	u.demosaic_cb = demosaic_cb
	// Недавние: сколько помнить (лишнее с конца - сразу)
	mut rfiles_cb := vgui.combo_box()
	rfiles_cb.set_items(recent_counts.map('${it}'))
	rfiles_cb.on_change = fn [mut st] (i int, _ string) {
		if i >= 0 && i < recent_counts.len {
			set_recent_limit(mut st, false, recent_counts[i])
		}
	}
	u.rfiles_cb = rfiles_cb
	mut rdirs_cb := vgui.combo_box()
	rdirs_cb.set_items(recent_counts.map('${it}'))
	rdirs_cb.on_change = fn [mut st] (i int, _ string) {
		if i >= 0 && i < recent_counts.len {
			set_recent_limit(mut st, true, recent_counts[i])
		}
	}
	u.rdirs_cb = rdirs_cb

	// Колонки - по самым длинным текстам (шрифтом окна)
	mut dw := &dlg.win
	btn_col := column_width(mut dw, [i18n.tr('Закрыть')], 0) + 2 * vgui.measure_pad_x
	look_col := column_width(mut dw, [i18n.tr('Тема'), i18n.tr('Фон вокруг снимка'), i18n.tr('Масштаб интерфейса'),
		i18n.tr('Не больше'), i18n.tr('Файлов'), i18n.tr('Папок'), i18n.tr('Демозаика')], 8)
	// Списки оформления - одной ширины, по самому длинному пункту обоих
	// (24 - стрелка ComboBox, как в его measure)
	mut look_items := i18n.tr_all(theme_names)
	look_items << i18n.tr_all(bg_names)
	look_w := column_width(mut dw, look_items, 0) +
		2 * theme_cb.pad + 24
	// ── Вкладка «Общие» ──
	mut general := tab_page()
	general.add(caption(i18n.tr('Оформление')))
	general.add(labeled(i18n.tr('Тема'), theme_cb, look_col, look_w))
	general.add(labeled(i18n.tr('Фон вокруг снимка'), bg_cb, look_col, look_w))
	mut scale_row := vgui.create_hbox_fill()
	scale_row.set_spacing(8)
	scale_row.add(vgui.label(i18n.tr('Масштаб интерфейса')), min: look_col)
	// Ширина поля - явно: measure Spinbox кладёт на две кнопки 44 px, а
	// они квадратные по высоте поля - число обрезалось
	scale_row.add(scale_sp, min: column_width(mut dw, ['300'], 0) + 2 * vgui.measure_pad_x +
		2 * dw.ctx.control_h())
	scale_row.add(vgui.label('%'))
	scale_row.add(scale_ok)
	scale_row.add(vgui.create_spacer(), flex: 1)
	general.add(scale_row)

	general.add(caption(i18n.tr('Память')))
	general.add(cache_ck)
	general.add(labeled(i18n.tr('Не больше'), cache_cb, look_col, look_w))
	general.add(note(mut u, i18n.tr('Возврат к недавнему кадру - мгновенно, без повторной проявки (~110-150 МБ на кадр 24 Мп)')))
	general.add(aicache_ck)
	general.add(note(mut u, i18n.tr('Папка .vraw-cache рядом с RAW, ~145 МБ на кадр 24 Мп: повторный AI - за секунду вместо ~16 минут')))

	general.add(caption(i18n.tr('Проявка')))
	general.add(labeled(i18n.tr('Демозаика'), demosaic_cb, look_col, look_w))
	general.add(note(mut u, i18n.tr('Разница - в мелких деталях: муар, «лабиринт», ступеньки на тонких линиях')))
	general.add(note(mut u, i18n.tr('Видна при 100% и в экспорте: превью - половинного размера, без демозаики')))

	general.add(caption(i18n.tr('Недавние')))
	general.add(labeled(i18n.tr('Файлов'), rfiles_cb, look_col, look_w))
	general.add(labeled(i18n.tr('Папок'), rdirs_cb, look_col, look_w))
	general.add(note(mut u, i18n.tr('Сколько помнить в меню «Файл - Недавние файлы» и «Недавние папки»')))

	// ── Вкладка «Интерфейс» ──
	iface, secs := build_iface_tab(mut st, mut u, mut dw)

	mut tabs := vgui.tab_box()
	tabs.add_tab(i18n.tr('Общие'), general)
	tabs.add_tab(i18n.tr('Интерфейс'), iface)
	tabs.add_tab(i18n.tr('Разделы панели'), secs)
	tabs.add_tab(i18n.tr('Горячие клавиши'), build_hotkeys_tab(mut st, mut u, mut dw))

	// ── Где что лежит, закрыть ──
	mut outer := vgui.create_vbox_fill()
	outer.set_padding(16)
	outer.set_spacing(6)
	outer.add(tabs, flex: 1)
	path := path_note(i18n.tr('Настройки: '), settings_path(), set_path_max)
	u.notes << path.label
	outer.add(path.label)
	mut close := vgui.button(i18n.tr('Закрыть'))
	close.style = .accent
	close.on_click = fn [mut dlg] () {
		dlg.close_with_result(0)
	}
	mut close_row := vgui.create_hbox_fill()
	close_row.add(vgui.create_spacer(), flex: 1)
	close_row.add(close, min: btn_col)
	outer.add(close_row)

	u.scroll = dialog_scroll(outer)
	dlg.add_widget(u.scroll)
	app.add_dialog(dlg)
	st.sui = u
	paint_settings(mut st)
}

// tab_page - содержимое вкладки окна: ряды естественной высоты с полями
fn tab_page() &vgui.VBox {
	mut v := vgui.create_vbox_fill()
	v.set_padding(12)
	v.set_spacing(6)
	return v
}

// build_lang_row - язык интерфейса: «Как в системе» и языки i18n.langs
// самоназваниями. Окно строится один раз, поэтому новый язык - после
// перезапуска; подпись об этом - сразу на выбранном языке.
fn build_lang_row(mut st State) &vgui.VBox {
	sys := system_lang()
	sys_name := i18n.langs.filter(it.code == sys)[0].name
	mut items := ['${i18n.tr('Как в системе')} (${sys_name})']
	items << i18n.langs.map(it.name)
	mut cb := vgui.combo_box()
	cb.set_items(items)
	idx := i18n.langs.map(it.code).index(st.settings.lang)
	cb.set_selected(idx + 1)
	mut restart := vgui.label('')
	restart.visible = false
	cb.on_change = fn [mut st, mut restart] (i int, _ string) {
		code := if i <= 0 { '' } else { i18n.langs[i - 1].code }
		if code == st.settings.lang {
			return
		}
		st.settings.lang = code
		save_settings(st.settings)
		shown := if code == '' { system_lang() } else { code }
		restart.text = i18n.tr_in(shown, 'Язык сменится после перезапуска программы')
		restart.visible = shown != i18n.current()
	}
	mut v := vgui.create_vbox_fill()
	v.set_spacing(4)
	v.add(cb)
	v.add(restart)
	return v
}

// build_iface_tab - вкладки «Интерфейс» (видимость панели инструментов
// и ленты в окне и в полноэкранном режиме, их стороны) и «Разделы
// панели» (показывать ли, порядок кнопками вверх/вниз; отдельной
// вкладкой - иначе окно выше экрана). Ряды разделов создаются один раз,
// порядок - пересборкой sec_box (sync_settings_ui).
fn build_iface_tab(mut st State, mut u SettingsUi, mut dw vgui.Window) (&vgui.VBox, &vgui.VBox) {
	mut panel_ck := vgui.checkbox(i18n.tr('Показывать панель инструментов (F8)'))
	panel_ck.on_change = fn [mut st] (v bool) {
		set_panel_visible(mut st, false, v)
	}
	u.panel_ck = panel_ck
	mut side_cb := vgui.combo_box()
	side_cb.set_items(i18n.tr_all(panel_side_names))
	side_cb.on_change = fn [mut st] (i int, _ string) {
		set_panel_left(mut st, i == 1)
	}
	u.side_cb = side_cb
	mut strip_ck := vgui.checkbox(i18n.tr('Показывать ленту кадров (F6)'))
	strip_ck.on_change = fn [mut st] (v bool) {
		set_strip_visible(mut st, false, v)
	}
	u.strip_ck = strip_ck
	mut top_cb := vgui.combo_box()
	top_cb.set_items(i18n.tr_all(strip_side_names))
	top_cb.on_change = fn [mut st] (i int, _ string) {
		set_strip_top(mut st, i == 1)
	}
	u.top_cb = top_cb
	mut fs_panel := vgui.checkbox(i18n.tr('Панель инструментов'))
	fs_panel.on_change = fn [mut st] (v bool) {
		set_panel_visible(mut st, true, v)
	}
	u.fs_panel = fs_panel
	mut fs_strip := vgui.checkbox(i18n.tr('Лента кадров'))
	fs_strip.on_change = fn [mut st] (v bool) {
		set_strip_visible(mut st, true, v)
	}
	u.fs_strip = fs_strip
	side_col := column_width(mut dw, [i18n.tr('Расположение панели'), i18n.tr('Расположение ленты')], 8)
	mut side_items := i18n.tr_all(panel_side_names)
	side_items << i18n.tr_all(strip_side_names)
	side_w := column_width(mut dw, side_items, 0) + 2 * side_cb.pad + 24

	for sec in panel_sections {
		key := sec.key
		mut ck := vgui.checkbox(i18n.tr(sec.title))
		ck.on_change = fn [mut st, key] (v bool) {
			mut hidden := st.settings.panel_hidden.filter(it != key)
			if !v {
				hidden << key
			}
			set_panel_sections(mut st, st.settings.panel_order, hidden)
		}
		mut up := vgui.button('')
		up.icon_name = 'chevron-up'
		up.icon_size = 15
		up.style = .flat
		up.on_click = fn [mut st, key] () {
			set_panel_sections(mut st, panel_move(panel_order_from(st.settings.panel_order),
				key, -1), st.settings.panel_hidden)
		}
		mut down := vgui.button('')
		down.icon_name = 'chevron-down'
		down.icon_size = 15
		down.style = .flat
		down.on_click = fn [mut st, key] () {
			set_panel_sections(mut st, panel_move(panel_order_from(st.settings.panel_order),
				key, 1), st.settings.panel_hidden)
		}
		mut row := vgui.create_hbox_fill()
		row.set_spacing(4)
		row.add(ck, flex: 1)
		row.add(up, min: icon_slot_w)
		row.add(down, min: icon_slot_w)
		u.sec_rows << SecRow{
			row:  row
			ck:   ck
			up:   up
			down: down
		}
	}
	mut sec_box := vgui.create_vbox_fill()
	sec_box.set_spacing(2)
	u.sec_box = sec_box
	mut reset := vgui.button(i18n.tr('Как было'))
	reset.on_click = fn [mut st] () {
		set_panel_sections(mut st, panel_default_order(), [])
	}
	mut reset_row := vgui.create_hbox_fill()
	reset_row.add(reset)
	reset_row.add(vgui.create_spacer(), flex: 1)

	mut v := tab_page()
	v.add(caption(i18n.tr('Язык')))
	v.add(build_lang_row(mut st))
	v.add(caption(i18n.tr('Окно')))
	v.add(panel_ck)
	v.add(labeled(i18n.tr('Расположение панели'), side_cb, side_col, side_w))
	v.add(strip_ck)
	v.add(labeled(i18n.tr('Расположение ленты'), top_cb, side_col, side_w))
	u.fs_cap = caption(i18n.tr('Полноэкранный режим'))
	v.add(u.fs_cap)
	u.fs_note = note(mut u, '')
	v.add(u.fs_note)
	v.add(fs_panel)
	v.add(fs_strip)
	mut secs := tab_page()
	secs.add(caption(i18n.tr('Разделы панели инструментов')))
	secs.add(note(mut u, i18n.tr('Гистограмма - всегда вверху. Скрытый раздел не показан, но его настройки действуют.')))
	secs.add(sec_box)
	secs.add(reset_row)
	return v, secs
}

// sync_iface - вкладка «Интерфейс» по настройкам: флажки, сторона,
// ряды разделов в текущем порядке; у крайних нет кнопки «вверх»/«вниз»
fn sync_iface(mut u SettingsUi, s &Settings) {
	if isnil(u.sec_box) {
		return
	}
	mut pck := u.panel_ck
	pck.checked = !s.no_panel
	mut scb := u.side_cb
	scb.set_selected(if s.panel_left { 1 } else { 0 })
	scb.enabled = !s.no_panel
	mut sck := u.strip_ck
	sck.checked = !s.no_strip
	mut tcb := u.top_cb
	tcb.set_selected(if s.strip_top { 1 } else { 0 })
	tcb.enabled = !s.no_strip
	mut fpc := u.fs_panel
	fpc.checked = s.fs_panel
	mut fsc := u.fs_strip
	fsc.checked = s.fs_strip
	order := panel_order_from(s.panel_order)
	mut box := u.sec_box
	box.clear()
	for pos, key in order {
		r := u.sec_rows[panel_section_index(key)]
		mut ck := r.ck
		ck.checked = key !in s.panel_hidden
		mut up := r.up
		up.enabled = pos > 0
		mut down := r.down
		down.enabled = pos < order.len - 1
		box.add(r.row)
	}
}

// apply_scale_field - свой масштаб из поля; в поле - что применилось
// (число вне пределов - ближайший предел)
fn apply_scale_field(mut st State) {
	mut sp := st.sui.scale_sp
	apply_ui_scale(mut st, sp.value)
	sp.set_value(ui_scale_pct(st.settings.ui_scale))
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
	pct := ui_scale_pct(st.settings.ui_scale)
	// Пока в поле печатают - число не трогать (окно обновляется и от
	// скачивания)
	mut ssp := u.scale_sp
	if !ssp.text_input.focused {
		ssp.set_value(pct)
	}
	mut ck := u.cache_ck
	ck.checked = !st.settings.no_frame_cache
	mut ccb := u.cache_cb
	mb := if st.settings.frame_cache_mb > 0 { st.settings.frame_cache_mb } else { frame_cache_mb_default }
	ci := frame_cache_mbs.index(mb)
	ccb.set_selected(if ci >= 0 { ci } else { frame_cache_mbs.index(frame_cache_mb_default) })
	ccb.enabled = ck.checked
	mut ack := u.aicache_ck
	ack.checked = !st.settings.no_ai_cache
	mut dcb := u.demosaic_cb
	dcb.set_selected(demosaic_keys.index(st.settings.demosaic))
	mut rf := u.rfiles_cb
	rf.set_selected(recent_counts.index(recent_limit(st.settings.recent_files_n)))
	mut rd := u.rdirs_cb
	rd.set_selected(recent_counts.index(recent_limit(st.settings.recent_dirs_n)))
	sync_iface(mut u, st.settings)
	sync_hotkeys_ui(mut u, st)
	sync_hk_texts(mut u, st)
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

// fmt_cache_mb - предел кэша кадров в списке настроек
fn fmt_cache_mb(mb int) string {
	return if mb < 1024 { i18n.trf('{0} МБ', '${mb}') } else if mb % 1024 == 0 { i18n.trf('{0} ГБ', '${mb / 1024}') } else { i18n.trf('{0} ГБ', '${f64(mb) / 1024:.1f}') }
}

// sync_hk_texts - подписи вкладки «Интерфейс» с текущими сочетаниями
// (hotkeys.v): флажки панели и ленты, полноэкранный режим
fn sync_hk_texts(mut u SettingsUi, st &State) {
	if isnil(u.panel_ck) {
		return
	}
	mut pck := u.panel_ck
	pck.text = i18n.trf('Показывать панель инструментов{0}', '${hk_paren(st, 'view.panel')}')
	mut sck := u.strip_ck
	sck.text = i18n.trf('Показывать ленту кадров{0}', '${hk_paren(st, 'view.strip')}')
	mut cap := u.fs_cap
	cap.text = i18n.trf('Полноэкранный режим{0}', '${hk_paren(st, 'view.full')}')
	kp := hk_key(st, 'view.panel')
	ks := hk_key(st, 'view.strip')
	keys := [kp, ks].filter(it.len > 0)
	mut n := u.fs_note
	n.text = if keys.len > 0 {
		i18n.trf('Что показывать вокруг снимка; {0} в режиме - то же', keys.join(i18n.tr(' и ')))
	} else {
		i18n.tr('Что показывать вокруг снимка')
	}
}
