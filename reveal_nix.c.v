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
// проверяем заранее (fm1_available, ответ шины - миллисекунды). procs -
// запущенные xdg-open (open_folder_plain), State.reveal_procs.
fn reveal_in_folder(paths []string, mut procs []&os.Process) ! {
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
	open_folder_plain(os.dir(paths[0]), mut procs)!
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

// open_folder_plain - папка в программе по умолчанию (xdg-open). Не ждём
// (бывает, xdg-open живёт, пока открыт файловый менеджер): процесс - в
// procs, закончившиеся забирает (waitpid без ожидания - is_alive) следующий
// вызов, чтобы не копились зомби-процессы. Без фонового потока: его
// пришлось бы ждать, а ждать открытый менеджер на выходе нельзя.
fn open_folder_plain(dir string, mut procs []&os.Process) ! {
	reap_procs(mut procs)
	exe := os.find_abs_path_of_executable('xdg-open') or {
		return error(i18n.tr('не найден файловый менеджер (xdg-open)'))
	}
	mut p := os.new_process(exe)
	p.set_args([dir])
	p.run()
	if p.err != '' {
		return error(p.err)
	}
	procs << p
}

// reap_procs - забрать закончившиеся процессы и убрать их из списка
fn reap_procs(mut procs []&os.Process) {
	for i := procs.len - 1; i >= 0; i-- {
		mut p := procs[i]
		if !p.is_alive() {
			p.close()
			procs.delete(i)
		}
	}
}
