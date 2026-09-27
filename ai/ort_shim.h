// Тонкая прослойка vraw к ONNX Runtime C API. C API ORT - таблица
// указателей на функции (OrtApi), из V её звать неудобно, поэтому здесь
// четыре простые функции: открыть модель, прогнать тензор, закрыть, текст
// последней ошибки. Модель - один вход и один выход float32 NCHW
// (1 x 3 x h x w), имена берутся из самой модели.
#ifndef VRAW_ORT_SHIM_H
#define VRAW_ORT_SHIM_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <onnxruntime_c_api.h>

typedef struct VrModel {
	OrtEnv *env;
	OrtSession *sess;
	OrtMemoryInfo *mem;
	char *in_name;
	char *out_name;
} VrModel;

static const OrtApi *vr_ort_api(void) {
	static const OrtApi *api = NULL;
	if (api == NULL) {
		api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
	}
	return api;
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

static void vr_model_close(VrModel *m) {
	if (m == NULL) {
		return;
	}
	const OrtApi *api = vr_ort_api();
	free(m->in_name);
	free(m->out_name);
	if (m->mem) api->ReleaseMemoryInfo(m->mem);
	if (m->sess) api->ReleaseSession(m->sess);
	if (m->env) api->ReleaseEnv(m->env);
	free(m);
}

// vr_model_open - NULL при ошибке (текст - в err)
static VrModel *vr_model_open(const char *path, char *err, int err_len) {
	const OrtApi *api = vr_ort_api();
	if (api == NULL) {
		snprintf(err, err_len, "ONNX Runtime: несовместимая версия библиотеки");
		return NULL;
	}
	VrModel *m = (VrModel *)calloc(1, sizeof(VrModel));
	OrtSessionOptions *opts = NULL;
	OrtAllocator *alloc = NULL;
	char *name = NULL;
	if (vr_take_error(api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "vraw", &m->env), err, err_len)) goto fail;
	if (vr_take_error(api->CreateSessionOptions(&opts), err, err_len)) goto fail;
	if (vr_take_error(api->SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL), err, err_len)) goto fail;
	if (vr_take_error(api->CreateSession(m->env, path, opts, &m->sess), err, err_len)) goto fail;
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
