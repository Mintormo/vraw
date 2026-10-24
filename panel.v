module main

// Раскладка окна по настройкам (settings.v, окно «Настройки - Интерфейс»,
// меню «Вид»): какие разделы правой панели видны и в каком порядке,
// с какой стороны панель инструментов, где лента кадров (снизу или
// сверху), видны ли панель и лента.
// Разделы - секции аккордеона: виджеты создаются один раз в main
// (panel_add), раскладка пересобирает только список секций (layout_panel).
// Скрытый раздел только не показан - его настройки кадра действуют.
import vgui
import i18n

// PanelSection - раздел панели: ключ в настройках, заголовок. При запуске
// все разделы свёрнуты (раскрытость не запоминается).
struct PanelSection {
	key   string
	title string
}

// panel_sections - все разделы в порядке по умолчанию. Новый раздел -
// сюда: в старых настройках его нет, panel_order_from поставит его на
// место по умолчанию.
const panel_sections = [
	PanelSection{'lens', 'Коррекция'},
	PanelSection{'crop', 'Кадрирование и поворот'},
	PanelSection{'spots', 'Удаление пятен'},
	PanelSection{'wb', 'Баланс белого'},
	PanelSection{'tone', 'Экспозиция и тон'},
	PanelSection{'haze', 'Удаление дымки'},
	PanelSection{'shadows', 'Тени/Света'},
	PanelSection{'eq', 'Тон-эквалайзер (EV)'},
	PanelSection{'curves', 'Кривые'},
	PanelSection{'hsl', 'HSL'},
	PanelSection{'bw', 'Чёрно-белое'},
	PanelSection{'grade', 'Цветокоррекция'},
	PanelSection{'masks', 'Градиентные фильтры'},
	PanelSection{'nr', 'Шумодав и ореолы'},
	PanelSection{'sharp', 'Резкость'},
	PanelSection{'fx', 'Эффекты'},
	PanelSection{'history', 'История'},
]

const panel_side_names = ['Справа', 'Слева']
const strip_side_names = ['Снизу', 'Сверху']

// Поля вокруг снимка (в полноэкранном режиме - без полей)
const view_pad = f32(16)

// Мин. высота снимка в сплиттере «снимок | лента»
const view_min_h = f32(200)

// Ширина панели по умолчанию (перетащенная - в настройке panel_w); мин.
// ширины панели и просмотра
const panel_start_w = f32(440)
const panel_min_w = f32(360)
const viewer_min_w = f32(400)

fn panel_section_index(key string) int {
	for i, s in panel_sections {
		if s.key == key {
			return i
		}
	}
	return -1
}

fn panel_default_order() []string {
	return panel_sections.map(it.key)
}

// panel_order_from - порядок из настроек: известные ключи без повторов,
// недостающие (новые разделы) - на место по умолчанию: после того
// раздела, что стоит перед ними в порядке по умолчанию
fn panel_order_from(saved []string) []string {
	mut out := []string{}
	for k in saved {
		if panel_section_index(k) >= 0 && k !in out {
			out << k
		}
	}
	for i, s in panel_sections {
		if s.key in out {
			continue
		}
		// Вставить за ближайшим предшественником по умолчанию
		mut pos := 0
		for j := i - 1; j >= 0; j-- {
			p := out.index(panel_sections[j].key)
			if p >= 0 {
				pos = p + 1
				break
			}
		}
		out.insert(pos, s.key)
	}
	return out
}

// panel_keys_from - список разделов из настроек (скрытые, раскрытые):
// только известные, без повторов
fn panel_keys_from(saved []string) []string {
	mut out := []string{}
	for k in saved {
		if panel_section_index(k) >= 0 && k !in out {
			out << k
		}
	}
	return out
}

// panel_shown - видимые разделы по порядку
fn panel_shown(order []string, hidden []string) []string {
	return order.filter(it !in hidden)
}

// panel_move - порядок, где раздел key сдвинут на delta позиций (у края -
// без изменений)
fn panel_move(order []string, key string, delta int) []string {
	mut out := order.clone()
	i := out.index(key)
	j := i + delta
	if i < 0 || j < 0 || j >= out.len {
		return out
	}
	out[i] = out[j]
	out[j] = key
	return out
}

// panel_add - раздел панели (виджет секции) по ключу; показ - layout_panel
fn panel_add(mut st State, key string, w &vgui.Widget) {
	i := panel_section_index(key)
	if i < 0 {
		return
	}
	if st.sec_w.len == 0 {
		st.sec_w = []&vgui.Widget{len: panel_sections.len, init: unsafe { nil }}
		st.sec_open = []bool{len: panel_sections.len}
	}
	st.sec_w[i] = unsafe { w }
}

// layout_panel пересобирает секции аккордеона по настройкам: порядок,
// скрытые. Раскрытость видимых разделов сохраняется (скрытый, снова
// показанный, - какой был).
fn layout_panel(mut st State) {
	if isnil(st.acc) || st.sec_w.len == 0 {
		return
	}
	mut acc := st.acc
	for i, key in st.panel_keys {
		k := panel_section_index(key)
		if k >= 0 {
			st.sec_open[k] = acc.is_expanded(i)
		}
	}
	acc.sections.clear()
	st.panel_keys = panel_shown(panel_order_from(st.settings.panel_order), st.settings.panel_hidden)
	for key in st.panel_keys {
		k := panel_section_index(key)
		if st.sec_open[k] {
			acc.add_section_expanded(i18n.tr(panel_sections[k].title), st.sec_w[k])
		} else {
			acc.add_section(i18n.tr(panel_sections[k].title), st.sec_w[k])
		}
	}
	// Градиентные фильтры: раскрытая секция показывает метки на снимке
	if !isnil(st.mask_ui) {
		mut mu := st.mask_ui
		mu.acc = acc
		mu.acc_idx = st.panel_keys.index('masks')
		mask_redraw(st)
	}
}

// layout_work собирает рабочую область под меню: просмотр и панель
// инструментов (справа или слева) в сплиттере, без панели - один
// просмотр. Пересборка корня через clear + add (VBox.remove в vgui не
// работает).
fn layout_work(mut st State) {
	if isnil(st.root) || isnil(st.hsplit) || isnil(st.menu) || isnil(st.right)
		|| isnil(st.viewer) {
		return
	}
	mut root := st.root
	mut sp := st.hsplit
	root.clear()
	root.add(st.menu)
	sp.clear_first()
	sp.clear_second()
	if !panel_on(st) {
		root.add(st.viewer, flex: 1)
	} else {
		// Панель держит ширину в пикселях (Splitter.keep): при изменении окна
		// растёт или сжимается только просмотр; узкое окно ужимает панель до
		// min, настройка при этом не меняется
		if st.settings.panel_left {
			sp.min_first = panel_min_w
			sp.min_second = viewer_min_w
			sp.set_first(st.right)
			sp.set_second(st.viewer)
			sp.set_keep(.first, panel_width(st))
		} else {
			sp.min_first = viewer_min_w
			sp.min_second = panel_min_w
			sp.set_first(st.viewer)
			sp.set_second(st.right)
			sp.set_keep(.second, panel_width(st))
		}
		// Доля - сразу (center_strip ниже её читает), а не на следующей раскладке
		sp.apply_keep()
		root.add(sp, flex: 1)
	}
	if !isnil(st.m_panel) {
		mut m := st.m_panel
		m.checked = panel_on(st)
	}
	if !isnil(st.m_left) {
		mut m := st.m_left
		m.checked = st.settings.panel_left
	}
	center_strip(mut st)
}

// viewer_share - доля просмотра в сплиттере «просмотр | панель»
fn viewer_share(st &State) f32 {
	if !panel_on(st) {
		return 1
	}
	r := st.hsplit.ratio
	return if st.settings.panel_left { 1 - r } else { r }
}

// panel_width - ширина панели инструментов, px: перетащенная (настройка
// panel_w) или по умолчанию
fn panel_width(st &State) f32 {
	return if st.settings.panel_w > 0 { f32(st.settings.panel_w) } else { panel_start_w }
}

// panel_dragged - ширину панели перетащили: запомнить её в пикселях
// (Splitter.keep_size - уже новая ширина)
fn panel_dragged(mut st State) {
	sp := st.hsplit
	if sp.keep_size <= 0 {
		return
	}
	st.settings.panel_w = int(sp.keep_size + 0.5)
	save_settings(st.settings)
}

// panel_on / strip_on - видны ли панель и лента (no_panel/no_strip):
// одинаково в окне и в полноэкранном режиме
fn panel_on(st &State) bool {
	return !st.settings.no_panel
}

fn strip_on(st &State) bool {
	return !st.settings.no_strip
}

// set_panel_visible - показать/скрыть панель инструментов (меню «Вид»,
// F8, окно настроек) - в окне и в полноэкранном режиме разом
fn set_panel_visible(mut st State, v bool) {
	st.settings.no_panel = !v
	save_settings(st.settings)
	layout_work(mut st)
	sync_settings_ui(mut st)
}

// set_panel_left - панель слева или справа; ширина панели сохраняется
fn set_panel_left(mut st State, left bool) {
	if st.settings.panel_left == left {
		return
	}
	st.settings.panel_left = left
	save_settings(st.settings)
	layout_work(mut st) // удерживаемая панель - с другой стороны
	sync_settings_ui(mut st)
}

// strip_share - доля ленты в сплиттере «снимок | лента»
fn strip_share(st &State) f32 {
	r := st.vsplit.ratio
	return if st.settings.strip_top { r } else { 1 - r }
}

// strip_start_ratio - доля первой половины сплиттера ленты при старте:
// высота ленты ~strip_pane_h при высоте окна 946 (минус меню)
fn strip_start_ratio(top bool) f32 {
	sf := strip_pane_h / f32(946 - 28)
	return if top { sf } else { 1 - sf }
}

// set_fullscreen - полноэкранный режим (меню «Вид», F; выход - F, Esc):
// окно SDL на весь экран, полоса меню скрыта (её сочетания клавиш
// работают - keys_when_hidden), снимок без полей. Панель и лента - как в
// окне (no_panel, no_strip): скрытое в окне скрыто и в режиме, F8/F6 в
// режиме меняют их и для окна.
fn set_fullscreen(mut st State, on bool) {
	if isnil(st.win) || isnil(st.menu) || st.fullscreen == on {
		return
	}
	st.fullscreen = on
	mut w := st.win
	w.set_fullscreen(on)
	mut m := st.menu
	m.visible = !on
	if !isnil(st.view_area) {
		mut va := st.view_area
		va.set_padding(if on { 0 } else { view_pad })
	}
	if !isnil(st.m_full) {
		mut mi := st.m_full
		mi.checked = on
	}
	layout_work(mut st)
	layout_strip(mut st)
}

// set_strip_top - лента сверху или снизу; высота ленты сохраняется
fn set_strip_top(mut st State, top bool) {
	if st.settings.strip_top == top {
		return
	}
	st.settings.strip_top = top
	if !isnil(st.vsplit) {
		mut sp := st.vsplit
		sp.ratio = 1 - sp.ratio
	}
	save_settings(st.settings)
	layout_strip(mut st)
	if !isnil(st.m_top) {
		mut m := st.m_top
		m.checked = top
	}
	sync_settings_ui(mut st)
}

// set_strip_visible - показать/скрыть ленту кадров целиком, вместе с
// полосой, - в окне и в полноэкранном режиме разом (как у панели);
// свернуть до полосы - set_strip_open
fn set_strip_visible(mut st State, v bool) {
	st.settings.no_strip = !v
	save_settings(st.settings)
	layout_strip(mut st)
	sync_settings_ui(mut st)
}

// set_panel_sections - новый порядок и скрытые разделы (окно настроек)
fn set_panel_sections(mut st State, order []string, hidden []string) {
	st.settings.panel_order = panel_order_from(order)
	st.settings.panel_hidden = panel_keys_from(hidden)
	save_settings(st.settings)
	layout_panel(mut st)
	sync_settings_ui(mut st)
}
