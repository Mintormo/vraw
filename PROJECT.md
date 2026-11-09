# vraw — устройство проекта

Подробная рабочая документация: модули, формулы, GUI, замеры. План развития — в ROADMAP.md.
Постоянное (окружение, сборка, архитектурный принцип, грабли) —
в CLAUDE.md. Файлы `docs/` обновляются вместе с кодом; новый файл —
добавить в оглавление ниже.

Документация разбита по модулям и лежит в `docs/`: под задачу читается
нужный файл, а не всё сразу. Здесь — оглавление.

## Модули

- [docs/raw.md](docs/raw.md) — обёртка LibRaw: проявка, превью камеры, метаданные
- [docs/lens.md](docs/lens.md) — lensfun: профиль, виньетирование, дисторсия и ХА, ручная коррекция, подбор по JPEG
- [docs/pipeline.md](docs/pipeline.md) — порядок операций и формулы, Clarity, текстура, эффекты, потоки, таблицы, инварианты теста
- [docs/pipeline-tools.md](docs/pipeline-tools.md) — баланс белого, дымка, резкость, Capture-резкость, геометрия, перспектива, части кадра, пятна, шумодав
- [docs/pipeline-local.md](docs/pipeline-local.md) — градиентные фильтры (local.v): формы, кисть, диапазоны, маски
- [docs/bigbuf.md](docs/bigbuf.md) — буферы вне сборщика мусора и владение буферами кадра (bufown.v)
- [docs/imgio.md](docs/imgio.md) — запись JPEG, PNG, TIFF, BMP, QOI, GIF; EXIF и ICC
- [docs/i18n.md](docs/i18n.md) — перевод интерфейса
- [docs/app.md](docs/app.md) — приложение: портабельные сборки, иконка, платформенный код, список файлов и тестов

## GUI (app.v и файлы окна)

- [docs/gui-window.md](docs/gui-window.md) — State, компоновка, меню, доступность, темы, масштаб, настройки, раскладка, тосты, подготовка сырья в фоне
- [docs/gui-panel.md](docs/gui-panel.md) — профиль, объектив, автотон, ползунки и их ряды, кривые, ББ, тон, дымка, резкость, HSL, ч/б, цветокоррекция
- [docs/gui-history.md](docs/gui-history.md) — EditState, история, формат сайдкара
- [docs/gui-browser.md](docs/gui-browser.md) — браузер папки, миниатюры, отбор (звёзды, флажки, фильтр)
- [docs/gui-presets.md](docs/gui-presets.md) — буфер настроек, группы, файлы пресетов
- [docs/gui-background.md](docs/gui-background.md) — фоновая загрузка кадра, результат из spawn через app.post, замыкания и память
- [docs/gui-crop.md](docs/gui-crop.md) — секция и режим на холсте, горизонт, перспектива
- [docs/gui-masks.md](docs/gui-masks.md) — секция, ручки, кисть, многоугольник, заливка маски
- [docs/gui-retouch.md](docs/gui-retouch.md) — spots_ui.v, pcolor_ui.v
- [docs/gui-view.md](docs/gui-view.md) — пересветы, маска фокуса, до/после, сравнение кадров, горячие клавиши, гистограмма, сведения о съёмке, настоящий 1:1
- [docs/gui-export.md](docs/gui-export.md) — сохранение в фоне, этапы и отмена, окно «Экспорт», пакет, диалог прогресса

## Прочее

- [docs/measurements.md](docs/measurements.md) — замеры скорости

## План развития

Открытые задачи и сделанное — в [ROADMAP.md](ROADMAP.md).
