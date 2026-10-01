module main

import os

// Итог пакета: все сохранены, ошибки (первая и счётчик), отмена
fn test_batch_outcome() {
	r1, m1 := batch_outcome(12, 12, []string{}, false, .jpeg, 185)
	assert r1 == .saved && m1 == 'Экспорт: сохранено 12 из 12 кадров - JPEG, 3 мин 05 с'
	r2, m2 := batch_outcome(3, 1, ['A.CR3: x', 'B.CR3: y'], false, .png, 5)
	assert r2 == .failed && m2.contains('сохранено 1 из 3 кадров') && m2.contains('A.CR3: x')
		&& m2.contains('и ещё 1')
	r3, m3 := batch_outcome(1, 0, []string{}, true, .tiff, 1)
	assert r3 == .cancelled && m3 == 'Экспорт отменён: сохранено 0 из 1 кадра'
}

// Кадры пакета: открытый - настройки окна (с производными полями),
// остальные - из сайдкара (нет сайдкара - нейтральные), испорченный
// сайдкар - в списке плохих
fn test_batch_items() {
	dir := os.join_path(os.temp_dir(), 'vraw_batch_items_test')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir)!
	a := os.join_path(dir, 'A.CR3')
	b := os.join_path(dir, 'B.CR3')
	c := os.join_path(dir, 'C.CR3')
	d := os.join_path(dir, 'D.CR3')
	mut eb := neutral_edit()
	eb.params.exposure = 1.5
	write_atomic(sidecar_path(b), encode_history([HistEntry{
		name:  'Открыт файл'
		state: neutral_edit()
	}, HistEntry{
		name:  'Экспозиция'
		state: eb
	}], 1))!
	os.write_file(sidecar_path(d), 'не json')!
	mut st := &State{}
	st.edit = neutral_edit()
	st.edit.params.exposure = -0.5
	st.history = [HistEntry{
		name:  'Открыт файл'
		state: st.edit
	}]
	st.side_path = sidecar_path(a)
	items, bad := batch_items(st, [a, b, c, d])
	assert items.len == 4
	assert items[0].derived && items[0].edit.params.exposure == -0.5
	assert !items[1].derived && items[1].edit.params.exposure == 1.5
	assert !items[2].derived && items[2].edit.params.exposure == 0
	assert bad == ['D.CR3'] && items[3].edit.params.exposure == 0
	os.rmdir_all(dir) or {}
}

// Производные поля неоткрытого кадра по тестовому CR3: цвет камеры и
// камерная кривая; кривая выключена - пустая
fn test_batch_derive() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		return
	}
	e := neutral_edit()
	d := batch_derive(path, e, unsafe { nil })!
	assert e.use_curve && d.params.curve.len > 0
	mut off := neutral_edit()
	off.use_curve = false
	d2 := batch_derive(path, off, unsafe { nil })!
	assert d2.params.curve.len == 0
}
