module main

// Отбор кадров: звёзды 0..5 и флажок (отобран / отклонён) - с этого
// начинается разбор съёмки: пролистать серию, отметить лучшие,
// отфильтровать ленту. Клавиши - пункты меню «Отбор»: 0..5, P, X, U.
// Пометка действует на выделенные в ленте кадры (одиночный щелчок только
// выделяет), без выделения - на открытый. Пометка - не правка: в историю
// не идёт, но живёт в сайдкаре кадра (Mark, sidecar.v) - у открытого
// через sync_sidecar, у прочих через write_mark.
//
// Фильтр ленты (список на полосе над лентой): строки ленты - только
// кадры фильтра, st.shown - номера кадров по строкам. Индексы строк
// ListBox и кадров st.frames поэтому различаются: row_of / frame_of_row.
import os
import math
import vgui
import i18n

const filter_keys = ['all', 'picked', 'unrejected', 'rejected', 'r1', 'r2', 'r3', 'r4', 'r5']
const filter_names = ['Все кадры', 'Отобранные', 'Без отклонённых', 'Отклонённые',
	'От 1 звезды', 'От 2 звёзд', 'От 3 звёзд', 'От 4 звёзд', '5 звёзд']

// Значки на миниатюре: звёзды внизу, флажок слева вверху
const star_color = vgui.Color{250, 200, 70, 255}
const star_ring = vgui.Color{20, 20, 22, 200}
const pick_color = vgui.Color{240, 240, 240, 255}
const reject_color = vgui.Color{235, 80, 70, 255}
const badge_bg = vgui.Color{20, 20, 22, 170}
const reject_shade = vgui.Color{0, 0, 0, 120} // отклонённый кадр - притушен

// mark_passes - кадр с пометкой m проходит фильтр
fn mark_passes(m Mark, filter string) bool {
	return match filter {
		'picked' { m.flag > 0 }
		'unrejected' { m.flag >= 0 }
		'rejected' { m.flag < 0 }
		'r1' { m.rating >= 1 }
		'r2' { m.rating >= 2 }
		'r3' { m.rating >= 3 }
		'r4' { m.rating >= 4 }
		'r5' { m.rating >= 5 }
		else { true }
	}
}

// row_of - строка ленты кадра (-1 - кадр не прошёл фильтр)
fn row_of(st &State, frame int) int {
	return st.shown.index(frame)
}

// frame_of_row - кадр строки ленты (-1 - нет такой строки)
fn frame_of_row(st &State, row int) int {
	return if row >= 0 && row < st.shown.len { st.shown[row] } else { -1 }
}

// next_shown - ближайший к from кадр фильтра в сторону dir (+1/-1);
// from может и не проходить фильтр. -1 - дальше кадров нет.
fn next_shown(st &State, from int, dir int) int {
	if dir > 0 {
		for f in st.shown {
			if f > from {
				return f
			}
		}
	} else {
		for i := st.shown.len - 1; i >= 0; i-- {
			if st.shown[i] < from {
				return st.shown[i]
			}
		}
	}
	return -1
}

// apply_filter - строки ленты заново по фильтру (пересборка ListBox:
// clear + add тех же ячеек). Выделение - снова на открытом кадре.
fn apply_filter(mut st State) {
	st.shown = []int{}
	for i, f in st.frames {
		if mark_passes(f.mark, st.filter) {
			st.shown << i
		}
	}
	if isnil(st.strip) {
		return
	}
	mut strip := st.strip
	strip.clear()
	for i in st.shown {
		if !isnil(st.frames[i].cell) {
			strip.add_item_widget(st.frames[i].cell)
		}
	}
	sync_strip(mut st)
}

// set_filter - фильтр ленты по ключу (список на полосе над лентой)
fn set_filter(mut st State, key string) {
	st.filter = if key in filter_keys { key } else { 'all' }
	if !isnil(st.filter_cb) {
		mut cb := st.filter_cb
		cb.set_selected(filter_keys.index(st.filter))
	}
	apply_filter(mut st)
}

// mark_targets - кадры для пометки: выделенные в ленте, без выделения -
// открытый
fn mark_targets(st &State) []int {
	sel := strip_selection(st)
	if sel.len > 0 {
		return sel
	}
	return if st.frame_idx >= 0 && st.frame_idx < st.frames.len { [st.frame_idx] } else { []int{} }
}

// MarkEdit - что меняет пометка: звёзды или флажок (значение, а не
// замыкание - post.v)
struct MarkEdit {
	rating   int
	flag     int
	set_flag bool // false - меняются звёзды, true - флажок
}

fn (e MarkEdit) apply(m Mark) Mark {
	return if e.set_flag {
		Mark{
			rating: m.rating
			flag:   e.flag
		}
	} else {
		Mark{
			rating: e.rating
			flag:   m.flag
		}
	}
}

// set_mark - пометка кадров mark_targets: change даёт новую пометку из
// старой. Открытый кадр - в st.mark и сайдкар (sync_sidecar), прочие -
// write_mark. Затем фильтр ленты, подпись и (флажок «Переходить к
// следующему») следующий кадр фильтра, если помечали открытый.
fn set_mark(mut st State, change MarkEdit) {
	targets := mark_targets(st)
	if targets.len == 0 {
		if !isnil(st.nm) {
			mut nm := st.nm
			nm.show_warning(i18n.tr('Откройте кадр или выделите кадры в ленте'))
		}
		return
	}
	mut failed := []string{}
	for i in targets {
		m := change.apply(st.frames[i].mark)
		if i == st.frame_idx && st.history.len > 0 {
			st.mark = m
			sync_sidecar(mut st)
		} else {
			write_mark(st.frames[i].path, m) or {
				failed << '${os.file_name(st.frames[i].path)}: ${err.msg()}'
				continue
			}
		}
		st.frames[i].mark = m
		if !isnil(st.frames[i].cv) {
			mut cv := st.frames[i].cv
			cv.mark_dirty()
		}
	}
	if failed.len > 0 && !isnil(st.nm) {
		mut nm := st.nm
		nm.show_error(i18n.trf('Пометка не сохранена: {0}', '${failed[0]}'))
	}
	advance := st.settings.auto_advance && targets == [st.frame_idx]
	if st.filter != 'all' {
		apply_filter(mut st)
	} else {
		strip_info_text(mut st)
	}
	if advance && !isnil(st.goto_frame) {
		next := next_shown(st, st.frame_idx, 1)
		if next >= 0 {
			st.goto_frame(next)
		}
	}
}

fn set_rating(mut st State, r int) {
	set_mark(mut st, MarkEdit{
		rating: r
	})
}

fn set_flag(mut st State, f int) {
	set_mark(mut st, MarkEdit{
		flag:     f
		set_flag: true
	})
}

// mark_text - пометка словами для подписи над лентой (пусто - нет)
fn mark_text(m Mark) string {
	mut parts := []string{}
	if m.rating > 0 {
		parts << '${m.rating} ${i18n.pl(m.rating, 'звезда|звезды|звёзд')}'
	}
	if m.flag > 0 {
		parts << i18n.tr('отобран')
	} else if m.flag < 0 {
		parts << i18n.tr('отклонён')
	}
	return parts.join(', ')
}

// fill_star - залитая пятиконечная звезда с центром (cx, cy) и внешним
// радиусом r: десять треугольников от центра
fn fill_star(mut ctx vgui.RenderContext, cx f32, cy f32, r f32, c vgui.Color) {
	ri := r * 0.45
	mut xs := []f32{len: 10}
	mut ys := []f32{len: 10}
	for k in 0 .. 10 {
		a := f32(k) * f32(3.14159265) / 5 - f32(3.14159265) / 2
		rr := if k % 2 == 0 { r } else { ri }
		xs[k] = cx + rr * math.cosf(a)
		ys[k] = cy + rr * math.sinf(a)
	}
	for k in 0 .. 10 {
		n := (k + 1) % 10
		ctx.fill_triangle(cx, cy, xs[k], ys[k], xs[n], ys[n], c)
	}
}

// draw_thumb_marks - пометка поверх миниатюры (on_overlay её холста, в
// экранных координатах): отклонённый кадр притушен, флажок - слева
// вверху, звёзды - внизу по центру картинки
fn draw_thumb_marks(mut ctx vgui.RenderContext, cv &vgui.Canvas, m Mark) {
	if m == Mark{} {
		return
	}
	x0, y0 := cv.buf_to_screen(0, 0)
	x1, y1 := cv.buf_to_screen(thumb_w, thumb_h)
	w := x1 - x0
	h := y1 - y0
	if w < 20 || h < 14 {
		return
	}
	if m.flag < 0 {
		ctx.fill_rect(vgui.Rect{x0, y0, w, h}, reject_shade)
	}
	// Размер значков - от высоты миниатюры (лента меняет высоту)
	s := if h / 7 < 7 { f32(7) } else if h / 7 > 12 { f32(12) } else { h / 7 }
	if m.flag != 0 {
		bx := x0 + s * 0.5
		by := y0 + s * 0.5
		ctx.fill_rounded_rect(vgui.Rect{bx, by, s * 2.2, s * 2.2}, badge_bg, s * 0.5)
		icon, _ := vgui.icon_codepoint(if m.flag > 0 { 'flag' } else { 'ban' })
		ctx.draw_icon_glyph(icon, vgui.Rect{bx, by, s * 2.2, s * 2.2}, int(s * 1.5),
			if m.flag > 0 { pick_color } else { reject_color })
	}
	if m.rating > 0 {
		step := s * 2.1
		total := step * f32(m.rating)
		bx := x0 + (w - total) / 2
		by := y1 - s * 2.6
		ctx.fill_rounded_rect(vgui.Rect{bx - s * 0.4, by, total + s * 0.8, s * 2.2}, badge_bg,
			s * 0.6)
		for k in 0 .. m.rating {
			cx := bx + step * (f32(k) + 0.5)
			cy := by + s * 1.15
			fill_star(mut ctx, cx, cy, s * 0.95, star_ring)
			fill_star(mut ctx, cx, cy, s * 0.8, star_color)
		}
	}
}
