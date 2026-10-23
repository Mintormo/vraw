module main

// Доступность пунктов меню и панели (avail.v) без окна: виджеты vgui
// создаются и работают без App
import vgui

fn avail_menu(mut st State) (&vgui.MenuItem, &vgui.MenuItem, &vgui.MenuItem, &vgui.MenuItem) {
	mut fr := vgui.menu_action('Сбросить тон')
	mut px := vgui.menu_action('Автотон')
	mut ex := vgui.menu_action('Экспорт...')
	mut un := vgui.menu_action('Отменить')
	avail_add(mut st, .frame, [fr])
	avail_add(mut st, .pixels, [px])
	avail_add(mut st, .export, [ex])
	avail_add(mut st, .undo, [un])
	return fr, px, ex, un
}

fn test_menu_without_frame() {
	mut st := &State{}
	fr, px, ex, un := avail_menu(mut st)
	sync_avail(mut st)
	assert !fr.enabled && !px.enabled && !ex.enabled && !un.enabled
}

fn test_menu_while_loading() {
	mut st := &State{}
	fr, px, ex, un := avail_menu(mut st)
	st.raw_path = '/x/IMG_0001.CR3'
	st.loading = true
	start_history(mut st)
	sync_avail(mut st)
	// Пока кадр грузится, правки уже пишутся; превью ещё нет
	assert fr.enabled && ex.enabled
	assert !px.enabled
	assert !un.enabled // одна запись «Открыт файл» - отменять нечего
	st.history << HistEntry{
		name: 'Экспозиция'
	}
	st.hist_pos = 1
	sync_avail(mut st)
	assert un.enabled
	// Загрузка не удалась: кадра нет, правки недоступны
	st.loading = false
	sync_avail(mut st)
	assert !fr.enabled && !un.enabled
}

fn test_panel_lock() {
	mut st := &State{}
	mut sl := vgui.slider_horizontal(0, 1, 0)
	mut b := vgui.button('Автотон')
	mut cb := vgui.checkbox('Коррекция объектива')
	cb.enabled = false // профиля объектива нет (свой sync)
	mut row := vgui.create_hbox_fill()
	row.add(sl)
	row.add(b)
	mut sec := vgui.create_vbox_fill()
	sec.add(row)
	sec.add(cb)
	st.sec_w = [&vgui.Widget(sec)]
	sync_avail(mut st)
	// Гасится корень раздела, собственные флаги детей не трогаются
	assert !st.panel_live
	assert !vgui.widget_enabled(st.sec_w[0])
	assert sl.enabled && b.enabled && !cb.enabled
	st.raw_path = '/x/IMG_0001.CR3'
	st.loading = true
	sync_avail(mut st)
	assert st.panel_live
	assert vgui.widget_enabled(st.sec_w[0])
	// Флажок коррекции остался таким, каким его сделал свой sync
	assert sl.enabled && b.enabled && !cb.enabled
}

fn test_panel_lock_before_panel() {
	// Меню пресетов строится раньше панели: блокировка - при первом
	// sync_avail, когда разделы уже есть
	mut st := &State{}
	sync_avail(mut st)
	assert st.panel_live
	mut sl := vgui.slider_horizontal(0, 1, 0)
	st.sec_w = [&vgui.Widget(sl)]
	sync_avail(mut st)
	assert !st.panel_live && !sl.enabled
	st.raw_path = '/x/IMG_0001.CR3'
	st.loading = true
	sync_avail(mut st)
	assert st.panel_live && sl.enabled
}
