# vraw

**English** | [Русский](README.ru.md)

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
  The AI denoiser needs the
  [Microsoft Visual C++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe).
  The Windows build is experimental: so far it has been tested under Wine.

Settings, presets and the AI model are kept next to the program, so the
folder can live on a USB stick.

Nothing else needs to be installed: all libraries are inside the archive.
The only exception is the Visual C++ Redistributable on Windows, and only
for AI denoise; without it everything else works.

## System requirements

| | Minimum | Recommended |
|---|---|---|
| OS | Linux x86_64 with glibc 2.39+ (X11 or Wayland); Windows 10 64-bit | the same |
| CPU | any 64-bit x86 | 4+ cores (the pipeline and export use all cores) |
| RAM | 4 GB | 8 GB or more |
| Disk | 300 MB for the program | plus space for the photos |
| Screen | 1280×720 | 1920×1080 |

No GPU is needed. AI denoise runs on the CPU and is slow: on an Intel Core
i5-1235U (10 cores) with 16 GB RAM the preview takes about 4 minutes and a
full 24 MP frame about 16 minutes. All other tools react instantly.

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
- **AI denoise** with the SCUNet neural network (bundled, works offline):
  removes noise while keeping detail. Runs in the background with
  progress and cancel.

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

## Made with Claude Code

vraw was vibe-coded: written together with
[Claude Code](https://claude.com/claude-code), Anthropic's AI coding
assistant. The program is written in [V](https://vlang.io) on top of my
own GUI library vgui, with its own tone pipeline; LibRaw does only
demosaicing.

## License

MIT, see [LICENSE](LICENSE). The source code is not published.
Third-party components included in the archives (LibRaw, lensfun,
SDL3, ONNX Runtime, SCUNet and others) are covered by their own licenses:
see `THIRD_PARTY.md` and the `licenses/` folder inside the archive.
