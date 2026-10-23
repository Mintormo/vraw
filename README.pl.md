# vraw

[English](README.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Português](README.pt.md) | **Polski**

Darmowy wywoływacz RAW dla Linuksa i Windows. Otwiera Canon CR3 i
wszystkie inne formaty obsługiwane przez LibRaw, pozwala na edycję
nieniszczącą i eksportuje do JPEG, PNG, TIFF, BMP, QOI lub GIF.
Przenośny: wystarczy rozpakować i uruchomić, nic nie trzeba instalować.

![Główne okno vraw](screenshots/main.jpg)

## Pobieranie

Najnowsze archiwum jest w [Releases](../../releases/latest):

- **Linux x86_64** — `vraw-linux-x86_64.tar.gz`. Rozpakować w dowolnym
  miejscu i uruchomić `vraw/vraw`. Wymaga glibc 2.39 lub nowszego
  (Ubuntu 24.04, Linux Mint 22, aktualne Fedora i Arch).
- **Windows x64** — `vraw-windows-x86_64.zip`. Rozpakować i uruchomić
  `vraw.exe`. Wersja dla Windows jest eksperymentalna: na razie testowana pod Wine.

Ustawienia i presety leżą obok programu, więc folder może działać
z pendrive'a.

Nic więcej nie trzeba instalować: wszystkie biblioteki są w archiwum.

## Wymagania systemowe

| | Minimum | Zalecane |
|---|---|---|
| System | Linux x86_64 z glibc 2.39+ (X11 lub Wayland); Windows 10 64-bit | to samo |
| Procesor | dowolny 64-bitowy x86 | 4+ rdzenie (przetwarzanie i eksport używają wszystkich rdzeni) |
| Pamięć | 4 GB | 8 GB lub więcej |
| Dysk | 100 MB na program | plus miejsce na zdjęcia |
| Ekran | 1280×720 | 1920×1080 |

Karta graficzna nie jest potrzebna: wszystko działa na procesorze,
a wszystkie narzędzia reagują natychmiast.

## Możliwości

**Edycja**
- Nieniszcząca: plik RAW nigdy nie jest zmieniany. Zmiany i pełna
  historia zapisują się automatycznie w pliku pomocniczym obok zdjęcia.
- Ekspozycja, kontrast, cienie/światła, punkt czerni i bieli, korektor
  tonów, tekstura, przejrzystość, usuwanie zamglenia, jaskrawość i
  nasycenie.
- Balans bieli, krzywe RGB/R/G/B, korektor HSL, czerń i biel,
  gradacja kolorów.
- „Jak JPEG z aparatu”: ton i nasycenie są dopasowywane do JPEG-a
  osadzonego w tym samym zdjęciu.
- Auto-ton (Ctrl+U).
- Korekcja obiektywu z bazy lensfun: winietowanie, dystorsja, aberracja
  chromatyczna.
- Kadrowanie i prostowanie, korekcja perspektywy, usuwanie plam, maski.
- Redukcja szumu, wyostrzanie, winieta i ziarno filmowe.

**Przeglądanie i selekcja**
- Taśma miniatur ze wszystkimi plikami RAW z folderu; sąsiednie zdjęcia
  są wywoływane z wyprzedzeniem, więc przełączanie ←/→ jest
  natychmiastowe.
- Oceny 0–5, flagi „wybrane/odrzucone”, filtry; odrzucone zdjęcia trafiają
  do systemowego kosza.
- Przed/po: przytrzymać `\` lub widok dzielony (Y).
- Porównanie dwóch zdjęć obok siebie (C) ze wspólnym powiększeniem.
- Ostrzeżenie o przepaleniach i niedoświetleniach, histogram RGB, dane
  zdjęcia (ISO, czas, przysłona, obiektyw), minimapa przy 100%.
- Tryb pełnoekranowy, 15 motywów (w tym macOS i Mac OS 9 Platinum).

**Praca wsadowa i eksport**
- Kopiowanie i wklejanie ustawień (z wyborem grup) do jednego lub wielu
  zdjęć.
- Presety: zapisywanie, zmiana nazwy, import i eksport.
- Eksport otwartego zdjęcia, zaznaczonych, przefiltrowanej taśmy lub
  całego folderu; szablony nazw (`{name}`, `{num}`, `{date}`),
  zmniejszanie, jakość JPEG.
- EXIF i profil ICC sRGB w JPEG, PNG i TIFF.
- TIFF i PNG opcjonalnie w 16 bitach.

**Interfejs w 31 językach**, domyślnie w języku systemu. Wszystkie skróty
klawiszowe można zmienić.

## Zrzuty ekranu

![Przed/po w widoku dzielonym](screenshots/before-after.jpg)

![Okno eksportu](screenshots/export.png)

![Jasny motyw macOS](screenshots/light.jpg)

## Budowanie ze źródeł

vraw jest napisany w [V](https://vlang.io) na mojej bibliotece GUI
[vgui](https://github.com/Mintormo/vgui). Główną platformą jest Linux
(testowane na Ubuntu 24.04). Wersja dla Windows jest kompilowana
skrośnie na Linuksie; budowanie bezpośrednio w Windows w MSYS2 też
powinno działać, ale nie zostało jeszcze sprawdzone.

### Zależności

| Składnik | Wersja | Linux (Ubuntu / Debian / Mint) | Windows (MSYS2, MINGW64) |
|---|---|---|---|
| Kompilator V | 0.5.2 (a1c9e93) lub nowszy | ze źródeł (krok 3) | ze źródeł |
| gcc (z OpenMP) | 13+ | `build-essential` | `mingw-w64-x86_64-gcc` |
| LibRaw | 0.21+ | `libraw-dev` | `mingw-w64-x86_64-libraw` |
| lensfun | 0.3.4 | `liblensfun-dev` | `mingw-w64-x86_64-lensfun` |
| libjpeg | dowolna | `libjpeg-dev` | `mingw-w64-x86_64-libjpeg-turbo` |
| SDL3, SDL3_ttf, SDL3_image | 3.2+, 3.2+, 3.4+ | ze źródeł (krok 2), jeszcze nie ma ich w repozytoriach | `mingw-w64-x86_64-sdl3`, `-sdl3-ttf`, `-sdl3-image` |
| vgui | najnowsza | `git clone` (krok 4) | `git clone` |

vraw buduje się tylko kompilatorem gcc (`-cc gcc`).

### Linux

**1. Pakiety systemowe** — kompilator, LibRaw, lensfun, libjpeg i
biblioteki, z którymi budowane jest SDL3:

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

W Fedorze, Archu i innych dystrybucjach zainstaluj te same biblioteki
ich menedżerem pakietów. Jeśli ma już SDL3, SDL3_ttf i SDL3_image 3.4
lub nowsze (z pakietami `-devel`/`-dev`), pomiń krok 2.

**2. SDL3, SDL3_ttf, SDL3_image** — budowane ze źródeł i instalowane w
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

**3. Kompilator V:**

```bash
git clone https://github.com/vlang/v ~/soft/v
cd ~/soft/v && make
```

**4. vgui i vraw.** V znajduje moduł `vgui` przez `~/.vmodules`:

```bash
mkdir -p ~/.vmodules ~/projects
git clone https://github.com/Mintormo/vgui ~/projects/vgui
ln -s ~/projects/vgui ~/.vmodules/vgui
git clone https://github.com/Mintormo/vraw ~/projects/vraw
cd ~/projects/vraw
~/soft/v/v -prod -cc gcc .     # -> ./vraw
./vraw
```

`-prod` włącza optymalizacje gcc: potok jest około 2,5 raza szybszy,
kompilacja trwa około pół minuty. Inne polecenia:

```bash
~/soft/v/v -cc gcc test .      # testy
tools/portable.sh              # przenośny folder i archiwum w dist/
```

**5. Aktualne profile obiektywów (opcjonalnie).** Baza lensfun w
pakietach dystrybucji jest stara. vraw czyta też nowszą z
`~/.local/share/lensfun/updates/version_1`:

```bash
mkdir -p ~/.local/share/lensfun/updates/version_1
curl -L https://lensfun.github.io/db/version_1.tar.bz2 \
  | tar -xj -C ~/.local/share/lensfun/updates/version_1
```

### Windows

**Kompilacja skrośna na Linuksie** — tak powstają archiwa wydań.
Potrzebne są V i vgui z kroków 3–4 dla Linuksa oraz MinGW-w64:

```bash
sudo apt install gcc-mingw-w64-x86-64 zstd
python3 tools/win_deps.py      # SDL3, LibRaw, lensfun i ich zależności
                               # z pakietów MSYS2 -> ~/soft/mingw64-vraw
tools/windows.sh               # -> dist/vraw-windows-x86_64.zip
```

Archiwum zawiera `vraw.exe`, wszystkie potrzebne mu biblioteki DLL i
bazę obiektywów.

**Bezpośrednio w MSYS2 (jeszcze nie sprawdzone).** Zainstaluj
[MSYS2](https://www.msys2.org), otwórz powłokę **MSYS2 MINGW64** i
wykonaj:

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

Aby uruchamiać `vraw.exe` poza powłoką MSYS2, połóż obok niego potrzebne
biblioteki DLL z `C:\msys64\mingw64\bin` (jak je zebrać, pokazuje
`tools/windows.sh`).

### Dokumentacja dla programistów

Kod jest szczegółowo skomentowany. Notatki projektowe są po rosyjsku:
[PROJECT.md](PROJECT.md) — moduły i potok,
[ROADMAP.md](ROADMAP.md) — co zrobione i co w planach,
[REQUIREMENTS.md](REQUIREMENTS.md) — co program robi teraz.

## Zrobione z Claude Code

vraw powstał metodą vibe codingu: napisany wspólnie z
[Claude Code](https://claude.com/claude-code), asystentem programowania
AI od Anthropic. Program jest napisany w [V](https://vlang.io) na mojej
własnej bibliotece GUI [vgui](https://github.com/Mintormo/vgui), z własnym przetwarzaniem tonów; LibRaw
wykonuje tylko demozaikowanie.

## Licencja

MIT, zobacz [LICENSE](LICENSE). Kod źródłowy jest w tym repozytorium.
Komponenty zewnętrzne zawarte w archiwach (LibRaw, lensfun, SDL3
i inne) podlegają własnym licencjom: zobacz
`THIRD_PARTY.md` i folder `licenses/` w archiwum.
