module ai

// Модель шумодава и где она лежит. Модель одна - SCUNet (вариант «real
// PSNR»: бережёт детали, ничего не выдумывает). Она и ONNX Runtime идут
// вместе с vraw, в папках рядом с программой (переносимо, без установки):
//   <папка vraw>/models/       - файлы модели
//   <папка vraw>/onnxruntime/  - ONNX Runtime (официальная сборка с GitHub)
// Кладёт их туда сборка (tools/fetch_ai.sh, tools/portable.sh): адреса и
// sha256 - там. Нет файлов - vraw работает без AI.
import os

pub struct ModelFile {
pub:
	name string
	size i64
}

pub struct ModelInfo {
pub:
	id    string // ключ в сайдкаре
	title string // короткое имя (в окне)
	files []ModelFile // первый - сам .onnx, его путь открывает ORT
	// секунд на плитку 256x256 (i5-1235U, 12 потоков) - для оценок времени
	tile_secs f64
}

// model - модель шумодава: граф .onnx и веса .onnx.data рядом с ним
// (cszn/SCUNet, Apache-2.0, ONNX-перевод весов - Heliosoph/scunet-onnx)
pub const model = ModelInfo{
	id:        'scunet_real_psnr'
	title:     'SCUNet'
	files:     [
		ModelFile{'scunet_color_real_psnr.onnx', 3798678},
		ModelFile{'scunet_color_real_psnr.onnx.data', 73138176},
	]
	tile_secs: 2.0
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

// installed - все файлы модели на месте и нужного размера (sha256
// проверяет сборка: 70 МБ на каждый запуск считать незачем)
pub fn (m ModelInfo) installed(p Places) bool {
	for f in m.files {
		path := os.join_path(p.models, f.name)
		if !os.is_file(path) || os.file_size(path) != u64(f.size) {
			return false
		}
	}
	return true
}

// ONNX Runtime - официальная сборка с GitHub (MIT), заголовки для сборки
// vraw - в ai/include той же версии. Библиотеке в Windows нужны DLL
// Microsoft Visual C++ (обычно уже стоят).
pub const runtime_version = '1.30.0'

// runtime_lib_name - библиотека ORT внутри папки runtime
pub const runtime_lib_name = $if windows { 'lib/onnxruntime.dll' } $else { 'lib/libonnxruntime.so.1' }

// runtime_lib - путь к библиотеке ORT в папке runtime; пусто - не
// установлена
pub fn runtime_lib(p Places) string {
	lib := os.join_path(p.runtime, runtime_lib_name)
	return if os.exists(lib) { lib } else { '' }
}
