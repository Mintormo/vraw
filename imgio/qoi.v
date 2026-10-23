module imgio

// QOI (https://qoiformat.org/qoi-specification.pdf): сжатие без потерь,
// быстрое, байт за байтом как в эталонном qoi.h (RGB, без альфы: альфа
// всегда 255 и входит в хэш).

const qoi_op_index = u8(0x00)
const qoi_op_diff = u8(0x40)
const qoi_op_luma = u8(0x80)
const qoi_op_run = u8(0xc0)
const qoi_op_rgb = u8(0xfe)

fn qoi_hash(r u8, g u8, b u8) int {
	return (int(r) * 3 + int(g) * 5 + int(b) * 7 + 255 * 11) % 64
}

fn put_u32_be(mut out []u8, v u32) {
	out << u8(v >> 24)
	out << u8(v >> 16)
	out << u8(v >> 8)
	out << u8(v)
}

fn encode_qoi(w int, h int, rgb []u8) []u8 {
	n := w * h
	mut out := []u8{cap: 14 + n + 8}
	out << 'qoif'.bytes()
	put_u32_be(mut out, u32(w))
	put_u32_be(mut out, u32(h))
	out << 3 // каналы
	out << 0 // sRGB
	mut index := []u32{len: 64} // упакованный RGB + флаг занятости
	mut pr, mut pg, mut pb := u8(0), u8(0), u8(0)
	mut run := 0
	for i in 0 .. n {
		r := rgb[i * 3]
		g := rgb[i * 3 + 1]
		b := rgb[i * 3 + 2]
		if r == pr && g == pg && b == pb {
			run++
			if run == 62 || i == n - 1 {
				out << qoi_op_run | u8(run - 1)
				run = 0
			}
			continue
		}
		if run > 0 {
			out << qoi_op_run | u8(run - 1)
			run = 0
		}
		idx := qoi_hash(r, g, b)
		key := (u32(1) << 24) | (u32(r) << 16) | (u32(g) << 8) | u32(b)
		if index[idx] == key {
			out << qoi_op_index | u8(idx)
		} else {
			index[idx] = key
			// Разности - со знаком и переполнением, как у байтов в qoi.h
			dr := int(i8(r - pr))
			dg := int(i8(g - pg))
			db := int(i8(b - pb))
			dr_dg := dr - dg
			db_dg := db - dg
			if dr >= -2 && dr <= 1 && dg >= -2 && dg <= 1 && db >= -2 && db <= 1 {
				out << qoi_op_diff | u8((dr + 2) << 4) | u8((dg + 2) << 2) | u8(db + 2)
			} else if dg >= -32 && dg <= 31 && dr_dg >= -8 && dr_dg <= 7 && db_dg >= -8
				&& db_dg <= 7 {
				out << qoi_op_luma | u8(dg + 32)
				out << u8((dr_dg + 8) << 4) | u8(db_dg + 8)
			} else {
				out << qoi_op_rgb
				out << r
				out << g
				out << b
			}
		}
		pr, pg, pb = r, g, b
	}
	out << [u8(0), 0, 0, 0, 0, 0, 0, 1]
	return out
}
