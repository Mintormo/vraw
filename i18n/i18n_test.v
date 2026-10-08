module i18n

// Правила форм числа: по примеру на каждую форму
fn test_plural_index() {
	for n, want in {1: 0, 3: 1, 5: 2, 11: 2, 21: 0, 22: 1, 112: 2} {
		assert plural_index('ru', n) == want
	}
	for n, want in {1: 0, 3: 1, 5: 2, 21: 2, 22: 1, 12: 2} {
		assert plural_index('pl', n) == want
	}
	for n, want in {1: 0, 4: 1, 5: 2, 21: 2} {
		assert plural_index('cs', n) == want
	}
	for n, want in {1: 0, 21: 0, 11: 2, 2: 1, 10: 2, 19: 2} {
		assert plural_index('lt', n) == want
	}
	for n, want in {0: 0, 10: 0, 15: 0, 1: 1, 21: 1, 11: 0, 2: 2} {
		assert plural_index('lv', n) == want
	}
	for n, want in {1: 0, 0: 1, 2: 1, 19: 1, 20: 2, 101: 1} {
		assert plural_index('ro', n) == want
	}
	for n, want in {1: 0, 101: 0, 2: 1, 3: 2, 4: 2, 5: 3} {
		assert plural_index('sl', n) == want
	}
	for n, want in {0: 0, 1: 0, 2: 1} {
		assert plural_index('fr', n) == want
	}
	for n, want in {1: 0, 0: 1, 2: 1} {
		assert plural_index('en', n) == want
	}
	assert plural_index('vi', 1) == 0
	assert plural_index('vi', 5) == 0
}

// Русский - ключи как есть; подстановки; формы числа без перевода -
// русское правило
fn test_tr_russian() {
	set('ru')
	assert tr('Экспозиция') == 'Экспозиция'
	assert trf('Кадр {0} из {1}', '2', '5') == 'Кадр 2 из 5'
	assert pl(5, 'кадр|кадра|кадров') == 'кадров'
	assert pl(2, 'кадр|кадра|кадров') == 'кадра'
}

// Каждый файл перевода читается и не пуст; формы числа в нём - столько,
// сколько требует правило языка
fn test_tables() {
	for l in langs {
		if l.code == 'ru' {
			continue
		}
		t := table(l.code)
		assert t.len > 0, l.code
		want := match l.code {
			'ru', 'uk', 'be', 'sr', 'hr', 'pl', 'cs', 'sk', 'lt', 'lv', 'ro' { 3 }
			'sl' { 4 }
			'vi', 'id' { 1 }
			else { 2 }
		}
		for k, v in t {
			if k.contains('|') {
				assert v.split('|').len == want, '${l.code}: ${k} -> ${v}'
			}
		}
	}
}

// Незнакомый язык - английский; система C/POSIX - английский
fn test_set_unknown() {
	set('xx')
	assert current() == 'en'
	set('ru')
}
