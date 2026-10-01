module main

// Копирование настроек между кадрами и пресеты.
//
// «Правка - Копировать настройки...» (Ctrl+Shift+C) открывает окно с
// флажками групп (как в Lightroom): выбранные группы настроек текущего
// кадра запоминаются в буфере vraw (st.clip, не системный буфер обмена).
// «Вставить настройки» (Ctrl+Shift+V) переносит их в открытый кадр или
// во все кадры, выделенные в ленте (Ctrl/Shift+щелчок). Каждый кадр
// получает запись в истории: открытый - через restore_edit + record,
// остальные - прямо в сайдкар (история из файла + новая запись), без
// открытия RAW.
//
// Пресет - именованный набор групп настроек в файле
// presets/<имя>.json рядом с программой (vraw переносим, как settings.json
// и models/). Меню «Пресеты»: применить (так же, как вставка), сохранить
// текущие настройки кадра пресетом (то же окно групп с полем имени).
import os
import json2
import vgui

// Группы настроек: ключи (settings.json, файлы пресетов) и названия в окне
const copy_groups = ['tone', 'color', 'curves', 'hsl', 'nr', 'sharp', 'haze', 'lens', 'crop']
const copy_group_names = ['Экспозиция и тон', 'Баланс белого и цвет',
	'Кривые', 'HSL', 'Шумодав и ореолы (и AI)', 'Резкость',
	'Удаление дымки', 'Коррекция объектива', 'Кадрирование и поворот']

// Группы по умолчанию (нет выбора в settings.json) - все, кроме
// кадрирования: как в Lightroom, рамку обычно не переносят на другие кадры
const default_copy_groups = copy_groups.filter(it != 'crop')

// merge_groups - настройки dst, в которых группы groups взяты из src.
// Производные поля (таблицы кривых, камерная кривая, матрица ББ) не
// пересчитываются: для открытого кадра это делает set_edit (with_derived),
// в сайдкар они не пишутся.
//   tone   - экспозиция, тени, контраст, тон-эквалайзер, «Тени/Света»,
//            пересветы, камерная кривая (вкл/выкл)
//   color  - баланс белого, сочность, насыщенность
//   curves - точки тональных кривых RGB, R, G, B
//   hsl    - HSL-эквалайзер
//   nr     - классический шумодав и ореолы, AI-шумодав (сила и модель)
//   sharp, haze, lens - резкость, удаление дымки, коррекция объектива
//   crop   - кадрирование и поворот (геометрия, пропорция)
fn merge_groups(dst EditState, src EditState, groups []string) EditState {
	mut e := dst.clone()
	s := src
	for g in groups {
		match g {
			'tone' {
				e.params.exposure = s.params.exposure
				e.params.shadows = s.params.shadows
				e.params.contrast = s.params.contrast
				e.params.eq = s.params.eq
				e.params.sh_shadows = s.params.sh_shadows
				e.params.sh_highlights = s.params.sh_highlights
				e.highlight = s.highlight
				e.use_curve = s.use_curve
			}
			'color' {
				e.wb_mode = s.wb_mode
				e.wb_temp = s.wb_temp
				e.wb_tint = s.wb_tint
				e.params.vibrance = s.params.vibrance
				e.params.saturation = s.params.saturation
			}
			'curves' {
				e.curve_pts = [][]vgui.CurvePoint{}
				for pts in s.curve_pts {
					e.curve_pts << pts.clone()
				}
			}
			'hsl' {
				e.params.hsl_hue = s.params.hsl_hue
				e.params.hsl_sat = s.params.hsl_sat
				e.params.hsl_lum = s.params.hsl_lum
			}
			'nr' {
				e.nr = s.nr
				e.ai = s.ai
				e.ai_model = s.ai_model
			}
			'sharp' {
				e.params.sharp = s.params.sharp
			}
			'haze' {
				e.params.haze = s.params.haze
				e.params.haze_depth = s.params.haze_depth
			}
			'lens' {
				e.lens_corr = s.lens_corr
			}
			'crop' {
				e.geom = s.geom
				e.crop_aspect = s.crop_aspect
				e.crop_aw = s.crop_aw
				e.crop_ah = s.crop_ah
				e.crop_portrait = s.crop_portrait
			}
			else {}
		}
	}
	return e
}

// known_groups - только известные группы, в порядке copy_groups
fn known_groups(groups []string) []string {
	return copy_groups.filter(it in groups)
}

// groups_text - «3 группы из 8» для тостов
fn groups_text(n int) string {
	return '${n} ${plural(n, 'группа', 'группы', 'групп')} из ${copy_groups.len}'
}

// plural - русское окончание: 1 кадр, 2 кадра, 5 кадров
fn plural(n int, one string, few string, many string) string {
	m10 := n % 10
	m100 := n % 100
	if m10 == 1 && m100 != 11 {
		return one
	}
	if m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) {
		return few
	}
	return many
}

// ── Вставка в кадры ──

// paste_targets - RAW-файлы для вставки: выделенные в ленте, если их
// больше одного; иначе открытый кадр, а без него - выделенный в ленте.
fn paste_targets(st &State) []string {
	mut sel := []int{}
	if !isnil(st.strip) {
		sel = st.strip.get_selection()
	}
	mut out := []string{}
	if sel.len > 1 || st.history.len == 0 {
		for i in sel {
			if i >= 0 && i < st.frames.len {
				out << st.frames[i].path
			}
		}
		return out
	}
	if st.side_path.len > 0 {
		out << st.side_path.all_before_last(sidecar_ext)
	}
	return out
}

// paste_to_file - группы из src в кадр raw_path через его сайдкар: к
// истории файла (нет сайдкара - новая история «Открыт файл» с
// нейтральными настройками) добавляется запись name. false - настройки
// уже такие, записывать нечего. Испорченный сайдкар не перезаписывается.
fn paste_to_file(raw_path string, src EditState, groups []string, name string) !bool {
	side := sidecar_path(raw_path)
	loaded := load_sidecar(side) or { return error('сайдкар не прочитан (${err.msg()})') }
	mut hist := loaded.history.clone()
	mut cur := loaded.current
	if hist.len == 0 {
		hist = [HistEntry{
			name:  'Открыт файл'
			state: neutral_edit()
		}]
		cur = 0
	}
	old := hist[cur].state
	e := merge_groups(old, src, groups)
	if side_state(e) == side_state(old) {
		return false
	}
	hist.trim(cur + 1)
	hist << HistEntry{
		name:  name
		state: e
	}
	write_atomic(side, encode_history(hist, hist.len - 1))!
	return true
}

// paste_settings - вставка групп из src (буфер или пресет) во все
// кадры paste_targets; name - название записи в истории.
fn paste_settings(mut st State, src EditState, groups []string, name string, mut cv vgui.Canvas, mut hist vgui.Canvas, mut nm vgui.NotificationManager, mut app vgui.App) {
	if groups.len == 0 {
		return
	}
	targets := paste_targets(st)
	if targets.len == 0 {
		nm.show_warning('Откройте кадр или выделите кадры в ленте')
		return
	}
	mut done := 0
	mut failed := []string{}
	for p in targets {
		if st.history.len > 0 && sidecar_path(p) == st.side_path {
			// Открытый кадр - как обычная правка: виджеты, пересчёт, история
			e := merge_groups(st.edit, src, groups)
			restore_edit(mut st, e, mut cv, mut hist, mut nm, mut app)
			n := st.history.len
			pos := st.hist_pos
			record(mut st, '', name, false)
			if st.history.len != n || st.hist_pos != pos {
				done++
			}
			continue
		}
		changed := paste_to_file(p, src, groups, name) or {
			failed << '${os.file_name(p)}: ${err.msg()}'
			continue
		}
		if changed {
			done++
			mark_frame_edited(mut st, p)
			if 'crop' in groups {
				refresh_frame_thumb(mut st, p)
			}
		}
	}
	if failed.len > 0 {
		nm.show_error('Не удалось вставить в ${failed.len} ${plural(failed.len, 'кадр', 'кадра', 'кадров')}: ${failed[0]}')
		return
	}
	if targets.len > 1 {
		nm.show_success('${name}: ${done} ${plural(done, 'кадр', 'кадра', 'кадров')} из ${targets.len}')
	} else if done == 0 {
		nm.show_info('${name}: настройки кадра уже такие')
	}
}

// refresh_frame_thumb - миниатюра кадра ленты по пути RAW заново (после
// вставки кадрирования в его сайдкар)
fn refresh_frame_thumb(mut st State, path string) {
	for i, f in st.frames {
		if f.path == path {
			refresh_thumb(mut st, i, thumb_geom(path))
		}
	}
}

// mark_frame_edited - отметка «изменён» у кадра ленты по пути RAW
fn mark_frame_edited(mut st State, path string) {
	for i, f in st.frames {
		if f.path == path && !f.edited {
			st.frames[i].edited = true
			draw_mark(mut st, i)
		}
	}
}

// ── Буфер настроек ──

// copy_settings - запомнить группы текущего кадра (кнопка окна групп)
fn copy_settings(mut st State, groups []string) {
	st.clip = st.edit.clone()
	st.clip_groups = groups.clone()
	st.settings.copy_groups = groups.clone()
	save_settings(st.settings)
	if !isnil(st.m_paste) {
		mut m := st.m_paste
		m.enabled = groups.len > 0
	}
	if !isnil(st.nm) {
		mut nm := st.nm
		nm.show_info('Скопировано: ${groups_text(groups.len)}')
	}
}

// ── Пресеты ──

const preset_app = 'vraw-preset'
const preset_version = 1

// PresetFile - файл пресета: группы и настройки (формат сайдкара,
// SideState; значения вне групп в файле есть, но не применяются)
struct PresetFile {
mut:
	app     string = preset_app
	version int    = preset_version
	name    string
	groups  []string
	state   SideState
}

// Preset - пресет в меню: имя (= имя файла без .json) и путь
struct Preset {
	name string
	path string
}

fn presets_dir() string {
	return os.join_path(app_dir(), 'presets')
}

// preset_file_name - имя файла пресета: символы, запрещённые в именах
// файлов (Linux и Windows), заменяются на «_»
fn preset_file_name(name string) string {
	mut out := []rune{}
	for r in name.trim_space().runes() {
		out << if r in [`/`, `\\`, `:`, `*`, `?`, `"`, `<`, `>`, `|`] || r < ` ` { `_` } else { r }
	}
	s := out.string().trim('. ')
	return if s.len == 0 { '' } else { s + '.json' }
}

// list_presets - пресеты папки dir по имени (нет папки - пусто)
fn list_presets(dir string) []Preset {
	names := os.ls(dir) or { return [] }
	mut out := []Preset{}
	for n in names {
		if n.ends_with('.json') {
			out << Preset{
				name: n.all_before_last('.json')
				path: os.join_path(dir, n)
			}
		}
	}
	out.sort(a.name.to_lower() < b.name.to_lower())
	return out
}

// save_preset - пресет из настроек e и групп в папке dir; путь файла
fn save_preset(dir string, name string, e EditState, groups []string) !string {
	file := preset_file_name(name)
	if file.len == 0 {
		return error('пустое имя')
	}
	os.mkdir_all(dir)!
	path := os.join_path(dir, file)
	f := PresetFile{
		name:   name.trim_space()
		groups: known_groups(groups)
		state:  side_state(e)
	}
	write_atomic(path, preset_json(f))!
	return path
}

// load_preset - настройки и группы пресета; чужой файл, новая версия,
// неверные массивы - ошибка
fn load_preset(path string) !(EditState, []string) {
	text := os.read_file(path)!
	f := json2.decode[PresetFile](text) or { return error('не пресет vraw') }
	if f.app != preset_app {
		return error('не пресет vraw')
	}
	if f.version > preset_version {
		return error('версия ${f.version} новее программы')
	}
	return edit_state(f.state)!, known_groups(f.groups)
}

// preset_display_name - имя пресета из файла: поле name, без него -
// имя файла без .json
fn preset_display_name(path string) string {
	text := os.read_file(path) or { return os.file_name(path).all_before_last('.json') }
	f := json2.decode[PresetFile](text) or { return os.file_name(path).all_before_last('.json') }
	n := f.name.trim_space()
	return if n.len > 0 { n } else { os.file_name(path).all_before_last('.json') }
}

// free_path - путь для файла stem.json в dir, не затирающий другой файл:
// занято - «stem (2).json», «stem (3).json»...; same - файл с таким же
// содержимым считается своим (повторный импорт/экспорт не плодит копий)
fn free_path(dir string, stem string, same string) string {
	mut path := os.join_path(dir, stem + '.json')
	mut n := 2
	for os.exists(path) {
		if old := os.read_file(path) {
			if old == same {
				return path
			}
		}
		path = os.join_path(dir, '${stem} (${n}).json')
		n++
	}
	return path
}

// import_preset - пресет из файла src в папку пресетов dir; проверяется
// как при применении (чужой файл - ошибка). Одноимённый пресет с другими
// настройками не затирается - имя получает номер. Результат - имя в меню.
fn import_preset(src string, dir string) !string {
	e, groups := load_preset(src)!
	base := preset_file_name(preset_display_name(src))
	stem := if base.len > 0 { base.all_before_last('.json') } else { 'Пресет' }
	f := PresetFile{
		name:   stem
		groups: groups
		state:  side_state(e)
	}
	os.mkdir_all(dir)!
	path := free_path(dir, stem, preset_json(f))
	name := os.file_name(path).all_before_last('.json')
	f2 := PresetFile{
		...f
		name: name
	}
	write_atomic(path, preset_json(f2))!
	return name
}

// export_preset - копия файла пресета p по пути dst (как есть)
fn export_preset(p Preset, dst string) ! {
	write_atomic(dst, os.read_file(p.path)!)!
}

// export_presets - все пресеты в папку dir; одноимённые файлы с другим
// содержимым не затираются (номер в имени). Результат - сколько записано.
fn export_presets(presets []Preset, dir string) !int {
	mut n := 0
	for p in presets {
		text := os.read_file(p.path)!
		path := free_path(dir, p.name, text)
		write_atomic(path, text)!
		n++
	}
	return n
}

fn preset_json(f PresetFile) string {
	return json2.encode(f, prettify: true, indent_string: '  ')
}

// apply_preset - пресет из меню: как вставка, запись «Пресет: имя»
fn apply_preset(mut st State, p Preset) {
	e, groups := load_preset(p.path) or {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_error('Пресет «${p.name}» не прочитан: ${err.msg()}')
		}
		return
	}
	if !isnil(st.paste_fn) {
		st.paste_fn(e, groups, 'Пресет: ${p.name}')
	}
}

// rebuild_presets_menu - меню «Пресеты»: список пресетов, «Сохранить
// пресет...», «Обновить список» (файлы можно положить и удалить руками)
fn rebuild_presets_menu(mut st State) {
	if isnil(st.bar) || st.presets_menu < 0 {
		return
	}
	mut items := []&vgui.MenuItem{}
	presets := list_presets(presets_dir())
	for p in presets {
		mut it := vgui.menu_action(p.name)
		it.on_click = fn [mut st, p] () {
			apply_preset(mut st, p)
		}
		items << it
	}
	if presets.len == 0 {
		mut none_ := vgui.menu_action('Пресетов нет')
		none_.enabled = false
		items << none_
	}
	items << vgui.menu_separator()
	mut m_save := vgui.menu_action('Сохранить пресет...')
	m_save.on_click = fn [mut st] () {
		if !isnil(st.show_groups) {
			st.show_groups(true)
		}
	}
	items << m_save
	// Импорт и экспорт - файлы .json пресетов (системные диалоги - в main)
	items << vgui.menu_separator()
	mut m_import := vgui.menu_action('Импорт пресетов...')
	m_import.on_click = fn [mut st] () {
		if !isnil(st.import_presets) {
			st.import_presets()
		}
	}
	items << m_import
	mut m_export := vgui.menu_submenu('Экспорт пресета')
	for p in presets {
		mut it := vgui.menu_action(p.name)
		it.on_click = fn [mut st, p] () {
			if !isnil(st.export_presets) {
				st.export_presets(p)
			}
		}
		m_export.add(it)
	}
	m_export.enabled = presets.len > 0
	items << m_export
	mut m_export_all := vgui.menu_action('Экспорт всех пресетов...')
	m_export_all.enabled = presets.len > 0
	m_export_all.on_click = fn [mut st] () {
		if !isnil(st.export_presets) {
			st.export_presets(Preset{})
		}
	}
	items << m_export_all
	items << vgui.menu_separator()
	mut m_reload := vgui.menu_action('Обновить список')
	m_reload.on_click = fn [mut st] () {
		rebuild_presets_menu(mut st)
	}
	items << m_reload
	mut bar := st.bar
	bar.set_items(st.presets_menu, items)
}

// ── Окно групп: копирование и сохранение пресета ──

@[heap]
struct GroupsUi {
mut:
	dlg      &vgui.Dialog    = unsafe { nil }
	title    &vgui.Label     = unsafe { nil }
	name     &vgui.TextInput = unsafe { nil }
	ok       &vgui.Button    = unsafe { nil }
	cbs      []&vgui.CheckBox
	body     &vgui.VBox = unsafe { nil }
	name_row &vgui.HBox = unsafe { nil }
	btn_row  &vgui.HBox = unsafe { nil }
	preset   bool // true - сохранение пресета (поле имени), false - копирование
}

const grp_w = 440
const grp_h = 466 // 9 групп (с кадрированием)

// show_groups - окно групп: preset = false - «Копировать настройки»,
// true - «Сохранить пресет» (с полем имени). Флажки - последний выбор.
fn show_groups(mut st State, mut app vgui.App, parent &vgui.Window, preset bool) {
	if st.history.len == 0 {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_warning('Сначала откройте RAW-файл')
		}
		return
	}
	if isnil(st.groups_ui) {
		build_groups_ui(mut st, mut app, parent) or {
			if !isnil(st.nm) {
				mut nm := st.nm
				nm.show_error('Не удалось открыть окно: ${err.msg()}')
			}
			return
		}
	}
	mut u := st.groups_ui
	u.preset = preset
	mut d := u.dlg
	d.set_title(if preset {
		'Сохранить пресет'
	} else {
		'Копировать настройки'
	})
	mut t := u.title
	t.text = if preset {
		'Группы настроек кадра, которые войдут в пресет:'
	} else {
		'Группы настроек кадра, которые будут скопированы:'
	}
	mut ok := u.ok
	ok.text = if preset { 'Сохранить' } else { 'Копировать' }
	mut name := u.name
	name.set_text('')
	layout_groups(mut u)
	for i, g in copy_groups {
		mut cb := u.cbs[i]
		cb.set_checked(g in st.settings.copy_groups)
	}
	if !d.is_open() {
		d.show_scaled(parent)
	}
	if preset {
		d.win.set_default_focus_text_input(name)
	}
}

// groups_confirm - кнопка «Копировать»/«Сохранить» окна групп
fn groups_confirm(mut st State) {
	mut u := st.groups_ui
	mut groups := []string{}
	for i, g in copy_groups {
		if u.cbs[i].is_checked() {
			groups << g
		}
	}
	mut nm := st.nm
	if groups.len == 0 {
		nm.show_warning('Не выбрано ни одной группы')
		return
	}
	if !u.preset {
		copy_settings(mut st, groups)
		mut d := u.dlg
		d.close_with_result(1)
		return
	}
	name := u.name.get_text().trim_space()
	if preset_file_name(name).len == 0 {
		nm.show_warning('Введите имя пресета')
		return
	}
	existed := os.exists(os.join_path(presets_dir(), preset_file_name(name)))
	save_preset(presets_dir(), name, st.edit, groups) or {
		nm.show_error('Пресет не сохранён: ${err.msg()}')
		return
	}
	st.settings.copy_groups = groups.clone()
	save_settings(st.settings)
	rebuild_presets_menu(mut st)
	verb := if existed { 'обновлён' } else { 'сохранён' }
	nm.show_success('Пресет «${name}» ${verb}: ${groups_text(groups.len)}')
	mut d := u.dlg
	d.close_with_result(1)
}

// layout_groups - содержимое окна под режим: поле имени только у пресета
// (VBox.remove в vgui не работает - пересборка clear + add)
fn layout_groups(mut u GroupsUi) {
	mut body := u.body
	body.clear()
	if u.preset {
		body.add_fixed(u.name_row, set_row_h)
		body.add_fixed(vgui.create_spacer(), 6)
	}
	body.add_fixed(u.title, set_note_h + 4)
	for cb in u.cbs {
		body.add_fixed(cb, 26)
	}
	body.add(vgui.create_spacer(), 1)
	body.add_fixed(u.btn_row, 30)
}

fn build_groups_ui(mut st State, mut app vgui.App, parent &vgui.Window) ! {
	mut u := &GroupsUi{}
	mut dlg := vgui.create_dialog(
		title:     'Копировать настройки'
		width:     grp_w
		height:    grp_h
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

	mut name_l := vgui.label('Имя пресета')
	mut name := vgui.text_input('Например: Пейзаж, пасмурно')
	name.on_submit = fn [mut st] (s string) {
		groups_confirm(mut st)
	}
	u.name = name
	mut name_row := vgui.create_hbox_fill()
	name_row.set_spacing(8)
	name_row.add_fixed(name_l, 110)
	name_row.add(name, 1)

	u.name_row = name_row
	mut title := vgui.label('')
	u.title = title
	for g in copy_group_names {
		u.cbs << vgui.checkbox(g)
	}

	// «Все» / «Ничего» - слева, «Отмена» и главная кнопка - справа
	mut b_all := vgui.button('Все')
	b_all.style = .outline
	b_all.on_click = fn [mut u] () {
		for mut cb in u.cbs {
			cb.set_checked(true)
		}
	}
	mut b_none := vgui.button('Ничего')
	b_none.style = .outline
	b_none.on_click = fn [mut u] () {
		for mut cb in u.cbs {
			cb.set_checked(false)
		}
	}
	mut b_cancel := vgui.button('Отмена')
	b_cancel.style = .outline
	b_cancel.on_click = fn [mut dlg] () {
		dlg.close_with_result(0)
	}
	mut ok := vgui.button('Копировать')
	ok.style = .accent
	ok.on_click = fn [mut st] () {
		groups_confirm(mut st)
	}
	u.ok = ok
	mut btn_row := vgui.create_hbox_fill()
	btn_row.set_spacing(8)
	btn_row.add_fixed(b_all, 70)
	btn_row.add_fixed(b_none, 80)
	btn_row.add(vgui.create_spacer(), 1)
	btn_row.add_fixed(b_cancel, 90)
	btn_row.add_fixed(ok, 110)
	u.btn_row = btn_row
	mut body := vgui.create_vbox_fill()
	body.set_padding(16)
	body.set_spacing(4)
	u.body = body
	layout_groups(mut u)

	dlg.add_widget(body)
	app.add_dialog(dlg)
	st.groups_ui = u
}
