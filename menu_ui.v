module main

// Меню вверху окна: «Файл», «Правка», «Вид», «Отбор», «Пресеты» - пункты,
// сочетания (их обрабатывает сам MenuBar), доступность без кадра.
// Вынесено из main() 13.11.2026 (аудит, п. 11).
import os
import vgui
import i18n

// MenuActions - действия окна, которые зовут пункты меню (их собирает
// main: открытие файла и папки, отмена, тон, экспорт)
struct MenuActions {
	open_file          fn (string) = unsafe { nil }
	open_file_dialog   fn ()       = unsafe { nil }
	open_folder        fn (string) = unsafe { nil }
	open_folder_dialog fn ()       = unsafe { nil }
	delete_rejected    fn ()       = unsafe { nil }
	undo               fn ()       = unsafe { nil }
	redo               fn ()       = unsafe { nil }
	reset_tone         fn ()       = unsafe { nil }
	auto_tone          fn ()       = unsafe { nil }
	m_export           &vgui.MenuItem = unsafe { nil }
}

// build_menu - строка меню окна
fn build_menu(mut st State, mut app vgui.App, win &vgui.Window, mut cv vgui.Canvas, mut hist vgui.Canvas, mut nm vgui.NotificationManager, acts MenuActions) &vgui.MenuBar {
	mut wh := unsafe { win } // привязка клавиш окна
	open_file := acts.open_file
	open_file_dialog := acts.open_file_dialog
	open_folder := acts.open_folder
	open_folder_dialog := acts.open_folder_dialog
	delete_rejected := acts.delete_rejected
	undo := acts.undo
	redo := acts.redo
	reset_tone := acts.reset_tone
	auto_tone_fn := acts.auto_tone
	mut m_export := acts.m_export
	// Сочетания клавиш пунктов обрабатывает само меню (MenuBar)
	mut bar := vgui.menu_bar()
	mut m_open := vgui.menu_action(i18n.tr('Открыть файл...'))
	m_open.shortcut = 'Ctrl+O'
	m_open.on_click = open_file_dialog
	mut m_open_dir := vgui.menu_action(i18n.tr('Открыть папку...'))
	m_open_dir.shortcut = 'Ctrl+Shift+O'
	m_open_dir.on_click = open_folder_dialog
	mut m_quit := vgui.menu_action(i18n.tr('Выход'))
	m_quit.shortcut = 'Ctrl+Q'
	m_quit.on_click = fn [mut app] () {
		app.quit()
	}
	// Недавние (recent.v): пункты подменю собирает rebuild_recent_menus
	m_recent_files := vgui.menu_submenu(i18n.tr('Недавние файлы'))
	m_recent_dirs := vgui.menu_submenu(i18n.tr('Недавние папки'))
	st.m_recent_files = m_recent_files
	st.m_recent_dirs = m_recent_dirs
	st.open_path = open_file
	st.open_dir = open_folder
	rebuild_recent_menus(mut st)
	// Показать в папке (reveal_*.c.v): файловый менеджер с выделенным
	// кадром - Ctrl+R, как «Показать в Проводнике» в Lightroom
	mut m_reveal := vgui.menu_action(i18n.tr('Показать в папке'))
	m_reveal.shortcut = 'Ctrl+R'
	m_reveal.on_click = fn [mut st, mut nm] () {
		reveal_in_folder(reveal_paths(st), mut st.reveal_procs) or {
			nm.show_error(i18n.trf('Не удалось открыть папку: {0}', err.msg()))
		}
	}
	bar.add_menu(i18n.tr('Файл'), [m_open, m_open_dir, m_recent_files, m_recent_dirs,
		vgui.menu_separator(), m_reveal, m_export, vgui.menu_separator(), m_quit])
	// Горячие клавиши - настраиваемые (hotkeys.v): ключи постоянные, по
	// умолчанию - сочетания, заданные пунктам выше
	hk_add(mut st, 'file.open', 'Файл', mut m_open)
	hk_add(mut st, 'file.open_dir', 'Файл', mut m_open_dir)
	hk_add(mut st, 'file.reveal', 'Файл', mut m_reveal)
	hk_add(mut st, 'file.export', 'Файл', mut m_export)
	hk_add(mut st, 'file.quit', 'Файл', mut m_quit)
	avail_add(mut st, .export, [m_export])
	avail_add(mut st, .target, [m_reveal])

	mut m_undo := vgui.menu_action(i18n.tr('Отменить'))
	m_undo.shortcut = 'Ctrl+Z'
	m_undo.on_click = undo
	mut m_redo := vgui.menu_action(i18n.tr('Вернуть'))
	m_redo.shortcut = 'Ctrl+Shift+Z'
	m_redo.on_click = redo
	mut m_reset := vgui.menu_action(i18n.tr('Сбросить тон'))
	m_reset.shortcut = 'Ctrl+Shift+R'
	m_reset.on_click = reset_tone
	mut m_autotone := vgui.menu_action(i18n.tr('Автотон'))
	m_autotone.shortcut = 'Ctrl+U'
	m_autotone.on_click = auto_tone_fn
	mut m_settings := vgui.menu_action(i18n.tr('Настройки...'))
	m_settings.shortcut = 'Ctrl+P'
	m_settings.on_click = fn [mut st] () {
		st.open_settings()
	}
	// Копирование настроек и пресеты (presets.v): окно групп, вставка в
	// открытый кадр или в выделенные в ленте
	st.paste_fn = fn [mut st, mut cv, mut hist, mut nm, mut app] (src EditState, groups []string, name string) {
		paste_settings(mut st, src, groups, name, mut cv, mut hist, mut nm, mut app)
	}
	st.show_groups = fn [mut st, mut app, win] (preset bool) {
		show_groups(mut st, mut app, win, preset)
	}
	mut m_copy := vgui.menu_action(i18n.tr('Копировать настройки...'))
	m_copy.shortcut = 'Ctrl+Shift+C'
	m_copy.on_click = fn [mut st] () {
		st.show_groups(false)
	}
	mut m_paste := vgui.menu_action(i18n.tr('Вставить настройки'))
	m_paste.shortcut = 'Ctrl+Shift+V'
	m_paste.on_click = fn [mut st] () {
		if st.clip_groups.len > 0 {
			st.paste_fn(st.clip, st.clip_groups, i18n.tr('Вставка настроек'))
		}
	}
	st.m_paste = m_paste
	// Режим кадрирования (crop.v): R, как в Lightroom
	mut m_crop := vgui.menu_checkbox(i18n.tr('Кадрирование'), false)
	m_crop.shortcut = 'R'
	m_crop.on_toggle = fn [mut st] (v bool) {
		set_crop_mode(mut st, v)
	}
	st.crop_ui.m_crop = m_crop
	// Выделить все кадры ленты (для вставки настроек и экспорта)
	mut m_all := vgui.menu_action(i18n.tr('Выделить все кадры'))
	m_all.shortcut = 'Ctrl+A'
	m_all.on_click = fn [mut st] () {
		select_all_frames(mut st)
	}
	// Пипетка баланса белого (wb_ui.v) - как кнопка в разделе «Баланс белого»
	mut m_pick := vgui.menu_action(i18n.tr('Пипетка баланса белого'))
	m_pick.shortcut = 'W'
	m_pick.on_click = fn [mut st] () {
		set_wb_pick(mut st, !st.wb_pick && st.linear.len > 0)
	}
	// Удаление пятен (spots_ui.v): Q, как в Lightroom
	mut m_spots := vgui.menu_checkbox(i18n.tr('Удаление пятен'), false)
	m_spots.shortcut = 'Q'
	m_spots.on_toggle = fn [mut st] (v bool) {
		set_spot_mode(mut st, v)
	}
	if !isnil(st.spot_ui) {
		mut su := st.spot_ui
		su.m_spots = m_spots
	}
	bar.add_menu(i18n.tr('Правка'), [m_undo, m_redo, vgui.menu_separator(), m_copy, m_paste,
		m_all, vgui.menu_separator(), m_crop, m_spots, m_pick, m_autotone, m_reset, vgui.menu_separator(),
		m_settings])
	hk_add(mut st, 'edit.undo', 'Правка', mut m_undo)
	hk_add(mut st, 'edit.redo', 'Правка', mut m_redo)
	hk_add(mut st, 'edit.copy', 'Правка', mut m_copy)
	hk_add(mut st, 'edit.paste', 'Правка', mut m_paste)
	hk_add(mut st, 'edit.select_all', 'Правка', mut m_all)
	hk_add(mut st, 'edit.crop', 'Правка', mut m_crop)
	hk_add(mut st, 'edit.spots', 'Правка', mut m_spots)
	hk_add(mut st, 'edit.wb_pick', 'Правка', mut m_pick)
	hk_add(mut st, 'edit.autotone', 'Правка', mut m_autotone)
	hk_add(mut st, 'edit.reset_tone', 'Правка', mut m_reset)
	hk_add(mut st, 'edit.settings', 'Правка', mut m_settings)
	avail_add(mut st, .undo, [m_undo])
	avail_add(mut st, .redo, [m_redo])
	avail_add(mut st, .frame, [m_copy, m_reset])
	avail_add(mut st, .paste, [m_paste])
	avail_add(mut st, .frames, [m_all])
	avail_add(mut st, .pixels, [m_crop, m_spots, m_pick, m_autotone])

	mut m_fit := vgui.menu_action(i18n.tr('Вписать'))
	m_fit.shortcut = 'Ctrl+0'
	m_fit.on_click = fn [mut cv] () {
		cv.fit_to_view()
	}
	mut m_z50 := vgui.menu_action('50%')
	m_z50.on_click = fn [mut cv] () {
		cv.set_zoom(0.5)
	}
	mut m_z100 := vgui.menu_action('100% (1:1)')
	m_z100.shortcut = 'Ctrl+1'
	m_z100.on_click = fn [mut cv] () {
		cv.set_zoom(1.0)
	}
	mut m_z200 := vgui.menu_action('200%')
	m_z200.on_click = fn [mut cv] () {
		cv.set_zoom(2.0)
	}
	// Увеличение 100% и обратно (щелчок по снимку - то же в точку щелчка)
	mut m_zoom := vgui.menu_action(i18n.tr('100% / вписать'))
	m_zoom.shortcut = 'Z'
	m_zoom.on_click = fn [mut st] () {
		toggle_zoom_center(mut st)
	}
	wh.bind_hotkey('Space', fn [mut st] () {
		toggle_zoom_center(mut st)
	})
	// До/после (compare.v): шторка - Y, весь снимок «до» - пока зажата «\»
	mut m_split := vgui.menu_checkbox(i18n.tr('До/после: шторка'), false)
	m_split.shortcut = 'Y'
	m_split.on_toggle = fn [mut st] (v bool) {
		set_ba_split(mut st, v)
	}
	st.m_split = m_split
	mut m_sbs := vgui.menu_checkbox(i18n.tr('До/после: бок о бок'), false)
	m_sbs.shortcut = 'Shift+Y'
	m_sbs.on_toggle = fn [mut st] (v bool) {
		set_ba_sbs(mut st, v)
	}
	st.m_sbs = m_sbs
	// Сравнение двух кадров (pair.v): C, как в Lightroom
	mut m_pair := vgui.menu_checkbox(i18n.tr('Сравнить с выделенным'), false)
	m_pair.shortcut = 'C'
	m_pair.on_toggle = fn [mut st] (v bool) {
		set_pair(mut st, v)
	}
	st.m_pair = m_pair
	mut m_swap := vgui.menu_action(i18n.tr('Сравнение: поменять местами'))
	m_swap.shortcut = 'Shift+C'
	m_swap.on_click = fn [mut st] () {
		pair_swap(mut st)
	}
	// JPEG камеры вместо проявки (camjpeg.v)
	mut m_jpeg := vgui.menu_checkbox(i18n.tr('JPEG камеры'), false)
	m_jpeg.shortcut = 'K'
	m_jpeg.on_toggle = fn [mut st] (v bool) {
		set_jpeg_show(mut st, v)
	}
	st.m_jpeg = m_jpeg
	// Раскладка окна (panel.v): лента и панель скрываются целиком (F6/F8,
	// как в Lightroom), панель - справа или слева
	mut m_strip := vgui.menu_checkbox(i18n.tr('Лента кадров'), !st.settings.no_strip)
	m_strip.shortcut = 'F6'
	m_strip.on_toggle = fn [mut st] (v bool) {
		set_strip_visible(mut st, v)
	}
	st.m_strip = m_strip
	// Обновить ленту: файлы, скопированные в папку во время работы
	mut m_refresh := vgui.menu_action(i18n.tr('Обновить ленту'))
	m_refresh.shortcut = 'F5'
	m_refresh.on_click = fn [mut st] () {
		refresh_folder(mut st)
	}
	mut m_panel := vgui.menu_checkbox(i18n.tr('Панель инструментов'), !st.settings.no_panel)
	m_panel.shortcut = 'F8'
	m_panel.on_toggle = fn [mut st] (v bool) {
		set_panel_visible(mut st, v)
	}
	st.m_panel = m_panel
	mut m_left := vgui.menu_checkbox(i18n.tr('Панель слева'), st.settings.panel_left)
	m_left.on_toggle = fn [mut st] (v bool) {
		set_panel_left(mut st, v)
	}
	st.m_left = m_left
	// Полноэкранный режим: F, выход - F или Esc (как в Lightroom)
	mut m_full := vgui.menu_checkbox(i18n.tr('Полноэкранный режим'), false)
	m_full.shortcut = 'F'
	m_full.on_toggle = fn [mut st] (v bool) {
		set_fullscreen(mut st, v)
	}
	st.m_full = m_full
	mut m_top := vgui.menu_checkbox(i18n.tr('Лента сверху'), st.settings.strip_top)
	m_top.on_toggle = fn [mut st] (v bool) {
		set_strip_top(mut st, v)
	}
	st.m_top = m_top
	// Пересветы и провалы (clipping.v): J - оба сразу, как в Lightroom
	mut m_clipwarn := vgui.menu_checkbox(i18n.tr('Пересветы и провалы'), false)
	m_clipwarn.shortcut = 'J'
	m_clipwarn.on_toggle = fn [mut st] (v bool) {
		set_clip_warn(mut st, v, v)
	}
	st.m_clipwarn = m_clipwarn
	// Маска фокуса (focus.v): резкие места зелёным, как в Capture One
	mut m_focus := vgui.menu_checkbox(i18n.tr('Маска фокуса'), false)
	m_focus.shortcut = 'Shift+F'
	m_focus.on_toggle = fn [mut st] (v bool) {
		set_focus_show(mut st, v)
	}
	st.m_focus = m_focus
	// Заливка маски выделенного градиентного фильтра (masks.v)
	mut m_mask := vgui.menu_checkbox(i18n.tr('Маска фильтра'), st.mask_show)
	m_mask.shortcut = 'O'
	m_mask.on_toggle = fn [mut st] (v bool) {
		set_mask_show(mut st, v)
	}
	st.mask_ui.m_show = m_mask
	// Миникарта при увеличении (vgui): весь снимок и рамка видимого,
	// щелчок по ней - вид туда
	mut m_nav := vgui.menu_checkbox(i18n.tr('Миникарта'), !st.settings.no_navigator)
	m_nav.shortcut = 'N'
	m_nav.on_toggle = fn [mut st, mut cv] (v bool) {
		st.settings.no_navigator = !v
		save_settings(st.settings)
		cv.navigator = v
		cv.mark_dirty()
	}
	// Сведения о съёмке поверх снимка (shotinfo.v), как I в Lightroom
	mut m_info := vgui.menu_checkbox(i18n.tr('Сведения о съёмке'), !st.settings.no_info)
	m_info.shortcut = 'I'
	m_info.on_toggle = fn [mut st] (v bool) {
		set_show_info(mut st, v)
	}
	// Фон вокруг снимка: пункты-флажки, работают как переключатель
	// (отмечен ровно один - set_viewer_bg)
	mut m_bg := vgui.menu_submenu(i18n.tr('Фон вокруг снимка'))
	for i in 0 .. bg_keys.len {
		mut it := vgui.menu_checkbox(i18n.tr(bg_names[i]), bg_keys[i] == st.settings.viewer_bg)
		it.on_toggle = fn [mut st, i] (v bool) {
			set_viewer_bg(mut st, i)
		}
		st.m_bg << it
		m_bg.add(it)
	}
	// Тема оформления: все темы vgui, пункты-флажки как переключатель
	mut m_themes := vgui.menu_submenu(i18n.tr('Тема'))
	for i in 0 .. theme_keys.len {
		mut it := vgui.menu_checkbox(i18n.tr(theme_names[i]), theme_keys[i] == st.settings.theme)
		it.on_toggle = fn [mut st, mut app, i] (v bool) {
			apply_theme(mut st, mut app, i)
		}
		st.m_theme << it
		m_themes.add(it)
	}
	// Вид гистограммы (histogram.v)
	m_hist, hist_items := hist_menu(mut st)
	bar.add_menu(i18n.tr('Вид'), [m_fit, m_z50, m_z100, m_z200, m_zoom, vgui.menu_separator(), m_split,
		m_sbs, m_pair, m_swap, m_jpeg, m_clipwarn, m_focus, m_hist, m_mask, m_info, m_nav, vgui.menu_separator(), m_full, m_strip, m_refresh, m_top, m_panel, m_left, m_bg, m_themes])
	view_ids := ['view.fit', 'view.z50', 'view.z100', 'view.z200', 'view.zoom', 'view.split',
		'view.sbs', 'view.pair', 'view.swap', 'view.jpeg', 'view.clipwarn', 'view.focus', 'view.mask', 'view.info', 'view.nav', 'view.full',
		'view.strip', 'view.refresh', 'view.top', 'view.panel', 'view.left']
	view_items := [m_fit, m_z50, m_z100, m_z200, m_zoom, m_split, m_sbs, m_pair, m_swap, m_jpeg,
		m_clipwarn, m_focus, m_mask, m_info, m_nav, m_full, m_strip, m_refresh, m_top, m_panel, m_left]
	for i, id in view_ids {
		mut it := view_items[i]
		hk_add(mut st, id, 'Вид', mut it)
	}
	for i, id in ['view.hist_raw', 'view.hist_log', 'view.hist_luma'] {
		mut it := hist_items[i]
		hk_add(mut st, id, 'Вид', mut it)
	}
	avail_add(mut st, .frame, [m_fit, m_z50, m_z100, m_z200, m_zoom, m_split, m_sbs, m_jpeg,
		m_clipwarn, m_focus])

	// «Отбор» (rating.v): звёзды и флажки - клавишами, как в Lightroom;
	// действуют на выделенные в ленте кадры, без выделения - на открытый
	mut pick_items := []&vgui.MenuItem{}
	for r in 0 .. 6 {
		mut it := vgui.menu_action(if r == 0 {
			i18n.tr('Без звёзд')
		} else {
			'${r} ${i18n.pl(r, 'звезда|звезды|звёзд')}'
		})
		it.shortcut = '${r}'
		it.on_click = fn [mut st, r] () {
			set_rating(mut st, r)
		}
		pick_items << it
	}
	pick_items << vgui.menu_separator()
	flag_names := [i18n.tr('Отобран'), i18n.tr('Отклонён'), i18n.tr('Снять флажок')]
	flag_keys := ['P', 'X', 'U']
	flag_vals := [1, -1, 0]
	for k in 0 .. 3 {
		mut it := vgui.menu_action(flag_names[k])
		it.shortcut = flag_keys[k]
		f := flag_vals[k]
		it.on_click = fn [mut st, f] () {
			set_flag(mut st, f)
		}
		pick_items << it
	}
	pick_items << vgui.menu_separator()
	mut m_advance := vgui.menu_checkbox(i18n.tr('Переходить к следующему кадру'), st.settings.auto_advance)
	m_advance.on_toggle = fn [mut st] (v bool) {
		st.settings.auto_advance = v
		save_settings(st.settings)
	}
	avail_add(mut st, .target, pick_items.filter(it.kind != .separator))
	pick_items << m_advance
	pick_items << vgui.menu_separator()
	// Как в Lightroom: Ctrl+Backspace
	mut m_del_rej := vgui.menu_action(i18n.tr('Удалить отклонённые...'))
	m_del_rej.shortcut = 'Ctrl+Backspace'
	m_del_rej.on_click = fn [delete_rejected] () {
		delete_rejected()
	}
	pick_items << m_del_rej
	avail_add(mut st, .frames, [m_del_rej])
	bar.add_menu(i18n.tr('Отбор'), pick_items)
	pick_ids := ['pick.rate0', 'pick.rate1', 'pick.rate2', 'pick.rate3', 'pick.rate4',
		'pick.rate5', '', 'pick.flag_pick', 'pick.flag_reject', 'pick.flag_none', '',
		'pick.advance', '', 'pick.del_rejected']
	for i, id in pick_ids {
		if id.len > 0 {
			mut it := pick_items[i]
			hk_add(mut st, id, 'Отбор', mut it)
		}
	}

	// «Пресеты» - список пересобирается при сохранении (rebuild_presets_menu)
	st.bar = bar
	st.import_presets = fn [mut st, mut app, win, mut nm] () {
		files := vgui.native_open_files_dialog(win, mut app, vgui.NativeFileDialogConfig{
			filter_names:    [i18n.tr('Пресеты vraw'), i18n.tr('Все файлы')]
			filter_patterns: ['json', '*']
		})
		if files.len == 0 {
			return
		}
		mut names := []string{}
		mut failed := []string{}
		for f in files {
			names << import_preset(f, presets_dir()) or {
				failed << '${os.file_name(f)}: ${err.msg()}'
				continue
			}
		}
		rebuild_presets_menu(mut st)
		if failed.len > 0 {
			nm.show_error(i18n.trf('Не импортировано {0} из {1}: {2}', '${failed.len}', '${files.len}', '${failed[0]}'))
		} else if names.len == 1 {
			nm.show_success(i18n.trf('Пресет «{0}» импортирован', '${names[0]}'))
		} else {
			nm.show_success(i18n.trf('Импортировано пресетов: {0}', '${names.len}'))
		}
	}
	st.export_presets = fn [mut app, win, mut nm] (p Preset) {
		if p.path.len > 0 {
			dst := vgui.native_save_file_dialog(win, mut app, vgui.NativeFileDialogConfig{
				default_name:    '${p.name}.json'
				filter_names:    [i18n.tr('Пресеты vraw')]
				filter_patterns: ['json']
			})
			if dst.len == 0 {
				return
			}
			path := if dst.to_lower().ends_with('.json') { dst } else { dst + '.json' }
			export_preset(p, path) or {
				nm.show_error(i18n.trf('Пресет не экспортирован: {0}', '${err.msg()}'))
				return
			}
			nm.show_success(i18n.trf('Пресет «{0}» сохранён: {1}', '${p.name}', '${os.file_name(path)}'))
			return
		}
		all := list_presets(presets_dir())
		dir := vgui.native_select_folder_dialog(win, mut app, vgui.NativeFileDialogConfig{})
		if dir.len == 0 {
			return
		}
		n := export_presets(all, dir) or {
			nm.show_error(i18n.trf('Пресеты не экспортированы: {0}', '${err.msg()}'))
			return
		}
		nm.show_success(i18n.trf('Экспортировано пресетов: {0} в {1}', '${n}', '${os.file_name(dir)}'))
	}
	st.show_presets = fn [mut st, mut app, win] () {
		show_presets(mut st, mut app, win)
	}
	st.presets_menu = bar.entries.len
	bar.add_menu(i18n.tr('Пресеты'), []&vgui.MenuItem{})
	rebuild_presets_menu(mut st)
	avail_add(mut st, .pair, [m_pair])
	avail_add(mut st, .swap, [m_swap])
	avail_add(mut st, .mask, [m_mask])
	return bar
}
