module main

// Ввод точного значения ползунка (numedit.v): какой текст поле пропустит,
// как он читается и как значение показывается при открытии поля

fn test_num_prefix_ok() {
	for s in ['', '-', '+', '1', '-1.5', '0,25', '.5', '12.'] {
		assert num_prefix_ok(s), s
	}
	for s in ['a', '1a', '1.2.3', '1,2.3', '--1', '1-', '5 K', '1e3'] {
		assert !num_prefix_ok(s), s
	}
}

fn test_parse_num() {
	assert parse_num('1.5')? == f32(1.5)
	assert parse_num('-0,75')? == f32(-0.75)
	assert parse_num(' 5500 ')? == f32(5500)
	assert parse_num('+2')? == f32(2)
	assert parse_num('.5')? == f32(0.5)
	assert parse_num('') == none
	assert parse_num('-') == none
	assert parse_num('.') == none
	assert parse_num('abc') == none
}

fn test_num_text() {
	assert num_text(1.5, 2) == '1.5'
	assert num_text(2, 2) == '2'
	assert num_text(-0.70, 2) == '-0.7'
	assert num_text(-0.001, 2) == '0'
	assert num_text(42.6, 0) == '43'
	assert num_text(1.25, 1) == '1.2' || num_text(1.25, 1) == '1.3'
}
