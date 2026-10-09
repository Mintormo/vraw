module main

// Размер диалога: влезает - как просит содержимое; выше экрана - по
// экрану и шире на полосу прокрутки; шире экрана - по экрану; место
// неизвестно (0) - без предела
fn test_dialog_size() {
	mut w, mut h := dialog_size(500, 400, 1000, 600, 14)
	assert w == 500 && h == 400
	w, h = dialog_size(500, 839, 1000, 624, 14)
	assert w == 514 && h == 624
	w, h = dialog_size(1200, 400, 1000, 600, 14)
	assert w == 1000 && h == 400
	w, h = dialog_size(500.2, 400.5, 0, 0, 14)
	assert w == 501 && h == 401
}

// SDL_Rect - четыре int C (32 бита): своя структура той же раскладки
fn test_disp_rect_layout() {
	assert sizeof(DispRect) == 16
}
