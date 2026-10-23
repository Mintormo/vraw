# vraw

**English** | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Português](README.pt.md) | [Polski](README.pl.md)

A free RAW photo developer for Linux and Windows. Opens Canon CR3 and
every other format LibRaw understands, lets you edit non-destructively
and exports to JPEG, PNG, TIFF, BMP, QOI or GIF. Portable: unpack and
run, nothing to install.

![vraw main window](screenshots/main.jpg)

## Download

Get the latest archive from [Releases](../../releases/latest):

- **Linux x86_64** — `vraw-linux-x86_64.tar.gz`. Unpack anywhere and run
  `vraw/vraw`. Needs glibc 2.39 or newer (Ubuntu 24.04, Linux Mint 22,
  recent Fedora and Arch).
- **Windows x64** — `vraw-windows-x86_64.zip`. Unpack and run `vraw.exe`.
  The Windows build is experimental: so far it has been tested under Wine.

Settings and presets are kept next to the program, so the folder can live
on a USB stick.

Nothing else needs to be installed: all libraries are inside the archive.

## System requirements

| | Minimum | Recommended |
|---|---|---|
| OS | Linux x86_64 with glibc 2.39+ (X11 or Wayland); Windows 10 64-bit | the same |
| CPU | any 64-bit x86 | 4+ cores (the pipeline and export use all cores) |
| RAM | 4 GB | 8 GB or more |
| Disk | 100 MB for the program | plus space for the photos |
| Screen | 1280×720 | 1920×1080 |

No GPU is needed: everything runs on the CPU, and all tools react
instantly.

## Features

**Editing**
- Non-destructive: the RAW file is never changed. Edits and full history
  are saved automatically in a sidecar file next to the photo.
- Exposure, contrast, shadows/highlights, black and white points, tone
  equalizer, texture, clarity, dehaze, vibrance and saturation.
- White balance, RGB/R/G/B curves, HSL equalizer, black and white
  conversion, color grading.
- "Like camera JPEG": tone and saturation are matched to the JPEG
  embedded in the same shot.
- Auto tone (Ctrl+U).
- Lens correction from the lensfun database: vignetting, distortion,
  chromatic aberration.
- Crop and straighten, upright correction, spot removal, masks.
- Noise reduction, sharpening, vignette and film grain.

**Viewing and culling**
- Film strip with all RAW files of the folder; neighbouring shots are
  developed in advance, so flipping with ←/→ is instant.
- Ratings 0–5, pick/reject flags, filters; rejected shots go to the
  system trash.
- Before/after: hold `\` or use a split view (Y).
- Compare two shots side by side (C) with shared zoom.
- Clipping warnings, RGB histogram, shot info (ISO, shutter, aperture,
  lens), minimap at 100%.
- Full screen mode, 15 themes (including macOS and Mac OS 9 Platinum).

**Batch work and export**
- Copy and paste settings (choose which groups) to one or many shots.
- Presets: save, rename, import and export.
- Export one shot, the selected ones, the filtered strip or the whole
  folder; file name templates (`{name}`, `{num}`, `{date}`), resizing,
  JPEG quality.
- EXIF and an sRGB ICC profile are written to JPEG, PNG and TIFF.
- TIFF and PNG can be exported in 16 bit.

**Interface in 31 languages**, chosen from the system language by
default. All hotkeys can be reassigned.

## Screenshots

![Before/after split view](screenshots/before-after.jpg)

![Export dialog](screenshots/export.png)

![Light macOS theme](screenshots/light.jpg)

## Building from source

vraw is written in [V](https://vlang.io) on top of my GUI library
[vgui](https://github.com/Mintormo/vgui). The main platform is Linux
(tested on Ubuntu 24.04). The Windows release is cross-compiled on Linux;
building natively on Windows in MSYS2 should work too, but has not been
tested yet.

### Dependencies

| Component | Version | Linux (Ubuntu / Debian / Mint) | Windows (MSYS2, MINGW64) |
|---|---|---|---|
| V compiler | 0.5.2 (a1c9e93) or newer | from source (step 3) | from source |
| gcc (with OpenMP) | 13+ | `build-essential` | `mingw-w64-x86_64-gcc` |
| LibRaw | 0.21+ | `libraw-dev` | `mingw-w64-x86_64-libraw` |
| lensfun | 0.3.4 | `liblensfun-dev` | `mingw-w64-x86_64-lensfun` |
| libjpeg | any | `libjpeg-dev` | `mingw-w64-x86_64-libjpeg-turbo` |
| SDL3, SDL3_ttf, SDL3_image | 3.2+, 3.2+, 3.4+ | from source (step 2), not in the repositories yet | `mingw-w64-x86_64-sdl3`, `-sdl3-ttf`, `-sdl3-image` |
| vgui | latest | `git clone` (step 4) | `git clone` |

vraw builds only with gcc (`-cc gcc`).

### Linux

**1. System packages** — compiler, LibRaw, lensfun, libjpeg and the
libraries SDL3 is built against:

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

On Fedora, Arch and other distributions install the same libraries with
their package manager. If it already ships SDL3, SDL3_ttf and SDL3_image
3.4 or newer (with `-devel`/`-dev` packages), skip step 2.

**2. SDL3, SDL3_ttf, SDL3_image** — built from source and installed to
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

**3. V compiler:**

```bash
git clone https://github.com/vlang/v ~/soft/v
cd ~/soft/v && make
```

**4. vgui and vraw.** V finds the `vgui` module through `~/.vmodules`:

```bash
mkdir -p ~/.vmodules ~/projects
git clone https://github.com/Mintormo/vgui ~/projects/vgui
ln -s ~/projects/vgui ~/.vmodules/vgui
git clone https://github.com/Mintormo/vraw ~/projects/vraw
cd ~/projects/vraw
~/soft/v/v -prod -cc gcc .     # -> ./vraw
./vraw
```

`-prod` turns on gcc optimizations: the pipeline is about 2.5 times
faster, compilation takes about half a minute. Other commands:

```bash
~/soft/v/v -cc gcc test .      # tests
tools/portable.sh              # portable folder and archive in dist/
```

**5. Fresh lens profiles (optional).** The lensfun database in the
distribution packages is old. vraw also reads a newer one from
`~/.local/share/lensfun/updates/version_1`:

```bash
mkdir -p ~/.local/share/lensfun/updates/version_1
curl -L https://lensfun.github.io/db/version_1.tar.bz2 \
  | tar -xj -C ~/.local/share/lensfun/updates/version_1
```

### Windows

**Cross-compiling on Linux** — this is how the release archives are
made. You need V and vgui from the Linux steps 3–4, plus MinGW-w64:

```bash
sudo apt install gcc-mingw-w64-x86-64 zstd
python3 tools/win_deps.py      # SDL3, LibRaw, lensfun and their dependencies
                               # from MSYS2 packages -> ~/soft/mingw64-vraw
tools/windows.sh               # -> dist/vraw-windows-x86_64.zip
```

The archive contains `vraw.exe`, all the DLLs it needs and the lens
database.

**Natively in MSYS2 (not tested yet).** Install [MSYS2](https://www.msys2.org),
open the **MSYS2 MINGW64** shell and run:

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

To run `vraw.exe` outside the MSYS2 shell, put the DLLs from
`C:\msys64\mingw64\bin` it depends on next to it (`tools/windows.sh`
shows how they are collected).

### Developer documentation

The code is commented in detail. Design notes are in Russian:
[PROJECT.md](PROJECT.md) — how the modules and the pipeline work,
[ROADMAP.md](ROADMAP.md) — what is done and what is planned,
[REQUIREMENTS.md](REQUIREMENTS.md) — what the program does now.

## Made with Claude Code

vraw was vibe-coded: written together with
[Claude Code](https://claude.com/claude-code), Anthropic's AI coding
assistant. The program is written in [V](https://vlang.io) on top of my
own GUI library [vgui](https://github.com/Mintormo/vgui), with its own tone pipeline; LibRaw does only
demosaicing.

## License

MIT, see [LICENSE](LICENSE). The source code is in this repository.
Third-party components included in the archives (LibRaw, lensfun,
SDL3 and others) are covered by their own licenses:
see `THIRD_PARTY.md` and the `licenses/` folder inside the archive.
