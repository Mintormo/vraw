module main

// Точечный цвет в приложении (pcolor_ui.v): сайдкар туда и обратно и
// пределы, не больше pcolor_max точек, старый файл без поля, копирование
// группой «HSL», снимок истории не делит точки с живым состоянием
import pipeline

fn pc_sample_points() []pipeline.PointColor {
	return [
		pipeline.PointColor{
			hue:   12.5
			sat:   0.6
			val:   0.7
			dhue:  20
			dsat:  -35
			dlum:  10
			range: 40
		},
		pipeline.PointColor{
			hue:  210
			sat:  0.3
			val:  0.5
			dsat: 50
		},
	]
}

fn test_pcolor_sidecar() {
	mut e := neutral_edit()
	e.params.pcolor = pc_sample_points()
	text := encode_history([HistEntry{
		name:  'Открыт файл'
		state: neutral_edit()
	}, HistEntry{
		name:  'Точечный цвет'
		state: e
	}], 1, Mark{})
	assert text.contains('"pcolor": [{"hue": 12.5, "sat": 0.6, "val": 0.7, "dhue": 20, "dsat": -35, "dlum": 10, "range": 40}')
	// У нейтрального снимка поля нет (пусто - по умолчанию)
	assert text.contains('{"name": "Открыт файл", "state": {}}')
	l := decode_sidecar(text)!
	assert l.history[1].state.params.pcolor == e.params.pcolor
	assert l.history[0].state.params.pcolor.len == 0
	// Чужие значения - в пределах; лишние точки отбрасываются
	mut many := []SidePColor{}
	for i in 0 .. pipeline.pcolor_max + 3 {
		many << SidePColor{
			hue:   f32(400 + i)
			sat:   2
			val:   -1
			dhue:  500
			dsat:  -500
			dlum:  0
			range: 150
		}
	}
	b := edit_state(SideState{
		...side_state(neutral_edit())
		pcolor: many
	})!
	assert b.params.pcolor.len == pipeline.pcolor_max
	c := b.params.pcolor[0]
	assert c.hue == 0 && c.sat == 1 && c.val == 0 && c.dhue == 100 && c.dsat == -100
	assert c.range == 100
}

fn test_pcolor_groups_and_clone() {
	mut src := neutral_edit()
	src.params.pcolor = pc_sample_points()
	dst := neutral_edit()
	// Группа «HSL» переносит точки, другие группы - нет
	m := merge_groups(dst, src, ['hsl'])
	assert m.params.pcolor == src.params.pcolor
	assert merge_groups(dst, src, ['tone', 'color']).params.pcolor.len == 0
	// Снимок истории - своя копия точек
	snap := src.clone()
	src.params.pcolor[0].dhue = -70
	assert snap.params.pcolor[0].dhue == 20
}
