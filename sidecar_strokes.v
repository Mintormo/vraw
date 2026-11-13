module main

// Мазки кисти в сайдкаре версии 3 (13.11.2026). Мазок после завершения не
// меняется, а снимок истории хранит ВСЕ мазки на момент правки: в версии 2
// каждая запись повторяла их целиком - файл и время записи росли
// квадратично (100 мазков по 80 точек - 14.6 МБ JSON и 1.9 с записи в
// главном потоке на каждую правку). Версия 3 пишет каждый мазок один раз -
// таблица "strokes" перед настройками, - а в настройках масок вместо
// мазков их номера в таблице:
//   "strokes": [
//     {"pts": [...], "radius": 0.05, ...},
//     ...
//   ],
//   "state": {"masks": [{"kind": "brush", "strokes": [0, 1], ...}]},
// В памяти снимки так же делят массивы точек мазков (pipeline.Stroke.copy),
// прочитанные записи - один мазок таблицы на всех. Номер 3 ставится, только
// если мазки есть: без них файл - версия 2, его читает и прежний vraw.
import json2
import pipeline
import i18n

// StrokeTable - таблица мазков при записи: номер по адресу точек (снимки
// делят массивы мазка - находится сразу) и по тексту (одинаковые мазки в
// разных массивах - прочитанные из старого файла, вставленные)
struct StrokeTable {
mut:
	by_ptr  map[u64]int
	by_text map[string]int
	lines   []string
}

// index - номер мазка s в таблице (новый - дописывается)
fn (mut t StrokeTable) index(s pipeline.Stroke) int {
	key := u64(s.pts.data)
	if s.pts.len > 0 {
		if i := t.by_ptr[key] {
			return i
		}
	}
	line := stroke_line(s)
	i := t.by_text[line] or {
		t.lines << line
		n := t.lines.len - 1
		t.by_text[line] = n
		n
	}
	if s.pts.len > 0 {
		t.by_ptr[key] = i
	}
	return i
}

// stroke_line - мазок строкой JSON (числа - до 6 значащих цифр, как
// остальные настройки)
fn stroke_line(s pipeline.Stroke) string {
	a := json2.decode[json2.Any](json2.encode(side_stroke(s))) or { return '{}' }
	return any_line(round_any(a))
}

// bare_mask - фильтр без мазков (основы и частей): их номера дописывает
// state_line
fn bare_mask(m pipeline.Mask) pipeline.Mask {
	mut c := m
	c.strokes = []pipeline.Stroke{}
	c.parts = m.parts.map(pipeline.MaskPart{
		...it
		strokes: []pipeline.Stroke{}
	})
	return c
}

// stroke_refs - номера мазков strokes в таблице как массив JSON
fn stroke_refs(strokes []pipeline.Stroke, mut t StrokeTable) json2.Any {
	mut r := []json2.Any{cap: strokes.len}
	for s in strokes {
		r << json2.Any(t.index(s))
	}
	return json2.Any(r)
}

// state_line - настройки снимка e строкой файла: поля, отличные от
// умолчаний (defs), мазки масок - номерами в таблице t. Мазки не
// проходят через json2 на каждый снимок - только новые, один раз.
fn state_line(e EditState, defs map[string]json2.Any, mut t StrokeTable) string {
	mut bare := e
	bare.params.masks = e.params.masks.map(bare_mask(it))
	mut m := side_sparse(side_state(bare), defs)
	if ms := m['masks'] {
		mut arr := ms.as_array().clone()
		for i, ma in arr {
			if i >= e.params.masks.len || ma !is map[string]json2.Any {
				continue
			}
			src := e.params.masks[i]
			mut mm := ma.as_map().clone()
			mm['strokes'] = stroke_refs(src.strokes, mut t)
			if ps := mm['parts'] {
				mut parr := ps.as_array().clone()
				for j, pa in parr {
					if j >= src.parts.len || pa !is map[string]json2.Any {
						continue
					}
					mut pm := pa.as_map().clone()
					pm['strokes'] = stroke_refs(src.parts[j].strokes, mut t)
					parr[j] = json2.Any(pm)
				}
				mm['parts'] = json2.Any(parr)
			}
			arr[i] = json2.Any(mm)
		}
		m['masks'] = json2.Any(arr)
	}
	return any_line(json2.Any(m))
}

// stroke_table_of - таблица "strokes" файла: мазки (как stroke_of -
// значения в пределах ползунков). Нет таблицы - пусто.
fn stroke_table_of(a json2.Any) ![]pipeline.Stroke {
	if a !is []json2.Any {
		return []pipeline.Stroke{}
	}
	mut r := []pipeline.Stroke{cap: a.as_array().len}
	for s in a.as_array() {
		if s !is map[string]json2.Any {
			return error(i18n.tr('пустая или испорченная история'))
		}
		r << stroke_of(json2.decode[SideStroke](json2.encode(s))!)
	}
	return r
}

// MaskRefs - номера мазков фильтра (основа и части) из настроек файла
struct MaskRefs {
	base  []int
	parts [][]int
}

// refs_of - номера из массива "strokes" (-1 - мазки там записаны целиком,
// как в версии 2: их разберёт side_from_obj)
fn refs_of(a json2.Any, n int) ![]int {
	if a !is []json2.Any {
		return []int{}
	}
	arr := a.as_array()
	if arr.len == 0 || arr[0] is map[string]json2.Any {
		return [-1]
	}
	mut r := []int{cap: arr.len}
	for v in arr {
		if v is map[string]json2.Any {
			return error(i18n.tr('пустая или испорченная история'))
		}
		i := v.int()
		if i < 0 || i >= n {
			return error(i18n.tr('пустая или испорченная история'))
		}
		r << i
	}
	return r
}

// take_refs - настройки obj без номеров мазков (массивы номеров - пустые)
// и сами номера по фильтрам; n - размер таблицы
fn take_refs(obj json2.Any, n int) !(json2.Any, []MaskRefs) {
	if obj !is map[string]json2.Any {
		return obj, []MaskRefs{}
	}
	mut m := obj.as_map().clone()
	ms := m['masks'] or { return obj, []MaskRefs{} }
	if ms !is []json2.Any {
		return obj, []MaskRefs{}
	}
	mut arr := ms.as_array().clone()
	mut refs := []MaskRefs{cap: arr.len}
	for i, ma in arr {
		if ma !is map[string]json2.Any {
			refs << MaskRefs{}
			continue
		}
		mut mm := ma.as_map().clone()
		base := refs_of(mm['strokes'] or { json2.Any(0) }, n)!
		if base.len > 0 && base[0] >= 0 {
			mm['strokes'] = json2.Any([]json2.Any{})
		}
		mut parts := [][]int{}
		if ps := mm['parts'] {
			if ps is []json2.Any {
				mut parr := ps.as_array().clone()
				for j, pa in parr {
					if pa !is map[string]json2.Any {
						parts << []int{}
						continue
					}
					mut pm := pa.as_map().clone()
					pr := refs_of(pm['strokes'] or { json2.Any(0) }, n)!
					if pr.len > 0 && pr[0] >= 0 {
						pm['strokes'] = json2.Any([]json2.Any{})
					}
					parts << pr
					parr[j] = json2.Any(pm)
				}
				mm['parts'] = json2.Any(parr)
			}
		}
		refs << MaskRefs{
			base:  base
			parts: parts
		}
		arr[i] = json2.Any(mm)
	}
	m['masks'] = json2.Any(arr)
	return json2.Any(m), refs
}

// put_refs - мазки таблицы в фильтры снимка по номерам (общие массивы: в
// памяти мазок один на все записи)
fn put_refs(mut e EditState, refs []MaskRefs, table []pipeline.Stroke) {
	for i, r in refs {
		if i >= e.params.masks.len {
			break
		}
		if r.base.len > 0 && r.base[0] >= 0 {
			e.params.masks[i].strokes = r.base.map(table[it])
		}
		for j, pr in r.parts {
			if j < e.params.masks[i].parts.len && pr.len > 0 && pr[0] >= 0 {
				e.params.masks[i].parts[j].strokes = pr.map(table[it])
			}
		}
	}
}

// state_of_obj - снимок из настроек файла (версии 2 и 3: мазки целиком
// или номерами в table)
fn state_of_obj(obj json2.Any, defs map[string]json2.Any, table []pipeline.Stroke) !EditState {
	bare, refs := take_refs(obj, table.len)!
	mut e := edit_state(side_from_obj(bare, defs)!)!
	put_refs(mut e, refs, table)
	return e
}

// share_strokes - одинаковые мазки записей истории - одни массивы (файлы
// версий 1 и 2: там у каждой записи свои копии; в памяти это та же
// квадратичная трата, а запись версии 3 искала бы их по тексту каждый раз)
fn share_strokes(mut hs []HistEntry) {
	mut seen := map[string]pipeline.Stroke{}
	for h in 0 .. hs.len {
		if hs[h].state.params.masks.len == 0 {
			continue
		}
		mut masks := hs[h].state.params.masks.clone()
		for i in 0 .. masks.len {
			masks[i].strokes = masks[i].strokes.map(shared_stroke(it, mut seen))
			mut parts := masks[i].parts.clone()
			for j in 0 .. parts.len {
				parts[j].strokes = parts[j].strokes.map(shared_stroke(it, mut seen))
			}
			masks[i].parts = parts
		}
		mut e := hs[h].state
		e.params.masks = masks
		hs[h] = HistEntry{
			...hs[h]
			state: e
		}
	}
}

fn shared_stroke(s pipeline.Stroke, mut seen map[string]pipeline.Stroke) pipeline.Stroke {
	line := stroke_line(s)
	if t := seen[line] {
		return t
	}
	seen[line] = s
	return s
}
