module main

// Автоперспектива на настоящих кадрах (pipeline/upright.v): сырьё
// half-size после объектива, как в окне. Без кадров - пропуск.
import os
import time
import raw
import lens
import pipeline

fn upright_frame(name string, db &lens.Database) ?([]pipeline.Segment, int, int) {
	path := os.join_path(@VMODROOT, name + '.CR3')
	if !os.exists(path) {
		eprintln('ПРОПУСК: нет ${name}.CR3')
		return none
	}
	mut d := raw.open(path) or { return none }
	defer {
		d.close()
	}
	mut img := d.develop(half: true) or { return none }
	w := img.width
	h := img.height
	mut lin := []u16{len: w * h * 3}
	unsafe { vmemcpy(lin.data, img.data_u16(), w * h * 6) }
	img.free()
	correct_lens(unsafe { &u16(lin.data) }, w, h, d.meta(), db, true, lens.vign_default, 1,
		lens.Manual{})
	sw := time.new_stopwatch()
	segs := pipeline.upright_segments(unsafe { &u16(lin.data) }, w, h, pipeline.Geom{})
	eprintln('${name}: ${segs.len} отрезков за ${sw.elapsed().milliseconds()} мс')
	return segs, w, h
}

fn test_upright_real_frames() {
	db := lens.load_db() or { return }
	// Фасад (RF 24-105 на 105 мм): небольшая «Вертикаль», наклон почти 0
	if segs, w, h := upright_frame('IMG_0991', db) {
		sw := time.new_stopwatch()
		v := pipeline.upright_fit(segs, w, h, .vertical) or { panic('нет линий') }
		eprintln('IMG_0991 вертикали: ${v}, ${sw.elapsed().milliseconds()} мс')
		assert v.pv > 2 && v.pv < 9, '${v}'
		assert v.angle > -1 && v.angle < 1, '${v}'
		l := pipeline.upright_fit(segs, w, h, .level) or { panic('нет линий') }
		assert l.angle > -1 && l.angle < 1, '${l}'
		f := pipeline.upright_fit(segs, w, h, .full) or { panic('нет линий') }
		assert f.pv > 2 && f.pv < 9 && f.angle > -1.5 && f.angle < 1.5, '${f}'
	}
	// Поле без прямых (колея, кромка леса): отказ во всех режимах
	if segs, w, h := upright_frame('IMG_0817', db) {
		for m in [pipeline.UprightMode.level, .vertical, .full] {
			if f := pipeline.upright_fit(segs, w, h, m) {
				assert false, '${m}: ${f}'
			}
		}
	}
	// Интерьер сверху вниз (24 мм): «Уровень» почти 0, «Полностью» не
	// уходит в наклон по столам, уходящим вглубь
	if segs, w, h := upright_frame('IMG_0634', db) {
		l := pipeline.upright_fit(segs, w, h, .level) or { panic('нет линий') }
		assert l.angle > -2 && l.angle < 2, '${l}'
		f := pipeline.upright_fit(segs, w, h, .full) or { panic('нет линий') }
		assert f.angle > -3 && f.angle < 3, '${f}'
		assert f.pv > 50, '${f}'
	}
}
