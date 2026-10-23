module main

// Диалоги не больше экрана. Содержимое каждого диалога vraw лежит в
// ScrollBox (dialog_scroll) с размером по содержимому (fit_content), а
// размер окна считает vgui при каждом показе (Dialog.show): по
// содержимому (или заданный при создании), но не больше свободного места
// на экране родителя при текущем масштабе интерфейса; не влезло -
// прокрутка, окно шире на её полосу. Смена масштаба при открытом диалоге -
// Dialog.refit (uiscale.v).
import vgui

// dialog_scroll - корень диалога: содержимое в прокрутке (если места
// хватает, ScrollBox растягивает его на всё окно - flex работает как
// прежде)
fn dialog_scroll(content &vgui.Widget) &vgui.ScrollBox {
	mut sb := vgui.scroll_box(0)
	sb.pad = 0
	sb.fit_content = true
	sb.add(content)
	return sb
}
