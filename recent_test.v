module main

import os
import json2

// Список недавних: новое - первым, без повторов, не длиннее предела
fn test_recent_push() {
	mut l := []string{}
	for p in ['a', 'b', 'c'] {
		l = recent_push(l, p, 3)
	}
	assert l == ['c', 'b', 'a']
	l = recent_push(l, 'a', 3)
	assert l == ['a', 'c', 'b']
	l = recent_push(l, 'd', 3)
	assert l == ['d', 'a', 'c']
}

// Предел: варианты из recent_counts, чужое - по умолчанию; список в
// настройках обрезается по пределу, пустые строки убираются
fn test_recent_settings() ! {
	assert recent_limit(0) == recent_default
	assert recent_limit(7) == recent_default
	assert recent_limit(5) == 5
	s := Settings{
		recent_files:   ['1', '', '2', '3', '4', '5', '6', '7']
		recent_files_n: 5
		recent_dirs_n:  7
	}
	back := settings_from(json2.decode[Settings](json2.encode(s))!)
	assert back.recent_files == ['1', '2', '3', '4', '5']
	assert back.recent_files_n == 5
	assert back.recent_dirs_n == 0
	assert short_dir(os.join_path(os.home_dir(), 'Снимки')) == '~/Снимки'
	assert short_dir('/media/диск') == '/media/диск'
	// Длинный путь - «…/» и две последние папки
	assert menu_dir('/media/igor/Disk/Фото/2026/2026-10-18 Прогулка по парку') == '…/2026/2026-10-18 Прогулка по парку'
	assert menu_dir('/media/диск') == '/media/диск'
}
