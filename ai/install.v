module ai

// Скачивание моделей и ONNX Runtime в папки рядом с программой (Places).
// Файл качается во временный «.part» рядом с целевым; только когда он
// докачан целиком и совпали размер и sha256 - переименование на место.
// Поэтому оборванное или испорченное скачивание не оставляет «модель»,
// которую installed() принял бы за готовую. Всё - в потоке вызывающего
// (в vraw - фоновый поток), прогресс - callback'ом.
//
// Докачка: при обрыве .part остаётся, запрос повторяется с заголовком
// Range: bytes=N- (сервер отвечает 206 и отдаёт хвост) - несколько
// попыток с паузой; не вышло - .part лежит до следующего «Скачать», и
// тогда качается тоже с места обрыва. Сервер без поддержки Range отвечает
// 200 - файл качается заново. Отмена пользователем .part удаляет.
import os
import time
import net.http
import crypto.sha256
import i18n

const fetch_attempts = 5

// Sink - приём тела одной попытки: дописывает в .part, сообщает прогресс
// по всем файлам задания (base - уже скачанное предыдущими файлами).
// progress вернул false - отмена (ошибка из callback'а обрывает запрос).
@[heap]
struct Sink {
mut:
	f         os.File
	opened    bool
	path      string
	got       i64 // байт в .part (с учётом скачанного до этой попытки)
	base      i64
	total     i64
	progress  fn (done i64, total i64) bool = unsafe { nil }
	cancelled bool
}

fn (mut s Sink) chunk(chunk []u8, status int) ! {
	// Тело редиректа или ошибки - не файл
	if status != 200 && status != 206 {
		return
	}
	if !s.opened {
		// 206 - хвост к уже скачанному; 200 - сервер отдаёт файл целиком
		if status == 200 {
			s.f = os.create(s.path)!
			s.got = 0
		} else {
			s.f = os.open_append(s.path)!
		}
		s.opened = true
	}
	s.f.write(chunk)!
	s.got += chunk.len
	if !s.progress(s.base + s.got, s.total) {
		s.cancelled = true
		return error(i18n.tr('отменено'))
	}
}

fn (mut s Sink) close() {
	if s.opened {
		s.f.close()
		s.opened = false
	}
}

// file_sha256 - сумма файла потоково (модель ~70 МБ - не в память целиком)
fn file_sha256(path string) !string {
	mut f := os.open(path)!
	defer {
		f.close()
	}
	mut h := sha256.new()
	mut buf := []u8{len: 1 << 20}
	for {
		n := f.read(mut buf) or { break }
		if n <= 0 {
			break
		}
		h.write(buf[..n])!
	}
	return h.sum([]).hex()
}

// wait_or_cancel - пауза перед повтором; false - пользователь отменил
fn wait_or_cancel(ms int, done i64, total i64, progress fn (done i64, total i64) bool) bool {
	for _ in 0 .. ms / 250 {
		if !progress(done, total) {
			return false
		}
		time.sleep(250 * time.millisecond)
	}
	return progress(done, total)
}

// part_size - сколько уже лежит в .part
fn part_size(part string) i64 {
	return if os.is_file(part) { i64(os.file_size(part)) } else { 0 }
}

// fetch - один файл в dest через dest.part с докачкой и проверкой;
// base/total - для общего прогресса задания
fn fetch(f ModelFile, dest string, base i64, total i64, progress fn (done i64, total i64) bool) ! {
	part := dest + '.part'
	mut last_err := ''
	mut resumed := false // .part был до этой попытки - при порче качать заново
	for attempt in 0 .. fetch_attempts {
		mut have := part_size(part)
		if have > f.size {
			os.rm(part)!
			have = 0
		}
		if attempt > 0 && !wait_or_cancel(1000 * attempt, base + have, total, progress) {
			os.rm(part) or {}
			return Cancelled{}
		}
		resumed = resumed || have > 0
		if have < f.size {
			mut sink := &Sink{
				path:     part
				got:      have
				base:     base
				total:    total
				progress: progress
			}
			mut header := http.new_header()
			if have > 0 {
				header.add(.range, 'bytes=${have}-')
			}
			// HTTP/1.1: HTTP/2-клиент V (0.5.2) качает большие файлы в
			// десятки раз медленнее (3.8 МБ с huggingface - 2 с против >2 мин)
			resp := http.fetch(
				url:                f.url
				header:             header
				enable_http2:       false
				stop_copying_limit: 65536 // тело - в файл, не в память
				on_progress_body:   fn [sink] (_ &http.Request, chunk []u8, _ u64, _ u64, status int) ! {
					mut s := unsafe { sink }
					s.chunk(chunk, status)!
				}
			) or {
				sink.close()
				if sink.cancelled {
					os.rm(part) or {}
					return Cancelled{}
				}
				last_err = err.msg()
				continue
			}
			sink.close()
			if resp.status_code == 416 {
				// Range за концом файла - .part не тот, заново
				os.rm(part)!
				last_err = i18n.tr('сервер отверг докачку')
				continue
			}
			if resp.status_code != 200 && resp.status_code != 206 {
				return error(i18n.trf('{0}: сервер ответил {1}', '${f.name}', '${resp.status_code}'))
			}
			if part_size(part) < f.size {
				last_err = i18n.tr('соединение оборвалось')
				continue
			}
		}
		got := part_size(part)
		if got != f.size {
			os.rm(part)!
			return error(i18n.trf('{0}: размер {1} байт вместо {2}', '${f.name}', '${got}', '${f.size}'))
		}
		if file_sha256(part)! != f.sha256 {
			os.rm(part)!
			if resumed {
				// Порченый хвост прошлой попытки - один раз с нуля
				resumed = false
				last_err = i18n.tr('контрольная сумма не совпала')
				continue
			}
			return error(i18n.trf('{0}: контрольная сумма не совпала, файл удалён', '${f.name}'))
		}
		os.mv(part, dest)!
		return
	}
	return error(i18n.trf('{0}: {1} (скачанное сохранено - докачается при следующей попытке)', '${f.name}', '${last_err}'))
}

// install_model - скачать файлы модели в папку моделей (уже лежащие
// целыми - пропускаются). Ошибка Cancelled - отменил пользователь.
pub fn install_model(p Places, m ModelInfo, progress fn (done i64, total i64) bool) ! {
	if !m.downloadable() {
		return error(i18n.trf('модель {0} не скачивается', '${m.title}'))
	}
	os.mkdir_all(p.models)!
	total := m.size()
	mut base := i64(0)
	for f in m.files {
		dest := os.join_path(p.models, f.name)
		if !(os.is_file(dest) && os.file_size(dest) == u64(f.size)) {
			fetch(f, dest, base, total, progress)!
		}
		base += f.size
	}
}

// install_runtime - скачать официальную сборку ONNX Runtime и распаковать
// в папку runtime (содержимое архива без верхней папки: lib/, лицензии).
// Распаковка - системным tar (в Windows 10+ он есть и понимает zip) во
// временную папку, затем переименование: недораспакованный runtime не
// появится.
pub fn install_runtime(p Places, progress fn (done i64, total i64) bool) ! {
	parent := os.dir(p.runtime)
	os.mkdir_all(parent)!
	f := runtime_file
	arc := p.runtime + os.file_ext(f.name)
	tmp := p.runtime + '.tmp'
	fetch(f, arc, 0, f.size, progress)!
	defer {
		os.rm(arc) or {}
	}
	if os.exists(tmp) {
		os.rmdir_all(tmp)!
	}
	os.mkdir_all(tmp)!
	// Аргументы массивом, без оболочки (os.execute со строкой устарел);
	// заголовки и отладочные символы (.pdb - 400 МБ) не нужны
	res := os.exec(['tar', '-xf', arc, '-C', tmp, '--strip-components=1', '--exclude=*.pdb',
		'--exclude=*.lib', '--exclude=*/include/*'])
	if res.exit_code != 0 {
		os.rmdir_all(tmp) or {}
		return error(i18n.trf('не удалось распаковать {0}: {1}', '${f.name}', '${res.output.trim_space()}'))
	}
	if !os.exists(os.join_path(tmp, runtime_lib_name)) {
		os.rmdir_all(tmp) or {}
		return error(i18n.trf('в архиве {0} нет {1}', '${f.name}', runtime_lib_name))
	}
	// Папка без библиотеки (обрывок прошлой установки) - заменяется
	if os.exists(p.runtime) {
		os.rmdir_all(p.runtime)!
	}
	os.mv(tmp, p.runtime)!
}

// remove_runtime - удалить папку ONNX Runtime (и обрывки установки:
// временную папку и архив). Уже загруженная библиотека остаётся в памяти
// до выхода.
pub fn remove_runtime(p Places) ! {
	for x in [p.runtime, p.runtime + '.tmp'] {
		if os.exists(x) {
			os.rmdir_all(x)!
		}
	}
	arc := p.runtime + os.file_ext(runtime_file.name)
	if os.exists(arc) {
		os.rm(arc)!
	}
}

// remove_model - удалить файлы модели из папки моделей (и недокачанные
// .part). Уже загруженная в память модель продолжает работать до выхода.
pub fn remove_model(p Places, m ModelInfo) ! {
	for f in m.files {
		path := os.join_path(p.models, f.name)
		for x in [path, path + '.part'] {
			if os.exists(x) {
				os.rm(x)!
			}
		}
	}
}
