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
import i18n

const name_tmpl_default = '{name}'
// Размер на выход: ключи (Settings.export_size) и названия
const export_size_keys = ['', 'long', 'fit', 'pct']
const export_size_names = ['Как есть', 'По длинной стороне', 'Вписать в Ш × В', 'В процентах']
const export_px_max = 30000
// Резкость на выход: ключи (Settings.export_sharp), названия и сила
// (pipeline.out_sharpen). Уменьшение усредняет пиксели и смягчает края -
// резкость под размер файла возвращает чёткость (как Output Sharpening
// в Lightroom); без уменьшения не применяется - резкость кадра уже есть.
const export_sharp_keys = ['', 'low', 'std', 'high']
const export_sharp_names = ['Нет', 'Слабая', 'Средняя', 'Сильная']
const export_sharp_amounts = [f32(0), 0.4, 0.8, 1.3]

// clamp_px - размер в пикселях из настроек: вне 1..export_px_max - def
fn clamp_px(v int, def int) int {
	return if v >= 1 && v <= export_px_max { v } else { def }
}

// ExportSize - размер на выход и резкость под него (снимок настроек для
// воркера)
struct ExportSize {
	mode  string // ключ export_size_keys
	long  int
	w     int
	h     int
	pct   int
	sharp f32 // сила резкости на выход (0 - нет), только при уменьшении
}

fn (s &Settings) export_size_opts() ExportSize {
	return ExportSize{
		mode: s.export_size
		long: s.export_long
		w:    s.export_w
		h:    s.export_h
		pct:   s.export_pct
		sharp: export_sharp_amounts[math.max(0, export_sharp_keys.index(s.export_sharp))]
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
	sharp_cb &vgui.ComboBox = unsafe { nil }
	size_mode string = '?' // режим, под который собран size_row
	ex_cb   &vgui.ComboBox  = unsafe { nil }
	load_cb &vgui.ComboBox  = unsafe { nil }
	load_nt &vgui.Label     = unsafe { nil }
	ai_cb   &vgui.CheckBox  = unsafe { nil }
	exif_cb &vgui.CheckBox  = unsafe { nil }
	copy_in &vgui.TextInput = unsafe { nil }
	result  &vgui.Label     = unsafe { nil }
	// Колонка подписей: по самой длинной (меряется шрифтом окна)
	lbl_col f32
	notes   []&vgui.Label
}

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
				nm.show_error(i18n.trf('Не удалось открыть окно экспорта: {0}', '${err.msg()}'))
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
		names << i18n.trf('Открытый кадр ({0})', '${os.file_name(st.dev.path)}')
	}
	if sel.len > 1 {
		keys << 'sel'
		names << i18n.trf('Выделенные в ленте ({0})', '${sel.len}')
	}
	// Фильтр ленты (rating.v) оставил не все кадры - «по фильтру»
	if st.filter != 'all' && st.shown.len > 0 && st.shown.len < st.frames.len {
		keys << 'shown'
		names << i18n.trf('По фильтру ленты: {0} ({1})', i18n.tr(filter_names[filter_keys.index(st.filter)]).to_lower(), '${st.shown.len}')
	}
	if st.frames.len > 1 || (st.frames.len == 1 && keys.len == 0) {
		keys << 'all'
		names << i18n.trf('Все кадры папки ({0})', '${st.frames.len}')
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

// strip_selection - выделенные в ленте кадры (номера в st.frames: строки
// ленты с фильтром - не номера кадров, rating.v)
fn strip_selection(st &State) []int {
	if isnil(st.strip) {
		return []int{}
	}
	return st.strip.get_selection().map(frame_of_row(st, it)).filter(it >= 0)
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
		'shown' {
			st.shown.map(st.frames[it].path)
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
	size := match s.export_size {
		'long' { i18n.trf('длинная сторона до {0} px', '${s.export_long}') }
		'fit' { i18n.trf('в пределах {0} × {1} px', '${s.export_w}', '${s.export_h}') }
		'pct' { i18n.trf('{0}% размера', '${s.export_pct}') }
		else { i18n.tr('полный размер') }
	}
	i := export_sharp_keys.index(s.export_sharp)
	return if s.export_size != '' && i > 0 {
		i18n.trf('{0}, резкость: {1}', '${size}', i18n.tr(export_sharp_names[i]).to_lower())
	} else {
		size
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
	u.dir.set(i18n.tr('Папка: '), if raw_path == '' && s.export_dir_mode != 'dir' {
		i18n.tr('рядом с RAW-файлом')
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
		r.add(vgui.label(i18n.tr('Размер')), min: u.lbl_col)
		r.add(u.size_cb)
		if s.export_size != '' {
			r.add(sa)
			if s.export_size == 'fit' {
				r.add(times)
				r.add(sb)
			}
			r.add(unit)
		}
		r.add(vgui.create_spacer(), flex: 1)
	}
	// Резкость на выход - только при уменьшении: «Как есть» - недоступна
	mut shcb := u.sharp_cb
	shcb.set_selected(math.max(0, export_sharp_keys.index(s.export_sharp)))
	shcb.enabled = s.export_size != ''
	mut ecb := u.ex_cb
	ecb.set_selected(math.max(0, export_exists_keys.index(s.export_exists)))
	mut acb := u.ai_cb
	acb.checked = !s.export_no_ai
	// EXIF: копирайт - только при включённом EXIF; поле в фокусе не
	// перезаписывается (набор не сбивается)
	mut xcb := u.exif_cb
	xcb.checked = !s.export_no_exif
	mut cin := u.copy_in
	cin.enabled = !s.export_no_exif
	if !cin.focused && cin.get_text() != s.exif_copyright {
		cin.set_text(s.exif_copyright)
	}
	mut lcb := u.load_cb
	li := math.max(0, load_keys.index(s.export_load))
	lcb.set_selected(li)
	mut lnt := u.load_nt
	lnt.text = i18n.tr(load_notes[li])
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
			r.text = i18n.tr('Нет кадров')
			return
		}
		first := os.file_name(export_path_taken(&s, paths[0], f, map[string]bool{},
			NameInfo{ count: paths.len }))
		r.text = '${paths.len} ${i18n.pl(paths.len, 'кадр|кадра|кадров')}: ${first}...  ·  ${size_desc(&s)}'
		return
	}
	if isnil(st.dev) {
		r.text = i18n.tr('Кадр не открыт')
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
			nm.show_warning(i18n.tr('Нет кадров для экспорта'))
			return
		}
		if st.settings.export_dir_mode == 'dir' && !os.is_dir(st.settings.export_dir) {
			nm.show_error(i18n.trf('Папки нет: {0}', '${st.settings.export_dir}'))
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
		nm.show_warning(i18n.tr('Сначала откройте RAW-файл'))
		return
	}
	dir := export_dir_for(&st.settings, st.dev.path)
	if !os.is_dir(dir) {
		nm.show_error(i18n.trf('Папки нет: {0}', '${dir}'))
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
		title:     i18n.tr('Экспорт')
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
	// Колонка подписей - по самой длинной подписи шрифтом окна, поля и
	// подсказки под ними встают ровно (+8 - поля Label, pad 4 с двух сторон)
	lbl_col := column_width(mut dlg.win, [i18n.tr('Кадры'), i18n.tr('Папка'), i18n.tr('Имя файла'), i18n.tr('Если файл есть'),
		i18n.tr('Формат'), i18n.tr('Качество JPEG'), i18n.tr('Размер'), i18n.tr('Резкость на выход'), i18n.tr('Метаданные'), i18n.tr('Нагрузка')], 8)
	u.lbl_col = lbl_col
	row := fn [lbl_col] (text string, w &vgui.Widget) &vgui.HBox {
		mut r := vgui.create_hbox_fill()
		r.set_spacing(8)
		r.add(vgui.label(text), min: lbl_col)
		r.add(w, flex: 1)
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
	dir_cb.set_items(i18n.tr_all(export_dir_names))
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
	mut dir_btn := vgui.button(i18n.tr('Выбрать...'))
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
	dir_row.add(vgui.label(i18n.tr('Папка')), min: lbl_col)
	dir_row.add(dir_cb, flex: 1)
	dir_row.add(dir_btn)
	dir_note := path_note(i18n.tr('Папка: '), '', xs_path_max)
	u.dir = dir_note
	u.notes << dir_note.label

	// Имя файла
	mut name := vgui.text_input(i18n.tr('шаблон имени'))
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
	mut name_note := vgui.label(i18n.tr('{name} - имя RAW, {num} - номер (001), {date} - дата съёмки'))
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
	q_row.add(vgui.label(i18n.tr('Качество JPEG')), min: lbl_col)
	q_row.add(q_sl, flex: 1)
	// Ширина значения - под «100»: ползунок не дёргается от числа цифр
	q_row.add(q_vl, min: column_width(mut dlg.win, ['100'], 8))
	mut q_note := vgui.label(i18n.trf('Больше - лучше и крупнее файл; {0} - хороший баланс', '${jpeg_q_default}'))
	u.notes << q_note

	// Размер на выход
	mut size_cb := vgui.combo_box()
	size_cb.set_items(i18n.tr_all(export_size_names))
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
	mut size_note := vgui.label(i18n.tr('Кадр только уменьшается: увеличение деталей не добавит'))
	u.notes << size_note

	// Резкость на выход - под размер файла
	mut sharp_cb := vgui.combo_box()
	sharp_cb.set_items(i18n.tr_all(export_sharp_names))
	sharp_cb.on_change = fn [mut st] (i int, _ string) {
		if st.suppress || i < 0 || i >= export_sharp_keys.len {
			return
		}
		st.settings.export_sharp = export_sharp_keys[i]
		export_setup_changed(mut st)
	}
	u.sharp_cb = sharp_cb
	mut sharp_note := vgui.label(i18n.tr('Только при уменьшении кадра: возвращает ему чёткость'))
	u.notes << sharp_note

	// Файл уже есть
	mut ex_cb := vgui.combo_box()
	ex_cb.set_items(i18n.tr_all(export_exists_names))
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
	mut ai_cb := vgui.checkbox(i18n.tr('AI-шумодав, если включён у кадра (минуты, кадры с ним - по одному)'))
	ai_cb.on_change = fn [mut st] (v bool) {
		if st.suppress {
			return
		}
		st.settings.export_no_ai = !v
		export_setup_changed(mut st)
	}
	u.ai_cb = ai_cb

	// EXIF: дата съёмки, камера, объектив, параметры съёмки и копирайт
	mut exif_cb := vgui.checkbox(i18n.tr('Сохранять EXIF'))
	exif_cb.on_change = fn [mut st] (v bool) {
		if st.suppress {
			return
		}
		st.settings.export_no_exif = !v
		export_setup_changed(mut st)
	}
	u.exif_cb = exif_cb
	mut copy_in := vgui.text_input(i18n.tr('копирайт, например «© Игорь 2026»'))
	copy_in.max_len = 200
	copy_in.on_change = fn [mut st] (t string) {
		if st.suppress {
			return
		}
		st.settings.exif_copyright = t.trim_space()
		save_settings(st.settings)
	}
	u.copy_in = copy_in
	mut exif_row := vgui.create_hbox_fill()
	exif_row.set_spacing(8)
	exif_row.add(vgui.label(i18n.tr('Метаданные')), min: lbl_col)
	exif_row.add(exif_cb)
	exif_row.add(copy_in, flex: 1)
	mut exif_note := vgui.label(i18n.tr('Дата съёмки, камера, объектив, выдержка - в JPEG, PNG и TIFF'))
	u.notes << exif_note

	// Нагрузка: кадров одновременно и приоритет потоков экспорта
	mut load_cb := vgui.combo_box()
	load_cb.set_items(i18n.tr_all(load_names))
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

	mut b_cancel := vgui.button(i18n.tr('Отмена'))
	b_cancel.style = .outline
	b_cancel.on_click = fn [mut dlg] () {
		dlg.close_with_result(0)
	}
	mut ok := vgui.button(i18n.tr('Экспорт'))
	ok.style = .accent
	ok.on_click = fn [mut st] () {
		export_confirm(mut st)
	}
	mut btn_row := vgui.create_hbox_fill()
	btn_row.set_spacing(8)
	btn_row.add(vgui.create_spacer(), flex: 1)
	btn_row.add(b_cancel, min: 100)
	btn_row.add(ok, min: 100)

	mut body := vgui.create_vbox_fill()
	body.set_padding(16)
	body.set_spacing(6)
	body.add(row(i18n.tr('Кадры'), what_cb))
	body.add(dir_row)
	body.add(indented(dir_note.label, lbl_col + 8))
	body.add(row(i18n.tr('Имя файла'), name))
	body.add(indented(name_note, lbl_col + 8))
	body.add(row(i18n.tr('Если файл есть'), ex_cb))
	body.add(row(i18n.tr('Формат'), fmt_cb))
	body.add(q_row)
	body.add(indented(q_note, lbl_col + 8))
	body.add(size_row)
	body.add(indented(size_note, lbl_col + 8))
	body.add(row(i18n.tr('Резкость на выход'), sharp_cb))
	body.add(indented(sharp_note, lbl_col + 8))
	body.add(exif_row)
	body.add(indented(exif_note, lbl_col + 8))
	body.add(ai_cb)
	body.add(row(i18n.tr('Нагрузка'), load_cb))
	body.add(indented(load_note, lbl_col + 8))
	body.add(vgui.create_spacer(), flex: 1)
	body.add(result)
	body.add(btn_row)

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
