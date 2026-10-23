# vraw

[English](README.md) | [Русский](README.ru.md) | **Deutsch** | [Français](README.fr.md) | [Español](README.es.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Português](README.pt.md) | [Polski](README.pl.md)

Ein kostenloser RAW-Entwickler für Linux und Windows. Öffnet Canon CR3
und alle anderen Formate, die LibRaw versteht, bearbeitet
nicht-destruktiv und exportiert nach JPEG, PNG, TIFF, BMP, QOI oder GIF.
Portabel: entpacken und starten, nichts zu installieren.

![Hauptfenster von vraw](screenshots/main.jpg)

## Download

Das aktuelle Archiv gibt es unter [Releases](../../releases/latest):

- **Linux x86_64** — `vraw-linux-x86_64.tar.gz`. Beliebig entpacken und
  `vraw/vraw` starten. Benötigt glibc 2.39 oder neuer (Ubuntu 24.04,
  Linux Mint 22, aktuelle Fedora und Arch).
- **Windows x64** — `vraw-windows-x86_64.zip`. Entpacken und `vraw.exe`
  starten. Die Windows-Version ist experimentell: bisher nur unter Wine getestet.

Einstellungen und Presets liegen neben dem Programm – der Ordner kann also
auf einem USB-Stick leben.

Sonst muss nichts installiert werden: Alle Bibliotheken sind im Archiv.

## Systemanforderungen

| | Minimum | Empfohlen |
|---|---|---|
| System | Linux x86_64 mit glibc 2.39+ (X11 oder Wayland); Windows 10 64 Bit | dasselbe |
| Prozessor | beliebiger 64-Bit-x86 | 4+ Kerne (Pipeline und Export nutzen alle Kerne) |
| Arbeitsspeicher | 4 GB | 8 GB oder mehr |
| Festplatte | 100 MB für das Programm | plus Platz für die Fotos |
| Bildschirm | 1280×720 | 1920×1080 |

Eine Grafikkarte ist nicht nötig: Alles läuft auf dem Prozessor, alle
Werkzeuge reagieren sofort.

## Funktionen

**Bearbeitung**
- Nicht-destruktiv: Die RAW-Datei wird nie verändert. Änderungen und der
  komplette Verlauf werden automatisch in einer Sidecar-Datei neben dem
  Foto gespeichert.
- Belichtung, Kontrast, Tiefen/Lichter, Schwarz- und Weißpunkt,
  Tonwert-Equalizer, Textur, Klarheit, Dunst entfernen, Dynamik und
  Sättigung.
- Weißabgleich, Kurven RGB/R/G/B, HSL-Equalizer, Schwarzweiß,
  Color Grading.
- „Wie Kamera-JPEG“: Tonwerte und Sättigung werden an das im selben Bild
  eingebettete JPEG angeglichen.
- Auto-Ton (Strg+U).
- Objektivkorrektur aus der lensfun-Datenbank: Vignettierung,
  Verzeichnung, chromatische Aberration.
- Zuschneiden und Ausrichten, Perspektivkorrektur, Flecken entfernen,
  Masken.
- Rauschreduzierung, Schärfen, Vignette und Filmkorn.

**Ansicht und Auswahl**
- Filmstreifen mit allen RAW-Dateien des Ordners; benachbarte Bilder
  werden im Voraus entwickelt, Blättern mit ←/→ ist daher sofort.
- Bewertungen 0–5, Markierungen „ausgewählt/abgelehnt“, Filter;
  abgelehnte Bilder wandern in den Papierkorb des Systems.
- Vorher/Nachher: `\` gedrückt halten oder geteilte Ansicht (Y).
- Zwei Bilder nebeneinander vergleichen (C) mit gemeinsamem Zoom.
- Warnung vor Über- und Unterbelichtung, RGB-Histogramm,
  Aufnahmedaten (ISO, Verschlusszeit, Blende, Objektiv), Minikarte bei
  100 %.
- Vollbildmodus, 15 Designs (darunter macOS und Mac OS 9 Platinum).

**Stapelverarbeitung und Export**
- Einstellungen kopieren und einfügen (mit Auswahl der Gruppen) – in ein
  oder viele Bilder.
- Presets: speichern, umbenennen, importieren und exportieren.
- Export des geöffneten Bildes, der ausgewählten, des gefilterten
  Filmstreifens oder des ganzen Ordners; Dateinamen-Vorlagen (`{name}`,
  `{num}`, `{date}`), Verkleinern, JPEG-Qualität.
- EXIF und ein sRGB-ICC-Profil in JPEG, PNG und TIFF.
- TIFF und PNG wahlweise mit 16 Bit.

**Oberfläche in 31 Sprachen**, standardmäßig in der Systemsprache. Alle
Tastenkürzel lassen sich neu belegen.

## Screenshots

![Vorher/Nachher geteilt](screenshots/before-after.jpg)

![Export-Dialog](screenshots/export.png)

![Helles macOS-Design](screenshots/light.jpg)

## Aus dem Quellcode bauen

vraw ist in [V](https://vlang.io) geschrieben, auf Basis meiner
GUI-Bibliothek [vgui](https://github.com/Mintormo/vgui). Die
Hauptplattform ist Linux (getestet unter Ubuntu 24.04). Die
Windows-Version wird unter Linux cross-kompiliert; ein Bau direkt unter
Windows in MSYS2 sollte ebenfalls funktionieren, ist aber noch nicht
getestet.

### Abhängigkeiten

| Komponente | Version | Linux (Ubuntu / Debian / Mint) | Windows (MSYS2, MINGW64) |
|---|---|---|---|
| V-Compiler | 0.5.2 (a1c9e93) oder neuer | aus dem Quellcode (Schritt 3) | aus dem Quellcode |
| gcc (mit OpenMP) | 13+ | `build-essential` | `mingw-w64-x86_64-gcc` |
| LibRaw | 0.21+ | `libraw-dev` | `mingw-w64-x86_64-libraw` |
| lensfun | 0.3.4 | `liblensfun-dev` | `mingw-w64-x86_64-lensfun` |
| libjpeg | beliebig | `libjpeg-dev` | `mingw-w64-x86_64-libjpeg-turbo` |
| SDL3, SDL3_ttf, SDL3_image | 3.2+, 3.2+, 3.4+ | aus dem Quellcode (Schritt 2), noch nicht in den Paketquellen | `mingw-w64-x86_64-sdl3`, `-sdl3-ttf`, `-sdl3-image` |
| vgui | aktuell | `git clone` (Schritt 4) | `git clone` |

vraw lässt sich nur mit gcc bauen (`-cc gcc`).

### Linux

**1. Systempakete** — Compiler, LibRaw, lensfun, libjpeg und die
Bibliotheken, gegen die SDL3 gebaut wird:

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

Unter Fedora, Arch und anderen Distributionen installieren Sie dieselben
Bibliotheken mit deren Paketverwaltung. Bietet sie bereits SDL3,
SDL3_ttf und SDL3_image 3.4 oder neuer (mit `-devel`/`-dev`-Paketen),
kann Schritt 2 entfallen.

**2. SDL3, SDL3_ttf, SDL3_image** — aus dem Quellcode gebaut und nach
`/usr/local` installiert:

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

**3. V-Compiler:**

```bash
git clone https://github.com/vlang/v ~/soft/v
cd ~/soft/v && make
```

**4. vgui und vraw.** V findet das Modul `vgui` über `~/.vmodules`:

```bash
mkdir -p ~/.vmodules ~/projects
git clone https://github.com/Mintormo/vgui ~/projects/vgui
ln -s ~/projects/vgui ~/.vmodules/vgui
git clone https://github.com/Mintormo/vraw ~/projects/vraw
cd ~/projects/vraw
~/soft/v/v -prod -cc gcc .     # -> ./vraw
./vraw
```

`-prod` schaltet die gcc-Optimierungen ein: Die Pipeline wird etwa
2,5-mal schneller, das Kompilieren dauert rund eine halbe Minute.
Weitere Befehle:

```bash
~/soft/v/v -cc gcc test .      # Tests
tools/portable.sh              # portabler Ordner und Archiv in dist/
```

**5. Aktuelle Objektivprofile (optional).** Die lensfun-Datenbank in den
Paketen der Distributionen ist alt. vraw liest zusätzlich eine neuere
aus `~/.local/share/lensfun/updates/version_1`:

```bash
mkdir -p ~/.local/share/lensfun/updates/version_1
curl -L https://lensfun.github.io/db/version_1.tar.bz2 \
  | tar -xj -C ~/.local/share/lensfun/updates/version_1
```

### Windows

**Cross-Kompilierung unter Linux** — so entstehen die Release-Archive.
Benötigt werden V und vgui aus den Linux-Schritten 3–4 sowie MinGW-w64:

```bash
sudo apt install gcc-mingw-w64-x86-64 zstd
python3 tools/win_deps.py      # SDL3, LibRaw, lensfun und Abhängigkeiten
                               # aus MSYS2-Paketen -> ~/soft/mingw64-vraw
tools/windows.sh               # -> dist/vraw-windows-x86_64.zip
```

Das Archiv enthält `vraw.exe`, alle benötigten DLLs und die
Objektivdatenbank.

**Direkt in MSYS2 (noch nicht getestet).** Installieren Sie
[MSYS2](https://www.msys2.org), öffnen Sie die Shell **MSYS2 MINGW64**
und führen Sie aus:

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

Um `vraw.exe` außerhalb der MSYS2-Shell zu starten, legen Sie die
benötigten DLLs aus `C:\msys64\mingw64\bin` daneben (wie man sie
einsammelt, zeigt `tools/windows.sh`).

### Entwicklerdokumentation

Der Code ist ausführlich kommentiert. Die Entwurfsnotizen sind auf
Russisch: [PROJECT.md](PROJECT.md) — Module und Pipeline,
[ROADMAP.md](ROADMAP.md) — Erledigtes und Geplantes,
[REQUIREMENTS.md](REQUIREMENTS.md) — was das Programm jetzt kann.

## Mit Claude Code gemacht

vraw ist per Vibe-Coding entstanden: gemeinsam mit
[Claude Code](https://claude.com/claude-code), dem KI-Programmierassistenten
von Anthropic. Das Programm ist in [V](https://vlang.io) auf meiner
eigenen GUI-Bibliothek [vgui](https://github.com/Mintormo/vgui) geschrieben, mit eigener Tonwert-Pipeline;
LibRaw übernimmt nur das Demosaicing.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Der Quellcode liegt in diesem Repository.
Die in den Archiven enthaltenen Fremdkomponenten (LibRaw, lensfun, SDL3
und andere) stehen unter ihren eigenen Lizenzen:
siehe `THIRD_PARTY.md` und den Ordner `licenses/` im Archiv.
