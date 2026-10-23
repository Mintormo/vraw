# vraw

[English](README.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Italiano](README.it.md) | **Nederlands** | [Português](README.pt.md) | [Polski](README.pl.md)

Een gratis RAW-ontwikkelaar voor Linux en Windows. Opent Canon CR3 en
alle andere formaten die LibRaw begrijpt, bewerkt niet-destructief en
exporteert naar JPEG, PNG, TIFF, BMP, QOI of GIF. Portable: uitpakken en
starten, niets te installeren.

![Hoofdvenster van vraw](screenshots/main.jpg)

## Downloaden

Het nieuwste archief staat bij [Releases](../../releases/latest):

- **Linux x86_64** — `vraw-linux-x86_64.tar.gz`. Uitpakken waar je wilt
  en `vraw/vraw` starten. Vereist glibc 2.39 of nieuwer (Ubuntu 24.04,
  Linux Mint 22, recente Fedora en Arch).
- **Windows x64** — `vraw-windows-x86_64.zip`. Uitpakken en `vraw.exe`
  starten. De Windows-versie is experimenteel: tot nu toe getest onder Wine.

Instellingen en voorinstellingen staan naast het programma, dus de map
kan op een USB-stick staan.

Verder hoeft er niets geïnstalleerd te worden: alle bibliotheken zitten
in het archief.

## Systeemvereisten

| | Minimaal | Aanbevolen |
|---|---|---|
| Systeem | Linux x86_64 met glibc 2.39+ (X11 of Wayland); Windows 10 64-bit | hetzelfde |
| Processor | elke 64-bit x86 | 4+ kernen (de verwerking en export gebruiken alle kernen) |
| Geheugen | 4 GB | 8 GB of meer |
| Schijf | 100 MB voor het programma | plus ruimte voor de foto's |
| Scherm | 1280×720 | 1920×1080 |

Een videokaart is niet nodig: alles draait op de processor en alle
gereedschappen reageren meteen.

## Mogelijkheden

**Bewerken**
- Niet-destructief: het RAW-bestand wordt nooit gewijzigd. Bewerkingen en
  de volledige geschiedenis worden automatisch opgeslagen in een
  sidecar-bestand naast de foto.
- Belichting, contrast, schaduwen/hooglichten, zwart- en witpunt,
  toonequalizer, textuur, helderheid, nevel verwijderen, levendigheid en
  verzadiging.
- Witbalans, curven RGB/R/G/B, HSL-equalizer, zwart-wit,
  kleurgradatie.
- "Zoals camera-JPEG": toon en verzadiging worden afgestemd op de JPEG
  die in dezelfde opname is ingebed.
- Automatische toon (Ctrl+U).
- Lenscorrectie uit de lensfun-database: vignettering, vervorming,
  chromatische aberratie.
- Bijsnijden en rechtzetten, perspectiefcorrectie, vlekken verwijderen,
  maskers.
- Ruisonderdrukking, verscherping, vignet en filmkorrel.

**Bekijken en selecteren**
- Filmstrip met alle RAW-bestanden uit de map; naburige foto's worden
  vooraf ontwikkeld, dus bladeren met ←/→ gaat meteen.
- Beoordelingen 0–5, vlaggen "gekozen/afgewezen", filters; afgewezen
  foto's gaan naar de prullenbak van het systeem.
- Voor/na: `\` ingedrukt houden of gesplitste weergave (Y).
- Twee foto's naast elkaar vergelijken (C) met gedeelde zoom.
- Waarschuwing voor uitgebeten lichten en dichtgelopen schaduwen,
  RGB-histogram, opname-info (ISO, sluitertijd, diafragma, objectief),
  minikaart op 100%.
- Volledig scherm, 15 thema's (waaronder macOS en Mac OS 9 Platinum).

**Batchwerk en export**
- Instellingen kopiëren en plakken (met keuze van groepen) naar een of
  veel foto's.
- Voorinstellingen: opslaan, hernoemen, importeren en exporteren.
- Exporteer de geopende foto, de geselecteerde, de gefilterde filmstrip
  of de hele map; bestandsnaamsjablonen (`{name}`, `{num}`, `{date}`),
  verkleinen, JPEG-kwaliteit.
- EXIF en een sRGB-ICC-profiel in JPEG, PNG en TIFF.
- TIFF en PNG desgewenst in 16 bit.

**Interface in 31 talen**, standaard in de taal van het systeem. Alle
sneltoetsen zijn opnieuw toe te wijzen.

## Schermafbeeldingen

![Voor/na in gesplitste weergave](screenshots/before-after.jpg)

![Exportvenster](screenshots/export.png)

![Licht macOS-thema](screenshots/light.jpg)

## Bouwen vanuit de broncode

vraw is geschreven in [V](https://vlang.io) bovenop mijn eigen
GUI-bibliotheek [vgui](https://github.com/Mintormo/vgui). Het
hoofdplatform is Linux (getest op Ubuntu 24.04). De Windows-versie wordt
op Linux gecross-compileerd; rechtstreeks bouwen op Windows in MSYS2 zou
ook moeten werken, maar is nog niet getest.

### Afhankelijkheden

| Onderdeel | Versie | Linux (Ubuntu / Debian / Mint) | Windows (MSYS2, MINGW64) |
|---|---|---|---|
| V-compiler | 0.5.2 (a1c9e93) of nieuwer | vanuit de broncode (stap 3) | vanuit de broncode |
| gcc (met OpenMP) | 13+ | `build-essential` | `mingw-w64-x86_64-gcc` |
| LibRaw | 0.21+ | `libraw-dev` | `mingw-w64-x86_64-libraw` |
| lensfun | 0.3.4 | `liblensfun-dev` | `mingw-w64-x86_64-lensfun` |
| libjpeg | elke | `libjpeg-dev` | `mingw-w64-x86_64-libjpeg-turbo` |
| SDL3, SDL3_ttf, SDL3_image | 3.2+, 3.2+, 3.4+ | vanuit de broncode (stap 2), nog niet in de pakketbronnen | `mingw-w64-x86_64-sdl3`, `-sdl3-ttf`, `-sdl3-image` |
| vgui | nieuwste | `git clone` (stap 4) | `git clone` |

vraw bouwt alleen met gcc (`-cc gcc`).

### Linux

**1. Systeempakketten** — compiler, LibRaw, lensfun, libjpeg en de
bibliotheken waarmee SDL3 wordt gebouwd:

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

Op Fedora, Arch en andere distributies installeert u dezelfde
bibliotheken met hun pakketbeheerder. Levert die al SDL3, SDL3_ttf en
SDL3_image 3.4 of nieuwer (met `-devel`/`-dev`-pakketten), sla dan
stap 2 over.

**2. SDL3, SDL3_ttf, SDL3_image** — vanuit de broncode gebouwd en
geïnstalleerd in `/usr/local`:

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

**3. V-compiler:**

```bash
git clone https://github.com/vlang/v ~/soft/v
cd ~/soft/v && make
```

**4. vgui en vraw.** V vindt de module `vgui` via `~/.vmodules`:

```bash
mkdir -p ~/.vmodules ~/projects
git clone https://github.com/Mintormo/vgui ~/projects/vgui
ln -s ~/projects/vgui ~/.vmodules/vgui
git clone https://github.com/Mintormo/vraw ~/projects/vraw
cd ~/projects/vraw
~/soft/v/v -prod -cc gcc .     # -> ./vraw
./vraw
```

`-prod` zet de optimalisaties van gcc aan: de pipeline is ongeveer
2,5 keer sneller, compileren duurt ongeveer een halve minuut. Andere
opdrachten:

```bash
~/soft/v/v -cc gcc test .      # tests
tools/portable.sh              # draagbare map en archief in dist/
```

**5. Actuele objectiefprofielen (optioneel).** De lensfun-database in de
pakketten van distributies is oud. vraw leest ook een nieuwere uit
`~/.local/share/lensfun/updates/version_1`:

```bash
mkdir -p ~/.local/share/lensfun/updates/version_1
curl -L https://lensfun.github.io/db/version_1.tar.bz2 \
  | tar -xj -C ~/.local/share/lensfun/updates/version_1
```

### Windows

**Cross-compileren op Linux** — zo worden de archieven van de releases
gemaakt. Nodig zijn V en vgui uit de Linux-stappen 3–4 en MinGW-w64:

```bash
sudo apt install gcc-mingw-w64-x86-64 zstd
python3 tools/win_deps.py      # SDL3, LibRaw, lensfun en afhankelijkheden
                               # uit MSYS2-pakketten -> ~/soft/mingw64-vraw
tools/windows.sh               # -> dist/vraw-windows-x86_64.zip
```

Het archief bevat `vraw.exe`, alle benodigde DLL's en de
objectievendatabase.

**Rechtstreeks in MSYS2 (nog niet getest).** Installeer
[MSYS2](https://www.msys2.org), open de shell **MSYS2 MINGW64** en voer
uit:

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

Om `vraw.exe` buiten de MSYS2-shell te starten, zet u de benodigde DLL's
uit `C:\msys64\mingw64\bin` ernaast (`tools/windows.sh` laat zien hoe ze
worden verzameld).

### Documentatie voor ontwikkelaars

De code is uitgebreid van commentaar voorzien. De ontwerpnotities zijn
in het Russisch: [PROJECT.md](PROJECT.md) — modules en pipeline,
[ROADMAP.md](ROADMAP.md) — wat klaar is en wat gepland is,
[REQUIREMENTS.md](REQUIREMENTS.md) — wat het programma nu doet.

## Gemaakt met Claude Code

vraw is gevibecodeerd: samen geschreven met
[Claude Code](https://claude.com/claude-code), de AI-programmeerassistent
van Anthropic. Het programma is geschreven in [V](https://vlang.io) op
mijn eigen GUI-bibliotheek [vgui](https://github.com/Mintormo/vgui), met een eigen toonverwerking; LibRaw
doet alleen de demosaicing.

## Licentie

MIT, zie [LICENSE](LICENSE). De broncode staat in deze repository. De
componenten van derden in de archieven (LibRaw, lensfun, SDL3
en andere) vallen onder hun eigen licenties: zie
`THIRD_PARTY.md` en de map `licenses/` in het archief.
