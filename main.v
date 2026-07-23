module main

import os
import flag
import time
import stbi
import raw

fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('vraw')
	fp.version('0.2.0')
	fp.description('Проявка RAW (CR3 и др.) в JPEG через LibRaw')
	fp.usage_example('vraw IMG_0001.CR3')
	fp.usage_example('vraw IMG_0001.CR3 итог.jpg -q 95 --bright 1.3')
	fp.skip_executable()

	quality := fp.int('quality', `q`, 92, 'качество JPEG, 1-100 (по умолчанию 92)')
	bright := fp.float('bright', `b`, 1.0, 'яркость, 1.0 = как есть')
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
	defer {
		img.free()
	}

	println('Проявлено: ${img.width}x${img.height}, ${img.colors} канала по 8 бит (${f64(sw.elapsed().milliseconds()) / 1000:.1f} с)')

	stbi.stbi_write_jpg(output, img.width, img.height, img.colors, img.data(), quality) or {
		eprintln('Не удалось сохранить JPEG: ${err}')
		exit(1)
	}

	out_size := os.file_size(output)
	println('Сохранено: ${output} (${f64(out_size) / 1024 / 1024:.1f} МБ, качество ${quality})')
}
