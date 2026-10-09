module raw

fn C.libraw_open_file(lr &C.libraw_data_t, path &char) int

// open_path - открыть файл в LibRaw (Windows - open_windows.c.v)
fn open_path(lr &C.libraw_data_t, path string) int {
	return C.libraw_open_file(lr, path.str)
}
