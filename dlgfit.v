module main

// Диалоги не больше экрана. Содержимое каждого диалога vraw лежит в
// ScrollBox (dialog_scroll), размер окна считается здесь перед каждым
// показом (show_dialog): по содержимому (или заданный), но не больше
// свободного места на экране родителя при текущем масштабе интерфейса;
// не влезло - прокрутка. Режим vgui «по содержимому» (auto_size) не
// годится: ScrollBox на вопрос о размере всегда отвечает 160 px. При
// большом масштабе (uiscale.v) и маленьком экране окно настроек иначе
// уходило низом за край вместе с «Закрыть».
import vgui

// Не vgui - своё объявление; заголовок SDL подключает vgui. C.SDL_Rect
// vgui закрыт для других модулей - своя структура той же раскладки:
// поля i32, как int в C (int V здесь 64-битный - SDL писал в первые
// два поля, w и h оставались нулями)
fn C.SDL_GetDisplayUsableBounds(id u32, rect voidptr) bool

struct DispRect {
	x i32
	y i32
	w i32
	h i32
}

// Запас под рамку и заголовок окна, px экрана
const dlg_margin_w = 40
const dlg_margin_h = 80

// dialog_scroll - корень диалога: содержимое в прокрутке (если места
// хватает, ScrollBox растягивает его на всё окно - flex работает как
// прежде)
fn dialog_scroll(content &vgui.Widget) &vgui.ScrollBox {
	mut sb := vgui.scroll_box(0)
	sb.pad = 0
	sb.add(content)
	return sb
}

// screen_room - свободное место на экране окна w в логических px vgui
// при масштабе s; 0, 0 - неизвестно (тогда без ограничения)
fn screen_room(w &vgui.Window, s f32) (f32, f32) {
	if isnil(w) || isnil(w.sdl_window) || s <= 0 {
		return 0, 0
	}
	id := C.SDL_GetDisplayForWindow(w.sdl_window)
	if id == 0 {
		return 0, 0
	}
	mut r := DispRect{}
	if !C.SDL_GetDisplayUsableBounds(id, &r) {
		return 0, 0
	}
	return f32(int(r.w) - dlg_margin_w) / s, f32(int(r.h) - dlg_margin_h) / s
}

// dialog_size - логический размер диалога: желаемый (want - по
// содержимому, если 0) в пределах room (0 - без предела); не влезло по
// высоте - шире на полосу прокрутки
fn dialog_size(want_w f32, want_h f32, room_w f32, room_h f32, sb_w f32) (int, int) {
	mut w := want_w
	mut h := want_h
	if room_h > 0 && h > room_h {
		h = room_h
		w += sb_w
	}
	if room_w > 0 && w > room_w {
		w = room_w
	}
	return int(w + 0.999), int(h + 0.999)
}

// fit_dialog - размер диалога d с корнем sb (dialog_scroll) при масштабе
// s: want_w×want_h или по содержимому (0), не больше экрана parent
fn fit_dialog(mut d vgui.Dialog, sb &vgui.ScrollBox, parent &vgui.Window, s f32, want_w int, want_h int) {
	if sb.children.len == 0 {
		return
	}
	hint := vgui.measure_widget(sb.children[0], &d.win.ctx)
	ww := if want_w > 0 { f32(want_w) } else { hint.w }
	wh := if want_h > 0 { f32(want_h) } else { hint.h }
	rw, rh := screen_room(parent, s)
	w, h := dialog_size(ww, wh, rw, rh, 14) // 14 - полоса ScrollBox
	d.auto_size = false
	d.base_width = w
	d.base_height = h
	d.win.config.width = w
	d.win.config.height = h
}

// show_dialog - показать диалог по размеру (fit_dialog) с масштабом
// главного окна
fn show_dialog(mut d vgui.Dialog, sb &vgui.ScrollBox, parent &vgui.Window, want_w int, want_h int) {
	if d.is_open() {
		return
	}
	s := if parent.ctx.ui_scale > 0 { parent.ctx.ui_scale } else { f32(1) }
	fit_dialog(mut d, sb, parent, s, want_w, want_h)
	d.show_scaled(parent)
}

// rescale_dialog - открытый диалог под новый масштаб s (смена масштаба
// из него самого): размер заново, по центру экрана родителя
fn rescale_dialog(mut d vgui.Dialog, sb &vgui.ScrollBox, parent &vgui.Window, s f32, want_w int, want_h int) {
	fit_dialog(mut d, sb, parent, s, want_w, want_h)
	pw := int(f32(d.base_width) * s + 0.5)
	ph := int(f32(d.base_height) * s + 0.5)
	// Размер диалога vgui закреплён (минимум = максимум) - сначала
	// пределы, иначе SDL не даст его изменить
	C.SDL_SetWindowMinimumSize(d.win.sdl_window, pw, ph)
	C.SDL_SetWindowMaximumSize(d.win.sdl_window, pw, ph)
	d.set_ui_scale(s) // окно - config × s, экран окна - config
	id := C.SDL_GetDisplayForWindow(parent.sdl_window)
	pos := int(u32(vgui.sdl_windowpos_centered) | id)
	C.SDL_SetWindowPosition(d.win.sdl_window, pos, pos)
}
