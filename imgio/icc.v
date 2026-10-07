module imgio

// ICC-профиль sRGB для готового файла - своя сборка по спецификации ICC
// (v2.1, класс «монитор», матрица + кривые), без готовых файлов профилей.
// Пайплайн выдаёт sRGB: основные цвета BT.709 / sRGB, белое D65; тон
// подогнан под камерный JPEG (тоже sRGB), поэтому кривая - стандартная
// sRGB (IEC 61966-2.1). Без профиля программы с управлением цветом
// угадывают пространство (обычно sRGB, но не все), с ним - показывают
// одинаково; на мониторах с широким охватом без профиля цвета
// перенасыщены.
//
// Устройство (всё big-endian):
//   заголовок 128 байт (размер, версия, класс 'mntr', 'RGB ' -> 'XYZ ',
//   'acsp', освещение PCS D50), таблица тегов, данные тегов по 4 байта;
//   desc, cprt - название и права; wtpt - белое (D50: основные цвета уже
//   приведены к PCS); rXYZ, gXYZ, bXYZ - столбцы матрицы RGB -> XYZ D50
//   (из цветностей sRGB, Брэдфорд D65 -> D50); rTRC, gTRC, bTRC - одна
//   общая таблица кривой sRGB (icc_curve_n точек, данные одни на три тега).
import math
import hash.crc32

const icc_curve_n = 1024
// Белое PCS D50 по спецификации ICC
const icc_d50 = [0.9642, 1.0, 0.8249]

// srgb_icc - ICC-профиль sRGB (несколько КБ; строится заново - дёшево)
pub fn srgb_icc() []u8 {
	m := srgb_d50_matrix()
	mut tags := []IccTag{}
	tags << IccTag{'desc', icc_desc('sRGB (vraw)')}
	tags << IccTag{'cprt', icc_text('No copyright, use freely')}
	tags << IccTag{'wtpt', icc_xyz(icc_d50[0], icc_d50[1], icc_d50[2])}
	tags << IccTag{'rXYZ', icc_xyz(m[0][0], m[1][0], m[2][0])}
	tags << IccTag{'gXYZ', icc_xyz(m[0][1], m[1][1], m[2][1])}
	tags << IccTag{'bXYZ', icc_xyz(m[0][2], m[1][2], m[2][2])}
	curve := icc_srgb_curve()
	tags << IccTag{'rTRC', curve}
	tags << IccTag{'gTRC', []u8{}} // пусто - те же данные, что у предыдущего
	tags << IccTag{'bTRC', []u8{}}
	return icc_profile(tags)
}

struct IccTag {
	sig  string
	data []u8
}

// icc_profile - заголовок, таблица тегов и данные. Тег с пустыми данными
// ссылается на данные предыдущего (общая кривая трёх каналов).
fn icc_profile(tags []IccTag) []u8 {
	table := 4 + 12 * tags.len
	mut body := []u8{}
	mut offs := []int{}
	mut sizes := []int{}
	for t in tags {
		if t.data.len == 0 && offs.len > 0 {
			offs << offs.last()
			sizes << sizes.last()
			continue
		}
		offs << 128 + table + body.len
		sizes << t.data.len
		body << t.data
		for body.len % 4 != 0 {
			body << 0
		}
	}
	total := 128 + table + body.len
	mut out := []u8{cap: total}
	put_u32_be(mut out, u32(total))
	out << []u8{len: 4} // CMM - любой
	put_u32_be(mut out, 0x02100000) // версия 2.1
	out << 'mntrRGB XYZ '.bytes()
	for v in [2026, 10, 7, 0, 0, 0] { // дата создания - постоянная
		put_u16_be(mut out, v)
	}
	out << 'acsp'.bytes()
	out << []u8{len: 4 + 4 + 4 + 4 + 8} // платформа, флаги, производитель, модель, атрибуты
	put_u32_be(mut out, 0) // намерение: перцептивное
	for v in icc_d50 {
		put_s15f16(mut out, v)
	}
	out << 'vraw'.bytes() // создатель
	out << []u8{len: 128 - out.len}
	put_u32_be(mut out, u32(tags.len))
	for i, t in tags {
		out << t.sig.bytes()
		put_u32_be(mut out, u32(offs[i]))
		put_u32_be(mut out, u32(sizes[i]))
	}
	out << body
	return out
}

// srgb_d50_matrix - RGB sRGB (линейный) -> XYZ D50: матрица по цветностям
// основных цветов и белого D65, затем адаптация Брэдфорда к D50
fn srgb_d50_matrix() [][]f64 {
	xy := [[0.64, 0.33], [0.30, 0.60], [0.15, 0.06]]
	wx, wy := 0.3127, 0.3290
	// Столбцы - XYZ основных при Y = 1, затем масштаб, чтобы R+G+B = белое
	mut p := [][]f64{len: 3, init: []f64{len: 3}}
	for j in 0 .. 3 {
		x, y := xy[j][0], xy[j][1]
		p[0][j] = x / y
		p[1][j] = 1
		p[2][j] = (1 - x - y) / y
	}
	w := [wx / wy, 1.0, (1 - wx - wy) / wy]
	s := mat_vec(mat_inv(p), w)
	mut m := [][]f64{len: 3, init: []f64{len: 3}}
	for i in 0 .. 3 {
		for j in 0 .. 3 {
			m[i][j] = p[i][j] * s[j]
		}
	}
	// Брэдфорд: колбочки белого источника -> приёмника
	bf := [[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367],
		[0.0389, -0.0685, 1.0296]]
	cs := mat_vec(bf, w)
	cd := mat_vec(bf, icc_d50)
	mut d := [][]f64{len: 3, init: []f64{len: 3}}
	for i in 0 .. 3 {
		d[i][i] = cd[i] / cs[i]
	}
	adapt := mat_mul(mat_inv(bf), mat_mul(d, bf))
	return mat_mul(adapt, m)
}

// icc_srgb_curve - тег curv: кривая sRGB (код -> линейное) таблицей
fn icc_srgb_curve() []u8 {
	mut out := 'curv'.bytes()
	out << []u8{len: 4}
	put_u32_be(mut out, icc_curve_n)
	for i in 0 .. icc_curve_n {
		v := f64(i) / f64(icc_curve_n - 1)
		lin := if v <= 0.04045 { v / 12.92 } else { math.pow((v + 0.055) / 1.055, 2.4) }
		put_u16_be(mut out, int(math.round(lin * 65535)))
	}
	return out
}

fn icc_xyz(x f64, y f64, z f64) []u8 {
	mut out := 'XYZ '.bytes()
	out << []u8{len: 4}
	put_s15f16(mut out, x)
	put_s15f16(mut out, y)
	put_s15f16(mut out, z)
	return out
}

// icc_desc - textDescriptionType (v2): ASCII с нулём, пустые Unicode и
// ScriptCode (67 байт)
fn icc_desc(s string) []u8 {
	mut out := 'desc'.bytes()
	out << []u8{len: 4}
	put_u32_be(mut out, u32(s.len + 1))
	out << s.bytes()
	out << 0
	out << []u8{len: 4 + 4 + 2 + 1 + 67}
	return out
}

fn icc_text(s string) []u8 {
	mut out := 'text'.bytes()
	out << []u8{len: 4}
	out << s.bytes()
	out << 0
	return out
}

fn put_s15f16(mut out []u8, v f64) {
	put_u32_be(mut out, u32(i32(math.round(v * 65536))))
}

fn put_u16_be(mut out []u8, v int) {
	out << u8(v >> 8)
	out << u8(v)
}

fn mat_mul(a [][]f64, b [][]f64) [][]f64 {
	mut r := [][]f64{len: 3, init: []f64{len: 3}}
	for i in 0 .. 3 {
		for j in 0 .. 3 {
			for k in 0 .. 3 {
				r[i][j] += a[i][k] * b[k][j]
			}
		}
	}
	return r
}

fn mat_vec(a [][]f64, v []f64) []f64 {
	mut r := []f64{len: 3}
	for i in 0 .. 3 {
		r[i] = a[i][0] * v[0] + a[i][1] * v[1] + a[i][2] * v[2]
	}
	return r
}

// mat_inv - обратная 3x3 (через присоединённую)
fn mat_inv(a [][]f64) [][]f64 {
	det := a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
		a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
	mut r := [][]f64{len: 3, init: []f64{len: 3}}
	for i in 0 .. 3 {
		for j in 0 .. 3 {
			// Алгебраическое дополнение (j, i)
			a1 := a[(j + 1) % 3][(i + 1) % 3]
			a2 := a[(j + 2) % 3][(i + 2) % 3]
			b1 := a[(j + 1) % 3][(i + 2) % 3]
			b2 := a[(j + 2) % 3][(i + 1) % 3]
			r[i][j] = (a1 * a2 - b1 * b2) / det
		}
	}
	return r
}

// jpeg_with_icc - JPEG с профилем: сегмент APP2 «ICC_PROFILE» (номер 1 из
// 1) за SOI и сегментами APP0/APP1 в начале (EXIF остаётся первым)
fn jpeg_with_icc(jpg []u8, icc []u8) ![]u8 {
	if jpg.len < 2 || jpg[0] != 0xFF || jpg[1] != 0xD8 {
		return error('не JPEG')
	}
	n := 2 + 12 + 2 + icc.len // длина сегмента - вместе с полем длины
	if n > 65535 {
		return error('ICC-профиль больше 64 КБ')
	}
	mut at := 2
	for at + 4 <= jpg.len && jpg[at] == 0xFF && (jpg[at + 1] == 0xE0 || jpg[at + 1] == 0xE1) {
		at += 2 + (int(jpg[at + 2]) << 8 | int(jpg[at + 3]))
	}
	if at > jpg.len {
		return error('битый JPEG')
	}
	mut out := []u8{cap: jpg.len + n + 2}
	out << jpg[..at]
	out << [u8(0xFF), 0xE2, u8(n >> 8), u8(n)]
	out << 'ICC_PROFILE'.bytes()
	out << [u8(0), 1, 1]
	out << icc
	out << jpg[at..]
	return out
}

// png_with_icc - PNG с чанком iCCP (имя, метод сжатия 0, профиль в zlib)
// сразу за IHDR - до PLTE и IDAT, как требует PNG
fn png_with_icc(png []u8, icc []u8) ![]u8 {
	ihdr_end := 8 + 25
	if png.len < ihdr_end || png[12..16].bytestr() != 'IHDR' {
		return error('не PNG')
	}
	mut chunk := 'iCCP'.bytes()
	chunk << 'sRGB'.bytes()
	chunk << [u8(0), 0]
	chunk << zlib_compress(icc)!
	mut out := []u8{cap: png.len + chunk.len + 8}
	out << png[..ihdr_end]
	put_u32_be(mut out, u32(chunk.len - 4))
	out << chunk
	put_u32_be(mut out, crc32.sum(chunk))
	out << png[ihdr_end..]
	return out
}
