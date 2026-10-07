module main

import os
import vgui

fn pair_state(paths []string, cur int) State {
	mut st := State{}
	for p in paths {
		st.frames << Frame{
			path: p
		}
	}
	st.shown = []int{len: paths.len, init: index}
	st.frame_idx = cur
	st.strip = vgui.list_box()
	return st
}

// Левый кадр: выделенный в ленте; выделен открытый (или ничего) - соседний
fn test_pair_candidate() {
	mut st := pair_state(['a', 'b', 'c'], 1)
	assert pair_candidate(st) == 'c' // ничего не выделено - следующий
	mut lb := st.strip
	lb.selected = 1
	assert pair_candidate(st) == 'c' // выделен открытый - следующий
	lb.selected = 0
	assert pair_candidate(st) == 'a'
	st.frame_idx = 2
	lb.selected = 2
	assert pair_candidate(st) == 'b' // последний - предыдущий
	// Фильтр ленты: строки - только кадры фильтра
	st.shown = [2]
	assert pair_candidate(st) == '' // сравнивать не с чем
	st2 := pair_state(['a'], 0)
	assert pair_candidate(st2) == ''
}

// Левый кадр - превью-размер (half), как у открытого кадра; отмена -
// пустой результат без ошибки
fn test_pair_render() {
	path := os.join_path(@VMODROOT, 'IMG_0991.CR3')
	if !os.exists(path) {
		eprintln('нет тестового CR3, пропуск')
		return
	}
	mut e := neutral_edit()
	e.lens_corr = false
	e.ai = 50 // AI у левого кадра не считается
	r := pair_render(PairJob{
		gen:  3
		path: path
		edit: e
		stop: &StopFlag{}
	})
	assert r.err == '' && r.gen == 3 && r.path == path
	assert r.w > 2000 && r.w < 4000 // половина полного (6000)
	assert r.rgba.len == r.w * r.h * 4
	assert r.rgba[3] == 255 && r.rgba[r.rgba.len - 1] == 255
	c := pair_render(PairJob{
		path: path
		edit: e
		stop: &StopFlag{
			stop: true
		}
	})
	assert c.err == '' && c.rgba.len == 0
}
