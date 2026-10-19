module main

// Темы оформления: все темы vgui, выбор в меню «Вид - Тема», запоминается
// в настройках (settings.v). Смена - на лету: app.set_theme перекрашивает
// виджеты vgui, а свои цвета vraw (фоны панелей, разделители, серые
// подписи, ленту, историю, заглушку) пересчитывает apply_theme из
// палитры Palette, выведенной из темы.
//
// Гистограмма - в цветах темы (фон, столбцы каналов, треугольники
// клипа), перерисовывается при смене. Не зависят от темы: холст превью
// (это данные снимка), фон вокруг снимка (выбирается отдельно - «Фон
// вокруг снимка»).
import vgui

const theme_keys = ['dark', 'light', 'monokai', 'win10', 'win10_dark', 'win11', 'win11_dark',
	'breeze', 'breeze_dark', 'adwaita', 'adwaita_dark', 'macos', 'macos_dark', 'mac_aqua',
	'mac_platinum']
const theme_names = ['Тёмная', 'Светлая', 'Monokai', 'Windows 10', 'Windows 10 тёмная',
	'Windows 11', 'Windows 11 тёмная', 'KDE Breeze', 'KDE Breeze тёмная', 'GNOME Adwaita',
	'GNOME Adwaita тёмная', 'macOS', 'macOS тёмная', 'Mac OS X Aqua', 'Mac OS 9 Platinum']

fn theme_index(key string) int {
	i := theme_keys.index(key)
	return if i < 0 { 0 } else { i }
}

fn theme_by_key(key string) vgui.Theme {
	return match key {
		'light' { vgui.light_theme() }
		'monokai' { vgui.monokai_theme() }
		'win10' { vgui.win10_theme() }
		'win10_dark' { vgui.win10_dark_theme() }
		'win11' { vgui.win11_theme() }
		'win11_dark' { vgui.win11_dark_theme() }
		'breeze' { vgui.kde_breeze_theme() }
		'breeze_dark' { vgui.kde_breeze_dark_theme() }
		'adwaita' { vgui.gtk_adwaita_theme() }
		'adwaita_dark' { vgui.gtk_adwaita_dark_theme() }
		'macos' { vgui.macos_theme() }
		'macos_dark' { vgui.macos_dark_theme() }
		'mac_aqua' { vgui.mac_os_x_aqua_theme() }
		'mac_platinum' { vgui.mac_os_9_platinum_theme() }
		else { vgui.dark_theme() }
	}
}

// Palette - цвета vraw, выведенные из темы
struct Palette {
	dark      bool       // тёмная тема (по яркости фона)
	viewer    vgui.Color // фон области просмотра и панели ленты - темнее фона темы
	panel     vgui.Color // фон правой панели
	divider   vgui.Color // полосы сплиттеров
	text      vgui.Color // текущее/важное (текущий кадр, текущая запись истории)
	secondary vgui.Color // обычные подписи (имена кадров, записи истории, профиль)
	hint      vgui.Color // подсказки
	disabled  vgui.Color // отменённые записи истории
	// Гистограмма: цвет по маске каналов, чей столбец накрывает пиксель
	// (бит 0 - R, 1 - G, 2 - B): [0] - фон, [7] - все три
	hist      [8]vgui.Color
	clip_idle vgui.Color // треугольник клипа, когда клипа нет
	clip_ring vgui.Color // обводка треугольника при включённом показе
}

fn make_palette(th vgui.Theme) Palette {
	lum := (int(th.bg.r) * 54 + int(th.bg.g) * 183 + int(th.bg.b) * 19) >> 8
	dark := lum < 128
	return Palette{
		dark:      dark
		viewer:    if dark { th.bg.darken(0.25) } else { th.bg.darken(0.06) }
		panel:     th.panel_bg
		divider:   th.border
		text:      th.text_primary
		secondary: th.text_secondary
		hint:      th.text_hint
		disabled:  th.text_disabled
		hist:      hist_colors(th, dark)
		clip_idle: if dark { vgui.Color{95, 95, 100, 255} } else { vgui.Color{190, 190, 195, 255} }
		clip_ring: if dark { vgui.Color{255, 255, 255, 255} } else { th.text_primary }
	}
}

// hist_colors - цвета гистограммы под тему. В тёмной - сложение на
// почти чёрном фоне: канал столбца светлый, иначе канал фона (все три -
// почти белый). В светлой сложение не работает (белое на белом) -
// готовые цвета на фоне полей ввода: каналы, их смеси, все три - серый.
fn hist_colors(th vgui.Theme, dark bool) [8]vgui.Color {
	if dark {
		bg := th.bg.darken(0.055)
		mut c := [8]vgui.Color{}
		for m in 0 .. 8 {
			c[m] = vgui.Color{
				r: if m & 1 != 0 { u8(224) } else { bg.r }
				g: if m & 2 != 0 { u8(214) } else { bg.g }
				b: if m & 4 != 0 { u8(234) } else { bg.b }
				a: 255
			}
		}
		return c
	}
	return [th.input_bg, vgui.Color{220, 70, 70, 255}, vgui.Color{70, 170, 80, 255},
		vgui.Color{215, 180, 50, 255}, vgui.Color{70, 110, 225, 255},
		vgui.Color{185, 85, 200, 255}, vgui.Color{50, 170, 185, 255},
		vgui.Color{125, 125, 130, 255}]!
}

// hue - насыщенный цвет подписи (HSL, каналы кривых) под тему: в светлой
// затемняется, иначе жёлтый/голубой на светлом фоне не читается
fn (p Palette) hue(c vgui.Color) vgui.Color {
	return if p.dark { c } else { c.darken(0.35) }
}

// apply_theme - сменить тему на лету: тема vgui всем окнам, свои цвета
// vraw из палитры, отметка в меню, запомнить в настройках
fn apply_theme(mut st State, mut app vgui.App, idx int) {
	key := theme_keys[idx]
	th := theme_by_key(key)
	app.set_theme(th)
	st.pal = make_palette(th)
	for j in 0 .. st.m_theme.len {
		mut m := st.m_theme[j]
		m.checked = j == idx
	}
	paint_ui(mut st, th)
	st.settings.theme = key
	save_settings(st.settings)
	// Окно настроек - со своей темой (задана при создании): перекрасить
	if !isnil(st.sui) {
		mut d := st.sui.dlg
		d.set_theme(th)
		paint_settings(mut st)
		sync_settings_ui(mut st)
	}
	if !isnil(st.eui) {
		mut d := st.eui.dlg
		d.set_theme(th)
		paint_export(mut st)
	}
	if !isnil(st.xs) {
		mut d := st.xs.dlg
		d.set_theme(th)
		paint_export_setup(mut st)
	}
	if !isnil(st.groups_ui) {
		mut d := st.groups_ui.dlg
		d.set_theme(th)
	}
	if !isnil(st.presets_ui) {
		mut d := st.presets_ui.dlg
		d.set_theme(th)
	}
}

// paint_ui - свои цвета vraw по текущей палитре (при старте и смене темы)
fn paint_ui(mut st State, th vgui.Theme) {
	p := st.pal
	if !isnil(st.right) {
		mut r := st.right
		r.set_bg(p.panel)
	}
	if !isnil(st.viewer) {
		mut v := st.viewer
		v.set_bg(p.viewer)
	}
	if !isnil(st.strip_box) {
		mut sb := st.strip_box
		sb.set_bg(p.viewer)
	}
	if !isnil(st.hsplit) {
		mut s := st.hsplit
		s.bar_color = p.divider
	}
	if !isnil(st.vsplit) {
		mut s := st.vsplit
		s.bar_color = p.divider
	}
	for i in 0 .. st.hint_labels.len {
		st.hint_labels[i].color = p.hint
	}
	for i in 0 .. st.secondary_labels.len {
		st.secondary_labels[i].color = p.secondary
	}
	for i in 0 .. st.hsl_labels.len {
		st.hsl_labels[i].color = p.hue(hsl_label_colors[i % hsl_label_colors.len])
	}
	if !isnil(st.holder) {
		mut ph := st.holder
		paint_placeholder(mut ph, th)
	}
	if !isnil(st.load_ov) {
		mut ov := st.load_ov
		paint_load_overlay(mut ov, th)
	}
	sync_view_bg(mut st)
	sync_strip(mut st)
	refresh_history(mut st)
	sync_curve_editor(mut st)
	repaint_histogram(mut st)
}
