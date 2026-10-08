module pipeline

// Цветокоррекция (Color Grading, как в Lightroom): тонирование теней,
// средних тонов и светов своим цветом (тёплые света / холодные тени,
// раздельное тонирование Ч/Б) и общий оттенок всего кадра. Своя
// реализация.
//
// В тоновом пространстве (0..255), после HSL, перед квантованием. Зона
// задаётся оттенком (0..360°), насыщенностью (0..100) и яркостью
// (-100..100). Цвет зоны - сдвиг каналов «без яркости»:
//   c(h) = rgb(h) - Y(rgb(h)),  rgb(h) - чистый цвет оттенка h (HSV s = v = 1),
//   Y - BT.709-люма; добавка c·sat/100·grade_amp не меняет люму пикселя
//   (до клипа), только цвет. Яркость - добавка lum/100·grade_lum_amp ко всем
//   каналам.
// Вес зоны - по тону люмы пикселя u = l/255 (после баланса):
//   баланс b = balance/100: u' = u^(2^-b) - плюс отдаёт кадр светам,
//     минус - теням;
//   растушёвка w = 0.05 + 0.3·blend/100 (смешение 0 - резкие границы, 100 -
//     зоны широко перекрываются);
//   тени ws = 1 - smoothstep(1/3 - w, 1/3 + w, u'),
//   света wh = smoothstep(2/3 - w, 2/3 + w, u'),
//   средние wm = max(0, 1 - ws - wh); общий - вес 1.
// Чистый чёрный и белый цвет не получают (пропуск на краях тона, grade_edge
// и grade_white) - иначе тонирование теней окрашивало бы чёрную рамку и
// провалы, а светов - пересвеченное небо. Яркость зон действует и на краях.
//
// Всё зависит только от люмы пикселя, поэтому складывается в таблицу на
// grade_bins корзин тона (build_grade): на пиксель - люма и три выборки.
import math

pub const grade_zones = 4 // тени, средние, света, общий
pub const grade_names = ['Тени', 'Средние', 'Света', 'Общий']

const grade_bins = 1024
const grade_amp = f32(0.25 * 255) // насыщенность 100 - сдвиг каналов до ~64 уровней
const grade_lum_amp = f32(0.15 * 255) // яркость ±100 - ±38 уровней
const grade_edge = f32(0.06) // цвет у чёрного нарастает до тона 0.06
const grade_white = f32(0.02) // и спадает у белого с тона 0.98

// GradeZone - цвет зоны: оттенок 0..360°, насыщенность 0..100, яркость
// -100..100
pub struct GradeZone {
pub mut:
	hue f32
	sat f32
	lum f32
}

// Grade - цветокоррекция кадра: зоны (grade_names), смешение 0..100,
// баланс -100..100
pub struct Grade {
pub mut:
	zones   [4]GradeZone
	blend   f32 = 50
	balance f32
}

// active - есть ли что применять (иначе таблица не строится и на пиксель
// ничего не добавляется)
pub fn (g &Grade) active() bool {
	for z in g.zones {
		if z.sat != 0 || z.lum != 0 {
			return true
		}
	}
	return false
}

// grade_chroma - сдвиг каналов «без яркости» для оттенка deg (длина -
// размах 1: max - min = 1), см. заголовок
pub fn grade_chroma(deg f32) (f32, f32, f32) {
	mut h := f32(math.fmod(f64(deg), 360.0))
	if h < 0 {
		h += 360
	}
	h /= 60
	x := 1 - f32(math.abs(math.fmod(f64(h), 2.0) - 1))
	r, g, b := match int(h) {
		0 { f32(1), x, f32(0) }
		1 { x, f32(1), f32(0) }
		2 { f32(0), f32(1), x }
		3 { f32(0), x, f32(1) }
		4 { x, f32(0), f32(1) }
		else { f32(1), f32(0), x }
	}
	y := 0.2126 * r + 0.7152 * g + 0.0722 * b
	return r - y, g - y, b - y
}

// grade_weights - веса зон теней, средних и светов для тона u 0..1
pub fn grade_weights(g &Grade, u f32) (f32, f32, f32) {
	mut t := clamp01(u)
	if g.balance != 0 && t > 0 {
		t = f32(math.pow(f64(t), math.pow(2.0, -f64(g.balance) / 100.0)))
	}
	w := 0.05 + 0.3 * clamp01(g.blend / 100)
	ws := 1 - smoothstep(f32(1.0 / 3.0) - w, f32(1.0 / 3.0) + w, t)
	wh := smoothstep(f32(2.0 / 3.0) - w, f32(2.0 / 3.0) + w, t)
	mut wm := 1 - ws - wh
	if wm < 0 {
		wm = 0
	}
	return ws, wm, wh
}

// GradeLut - добавки к каналам по корзине тона люмы (r, g, b подряд)
struct GradeLut {
	d []f32
}

fn build_grade(g &Grade) GradeLut {
	mut cr := [4]f32{}
	mut cg := [4]f32{}
	mut cb := [4]f32{}
	mut ly := [4]f32{}
	for i in 0 .. grade_zones {
		z := g.zones[i]
		r, gg, b := grade_chroma(z.hue)
		k := clamp01(z.sat / 100) * grade_amp
		cr[i] = r * k
		cg[i] = gg * k
		cb[i] = b * k
		ly[i] = z.lum / 100 * grade_lum_amp
	}
	mut d := []f32{len: grade_bins * 3}
	for i in 0 .. grade_bins {
		u := f32(i) / f32(grade_bins - 1) // концы - ровно чёрный и белый
		ws, wm, wh := grade_weights(g, u)
		w := [ws, wm, wh, f32(1)]!
		// Цвет - мимо чистого чёрного и белого
		edge := clamp01(u / grade_edge) * clamp01((1 - u) / grade_white)
		mut ar := f32(0)
		mut ag := f32(0)
		mut ab := f32(0)
		mut al := f32(0)
		for z in 0 .. grade_zones {
			ar += w[z] * cr[z]
			ag += w[z] * cg[z]
			ab += w[z] * cb[z]
			al += w[z] * ly[z]
		}
		d[3 * i] = ar * edge + al
		d[3 * i + 1] = ag * edge + al
		d[3 * i + 2] = ab * edge + al
	}
	return GradeLut{
		d: d
	}
}

// grade_pixel - цветокоррекция одного пикселя (тон 0..255; клип - у
// вызывающего)
@[inline]
fn grade_pixel(r f32, g f32, b f32, gd &f32) (f32, f32, f32) {
	l := 0.2126 * r + 0.7152 * g + 0.0722 * b
	mut i := int(l * f32(grade_bins - 1) / 255.0 + 0.5)
	if i < 0 {
		i = 0
	} else if i >= grade_bins {
		i = grade_bins - 1
	}
	unsafe {
		return r + gd[3 * i], g + gd[3 * i + 1], b + gd[3 * i + 2]
	}
}
