module main

import vgui

// reveal_state - лента из кадров paths, все строки видны (фильтр «все»)
fn reveal_state(paths []string) &State {
	mut st := &State{}
	mut strip := vgui.list_box_h(100)
	strip.multi_select = true
	for p in paths {
		st.frames << Frame{
			path: p
		}
		strip.add_item_widget(vgui.label(p))
	}
	st.shown = []int{len: paths.len, init: index}
	st.strip = strip
	st.frame_idx = -1
	return st
}

// Что показать в файловом менеджере: кадр под выделением и выделенные из
// его папки; без выделения - открытый
fn test_reveal_paths() {
	mut st := reveal_state(['/f/a.CR3', '/f/b.CR3', '/f/s/c.CR3', '/f/d.CR3'])
	assert reveal_paths(st) == []string{} // ничего не открыто и не выделено
	st.raw_path = '/gone/x.CR3' // открыт, но не в ленте
	assert reveal_paths(st) == ['/gone/x.CR3']
	st.frame_idx = 1
	assert reveal_paths(st) == ['/f/b.CR3']
	mut strip := st.strip
	strip.set_selection([0, 2, 3]) // текущая - последняя
	assert reveal_paths(st) == ['/f/d.CR3', '/f/a.CR3']
	strip.set_selection([3, 0, 2]) // текущая - в подпапке
	assert reveal_paths(st) == ['/f/s/c.CR3']
}
