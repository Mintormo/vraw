module raw

fn C.libraw_open_wfile(lr &C.libraw_data_t, path &u16) int

// open_path - открыть файл в LibRaw: на Windows по UTF-16 пути (char*
// путь LibRaw понимает в кодировке ANSI - кириллица ломалась бы)
fn open_path(lr &C.libraw_data_t, path string) int {
	return C.libraw_open_wfile(lr, path.to_wide())
}
