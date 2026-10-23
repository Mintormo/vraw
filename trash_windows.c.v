module main

// Корзина Windows - системная (как «Удалить» в Проводнике): trash_win.h
import os
import i18n

#flag windows -lshell32
#include "@VMODROOT/trash_win.h"

fn C.vr_trash_w(path &u16) int

// move_to_trash - переместить файл в корзину
fn move_to_trash(path string) ! {
	abs := os.real_path(path).replace('/', '\\')
	rc := C.vr_trash_w(abs.to_wide())
	if rc != 0 {
		return error(i18n.trf('не удалось переместить в корзину (код {0})', '${rc}'))
	}
}
