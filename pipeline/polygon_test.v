module pipeline

// Многоугольник фильтра (local.v, raster_polygon): внутри - полное
// действие, снаружи - нет, мягкий край внутрь контура по растушёвке,
// «снаружи» - наоборот; меньше трёх вершин - формы нет; часть-
// многоугольник вычитается из основы; копия - свои вершины

fn pg_map(w int, h int) MaskMap {
	return mask_map(Geom{}, w, h, true, w, h)
}

// Квадрат 0.25..0.75 по обеим осям
fn pg_square() []f32 {
	return [f32(0.25), 0.25, 0.75, 0.25, 0.75, 0.75, 0.25, 0.75]
}

fn test_polygon_inside_outside() {
	w := 200
	h := 100
	m := Mask{
		kind:     .polygon
		pts:      pg_square()
		feather:  20
		exposure: 1
	}
	g := mask_weights(m, pg_map(w, h), w, h)
	assert g[50 * w + 100] == 255 // центр
	assert g[5 * w + 5] == 0 // угол кадра
	assert g[50 * w + 30] == 0 // левее контура (x = 0.15)
	// Растушёвка 20 - край 2% высоты внутрь: у самого контура слабо, чуть
	// глубже - полное
	edge := g[50 * w + 50] // x ≈ 0.2525: 0.005 высоты от левой стороны
	assert edge > 0 && edge < 200
	assert g[50 * w + 60] == 255
	// Без растушёвки край жёсткий (сглаживание - в клетку сетки)
	mut hard := m
	hard.feather = 0
	gh := mask_weights(hard, pg_map(w, h), w, h)
	assert gh[50 * w + 52] == 255
	// Снаружи контура
	mut inv := m
	inv.invert = true
	gi := mask_weights(inv, pg_map(w, h), w, h)
	assert gi[50 * w + 100] == 0 && gi[5 * w + 5] == 255
}

// Треугольник: точка внутри и снаружи наклонной стороны
fn test_polygon_triangle() {
	w := 100
	h := 100
	m := Mask{
		kind:     .polygon
		pts:      [f32(0.1), 0.9, 0.9, 0.9, 0.1, 0.1]
		feather:  0
		exposure: 1
	}
	g := mask_weights(m, pg_map(w, h), w, h)
	assert g[80 * w + 20] == 255 // под гипотенузой
	assert g[20 * w + 80] == 0 // над ней
}

fn test_polygon_degenerate_and_parts() {
	w := 120
	h := 80
	// Две вершины - формы нет (фильтр не действует)
	two := Mask{
		kind:     .polygon
		pts:      [f32(0.2), 0.2, 0.8, 0.8]
		exposure: 1
	}
	assert mask_weights(two, pg_map(w, h), w, h).all(it == 0)
	// Линейный на весь кадр минус многоугольник: в квадрате - пусто
	mut lin := Mask{
		kind:     .linear
		ax:       0.5
		ay:       -1
		bx:       0.5
		by:       -0.5
		exposure: 1
	}
	full := mask_weights(lin, pg_map(w, h), w, h)
	assert full[40 * w + 60] == 0 || full[40 * w + 60] == 255
	lin.ay = 2
	lin.by = 3 // переход за кадром снизу: весь кадр - полное действие
	assert mask_weights(lin, pg_map(w, h), w, h)[40 * w + 60] == 255
	lin.parts << MaskPart{
		kind:    .polygon
		op:      .subtract
		pts:     pg_square()
		feather: 0
	}
	g := mask_weights(lin, pg_map(w, h), w, h)
	assert g[40 * w + 60] == 0
	assert g[5 * w + 5] == 255
	// Копия - свои вершины (снимок истории не меняется)
	c := lin.copy()
	lin.parts[0].pts[0] = 0.5
	assert c.parts[0].pts[0] == 0.25
	mut b := Mask{
		kind: .polygon
		pts:  pg_square()
	}
	cb := b.copy()
	b.pts[1] = 0.9
	assert cb.pts[1] == 0.25
	// Основа - через shape / set_shape
	assert b.shape(-1).pts == b.pts
}
