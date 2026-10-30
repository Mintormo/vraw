// «Показать в папке» под Windows: SHOpenFolderAndSelectItems - Проводник
// открывает папку и выделяет в ней файлы. folder - папка, files - n
// путей файлов этой папки. 0 - успех, иначе HRESULT или -1.
#ifndef VRAW_REVEAL_WIN_H
#define VRAW_REVEAL_WIN_H
#include <windows.h>
#include <objbase.h>
#include <shlobj.h>
#include <stdlib.h>

static int vr_reveal_w(const wchar_t *folder, const wchar_t **files, int n) {
	// COM в этом потоке: уже инициализирован (SDL) - S_FALSE или
	// RPC_E_CHANGED_MODE, тоже годится
	HRESULT init = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
	PIDLIST_ABSOLUTE dir = ILCreateFromPathW(folder);
	if (dir == NULL) {
		if (SUCCEEDED(init)) {
			CoUninitialize();
		}
		return -1;
	}
	PIDLIST_ABSOLUTE *full = (PIDLIST_ABSOLUTE *)calloc(n > 0 ? n : 1, sizeof(PIDLIST_ABSOLUTE));
	PCUITEMID_CHILD *items = (PCUITEMID_CHILD *)calloc(n > 0 ? n : 1, sizeof(PCUITEMID_CHILD));
	int k = 0;
	for (int i = 0; full != NULL && items != NULL && i < n; i++) {
		full[k] = ILCreateFromPathW(files[i]);
		if (full[k] != NULL) {
			items[k] = ILFindLastID(full[k]);
			k++;
		}
	}
	HRESULT hr = (items != NULL) ? SHOpenFolderAndSelectItems(dir, (UINT)k, items, 0) : E_OUTOFMEMORY;
	for (int i = 0; i < k; i++) {
		ILFree(full[i]);
	}
	free(full);
	free((void *)items);
	ILFree(dir);
	if (SUCCEEDED(init)) {
		CoUninitialize();
	}
	return SUCCEEDED(hr) ? 0 : (int)hr;
}
#endif
