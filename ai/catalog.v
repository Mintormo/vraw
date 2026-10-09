module ai

// Каталог: какие модели шумодава знает vraw, откуда их скачать и где они
// лежат. Всё скачиваемое - рядом с программой (переносимо, без установки):
//   <папка vraw>/models/       - файлы моделей
//   <папка vraw>/onnxruntime/  - ONNX Runtime (официальная сборка с GitHub)
// Размеры и sha256 - для проверки скачанного; одна модель - один или
// несколько файлов (SCUNet: граф .onnx и веса .onnx.data рядом с ним).
import os

pub struct ModelFile {
pub:
	name   string
	url    string // пусто - не скачивается (получить вручную)
	size   i64
	sha256 string
}

pub struct ModelInfo {
pub:
	id    string // ключ в настройках и сайдкаре
	title string // короткое имя (в окне)
	note  string // чем хороша, чем плоха
	files []ModelFile // первый - сам .onnx, его путь открывает ORT
	// секунд на плитку 256x256 (i5-1235U, 12 потоков) - для оценок времени
	tile_secs f64
	license   string
}

// id модели по умолчанию - для новых установок
pub const default_model = 'scunet_real_psnr'

const hf_scunet = 'https://huggingface.co/Heliosoph/scunet-onnx/resolve/main/'

pub const models = [
	ModelInfo{
		id:        'scunet_real_psnr'
		title:     'SCUNet'
		note:      'Точная: бережёт детали, ничего не выдумывает. Медленная.'
		files:     [
			ModelFile{'scunet_color_real_psnr.onnx', hf_scunet + 'scunet_color_real_psnr.onnx', 3798678, '231be201ab413dbc999d7951caa9844846b93a12a40a41e037d6b5888ed4e88c'},
			ModelFile{'scunet_color_real_psnr.onnx.data', hf_scunet + 'scunet_color_real_psnr.onnx.data', 73138176, '98825ea1210b641c71e5f052f582c70c49fd44b35387ebe2c034268c17df3feb'},
		]
		tile_secs: 2.0
		license:   'Apache-2.0'
	},
	ModelInfo{
		id:        'scunet_real_gan'
		title:     'SCUNet GAN'
		note:      'Резче: дорисовывает правдоподобную текстуру. Медленная.'
		files:     [
			ModelFile{'scunet_color_real_gan.onnx', hf_scunet + 'scunet_color_real_gan.onnx', 3798249, 'e2bf014ad711f99322f2a94304431ffd6766b79ff00bcebb87d1a4f71c127b2d'},
			ModelFile{'scunet_color_real_gan.onnx.data', hf_scunet + 'scunet_color_real_gan.onnx.data', 73138176, '1e8d582046abf4a773215445c248d0f54751a57d69d2a2312ec59f1150256b79'},
		]
		tile_secs: 2.0
		license:   'Apache-2.0'
	},
	ModelInfo{
		id:        'nafnet_sidd_w32'
		title:     'NAFNet'
		note:      'Быстрая, но мылит мелкие детали. Только своя сборка (tools/).'
		files:     [
			ModelFile{'nafnet_sidd_w32.onnx', '', 117085442, ''},
		]
		tile_secs: 0.33
		license:   'MIT'
	},
]

// find_model_info - модель каталога по id
pub fn find_model_info(id string) ?ModelInfo {
	for m in models {
		if m.id == id {
			return m
		}
	}
	return none
}

// Places - где лежат модели и ORT: папка программы (в тестах - корень
// проекта, где и собирается ./vraw)
pub struct Places {
pub:
	models  string
	runtime string
}

pub fn places(root string) Places {
	return Places{
		models:  os.join_path(root, 'models')
		runtime: os.join_path(root, 'onnxruntime')
	}
}

// path - путь к .onnx модели в папке моделей
pub fn (m ModelInfo) path(p Places) string {
	return os.join_path(p.models, m.files[0].name)
}

// installed - все файлы модели на месте и нужного размера (sha256 - только
// при скачивании: 70 МБ на каждый запуск считать незачем)
pub fn (m ModelInfo) installed(p Places) bool {
	for f in m.files {
		path := os.join_path(p.models, f.name)
		if !os.is_file(path) || os.file_size(path) != u64(f.size) {
			return false
		}
	}
	return true
}

// downloadable - у всех файлов есть адрес
pub fn (m ModelInfo) downloadable() bool {
	return m.files.all(it.url != '')
}

// size - общий размер файлов модели, байт
pub fn (m ModelInfo) size() i64 {
	mut n := i64(0)
	for f in m.files {
		n += f.size
	}
	return n
}

// ONNX Runtime: официальная сборка с GitHub (MIT). Заголовки для сборки
// vraw - в ai/include той же версии. Для Windows - zip (82 МБ: внутри
// отладочные .pdb, при распаковке пропускаются), библиотеке нужны DLL
// Microsoft Visual C++ (обычно уже стоят).
pub const runtime_version = '1.30.0'
pub const runtime_file = $if windows {
	ModelFile{
		name:   'onnxruntime-win-x64-${runtime_version}.zip'
		url:    'https://github.com/microsoft/onnxruntime/releases/download/v${runtime_version}/onnxruntime-win-x64-${runtime_version}.zip'
		size:   82645522
		sha256: 'c6ba983baf5681af108599675d2a89c2d145512d02de28aed0bff177cd0ba949'
	}
} $else {
	ModelFile{
		name:   'onnxruntime-linux-x64-${runtime_version}.tgz'
		url:    'https://github.com/microsoft/onnxruntime/releases/download/v${runtime_version}/onnxruntime-linux-x64-${runtime_version}.tgz'
		size:   11306877
		sha256: 'a5ed5a3cac51fbb2e90da632ae43d19212faaa20e76484e62bcb7c23ddb3b3fd'
	}
}

// runtime_lib_name - библиотека ORT внутри папки runtime
pub const runtime_lib_name = $if windows { 'lib/onnxruntime.dll' } $else { 'lib/libonnxruntime.so.1' }

// runtime_lib - путь к библиотеке ORT в папке runtime; пусто - не
// установлена
pub fn runtime_lib(p Places) string {
	lib := os.join_path(p.runtime, runtime_lib_name)
	return if os.exists(lib) { lib } else { '' }
}
