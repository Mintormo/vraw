module main

// Действия меню «Файл» и тона: открыть файл или папку (диалоги), закрыть
// кадр, удалить отклонённые, экспорт одного кадра и пакета, «Сброс» и
// «Автотон». Вынесено из main() 13.11.2026 (аудит, п. 11).
import os
import time
import imgio
import pipeline
import raw
import vgui
import i18n

// FileActions - действия открытия, которые зовут меню и лента
struct FileActions {
	open_file_dialog   fn ()       = unsafe { nil }
	open_folder        fn (string) = unsafe { nil }
	open_folder_dialog fn ()       = unsafe { nil }
	delete_rejected    fn ()       = unsafe { nil }
}

// file_actions - открыть файл или папку, закрыть кадр, удалить
// отклонённые (open_file - открытие кадра, его собирает main)
fn file_actions(mut st State, mut app vgui.App, win &vgui.Window, mut cv vgui.Canvas, mut hist vgui.Canvas, mut nm vgui.NotificationManager, mut lens_cb vgui.CheckBox, mut lens_lb vgui.Label, mut placeholder vgui.Stack, open_file fn (string)) FileActions {
	open_file_dialog := fn [mut app, win, open_file] () {
		path := vgui.native_open_file_dialog(win, mut app, vgui.NativeFileDialogConfig{
			filter_names:    [i18n.tr('RAW-файлы'), i18n.tr('Все файлы')]
			filter_patterns: [raw_patterns, '*']
		})
		if path.len > 0 {
			open_file(path)
		}
	}

	// close_file - в области просмотра нет кадра (открыта папка без
	// выбора): загрузка отменяется, LibRaw закрывается, история пуста
	// (правки некуда писать - record без истории молчит), вместо снимка -
	// заглушка. Результаты фоновых воркеров отбросятся по file_gen.
	close_file := fn [mut st, mut cv, mut hist, mut lens_cb, mut lens_lb, mut placeholder] () {
		set_pair(mut st, false)
		prefetch_cancel(mut st)
		frame_store(mut st)
		if !isnil(st.load_stop) {
			mut ls := st.load_stop
			ls.set()
		}
		st.loading = false
		if !isnil(st.dev) {
			st.dev.close()
			st.dev = unsafe { nil }
		}
		st.corr = unsafe { nil }
		st.file_gen++
		detail_reset(mut st)
		ba_forget(mut st)
		st.raw_pending = false
		drop(mut st.dev_linear)
		drop(mut st.raw_linear)
		drop(mut st.linear)
		drop(mut st.mask)
		st.lin_gen++
		drop(mut st.glin)
		drop(mut st.gmask)
		crop_leave(mut st)
		spot_leave(mut st)
		pc_leave(mut st)
		st.mask_sel = -1
		st.mask_part = -1
		st.mask_drag = MaskDrag{}
		st.poly_open = false
		st.poly_vsel = -1
		st.haze = pipeline.HazeMap{}
		st.look = CamLook{}
		drop(mut st.cam_view)
		st.side_path = ''
		st.raw_path = ''
		update_title(mut st)
		st.mark = Mark{}
		set_cam_color(mut st, pipeline.CamColor{})
		set_wb_pick(mut st, false)
		set_edit(mut st, neutral_edit())
		st.history = []HistEntry{}
		st.hist_pos = 0
		refresh_history(mut st)
		st.frame_idx = -1
		lens_lb.text = i18n.tr(lens_no_info)
		lens_cb.enabled = false
		clear_histogram(mut st, mut hist)
		show_loading(mut st, false)
		show_placeholder(mut cv, mut placeholder)
		sync_view_bg(mut st)
		sync_avail(mut st)
	}

	// Открыть папку: все RAW - в ленте, в области просмотра ничего
	// (заглушка «Выберите кадр»); кадр открывается двойным щелчком
	open_folder := fn [mut st, mut app, mut nm, close_file] (dir string) {
		close_file()
		load_folder(mut st, os.real_path(dir), '', mut app)
		add_recent(mut st, os.real_path(dir), true)
		sync_strip(mut st)
		mut ph := st.holder
		set_placeholder_text(mut ph, st.frames.len > 0)
		if st.frames.len == 0 {
			nm.show_warning(i18n.tr('В папке нет RAW-файлов'))
		}
	}
	// Удалить отклонённые (rating.v): RAW и сайдкары - в корзину (вернуть
	// можно файловым менеджером), лента - заново; открытый кадр ушёл -
	// открывается ближайший оставшийся. Файлы читают воркеры (миниатюры,
	// предзагрузка, экспорт) - на Windows открытый файл не удалить, поэтому
	// во время экспорта нельзя, остальное останавливается.
	delete_rejected := fn [mut st, mut app, mut nm, close_file, open_file, win] () {
		if st.folder == '' {
			return
		}
		if !isnil(st.exp) {
			nm.show_warning(i18n.tr('Дождитесь конца экспорта'))
			return
		}
		gone := rejected_paths(st.frames)
		if gone.len == 0 {
			nm.show_info(i18n.tr('Отклонённых кадров в папке нет'))
			return
		}
		answer := vgui.message_box(win, mut app, vgui.MessageBoxConfig{
			title:          i18n.tr('Удалить отклонённые')
			message:        i18n.trf('Переместить в корзину отклонённые кадры ({0})? RAW-файлы и их правки можно будет вернуть из корзины.',
				'${gone.len}')
			kind:           .warning
			buttons:        [i18n.tr('В корзину'), i18n.tr('Отмена')]
			default_button: 1
			cancel_button:  1
		})
		if answer != 0 {
			return
		}
		cur := st.raw_path
		mut next := cur
		if cur in gone {
			next = after_trash(st.frames, st.frame_idx, gone)
			close_file()
		}
		prefetch_cancel(mut st)
		stop_thumbs(mut st)
		wait_thumbs(mut st)
		for p in gone {
			frame_drop(mut st, p)
		}
		n, errs := trash_frames(gone)
		load_folder(mut st, st.folder, next, mut app)
		if next != '' && next != st.raw_path {
			open_file(next)
		} else {
			show_frame(mut st, next, mut app)
		}
		if st.frames.len == 0 {
			mut ph := st.holder
			set_placeholder_text(mut ph, false)
		}
		if errs.len > 0 {
			nm.show_error(i18n.trf('Не всё удалось переместить в корзину: {0}', errs.join('; ')))
		}
		if n > 0 {
			nm.show_success(i18n.trf('В корзине: {0}', '${n} ${i18n.pl(n, 'кадр|кадра|кадров')}'))
		}
	}
	open_folder_dialog := fn [mut app, win, open_folder] () {
		dir := vgui.native_select_folder_dialog(win, mut app, vgui.NativeFileDialogConfig{})
		if dir.len > 0 {
			open_folder(dir)
		}
	}
	return FileActions{
		open_file_dialog:   open_file_dialog
		open_folder:        open_folder
		open_folder_dialog: open_folder_dialog
		delete_rejected:    delete_rejected
	}
}

// build_export - пункт «Файл - Экспорт...»: экспорт одного кадра и пакета
// в фоне, прогресс, итог
fn build_export(mut st State, mut app vgui.App, win &vgui.Window, mut nm vgui.NotificationManager) &vgui.MenuItem {
	// Экспорт (JPEG, PNG, TIFF, BMP, QOI, GIF - imgio) - в фоновом потоке
	// (полный кадр с коррекцией ~3.5 с, окно не должно замирать), ход - в
	// диалоге экспорта (export_ui.v). Пока
	// экспорт идёт, пункт меню не запускает второй, а снова открывает
	// диалог; ползунки остаются живыми. Прогресс и результат воркер
	// доставляет через app.post() - цикл vgui спит как обычно.
	mut m_export := vgui.menu_action(i18n.tr('Экспорт...'))
	m_export.shortcut = 'Ctrl+E'
	st.exp_progress = fn [mut st] (ctl &ExportCtl, stage ExportStage, done int, total int) {
		mut c := unsafe { ctl }
		if stage != c.stage {
			c.done = 0
			c.total = 0
		}
		c.stage = stage
		if total > 0 {
			c.done = done
			c.total = total
		}
		if st.exp == ctl {
			sync_export_ui(mut st)
		}
	}
	save_done := fn [mut st, mut nm] (res SaveOutcome, msg string) {
		st.exp = unsafe { nil }
		// Итог - в открытом диалоге, иначе тостом
		if !export_finished(mut st, res, msg) {
			match res {
				.saved { nm.show_success(msg) }
				.failed { nm.show_error(msg) }
				.cancelled { nm.show_warning(msg) }
			}
		}
		sync_settings_ui(mut st)
	}
	// «Файл - Экспорт...»: идёт экспорт - его диалог прогресса, иначе
	// окно «Экспорт» (export_setup.v), оно и запускает start_export
	m_export.on_click = fn [mut st, mut nm, mut app, win] () {
		if !isnil(st.exp) {
			show_export(mut st, mut app, win)
			return
		}
		if st.loading {
			nm.show_warning(i18n.tr('Кадр ещё загружается'))
			return
		}
		if isnil(st.dev) && st.frames.len == 0 {
			nm.show_warning(i18n.tr('Сначала откройте RAW-файл или папку'))
			return
		}
		show_export_setup(mut st, mut app, win)
	}
	st.export_go = fn [mut st, mut app, win, save_done] (path string, fmt imgio.Format) {
		if !isnil(st.exp) || isnil(st.dev) {
			return
		}
		edit := st.edit.clone()
		ctl := &ExportCtl{
			src:     st.dev.path
			dst:     path
			fmt:     fmt
			plan:    export_plan(edit, fmt)
			started: time.now().unix_milli()
		}
		// Снимок всего нужного по значению: воркер не трогает st после спавна
		job := SaveJob{
			src:      st.dev.path
			dst:      path
			db:       st.lens_db
			edit:     edit
			format:   fmt
			quality:  st.settings.jpeg_quality
			size:     st.settings.export_size_opts()
			load:     load_level(st.settings.export_load)
			settings: st.settings
			ctl:      ctl
			on_stage: st.exp_progress
		}
		st.exp = ctl
		show_export(mut st, mut app, win)
		export_started(mut st)
		wd := &Done{}
		track(mut st.save_threads, spawn save_worker(wd, job, mut app, save_done), wd)
	}
	st.exp_event = fn [mut st] (ctl &ExportCtl, ev BatchEvent) {
		batch_event(mut st, ctl, ev)
	}
	// Пакетный экспорт: настройки кадров - здесь (сайдкары),
	// проявка - в фоне по очереди (batch_worker)
	st.export_batch = fn [mut st, mut nm, mut app, win, save_done] (paths []string) {
		if !isnil(st.exp) || paths.len == 0 {
			return
		}
		fmt := st.settings.export_fmt()
		items, bad := batch_items(st, paths)
		if bad.len > 0 {
			nm.show_warning(i18n.trf('Правки не прочитаны, кадр без них: {0}', '${bad.join(', ')}'))
		}
		ctl := &ExportCtl{
			src:     items[0].src
			fmt:     fmt
			n:       items.len
			load:    st.settings.export_load
			started: time.now().unix_milli()
		}
		job := BatchJob{
			items:     items
			settings:  st.settings
			format:    fmt
			db:        st.lens_db
			ctl:       ctl
			on_event:  st.exp_event
		}
		st.exp = ctl
		show_export(mut st, mut app, win)
		export_started(mut st)
		sync_settings_ui(mut st)
		wd := &Done{}
		track(mut st.save_threads, spawn batch_worker(wd, job, mut app, save_done), wd)
	}
	return m_export
}

// tone_actions - «Сброс» тональный и «Автотон» (пункты меню и кнопка)
fn tone_actions(mut st State, mut app vgui.App, mut cv vgui.Canvas, mut hist vgui.Canvas, mut nm vgui.NotificationManager) (fn (), fn ()) {
	// «Сброс» тональный: коррекция объектива, камерная кривая
	// и шумодав остаются как есть. Это обычная правка - запись в истории,
	// отменяется Ctrl+Z. Пункт меню «Правка - Сбросить тон».
	reset_tone := fn [mut st, mut cv, mut hist, mut app] () {
		mut e := st.edit.clone()
		// Баланс белого (в EditState, не в params), резкость и эффекты -
		// не тон, «Сброс» их не трогает, как шумодав
		e.params = pipeline.Params{
			sharp: st.edit.params.sharp
			fx:    st.edit.params.fx
		}
		e.curve_pts = neutral_edit().curve_pts
		restore_edit(mut st, e, mut cv, mut hist, mut app)
		record(mut st, 'reset', i18n.tr('Сброс'), false)
	}
	// «Автотон» (autotone.v): экспозиция, контраст, «Тени/Света», чёрные и
	// белые по гистограмме кадра - одной записью истории, отменяется Ctrl+Z.
	// Кнопка в секции «Экспозиция и тон» и «Правка - Автотон».
	auto_tone_fn := fn [mut st, mut cv, mut hist, mut nm, mut app] () {
		if st.linear.len == 0 {
			nm.show_warning(i18n.tr('Сначала откройте RAW-файл'))
			return
		}
		// По кадру после кадрирования (glin), до первого apply - по всему
		t := if st.glin.len == st.gw * st.gh * 3 && st.glin.len > 0 {
			auto_tone(st.glin, st.gmask, st.gw * st.gh, st.edit.params)
		} else {
			auto_tone(st.linear, st.mask, st.pw * st.ph, st.edit.params)
		}
		mut e := st.edit.clone()
		e.params = t.put(e.params)
		restore_edit(mut st, e, mut cv, mut hist, mut app)
		record(mut st, 'autotone', i18n.tr('Автотон'), false)
	}
	return reset_tone, auto_tone_fn
}

// build_open - открытие кадра (кнопка, аргумент, лента, недавние) и приём
// итогов загрузки и предзагрузки; возвращает open_file(путь)
fn build_open(mut st State, mut app vgui.App, mut cv vgui.Canvas, mut hist vgui.Canvas, mut nm vgui.NotificationManager, mut lens_cb vgui.CheckBox, mut lens_lb vgui.Label, mut placeholder vgui.Stack) fn (string) {
	// Быстрая часть - здесь, в главном потоке: файл, настройки и история
	// из сайдкара, лента. Проявка, коррекция и камерная кривая - в фоне
	// (load_worker), на месте снимка - оверлей «Обработка» (loading.v).
	open_file := fn [mut st, mut nm, mut app, mut lens_cb, mut lens_lb] (path_arg string) {
		// Полный путь: по нему лента ищет кадр и узнаёт смену папки
		path := os.real_path(path_arg)
		mut nd := raw.open(path) or {
			nm.show_error(i18n.trf('Ошибка: {0}', '${err.msg()}'))
			return
		}
		add_recent(mut st, path, false)
		// Открывают левый кадр сравнения - левым станет уходящий (pair.v)
		pair_before_open(mut st, path)
		// Предзагрузка соседа (prefetch.v): открывают его - её итог и
		// будет загрузкой, другой кадр - отменить
		adopt := prefetch_adopt(mut st, path, nd)
		if !adopt {
			prefetch_cancel(mut st)
		}
		// Сырьё уходящего кадра - в кэш (framecache.v): вернутся к нему -
		// без загрузки
		frame_store(mut st)
		// Незаконченная загрузка прежнего кадра отменяется; её dev/corr
		// освободит on_load_done, увидев старый file_gen
		if !isnil(st.load_stop) {
			mut ls := st.load_stop
			ls.set()
		}
		if !isnil(st.dev) {
			st.dev.close()
			st.dev = unsafe { nil }
		}
		// Профиль - из общей базы: фоновая подготовка может ещё держать
		// указатель, освобождать нечего, просто забываем
		st.corr = unsafe { nil }
		st.file_gen++
		detail_reset(mut st)
		ba_forget(mut st)
		st.loading = true
		st.raw_pending = false
		drop(mut st.dev_linear)
		drop(mut st.raw_linear)
		drop(mut st.linear)
		drop(mut st.mask)
		st.lin_gen++
		drop(mut st.glin)
		drop(mut st.gmask)
		crop_leave(mut st)
		spot_leave(mut st)
		pc_leave(mut st)
		st.mask_sel = -1
		st.mask_part = -1
		st.mask_drag = MaskDrag{}
		st.poly_open = false
		st.poly_vsel = -1
		st.haze = pipeline.HazeMap{}
		st.look = CamLook{}
		drop(mut st.cam_view)
		st.lens_dirty = false
		lens_lb.text = i18n.tr('поиск профиля объектива...')
		lens_cb.enabled = false
		// Цвет камеры - сразу (есть после open): ББ снимков и ползунков
		set_cam_color(mut st, cam_color(nd.color()))
		set_wb_pick(mut st, false)
		// Правки и история из сайдкара (производные поля снимков - по
		// камерной кривой - заполнит on_load_done)
		st.side_path = sidecar_path(path)
		st.raw_path = path
		update_title(mut st)
		st.side_err = false
		st.load_msg = ''
		side := load_sidecar(st.side_path) or {
			st.load_msg = i18n.trf('{0}: правки не прочитаны ({1})', '${os.file_name(path)}', '${err.msg()}')
			LoadedSidecar{}
		}
		st.mark = side.mark
		if side.history.len > 0 {
			set_edit(mut st, side.history[side.current].state)
			st.history = side.history.clone()
			st.hist_pos = side.current
			st.hist_ms = 0
			refresh_history(mut st)
		} else {
			set_edit(mut st, neutral_edit())
			start_history(mut st)
		}
		show_frame(mut st, path, mut app)
		sync_avail(mut st)
		if adopt {
			show_loading(mut st, true) // итог - из prefetch_take
			return
		}
		// Кадр в кэше - сразу итог загрузки, без воркера
		if res := frame_take(mut st, path, nd) {
			st.on_load_done(res)
			return
		}
		load_start(mut st, nd)
	}

	// Итог загрузки: хендлы и буферы - в State, затем досчитать то, что
	// изменили за время загрузки (как restore_edit), и apply
	st.on_load_done = fn [mut st, mut cv, mut hist, mut nm, mut app, mut lens_cb, mut lens_lb, mut placeholder] (res LoadResult) {
		if res.gen != st.file_gen {
			free_load(res) // отменённая загрузка прежнего кадра
			return
		}
		st.loading = false
		show_loading(mut st, false)
		if res.err.len > 0 {
			free_load(res)
			lens_lb.text = i18n.tr(lens_no_info)
			show_placeholder(mut cv, mut placeholder)
			sync_view_bg(mut st)
			sync_avail(mut st)
			nm.show_error(res.err)
			return
		}
		st.dev = res.dev
		st.dev.close() // нужны только путь и полный размер (кадр из кэша - хендл открыт)
		st.meta = res.meta
		st.corr = res.corr
		show_lens(st, mut lens_cb, mut lens_lb)
		// Холст - под размер кадра после геометрии (ensure_geom в apply)
		st.pw = res.w
		st.ph = res.h
		// Ссылки итога переходят в State (bufown.v)
		drop(mut st.dev_linear)
		drop(mut st.raw_linear)
		drop(mut st.linear)
		drop(mut st.mask)
		st.dev_linear = res.dev_linear
		st.raw_linear = res.raw_linear
		st.linear = res.linear
		st.mask = res.mask
		st.lin_gen++
		st.haze = pipeline.HazeMap{}
		// Что уже сделано с linear: у загрузки - ничего (dc_key пустой
		// резкости - нули), у кадра из кэша - как было
		st.nr_applied = res.nr_applied
		st.dc_applied = res.dc_applied
		st.lens_dirty = false
		st.raw_pending = false
		st.look = res.look
		drop(mut st.cam_view)
		st.cam_view = res.cam_view
		// Производные поля снимков - по камерной кривой этого кадра
		st.edit = with_derived(st.edit, st.look, st.cam)
		st.history = st.history.map(HistEntry{
			name:  it.name
			key:   it.key
			state: with_derived(it.state, st.look, st.cam)
		})
		show_viewer(mut cv, mut placeholder)
		sync_view_bg(mut st)
		// Что поменяли за время загрузки (и шумодав из сайдкара)
		if st.edit.lens_corr != res.lens_corr || st.edit.lman != res.man {
			request_prep(mut st, mut app, true)
		} else if prep_stale(st) {
			request_prep(mut st, mut app, false)
		}
		apply_pipeline(mut st, mut cv, mut hist)
		if st.load_msg.len > 0 {
			nm.show_warning(st.load_msg)
		}
		sync_avail(mut st)
		// Сосед в ленте - заранее, в фоне (prefetch.v)
		prefetch_next(mut st)
	}
	st.pf_done = fn [mut st] (r PfResult) {
		prefetch_take(mut st, r)
	}
	return open_file
}

// build_layout - раскладка окна: область снимка (холст, «до» бок о бок,
// заглушка, индикатор загрузки, перетаскивание файлов), просмотр с
// лентой (вертикальный сплиттер), просмотр | панель (горизонтальный),
// корень с меню; уведомления поверх; окно - в приложение
fn build_layout(mut st State, mut app vgui.App, mut win vgui.Window, mut cv vgui.Canvas, mut placeholder vgui.Stack, ph &Placeholder, theme vgui.Theme, mut nm vgui.NotificationManager, mut bar vgui.MenuBar, ui_k f32, open_file fn (string), open_folder fn (string)) {
	// Область снимка: фон, выбранный в меню «Вид», картинка с отступом от
	// краёв. Холст и заглушка лежат друг на друге в Stack, видим один.
	// Холст - в ряду: «бок о бок» добавляет слева холст «до» (set_ba_sbs)
	mut cmp_row := vgui.create_hbox_fill()
	cmp_row.set_spacing(sbs_gap)
	cmp_row.add(cv, flex: 1)
	st.cmp_row = cmp_row
	mut view_stack := &vgui.Stack{}
	view_stack.add(cmp_row)
	view_stack.add(placeholder)
	mut load_ov := make_load_overlay(theme)
	st.load_ov = load_ov
	view_stack.add(load_ov.stack)
	mut view_area := vgui.create_vbox_fill()
	view_area.set_padding(view_pad)
	view_area.set_bg(ph.edge) // выбранный фон - когда виден снимок (sync_view_bg)
	view_area.add(view_stack, flex: 1)
	st.view_area = view_area
	st.view_stack = view_stack
	// Перетаскивание из файлового менеджера в область снимка (vgui/dnd.v):
	// цель - вся область (и заглушка, и открытый кадр). RAW-файл
	// открывается как из меню, папка - как «Открыть папку». Брошено
	// несколько файлов - SDL присылает их по одному, открытым остаётся
	// последний RAW. Прочие файлы - предупреждение, а не ошибка LibRaw.
	vgui.set_drop_target(mut view_area, [vgui.dnd_kind_files], fn [open_file, open_folder, mut nm] (info vgui.DropInfo) {
		path := info.data.text
		if os.is_dir(path) {
			open_folder(path)
		} else if is_raw_file(path) {
			open_file(path)
		} else {
			nm.show_warning(i18n.trf('Не RAW-файл: {0}', os.file_name(path)))
		}
	})
	// Область просмотра - снимок и под ним лента кадров папки
	// (layout_strip, когда открыт файл или папка)
	mut viewer := vgui.create_vbox_fill()
	viewer.add(view_area, flex: 1)
	st.viewer = viewer
	// Высота ленты - вертикальным сплиттером; после перетаскивания ячейки
	// подстраиваются под новую высоту
	mut vsplit := vgui.splitter_vertical()
	vsplit.bar_size = 3
	// Мин. высоты и порядок половин - layout_strip (лента снизу или сверху)
	// (при масштабе интерфейса - той же логической высоты, uiscale.v)
	vsplit.ratio = scaled_strip_ratio(strip_start_ratio(st.settings.strip_top), st.settings.strip_top,
		ui_k)
	vsplit.on_resize = fn [mut st] (r f32) {
		fit_strip_items(mut st)
	}
	st.vsplit = vsplit
	// Панель ленты: полоса и лента на тёмном фоне с полями
	mut strip_box := vgui.create_vbox_fill()
	strip_box.set_spacing(4)
	strip_box.set_padding(strip_box_pad)
	st.strip_box = strip_box

	// Просмотр | панель инструментов - горизонтальный сплиттер: ширину
	// панели можно менять (по умолчанию 440 при ширине окна 1280); панель
	// справа или слева, или скрыта - layout_work (panel.v)
	mut top := vgui.splitter_horizontal()
	top.bar_size = 3
	// Ширину панели перетащили - запомнить в пикселях (при изменении окна
	// она держится - Splitter.keep); текущий кадр ленты снова по центру
	top.on_resize = fn [mut st] (r f32) {
		panel_dragged(mut st)
		center_strip(mut st)
	}
	st.hsplit = top

	// Корень: меню вверху, под ним рабочая область
	mut root := vgui.create_vbox_fill()
	st.root = root
	st.menu = bar
	st.win = win
	update_title(mut st)
	// Сочетания меню - и в полноэкранном режиме, где полоса скрыта
	bar.keys_when_hidden = true
	layout_work(mut st)
	win.add_widget(root)
	// Менеджер уведомлений - после корневого контейнера: рисуется поверх
	// всего окна, события получает первым (Window обходит виджеты с конца).
	// Свои цвета vraw по палитре темы (фоны панелей, разделители, подписи)
	paint_ui(mut st, theme)
	win.add_widget(nm)
	// Удержание «\» - до/после (compare.v)
	bind_ba_hold(mut win, mut st)
	app.add_window(win)
}

// shutdown_app - после закрытия окна: дождаться сохранений (пакет -
// отменить), закрыть LibRaw, дождаться фоновых потоков, освободить базу
// lensfun (ею пользуются потоки - последней)
fn shutdown_app(mut st State) {
	// Не обрывать записывающийся файл, если окно закрыли во время сохранения.
	// Пакет отменяется: без окна он работал бы невидимо до последнего
	// кадра; отмена - между этапами, начатая запись файла дописывается
	// (одиночный экспорт - дожидается целиком)
	if !isnil(st.exp) && st.exp.n > 1 {
		mut c := st.exp
		c.cancel.set()
	}
	wait_all(mut st.save_threads)
	if !isnil(st.dev) {
		st.dev.close()
	}
	wait_prep(mut st) // воркер пользуется профилем из st.lens_db
	wait_details(mut st) // и фрагмент 1:1 - тоже
	wait_ba(mut st) // и сырьё «до»
	wait_pair(mut st) // и левый кадр сравнения
	wait_thumbs(mut st)
	wait_loads(mut st)
	// Потоки сохранения уже дождались выше (wait_all); база lensfun,
	// которой они пользуются, освобождается только после них
	if !isnil(st.lens_db) {
		st.lens_db.free()
	}
}
