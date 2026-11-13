module main

import pipeline

// same_side - снимки равны во всём, что пишется в файл (производных полей
// - камерной кривой и таблиц - в файле нет), и мазками
fn same_side(a EditState, b EditState) bool {
	return side_state(a) == side_state(b) && a.params.masks == b.params.masks
}

// strokes_history - история кисти: n записей, в каждой на мазок больше
// (мазок основы и мазок части - у части через раз)
fn strokes_history(n int) []HistEntry {
	mut e := neutral_edit()
	e.params.masks << pipeline.Mask{
		kind:  .brush
		on:    true
		parts: [pipeline.MaskPart{
			kind: .brush
		}]
	}
	mut hs := [HistEntry{
		name:  'Открыт файл'
		state: e.clone()
	}]
	for k in 0 .. n {
		mut pts := []f32{}
		mut cols := []f32{}
		for i in 0 .. 10 {
			// Точно представимые числа: в файле - 6 значащих цифр
			pts << f32(i) / 64 + f32(k) / 32
			pts << f32(0.25) + f32(i) / 64
			cols << f32(1000 + i)
			cols << f32(2000 + k)
			cols << f32(3000.5 + i)
		}
		s := pipeline.Stroke{
			pts:    pts
			radius: 0.0625
			flow:   0.5
			auto:   k % 3 == 0
			cols:   cols
		}
		if k % 2 == 0 {
			e.params.masks[0].strokes << s
		} else {
			e.params.masks[0].parts[0].strokes << s
		}
		hs << HistEntry{
			name:  'Кисть'
			key:   'brush'
			state: e.clone()
		}
	}
	return hs
}

// Версия 3: каждый мазок в файле один раз, записи - номерами; после
// чтения снимки те же, а мазок - один массив на все записи
fn test_sidecar_v3_strokes_once() {
	hs := strokes_history(6)
	text := encode_history(hs, 4, Mark{})
	assert text.contains('"version": 3')
	assert text.contains('"strokes": [')
	assert text.count('"radius"') == 6 // по разу на мазок, а не на запись
	loaded := decode_sidecar(text)!
	assert loaded.current == 4 && loaded.history.len == hs.len
	for i, h in loaded.history {
		assert same_side(h.state, hs[i].state)
		assert h.name == hs[i].name && h.key == hs[i].key
	}
	a := loaded.history[3].state.params.masks[0].strokes[0]
	b := loaded.history[6].state.params.masks[0].strokes[0]
	assert a.pts.data == b.pts.data && a.cols.data == b.cols.data
	// Повторная запись прочитанного - тот же текст
	assert encode_history(loaded.history, loaded.current, Mark{}) == text
}

// Без мазков файл - версия 2 (читает и прежний vraw), таблицы нет
fn test_sidecar_no_strokes_v2() {
	mut e := neutral_edit()
	e.params.exposure = 0.5
	text := encode_history([HistEntry{
		name:  'Открыт файл'
		state: neutral_edit()
	}, HistEntry{
		name:  'Экспозиция'
		state: e
	}], 1, Mark{})
	assert text.contains('"version": 2') && !text.contains('"strokes": [\n')
	assert same_side(decode_sidecar(text)!.history[1].state, e)
}

// Версия 2 (мазки целиком в каждой записи) читается; одинаковые мазки
// записей после чтения - общие массивы
fn test_sidecar_v2_inline_strokes() {
	st := '{"pts": [0.1, 0.2, 0.3, 0.4], "radius": 0.05, "feather": 50, "flow": 1, "auto": false, "cols": [1, 2, 3, 4, 5, 6]}'
	mask := '{"kind": "brush", "on": true, "strokes": [${st}]}'
	text := '{\n  "app": "vraw", "version": 2, "rating": 0, "flag": 0, "current": 2,\n' +
		'  "state": {"exposure": 0.5, "masks": [${mask}]},\n  "history": [\n' +
		'    {"name": "Открыт файл", "state": {}},\n' +
		'    {"name": "Кисть", "state": {"masks": [${mask}]}},\n' +
		'    {"name": "Экспозиция", "state": {"exposure": 0.5, "masks": [${mask}]}}\n  ]\n}\n'
	loaded := decode_sidecar(text)!
	a := loaded.history[1].state.params.masks[0].strokes[0]
	b := loaded.history[2].state.params.masks[0].strokes[0]
	assert a.pts == [f32(0.1), 0.2, 0.3, 0.4] && a.radius == 0.05
	assert a.pts.data == b.pts.data
	cur := decode_side_current(text)!
	assert cur.has && cur.current == 2 && same_side(cur.state, loaded.history[2].state)
}

// Номер мазка вне таблицы - испорченный файл, а не выход за границы
fn test_sidecar_v3_bad_ref() {
	hs := strokes_history(2)
	text := encode_history(hs, 2, Mark{})
	bad := text.replace('"strokes": [0]', '"strokes": [7]')
	assert bad != text
	if _ := decode_sidecar(bad) {
		assert false
	}
}

// Текущие настройки без разбора истории - те же, что у полного чтения
fn test_side_current_fast() {
	hs := strokes_history(5)
	text := encode_history(hs, 3, Mark{
		rating: 4
	})
	cur := decode_side_current(text)!
	assert cur.has && cur.current == 3 && same_side(cur.state, hs[3].state)
	// Разметка без истории в начале строки - полный разбор
	full := decode_side_current(text.replace('\n  "history": [', '\n"history": ['))!
	assert full.has && full.current == 3 && same_side(full.state, hs[3].state)
}
