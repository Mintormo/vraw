module main

import raw

// Строки сведений: экспозиция и камера; нет данных - пропуск части
fn test_shot_info_text() {
	m := raw.Meta{
		cam_make:  'Canon'
		cam_model: 'EOS R8'
		lens:      'RF24-50mm F4.5-6.3 IS STM'
		focal:     35
		aperture:  5.6
		shutter:   1.0 / 60
		iso:       5000
	}
	assert shot_exposure(m) == 'ISO 5000 · 1/60 с · f/5.6 · 35 мм'
	assert shot_camera(m) == 'Canon EOS R8 · RF24-50mm F4.5-6.3 IS STM'
	assert shot_exposure(raw.Meta{ aperture: 8, shutter: 2 }) == '2 с · f/8'
	assert shot_exposure(raw.Meta{ shutter: 1.3 }) == '1.3 с'
	assert shot_exposure(raw.Meta{}) == ''
	// Производитель уже в модели - не повторять
	assert shot_camera(raw.Meta{ cam_make: 'Canon', cam_model: 'Canon EOS R50' }) == 'Canon EOS R50'
}
