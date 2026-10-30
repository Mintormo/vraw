module main

// «Показать в папке» под Windows (Linux - reveal_nix.c.v): Проводник
// открывает папку кадра и выделяет его (reveal_win.h). Под Windows не
// проверено.
import os
import i18n

#flag windows -lshell32 -lole32
#include "@VMODROOT/reveal_win.h"

fn C.vr_reveal_w(folder &u16, files &&u16, n int) int

// reveal_in_folder - показать файлы paths (из одной папки) в Проводнике
fn reveal_in_folder(paths []string) ! {
	if paths.len == 0 {
		return
	}
	dir := os.dir(os.real_path(paths[0])).replace('/', '\\')
	files := paths.map(os.real_path(it).replace('/', '\\').to_wide())
	rc := C.vr_reveal_w(dir.to_wide(), unsafe { &&u16(files.data) }, files.len)
	if rc != 0 {
		return error(i18n.trf('Проводник не открылся (код {0})', '${rc}'))
	}
}
