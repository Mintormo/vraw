module bigbuf

#include <windows.h>

fn C.VirtualAlloc(addr voidptr, size uint, alloc_type u32, protect u32) voidptr
fn C.VirtualFree(addr voidptr, size uint, free_type u32) int

// os_alloc - bytes обнулённой памяти VirtualAlloc (nil - нет памяти)
fn os_alloc(bytes uint) voidptr {
	return C.VirtualAlloc(unsafe { nil }, bytes, C.MEM_COMMIT | C.MEM_RESERVE, C.PAGE_READWRITE)
}

fn os_free(p voidptr, _ uint) {
	C.VirtualFree(p, 0, C.MEM_RELEASE)
}
