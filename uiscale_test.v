module main

import json2

// Масштаб интерфейса переживает перезапуск, любой в пределах; вне
// пределов и старый settings.json без поля - 100%
fn test_ui_scale_settings() {
	mut s := Settings{}
	assert s.ui_scale == 100
	s.ui_scale = 125
	back := settings_from(json2.decode[Settings](json2.encode(s))!)
	assert back.ui_scale == 125
	s.ui_scale = 133
	assert settings_from(s).ui_scale == 133
	s.ui_scale = ui_scale_max + 1
	assert settings_from(s).ui_scale == 100
	s.ui_scale = 0
	assert settings_from(s).ui_scale == 100
	old := settings_from(json2.decode[Settings]('{"theme": "dark"}')!)
	assert old.ui_scale == 100
}

fn test_ui_scale_limits() {
	assert ui_scale_pct(ui_scale_min) == ui_scale_min
	assert ui_scale_pct(ui_scale_max) == ui_scale_max
	assert ui_scale_pct(ui_scale_min - 1) == 100
}

// Доля ленты растёт вместе с масштабом (лента той же логической
// высоты), с пределами; лента сверху и снизу - зеркально
fn test_scaled_strip_ratio() {
	assert scaled_strip_ratio(0.2, true, 1.5) - 0.3 < 0.0001
	assert (1 - scaled_strip_ratio(0.8, false, 1.5)) - 0.3 < 0.0001
	assert scaled_strip_ratio(0.4, true, 2) == 0.6
	assert scaled_strip_ratio(0.2, true, 0.1) == 0.05
	back := scaled_strip_ratio(scaled_strip_ratio(0.8, false, 1.25), false, 0.8)
	assert back > 0.7999 && back < 0.8001
}
