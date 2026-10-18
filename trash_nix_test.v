module main

import os

// Корзина freedesktop: файл - в files/, запись - в info/ (путь, дата);
// одноимённый второй - под новым именем; путь с пробелом и кириллицей -
// %-кодом
fn test_move_to_trash() ! {
	root := os.join_path(os.vtmp_dir(), 'vraw_trash_${os.getpid()}')
	defer {
		os.rmdir_all(root) or {}
	}
	old := os.getenv('XDG_DATA_HOME')
	os.setenv('XDG_DATA_HOME', os.join_path(root, 'data'), true)
	defer {
		os.setenv('XDG_DATA_HOME', old, true)
	}
	dir := os.join_path(root, 'Снимки 1')
	os.mkdir_all(dir)!
	a := os.join_path(dir, 'IMG_1.CR3')
	os.write_file(a, 'первый')!
	move_to_trash(a)!
	assert !os.exists(a)
	trash := os.join_path(root, 'data', 'Trash')
	assert os.read_file(os.join_path(trash, 'files', 'IMG_1.CR3'))! == 'первый'
	info := os.read_file(os.join_path(trash, 'info', 'IMG_1.CR3.trashinfo'))!
	assert info.starts_with('[Trash Info]\nPath=')
	assert info.contains('%D0%A1%D0%BD%D0%B8%D0%BC%D0%BA%D0%B8%201/IMG_1.CR3')
	assert info.contains('DeletionDate=20')
	// Второй с тем же именем не затирает первый
	os.write_file(a, 'второй')!
	move_to_trash(a)!
	assert os.read_file(os.join_path(trash, 'files', 'IMG_1.2.CR3'))! == 'второй'
	assert os.exists(os.join_path(trash, 'info', 'IMG_1.2.CR3.trashinfo'))
	// Нет файла - ошибка, корзина не тронута
	if _ := move_to_trash(os.join_path(dir, 'нет.CR3')) {
		assert false
	}
	assert os.ls(os.join_path(trash, 'info'))!.len == 2
}
