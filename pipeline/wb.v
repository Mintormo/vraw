module pipeline

// Баланс белого: температура (K) и оттенок -> матрица 3x3 в линейном
// sRGB, которую apply накладывает на сырьё до всей тональной работы.
//
// Сырьё LibRaw уже проявлено с камерным ББ «как снято»:
//   out = rgb_cam · diag(m_shot) · raw
// Для другого источника света (T, оттенок) нужны другие множители m_T
// (источник должен стать нейтральным):
//   out' = rgb_cam · diag(m_T) · raw = M · out,
//   M = rgb_cam · diag(m_T / m_shot) · rgb_cam⁻¹.
// m_T = 1 / (cam_xyz · XYZ источника) - отклик камеры на белое под этим
// светом. Точка источника - на кривой Планка (приближение Kim et al.,
// 1667..25000 K), оттенок - сдвиг поперёк неё в CIE 1960 uv (Duv, как в
// Lightroom/DNG SDK: 1 единица оттенка = 1/3000 Duv, плюс - источник
// зеленее, поэтому картинка пурпурнее). Всё - на один кадр (камера),
// вызывается при смене настроек.
//
// На пиксель матрица M идёт по шагам (WbXform): в пространство камеры
// (rgb_cam⁻¹), множители m_T / m_shot, клип каналов, обратно (rgb_cam) -
// так же, как проявил бы LibRaw с множителями m_T (user_mul): канал,
// ушедший за предел, клипается в камере, а не красит светлое в sRGB.
// Канал с наименьшим множителем «как снято» (обычно G) клипается только
// на сенсоре - когда он у предела, пиксель пересвечен на сенсоре, и
// остальные его клипнутые каналы тоже уходят в предел (белое остаётся
// белым). Сравнение с user_mul на 21 кадре при 3000 K - ROADMAP.
import math

pub const wb_temp_min = f32(2000)
pub const wb_temp_max = f32(12000)
pub const wb_tint_max = f32(150)

const tint_scale = 1.0 / 3000.0

// CamColor - цвет камеры из LibRaw (raw.ColorData): множители «как снято»
// и матрицы (строки - выход, по три подряд).
pub struct CamColor {
pub:
	shot    [3]f32 // cam_mul: множители ББ камеры, R G B
	rgb_cam [9]f32 // камера (после ББ) -> линейный sRGB
	cam_xyz [9]f32 // XYZ -> камера (Adobe ColorMatrix)
}

fn mat_mul(a [9]f64, b [9]f64) [9]f64 {
	mut c := [9]f64{}
	for i in 0 .. 3 {
		for j in 0 .. 3 {
			c[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
		}
	}
	return c
}

fn mat_vec(a [9]f64, v [3]f64) [3]f64 {
	return [a[0] * v[0] + a[1] * v[1] + a[2] * v[2], a[3] * v[0] + a[4] * v[1] + a[5] * v[2],
		a[6] * v[0] + a[7] * v[1] + a[8] * v[2]]!
}

fn mat_det(a [9]f64) f64 {
	return a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) +
		a[2] * (a[3] * a[7] - a[4] * a[6])
}

// mat_inv - обратная матрица (det != 0 проверяет вызывающий)
fn mat_inv(a [9]f64) [9]f64 {
	d := mat_det(a)
	return [(a[4] * a[8] - a[5] * a[7]) / d, (a[2] * a[7] - a[1] * a[8]) / d,
		(a[1] * a[5] - a[2] * a[4]) / d, (a[5] * a[6] - a[3] * a[8]) / d,
		(a[0] * a[8] - a[2] * a[6]) / d, (a[2] * a[3] - a[0] * a[5]) / d,
		(a[3] * a[7] - a[4] * a[6]) / d, (a[1] * a[6] - a[0] * a[7]) / d,
		(a[0] * a[4] - a[1] * a[3]) / d]!
}

// linear sRGB -> XYZ (D65)
const srgb_xyz = [0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750,
	0.0193339, 0.1191920, 0.9503041]!

// Камера, заданная матрицами кадра, или запасная «камера = sRGB» (файл
// без цветовой матрицы: неизвестная камера, испорченные данные)
struct Cam {
	shot    [3]f64
	rgb_cam [9]f64
	cam_rgb [9]f64 // rgb_cam⁻¹
	xyz_cam [9]f64 // cam_xyz⁻¹
	cam_xyz [9]f64
}

fn (c CamColor) cam() Cam {
	mut rc := [9]f64{}
	mut cx := [9]f64{}
	for i in 0 .. 9 {
		rc[i] = c.rgb_cam[i]
		cx[i] = c.cam_xyz[i]
	}
	shot := [f64(c.shot[0]), c.shot[1], c.shot[2]]!
	if math.abs(mat_det(rc)) > 1e-9 && math.abs(mat_det(cx)) > 1e-9 && shot[0] > 0
		&& shot[1] > 0 && shot[2] > 0 {
		return Cam{
			shot:    [shot[0] / shot[1], 1.0, shot[2] / shot[1]]!
			rgb_cam: rc
			cam_rgb: mat_inv(rc)
			xyz_cam: mat_inv(cx)
			cam_xyz: cx
		}
	}
	id := [1.0, 0, 0, 0, 1, 0, 0, 0, 1]!
	return Cam{
		shot:    [1.0, 1.0, 1.0]!
		rgb_cam: id
		cam_rgb: id
		xyz_cam: srgb_xyz
		cam_xyz: mat_inv(srgb_xyz)
	}
}

// planck_xy - цветность чёрного тела T K (кубическое приближение Kim et al.)
fn planck_xy(temp f64) (f64, f64) {
	t := math.max(1667.0, math.min(25000.0, temp))
	t2 := t * t
	t3 := t2 * t
	x := if t < 4000 {
		-0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
	} else {
		-3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
	}
	x2 := x * x
	x3 := x2 * x
	y := if t < 2222 {
		-1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
	} else if t < 4000 {
		-0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
	} else {
		3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
	}
	return x, y
}

fn xy_uv(x f64, y f64) (f64, f64) {
	d := -2 * x + 12 * y + 3
	return 4 * x / d, 6 * y / d
}

fn uv_xy(u f64, v f64) (f64, f64) {
	d := 2 * u - 8 * v + 4
	return 3 * u / d, 2 * v / d
}

// locus - точка кривой Планка в uv и единичная нормаль к ней в сторону
// зелёного (больше v)
fn locus(temp f64) (f64, f64, f64, f64) {
	x, y := planck_xy(temp)
	u, v := xy_uv(x, y)
	x2, y2 := planck_xy(temp * 1.01)
	u2, v2 := xy_uv(x2, y2)
	du := u2 - u
	dv := v2 - v
	n := math.sqrt(du * du + dv * dv)
	mut nu := -dv / n
	mut nv := du / n
	if nv < 0 {
		nu, nv = -nu, -nv
	}
	return u, v, nu, nv
}

// illum_xyz - XYZ (Y = 1) источника с температурой и оттенком
fn illum_xyz(temp f64, tint f64) [3]f64 {
	u, v, nu, nv := locus(temp)
	duv := tint * tint_scale
	x, y := uv_xy(u + duv * nu, v + duv * nv)
	return [x / y, 1.0, (1 - x - y) / y]!
}

// wb_matrix - матрица ББ (линейный sRGB «как снято» -> под источник T,
// оттенок). Нормирована по зелёному: G-множитель не меняется, яркость
// средних тонов остаётся примерно прежней.
pub fn (c CamColor) wb_matrix(temp f32, tint f32) [9]f32 {
	k := c.cam()
	resp := mat_vec(k.cam_xyz, illum_xyz(temp, tint))
	mut d := [9]f64{}
	for i in 0 .. 3 {
		if resp[i] <= 0 {
			return [f32(1), 0, 0, 0, 1, 0, 0, 0, 1]!
		}
		// m_T / m_shot, оба нормированы по G
		d[i * 4] = (resp[1] / resp[i]) / k.shot[i]
	}
	m := mat_mul(mat_mul(k.rgb_cam, d), k.cam_rgb)
	mut out := [9]f32{}
	for i in 0 .. 9 {
		out[i] = f32(m[i])
	}
	return out
}

// WbXform - баланс белого по шагам (см. начало файла): c = cam · in,
// o = c · d с клипом в камере, out = rgb · o. g - канал, клипающийся только
// на сенсоре (наименьший множитель «как снято»).
pub struct WbXform {
pub:
	cam [9]f32 // rgb_cam⁻¹: линейный sRGB -> камера (после ББ «как снято»)
	d   [3]f32 // m_T / m_shot, нормированы по G
	rgb [9]f32 // rgb_cam: камера -> линейный sRGB
	g   int
	// Быстрый путь: при max(вход) < lim ни один канал камеры не дойдёт до
	// клипа и порога пересвета - хватает готовой матрицы m (rgb·d·cam)
	m   [9]f32
	lim f32
}

// wb_xform - ББ под источник T, оттенок по шагам для пайплайна
pub fn (c CamColor) wb_xform(temp f32, tint f32) WbXform {
	k := c.cam()
	resp := mat_vec(k.cam_xyz, illum_xyz(temp, tint))
	mut d := [f32(1), 1, 1]!
	if resp[0] > 0 && resp[1] > 0 && resp[2] > 0 {
		for i in 0 .. 3 {
			d[i] = f32((resp[1] / resp[i]) / k.shot[i])
		}
	}
	mut g := 0
	for i in 1 .. 3 {
		if k.shot[i] < k.shot[g] {
			g = i
		}
	}
	mut cm := [9]f32{}
	mut rm := [9]f32{}
	for i in 0 .. 9 {
		cm[i] = f32(k.cam_rgb[i])
		rm[i] = f32(k.rgb_cam[i])
	}
	mut x := WbXform{
		cam: cm
		d:   d
		rgb: rm
		g:   g
	}
	// |c_i · d_i| <= max(вход) · Σ_j |cam_ij| · max(d_i, 1); порог пересвета
	// wb_sat_lo ниже клипа - по нему
	mut b := f32(0)
	for i in 0 .. 3 {
		mut s := f32(0)
		for j in 0 .. 3 {
			s += f32(math.abs(cm[i * 3 + j]))
		}
		s *= if d[i] > 1 { d[i] } else { f32(1) }
		if s > b {
			b = s
		}
	}
	return WbXform{
		...x
		m:   x.matrix()
		lim: if b > 0 { wb_sat_lo / b } else { 0 }
	}
}

// matrix - та же матрица M одним куском (без клипа в камере)
pub fn (x WbXform) matrix() [9]f32 {
	mut out := [9]f32{}
	for i in 0 .. 3 {
		for j in 0 .. 3 {
			mut s := f32(0)
			for k in 0 .. 3 {
				s += x.rgb[i * 3 + k] * x.d[k] * x.cam[k * 3 + j]
			}
			out[i * 3 + j] = s
		}
	}
	return out
}

// temp_tint - температура и оттенок источника, дающего в камере отклик
// resp (ищется ближайшая точка кривой Планка в uv, оттенок - знаковое
// расстояние до неё). Результат - в пределах ползунков.
fn temp_tint(k Cam, resp [3]f64) (f32, f32) {
	xyz := mat_vec(k.xyz_cam, resp)
	sum := xyz[0] + xyz[1] + xyz[2]
	if sum <= 0 || xyz[1] <= 0 {
		return 5000, 0
	}
	u, v := xy_uv(xyz[0] / sum, xyz[1] / sum)
	// Перебор по майредам (шкала, в которой кривая равномерна), потом
	// уточнение вокруг лучшего
	dist := fn [u, v] (mired f64) f64 {
		lu, lv, _, _ := locus(1e6 / mired)
		return (u - lu) * (u - lu) + (v - lv) * (v - lv)
	}
	mut best := 1e6 / f64(wb_temp_max)
	mut best_d := dist(best)
	mut m := best
	for m <= 1e6 / f64(wb_temp_min) {
		d := dist(m)
		if d < best_d {
			best, best_d = m, d
		}
		m += 1.0
	}
	mut lo := best - 1.0
	mut hi := best + 1.0
	for _ in 0 .. 40 {
		a := lo + (hi - lo) / 3
		b := hi - (hi - lo) / 3
		if dist(a) < dist(b) {
			hi = b
		} else {
			lo = a
		}
	}
	mired := (lo + hi) / 2
	temp := math.max(f64(wb_temp_min), math.min(f64(wb_temp_max), 1e6 / mired))
	lu, lv, nu, nv := locus(temp)
	tint := ((u - lu) * nu + (v - lv) * nv) / tint_scale
	return f32(temp), f32(math.max(-f64(wb_tint_max), math.min(f64(wb_tint_max), tint)))
}

// as_shot - температура и оттенок камерного ББ «как снято»
pub fn (c CamColor) as_shot() (f32, f32) {
	k := c.cam()
	return temp_tint(k, [1 / k.shot[0], 1 / k.shot[1], 1 / k.shot[2]]!)
}

// neutral_temp_tint - настройки ББ, при которых цвет (r, g, b) - линейный
// sRGB превью «как снято» - станет серым (пипетка, «Авто»)
pub fn (c CamColor) neutral_temp_tint(r f64, g f64, b f64) (f32, f32) {
	k := c.cam()
	cam := mat_vec(k.cam_rgb, [r, g, b]!)
	// Отклик камеры до ББ: делим на множители «как снято»
	return temp_tint(k, [cam[0] / k.shot[0], cam[1] / k.shot[1], cam[2] / k.shot[2]]!)
}

// gray_world - средний цвет кадра для «Авто» (линейный 16-бит RGB, npix):
// без почти чёрного (шум) и пересвеченного (клип искажает цвет), каждый
// 4-й пиксель. Нет подходящих - серый.
pub fn gray_world(src &u16, npix int) (f64, f64, f64) {
	mut sr := 0.0
	mut sg := 0.0
	mut sb := 0.0
	unsafe {
		mut s := &u16(src)
		for _ in 0 .. npix / 4 {
			r := int(s[0])
			g := int(s[1])
			b := int(s[2])
			mx := if r > g { if r > b { r } else { b } } else { if g > b { g } else { b } }
			if mx > 600 && mx < 60000 {
				sr += f64(r)
				sg += f64(g)
				sb += f64(b)
			}
			s += 12
		}
	}
	if sg <= 0 {
		return 1, 1, 1
	}
	return sr, sg, sb
}
