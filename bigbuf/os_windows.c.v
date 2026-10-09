module bigbuf

#include <windows.h>

fn C.VirtualAlloc(addr voidptr, size usize, alloc_type u32, protect u32) voidptr
fn C.VirtualFree(addr voidptr, size usize, free_type u32) int

// os_alloc - bytes обнулённой памяти VirtualAlloc (nil - нет памяти)
fn os_alloc(bytes usize) voidptr {
	return C.VirtualAlloc(unsafe { nil }, bytes, C.MEM_COMMIT | C.MEM_RESERVE, C.PAGE_READWRITE)
}

fn os_free(p voidptr, _ usize) {
	C.VirtualFree(p, 0, C.MEM_RELEASE)
}
