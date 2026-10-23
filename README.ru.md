# vraw

[English](README.md) | **Русский** | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Português](README.pt.md) | [Polski](README.pl.md)

Бесплатный проявщик RAW для Linux и Windows. Открывает Canon CR3 и все
форматы, которые понимает LibRaw, позволяет править снимок без потерь
для исходника и сохраняет в JPEG, PNG, TIFF, BMP, QOI или GIF.
Портабельный: распаковал и запустил, ставить ничего не нужно.

![Главное окно vraw](screenshots/main.jpg)

## Скачать

Свежий архив — в разделе [Releases](../../releases/latest):

- **Linux x86_64** — `vraw-linux-x86_64.tar.gz`. Распаковать куда угодно
  и запустить `vraw/vraw`. Нужен glibc 2.39 или новее (Ubuntu 24.04,
  Linux Mint 22, свежие Fedora и Arch).
- **Windows x64** — `vraw-windows-x86_64.zip`. Распаковать и запустить
  `vraw.exe`. Сборка для Windows экспериментальная: пока проверена под Wine.

Настройки и пресеты лежат рядом с программой — папку можно носить на
флешке.

Больше ничего ставить не нужно: все библиотеки — внутри архива.

## Системные требования

| | Минимум | Рекомендуется |
|---|---|---|
| Система | Linux x86_64 с glibc 2.39+ (X11 или Wayland); Windows 10 64 бит | то же |
| Процессор | любой 64-битный x86 | 4 ядра и больше (пайплайн и экспорт используют все ядра) |
| Память | 4 ГБ | 8 ГБ и больше |
| Диск | 100 МБ под программу | плюс место под снимки |
| Экран | 1280×720 | 1920×1080 |

Видеокарта не нужна: всё считается на процессоре, инструменты
откликаются сразу.

## Возможности

**Правка**
- Неразрушающее редактирование: RAW не меняется. Правки и вся история
  сохраняются автоматически в сайдкар рядом со снимком.
- Экспозиция, контраст, тени/света, точки чёрного и белого,
  тон-эквалайзер, текстура, чёткость, дымка, сочность и насыщенность.
- Баланс белого, кривые RGB/R/G/B, HSL-эквалайзер, чёрно-белое,
  цветокоррекция.
- «Как JPEG камеры»: тон и насыщенность подбираются под JPEG, встроенный
  в этот же кадр.
- Автотон (Ctrl+U).
- Коррекция объектива по базе lensfun: виньетирование, дисторсия,
  хроматические аберрации.
- Кадрирование и выравнивание, исправление перспективы, удаление
  пятен, маски.
- Шумодав, резкость, виньетка и плёночное зерно.

**Просмотр и отбор**
- Лента со всеми RAW папки; соседние кадры проявляются заранее, поэтому
  листание ←/→ мгновенное.
- Звёзды 0–5, флажки «отобран»/«отклонён», фильтры; отклонённые кадры —
  в системную корзину.
- До/после: зажать `\` или шторка (Y).
- Сравнение двух кадров рядом (C) с общим масштабом.
- Пересветы и провалы, RGB-гистограмма, сведения о съёмке (ISO,
  выдержка, диафрагма, объектив), миникарта при 100%.
- Полноэкранный режим, 15 тем оформления (в том числе macOS и Mac OS 9
  Platinum).

**Пакетная работа и экспорт**
- Копирование и вставка настроек (с выбором групп) в один или много
  кадров.
- Пресеты: сохранить, переименовать, импортировать и экспортировать.
- Экспорт открытого кадра, выделенных, по фильтру ленты или всей папки;
  шаблон имени (`{name}`, `{num}`, `{date}`), уменьшение размера,
  качество JPEG.
- EXIF и ICC-профиль sRGB в JPEG, PNG и TIFF.
- TIFF и PNG — по желанию в 16 бит.

**Интерфейс на 31 языке**, по умолчанию — язык системы. Все горячие
клавиши можно переназначить.

## Скриншоты

![До/после шторкой](screenshots/before-after.jpg)

![Окно экспорта](screenshots/export.png)

![Светлая тема macOS](screenshots/light.jpg)

## Сборка из исходников

vraw написан на [V](https://vlang.io) поверх моей GUI-библиотеки
[vgui](https://github.com/Mintormo/vgui). Основная платформа — Linux
(проверено на Ubuntu 24.04). Выпуск для Windows собирается
кросс-компиляцией на Linux; сборка прямо на Windows в MSYS2 тоже должна
работать, но пока не проверялась.

### Зависимости

| Компонент | Версия | Linux (Ubuntu / Debian / Mint) | Windows (MSYS2, MINGW64) |
|---|---|---|---|
| Компилятор V | 0.5.2 (a1c9e93) или новее | из исходников (шаг 3) | из исходников |
| gcc (с OpenMP) | 13+ | `build-essential` | `mingw-w64-x86_64-gcc` |
| LibRaw | 0.21+ | `libraw-dev` | `mingw-w64-x86_64-libraw` |
| lensfun | 0.3.4 | `liblensfun-dev` | `mingw-w64-x86_64-lensfun` |
| libjpeg | любая | `libjpeg-dev` | `mingw-w64-x86_64-libjpeg-turbo` |
| SDL3, SDL3_ttf, SDL3_image | 3.2+, 3.2+, 3.4+ | из исходников (шаг 2), в репозиториях их пока нет | `mingw-w64-x86_64-sdl3`, `-sdl3-ttf`, `-sdl3-image` |
| vgui | последняя | `git clone` (шаг 4) | `git clone` |

vraw собирается только gcc (`-cc gcc`).

### Linux

**1. Системные пакеты** — компилятор, LibRaw, lensfun, libjpeg и
библиотеки, с которыми собирается SDL3:

```bash
sudo apt install build-essential git cmake pkg-config curl \
  libraw-dev liblensfun-dev libjpeg-dev \
  libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxfixes-dev \
  libxi-dev libxss-dev libxtst-dev libxkbcommon-dev libwayland-dev \
  libdecor-0-dev libegl1-mesa-dev libgl1-mesa-dev libgles2-mesa-dev \
  libdrm-dev libgbm-dev libdbus-1-dev libibus-1.0-dev libudev-dev \
  libasound2-dev libpulse-dev libpipewire-0.3-dev \
  libfreetype-dev libharfbuzz-dev libpng-dev libwebp-dev libtiff-dev
```

В Fedora, Arch и других дистрибутивах поставьте те же библиотеки своим
менеджером пакетов. Если в нём уже есть SDL3, SDL3_ttf и SDL3_image 3.4
или новее (с пакетами `-devel`/`-dev`), шаг 2 можно пропустить.

**2. SDL3, SDL3_ttf, SDL3_image** — сборка из исходников с установкой в
`/usr/local`:

```bash
mkdir -p ~/src && cd ~/src
for repo in SDL SDL_ttf SDL_image; do
  git clone --depth 1 https://github.com/libsdl-org/$repo
  cmake -S $repo -B $repo/build -DCMAKE_BUILD_TYPE=Release
  cmake --build $repo/build -j"$(nproc)"
  sudo cmake --install $repo/build
done
sudo ldconfig
```

**3. Компилятор V:**

```bash
git clone https://github.com/vlang/v ~/soft/v
cd ~/soft/v && make
```

**4. vgui и vraw.** Модуль `vgui` компилятор V находит через
`~/.vmodules`:

```bash
mkdir -p ~/.vmodules ~/projects
git clone https://github.com/Mintormo/vgui ~/projects/vgui
ln -s ~/projects/vgui ~/.vmodules/vgui
git clone https://github.com/Mintormo/vraw ~/projects/vraw
cd ~/projects/vraw
~/soft/v/v -prod -cc gcc .     # -> ./vraw
./vraw
```

`-prod` включает оптимизацию gcc: пайплайн примерно в 2,5 раза быстрее,
компиляция — около полуминуты. Другие команды:

```bash
~/soft/v/v -cc gcc test .      # тесты
tools/portable.sh              # портабельная папка и архив в dist/
```

**5. Свежие профили объективов (по желанию).** База lensfun в пакетах
дистрибутивов старая. vraw читает и более новую из
`~/.local/share/lensfun/updates/version_1`:

```bash
mkdir -p ~/.local/share/lensfun/updates/version_1
curl -L https://lensfun.github.io/db/version_1.tar.bz2 \
  | tar -xj -C ~/.local/share/lensfun/updates/version_1
```

### Windows

**Кросс-компиляция на Linux** — так собираются архивы выпусков. Нужны V
и vgui из шагов 3–4 для Linux и MinGW-w64:

```bash
sudo apt install gcc-mingw-w64-x86-64 zstd
python3 tools/win_deps.py      # SDL3, LibRaw, lensfun и их зависимости
                               # из пакетов MSYS2 -> ~/soft/mingw64-vraw
tools/windows.sh               # -> dist/vraw-windows-x86_64.zip
```

В архиве — `vraw.exe`, все нужные ему DLL и база объективов.

**Прямо в MSYS2 (пока не проверено).** Установите [MSYS2](https://www.msys2.org),
откройте оболочку **MSYS2 MINGW64** и выполните:

```bash
pacman -S --needed git make mingw-w64-x86_64-gcc \
  mingw-w64-x86_64-sdl3 mingw-w64-x86_64-sdl3-ttf mingw-w64-x86_64-sdl3-image \
  mingw-w64-x86_64-libraw mingw-w64-x86_64-lensfun mingw-w64-x86_64-libjpeg-turbo
git clone https://github.com/vlang/v ~/v
(cd ~/v && make)
mkdir -p "$USERPROFILE/.vmodules"
git clone https://github.com/Mintormo/vgui "$USERPROFILE/.vmodules/vgui"
git clone https://github.com/Mintormo/vraw ~/vraw
cd ~/vraw && ~/v/v -prod -cc gcc .
```

Чтобы запускать `vraw.exe` вне оболочки MSYS2, положите рядом с ним
нужные ему DLL из `C:\msys64\mingw64\bin` (как их собрать — видно в
`tools/windows.sh`).

### Документация для разработчиков

Код подробно прокомментирован. Устройство программы описано по-русски:
[PROJECT.md](PROJECT.md) — модули и пайплайн,
[ROADMAP.md](ROADMAP.md) — что сделано и что в планах,
[REQUIREMENTS.md](REQUIREMENTS.md) — что программа умеет сейчас.

## Сделано с Claude Code

vraw создан вайбкодингом — вместе с
[Claude Code](https://claude.com/claude-code), ИИ-помощником для
программирования от Anthropic. Программа написана на
[V](https://vlang.io) на моей собственной GUI-библиотеке [vgui](https://github.com/Mintormo/vgui), со своим
тональным пайплайном; LibRaw выполняет только демозаику.

## Лицензия

MIT, см. [LICENSE](LICENSE). Исходный код — в этом репозитории. Сторонние
компоненты в архивах (LibRaw, lensfun, SDL3 и
другие) распространяются под своими лицензиями: см. `THIRD_PARTY.md` и
папку `licenses/` внутри архива.
