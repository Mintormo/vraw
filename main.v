module main

// vraw - консольная проявка RAW в JPEG.
//
// Есть сайдкар правок рядом с RAW (IMG_0001.CR3.vraw.json, его пишет
// vraw-gui) - кадр проявляется по нему той же функцией, что экспорт из
// окна (develop.full): тон, кривые, HSL, коррекция объектива, шумодав,
// пересветы, камерная кривая. Результат совпадает с «Экспорт JPEG» GUI.
// Сайдкара нет - быстрый классический путь LibRaw (8 бит, гамма sRGB,
// авто-яркость, --bright).
import os
import flag
import time
import stbi
import raw
import lens
import develop

fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('vraw')
	fp.version('0.3.0')
	fp.description('Проявка RAW (CR3 и др.) в JPEG. Если рядом есть сайдкар правок vraw-gui ' +
		'(файл.CR3.vraw.json) - по нему, как «Экспорт JPEG» в окне; иначе - через LibRaw.')
	fp.usage_example('vraw IMG_0001.CR3')
	fp.usage_example('vraw IMG_0001.CR3 итог.jpg -q 95 --bright 1.3')
	fp.skip_executable()

	quality := fp.int('quality', `q`, 92, 'качество JPEG, 1-100 (по умолчанию 92)')
	bright := fp.float('bright', `b`, 1.0, 'яркость без сайдкара, 1.0 = как есть')
	half := fp.bool('half', 0, false, 'проявить в половинном размере (быстро, для превью)')

	rest := fp.finalize() or {
		eprintln(err.msg())
		println(fp.usage())
		exit(1)
	}
	if rest.len < 1 {
		println(fp.usage())
		exit(1)
	}

	input := rest[0]
	if !os.exists(input) {
		eprintln('Файл не найден: ${input}')
		exit(1)
	}
	output := if rest.len > 1 { rest[1] } else { input.all_before_last('.') + '.jpg' }

	sw := time.new_stopwatch()
	side_path := develop.sidecar_path(input)
	mut w, mut h, mut ch := 0, 0, 3
	mut data := []u8{}
	if os.exists(side_path) {
		// Испорченный сайдкар - ошибка, а не молчаливая проявка без правок
		f := develop.load(side_path) or {
			eprintln('Сайдкар ${side_path} не прочитан: ${err.msg()}')
			exit(1)
		}
		s := f.state
		// База lensfun (~0.1 с) - только если коррекция объектива включена
		db := if s.lens_corr { lens.load_db() or { unsafe { nil } } } else { unsafe { nil } }
		img := develop.full(input, s, cam_curve: f.camera_curve, db: db, half: half) or {
			eprintln('Ошибка: ${err.msg()}')
			exit(1)
		}
		w, h, data = img.width, img.height, img.rgb
		println('Правки из сайдкара: «${f.history[f.current].name}» (${f.current + 1} из ${f.history.len} в истории)')
		if bright != 1.0 {
			println('--bright не применяется: яркость задана правками')
		}
		println('Проявлено: ${w}x${h}, по правкам (${f64(sw.elapsed().milliseconds()) / 1000:.1f} с)')
	} else {
		mut dev := raw.open(input) or {
			eprintln('Ошибка: ${err.msg()}')
			exit(1)
		}
		defer {
			dev.close()
		}
		mut img := dev.develop(bright: f32(bright), half: half) or {
			eprintln('Ошибка: ${err.msg()}')
			exit(1)
		}
		w, h, ch = img.width, img.height, img.colors
		data = []u8{len: w * h * ch}
		unsafe { vmemcpy(data.data, img.data(), data.len) }
		img.free()
		println('Проявлено: ${w}x${h}, ${ch} канала по 8 бит (${f64(sw.elapsed().milliseconds()) / 1000:.1f} с)')
	}

	stbi.stbi_write_jpg(output, w, h, ch, data.data, quality) or {
		eprintln('Не удалось сохранить JPEG: ${err}')
		exit(1)
	}

	out_size := os.file_size(output)
	println('Сохранено: ${output} (${f64(out_size) / 1024 / 1024:.1f} МБ, качество ${quality})')
}
