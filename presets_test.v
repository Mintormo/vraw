module main

// Копирование настроек и пресеты (presets.v): слияние групп, вставка в
// сайдкар неоткрытого кадра и в открытый кадр, файлы пресетов.
import os
import vgui

fn preset_tmp_dir(name string) string {
	dir := os.join_path(os.temp_dir(), 'vraw_presets_test', name)
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or {}
	return dir
}

// Настройки-источник: каждая группа отличается от нейтральной
fn sample_edit() EditState {
	mut e := neutral_edit()
	e.params.exposure = 1.5
	e.params.eq[2] = 0.5
	e.use_curve = false
	e.wb_mode = 'cloudy'
	e.wb_temp = 6500
	e.wb_tint = 10
	e.params.vibrance = 30
	e.curve_pts[1] = [vgui.CurvePoint{0, 0}, vgui.CurvePoint{0.5, 0.6},
		vgui.CurvePoint{1, 1}]
	e.params.hsl_sat[3] = -40
	e.nr[1] = 25
	e.ai = 80
	e.ai_model = 'scunet'
	e.params.sharp.amount = 60
	e.params.haze = 20
	e.lens_corr = false
	return e
}

fn test_merge_groups() {
	src := sample_edit()
	dst := neutral_edit()
	// Только тон: экспозиция, эквалайзер, камерная кривая
	t := merge_groups(dst, src, ['tone'])
	assert t.params.exposure == 1.5 && t.params.eq[2] == 0.5
	assert !t.use_curve
	assert t.wb_mode == '' && t.params.vibrance == 0 && t.curve_pts == dst.curve_pts
	assert t.nr == dst.nr && t.lens_corr
	// Цвет, кривые, HSL
	c := merge_groups(dst, src, ['color', 'curves', 'hsl'])
	assert c.wb_mode == 'cloudy' && c.wb_temp == 6500 && c.params.vibrance == 30
	assert c.curve_pts == src.curve_pts && c.params.hsl_sat[3] == -40
	assert c.params.exposure == 0
	// Все группы - все исходные настройки источника
	all := merge_groups(dst, src, copy_groups)
	assert side_state(all) == side_state(src)
	// Кривые скопированы, а не разделены с источником
	mut s2 := src.clone()
	m := merge_groups(dst, s2, ['curves'])
	s2.curve_pts[1][1] = vgui.CurvePoint{0.5, 0.9}
	assert m.curve_pts[1][1].y == f32(0.6)
	// Неизвестная группа ничего не делает
	assert side_state(merge_groups(dst, src, ['nope'])) == side_state(dst)
}

fn test_paste_to_file_new_and_existing() {
	dir := preset_tmp_dir('paste')
	raw_path := os.join_path(dir, 'IMG_1.CR3')
	src := sample_edit()
	// Нет сайдкара: «Открыт файл» (нейтральные) + вставка
	assert paste_to_file(raw_path, src, ['tone'], 'Вставка настроек')!
	l := load_sidecar(sidecar_path(raw_path))!
	assert l.history.map(it.name) == ['Открыт файл', 'Вставка настроек']
	assert l.current == 1
	assert l.history[1].state.params.exposure == 1.5
	assert side_state(l.history[0].state) == side_state(neutral_edit())
	// Те же настройки ещё раз - записывать нечего
	assert !paste_to_file(raw_path, src, ['tone'], 'Вставка настроек')!
	// Вторая группа - новая запись; отменённое «будущее» отрезается
	text := encode_history(l.history, 0, Mark{}) // откат к «Открыт файл»
	os.write_file(sidecar_path(raw_path), text)!
	assert paste_to_file(raw_path, src, ['color'], 'Пресет: Облачно')!
	l2 := load_sidecar(sidecar_path(raw_path))!
	assert l2.history.map(it.name) == ['Открыт файл', 'Пресет: Облачно']
	assert l2.history[1].state.wb_mode == 'cloudy'
	assert l2.history[1].state.params.exposure == 0
}

fn test_paste_to_file_broken_sidecar() {
	dir := preset_tmp_dir('broken')
	raw_path := os.join_path(dir, 'IMG_2.CR3')
	os.write_file(sidecar_path(raw_path), '{испорчен')!
	paste_to_file(raw_path, sample_edit(), ['tone'], 'Вставка настроек') or {
		assert err.msg().contains('сайдкар')
		// Испорченный файл не перезаписан
		assert os.read_file(sidecar_path(raw_path))! == '{испорчен'
		return
	}
	assert false
}

// Вставка в открытый кадр - обычная правка: запись в истории и сайдкаре
fn test_paste_settings_current() {
	dir := preset_tmp_dir('current')
	mut st := &State{}
	st.edit = neutral_edit()
	st.side_path = sidecar_path(os.join_path(dir, 'IMG_3.CR3'))
	start_history(mut st)
	mut cv := vgui.canvas(4, 3)
	mut hist := vgui.canvas(4, 3)
	mut nm := vgui.notification_manager_at(.top_left)
	mut app := &vgui.App{}
	paste_settings(mut st, sample_edit(), ['tone', 'sharp'], 'Вставка настроек', mut cv, mut
		hist, mut nm, mut app)
	assert st.history.map(it.name) == ['Открыт файл', 'Вставка настроек']
	assert st.edit.params.exposure == 1.5 && st.edit.params.sharp.amount == 60
	assert st.edit.wb_mode == ''
	assert os.exists(st.side_path)
	// Повтор - без новой записи
	paste_settings(mut st, sample_edit(), ['tone', 'sharp'], 'Вставка настроек', mut cv, mut
		hist, mut nm, mut app)
	assert st.history.len == 2
}

fn test_presets_files() {
	dir := preset_tmp_dir('files')
	assert preset_file_name('  Пейзаж: вечер/2 ') == 'Пейзаж_ вечер_2.json'
	assert preset_file_name(' .. ') == ''
	path := save_preset(dir, 'Пейзаж', sample_edit(), ['hsl', 'color', 'bogus'])!
	assert os.file_name(path) == 'Пейзаж.json'
	save_preset(dir, 'авто', neutral_edit(), ['tone'])!
	os.write_file(os.join_path(dir, 'readme.txt'), 'не пресет')!
	ps := list_presets(dir)
	assert ps.map(it.name) == ['авто', 'Пейзаж']
	e, groups := load_preset(path)!
	assert groups == ['color', 'hsl'] // порядок copy_groups, чужие отброшены
	assert e.params.hsl_sat[3] == -40 && e.wb_mode == 'cloudy'
	// Чужой JSON - ошибка
	bad := os.join_path(dir, 'bad.json')
	os.write_file(bad, '{"app": "other"}')!
	load_preset(bad) or {
		assert err.msg().contains('не пресет')
		return
	}
	assert false
}

fn test_plural() {
	assert plural(1, 'кадр', 'кадра', 'кадров') == 'кадр'
	assert plural(3, 'кадр', 'кадра', 'кадров') == 'кадра'
	assert plural(11, 'кадр', 'кадра', 'кадров') == 'кадров'
	assert plural(22, 'кадр', 'кадра', 'кадров') == 'кадра'
	assert groups_text(8) == '8 групп из 10'
}

// Импорт и экспорт: чужой файл отвергается, одноимённый пресет с другими
// настройками не затирается (номер в имени), повтор того же - без копии
fn test_presets_import_export() {
	src_dir := preset_tmp_dir('io_src')
	lib := preset_tmp_dir('io_lib')
	out := preset_tmp_dir('io_out')
	a := save_preset(src_dir, 'Пейзаж', sample_edit(), ['tone', 'hsl'])!
	// Импорт в пустую библиотеку - имя из файла
	assert import_preset(a, lib)! == 'Пейзаж'
	e, groups := load_preset(os.join_path(lib, 'Пейзаж.json'))!
	assert groups == ['tone', 'hsl'] && e.params.exposure == 1.5
	// Тот же файл ещё раз - тот же пресет, без копии
	assert import_preset(a, lib)! == 'Пейзаж'
	assert list_presets(lib).len == 1
	// Другой пресет с тем же именем - «Пейзаж (2)»
	b := save_preset(out, 'Пейзаж', neutral_edit(), ['tone'])!
	assert import_preset(b, lib)! == 'Пейзаж (2)'
	assert list_presets(lib).map(it.name) == ['Пейзаж', 'Пейзаж (2)']
	_, g2 := load_preset(os.join_path(lib, 'Пейзаж (2).json'))!
	assert g2 == ['tone']
	// Чужой JSON не импортируется
	bad := os.join_path(src_dir, 'bad.json')
	os.write_file(bad, '{"app": "other"}')!
	if _ := import_preset(bad, lib) {
		assert false
	}
	assert list_presets(lib).len == 2
	// Экспорт всех: копии как есть; повтор не плодит файлов
	os.rm(b)!
	assert export_presets(list_presets(lib), out)! == 2
	assert os.read_file(os.join_path(out, 'Пейзаж.json'))! == os.read_file(os.join_path(lib,
		'Пейзаж.json'))!
	export_presets(list_presets(lib), out)!
	assert os.ls(out)!.len == 2
	// Экспорт одного
	dst := os.join_path(out, 'один.json')
	export_preset(list_presets(lib)[0], dst)!
	_, g3 := load_preset(dst)!
	assert g3 == ['tone', 'hsl']
	// Удаление: файл пропадает из списка, остальные на месте
	delete_preset(list_presets(lib)[0])!
	assert list_presets(lib).map(it.name) == ['Пейзаж (2)']
	if _ := delete_preset(Preset{ name: 'нет', path: os.join_path(lib, 'нет.json') }) {
		assert false
	}
}
