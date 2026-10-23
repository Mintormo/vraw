module main

// Системное для Windows (Linux - sys_nix.c.v): свободная память и
// приоритет потока экспорта (batch.v).

#include <windows.h>

@[typedef]
struct C.MEMORYSTATUSEX {
mut:
	dwLength     u32
	ullAvailPhys u64
}

fn C.GlobalMemoryStatusEx(st &C.MEMORYSTATUSEX) int
fn C.SetThreadPriority(h voidptr, prio int) int
fn C.GetCurrentThread() voidptr

// mem_available - свободная физическая память, байт (0 - неизвестно)
fn mem_available() i64 {
	mut st := C.MEMORYSTATUSEX{}
	st.dwLength = u32(sizeof(C.MEMORYSTATUSEX))
	if C.GlobalMemoryStatusEx(&st) == 0 {
		return 0
	}
	return i64(st.ullAvailPhys)
}

// lower_thread_priority - понизить приоритет вызывающего потока по шкале
// nice (1..19): от 15 - самый низкий, иначе - ниже обычного. В Windows
// созданные потоком потоки приоритет не наследуют.
fn lower_thread_priority(nice int) {
	prio := if nice >= 15 { C.THREAD_PRIORITY_LOWEST } else { C.THREAD_PRIORITY_BELOW_NORMAL }
	C.SetThreadPriority(C.GetCurrentThread(), prio)
}
