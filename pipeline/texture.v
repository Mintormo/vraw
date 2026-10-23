module pipeline

// Текстура (Texture, как в Lightroom): средняя детализация - листва, кора,
// ткань, камень - сильнее или мягче, почти не трогая мелкий шум и крупные
// перепады. Проход по тоновому буферу (×256, после HSL) перед резкостью,
// по люме - одна добавка на все каналы (цвет не сдвигается):
//
//   L - люма тонов (BT.709), B1, B2 - L, размытая гауссом tx_fine и
//   tx_coarse пикселей полного кадра (половинное превью - радиусы × scale);
//   деталь средней полосы d = B1 - B2 (мельче tx_fine - шум и резкость,
//   крупнее tx_coarse - Clarity и тон);
//   плюс:  порог d·d²/(d² + t²), t = tx_noise уровня - шум почти не
//          усиливается; предел d / (1 + |d| / tx_edge) - на сильном крае
//          (ветки на фоне неба) добавка ограничена, без ореолов;
//          L += texture/100 · tx_gain · d;
//   минус: L += texture/100 · d (−100 - полоса убрана целиком: кожа,
//          ткань мягче), предел краёв tx_edge_neg - контуры не плывут.
//
// Проверка (07.10.2026, превью-размер, СКО полосы 1-4 px): +100 - средняя
// деталь травы IMG_0817 ×1.35, листвы и кирпича IMG_0991 ×1.25 и ×1.2,
// шум неба почти тот же (+0.1 уровня), средняя яркость неба не меняется;
// −100 - деталь ×0.65. На 100% ореолов у листвы на фоне стены не видно.
import bigbuf

const tx_fine = f32(1.5)
const tx_coarse = f32(6.0)
const tx_gain = f32(1.5)
const tx_noise = f32(0.8)
const tx_edge = f32(6.0)
const tx_edge_neg = f32(12.0)

// texture_tone - текстура по тоновому буферу tone (w x h x 3, ×256) на
// месте; amount -100..100, scale - масштаб кадра относительно полного
pub fn texture_tone(mut tone []u16, w int, h int, amount f32, scale f32) {
	if amount == 0 || w < 3 || h < 3 {
		return
	}
	npix := w * h
	mut l := bigbuf.new_f32(npix)
	for i in 0 .. npix {
		l[i] = (0.2126 * f32(tone[3 * i]) + 0.7152 * f32(tone[3 * i + 1]) +
			0.0722 * f32(tone[3 * i + 2])) * f32(1.0 / 256.0)
	}
	mut s1 := tx_fine * scale
	if s1 < 0.5 {
		s1 = 0.5
	}
	mut s2 := tx_coarse * scale
	if s2 < s1 * 2 {
		s2 = s1 * 2
	}
	mut b1 := gauss_blur(l, w, h, s1)
	mut b2 := gauss_blur(l, w, h, s2)
	defer {
		bigbuf.free(mut l)
		bigbuf.free(mut b1)
		bigbuf.free(mut b2)
	}
	a := amount / 100
	t2 := tx_noise * tx_noise
	unsafe {
		p1 := &f32(b1.data)
		p2 := &f32(b2.data)
		mut pt := &u16(tone.data)
		for i in 0 .. npix {
			d := p1[i] - p2[i]
			add := if a > 0 {
				dt := soft_threshold(d, t2)
				a * tx_gain * dt / (1 + abs_f(dt) / tx_edge)
			} else {
				a * d / (1 + abs_f(d) / tx_edge_neg)
			}
			if add != 0 {
				k := add * 256
				for c in 0 .. 3 {
					v := f32(pt[c]) + k
					pt[c] = if v <= 0 { u16(0) } else if v >= 65535 { u16(65535) } else { u16(v + 0.5) }
				}
			}
			pt += 3
		}
	}
}

@[inline]
fn abs_f(v f32) f32 {
	return if v < 0 { -v } else { v }
}
