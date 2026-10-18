module main

// Недавние файлы и папки (18.10.2026): подменю «Файл - Недавние файлы» и
// «Недавние папки», новые - сверху; сколько помнить - «Настройки - Общие»
// (recent_counts, по умолчанию recent_default); хранятся в настройках
// (Settings.recent_files, recent_dirs). Открытый файл
// запоминается вместе со своей папкой (лента - это папка). Пропавший с
// диска пункт (отключённая флешка) - неактивен, а не удалён: вернётся,
// когда диск подключат.
import os
import vgui
import i18n

// Сколько помнить: варианты в настройках и по умолчанию (0 в файле)
const recent_counts = [5, 10, 15, 20, 30, 50]
const recent_default = 10

// recent_limit - сколько помнить по полю настроек (0 - по умолчанию)
fn recent_limit(n int) int {
	return if n in recent_counts { n } else { recent_default }
}

// recent_push - p в начало списка, без повтора, не больше max
fn recent_push(list []string, p string, max int) []string {
	mut out := [p]
	for x in list {
		if x != p && out.len < max {
			out << x
		}
	}
	return out
}

// set_recent_limit - новый предел (настройки): лишнее с конца списка уходит
fn set_recent_limit(mut st State, dir bool, n int) {
	if dir {
		st.settings.recent_dirs_n = n
		st.settings.recent_dirs = st.settings.recent_dirs#[..n].clone()
	} else {
		st.settings.recent_files_n = n
		st.settings.recent_files = st.settings.recent_files#[..n].clone()
	}
	save_settings(st.settings)
	rebuild_recent_menus(mut st)
}

// add_recent - открыт файл (dir = false) или папка: запомнить и обновить меню
fn add_recent(mut st State, path string, dir bool) {
	nf := recent_limit(st.settings.recent_files_n)
	nd := recent_limit(st.settings.recent_dirs_n)
	if dir {
		st.settings.recent_dirs = recent_push(st.settings.recent_dirs, path, nd)
	} else {
		st.settings.recent_files = recent_push(st.settings.recent_files, path, nf)
		st.settings.recent_dirs = recent_push(st.settings.recent_dirs, os.dir(path), nd)
	}
	save_settings(st.settings)
	rebuild_recent_menus(mut st)
}

// short_dir - папка для меню: домашняя - «~»
fn short_dir(dir string) string {
	home := os.home_dir()
	if home != '' && (dir == home || dir.starts_with(home + os.path_separator)) {
		return '~' + dir[home.len..]
	}
	return dir
}

// Путь в меню длиннее этого (символов) - «…/» и две последние папки
const recent_path_max = 40

// menu_dir - папка для пункта меню: short_dir, длинная - с конца
fn menu_dir(dir string) string {
	d := short_dir(dir)
	if d.runes().len <= recent_path_max {
		return d
	}
	parts := d.split(os.path_separator).filter(it != '')
	return if parts.len <= 2 { d } else { '…' + os.path_separator + parts#[-2..].join(os.path_separator) }
}

// rebuild_recent_menus - пункты обоих подменю по настройкам
fn rebuild_recent_menus(mut st State) {
	if isnil(st.m_recent_files) || isnil(st.m_recent_dirs) {
		return
	}
	mut mf := st.m_recent_files
	mf.children.clear()
	for p in st.settings.recent_files {
		// Имя файла и его папка: одинаковые имена из разных съёмок различимы
		mut it := vgui.menu_action('${os.file_name(p)}  (${menu_dir(os.dir(p))})')
		it.enabled = os.is_file(p)
		it.on_click = fn [mut st, p] () {
			if !isnil(st.open_path) {
				st.open_path(p)
			}
		}
		mf.add(it)
	}
	recent_tail(mut st, mut mf, false)
	mut md := st.m_recent_dirs
	md.children.clear()
	for d in st.settings.recent_dirs {
		mut it := vgui.menu_action(menu_dir(d))
		it.enabled = os.is_dir(d)
		it.on_click = fn [mut st, d] () {
			if !isnil(st.open_dir) {
				st.open_dir(d)
			}
		}
		md.add(it)
	}
	recent_tail(mut st, mut md, true)
}

// recent_tail - конец подменю: «Пусто» или разделитель и «Очистить список»
fn recent_tail(mut st State, mut m vgui.MenuItem, dir bool) {
	if m.children.len == 0 {
		mut none_ := vgui.menu_action(i18n.tr('Пусто'))
		none_.enabled = false
		m.add(none_)
		return
	}
	m.add(vgui.menu_separator())
	mut clear := vgui.menu_action(i18n.tr('Очистить список'))
	clear.on_click = fn [mut st, dir] () {
		if dir {
			st.settings.recent_dirs = []string{}
		} else {
			st.settings.recent_files = []string{}
		}
		save_settings(st.settings)
		rebuild_recent_menus(mut st)
	}
	m.add(clear)
}
