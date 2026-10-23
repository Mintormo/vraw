# vraw

[English](README.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | **Español** | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Português](README.pt.md) | [Polski](README.pl.md)

Un revelador RAW gratuito para Linux y Windows. Abre Canon CR3 y todos
los demás formatos que entiende LibRaw, permite editar de forma no
destructiva y exporta a JPEG, PNG, TIFF, BMP, QOI o GIF. Portátil:
descomprimir y ejecutar, sin instalar nada.

![Ventana principal de vraw](screenshots/main.jpg)

## Descarga

El archivo más reciente está en [Releases](../../releases/latest):

- **Linux x86_64** — `vraw-linux-x86_64.tar.gz`. Descomprimir en
  cualquier lugar y ejecutar `vraw/vraw`. Requiere glibc 2.39 o posterior
  (Ubuntu 24.04, Linux Mint 22, Fedora y Arch recientes).
- **Windows x64** — `vraw-windows-x86_64.zip`. Descomprimir y ejecutar
  `vraw.exe`. La versión para Windows es experimental: por ahora probada bajo Wine.

Los ajustes y los preajustes se guardan junto al programa, así que la
carpeta puede vivir en una memoria USB.

No hace falta instalar nada más: todas las bibliotecas están dentro del
archivo.

## Requisitos del sistema

| | Mínimo | Recomendado |
|---|---|---|
| Sistema | Linux x86_64 con glibc 2.39+ (X11 o Wayland); Windows 10 de 64 bits | lo mismo |
| Procesador | cualquier x86 de 64 bits | 4 núcleos o más (el procesado y la exportación usan todos los núcleos) |
| Memoria | 4 GB | 8 GB o más |
| Disco | 100 MB para el programa | más espacio para las fotos |
| Pantalla | 1280×720 | 1920×1080 |

No se necesita tarjeta gráfica: todo funciona en el procesador y las
herramientas responden al instante.

## Funciones

**Edición**
- No destructiva: el archivo RAW nunca se modifica. Los ajustes y todo el
  historial se guardan automáticamente en un archivo adjunto junto a la
  foto.
- Exposición, contraste, sombras/luces, puntos de negro y blanco,
  ecualizador de tonos, textura, claridad, eliminación de neblina,
  intensidad y saturación.
- Balance de blancos, curvas RGB/R/G/B, ecualizador HSL, blanco y negro,
  gradación de color.
- «Como el JPEG de la cámara»: el tono y la saturación se ajustan al JPEG
  incrustado en la misma toma.
- Tono automático (Ctrl+U).
- Corrección de objetivo con la base de datos lensfun: viñeteo,
  distorsión, aberración cromática.
- Recorte y enderezado, corrección de perspectiva, eliminación de
  manchas, máscaras.
- Reducción de ruido, enfoque, viñeta y grano de película.

**Visualización y selección**
- Tira de miniaturas con todos los RAW de la carpeta; las fotos vecinas
  se revelan por adelantado, así que pasar con ←/→ es instantáneo.
- Valoraciones de 0 a 5, marcas «elegida/rechazada», filtros; las fotos
  rechazadas van a la papelera del sistema.
- Antes/después: mantener `\` o vista dividida (Y).
- Comparar dos fotos lado a lado (C) con zoom compartido.
- Aviso de recorte de luces y sombras, histograma RGB, datos de la toma
  (ISO, velocidad, diafragma, objetivo), minimapa al 100 %.
- Modo de pantalla completa, 15 temas (entre ellos macOS y Mac OS 9
  Platinum).

**Trabajo por lotes y exportación**
- Copiar y pegar ajustes (eligiendo los grupos) en una o muchas fotos.
- Preajustes: guardar, renombrar, importar y exportar.
- Exportar la foto abierta, las seleccionadas, la tira filtrada o toda la
  carpeta; plantillas de nombre (`{name}`, `{num}`, `{date}`), reducción
  de tamaño, calidad JPEG.
- EXIF y perfil ICC sRGB en JPEG, PNG y TIFF.
- TIFF y PNG en 16 bits si se desea.

**Interfaz en 31 idiomas**, por defecto en el idioma del sistema. Todos
los atajos de teclado se pueden reasignar.

## Capturas de pantalla

![Antes/después en vista dividida](screenshots/before-after.jpg)

![Ventana de exportación](screenshots/export.png)

![Tema claro macOS](screenshots/light.jpg)

## Compilar desde el código fuente

vraw está escrito en [V](https://vlang.io) sobre mi biblioteca gráfica
[vgui](https://github.com/Mintormo/vgui). La plataforma principal es
Linux (probado en Ubuntu 24.04). La versión para Windows se compila de
forma cruzada en Linux; compilar directamente en Windows con MSYS2
también debería funcionar, pero aún no se ha probado.

### Dependencias

| Componente | Versión | Linux (Ubuntu / Debian / Mint) | Windows (MSYS2, MINGW64) |
|---|---|---|---|
| Compilador V | 0.5.2 (a1c9e93) o posterior | desde el código fuente (paso 3) | desde el código fuente |
| gcc (con OpenMP) | 13+ | `build-essential` | `mingw-w64-x86_64-gcc` |
| LibRaw | 0.21+ | `libraw-dev` | `mingw-w64-x86_64-libraw` |
| lensfun | 0.3.4 | `liblensfun-dev` | `mingw-w64-x86_64-lensfun` |
| libjpeg | cualquiera | `libjpeg-dev` | `mingw-w64-x86_64-libjpeg-turbo` |
| SDL3, SDL3_ttf, SDL3_image | 3.2+, 3.2+, 3.4+ | desde el código fuente (paso 2), aún no están en los repositorios | `mingw-w64-x86_64-sdl3`, `-sdl3-ttf`, `-sdl3-image` |
| vgui | la última | `git clone` (paso 4) | `git clone` |

vraw solo se compila con gcc (`-cc gcc`).

### Linux

**1. Paquetes del sistema** — compilador, LibRaw, lensfun, libjpeg y las
bibliotecas con las que se compila SDL3:

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

En Fedora, Arch y otras distribuciones instale las mismas bibliotecas
con su gestor de paquetes. Si ya incluye SDL3, SDL3_ttf y SDL3_image 3.4
o posterior (con paquetes `-devel`/`-dev`), omita el paso 2.

**2. SDL3, SDL3_ttf, SDL3_image** — compiladas desde el código fuente e
instaladas en `/usr/local`:

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

**3. Compilador V:**

```bash
git clone https://github.com/vlang/v ~/soft/v
cd ~/soft/v && make
```

**4. vgui y vraw.** V encuentra el módulo `vgui` a través de
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

`-prod` activa las optimizaciones de gcc: el pipeline es unas 2,5 veces
más rápido y la compilación tarda cerca de medio minuto. Otros comandos:

```bash
~/soft/v/v -cc gcc test .      # pruebas
tools/portable.sh              # carpeta portable y archivo en dist/
```

**5. Perfiles de objetivos actualizados (opcional).** La base de datos
de lensfun de los paquetes de las distribuciones es antigua. vraw también
lee una más reciente de `~/.local/share/lensfun/updates/version_1`:

```bash
mkdir -p ~/.local/share/lensfun/updates/version_1
curl -L https://lensfun.github.io/db/version_1.tar.bz2 \
  | tar -xj -C ~/.local/share/lensfun/updates/version_1
```

### Windows

**Compilación cruzada en Linux** — así se crean los archivos de las
versiones. Se necesitan V y vgui de los pasos 3–4 de Linux y MinGW-w64:

```bash
sudo apt install gcc-mingw-w64-x86-64 zstd
python3 tools/win_deps.py      # SDL3, LibRaw, lensfun y sus dependencias
                               # de paquetes MSYS2 -> ~/soft/mingw64-vraw
tools/windows.sh               # -> dist/vraw-windows-x86_64.zip
```

El archivo contiene `vraw.exe`, todas las DLL que necesita y la base de
datos de objetivos.

**Directamente en MSYS2 (aún no probado).** Instale
[MSYS2](https://www.msys2.org), abra la terminal **MSYS2 MINGW64** y
ejecute:

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

Para ejecutar `vraw.exe` fuera de la terminal de MSYS2, coloque junto a
él las DLL que necesita de `C:\msys64\mingw64\bin` (`tools/windows.sh`
muestra cómo reunirlas).

### Documentación para desarrolladores

El código está comentado en detalle. Las notas de diseño están en ruso:
[PROJECT.md](PROJECT.md) — módulos y pipeline,
[ROADMAP.md](ROADMAP.md) — qué está hecho y qué está previsto,
[REQUIREMENTS.md](REQUIREMENTS.md) — qué hace el programa ahora.

## Hecho con Claude Code

vraw se creó con vibe coding: escrito junto con
[Claude Code](https://claude.com/claude-code), el asistente de
programación con IA de Anthropic. El programa está escrito en
[V](https://vlang.io) sobre mi propia biblioteca gráfica [vgui](https://github.com/Mintormo/vgui), con su
propio procesado de tonos; LibRaw solo realiza el demosaico.

## Licencia

MIT, ver [LICENSE](LICENSE). El código fuente está en este repositorio. Los
componentes de terceros incluidos en los archivos (LibRaw, lensfun, SDL3
y otros) se rigen por sus propias licencias: ver
`THIRD_PARTY.md` y la carpeta `licenses/` dentro del archivo.
