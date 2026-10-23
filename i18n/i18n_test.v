module i18n

// Правила форм числа - тест vgui.i18n; здесь - что обёртка их отдаёт
fn test_plural_index() {
	assert plural_index('ru', 21) == 0
	assert plural_index('sl', 5) == 3
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

// Незнакомый язык - английский
fn test_set_unknown() {
	set('xx')
	assert current() == 'en'
	assert supported('xx') == 'en' && supported('de') == 'de'
	set('ru')
}

// Перевод из вшитого файла, запасной - английский, омоним; tr_in - не
// меняя текущего языка
fn test_tr_german() {
	set('de')
	assert tr('Экспозиция') == table('de')['Экспозиция']
	assert tr('Экспозиция') != 'Экспозиция'
	assert trc('ББ', 'Оттенок') != trc('HSL', 'Оттенок')
	assert pl(1, 'кадр|кадра|кадров') != pl(5, 'кадр|кадра|кадров')
	set('ru')
	assert tr_in('de', 'Экспозиция') == table('de')['Экспозиция']
	assert current() == 'ru'
	assert tr('Экспозиция') == 'Экспозиция'
}
