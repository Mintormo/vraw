// Перевод интерфейса vraw. Ключ - сама русская строка из кода (как в
// gettext): tr('Экспозиция'), поэтому код остаётся читаемым, а русский
// не нужен отдельным файлом. Переводы - lang/<код>.json рядом с модулем
// ({"русская строка": "перевод"}), вшиты в бинарник.
//
// Язык выбирается один раз при запуске (set) - дальше таблица только
// читается, поэтому tr можно звать из любых потоков. Поиск: выбранный
// язык, затем английский, затем сам ключ (русский).
//
// Строки с подстановками - trf('Кадр {0} из {1}', a, b); формы числа -
// pl(n, 'кадр|кадра|кадров'): ключ - русские формы через «|», в переводе -
// формы своего языка в порядке его правила (plural_index).
module i18n

import os
import json2

// Lang - язык интерфейса: код и самоназвание (для списка в настройках)
pub struct Lang {
pub:
	code string
	name string
}

// Порядок - как в списке настроек: русский (исходный), английский,
// дальше по алфавиту самоназваний.
pub const langs = [
	Lang{'ru', 'Русский'},
	Lang{'en', 'English'},
	Lang{'id', 'Bahasa Indonesia'},
	Lang{'cs', 'Čeština'},
	Lang{'da', 'Dansk'},
	Lang{'de', 'Deutsch'},
	Lang{'et', 'Eesti'},
	Lang{'es', 'Español'},
	Lang{'fr', 'Français'},
	Lang{'hr', 'Hrvatski'},
	Lang{'it', 'Italiano'},
	Lang{'lv', 'Latviešu'},
	Lang{'lt', 'Lietuvių'},
	Lang{'hu', 'Magyar'},
	Lang{'nl', 'Nederlands'},
	Lang{'nb', 'Norsk bokmål'},
	Lang{'pl', 'Polski'},
	Lang{'pt', 'Português (Brasil)'},
	Lang{'ro', 'Română'},
	Lang{'sk', 'Slovenčina'},
	Lang{'sl', 'Slovenščina'},
	Lang{'fi', 'Suomi'},
	Lang{'sv', 'Svenska'},
	Lang{'vi', 'Tiếng Việt'},
	Lang{'tr', 'Türkçe'},
	Lang{'el', 'Ελληνικά'},
	Lang{'be', 'Беларуская'},
	Lang{'bg', 'Български'},
	Lang{'kk', 'Қазақ тілі'},
	Lang{'sr', 'Српски'},
	Lang{'uk', 'Українська'},
]

__global (
	i18n_code  = 'ru'
	i18n_main  = map[string]string{}
	i18n_en    = map[string]string{}
	i18n_ready = false
)

// embedded - вшитый файл перевода; '' - нет такого языка
fn embedded(code string) string {
	return match code {
		'en' { $embed_file('lang/en.json').to_string() }
		'id' { $embed_file('lang/id.json').to_string() }
		'cs' { $embed_file('lang/cs.json').to_string() }
		'da' { $embed_file('lang/da.json').to_string() }
		'de' { $embed_file('lang/de.json').to_string() }
		'et' { $embed_file('lang/et.json').to_string() }
		'es' { $embed_file('lang/es.json').to_string() }
		'fr' { $embed_file('lang/fr.json').to_string() }
		'hr' { $embed_file('lang/hr.json').to_string() }
		'it' { $embed_file('lang/it.json').to_string() }
		'lv' { $embed_file('lang/lv.json').to_string() }
		'lt' { $embed_file('lang/lt.json').to_string() }
		'hu' { $embed_file('lang/hu.json').to_string() }
		'nl' { $embed_file('lang/nl.json').to_string() }
		'nb' { $embed_file('lang/nb.json').to_string() }
		'pl' { $embed_file('lang/pl.json').to_string() }
		'pt' { $embed_file('lang/pt.json').to_string() }
		'ro' { $embed_file('lang/ro.json').to_string() }
		'sk' { $embed_file('lang/sk.json').to_string() }
		'sl' { $embed_file('lang/sl.json').to_string() }
		'fi' { $embed_file('lang/fi.json').to_string() }
		'sv' { $embed_file('lang/sv.json').to_string() }
		'vi' { $embed_file('lang/vi.json').to_string() }
		'tr' { $embed_file('lang/tr.json').to_string() }
		'el' { $embed_file('lang/el.json').to_string() }
		'be' { $embed_file('lang/be.json').to_string() }
		'bg' { $embed_file('lang/bg.json').to_string() }
		'kk' { $embed_file('lang/kk.json').to_string() }
		'sr' { $embed_file('lang/sr.json').to_string() }
		'uk' { $embed_file('lang/uk.json').to_string() }
		else { '' }
	}
}

// table - перевод языка code (пустой - нет файла или он испорчен)
pub fn table(code string) map[string]string {
	text := embedded(code)
	if text == '' {
		return map[string]string{}
	}
	return json2.decode[map[string]string](text) or { map[string]string{} }
}

// known - есть ли язык в списке
pub fn known(code string) bool {
	return langs.any(it.code == code)
}

// system - язык системы из LC_ALL / LC_MESSAGES / LANG / LANGUAGE
// (uk_UA.UTF-8 -> uk; Norwegian no/nn -> nb); не из списка - английский.
pub fn system() string {
	for key in ['LC_ALL', 'LC_MESSAGES', 'LANG', 'LANGUAGE'] {
		v := os.getenv(key).to_lower()
		if v.len < 2 || v == 'c' || v.starts_with('c.') || v == 'posix' {
			continue
		}
		mut code := v.all_before(':').all_before('.').all_before('_').all_before('-')
		if code in ['no', 'nn'] {
			code = 'nb'
		}
		return if known(code) { code } else { 'en' }
	}
	return 'en'
}

// set выбирает язык интерфейса. Звать один раз при запуске, до
// построения окна и до запуска потоков.
pub fn set(code string) {
	i18n_code = if known(code) { code } else { 'en' }
	i18n_main = if i18n_code == 'ru' { map[string]string{} } else { table(i18n_code) }
	i18n_en = if i18n_code in ['ru', 'en'] { map[string]string{} } else { table('en') }
	i18n_ready = true
}

// current - код выбранного языка
pub fn current() string {
	return i18n_code
}

// tr - перевод строки s (ключ - русский текст)
pub fn tr(s string) string {
	if i18n_code == 'ru' {
		return s
	}
	if v := i18n_main[s] {
		if v != '' {
			return v
		}
	}
	if v := i18n_en[s] {
		if v != '' {
			return v
		}
	}
	return s
}

// trc - перевод омонима: одно русское слово, разные переводы
// («Оттенок» - Hue в HSL и Tint в балансе белого). Ключ перевода -
// «контекст::строка», по-русски и без перевода - сама строка.
pub fn trc(ctx string, s string) string {
	key := ctx + '::' + s
	t := tr(key)
	return if t == key { s } else { t }
}

// trf - перевод с подстановками {0}, {1}...
pub fn trf(s string, args ...string) string {
	mut r := tr(s)
	for i, a in args {
		r = r.replace('{${i}}', a)
	}
	return r
}

// tr_in - перевод s на язык code, не меняя текущего (подпись о смене
// языка - сразу на выбранном). Без перевода - английский, для ru - s.
pub fn tr_in(code string, s string) string {
	if code == 'ru' {
		return s
	}
	if v := table(code)[s] {
		if v != '' {
			return v
		}
	}
	if v := table('en')[s] {
		if v != '' {
			return v
		}
	}
	return s
}

// tr_all - перевод списка (названия пунктов из констант)
pub fn tr_all(a []string) []string {
	return a.map(tr(it))
}

// pl - форма слова для числа n. forms - русские формы «один|два|пять»
// (ключ перевода); перевод - формы своего языка через «|» в порядке
// plural_index. Без перевода - русское правило.
pub fn pl(n i64, forms string) string {
	t := tr(forms)
	// перевод не нашёлся - формы русские, правило тоже русское
	code := if t == forms && i18n_code != 'ru' { 'ru' } else { i18n_code }
	f := t.split('|')
	i := plural_index(code, n)
	return f[if i < f.len { i } else { f.len - 1 }]
}

// plural_index - номер формы для числа n по правилу языка (CLDR, только
// целые). Порядок форм в переводе:
//   ru uk be sr hr          один | два-четыре | пять (21 - один, 11 - пять)
//   pl                      один | два-четыре | пять (21 - пять)
//   cs sk                   один | два-четыре | остальные
//   lt                      один (1, 21) | два-девять | остальные (11-19, 10, 20)
//   lv                      ноль (0, 10-20, 30) | один (1, 21) | остальные
//   ro                      один | мало (0, 2-19, 101-119) | остальные
//   sl                      один (1, 101) | два (2, 102) | три-четыре | остальные
//   fr pt                   один (0, 1) | остальные
//   vi id                   одна форма
//   остальные               один | остальные
pub fn plural_index(code string, n i64) int {
	a := if n < 0 { -n } else { n }
	m10 := a % 10
	m100 := a % 100
	return match code {
		'ru', 'uk', 'be', 'sr', 'hr' {
			if m10 == 1 && m100 != 11 {
				0
			} else if m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) {
				1
			} else {
				2
			}
		}
		'pl' {
			if a == 1 {
				0
			} else if m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) {
				1
			} else {
				2
			}
		}
		'cs', 'sk' {
			if a == 1 {
				0
			} else if a >= 2 && a <= 4 {
				1
			} else {
				2
			}
		}
		'lt' {
			if m10 == 1 && (m100 < 11 || m100 > 19) {
				0
			} else if m10 >= 2 && (m100 < 11 || m100 > 19) {
				1
			} else {
				2
			}
		}
		'lv' {
			if m10 == 0 || (m100 >= 11 && m100 <= 19) {
				0
			} else if m10 == 1 && m100 != 11 {
				1
			} else {
				2
			}
		}
		'ro' {
			if a == 1 {
				0
			} else if a == 0 || (m100 >= 1 && m100 <= 19) {
				1
			} else {
				2
			}
		}
		'sl' {
			if m100 == 1 {
				0
			} else if m100 == 2 {
				1
			} else if m100 == 3 || m100 == 4 {
				2
			} else {
				3
			}
		}
		'fr', 'pt' {
			if a <= 1 { 0 } else { 1 }
		}
		'vi', 'id' {
			0
		}
		else {
			if a == 1 { 0 } else { 1 }
		}
	}
}
