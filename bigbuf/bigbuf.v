module bigbuf

// Большие пиксельные буферы ВНЕ сборщика мусора.
//
// Boehm (сборщик V) освобождённую память системе не отдаёт: после экспорта
// полного кадра (пик ~2 ГБ временных плоскостей) процесс так и оставался
// при ~1.8 ГБ, а куча росла с каждым экспортом. Буфер отсюда - обычный
// массив V, но данные лежат в анонимном mmap: free() сразу возвращает их
// системе (munmap), сборщик их не видит и не сканирует (указателей в
// пиксельных данных нет).
//
// Правила: буфер освобождать ровно один раз (free), после этого ни сам
// массив, ни его копии не трогать. Расти буфер не может (nogrow: `<<`
// - паника, а не тихая порча), clone() даёт обычный массив сборщика.
// Удобно для временных плоскостей внутри функции:
//   mut tmp := bigbuf.new_f32(n)
//   defer { bigbuf.free(mut tmp) }
//
// Выделение у системы - os_alloc/os_free: mmap (os_nix.c.v), на Windows
// VirtualAlloc (os_windows.c.v); память в обоих случаях обнулена.

// alloc - массив из n нулевых элементов T в своём mmap
fn alloc[T](n int) []T {
	mut a := []T{}
	if n <= 0 {
		return a
	}
	bytes := usize(n) * sizeof(T)
	p := os_alloc(bytes)
	if p == unsafe { nil } {
		panic('bigbuf: нет памяти на ${bytes >> 20} МБ')
	}
	unsafe {
		a.data = p
		a.len = n
		a.cap = n
		a.flags = ArrayFlags.nofree | .nogrow | .noslices
	}
	return a
}

// new_f32 - n нулей f32 вне сборщика (освобождать free)
pub fn new_f32(n int) []f32 {
	return alloc[f32](n)
}

// new_u16 - n нулей u16 вне сборщика (освобождать free)
pub fn new_u16(n int) []u16 {
	return alloc[u16](n)
}

// new_u8 - n нулей u8 вне сборщика (освобождать free)
pub fn new_u8(n int) []u8 {
	return alloc[u8](n)
}

// is_big - массив выделен здесь (а не сборщиком)
pub fn is_big[T](a []T) bool {
	f := u32(a.flags)
	return a.cap > 0 && f & u32(ArrayFlags.nofree) != 0 && f & u32(ArrayFlags.nogrow) != 0
		&& f & u32(ArrayFlags.managed) == 0
}

// free - вернуть память буфера системе; массив становится пустым.
// Обычный массив сборщика (не отсюда) просто забывается - так можно
// освобождать результат, который бывает и тем, и другим.
pub fn free[T](mut a []T) {
	if is_big(a) {
		os_free(a.data, usize(a.cap) * sizeof(T))
	}
	a = []T{}
}
