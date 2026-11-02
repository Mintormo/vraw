module bigbuf

#include <sys/mman.h>

fn C.mmap(addr voidptr, length uint, prot int, flags int, fd int, offset i64) voidptr
fn C.munmap(addr voidptr, length uint) int

// os_alloc - bytes обнулённой памяти анонимным mmap (nil - нет памяти)
fn os_alloc(bytes uint) voidptr {
	p := C.mmap(unsafe { nil }, bytes, C.PROT_READ | C.PROT_WRITE, C.MAP_PRIVATE | C.MAP_ANONYMOUS,
		-1, 0)
	if int(p) == -1 { // MAP_FAILED
		return unsafe { nil }
	}
	return p
}

fn os_free(p voidptr, bytes uint) {
	C.munmap(p, bytes)
}
