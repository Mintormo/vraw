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
import i18n

// Группы настроек: ключи (settings.json, файлы пресетов) и названия в окне
const copy_groups = ['tone', 'color', 'curves', 'hsl', 'bw', 'grade', 'nr', 'sharp', 'haze', 'fx', 'lens',
	'crop', 'masks', 'spots']
const copy_group_names = ['Экспозиция и тон', 'Баланс белого и цвет',
	'Кривые', 'HSL', 'Чёрно-белое', 'Цветокоррекция', 'Шумодав и ореолы', 'Резкость',
	'Удаление дымки', 'Эффекты (виньетка, зерно)', 'Коррекция объектива', 'Кадрирование и поворот',
	'Градиентные фильтры', 'Удаление пятен']

// Группы по умолчанию (нет выбора в settings.json) - все, кроме
// кадрирования, фильтров и пятен: как в Lightroom, рамку и места фильтров
// обычно не переносят на другие кадры (пыль матрицы серии - переносят,
// флажком)
const default_copy_groups = copy_groups.filter(it !in ['crop', 'masks', 'spots'])

// merge_groups - настройки dst, в которых группы groups взяты из src.
// Производные поля (таблицы кривых, камерная кривая, матрица ББ) не
// пересчитываются: для открытого кадра это делает set_edit (with_derived),
// в сайдкар они не пишутся.
//   tone   - экспозиция, тени, контраст, текстура, Clarity, тон-эквалайзер,
//            «Тени/Света», профиль (камерная кривая и стиль)
//   color  - баланс белого, сочность, насыщенность
//   curves - точки тональных кривых RGB, R, G, B
//   hsl    - HSL-эквалайзер
//   bw     - чёрно-белое и микшер
//   grade  - цветокоррекция (тонирование теней, средних, светов)
//   nr     - шумодав и ореолы
//   sharp, haze, lens - резкость, удаление дымки, коррекция объектива
//   fx     - эффекты: виньетка и зерно
//   crop   - кадрирование и поворот (геометрия, пропорция)
//   masks  - градиентные фильтры (заменяют фильтры кадра целиком)
//   spots  - удаление пятен (заменяют пятна кадра целиком)
fn merge_groups(dst EditState, src EditState, groups []string) EditState {
	mut e := dst.clone()
	s := src
	for g in groups {
		match g {
			'tone' {
				e.params.exposure = s.params.exposure
				e.params.shadows = s.params.shadows
				e.params.contrast = s.params.contrast
				e.params.clarity = s.params.clarity
				e.params.texture = s.params.texture
				e.params.eq = s.params.eq
				e.params.sh_shadows = s.params.sh_shadows
				e.params.sh_highlights = s.params.sh_highlights
				e.use_curve = s.use_curve
				e.profile = s.profile
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
			'bw' {
				e.params.bw = s.params.bw
				e.params.bw_mix = s.params.bw_mix
			}
			'grade' {
				e.params.grade = s.params.grade
			}
			'nr' {
				e.nr = s.nr
			}
			'sharp' {
				e.params.sharp = s.params.sharp
			}
			'haze' {
				e.params.haze = s.params.haze
				e.params.haze_depth = s.params.haze_depth
			}
			'fx' {
				e.params.fx = s.params.fx
			}
			'lens' {
				e.lens_corr = s.lens_corr
				e.lman = s.lman
			}
			'crop' {
				e.geom = s.geom
				e.crop_aspect = s.crop_aspect
				e.crop_aw = s.crop_aw
				e.crop_ah = s.crop_ah
				e.crop_portrait = s.crop_portrait
			}
			'masks' {
				e.params.masks = s.params.masks.map(it.copy())
			}
			'spots' {
				e.spots = s.spots.clone()
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
	return i18n.trf('{0} {1} из {2}', '${n}', i18n.pl(n, 'группа|группы|групп'), '${copy_groups.len}')
}

// ── Вставка в кадры ──

// paste_targets - RAW-файлы для вставки: выделенные в ленте, если их
// больше одного; иначе открытый кадр, а без него - выделенный в ленте.
fn paste_targets(st &State) []string {
	sel := strip_selection(st) // номера кадров (с фильтром строки - не они)
	mut out := []string{}
	if sel.len > 1 || st.history.len == 0 {
		for i in sel {
			out << st.frames[i].path
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
	loaded := load_sidecar(side) or { return error(i18n.trf('сайдкар не прочитан ({0})', '${err.msg()}')) }
	mut hist := loaded.history.clone()
	mut cur := loaded.current
	if hist.len == 0 {
		hist = [HistEntry{
			name:  i18n.tr('Открыт файл')
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
	write_atomic(side, encode_history(hist, hist.len - 1, loaded.mark))!
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
		nm.show_warning(i18n.tr('Откройте кадр или выделите кадры в ленте'))
		return
	}
	mut done := 0
	mut failed := []string{}
	for p in targets {
		if st.history.len > 0 && sidecar_path(p) == st.side_path {
			// Открытый кадр - как обычная правка: виджеты, пересчёт, история
			e := merge_groups(st.edit, src, groups)
			restore_edit(mut st, e, mut cv, mut hist, mut app)
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
		nm.show_error(i18n.trf('Не удалось вставить в {0} {1}: {2}', '${failed.len}', i18n.pl(failed.len, 'кадр|кадра|кадров'), failed[0]))
		return
	}
	if targets.len > 1 {
		nm.show_success(i18n.trf('{0}: {1} {2} из {3}', name, '${done}', i18n.pl(done, 'кадр|кадра|кадров'), '${targets.len}'))
	} else if done == 0 {
		nm.show_info(i18n.trf('{0}: настройки кадра уже такие', '${name}'))
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
	pair_edited(mut st, path) // левый кадр сравнения - заново (pair.v)
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
	sync_avail(mut st)
	if !isnil(st.nm) {
		mut nm := st.nm
		nm.show_info(i18n.trf('Скопировано: {0}', '${groups_text(groups.len)}'))
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
		return error(i18n.tr('пустое имя'))
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
	f := json2.decode[PresetFile](text) or { return error(i18n.tr('не пресет vraw')) }
	if f.app != preset_app {
		return error(i18n.tr('не пресет vraw'))
	}
	if f.version > preset_version {
		return error(i18n.trf('версия {0} новее программы', '${f.version}'))
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
	stem := if base.len > 0 { base.all_before_last('.json') } else { i18n.tr('Пресет') }
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

// delete_preset - удалить файл пресета p (подтверждение - в main)
fn delete_preset(p Preset) ! {
	os.rm(p.path)!
}

// rename_preset - пресет p под новым именем name в той же папке: файл
// переименовывается, поле name в нём обновляется (настройки как есть).
// Имя занято другим пресетом - ошибка. Результат - новый путь.
fn rename_preset(p Preset, name string) !string {
	file := preset_file_name(name)
	if file.len == 0 {
		return error(i18n.tr('пустое имя'))
	}
	load_preset(p.path)! // чужой файл или новая версия - не трогаем
	mut f := json2.decode[PresetFile](os.read_file(p.path)!)!
	f.name = name.trim_space()
	path := os.join_path(os.dir(p.path), file)
	// То же имя без учёта регистра - тот же файл (Windows, macOS)
	same := path.to_lower() == p.path.to_lower()
	if !same && os.exists(path) {
		return error(i18n.trf('пресет «{0}» уже есть', '${file.all_before_last('.json')}'))
	}
	if path != p.path {
		os.mv(p.path, path)!
	}
	write_atomic(path, preset_json(f))!
	return path
}

fn preset_json(f PresetFile) string {
	return json2.encode(f, prettify: true, indent_string: '  ')
}

// apply_preset - пресет из меню: как вставка, запись «Пресет: имя»
fn apply_preset(mut st State, p Preset) {
	e, groups := load_preset(p.path) or {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_error(i18n.trf('Пресет «{0}» не прочитан: {1}', '${p.name}', '${err.msg()}'))
		}
		return
	}
	if !isnil(st.paste_fn) {
		st.paste_fn(e, groups, i18n.trf('Пресет: {0}', '${p.name}'))
	}
}

// rebuild_presets_menu - меню «Пресеты»: список пресетов, «Сохранить
// пресет...», «Управление пресетами...»; открытое окно управления
// получает тот же список
fn rebuild_presets_menu(mut st State) {
	if isnil(st.bar) || st.presets_menu < 0 {
		return
	}
	mut items := []&vgui.MenuItem{}
	presets := list_presets(presets_dir())
	st.m_presets.clear()
	for p in presets {
		mut it := vgui.menu_action(p.name)
		it.on_click = fn [mut st, p] () {
			apply_preset(mut st, p)
		}
		items << it
		st.m_presets << it
	}
	if presets.len == 0 {
		mut none_ := vgui.menu_action(i18n.tr('Пресетов нет'))
		none_.enabled = false
		items << none_
	}
	items << vgui.menu_separator()
	mut m_save := vgui.menu_action(i18n.tr('Сохранить пресет...'))
	m_save.on_click = fn [mut st] () {
		if !isnil(st.show_groups) {
			st.show_groups(true)
		}
	}
	items << m_save
	st.m_preset_save = m_save
	mut m_manage := vgui.menu_action(i18n.tr('Управление пресетами...'))
	m_manage.on_click = fn [mut st] () {
		if !isnil(st.show_presets) {
			st.show_presets()
		}
	}
	items << m_manage
	mut bar := st.bar
	bar.set_items(st.presets_menu, items)
	sync_avail(mut st)
	if !isnil(st.presets_ui) {
		fill_presets_ui(mut st, presets)
	}
}

// ── Окно групп: копирование и сохранение пресета ──

@[heap]
struct GroupsUi {
mut:
	dlg      &vgui.Dialog    = unsafe { nil }
	scroll   &vgui.ScrollBox = unsafe { nil } // корень: содержимое в прокрутке (dlgfit.v)
	title    &vgui.Label     = unsafe { nil }
	name     &vgui.TextInput = unsafe { nil }
	ok       &vgui.Button    = unsafe { nil }
	cbs      []&vgui.CheckBox
	body     &vgui.VBox = unsafe { nil }
	name_row &vgui.HBox = unsafe { nil }
	btn_row  &vgui.HBox = unsafe { nil }
	preset   bool // true - сохранение пресета (поле имени), false - копирование
}


// show_groups - окно групп: preset = false - «Копировать настройки»,
// true - «Сохранить пресет» (с полем имени). Флажки - последний выбор.
fn show_groups(mut st State, mut app vgui.App, parent &vgui.Window, preset bool) {
	if st.history.len == 0 {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_warning(i18n.tr('Сначала откройте RAW-файл'))
		}
		return
	}
	if isnil(st.groups_ui) {
		build_groups_ui(mut st, mut app, parent) or {
			if !isnil(st.nm) {
				mut nm := st.nm
				nm.show_error(i18n.trf('Не удалось открыть окно: {0}', '${err.msg()}'))
			}
			return
		}
	}
	mut u := st.groups_ui
	u.preset = preset
	mut d := u.dlg
	d.set_title(if preset {
		i18n.tr('Сохранить пресет')
	} else {
		i18n.tr('Копировать настройки')
	})
	mut t := u.title
	t.text = if preset {
		i18n.tr('Группы настроек кадра, которые войдут в пресет:')
	} else {
		i18n.tr('Группы настроек кадра, которые будут скопированы:')
	}
	mut ok := u.ok
	ok.text = if preset { i18n.tr('Сохранить') } else { i18n.tr('Копировать') }
	mut name := u.name
	name.set_text('')
	layout_groups(mut u)
	for i, g in copy_groups {
		mut cb := u.cbs[i]
		cb.set_checked(g in st.settings.copy_groups)
	}
	if !d.is_open() {
		d.show()
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
		nm.show_warning(i18n.tr('Не выбрано ни одной группы'))
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
		nm.show_warning(i18n.tr('Введите имя пресета'))
		return
	}
	existed := os.exists(os.join_path(presets_dir(), preset_file_name(name)))
	save_preset(presets_dir(), name, st.edit, groups) or {
		nm.show_error(i18n.trf('Пресет не сохранён: {0}', '${err.msg()}'))
		return
	}
	st.settings.copy_groups = groups.clone()
	save_settings(st.settings)
	rebuild_presets_menu(mut st)
	verb := if existed { i18n.tr('обновлён') } else { i18n.tr('сохранён') }
	nm.show_success(i18n.trf('Пресет «{0}» {1}: {2}', '${name}', '${verb}', '${groups_text(groups.len)}'))
	mut d := u.dlg
	d.close_with_result(1)
}

// layout_groups - содержимое окна под режим: поле имени только у пресета
// (VBox.remove в vgui не работает - пересборка clear + add)
fn layout_groups(mut u GroupsUi) {
	mut body := u.body
	body.clear()
	if u.preset {
		body.add(u.name_row)
	}
	body.add(u.title)
	for cb in u.cbs {
		body.add(cb)
	}
	body.add(vgui.create_spacer(), flex: 1)
	body.add(u.btn_row)
}

fn build_groups_ui(mut st State, mut app vgui.App, parent &vgui.Window) ! {
	mut u := &GroupsUi{}
	mut dlg := vgui.create_dialog(
		title:     i18n.tr('Копировать настройки')
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

	mut name_l := vgui.label(i18n.tr('Имя пресета'))
	mut name := vgui.text_input(i18n.tr('Например: Пейзаж, пасмурно'))
	name.on_submit = fn [mut st] (s string) {
		groups_confirm(mut st)
	}
	u.name = name
	mut name_row := vgui.create_hbox_fill()
	name_row.set_spacing(8)
	name_row.add(name_l)
	name_row.add(name, flex: 1)

	u.name_row = name_row
	mut title := vgui.label('')
	u.title = title
	for g in copy_group_names {
		u.cbs << vgui.checkbox(i18n.tr(g))
	}

	// «Все» / «Ничего» - слева, «Отмена» и главная кнопка - справа
	mut b_all := vgui.button(i18n.tr('Все'))
	b_all.style = .outline
	b_all.on_click = fn [mut u] () {
		for mut cb in u.cbs {
			cb.set_checked(true)
		}
	}
	mut b_none := vgui.button(i18n.tr('Ничего'))
	b_none.style = .outline
	b_none.on_click = fn [mut u] () {
		for mut cb in u.cbs {
			cb.set_checked(false)
		}
	}
	mut b_cancel := vgui.button(i18n.tr('Отмена'))
	b_cancel.style = .outline
	b_cancel.on_click = fn [mut dlg] () {
		dlg.close_with_result(0)
	}
	mut ok := vgui.button(i18n.tr('Копировать'))
	ok.style = .accent
	ok.on_click = fn [mut st] () {
		groups_confirm(mut st)
	}
	u.ok = ok
	mut btn_row := vgui.create_hbox_fill()
	btn_row.set_spacing(8)
	btn_row.add(b_all)
	btn_row.add(b_none)
	btn_row.add(vgui.create_spacer(), flex: 1)
	btn_row.add(b_cancel, min: 100)
	btn_row.add(ok, min: 100)
	u.btn_row = btn_row
	mut body := vgui.create_vbox_fill()
	body.set_padding(16)
	body.set_spacing(4)
	u.body = body
	layout_groups(mut u)

	u.scroll = dialog_scroll(body)
	dlg.add_widget(u.scroll)
	app.add_dialog(dlg)
	st.groups_ui = u
}

// ── Окно «Управление пресетами» ──

@[heap]
struct PresetsUi {
mut:
	dlg      &vgui.Dialog    = unsafe { nil }
	scroll   &vgui.ScrollBox = unsafe { nil } // корень: содержимое в прокрутке (dlgfit.v)
	app      &vgui.App       = unsafe { nil }
	list     &vgui.ListBox   = unsafe { nil }
	name     &vgui.TextInput = unsafe { nil }
	b_rename &vgui.Button    = unsafe { nil }
	b_delete &vgui.Button    = unsafe { nil }
	b_export &vgui.Button    = unsafe { nil }
	b_all    &vgui.Button    = unsafe { nil }
	presets  []Preset // строки списка
}

// show_presets - окно управления: папка пресетов перечитывается при
// каждом открытии (файлы можно положить и удалить руками), меню - тоже
fn show_presets(mut st State, mut app vgui.App, parent &vgui.Window) {
	if isnil(st.presets_ui) {
		build_presets_ui(mut st, mut app, parent) or {
			if !isnil(st.nm) {
				mut nm := st.nm
				nm.show_error(i18n.trf('Не удалось открыть окно: {0}', '${err.msg()}'))
			}
			return
		}
	}
	rebuild_presets_menu(mut st)
	mut u := st.presets_ui
	mut d := u.dlg
	if !d.is_open() {
		// размер - заданный при создании (presets_w × presets_h), не больше экрана
		d.show()
	}
}

// fill_presets_ui - список окна; выбор остаётся на пресете с тем же
// именем, иначе - на той же строке (после удаления - соседний)
fn fill_presets_ui(mut st State, presets []Preset) {
	mut u := st.presets_ui
	mut list := u.list
	old := list.selected
	old_name := if old >= 0 && old < u.presets.len { u.presets[old].name } else { '' }
	u.presets = presets.clone()
	list.set_items(presets.map(it.name))
	mut sel := -1
	for i, p in presets {
		if p.name == old_name {
			sel = i
		}
	}
	if sel < 0 && old >= 0 && presets.len > 0 {
		sel = if old < presets.len { old } else { presets.len - 1 }
	}
	select_preset_row(mut u, sel)
}

// select_preset_row - строка i выбрана: имя в поле, кнопки по выбору
fn select_preset_row(mut u PresetsUi, i int) {
	mut list := u.list
	list.set_selected(i)
	has := i >= 0 && i < u.presets.len
	mut name := u.name
	name.set_text(if has { u.presets[i].name } else { '' })
	name.enabled = has
	mut buttons := [u.b_rename, u.b_delete, u.b_export]
	for mut b in buttons {
		b.enabled = has
	}
	mut all := u.b_all
	all.enabled = u.presets.len > 0
}

fn selected_preset(u &PresetsUi) ?Preset {
	i := u.list.selected
	if i < 0 || i >= u.presets.len {
		return none
	}
	return u.presets[i]
}

// presets_rename - «Переименовать» и Enter в поле имени: занятое или
// пустое имя - предупреждение, пресет не трогается
fn presets_rename(mut st State) {
	mut u := st.presets_ui
	old := selected_preset(u) or { return }
	mut nm := st.nm
	name := u.name.get_text().trim_space()
	if preset_file_name(name).len == 0 {
		nm.show_warning(i18n.tr('Введите имя пресета'))
		return
	}
	if name == old.name {
		return
	}
	path := rename_preset(old, name) or {
		nm.show_warning(i18n.trf('Пресет не переименован: {0}', '${err.msg()}'))
		return
	}
	new_name := os.file_name(path).all_before_last('.json')
	// Выбор переходит на новое имя (fill_presets_ui ищет старое)
	mut list := u.list
	list.set_selected(-1)
	rebuild_presets_menu(mut st)
	for i, p in u.presets {
		if p.name == new_name {
			select_preset_row(mut u, i)
		}
	}
	nm.show_success(i18n.trf('Пресет «{0}» переименован в «{1}»', '${old.name}', '${new_name}'))
}

// presets_delete - «Удалить» с подтверждением
fn presets_delete(mut st State) {
	mut u := st.presets_ui
	p := selected_preset(u) or { return }
	mut app := u.app
	answer := vgui.message_box(u.dlg.win, mut app, vgui.MessageBoxConfig{
		title:          i18n.tr('Удалить пресет')
		message:        i18n.trf('Удалить пресет «{0}»? Файл пресета будет удалён.', '${p.name}')
		kind:           .warning
		buttons:        [i18n.tr('Удалить'), i18n.tr('Отмена')]
		default_button: 1
		cancel_button:  1
	})
	if answer != 0 {
		return
	}
	mut nm := st.nm
	delete_preset(p) or {
		nm.show_error(i18n.trf('Пресет «{0}» не удалён: {1}', '${p.name}', '${err.msg()}'))
		return
	}
	rebuild_presets_menu(mut st)
	nm.show_success(i18n.trf('Пресет «{0}» удалён', '${p.name}'))
}

// Окно «Управление пресетами» - своего размера (список растягивается)
const presets_w = 560
const presets_h = 400

fn build_presets_ui(mut st State, mut app vgui.App, parent &vgui.Window) ! {
	mut u := &PresetsUi{
		app: unsafe { &app }
	}
	mut dlg := vgui.create_dialog(
		title:     i18n.tr('Управление пресетами')
		parent:    unsafe { parent }
		theme:     parent.ctx.theme
		font_path: parent.config.font_path
		mono_path: parent.config.mono_path
		font_data: parent.config.font_data
		mono_data: parent.config.mono_data
		font_size: parent.config.font_size
		mono_size: parent.config.mono_size
		ui_scale:  parent.ctx.ui_scale
		width:     presets_w
		height:    presets_h
	)!
	u.dlg = dlg

	mut list := vgui.list_box()
	list.on_select = fn [mut u] (i int, s string) {
		select_preset_row(mut u, i)
	}
	// Двойной щелчок - к полю имени (переименование)
	list.on_dbl_click = fn [mut u] (i int, s string) {
		mut d := u.dlg
		d.win.set_default_focus_text_input(u.name)
	}
	u.list = list

	mut b_delete := vgui.button(i18n.tr('Удалить'))
	b_delete.style = .outline
	b_delete.on_click = fn [mut st] () {
		presets_delete(mut st)
	}
	u.b_delete = b_delete
	mut b_export := vgui.button(i18n.tr('Экспорт...'))
	b_export.style = .outline
	b_export.on_click = fn [mut st, mut u] () {
		p := selected_preset(u) or { return }
		if !isnil(st.export_presets) {
			st.export_presets(p)
		}
	}
	u.b_export = b_export
	mut b_import := vgui.button(i18n.tr('Импорт...'))
	b_import.style = .outline
	b_import.on_click = fn [mut st] () {
		if !isnil(st.import_presets) {
			st.import_presets()
		}
	}
	mut b_all := vgui.button(i18n.tr('Экспорт всех...'))
	b_all.style = .outline
	b_all.on_click = fn [mut st] () {
		if !isnil(st.export_presets) {
			st.export_presets(Preset{})
		}
	}
	u.b_all = b_all
	mut side := vgui.create_vbox_fill()
	side.set_spacing(6)
	side.set_padding(0)
	side.add(b_delete)
	side.add(b_export)
	side.add(b_import)
	side.add(b_all)
	side.add(vgui.create_spacer(), flex: 1)

	mut top := vgui.create_hbox_fill()
	top.set_spacing(10)
	top.set_padding(0)
	top.add(list, flex: 1)
	top.add(side, min: 150)

	// Переименование: имя выбранного пресета в поле, Enter - переименовать
	mut name_l := vgui.label(i18n.tr('Имя'))
	mut name := vgui.text_input(i18n.tr('Имя пресета'))
	name.on_submit = fn [mut st] (s string) {
		presets_rename(mut st)
	}
	u.name = name
	mut b_rename := vgui.button(i18n.tr('Переименовать'))
	b_rename.style = .outline
	b_rename.on_click = fn [mut st] () {
		presets_rename(mut st)
	}
	u.b_rename = b_rename
	mut name_row := vgui.create_hbox_fill()
	name_row.set_spacing(8)
	name_row.set_padding(0)
	name_row.add(name_l)
	name_row.add(name, flex: 1)
	name_row.add(b_rename, min: 150)

	mut b_close := vgui.button(i18n.tr('Закрыть'))
	b_close.style = .accent
	b_close.on_click = fn [mut dlg] () {
		dlg.close_with_result(0)
	}
	mut btn_row := vgui.create_hbox_fill()
	btn_row.set_padding(0)
	btn_row.add(vgui.create_spacer(), flex: 1)
	btn_row.add(b_close, min: 100)

	mut body := vgui.create_vbox_fill()
	body.set_padding(16)
	body.set_spacing(10)
	body.add(top, flex: 1)
	body.add(name_row)
	body.add(btn_row)

	u.scroll = dialog_scroll(body)
	dlg.add_widget(u.scroll)
	app.add_dialog(dlg)
	st.presets_ui = u
}
