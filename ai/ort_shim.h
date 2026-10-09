// Тонкая прослойка vraw к ONNX Runtime C API. C API ORT - таблица
// указателей на функции (OrtApi), из V её звать неудобно, поэтому здесь
// простые функции: загрузить библиотеку, открыть модель, прогнать тензор,
// закрыть. Модель - один вход и один выход float32 NCHW (1 x 3 x h x w),
// имена берутся из самой модели.
//
// Библиотека ORT не линкуется, а грузится dlopen по пути (vr_ort_load):
// её можно скачать в папку рядом с программой, и без неё vraw работает.
// Нужен ровно один символ - OrtGetApiBase, остальное - через таблицу.
// Заголовки - в ai/include (из официальной сборки 1.30, MIT).
#ifndef VRAW_ORT_SHIM_H
#define VRAW_ORT_SHIM_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "onnxruntime_c_api.h"

typedef struct VrModel {
	OrtSession *sess;
	OrtMemoryInfo *mem;
	char *in_name;
	char *out_name;
} VrModel;

// Таблица API и общая среда ORT (одна на процесс, на все модели).
// Пишутся один раз в vr_ort_load - вызывающий (ai.load_runtime) держит мьютекс.
static const OrtApi *vr_api = NULL;
static OrtEnv *vr_env = NULL;

static const OrtApi *vr_ort_api(void) {
	return vr_api;
}

// vr_take_error - текст ошибки ORT в buf (status освобождается); 1 - была ошибка
static int vr_take_error(OrtStatus *st, char *buf, int buf_len) {
	if (st == NULL) {
		return 0;
	}
	const OrtApi *api = vr_ort_api();
	snprintf(buf, buf_len, "%s", api->GetErrorMessage(st));
	api->ReleaseStatus(st);
	return 1;
}

typedef const OrtApiBase *(*VrGetApiBase)(void);

// Загрузка библиотеки: dlopen, на Windows - LoadLibraryExW. Пути из V -
// UTF-8; Windows ждёт UTF-16 (и путь модели для CreateSession там тоже
// wchar_t - ORTCHAR_T).
#ifdef _WIN32
#include <windows.h>

// vr_wide - UTF-8 -> UTF-16 (malloc; NULL - ошибка)
static wchar_t *vr_wide(const char *s) {
	int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
	if (n <= 0) {
		return NULL;
	}
	wchar_t *w = (wchar_t *)malloc(n * sizeof(wchar_t));
	MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
	return w;
}

// Зависимости (onnxruntime_providers_shared.dll) ищутся в папке самой
// библиотеки - LOAD_WITH_ALTERED_SEARCH_PATH
static void *vr_dlopen(const char *path, char *err, int err_len) {
	wchar_t *w = vr_wide(path);
	HMODULE h = w ? LoadLibraryExW(w, NULL, LOAD_WITH_ALTERED_SEARCH_PATH) : NULL;
	free(w);
	if (h == NULL) {
		DWORD code = GetLastError();
		if (code == ERROR_MOD_NOT_FOUND) {
			// сама библиотека есть (путь проверен в V) - нет её зависимостей
			snprintf(err, err_len, "не найдены библиотеки, нужные ONNX Runtime: установите "
				"Microsoft Visual C++ Redistributable (x64) - https://aka.ms/vs/17/release/vc_redist.x64.exe");
		} else {
			snprintf(err, err_len, "LoadLibrary: ошибка %lu", (unsigned long)code);
		}
	}
	return (void *)h;
}
#define vr_dlsym(h, name) ((void *)GetProcAddress((HMODULE)(h), name))
#define vr_dlclose(h) FreeLibrary((HMODULE)(h))
#else
#include <dlfcn.h>

static void *vr_dlopen(const char *path, char *err, int err_len) {
	void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (h == NULL) {
		snprintf(err, err_len, "%s", dlerror());
	}
	return h;
}
#define vr_dlsym(h, name) dlsym(h, name)
#define vr_dlclose(h) dlclose(h)
#endif

// vr_ort_load - загрузить библиотеку ORT по пути; 0 - успех (или уже
// загружена), иначе текст ошибки в err
static int vr_ort_load(const char *path, char *err, int err_len) {
	if (vr_api != NULL) {
		return 0;
	}
	void *h = vr_dlopen(path, err, err_len);
	if (h == NULL) {
		return 1;
	}
	VrGetApiBase get_base = (VrGetApiBase)vr_dlsym(h, "OrtGetApiBase");
	if (get_base == NULL) {
		snprintf(err, err_len, "в библиотеке нет OrtGetApiBase");
		vr_dlclose(h);
		return 1;
	}
	const OrtApi *api = get_base()->GetApi(ORT_API_VERSION);
	if (api == NULL) {
		snprintf(err, err_len, "несовместимая версия библиотеки (нужен API %d)", ORT_API_VERSION);
		vr_dlclose(h);
		return 1;
	}
	OrtEnv *env = NULL;
	OrtStatus *st = api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "vraw", &env);
	if (st != NULL) {
		snprintf(err, err_len, "%s", api->GetErrorMessage(st));
		api->ReleaseStatus(st);
		vr_dlclose(h);
		return 1;
	}
	// Библиотека остаётся загруженной до конца процесса
	vr_env = env;
	vr_api = api;
	return 0;
}

static void vr_model_close(VrModel *m) {
	if (m == NULL) {
		return;
	}
	const OrtApi *api = vr_ort_api();
	free(m->in_name);
	free(m->out_name);
	if (m->mem) api->ReleaseMemoryInfo(m->mem);
	if (m->sess) api->ReleaseSession(m->sess);
	free(m);
}

// vr_model_open - NULL при ошибке (текст - в err)
static VrModel *vr_model_open(const char *path, char *err, int err_len) {
	const OrtApi *api = vr_ort_api();
	if (api == NULL) {
		snprintf(err, err_len, "ONNX Runtime не загружен");
		return NULL;
	}
	VrModel *m = (VrModel *)calloc(1, sizeof(VrModel));
	OrtSessionOptions *opts = NULL;
	OrtAllocator *alloc = NULL;
	char *name = NULL;
	if (vr_take_error(api->CreateSessionOptions(&opts), err, err_len)) goto fail;
	if (vr_take_error(api->SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL), err, err_len)) goto fail;
#ifdef _WIN32
	wchar_t *wpath = vr_wide(path);
	OrtStatus *st = api->CreateSession(vr_env, wpath, opts, &m->sess);
	free(wpath);
#else
	OrtStatus *st = api->CreateSession(vr_env, path, opts, &m->sess);
#endif
	if (vr_take_error(st, err, err_len)) goto fail;
	api->ReleaseSessionOptions(opts);
	opts = NULL;
	if (vr_take_error(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &m->mem), err, err_len)) goto fail;
	if (vr_take_error(api->GetAllocatorWithDefaultOptions(&alloc), err, err_len)) goto fail;
	if (vr_take_error(api->SessionGetInputName(m->sess, 0, alloc, &name), err, err_len)) goto fail;
	m->in_name = strdup(name);
	api->AllocatorFree(alloc, name);
	if (vr_take_error(api->SessionGetOutputName(m->sess, 0, alloc, &name), err, err_len)) goto fail;
	m->out_name = strdup(name);
	api->AllocatorFree(alloc, name);
	return m;
fail:
	if (opts) api->ReleaseSessionOptions(opts);
	vr_model_close(m);
	return NULL;
}

// vr_model_run - in и out: 3*h*w float (планарно RGB); 0 - успех
static int vr_model_run(VrModel *m, float *in, float *out, int h, int w, char *err, int err_len) {
	const OrtApi *api = vr_ort_api();
	int64_t shape[4] = {1, 3, h, w};
	size_t bytes = (size_t)3 * h * w * sizeof(float);
	OrtValue *iv = NULL;
	OrtValue *ov = NULL;
	int rc = 1;
	if (vr_take_error(api->CreateTensorWithDataAsOrtValue(m->mem, in, bytes, shape, 4,
			ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &iv), err, err_len)) goto done;
	if (vr_take_error(api->CreateTensorWithDataAsOrtValue(m->mem, out, bytes, shape, 4,
			ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &ov), err, err_len)) goto done;
	const char *in_names[1] = {m->in_name};
	const char *out_names[1] = {m->out_name};
	if (vr_take_error(api->Run(m->sess, NULL, in_names, (const OrtValue *const *)&iv, 1,
			out_names, 1, &ov), err, err_len)) goto done;
	rc = 0;
done:
	if (iv) api->ReleaseValue(iv);
	if (ov) api->ReleaseValue(ov);
	return rc;
}

#endif
