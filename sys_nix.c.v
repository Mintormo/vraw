module main

import os

// Системное для Linux (Windows - sys_windows.c.v): свободная память и
// приоритет потока экспорта (batch.v).

#include <sys/resource.h>
#include <unistd.h>

fn C.setpriority(which int, who u32, prio int) int
fn C.gettid() int

// mem_available - MemAvailable из /proc/meminfo, байт (0 - неизвестно)
fn mem_available() i64 {
	s := os.read_file('/proc/meminfo') or { return 0 }
	for l in s.split_into_lines() {
		if l.starts_with('MemAvailable:') {
			return l.all_after(':').trim_space().all_before(' ').i64() * 1024
		}
	}
	return 0
}

// lower_thread_priority - nice вызывающего потока (1..19, больше -
// уступчивее); созданные им потоки наследуют
fn lower_thread_priority(nice int) {
	C.setpriority(0, u32(C.gettid()), nice) // 0 - PRIO_PROCESS: для потока по tid
}
