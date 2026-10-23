module pipeline

// Шумодав, импульсы и ореолы - полосами строк в потоках.
//
// Целым кадром они держали плоскости f32 на весь кадр: вейвлет - y, u, v и
// ещё четыре рабочие, ~34 байта на пиксель (~0.8 ГБ на 24 Мп) - это и был
// пик памяти экспорта. Фильтры локальные, поэтому кадр режется на полосы с
// запасом строк сверху и снизу: полоса с запасом копируется, считается
// прежней функцией (_whole), в выход идут только её собственные строки.
// Запас не меньше радиуса фильтра - строки полосы те же, что у прохода по
// всему кадру, бит в бит (тест test_bands_match_whole): вейвлет
// 4 уровня B3 - 2·(1+2+4+8) = 30 строк, ореолы - 2·(1+2) + 1 = 7, импульсы -
// два прохода 3x3 = 2.
//
// Полосы читают нетронутый вход и пишут в отдельный выход (соседняя
// полоса читает в своём запасе ещё не обработанные строки), выход в конце
// копируется во вход. Память: выход (6 байт/пк) + полосы в работе.
import runtime
import bigbuf

pub enum NrOp {
	impulse
	denoise
	defringe
}

// Пикселей в полосе (без запаса): на 24 Мп (6000 в ширину) - 250 строк
const nr_band_px = 1_500_000
// Полос одновременно (каждая - до ~50 МБ плоскостей)
const nr_threads_max = 4

fn nr_margin(op NrOp) int {
	return match op {
		.impulse { 2 }
		.denoise { 32 }
		.defringe { 8 }
	}
}

fn nr_run(op NrOp, buf &u16, w int, h int, a f32, b f32) {
	match op {
		.impulse { impulse_whole(buf, w, h, a) }
		.denoise { denoise_whole(buf, w, h, a, b) }
		.defringe { defringe_whole(buf, w, h, a) }
	}
}

// NrBandJob - полосы одного потока: с номера first через step
struct NrBandJob {
	src    &u16
	dst    &u16
	w      int
	h      int
	op     NrOp
	a      f32
	b      f32
	rows   int // строк в полосе
	margin int
	first  int
	step   int
	nb     int // всего полос
}

fn nr_band_worker(j NrBandJob) {
	row := j.w * 3
	for k := j.first; k < j.nb; k += j.step {
		y0 := k * j.rows
		y1 := imin(j.h, y0 + j.rows)
		e0 := if y0 > j.margin { y0 - j.margin } else { 0 }
		e1 := imin(j.h, y1 + j.margin)
		mut tmp := bigbuf.new_u16((e1 - e0) * row)
		unsafe {
			vmemcpy(tmp.data, &u16(j.src) + e0 * row, (e1 - e0) * row * 2)
			nr_run(j.op, &u16(tmp.data), j.w, e1 - e0, j.a, j.b)
			vmemcpy(&u16(j.dst) + y0 * row, &u16(tmp.data) + (y0 - e0) * row, (y1 - y0) * row * 2)
		}
		bigbuf.free(mut tmp)
	}
}

// nr_bands - операция op по кадру полосами (rows - строк в полосе, 0 - по
// nr_band_px; threads 0 - по числу ядер, не больше nr_threads_max). Одна
// полоса на весь кадр - сразу _whole, без копий.
fn nr_bands(buf &u16, w int, h int, op NrOp, a f32, b f32, rows int, threads int) {
	if w <= 0 || h <= 0 {
		return
	}
	margin := nr_margin(op)
	mut r := if rows > 0 { rows } else { nr_band_px / w }
	if r < 4 * margin {
		r = 4 * margin
	}
	if r >= h {
		nr_run(op, buf, w, h, a, b)
		return
	}
	nb := (h + r - 1) / r
	mut nt := if threads > 0 { threads } else { imin(runtime.nr_cpus(), nr_threads_max) }
	nt = imin(nt, nb)
	if nt < 1 {
		nt = 1
	}
	n := w * h * 3
	mut out := bigbuf.new_u16(n)
	defer {
		bigbuf.free(mut out)
	}
	mut ts := []thread{}
	for t in 0 .. nt {
		job := NrBandJob{
			src:    buf
			dst:    unsafe { &u16(out.data) }
			w:      w
			h:      h
			op:     op
			a:      a
			b:      b
			rows:   r
			margin: margin
			first:  t
			step:   nt
			nb:     nb
		}
		if t == nt - 1 {
			nr_band_worker(job)
		} else {
			ts << spawn nr_band_worker(job)
		}
	}
	ts.wait()
	unsafe { vmemcpy(buf, out.data, n * 2) }
}
