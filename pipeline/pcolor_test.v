module pipeline

// Точечный цвет (pcolor.v): без точек и с нулевыми правками - байт в байт;
// правка касается цвета пипетки, не трогает далёкие оттенки и серое; в Ч/Б
// не действует; ширина «Диапазон»
import math

fn pc_px(r u16, g u16, b u16, p Params) (int, int, int) {
	src := [r, g, b]
	mut dst := []u8{len: 3}
	apply(unsafe { &u16(src.data) }, unsafe { nil }, 1, p, mut dst, 3)
	return int(dst[0]), int(dst[1]), int(dst[2])
}

// pc_center - точка по цвету пикселя (как пипетка: тон до точечного цвета)
fn pc_center(r u16, g u16, b u16) PointColor {
	tr, tg, tb := pc_px(r, g, b, Params{ dither: false })
	return rgb_point(f32(tr), f32(tg), f32(tb))
}

const pc_red = [u16(30000), 4000, 3000]
const pc_blue = [u16(3000), 6000, 30000]
const pc_gray = [u16(12000), 12000, 12000]

fn pc_all(p Params) [][]int {
	mut out := [][]int{}
	for c in [pc_red, pc_blue, pc_gray] {
		r, g, b := pc_px(c[0], c[1], c[2], p)
		out << [r, g, b]
	}
	return out
}

fn test_pcolor_identity() {
	base := pc_all(Params{ dither: false })
	// Точка без правок - не действует
	mut p := Params{
		dither: false
	}
	p.pcolor << pc_center(pc_red[0], pc_red[1], pc_red[2])
	assert !pcolor_on(&p)
	assert pc_all(p) == base
}

fn test_pcolor_target_only() {
	base := pc_all(Params{ dither: false })
	mut c := pc_center(pc_red[0], pc_red[1], pc_red[2])
	c.dsat = -100
	mut p := Params{
		dither: false
		pcolor: [c]
	}
	out := pc_all(p)
	// Красное - серое (каналы почти равны), синее и серое - как было
	assert out[0][0] - out[0][2] < 4
	assert out[1] == base[1]
	assert out[2] == base[2]
	// Сдвиг оттенка +100 (+30°): красное уходит к оранжевому - зелёный
	// канал растёт
	c.dsat = 0
	c.dhue = 100
	p.pcolor = [c]
	o2 := pc_all(p)
	assert o2[0][1] > base[0][1] + 20
	assert o2[1] == base[1]
	// Яркость -100: красное темнее
	c.dhue = 0
	c.dlum = -100
	p.pcolor = [c]
	o3 := pc_all(p)
	assert o3[0][0] < base[0][0] - 20
	// В Ч/Б не действует
	p.bw = true
	mut q := Params{
		dither: false
		bw:     true
	}
	assert pc_all(p) == pc_all(q)
}

// «Диапазон»: узкий не задевает соседний оттенок (оранжевый при точке на
// красном), широкий - задевает
fn test_pcolor_range() {
	orange := [u16(30000), 12000, 2000]
	o0, _, _ := pc_px(orange[0], orange[1], orange[2], Params{ dither: false })
	mut c := pc_center(pc_red[0], pc_red[1], pc_red[2])
	c.dlum = -100
	c.range = 0
	mut p := Params{
		dither: false
		pcolor: [c]
	}
	o1, _, _ := pc_px(orange[0], orange[1], orange[2], p)
	assert o1 == o0
	c.range = 100
	p.pcolor = [c]
	o2, _, _ := pc_px(orange[0], orange[1], orange[2], p)
	assert o2 < o0 - 5
	// Вес: в центре 1, далеко - 0
	h := c.hue / 60
	assert pcolor_weight(c, h, c.sat, c.val * 255) == 1
	assert pcolor_weight(c, f32(math.fmod(f64(h) + 3, 6)), c.sat, c.val * 255) == 0
}

fn test_rgb_point() {
	p := rgb_point(200, 100, 0)
	assert p.hue == 30 && p.sat == 1 && p.val == f32(200) / 255
	g := rgb_point(80, 80, 80)
	assert g.sat == 0
}
