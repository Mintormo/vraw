// Корзина Windows: SHFileOperationW с FOF_ALLOWUNDO - файл уходит в
// корзину, как из Проводника. pFrom - список путей, оканчивается двумя
// нулями. 0 - успех.
#ifndef VRAW_TRASH_WIN_H
#define VRAW_TRASH_WIN_H
#include <windows.h>
#include <shellapi.h>
#include <stdlib.h>
#include <wchar.h>

static int vr_trash_w(const wchar_t *path) {
	size_t n = wcslen(path);
	wchar_t *buf = (wchar_t *)calloc(n + 2, sizeof(wchar_t));
	if (buf == NULL) {
		return -1;
	}
	memcpy(buf, path, n * sizeof(wchar_t));
	SHFILEOPSTRUCTW op;
	memset(&op, 0, sizeof(op));
	op.wFunc = FO_DELETE;
	op.pFrom = buf;
	op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI;
	int rc = SHFileOperationW(&op);
	if (rc == 0 && op.fAnyOperationsAborted) {
		rc = -2;
	}
	free(buf);
	return rc;
}
#endif
