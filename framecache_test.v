module main

import json2

// Настройки кэша кадров переживают сохранение и чтение (load_settings
// собирает Settings поле за полем - новое поле легко забыть)
fn test_settings_roundtrip() {
	mut s := Settings{}
	s.no_frame_cache = true
	s.frame_cache_mb = 3072
	back := settings_from(json2.decode[Settings](json2.encode(s))!)
	assert back.no_frame_cache
	assert back.frame_cache_mb == 3072
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
