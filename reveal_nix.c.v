module main

// «Показать в папке» под Linux (Windows - reveal_windows.c.v): файловый
// менеджер открывает папку кадра и выделяет его. Стандарт freedesktop -
// D-Bus-интерфейс org.freedesktop.FileManager1, метод ShowItems (Dolphin,
// Nautilus, Nemo, Caja, Thunar и др.). Нет такой службы - xdg-open папки,
// без выделения.
import os
import i18n

const fm1_name = 'org.freedesktop.FileManager1'

// reveal_in_folder - показать файлы paths (из одной папки) в файловом
// менеджере. Ответ ShowItems не ждём: менеджер может запускаться секунду,
// окно программы за это время не замирает. Есть ли кому ответить,
// проверяем заранее (fm1_available, ответ шины - миллисекунды).
fn reveal_in_folder(paths []string) ! {
	if paths.len == 0 {
		return
	}
	if fm1_available() {
		// Путь - в %-кодировке (trash_url): запятая в имени не разобьёт
		// массив dbus-send
		uris := paths.map('file://' + trash_url(it)).join(',')
		r := os.exec(['dbus-send', '--session', '--type=method_call', '--dest=${fm1_name}',
			'/org/freedesktop/FileManager1', '${fm1_name}.ShowItems', 'array:string:${uris}',
			'string:'])
		if r.exit_code == 0 {
			return
		}
	}
	open_folder_plain(os.dir(paths[0]))!
}

// fm1_available - на сеансовой шине есть файловый менеджер с FileManager1:
// уже запущен или запускается по требованию
fn fm1_available() bool {
	owner := os.exec(['dbus-send', '--session', '--print-reply', '--reply-timeout=1000',
		'--dest=org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus.NameHasOwner',
		'string:${fm1_name}'])
	if owner.exit_code == 0 && owner.output.contains('boolean true') {
		return true
	}
	act := os.exec(['dbus-send', '--session', '--print-reply', '--reply-timeout=1000',
		'--dest=org.freedesktop.DBus', '/org/freedesktop/DBus',
		'org.freedesktop.DBus.ListActivatableNames'])
	return act.exit_code == 0 && act.output.contains('"${fm1_name}"')
}

// open_folder_plain - папка в программе по умолчанию (xdg-open). Не ждём:
// его вывод не перехватываем, завершения дожидается фоновый поток (иначе
// остался бы зомби-процесс)
fn open_folder_plain(dir string) ! {
	exe := os.find_abs_path_of_executable('xdg-open') or {
		return error(i18n.tr('не найден файловый менеджер (xdg-open)'))
	}
	mut p := os.new_process(exe)
	p.set_args([dir])
	p.run()
	if p.err != '' {
		return error(p.err)
	}
	spawn reap_process(mut p)
}

fn reap_process(mut p os.Process) {
	p.wait()
	p.close()
}
