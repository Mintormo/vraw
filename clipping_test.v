module main

// Показ пересветов и провалов (clipping.v): подсветка, треугольники, щелчки
import vgui

fn px(r u8, g u8, b u8) []u8 {
	return [r, g, b, u8(255)]
}

fn test_mark_clipping() {
	mut pix := []u8{}
	pix << px(255, 120, 90) // пересвет по R
	pix << px(10, 0, 30) // провал по G
	pix << px(255, 255, 0) // оба края - считается пересветом
	pix << px(128, 128, 128) // норма
	orig := pix.clone()
	mut a := pix.clone()
	mark_clipping(mut a, true, true)
	assert a[0..3] == [clip_hi_color.r, clip_hi_color.g, clip_hi_color.b]
	assert a[4..7] == [clip_lo_color.r, clip_lo_color.g, clip_lo_color.b]
	assert a[8..11] == [clip_hi_color.r, clip_hi_color.g, clip_hi_color.b]
	assert a[12..16] == orig[12..16]
	assert a[3] == 255 && a[7] == 255 // альфа цела
	// Только пересветы: провал не трогается
	mut h := pix.clone()
	mark_clipping(mut h, true, false)
	assert h[4..8] == orig[4..8]
	assert h[0] == clip_hi_color.r
	// Только провалы: у пикселя с 255 и 0 - синий
	mut l := pix.clone()
	mark_clipping(mut l, false, true)
	assert l[0..4] == orig[0..4]
	assert l[8..11] == [clip_lo_color.r, clip_lo_color.g, clip_lo_color.b]
	// Выключено - ничего
	mut n := pix.clone()
	mark_clipping(mut n, false, false)
	assert n == orig
}

fn test_clip_hit_and_marks() {
	assert clip_hit_test(3, 3, 256) == -1
	assert clip_hit_test(250, 5, 256) == 1
	assert clip_hit_test(128, 5, 256) == 0
	assert clip_hit_test(3, 60, 256) == 0
	mut hist := vgui.canvas(256, 100)
	hist.fill(vgui.Color{16, 16, 18, 255})
	// Есть пересвет, показ провалов включён: правый - красный, левый -
	// серый с белой обводкой
	dp := make_palette(vgui.dark_theme())
	draw_clip_marks(mut hist, true, false, false, true, dp)
	at := fn [hist] (x int, y int) []u8 {
		k := (y * 256 + x) * 4
		return hist.pixels[k..k + 3]
	}
	inner := clip_tri_pad + 2
	assert at(inner, inner) == [dp.clip_idle.r, dp.clip_idle.g, dp.clip_idle.b]
	assert at(clip_tri_pad, clip_tri_pad) == [u8(255), 255, 255]
	assert at(255 - inner, inner) == [clip_hi_color.r, clip_hi_color.g, clip_hi_color.b]
	assert at(255 - clip_tri_pad, clip_tri_pad) == [clip_hi_color.r, clip_hi_color.g,
		clip_hi_color.b]
	assert at(128, 50) == [u8(16), 16, 18]
}

// Цвета гистограммы под тему: в тёмной - прежние (почти чёрный фон,
// почти белое пересечение каналов), в светлой - фон светлый, а столбцы
// и обводка треугольника - тёмнее фона (видны)
fn test_hist_theme_colors() {
	dp := make_palette(vgui.dark_theme())
	assert dp.hist[0].r < 30 && dp.hist[7].r > 200
	assert dp.hist[1] == vgui.Color{224, dp.hist[0].g, dp.hist[0].b, 255}
	lp := make_palette(vgui.light_theme())
	bg := lp.hist[0]
	assert bg.r > 200 && bg.g > 200 && bg.b > 200
	for m in 1 .. 8 {
		c := lp.hist[m]
		assert int(c.r) + c.g + c.b < int(bg.r) + bg.g + bg.b - 150
	}
	assert int(lp.clip_ring.r) + lp.clip_ring.g + lp.clip_ring.b < 200
	// Отрисовка: столбец красного канала - цветом R палитры, фон - фоном
	mut hist := vgui.canvas(256, 100)
	mut hr := []u32{len: 256}
	hr[100] = 10
	z := []u32{len: 256}
	draw_histogram(mut hist, HistBins{ r: hr, g: z, b: z, y: z }, HistLook{}, lp)
	k := (99 * 256 + 100) * 4
	assert hist.pixels[k..k + 3] == [lp.hist[1].r, lp.hist[1].g, lp.hist[1].b]
	assert hist.pixels[0..3] == [bg.r, bg.g, bg.b]
}
