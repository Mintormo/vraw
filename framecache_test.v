module main

import json2

// Настройки кэша кадров переживают сохранение и чтение (load_settings
// собирает Settings поле за полем - новое поле легко забыть)
fn test_settings_roundtrip() {
	mut s := Settings{}
	s.no_frame_cache = true
	s.frame_cache_mb = 3072
	s.lang = 'de'
	s.preset_wb_shift = true
	s.hist_raw = true
	s.hist_log = true
	s.no_hist_luma = true
	back := settings_from(json2.decode[Settings](json2.encode(s))!)
	assert back.no_frame_cache
	assert back.hist_raw && back.hist_log && back.no_hist_luma
	assert back.preset_wb_shift
	assert back.frame_cache_mb == 3072
	assert back.lang == 'de'
	// незнакомый язык - как в системе
	s.lang = 'xx'
	assert settings_from(s).lang == ''
	// Чужой предел - по умолчанию; старый файл без полей - кэш включён
	s.frame_cache_mb = 777
	assert settings_from(s).frame_cache_mb == 0
	old := settings_from(json2.decode[Settings]('{"theme": "dark"}')!)
	assert !old.no_frame_cache && old.frame_cache_mb == 0
}

// Размер записи кэша - по разным массивам: raw_linear бывает тем же
// массивом, что dev_linear или linear
fn test_frame_bytes_alias() {
	a := []u16{len: 1000}
	b := []u16{len: 1000}
	m := []u16{len: 100}
	same := &FrameCache{
		dev_linear: a
		raw_linear: a
		linear:     a
		mask:       m
	}
	assert frame_bytes(same) == 2200
	diff := &FrameCache{
		dev_linear: a
		raw_linear: b
		linear:     b
		mask:       m
		cam_view:   []u8{len: 50}
	}
	assert frame_bytes(diff) == 4250
}

// Предзагрузка (prefetch.v): итог - в кэш без лишних ссылок; тот же кадр
// заменяет прежнюю запись; вытеснение отпускает буферы (реестр пуст)
fn test_frame_put_ownership() {
	mut st := State{}
	before := own_refs.len
	for _ in 0 .. 2 {
		lin := own_new[u16](300)
		res := LoadResult{
			w:          10
			h:          10
			dev_linear: lin
			raw_linear: share(lin)
			linear:     share(lin)
			mask:       own_new[u16](200)
			cam_view:   own_new[u8](400)
		}
		frame_put(mut st, '/x/a.CR3', res)
	}
	assert st.fcache.len == 1
	assert st.fcache[0].bytes == 600 + 400 + 400
	assert own_refs.len == before + 3
	frame_drop(mut st, '/x/a.CR3')
	assert st.fcache.len == 0
	assert own_refs.len == before
}
