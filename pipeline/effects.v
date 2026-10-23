module pipeline

// Эффекты (как «Эффекты» Lightroom): художественная виньетка после
// кадрирования и плёночное зерно. Оба - по кадру после геометрии, в
// тоновом пространстве, в конце проявки:
//
//   виньетка - проход по тоновому буферу (×256) после текстуры, до
//   резкости (fx_tone); зерно - поле шума (fx_tone пишет его в буфер
//   grain), добавляется к выходу резкости перед квантованием в 8 бит
//   (sharpen_tone) - резкость зерно не усиливает.
//
// Виньетка. Точка кадра в долях полуосей: dx = (x - W/2)/(W/2), dy так
// же - эллипс, вписанный в кадр, углы на расстоянии √2.
//   округлость ro > 0 - оси тянутся к окружности (ro = 1 - круг с той же
//     дальностью углов); ro < 0 - суперэллипс степени p = 2 + 6·|ro|
//     (ближе к прямоугольнику кадра), расстояние нормировано так, что углы
//     остаются на √2;
//   вес w = smoothstep(r - f, r + f, d), r = 0.5 + 0.75·mid (средняя
//     точка 0..1), f = 0.03 + 0.6·feather (растушёвка 0..1);
//   минус (тёмная): v' = v · 2^(a·w·vig_ev / 2.2) - экспозиция у краёв,
//     одинаковая для R, G, B (цвет не сдвигается); плюс (светлая):
//     1 - v' = (1 - v) · 2^(-a·w·vig_ev / 2.2) - к белому, без клипа.
//
// Зерно. Шум значений (value noise) на решётке с шагом sz пикселей
// ПОЛНОГО кадра (размер 0..100 -> sz = 0.8..4.8 px): случайное значение в
// узле (хэш координат узла), между узлами - гладкая интерполяция; вторая
// октава sz/2 и «комки» (шум 4·sz, модуляция величины) - по грубости.
// Координаты - пиксели полного выходного кадра, поэтому фрагмент 1:1 и
// экспорт дают одно и то же зерно; половинное превью видит поле реже, а
// величина × min(1, sz·scale) - примерно как полный кадр, уменьшенный на
// экран. Одна добавка на R, G, B (монохромное), сильнее в средних тонах:
// вес 0.25 + 0.75·4t(1 - t) по тону люмы.
import math

const vig_ev = f32(3.0) // ±100 - ±3 EV у углов
const grain_levels = f32(30.0) // величина 100 - пик ±30 уровней из 255

// Effects - ползунки эффектов. Нули величин - эффектов нет (проходов
// тоже нет); остальное - форма, по умолчанию как в Lightroom
pub struct Effects {
pub mut:
	vig_amount  f32 // виньетка -100..100: минус темнее, плюс светлее
	vig_mid     f32 = 50 // средняя точка 0..100: больше - уже, ближе к углам
	vig_round   f32 // округлость -100..100: минус - к прямоугольнику, плюс - к кругу
	vig_feather f32 = 50 // растушёвка 0..100: 0 - резкая граница
	grain       f32 // зерно, величина 0..100
	grain_size  f32 = 25 // размер 0..100
	grain_rough f32 = 50 // грубость 0..100: неровность, крупные комки
}

// has_vignette / has_grain - эффект включён (величина не 0)
pub fn (e Effects) has_vignette() bool {
	return e.vig_amount != 0
}

pub fn (e Effects) has_grain() bool {
	return e.grain > 0
}

pub fn (e Effects) active() bool {
	return e.has_vignette() || e.has_grain()
}

// FxMap - место рендерного буфера в выходном кадре (после геометрии):
// пиксель (0, 0) буфера - пиксель (x, y) кадра fw x fh (в пикселях
// буфера). Производное поле Params.fxmap; fw == 0 - буфер и есть весь
// кадр (превью, экспорт). Задаётся для фрагмента настоящего 1:1.
pub struct FxMap {
pub:
	x  int
	y  int
	fw int
	fh int
}

// grain_px - шаг решётки зерна в пикселях полного кадра
fn grain_px(size f32) f32 {
	return 0.8 + 4.0 * clamp01(size / 100)
}

// FxCtx - входы прохода fx_rows (общие для потоков; каждый поток пишет
// свои строки tone и grain)
struct FxCtx {
	tone  &u16 = unsafe { nil }
	grain &u8  = unsafe { nil } // nil - зерна нет; 128 - ноль
	w     int
	// Виньетка
	vig   bool
	va    f32 // величина -1..1
	cx    f64 // центр кадра в пикселях буфера
	cy    f64
	kx    f64 // множители: пиксели буфера -> доли полуосей (с округлостью)
	ky    f64
	pw    f64 // степень суперэллипса (2 - эллипс)
	pn    f64 // нормировка суперэллипса: углы - √2
	e0    f32 // smoothstep от e0 до e1
	e1    f32
	// Зерно: координаты полного кадра X = (x + ox) / scale
	ox    f64
	oy    f64
	inv   f64 // 1 / (scale · sz) - пиксель буфера в шагах решётки
	rough f32
}

// fx_tone - виньетка по тоновому буферу tone (w x h x 3, ×256) на месте и
// поле зерна в grain (npix байт, 128 - ноль; пустой - без зерна). fm -
// место буфера в кадре, scale - масштаб буфера относительно полного кадра
fn fx_tone(mut tone []u16, mut grain []u8, w int, h int, fx Effects, fm FxMap, scale f32) {
	if !fx.active() || w < 1 || h < 1 {
		return
	}
	fw := if fm.fw > 0 { fm.fw } else { w }
	fh := if fm.fw > 0 { fm.fh } else { h }
	mut c := FxCtx{
		tone: unsafe { &u16(tone.data) }
		w:    w
	}
	if fx.has_vignette() {
		hw := f64(fw) / 2
		hh := f64(fh) / 2
		ro := f64(clampf(fx.vig_round / 100, -1, 1))
		mut kx := 1.0 / hw
		mut ky := 1.0 / hh
		mut pw := 2.0
		if ro > 0 {
			// Круг с той же дальностью углов: радиус - полудиагональ / √2
			r := math.sqrt(hw * hw + hh * hh) / math.sqrt2
			kx += (1.0 / r - kx) * ro
			ky += (1.0 / r - ky) * ro
		} else if ro < 0 {
			pw = 2 + 6 * -ro
		}
		mid := clamp01(fx.vig_mid / 100)
		fe := clamp01(fx.vig_feather / 100)
		rm := 0.5 + 0.75 * mid
		hf := 0.03 + 0.6 * fe
		c = FxCtx{
			...c
			vig: true
			va:  clampf(fx.vig_amount / 100, -1, 1)
			cx:  hw - f64(fm.x)
			cy:  hh - f64(fm.y)
			kx:  kx
			ky:  ky
			pw:  pw
			pn:  math.sqrt2 / math.pow(2, 1 / pw)
			e0:  rm - hf
			e1:  rm + hf
		}
	}
	if fx.has_grain() && grain.len >= w * h {
		sz := f64(grain_px(fx.grain_size))
		c = FxCtx{
			...c
			grain: unsafe { &u8(grain.data) }
			ox:    f64(fm.x)
			oy:    f64(fm.y)
			inv:   1.0 / (f64(scale) * sz)
			rough: clamp01(fx.grain_rough / 100)
		}
	}
	nt := bands(w, h)
	step := (h + nt - 1) / nt
	mut ts := []thread{}
	for y0 := 0; y0 < h; y0 += step {
		ts << spawn fx_rows(&c, y0, imin(h, y0 + step))
	}
	ts.wait()
}

// fx_rows - строки y0..y1: виньетка в tone, зерно в grain. Расстояние
// суперэллипса раскладывается по осям: |dx|^p - один раз на столбец,
// |dy|^p - на строку, на пиксель - одна степень 1/p (корень при p = 2)
fn fx_rows(c &FxCtx, y0 int, y1 int) {
	ev := f32(c.va) * vig_ev / 2.2
	mut cx := []f32{}
	if c.vig {
		cx = []f32{len: c.w}
		for x in 0 .. c.w {
			cx[x] = f32(math.pow(math.abs((f64(x) + 0.5 - c.cx) * c.kx), c.pw))
		}
	}
	ip := f32(1 / c.pw)
	pn := f32(c.pn)
	for y in y0 .. y1 {
		cy := f32(math.pow(math.abs((f64(y) + 0.5 - c.cy) * c.ky), c.pw))
		gy := (f64(y) + 0.5 + c.oy) * c.inv
		for x in 0 .. c.w {
			i := y * c.w + x
			if c.vig {
				q := cx[x] + cy
				d := if c.pw == 2 { f32(math.sqrtf(q)) } else { math.powf(q, ip) * pn }
				wv := smoothstep(c.e0, c.e1, d)
				if wv > 0 {
					unsafe {
						mut pt := c.tone + 3 * i
						if c.va < 0 {
							k := exp2f(ev * wv)
							for ch in 0 .. 3 {
								pt[ch] = u16(f32(pt[ch]) * k + 0.5)
							}
						} else {
							k := exp2f(-ev * wv)
							for ch in 0 .. 3 {
								pt[ch] = u16(65535 - (65535 - f32(pt[ch])) * k + 0.5)
							}
						}
					}
				}
			}
			if !isnil(c.grain) {
				n := grain_at((f64(x) + 0.5 + c.ox) * c.inv, gy, c.rough)
				unsafe {
					c.grain[i] = u8(128 + int(math.round(f64(clampf(n, -1, 1)) * 127)))
				}
			}
		}
	}
}

// grain_at - поле зерна в точке (u, v) в шагах решётки, -1..1: октава
// шага 1 и, по грубости r, октава 1/2 и модуляция «комками» (шаг 4)
@[inline]
fn grain_at(u f64, v f64, r f32) f32 {
	mut n := vnoise(u, v, 0x9e3779b9)
	if r > 0 {
		n2 := vnoise(u * 2, v * 2, 0x85ebca6b)
		clump := vnoise(u * 0.25, v * 0.25, 0xc2b2ae35)
		n = (n * (1 - 0.5 * r) + n2 * 0.5 * r) * (1 + 0.6 * r * clump)
	}
	return n
}

// vnoise - шум значений: узлы целочисленной решётки - хэш в -1..1, между
// ними - билинейно с гладким весом 3t² - 2t³
@[inline]
fn vnoise(u f64, v f64, seed u32) f32 {
	fu := math.floor(u)
	fv := math.floor(v)
	iu := int(fu)
	iv := int(fv)
	mut tu := f32(u - fu)
	mut tv := f32(v - fv)
	tu = tu * tu * (3 - 2 * tu)
	tv = tv * tv * (3 - 2 * tv)
	a := lat(iu, iv, seed)
	b := lat(iu + 1, iv, seed)
	cc := lat(iu, iv + 1, seed)
	d := lat(iu + 1, iv + 1, seed)
	top := a + (b - a) * tu
	bot := cc + (d - cc) * tu
	return top + (bot - top) * tv
}

// lat - значение узла решётки (x, y): целочисленный хэш -> -1..1
@[inline]
fn lat(x int, y int, seed u32) f32 {
	mut hs := u32(x) * 0x27d4eb2d ^ u32(y) * 0x165667b1 ^ seed
	hs ^= hs >> 15
	hs *= 0x2c1b3c6d
	hs ^= hs >> 12
	hs *= 0x297a2d39
	hs ^= hs >> 15
	return f32(hs >> 8) * f32(2.0 / 16777216.0) - 1
}

// grain_amp - пик зерна в уровнях 0..255 для буфера масштаба scale
fn grain_amp(fx Effects, scale f32) f32 {
	cell := grain_px(fx.grain_size) * scale
	att := if cell < 1 { cell } else { f32(1) }
	return clamp01(fx.grain / 100) * grain_levels * att
}

// grain_weight - вес зерна по тону люмы l (0..255): сильнее в средних
@[inline]
fn grain_weight(l f32) f32 {
	t := clamp01(l / 255)
	return 0.25 + 3 * t * (1 - t)
}

@[inline]
fn smoothstep(e0 f32, e1 f32, x f32) f32 {
	if x <= e0 {
		return 0
	}
	if x >= e1 {
		return 1
	}
	t := (x - e0) / (e1 - e0)
	return t * t * (3 - 2 * t)
}

@[inline]
fn clamp01(v f32) f32 {
	return clampf(v, 0, 1)
}
