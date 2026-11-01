module main

// Маска фокуса (как Focus Mask в Capture One): резкие места снимка
// закрашиваются зелёным - при отборе серии сразу видно, куда попал фокус,
// без увеличения до 1:1. Это вид, а не правка: в историю и сайдкар не
// пишется, экспорт не трогает (как показ пересветов, clipping.v).
//
// Мера своя и не зависит от контраста края: у резкого края почти весь
// перепад яркости приходится на соседние пиксели, у размытого он растянут
// на несколько. Поэтому сравнивается наибольший перепад к соседу (шаг s)
// с размахом яркости в окрестности: от focus_ratio_num / focus_ratio_den
// размаха - резко. Окрестность - 3x3 блока по 3s пикселей вокруг блока
// пикселя (окно ~9s, выровнено по сетке): минимум и максимум блоков
// считаются одним проходом, точное скользящее окно на каждый пиксель
// стоило втрое дороже, а разница в маске не видна. Люма - по готовым 8-битным пикселям
// (видно то, что получилось, с резкостью и шумодавом), сглаженная [1,2,1]
// - одиночный шумовой пиксель не «резкий». Шум кадра (медиана перепада к
// соседу: большая часть кадра - ровные места) поднимает пороги: размах -
// не меньше focus_min_range уровней и focus_noise_range шумов, перепад -
// не меньше focus_noise_step шумов. Без этого на ISO 6400 зеленел весь
// кадр. Подобрано 01.11.2026 на IMG_1439 (ISO 100), IMG_1586, IMG_1117
// (ISO 6400; правая половина размыта искусственно - маски нет),
// IMG_1852/1853 (f/4: церковь в фокусе, облака и фон чистые).
import vgui
import runtime
import bigbuf

const focus_color = vgui.Color{40, 235, 70, 255}
// Доля цвета маски в закрашенном пикселе, из 256
const focus_mix = 170
// Размах сглаженной люмы в окрестности, уровней 0..255: меньше - не край
const focus_min_range = 24
// Перепад к соседу / размах окрестности: от num/den - резкий край
const focus_ratio_num = 3
const focus_ratio_den = 10
// Пороги по шуму кадра: размах - не меньше focus_noise_range шумов,
// перепад - focus_noise_step
const focus_noise_range = 8
const focus_noise_step = 4

// Потоков не больше; кадр меньше focus_band_px - в одном потоке
const focus_threads_max = 4
const focus_band_px = 500_000

// FocusBufs - рабочие буферы маски (вне сборщика), живут между вызовами:
// свежие страницы mmap при каждом расчёте стоили ~40 мс на превью 6 Мп.
// Освобождать free (маску выключили, кадр закрыт).
struct FocusBufs {
mut:
	n    int
	t    []u16 // люма, сглаженная по строке
	l    []u16 // сглаженная люма ×16
	bmax []u16 // максимум и минимум l в блоках 3s x 3s
	bmin []u16
	m    []u8 // 1 - резко
}

fn (mut b FocusBufs) ensure(n int, nb int) {
	if b.n == n && b.bmax.len >= nb {
		unsafe { vmemset(b.m.data, 0, n) }
		return
	}
	b.free()
	b.n = n
	b.t = bigbuf.new_u16(n)
	b.l = bigbuf.new_u16(n)
	b.bmax = bigbuf.new_u16(nb)
	b.bmin = bigbuf.new_u16(nb)
	b.m = bigbuf.new_u8(n)
}

fn (mut b FocusBufs) free() {
	bigbuf.free(mut b.t)
	bigbuf.free(mut b.l)
	bigbuf.free(mut b.bmax)
	bigbuf.free(mut b.bmin)
	bigbuf.free(mut b.m)
	b.n = 0
}

// FocusCtx - буферы и пороги расчёта маски, общие для потоков-полос:
// каждая полоса пишет только свои строки, читает - уже готовые этапы
struct FocusCtx {
	pix  &u8 = unsafe { nil } // RGBA результат
	w    int
	h    int
	s    int
	bs   int // сторона блока, пикселей
	bw   int // блоков по ширине и высоте
	bh   int
	t    &u16 = unsafe { nil }
	l    &u16 = unsafe { nil }
	bmax &u16 = unsafe { nil }
	bmin &u16 = unsafe { nil }
	m    &u8  = unsafe { nil }
mut:
	min_rng int
	min_g   int
}

// focus_map - в b.m: 1 у резких пикселей RGBA-буфера w x h (stride 4).
// s - шаг пикселя в масштабе превью: 1 - превью (половина сенсора), 2 -
// полный кадр (1:1 - край вдвое шире в пикселях). false - кадр слишком
// мал (маска пуста).
fn focus_map(pix []u8, w int, h int, s int, mut b FocusBufs) bool {
	n := w * h
	bs := 3 * s
	if w < 4 * bs || h < 4 * bs || pix.len < n * 4 {
		return false
	}
	bw := (w + bs - 1) / bs
	bh := (h + bs - 1) / bs
	b.ensure(n, bw * bh)
	mut c := &FocusCtx{
		pix:  unsafe { &u8(pix.data) }
		w:    w
		h:    h
		s:    s
		bs:   bs
		bw:   bw
		bh:   bh
		t:    unsafe { &u16(b.t.data) }
		l:    unsafe { &u16(b.l.data) }
		bmax: unsafe { &u16(b.bmax.data) }
		bmin: unsafe { &u16(b.bmin.data) }
		m:    unsafe { &u8(b.m.data) }
	}
	focus_bands(c, 0)
	focus_bands(c, 1)
	focus_thresholds(mut c)
	focus_bands(c, 2)
	focus_bands(c, 3)
	return true
}

// mark_focus - маска фокуса поверх RGBA-буфера: резкие пиксели (и их
// соседи - тонкий край на уменьшенном экраном превью иначе пропадает)
// закрашиваются focus_color
fn mark_focus(mut pix []u8, w int, h int, s int, mut b FocusBufs) {
	if !focus_map(pix, w, h, s, mut b) {
		return
	}
	c := &FocusCtx{
		pix: unsafe { &u8(pix.data) }
		w:   w
		h:   h
		m:   unsafe { &u8(b.m.data) }
	}
	focus_bands(c, 4)
}

// set_focus_show - включить/выключить маску фокуса (меню «Вид», Shift+F):
// флажок меню, пересчёт превью, фрагмента 1:1 и левого кадра сравнения;
// выключили - буферы отпускаются
fn set_focus_show(mut st State, on bool) {
	st.focus_show = on
	if !isnil(st.m_focus) {
		mut m := st.m_focus
		m.checked = on
	}
	if !on {
		st.focus_pv.free()
		st.focus_dt.free()
		st.focus_pair.free()
	}
	if !isnil(st.tone_fx) {
		st.tone_fx()
	}
	pair_show(mut st)
}

// frag_marks - подсветка клипа и маска фокуса на фрагменте 1:1 стороны
// side (RGBA r.w x r.h); шаг маски - по масштабу фрагмента к превью
fn frag_marks(mut st State, mut pix []u8, side int) {
	mark_clipping(mut pix, st.clip_hi, st.clip_lo)
	if !st.focus_show {
		return
	}
	fr := st.dt.frag[side]
	s := if st.gw > 0 && fr.ow * 2 >= st.gw * 3 { 2 } else { 1 }
	mark_focus(mut pix, fr.r.w, fr.r.h, s, mut st.focus_dt)
}

// focus_bands - этап phase в несколько потоков (этапы идут по очереди:
// следующий читает строки соседних кусков предыдущего). Куски по
// focus_chunk строк раздаются потокам вперемешку: резкое обычно в одной
// части кадра, полосами подряд работа доставалась одному потоку.
fn focus_bands(c &FocusCtx, phase int) {
	mut nt := fo_mini(runtime.nr_cpus(), focus_threads_max)
	if c.w * c.h < focus_band_px || nt < 1 {
		nt = 1
	}
	if nt == 1 {
		focus_rows(c, phase, 0, c.h)
		return
	}
	mut ts := []thread{}
	for k in 0 .. nt {
		ts << spawn focus_chunks(c, phase, k, nt)
	}
	ts.wait()
}

const focus_chunk = 16

fn focus_chunks(c &FocusCtx, phase int, k int, nt int) {
	for a := k * focus_chunk; a < c.h; a += nt * focus_chunk {
		focus_rows(c, phase, a, fo_mini(c.h, a + focus_chunk))
	}
}

// focus_thresholds - пороги по шуму кадра: медиана перепада к соседу
// справа (каждый второй пиксель каждой четвёртой строки)
@[direct_array_access]
fn focus_thresholds(mut c FocusCtx) {
	mut hist := []int{len: 4096}
	mut cnt := 0
	w := c.w
	for y := 2; y < c.h - 2; y += 4 {
		r := y * w
		for x := 2; x < w - 2; x += 2 {
			v := unsafe { int(c.l[r + x + 1]) - int(c.l[r + x]) }
			hist[fo_mini(if v < 0 { -v } else { v }, 4095)]++
			cnt++
		}
	}
	mut noise := 0
	mut acc := 0
	for k, v in hist {
		acc += v
		if 2 * acc >= cnt {
			noise = k
			break
		}
	}
	c.min_rng = fo_maxi(focus_min_range * 16, noise * focus_noise_range)
	// Перепад не больше размаха: меньше min_rng·num/den резко не бывает
	c.min_g = fo_maxi(noise * focus_noise_step, (c.min_rng * focus_ratio_num + focus_ratio_den - 1) / focus_ratio_den)
}

// focus_rows - строки ya..yb этапа: 0 - люма и сглаживание по строке,
// 1 - по столбцу, 2 - минимум и максимум блоков (блочные строки,
// начинающиеся в полосе), 3 - кандидаты (перепад к соседу от min_g) и
// решение по размаху 3x3 блоков, 4 - закраска (резкий пиксель или сосед)
@[direct_array_access]
fn focus_rows(c &FocusCtx, phase int, ya int, yb int) {
	w := c.w
	h := c.h
	s := c.s
	unsafe {
		match phase {
			0 {
				for y in ya .. yb {
					r := y * w
					mut p := &u8(c.pix + r * 4)
					mut prev := fo_luma(p)
					mut cur := prev
					c.t[r] = u16(4 * cur)
					for x in 0 .. w - 1 {
						p += 4
						next := fo_luma(p)
						if x > 0 {
							c.t[r + x] = u16(prev + 2 * cur + next)
						}
						prev = cur
						cur = next
					}
					c.t[r + w - 1] = u16(4 * cur)
				}
			}
			1 {
				for y in ya .. yb {
					r := y * w
					if y == 0 || y == h - 1 {
						for x in 0 .. w {
							c.l[r + x] = 4 * c.t[r + x]
						}
						continue
					}
					for x in 0 .. w {
						i := r + x
						c.l[i] = c.t[i - w] + 2 * c.t[i] + c.t[i + w]
					}
				}
			}
			2 {
				bs := c.bs
				for by in (ya + bs - 1) / bs .. (yb + bs - 1) / bs {
					y0 := by * bs
					y1 := fo_mini(y0 + bs, h)
					for bx in 0 .. c.bw {
						x0 := bx * bs
						x1 := fo_mini(x0 + bs, w)
						mut mx := u16(0)
						mut mn := u16(65535)
						for y in y0 .. y1 {
							mut q := c.l + y * w + x0
							for _ in x0 .. x1 {
								v := *q
								if v > mx {
									mx = v
								}
								if v < mn {
									mn = v
								}
								q++
							}
						}
						c.bmax[by * c.bw + bx] = mx
						c.bmin[by * c.bw + bx] = mn
					}
				}
			}
			3 {
				min_g := c.min_g
				min_rng := c.min_rng
				bs := c.bs
				for y in fo_maxi(ya, s) .. fo_mini(yb, h - s) {
					r := y * w
					by := y / bs
					b0 := fo_maxi(by - 1, 0)
					b1 := fo_mini(by + 1, c.bh - 1)
					for x in s .. w - s {
						i := r + x
						cv := int(c.l[i])
						mut v := fo_absi(int(c.l[i + s]) - cv)
						v = fo_maxi(v, fo_absi(cv - int(c.l[i - s])))
						v = fo_maxi(v, fo_absi(int(c.l[i + s * w]) - cv))
						v = fo_maxi(v, fo_absi(cv - int(c.l[i - s * w])))
						if v < min_g {
							continue
						}
						bx := x / bs
						a0 := fo_maxi(bx - 1, 0)
						a1 := fo_mini(bx + 1, c.bw - 1)
						mut mx := u16(0)
						mut mn := u16(65535)
						for bb in b0 .. b1 + 1 {
							k := bb * c.bw
							for aa in a0 .. a1 + 1 {
								if c.bmax[k + aa] > mx {
									mx = c.bmax[k + aa]
								}
								if c.bmin[k + aa] < mn {
									mn = c.bmin[k + aa]
								}
							}
						}
						rng := int(mx) - int(mn)
						if rng >= min_rng && v * focus_ratio_den >= rng * focus_ratio_num {
							c.m[i] = 1
						}
					}
				}
			}
			else {
				a := u32(focus_mix)
				b := u32(256 - focus_mix)
				for y in fo_maxi(ya, 1) .. fo_mini(yb, h - 1) {
					r := y * w
					for x in 1 .. w - 1 {
						i := r + x
						if c.m[i] | c.m[i - 1] | c.m[i + 1] | c.m[i - w] | c.m[i + w] == 0 {
							continue
						}
						k := i * 4
						c.pix[k] = u8((u32(c.pix[k]) * b + u32(focus_color.r) * a) >> 8)
						c.pix[k + 1] = u8((u32(c.pix[k + 1]) * b + u32(focus_color.g) * a) >> 8)
						c.pix[k + 2] = u8((u32(c.pix[k + 2]) * b + u32(focus_color.b) * a) >> 8)
					}
				}
			}
		}
	}
}

// fo_luma - люма BT.709 пикселя RGBA, 0..255
@[inline]
fn fo_luma(p &u8) int {
	return unsafe { (54 * int(p[0]) + 183 * int(p[1]) + 19 * int(p[2])) >> 8 }
}

fn fo_absi(v int) int {
	return if v < 0 { -v } else { v }
}

fn fo_maxi(a int, b int) int {
	return if a > b { a } else { b }
}

fn fo_mini(a int, b int) int {
	return if a < b { a } else { b }
}
