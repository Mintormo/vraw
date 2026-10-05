module main

// «Вид - JPEG камеры» (K): вместо проявки - встроенный JPEG камеры этого
// кадра, для сравнения (цвет, тон, кадр). JPEG декодирует загрузчик
// (он и так нужен для «как JPEG»), вписанный в размер превью до
// геометрии (LoadResult.cam_view); показ - с геометрией кадра
// (кадрирование, поворот) и в размер холста, как превью. Гистограмма -
// по JPEG. Это вид, не правка: ползунки работают, при выключении -
// обычная проявка.
import vgui
import pipeline

// jpeg_active - JPEG показывается: включён и есть, не кадрирование, не
// показ дымки и резкости
fn jpeg_active(st &State) bool {
	return st.jpeg_show && st.cam_view.len == st.pw * st.ph * 4 && st.pw > 0 && !st.crop_mode
		&& !st.haze_show && !st.sharp_show && st.sharp_drag == .off
}

// jpeg_pixels - JPEG камеры в холст gw x gh с геометрией кадра
fn jpeg_pixels(st &State) []u8 {
	return pipeline.geom_rgba(st.cam_view, st.pw, st.ph, st.edit.geom, true, st.gw, st.gh)
}

// set_jpeg_show - вкл/выкл (K, меню «Вид»); без JPEG - сообщение
fn set_jpeg_show(mut st State, on bool) {
	st.jpeg_show = on
	if !isnil(st.m_jpeg) {
		mut m := st.m_jpeg
		m.checked = on
	}
	if on && st.pw > 0 && st.cam_view.len != st.pw * st.ph * 4 && !isnil(st.nm) {
		mut nm := st.nm
		nm.show_info('У этого кадра нет встроенного JPEG')
	}
	if !isnil(st.tone_fx) {
		st.tone_fx()
	}
}

// jpeg_overlay - подпись «JPEG камеры» поверх снимка
fn jpeg_overlay(st &State, mut ctx vgui.RenderContext) {
	if !jpeg_active(st) || isnil(st.cv) {
		return
	}
	x0, y0 := st.cv.buf_to_screen(0, 0)
	ba_label(mut ctx, 'JPEG камеры', x0 + 10, y0 + 10)
}
