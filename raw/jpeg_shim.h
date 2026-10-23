// Декодирование JPEG через libjpeg(-turbo) в буфер вызывающего. Ошибки
// libjpeg - longjmp, поэтому setjmp и весь разбор здесь, в C.
#include <stdio.h>
#include <setjmp.h>
#include <jpeglib.h>

struct vraw_jpeg_err {
	struct jpeg_error_mgr mgr;
	jmp_buf jump;
};

static void vraw_jpeg_exit(j_common_ptr cinfo) {
	struct vraw_jpeg_err *e = (struct vraw_jpeg_err *)cinfo->err;
	longjmp(e->jump, 1);
}

static void vraw_jpeg_quiet(j_common_ptr cinfo) { (void)cinfo; }

// out == NULL - только размер (w, h). Иначе out - w*h*3 байт RGB.
// 0 - успех.
static int vraw_jpeg_decode(const unsigned char *data, unsigned long len, int *w, int *h,
	unsigned char *out) {
	struct jpeg_decompress_struct ci;
	struct vraw_jpeg_err err;
	ci.err = jpeg_std_error(&err.mgr);
	err.mgr.error_exit = vraw_jpeg_exit;
	err.mgr.output_message = vraw_jpeg_quiet;
	if (setjmp(err.jump)) {
		jpeg_destroy_decompress(&ci);
		return 1;
	}
	jpeg_create_decompress(&ci);
	jpeg_mem_src(&ci, data, len);
	if (jpeg_read_header(&ci, TRUE) != JPEG_HEADER_OK) {
		jpeg_destroy_decompress(&ci);
		return 2;
	}
	ci.out_color_space = JCS_RGB;
	jpeg_calc_output_dimensions(&ci);
	if (out == NULL) {
		*w = (int)ci.output_width;
		*h = (int)ci.output_height;
		jpeg_destroy_decompress(&ci);
		return 0;
	}
	if ((int)ci.output_width != *w || (int)ci.output_height != *h) {
		jpeg_destroy_decompress(&ci);
		return 3;
	}
	jpeg_start_decompress(&ci);
	unsigned long stride = (unsigned long)ci.output_width * 3;
	while (ci.output_scanline < ci.output_height) {
		JSAMPROW row = out + stride * ci.output_scanline;
		jpeg_read_scanlines(&ci, &row, 1);
	}
	jpeg_finish_decompress(&ci);
	jpeg_destroy_decompress(&ci);
	return 0;
}
