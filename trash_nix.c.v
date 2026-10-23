module main

// Корзина Linux по спецификации freedesktop.org (Trash 1.0) - так же, как
// её ведут Dolphin, Nautilus и `gio trash`: файл переезжает в files/
// корзины, рядом в info/ - <имя>.trashinfo (откуда и когда), из корзины
// его можно вернуть файловым менеджером. Корзина - домашняя
// ($XDG_DATA_HOME/Trash), для файла на другом диске (флешка, второй
// раздел) - в корне его тома: <том>/.Trash-<uid> (переименование между
// томами невозможно, а копировать гигабайты в домашнюю корзину незачем).
import os
import time

// move_to_trash - переместить файл в корзину
fn move_to_trash(path string) ! {
	abs := os.real_path(path)
	fst := os.stat(abs)!
	home := home_trash()
	os.mkdir_all(home, mode: 0o700)!
	trash := if os.stat(home)!.dev == fst.dev {
		home
	} else {
		top := mount_top(abs, fst.dev)
		t := os.join_path(top, '.Trash-${os.getuid()}')
		os.mkdir_all(t, mode: 0o700)!
		t
	}
	files := os.join_path(trash, 'files')
	info := os.join_path(trash, 'info')
	os.mkdir_all(files, mode: 0o700)!
	os.mkdir_all(info, mode: 0o700)!
	name := trash_name(files, info, os.file_name(abs))
	info_path := os.join_path(info, name + '.trashinfo')
	// Сначала запись о файле, потом сам файл: прерванное перемещение не
	// оставляет в корзине безымянного файла
	os.write_file(info_path, '[Trash Info]\nPath=${trash_url(abs)}\nDeletionDate=${time.now().custom_format('YYYY-MM-DDTHH:mm:ss')}\n')!
	os.mv(abs, os.join_path(files, name)) or {
		os.rm(info_path) or {}
		return err
	}
}

// home_trash - домашняя корзина
fn home_trash() string {
	data := os.getenv('XDG_DATA_HOME')
	base := if data != '' { data } else { os.join_path(os.home_dir(), '.local', 'share') }
	return os.join_path(base, 'Trash')
}

// mount_top - корень тома файла: выше по папкам, пока тот же dev
fn mount_top(path string, dev u64) string {
	mut dir := os.dir(path)
	for {
		up := os.dir(dir)
		if up == dir {
			return dir
		}
		st := os.stat(up) or { return dir }
		if st.dev != dev {
			return dir
		}
		dir = up
	}
	return dir
}

// trash_name - свободное имя в корзине: IMG.CR3, IMG.2.CR3, IMG.3.CR3...
fn trash_name(files string, info string, base string) string {
	ext := os.file_ext(base)
	stem := base[..base.len - ext.len]
	mut name := base
	mut n := 2
	for os.exists(os.join_path(files, name)) || os.exists(os.join_path(info, name + '.trashinfo')) {
		name = '${stem}.${n}${ext}'
		n++
	}
	return name
}

// trash_url - путь для .trashinfo: байты вне «безопасных» - %XX
fn trash_url(path string) string {
	mut sb := []u8{}
	for b in path.bytes() {
		if (b >= `a` && b <= `z`) || (b >= `A` && b <= `Z`) || (b >= `0` && b <= `9`)
			|| b in [`/`, `-`, `_`, `.`, `~`] {
			sb << b
		} else {
			sb << '%${b:02X}'.bytes()
		}
	}
	return sb.bytestr()
}
