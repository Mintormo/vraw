module main

import os

// Кэш результата AI: запись и чтение того же; чужой ключ и обрезанный
// файл - ошибка, а не мусор; путь - .vraw-cache в папке снимка
fn test_ai_cache_roundtrip() ! {
	root := os.join_path(os.vtmp_dir(), 'vraw_aicache_${os.getpid()}')
	defer {
		os.rmdir_all(root) or {}
	}
	raw := os.join_path(root, 'Снимки', 'IMG_1.CR3')
	path := ai_cache_path(raw)
	assert path == os.join_path(root, 'Снимки', '.vraw-cache', 'IMG_1.CR3.vrai')
	fw, fh := 5, 3
	mut full := []u16{len: fw * fh * 3}
	for i in 0 .. full.len {
		full[i] = u16(i * 300)
	}
	ai_cache_write(path, 'ключ', full, fw, fh)!
	assert !os.exists(path + '.tmp')
	mut got, gw, gh := ai_cache_read(path, 'ключ')!
	defer {
		drop(mut got)
	}
	assert gw == fw && gh == fh
	assert got == full
	// Чужой ключ (другой объектив, изменённый RAW)
	if _, _, _ := ai_cache_read(path, 'другой') {
		assert false, 'чужой ключ принят'
	}
	// Обрезанный файл
	data := os.read_bytes(path)!
	os.write_file_array(path, data[..data.len - 10])!
	if _, _, _ := ai_cache_read(path, 'ключ') {
		assert false, 'обрезанный принят'
	}
	// Размер не сходится - не пишется
	if _ := ai_cache_write(path, 'ключ', full, fw + 1, fh) {
		assert false
	}
}
