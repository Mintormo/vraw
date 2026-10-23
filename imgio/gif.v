module imgio

// GIF89a: один кадр, глобальная палитра 256 цветов.
// - Палитра - медианное сечение по гистограмме 5 бит на канал (32768
//   ячеек): делится ячейка-«коробка» с наибольшим числом пикселей ×
//   протяжённостью, по медиане вдоль самой длинной оси; цвет палитры -
//   среднее настоящих 8-битных цветов коробки.
// - Каждой ячейке заранее - ближайший цвет палитры (таблица на 32768).
// - Дизеринг Флойда-Стейнберга: ошибка в полной точности, без полос на
//   плавных переходах (небо).
// - LZW как в gif.h: коды 9..12 бит, сброс словаря при заполнении
//   (4095), подблоки по 255 байт.

const gif_colors = 256

struct GifBox {
mut:
	lo    [3]int // границы в 5-битных ячейках, включительно
	hi    [3]int
	count u64
}

struct GifHist {
mut:
	count []u32 // по ячейке (r5 << 10 | g5 << 5 | b5)
	sum   []u64 // суммы 8-битных r, g, b по ячейке: 3 на ячейку
}

fn gif_bin(r u8, g u8, b u8) int {
	return (int(r >> 3) << 10) | (int(g >> 3) << 5) | int(b >> 3)
}

fn (h &GifHist) box_count(b GifBox) u64 {
	mut n := u64(0)
	for r in b.lo[0] .. b.hi[0] + 1 {
		for g in b.lo[1] .. b.hi[1] + 1 {
			base := (r << 10) | (g << 5)
			for bl in b.lo[2] .. b.hi[2] + 1 {
				n += h.count[base | bl]
			}
		}
	}
	return n
}

// shrink - границы коробки по занятым ячейкам
fn (h &GifHist) shrink(mut b GifBox) {
	mut lo := [31, 31, 31]!
	mut hi := [0, 0, 0]!
	for r in b.lo[0] .. b.hi[0] + 1 {
		for g in b.lo[1] .. b.hi[1] + 1 {
			for bl in b.lo[2] .. b.hi[2] + 1 {
				if h.count[(r << 10) | (g << 5) | bl] == 0 {
					continue
				}
				c := [r, g, bl]!
				for i in 0 .. 3 {
					if c[i] < lo[i] {
						lo[i] = c[i]
					}
					if c[i] > hi[i] {
						hi[i] = c[i]
					}
				}
			}
		}
	}
	b.lo = lo
	b.hi = hi
	b.count = h.box_count(b)
}

// split - разрезать коробку по медиане вдоль самой длинной оси
fn (h &GifHist) split(b GifBox) (GifBox, GifBox) {
	mut axis := 0
	for i in 1 .. 3 {
		if b.hi[i] - b.lo[i] > b.hi[axis] - b.lo[axis] {
			axis = i
		}
	}
	// Число пикселей по слоям вдоль оси
	mut layers := []u64{len: 32}
	for r in b.lo[0] .. b.hi[0] + 1 {
		for g in b.lo[1] .. b.hi[1] + 1 {
			for bl in b.lo[2] .. b.hi[2] + 1 {
				c := [r, g, bl]!
				layers[c[axis]] += h.count[(r << 10) | (g << 5) | bl]
			}
		}
	}
	// Граница: первый слой, на котором набралась половина (но хотя бы
	// один слой остаётся справа)
	mut acc := u64(0)
	mut cut := b.lo[axis]
	for v in b.lo[axis] .. b.hi[axis] {
		acc += layers[v]
		cut = v
		if acc * 2 >= b.count {
			break
		}
	}
	mut a := b
	mut c := b
	a.hi[axis] = cut
	c.lo[axis] = cut + 1
	h.shrink(mut a)
	h.shrink(mut c)
	return a, c
}

// gif_palette - палитра (до 256 цветов, RGB подряд) медианным сечением
fn gif_palette(h &GifHist) []u8 {
	mut boxes := []GifBox{}
	mut first := GifBox{
		hi: [31, 31, 31]!
	}
	h.shrink(mut first)
	boxes << first
	for boxes.len < gif_colors {
		// Коробка с наибольшим «весом» среди делимых
		mut best := -1
		mut best_w := f64(0)
		for i, b in boxes {
			ext := (b.hi[0] - b.lo[0]) + (b.hi[1] - b.lo[1]) + (b.hi[2] - b.lo[2])
			if ext == 0 || b.count == 0 {
				continue
			}
			w := f64(b.count) * f64(ext)
			if w > best_w {
				best_w = w
				best = i
			}
		}
		if best < 0 {
			break // все коробки - по одной ячейке
		}
		a, c := h.split(boxes[best])
		boxes[best] = a
		boxes << c
	}
	mut pal := []u8{cap: boxes.len * 3}
	for b in boxes {
		mut s := [u64(0), 0, 0]!
		mut n := u64(0)
		for r in b.lo[0] .. b.hi[0] + 1 {
			for g in b.lo[1] .. b.hi[1] + 1 {
				for bl in b.lo[2] .. b.hi[2] + 1 {
					i := (r << 10) | (g << 5) | bl
					n += h.count[i]
					s[0] += h.sum[i * 3]
					s[1] += h.sum[i * 3 + 1]
					s[2] += h.sum[i * 3 + 2]
				}
			}
		}
		for k in 0 .. 3 {
			pal << if n > 0 { u8((s[k] + n / 2) / n) } else { u8(0) }
		}
	}
	return pal
}

// gif_quantize - индексы палитры по кадру с дизерингом
fn gif_quantize(w int, h int, rgb []u8) ([]u8, []u8) {
	mut hist := GifHist{
		count: []u32{len: 32768}
		sum:   []u64{len: 32768 * 3}
	}
	for i in 0 .. w * h {
		r := rgb[i * 3]
		g := rgb[i * 3 + 1]
		b := rgb[i * 3 + 2]
		k := gif_bin(r, g, b)
		hist.count[k]++
		hist.sum[k * 3] += r
		hist.sum[k * 3 + 1] += g
		hist.sum[k * 3 + 2] += b
	}
	pal := gif_palette(&hist)
	np := pal.len / 3
	// Ближайший цвет палитры к центру каждой ячейки
	mut lut := []u8{len: 32768}
	for k in 0 .. 32768 {
		cr := ((k >> 10) & 31) * 8 + 4
		cg := ((k >> 5) & 31) * 8 + 4
		cb := (k & 31) * 8 + 4
		mut best := 0
		mut best_d := max_int
		for p in 0 .. np {
			dr := cr - int(pal[p * 3])
			dg := cg - int(pal[p * 3 + 1])
			db := cb - int(pal[p * 3 + 2])
			d := dr * dr + dg * dg + db * db
			if d < best_d {
				best_d = d
				best = p
			}
		}
		lut[k] = u8(best)
	}
	// Флойд-Стейнберг: ошибки текущей и следующей строк (в 1/16, с полями
	// по пикселю) - две строки одного буфера, меняются местами смещением
	mut idx := []u8{len: w * h}
	stride := (w + 2) * 3
	mut errs := []int{len: stride * 2}
	for y in 0 .. h {
		co := (y % 2) * stride // текущая строка
		no := stride - co // следующая
		for x in 0 .. w {
			i := (y * w + x) * 3
			e := (x + 1) * 3
			mut v := [0, 0, 0]!
			for c in 0 .. 3 {
				t := int(rgb[i + c]) + (errs[co + e + c] + 8) / 16
				v[c] = if t < 0 {
					0
				} else if t > 255 {
					255
				} else {
					t
				}
			}
			p := int(lut[gif_bin(u8(v[0]), u8(v[1]), u8(v[2]))])
			idx[y * w + x] = u8(p)
			for c in 0 .. 3 {
				err := v[c] - int(pal[p * 3 + c])
				errs[co + e + 3 + c] += err * 7
				errs[no + e - 3 + c] += err * 3
				errs[no + e + c] += err * 5
				errs[no + e + 3 + c] += err
			}
		}
		// Текущая строка отработана - станет «следующей» для y + 1
		for j in co .. co + stride {
			errs[j] = 0
		}
	}
	return pal, idx
}

// GifBits - упаковка кодов LZW (младшими битами вперёд) в подблоки
struct GifBits {
mut:
	out   []u8
	block []u8
	acc   u32
	nbits int
}

fn (mut b GifBits) put(code int, size int) {
	b.acc |= u32(code) << b.nbits
	b.nbits += size
	for b.nbits >= 8 {
		b.emit(u8(b.acc))
		b.acc >>= 8
		b.nbits -= 8
	}
}

fn (mut b GifBits) emit(v u8) {
	b.block << v
	if b.block.len == 255 {
		b.out << 255
		b.out << b.block
		b.block.clear()
	}
}

fn (mut b GifBits) finish() {
	if b.nbits > 0 {
		b.emit(u8(b.acc))
		b.acc = 0
		b.nbits = 0
	}
	if b.block.len > 0 {
		b.out << u8(b.block.len)
		b.out << b.block
		b.block.clear()
	}
	b.out << 0 // конец данных кадра
}

// gif_lzw - сжатые данные кадра (подблоки) при минимальном размере кода 8
fn gif_lzw(idx []u8) []u8 {
	clear := 256
	eoi := 257
	mut bits := GifBits{
		out: []u8{cap: idx.len / 2}
	}
	// Словарь: код строки «префикс + байт» - прямой таблицей 4096 × 256;
	// поколение вместо очистки таблицы при каждом сбросе
	mut codes := []u16{len: 4096 * 256}
	mut gens := []u16{len: 4096 * 256}
	mut gen := u16(1)
	mut size := 9
	mut max_code := eoi
	bits.put(clear, size)
	if idx.len == 0 {
		bits.put(eoi, size)
		bits.finish()
		return bits.out
	}
	mut cur := int(idx[0])
	for i in 1 .. idx.len {
		k := int(idx[i])
		t := cur * 256 + k
		if gens[t] == gen {
			cur = int(codes[t])
			continue
		}
		bits.put(cur, size)
		max_code++
		codes[t] = u16(max_code)
		gens[t] = gen
		if max_code >= (1 << size) && size < 12 {
			size++
		}
		if max_code == 4095 {
			bits.put(clear, size)
			size = 9
			max_code = eoi
			gen++
			if gen == 0 {
				// поколения кончились - честная очистка
				for j in 0 .. gens.len {
					gens[j] = 0
				}
				gen = 1
			}
		}
		cur = k
	}
	bits.put(cur, size)
	// Декодер, прочитав последний код, добавит запись и может расширить
	// код - EOI пишется уже с его размером
	if max_code + 1 >= (1 << size) && size < 12 {
		size++
	}
	bits.put(eoi, size)
	bits.finish()
	return bits.out
}

fn encode_gif(w int, h int, rgb []u8) []u8 {
	pal, idx := gif_quantize(w, h, rgb)
	mut out := []u8{cap: w * h / 2}
	out << 'GIF89a'.bytes()
	put_u16_le(mut out, w)
	put_u16_le(mut out, h)
	out << 0xf7 // глобальная палитра 2^(7+1) = 256 цветов, 8 бит на канал
	out << 0 // фон
	out << 0 // пропорции пикселя
	out << pal
	for _ in pal.len .. gif_colors * 3 {
		out << 0
	}
	out << 0x2c // дескриптор кадра
	put_u16_le(mut out, 0)
	put_u16_le(mut out, 0)
	put_u16_le(mut out, w)
	put_u16_le(mut out, h)
	out << 0 // без локальной палитры и чересстрочности
	out << 8 // минимальный размер кода LZW
	out << gif_lzw(idx)
	out << 0x3b // конец файла
	return out
}
