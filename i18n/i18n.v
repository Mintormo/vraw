// Перевод интерфейса vraw - обёртка над vgui.i18n (ядро перевода vgui на
// чистом V, без SDL: его можно звать и из raw/, ai/, imgio/, lens/,
// которым нельзя зависеть от окон). Здесь - только своё: переводы vraw
// (lang/<код>.json рядом с модулем, {"русская строка": "перевод"}, вшиты
// в бинарник), ключи - русский текст (исходный язык), запасной -
// английский; имена функций - прежние (tr, trf, trc, pl, tr_in ...),
// весь код и tools/i18n_check.py их и ищут.
//
// Язык выбирается один раз при запуске (set) - дальше каталог только
// читается, поэтому tr можно звать из любых потоков. Поиск: выбранный
// язык, затем английский, затем сам ключ (русский). Формы числа -
// pl(n, 'кадр|кадра|кадров'), правила - vgui.i18n.plural_index.
module i18n

import json2
import vgui.i18n as core

// Lang - язык интерфейса: код и самоназвание (для списка в настройках)
pub type Lang = core.Lang

// langs - языки vraw (у каждого, кроме русского, - файл lang/<код>.json);
// порядок - как в списке настроек
pub const langs = core.languages

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

// supported - язык code, если он есть у vraw, иначе английский
// (язык системы - vgui.detect_system_locale, в module main: здесь SDL нет)
pub fn supported(code string) string {
	return if known(code) { code } else { 'en' }
}

// init - до выбора языка (set) - исходный язык, русский: строки как есть
// и формы числа по русскому правилу (тесты и всё, что выполнится до
// set в main; без этого ядро брало правило своего языка по умолчанию -
// английского, «8 группы»)
fn init() {
	configure()
	core.set_locale('ru')
}

fn configure() {
	core.set_loader(embedded)
	core.set_source_locale('ru')
	core.set_fallback('en')
}

// set выбирает язык интерфейса (незнакомый - английский). Звать один раз
// при запуске, до построения окна и до запуска потоков.
pub fn set(code string) {
	configure()
	core.set_locale(supported(code))
}

// current - код выбранного языка
pub fn current() string {
	return core.locale()
}

// tr - перевод строки s (ключ - русский текст)
pub fn tr(s string) string {
	return core.tr(s)
}

// trc - перевод омонима («Оттенок» - Hue в HSL и Tint в балансе белого):
// ключ перевода - «контекст::строка», по-русски - сама строка
pub fn trc(ctx string, s string) string {
	return core.trc(ctx, s)
}

// trf - перевод с подстановками {0}, {1}...
pub fn trf(s string, args ...string) string {
	return core.trf(s, ...args)
}

// tr_in - перевод s на язык code, не меняя текущего (подпись о смене
// языка - сразу на выбранном). Без перевода - английский, для ru - s.
pub fn tr_in(code string, s string) string {
	return core.tr_in(code, s)
}

// tr_all - перевод списка (названия пунктов из констант)
pub fn tr_all(a []string) []string {
	return core.tr_all(a)
}

// pl - форма слова для числа n. forms - русские формы «один|два|пять»
// (ключ перевода); перевод - формы своего языка через «|» в порядке
// plural_index. Без перевода - русское правило.
pub fn pl(n i64, forms string) string {
	return core.pl(n, forms)
}

// plural_index - номер формы для числа n по правилу языка
pub fn plural_index(code string, n i64) int {
	return core.plural_index(code, n)
}
