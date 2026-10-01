module main

// Окно «Экспорт» (Ctrl+E, «Файл - Экспорт...»): что экспортировать
// (открытый кадр, выделенные в ленте, вся папка - пакет, batch.v), куда и
// как - папка, имя по шаблону, формат и качество, размер на
// выход, что делать с существующим файлом, AI-шумодав. Выбор запоминается
// в настройках программы (settings.v) - его же возьмёт пакетная обработка.
// Размер на выход - настройка экспорта, а не кадра (как в Lightroom):
// у кадра только рамка (crop.v).
import os
import math
import time
import vgui
import raw
import imgio

const name_tmpl_default = '{name}'
// Размер на выход: ключи (Settings.export_size) и названия
const export_size_keys = ['', 'long', 'fit', 'pct']
const export_size_names = ['Как есть', 'По длинной стороне', 'Вписать в Ш × В', 'В процентах']
const export_px_max = 30000

// clamp_px - размер в пикселях из настроек: вне 1..export_px_max - def
fn clamp_px(v int, def int) int {
	return if v >= 1 && v <= export_px_max { v } else { def }
}

// ExportSize - размер на выход (снимок настроек для воркера)
struct ExportSize {
	mode string // ключ export_size_keys
	long int
	w    int
	h    int
	pct  int
}

fn (s &Settings) export_size_opts() ExportSize {
	return ExportSize{
		mode: s.export_size
		long: s.export_long
		w:    s.export_w
		h:    s.export_h
		pct:  s.export_pct
	}
}

// export_dims - размер файла для обрезанного кадра cw x ch: уменьшение с
// сохранением пропорций, кадр не увеличивается (увеличение не добавит
// деталей, только размер файла)
fn export_dims(sz ExportSize, cw int, ch int) (int, int) {
	if cw <= 0 || ch <= 0 {
		return cw, ch
	}
	k := match sz.mode {
		'long' {
			f64(sz.long) / f64(math.max(cw, ch))
		}
		'fit' {
			math.min(f64(sz.w) / f64(cw), f64(sz.h) / f64(ch))
		}
		'pct' {
			f64(sz.pct) / 100
		}
		else {
			1.0
		}
	}
	if k >= 1 || k <= 0 {
		return cw, ch
	}
	// Длинная сторона - ровно по заданию, короткая - пропорцией
	if cw >= ch {
		w := int(math.max(1, math.round(f64(cw) * k)))
		return w, int(math.max(1, math.round(f64(ch) * f64(w) / f64(cw))))
	}
	h := int(math.max(1, math.round(f64(ch) * k)))
	return int(math.max(1, math.round(f64(cw) * f64(h) / f64(ch)))), h
}

// NameInfo - что подставляется в шаблон имени кроме имени RAW: номер
// кадра в экспорте (с 1) и их число (ширина номера), дата съёмки
// (unix-секунды; 0 - нет)
struct NameInfo {
	num   int = 1
	count int = 1
	shot  i64
}

// Переменные шаблона имени (английские): {name} - имя RAW без
// расширения, {num} - номер в экспорте (001, 002...; шире, если кадров
// больше 999), {date} - дата съёмки 2026-09-28

// export_file_name - имя файла без расширения по шаблону; символы,
// недопустимые в имени, - на «_»; пустой результат - имя RAW
fn export_file_name(tmpl string, raw_path string, ni NameInfo) string {
	base := os.file_name(raw_path).all_before_last('.')
	mut n := tmpl.replace('{name}', base)
	if n.contains('{num}') {
		num := '${ni.num}'
		w := math.max(3, '${ni.count}'.len)
		n = n.replace('{num}', '0'.repeat(math.max(0, w - num.len)) + num)
	}
	if n.contains('{date}') {
		n = n.replace('{date}', shot_date(ni.shot, raw_path))
	}
	for c in ['/', '\\', ':', '*', '?', '"', '<', '>', '|'] {
		n = n.replace(c, '_')
	}
	n = n.trim_space().trim_right('.')
	return if n.len == 0 { base } else { n }
}

// name_tmpl_migrate - шаблон имени из настроек: пустой - по умолчанию,
// {имя} (до 01.10.2026, переменные стали английскими) - {name}
fn name_tmpl_migrate(t string) string {
	return if t.trim_space() == '' { name_tmpl_default } else { t.replace('{имя}', '{name}') }
}

// shot_date - дата съёмки «2026-09-28»; нет в EXIF - дата изменения файла
fn shot_date(shot i64, raw_path string) string {
	ts := if shot > 0 { shot } else { os.file_last_mod_unix(raw_path) }
	t := time.unix(ts).local()
	return '${t.year:04}-${t.month:02}-${t.day:02}'
}

// raw_shot - дата съёмки RAW-файла (0 - не читается); открытие LibRaw без
// распаковки - единицы мс
fn raw_shot(path string) i64 {
	mut d := raw.open(path) or { return 0 }
	defer {
		d.close()
	}
	return d.meta().shot
}

// export_dir_for - папка экспорта: рядом с RAW или выбранная
fn export_dir_for(s &Settings, raw_path string) string {
	return if s.export_dir_mode == 'dir' && s.export_dir != '' {
		s.export_dir
	} else {
		os.dir(raw_path)
	}
}

// export_path - путь файла: папка, имя по шаблону, расширение формата;
// файл есть и выбрано «добавить номер» - «имя-2», «имя-3»...
fn export_path(s &Settings, raw_path string, f imgio.Format) string {
	return export_path_taken(s, raw_path, f, map[string]bool{}, NameInfo{})
}

// export_path_taken - то же, но пути taken тоже заняты (пакет: кадры,
// которые ещё проявляются, файлов пока не записали)
fn export_path_taken(s &Settings, raw_path string, f imgio.Format, taken map[string]bool, ni NameInfo) string {
	dir := export_dir_for(s, raw_path)
	// Дата съёмки - только если она в шаблоне (открытие RAW)
	info := if s.export_name.contains('{date}') && ni.shot == 0 {
		NameInfo{
			...ni
			shot: raw_shot(raw_path)
		}
	} else {
		ni
	}
	name := export_file_name(s.export_name, raw_path, info)
	ext := f.ext()
	mut p := os.join_path(dir, '${name}.${ext}')
	if s.export_exists == 'overwrite' && p !in taken {
		return p
	}
	mut i := 2
	for os.exists(p) || p in taken {
		p = os.join_path(dir, '${name}-${i}.${ext}')
		i++
	}
	return p
}

// ── Окно ──

@[heap]
struct ExportSetupUi {
mut:
	dlg     &vgui.Dialog   = unsafe { nil }
	what_cb &vgui.ComboBox = unsafe { nil }
	// Варианты «Кадры» на момент открытия окна (ключи: 'open', 'sel',
	// 'all') и выбранный; выбор не запоминается - зависит от ленты
	what_keys []string
	what      string
	dir_cb  &vgui.ComboBox = unsafe { nil }
	dir_btn &vgui.Button   = unsafe { nil }
	dir     PathNote
	name    &vgui.TextInput = unsafe { nil }
	fmt_cb  &vgui.ComboBox  = unsafe { nil }
	q_sl    &vgui.Slider    = unsafe { nil }
	q_vl    &vgui.Label     = unsafe { nil }
	size_cb &vgui.ComboBox  = unsafe { nil }
	sa      &vgui.Spinbox   = unsafe { nil } // длинная сторона / ширина / проценты
	sb      &vgui.Spinbox   = unsafe { nil } // высота (вписать в Ш × В)
	times   &vgui.Label     = unsafe { nil }
	unit    &vgui.Label     = unsafe { nil }
	size_row &vgui.HBox     = unsafe { nil } // пересобирается под режим
	size_mode string = '?' // режим, под который собран size_row
	ex_cb   &vgui.ComboBox  = unsafe { nil }
	load_cb &vgui.ComboBox  = unsafe { nil }
	load_nt &vgui.Label     = unsafe { nil }
	ai_cb   &vgui.CheckBox  = unsafe { nil }
	result  &vgui.Label     = unsafe { nil }
	notes   []&vgui.Label
}

const xs_w = 680
const xs_h = 620
const xs_lbl_w = f32(150)
const xs_path_max = 56

const export_dir_names = ['Рядом с RAW-файлом', 'Выбранная папка']
const export_exists_keys = ['number', 'overwrite']
const export_exists_names = ['Добавить номер (имя-2, имя-3...)', 'Перезаписать']

// show_export_setup - окно «Экспорт» перед запуском (создать при первом
// вызове); «Экспорт» в нём зовёт st.export_go
fn show_export_setup(mut st State, mut app vgui.App, parent &vgui.Window) {
	if isnil(st.xs) {
		build_export_setup(mut st, mut app, parent) or {
			if !isnil(st.nm) {
				mut nm := st.nm
				nm.show_error('Не удалось открыть окно экспорта: ${err.msg()}')
			}
			return
		}
	}
	set_export_targets(mut st)
	sync_export_setup(mut st)
	mut d := st.xs.dlg
	if !d.is_open() {
		d.show_scaled(parent)
	}
}

// set_export_targets - варианты «Кадры» по ленте: выделено больше одного
// кадра - по умолчанию они, иначе открытый кадр, иначе вся папка
fn set_export_targets(mut st State) {
	mut u := st.xs
	sel := strip_selection(st)
	mut keys := []string{}
	mut names := []string{}
	if !isnil(st.dev) {
		keys << 'open'
		names << 'Открытый кадр (${os.file_name(st.dev.path)})'
	}
	if sel.len > 1 {
		keys << 'sel'
		names << 'Выделенные в ленте (${sel.len})'
	}
	if st.frames.len > 1 || (st.frames.len == 1 && keys.len == 0) {
		keys << 'all'
		names << 'Все кадры папки (${st.frames.len})'
	}
	u.what_keys = keys
	u.what = if 'sel' in keys {
		'sel'
	} else if keys.len > 0 {
		keys[0]
	} else {
		''
	}
	mut cb := u.what_cb
	cb.set_items(names)
	cb.set_selected(math.max(0, keys.index(u.what)))
	cb.enabled = keys.len > 1
}

// strip_selection - выделенные в ленте кадры (индексы)
fn strip_selection(st &State) []int {
	if isnil(st.strip) {
		return []int{}
	}
	return st.strip.get_selection().filter(it >= 0 && it < st.frames.len)
}

// export_target_paths - RAW-файлы по выбору «Кадры»
fn export_target_paths(st &State, what string) []string {
	return match what {
		'open' {
			if isnil(st.dev) { []string{} } else { [st.dev.path] }
		}
		'sel' {
			strip_selection(st).map(st.frames[it].path)
		}
		'all' {
			st.frames.map(it.path)
		}
		else {
			[]string{}
		}
	}
}

// size_desc - размер на выход словами (итог пакета)
fn size_desc(s &Settings) string {
	return match s.export_size {
		'long' { 'длинная сторона до ${s.export_long} px' }
		'fit' { 'в пределах ${s.export_w} × ${s.export_h} px' }
		'pct' { '${s.export_pct}% размера' }
		else { 'полный размер' }
	}
}

// sync_export_setup - виджеты окна из настроек; итог - по открытому кадру
fn sync_export_setup(mut st State) {
	if isnil(st.xs) {
		return
	}
	mut u := st.xs
	s := st.settings
	was := st.suppress
	st.suppress = true
	mut dcb := u.dir_cb
	dcb.set_selected(if s.export_dir_mode == 'dir' { 1 } else { 0 })
	mut db := u.dir_btn
	db.enabled = true
	raw_path := if isnil(st.dev) { '' } else { st.dev.path }
	u.dir.set('Папка: ', if raw_path == '' && s.export_dir_mode != 'dir' {
		'рядом с RAW-файлом'
	} else {
		export_dir_for(&s, raw_path)
	})
	mut nm := u.name
	if nm.get_text() != s.export_name {
		nm.set_text(s.export_name)
	}
	f := s.export_fmt()
	mut fcb := u.fmt_cb
	fcb.set_selected(imgio.formats.index(f))
	mut q := u.q_sl
	q.set_value(s.jpeg_quality)
	q.enabled = f == .jpeg
	mut qv := u.q_vl
	qv.text = if f == .jpeg { '${s.jpeg_quality}' } else { '-' }
	mut scb := u.size_cb
	scb.set_selected(math.max(0, export_size_keys.index(s.export_size)))
	mut sa := u.sa
	mut sb := u.sb
	mut times := u.times
	mut unit := u.unit
	match s.export_size {
		'long' {
			sa.set_range(16, export_px_max)
			sa.set_value(s.export_long)
		}
		'fit' {
			sa.set_range(16, export_px_max)
			sa.set_value(s.export_w)
			sb.set_value(s.export_h)
		}
		'pct' {
			sa.set_range(1, 100)
			sa.set_value(s.export_pct)
		}
		else {}
	}
	unit.text = if s.export_size == 'pct' { '%' } else { 'px' }
	if u.size_mode != s.export_size {
		// Только нужные поля, единица - сразу за ними (скрытые виджеты
		// место в ряду занимают; VBox/HBox.remove не работает - clear + add)
		u.size_mode = s.export_size
		mut r := u.size_row
		r.clear()
		r.add_fixed(vgui.label('Размер'), xs_lbl_w)
		r.add_fixed(u.size_cb, 190)
		if s.export_size != '' {
			r.add_fixed(sa, 110)
			if s.export_size == 'fit' {
				r.add_fixed(times, 10)
				r.add_fixed(sb, 110)
			}
			r.add_fixed(unit, 22)
		}
		r.add(vgui.create_spacer(), 1)
	}
	mut ecb := u.ex_cb
	ecb.set_selected(math.max(0, export_exists_keys.index(s.export_exists)))
	mut acb := u.ai_cb
	acb.checked = !s.export_no_ai
	mut lcb := u.load_cb
	li := math.max(0, load_keys.index(s.export_load))
	lcb.set_selected(li)
	mut lnt := u.load_nt
	lnt.text = load_notes[li]
	st.suppress = was
	sync_export_result(mut st)
}

// sync_export_result - строка итога: имя файла и размер
fn sync_export_result(mut st State) {
	if isnil(st.xs) {
		return
	}
	mut r := st.xs.result
	s := st.settings
	f := s.export_fmt()
	if st.xs.what != 'open' {
		paths := export_target_paths(st, st.xs.what)
		if paths.len == 0 {
			r.text = 'Нет кадров'
			return
		}
		first := os.file_name(export_path_taken(&s, paths[0], f, map[string]bool{},
			NameInfo{ count: paths.len }))
		r.text = '${paths.len} ${plural(paths.len, 'кадр', 'кадра', 'кадров')}: ${first}...  ·  ${size_desc(&s)}'
		return
	}
	if isnil(st.dev) {
		r.text = 'Кадр не открыт'
		return
	}
	name := os.file_name(export_path(&s, st.dev.path, f))
	fw, fh := full_size(st)
	cw, ch := crop_size(&st.edit, fw, fh)
	ow, oh := export_dims(s.export_size_opts(), cw, ch)
	r.text = '${name}  ·  ${size_text(ow, oh)} px'
}

// export_setup_changed - выбор в окне изменился: запомнить и обновить
fn export_setup_changed(mut st State) {
	save_settings(st.settings)
	sync_settings_ui(mut st)
	sync_export_setup(mut st)
}

// export_confirm - «Экспорт»: проверка папки, запуск, окно закрывается
fn export_confirm(mut st State) {
	mut nm := st.nm
	// Имя из поля - и без Enter
	t := st.xs.name.get_text()
	st.settings.export_name = if t.trim_space() == '' { name_tmpl_default } else { t }
	save_settings(st.settings)
	if st.xs.what != 'open' {
		paths := export_target_paths(st, st.xs.what)
		if paths.len == 0 {
			nm.show_warning('Нет кадров для экспорта')
			return
		}
		if st.settings.export_dir_mode == 'dir' && !os.is_dir(st.settings.export_dir) {
			nm.show_error('Папки нет: ${st.settings.export_dir}')
			return
		}
		mut d := st.xs.dlg
		d.close_with_result(1)
		if !isnil(st.export_batch) {
			st.export_batch(paths)
		}
		return
	}
	if isnil(st.dev) {
		nm.show_warning('Сначала откройте RAW-файл')
		return
	}
	dir := export_dir_for(&st.settings, st.dev.path)
	if !os.is_dir(dir) {
		nm.show_error('Папки нет: ${dir}')
		return
	}
	f := st.settings.export_fmt()
	path := export_path(&st.settings, st.dev.path, f)
	mut d := st.xs.dlg
	d.close_with_result(1)
	if !isnil(st.export_go) {
		st.export_go(path, f)
	}
}

fn build_export_setup(mut st State, mut app vgui.App, parent &vgui.Window) ! {
	mut u := &ExportSetupUi{}
	mut dlg := vgui.create_dialog(
		title:     'Экспорт'
		width:     xs_w
		height:    xs_h
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
	row := fn (text string, w &vgui.Widget) &vgui.HBox {
		mut r := vgui.create_hbox_fill()
		r.set_spacing(8)
		r.add_fixed(vgui.label(text), xs_lbl_w)
		r.add(w, 1)
		return r
	}

	// Кадры: открытый, выделенные в ленте, вся папка
	mut what_cb := vgui.combo_box()
	what_cb.on_change = fn [mut st] (i int, _ string) {
		if st.suppress || isnil(st.xs) || i < 0 || i >= st.xs.what_keys.len {
			return
		}
		mut u := st.xs
		u.what = u.what_keys[i]
		sync_export_result(mut st)
	}
	u.what_cb = what_cb

	// Папка
	mut dir_cb := vgui.combo_box()
	dir_cb.set_items(export_dir_names)
	dir_cb.on_change = fn [mut st, mut app, dlg] (i int, _ string) {
		if st.suppress {
			return
		}
		if i == 1 && st.settings.export_dir == '' {
			// Папки ещё нет - сразу выбрать; отказ - остаётся «рядом с RAW»
			dir := vgui.native_select_folder_dialog(dlg.win, mut app, vgui.NativeFileDialogConfig{})
			if dir.len > 0 {
				st.settings.export_dir = dir
			}
		}
		st.settings.export_dir_mode = if i == 1 && st.settings.export_dir != '' { 'dir' } else { 'raw' }
		export_setup_changed(mut st)
	}
	u.dir_cb = dir_cb
	mut dir_btn := vgui.button('Выбрать...')
	dir_btn.style = .outline
	dir_btn.on_click = fn [mut st, mut app, dlg] () {
		start := if st.settings.export_dir != '' {
			st.settings.export_dir
		} else if !isnil(st.dev) {
			os.dir(st.dev.path)
		} else {
			''
		}
		dir := vgui.native_select_folder_dialog(dlg.win, mut app, vgui.NativeFileDialogConfig{
			start_dir: start
		})
		if dir.len > 0 {
			st.settings.export_dir = dir
			st.settings.export_dir_mode = 'dir'
			export_setup_changed(mut st)
		}
	}
	u.dir_btn = dir_btn
	mut dir_row := vgui.create_hbox_fill()
	dir_row.set_spacing(8)
	dir_row.add_fixed(vgui.label('Папка'), xs_lbl_w)
	dir_row.add(dir_cb, 1)
	dir_row.add_fixed(dir_btn, 110)
	dir_note := path_note('Папка: ', '', xs_path_max)
	u.dir = dir_note
	u.notes << dir_note.label

	// Имя файла
	mut name := vgui.text_input('шаблон имени')
	name.max_len = 200
	name.on_change = fn [mut st] (t string) {
		if st.suppress {
			return
		}
		st.settings.export_name = if t.trim_space() == '' { name_tmpl_default } else { t }
		save_settings(st.settings)
		sync_export_result(mut st)
	}
	name.on_submit = fn [mut st] (_ string) {
		export_confirm(mut st)
	}
	u.name = name
	mut name_note := vgui.label('{name} - имя RAW, {num} - номер (001), {date} - дата съёмки')
	u.notes << name_note

	// Формат и качество
	mut fmt_cb := vgui.combo_box()
	fmt_cb.set_items(imgio.formats.map(fmt_title(it)))
	fmt_cb.on_change = fn [mut st] (i int, _ string) {
		if st.suppress || i < 0 || i >= imgio.formats.len {
			return
		}
		st.settings.export_format = imgio.formats[i].key()
		export_setup_changed(mut st)
	}
	u.fmt_cb = fmt_cb
	mut q_vl := value_label('')
	u.q_vl = q_vl
	mut q_sl := vgui.slider_horizontal(jpeg_q_min, 100, st.settings.jpeg_quality)
	q_sl.step = 1
	q_sl.on_change = fn [mut st, mut q_vl] (v f32) {
		if st.suppress {
			return
		}
		q_vl.text = '${int(v)}'
		if int(v) != st.settings.jpeg_quality {
			st.settings.jpeg_quality = int(v)
			save_settings(st.settings)
		}
	}
	u.q_sl = q_sl
	mut q_row := vgui.create_hbox_fill()
	q_row.set_spacing(8)
	q_row.add_fixed(vgui.label('Качество JPEG'), xs_lbl_w)
	q_row.add(q_sl, 1)
	q_row.add_fixed(q_vl, 40)
	mut q_note := vgui.label('Больше - лучше и крупнее файл; ${jpeg_q_default} - хороший баланс')
	u.notes << q_note

	// Размер на выход
	mut size_cb := vgui.combo_box()
	size_cb.set_items(export_size_names)
	size_cb.on_change = fn [mut st] (i int, _ string) {
		if st.suppress || i < 0 || i >= export_size_keys.len {
			return
		}
		st.settings.export_size = export_size_keys[i]
		export_setup_changed(mut st)
	}
	u.size_cb = size_cb
	mut sa := vgui.spinbox()
	sa.set_range(16, export_px_max)
	sa.on_change = fn [mut st] (v int) {
		if st.suppress {
			return
		}
		match st.settings.export_size {
			'long' { st.settings.export_long = v }
			'fit' { st.settings.export_w = v }
			'pct' { st.settings.export_pct = v }
			else { return }
		}
		save_settings(st.settings)
		sync_export_result(mut st)
	}
	u.sa = sa
	mut sb := vgui.spinbox()
	sb.set_range(16, export_px_max)
	sb.on_change = fn [mut st] (v int) {
		if st.suppress {
			return
		}
		st.settings.export_h = v
		save_settings(st.settings)
		sync_export_result(mut st)
	}
	u.sb = sb
	mut times := vgui.label('×')
	times.align = .center
	u.times = times
	mut unit := vgui.label('px')
	u.unit = unit
	mut size_row := vgui.create_hbox_fill()
	size_row.set_spacing(8)
	u.size_row = size_row // ряд собирает sync_export_setup
	mut size_note := vgui.label('Кадр только уменьшается: увеличение деталей не добавит')
	u.notes << size_note

	// Файл уже есть
	mut ex_cb := vgui.combo_box()
	ex_cb.set_items(export_exists_names)
	ex_cb.on_change = fn [mut st] (i int, _ string) {
		if st.suppress || i < 0 || i >= export_exists_keys.len {
			return
		}
		st.settings.export_exists = export_exists_keys[i]
		export_setup_changed(mut st)
	}
	u.ex_cb = ex_cb

	// AI-шумодав на полном кадре - минуты (SCUNet ~16 мин): можно
	// отключить для быстрых проб; кадр своей настройки AI не теряет
	mut ai_cb := vgui.checkbox('AI-шумодав, если включён у кадра (минуты, кадры с ним - по одному)')
	ai_cb.on_change = fn [mut st] (v bool) {
		if st.suppress {
			return
		}
		st.settings.export_no_ai = !v
		export_setup_changed(mut st)
	}
	u.ai_cb = ai_cb

	// Нагрузка: кадров одновременно и приоритет потоков экспорта
	mut load_cb := vgui.combo_box()
	load_cb.set_items(load_names)
	load_cb.on_change = fn [mut st] (i int, _ string) {
		if st.suppress || i < 0 || i >= load_keys.len {
			return
		}
		st.settings.export_load = load_keys[i]
		export_setup_changed(mut st)
	}
	u.load_cb = load_cb
	mut load_note := vgui.label('')
	u.notes << load_note
	u.load_nt = load_note

	mut result := vgui.label('')
	result.font_style = .bold
	u.result = result

	mut b_cancel := vgui.button('Отмена')
	b_cancel.style = .outline
	b_cancel.on_click = fn [mut dlg] () {
		dlg.close_with_result(0)
	}
	mut ok := vgui.button('Экспорт')
	ok.style = .accent
	ok.on_click = fn [mut st] () {
		export_confirm(mut st)
	}
	mut btn_row := vgui.create_hbox_fill()
	btn_row.set_spacing(8)
	btn_row.add(vgui.create_spacer(), 1)
	btn_row.add_fixed(b_cancel, 110)
	btn_row.add_fixed(ok, 110)

	mut body := vgui.create_vbox_fill()
	body.set_padding(16)
	body.set_spacing(6)
	body.add_fixed(row('Кадры', what_cb), set_row_h)
	body.add_fixed(vgui.create_spacer(), 4)
	body.add_fixed(dir_row, set_row_h)
	body.add_fixed(indented(dir_note.label, xs_lbl_w + 8), set_note_h)
	body.add_fixed(row('Имя файла', name), set_row_h)
	body.add_fixed(indented(name_note, xs_lbl_w + 8), set_note_h)
	body.add_fixed(row('Если файл есть', ex_cb), set_row_h)
	body.add_fixed(vgui.create_spacer(), 6)
	body.add_fixed(row('Формат', fmt_cb), set_row_h)
	body.add_fixed(q_row, set_row_h)
	body.add_fixed(indented(q_note, xs_lbl_w + 8), set_note_h)
	body.add_fixed(size_row, set_row_h)
	body.add_fixed(indented(size_note, xs_lbl_w + 8), set_note_h)
	body.add_fixed(vgui.create_spacer(), 6)
	body.add_fixed(ai_cb, set_row_h)
	body.add_fixed(vgui.create_spacer(), 4)
	body.add_fixed(row('Нагрузка', load_cb), set_row_h)
	body.add_fixed(indented(load_note, xs_lbl_w + 8), set_note_h)
	body.add(vgui.create_spacer(), 1)
	body.add_fixed(result, set_row_h)
	body.add_fixed(btn_row, 30)

	dlg.add_widget(body)
	dlg.add_widget(dir_note.tip) // после корня: рисуется поверх
	app.add_dialog(dlg)
	st.xs = u
	paint_export_setup(mut st)
}

// paint_export_setup - цвета вторичных подписей по теме
fn paint_export_setup(mut st State) {
	if isnil(st.xs) {
		return
	}
	mut u := st.xs
	for i in 0 .. u.notes.len {
		u.notes[i].color = st.pal.secondary
	}
}
