# vraw

[English](README.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | **Italiano** | [Nederlands](README.nl.md) | [Português](README.pt.md) | [Polski](README.pl.md)

Uno sviluppatore RAW gratuito per Linux e Windows. Apre i Canon CR3 e
tutti gli altri formati supportati da LibRaw, permette di modificare le
foto in modo non distruttivo ed esporta in JPEG, PNG, TIFF, BMP, QOI o
GIF. Portatile: si estrae e si avvia, senza installazione.

![Finestra principale di vraw](screenshots/main.jpg)

## Download

Scarica l'archivio più recente da [Releases](../../releases/latest):

- **Linux x86_64** — `vraw-linux-x86_64.tar.gz`. Estrarre ovunque e
  avviare `vraw/vraw`. Richiede glibc 2.39 o successiva (Ubuntu 24.04,
  Linux Mint 22, Fedora e Arch recenti).
- **Windows x64** — `vraw-windows-x86_64.zip`. Estrarre e avviare
  `vraw.exe`. La versione per Windows è sperimentale: finora è stata
  provata con Wine.

Le impostazioni e i preset sono salvati accanto al programma, quindi la
cartella può stare su una chiavetta USB.

Non serve installare nient'altro: tutte le librerie sono nell'archivio.

## Requisiti di sistema

| | Minimo | Consigliato |
|---|---|---|
| Sistema | Linux x86_64 con glibc 2.39+ (X11 o Wayland); Windows 10 a 64 bit | lo stesso |
| Processore | qualsiasi x86 a 64 bit | 4 core o più (l'elaborazione e l'esportazione usano tutti i core) |
| Memoria | 4 GB | 8 GB o più |
| Disco | 100 MB per il programma | più lo spazio per le foto |
| Schermo | 1280×720 | 1920×1080 |

Non serve una scheda grafica: tutto gira sul processore e tutti gli
strumenti rispondono all'istante.

## Funzioni

**Modifica**
- Non distruttiva: il file RAW non viene mai modificato. Le modifiche e
  l'intera cronologia si salvano automaticamente in un file accanto alla
  foto.
- Esposizione, contrasto, ombre/luci, punto del nero e del bianco,
  equalizzatore dei toni, texture, chiarezza, rimozione foschia, vividezza
  e saturazione.
- Bilanciamento del bianco, curve RGB/R/G/B, equalizzatore HSL,
  conversione in bianco e nero, color grading.
- «Come il JPEG della fotocamera»: tono e saturazione vengono adattati al
  JPEG incorporato nello stesso scatto.
- Tono automatico (Ctrl+U).
- Correzione dell'obiettivo dal database lensfun: vignettatura,
  distorsione, aberrazione cromatica.
- Ritaglio e raddrizzamento, correzione della prospettiva, rimozione
  macchie, maschere.
- Riduzione del rumore, nitidezza, vignettatura e grana pellicola.

**Visualizzazione e selezione**
- Striscia con tutti i file RAW della cartella; gli scatti vicini vengono
  sviluppati in anticipo, quindi lo scorrimento con ←/→ è istantaneo.
- Valutazioni 0–5, bandierine scelta/scarto, filtri; gli scatti scartati
  finiscono nel cestino di sistema.
- Prima/dopo: tenere premuto `\` o usare la vista divisa (Y).
- Confronto di due scatti affiancati (C) con zoom condiviso.
- Avviso di luci e ombre bruciate, istogramma RGB, dati di scatto (ISO,
  tempo, diaframma, obiettivo), minimappa al 100%.
- Modalità a schermo intero, 15 temi (tra cui macOS e Mac OS 9 Platinum).

**Lavoro in serie ed esportazione**
- Copia e incolla delle impostazioni (scegliendo i gruppi) su uno o più
  scatti.
- Preset: salvataggio, rinomina, importazione ed esportazione.
- Esportazione dello scatto aperto, di quelli selezionati, della striscia
  filtrata o dell'intera cartella; modelli per il nome del file (`{name}`,
  `{num}`, `{date}`), ridimensionamento, qualità JPEG.
- EXIF e profilo ICC sRGB vengono scritti in JPEG, PNG e TIFF.
- TIFF e PNG si possono esportare a 16 bit.

**Interfaccia in 31 lingue**, scelta di default in base alla lingua del
sistema. Tutte le scorciatoie da tastiera si possono riassegnare.

## Screenshot

![Prima/dopo con vista divisa](screenshots/before-after.jpg)

![Finestra di esportazione](screenshots/export.png)

![Tema chiaro macOS](screenshots/light.jpg)

## Compilare dai sorgenti

vraw è scritto in [V](https://vlang.io) sulla mia libreria grafica
[vgui](https://github.com/Mintormo/vgui). La piattaforma principale è
Linux (provato su Ubuntu 24.04). La versione per Windows viene
cross-compilata su Linux; la compilazione direttamente su Windows in
MSYS2 dovrebbe funzionare, ma non è ancora stata provata.

### Dipendenze

| Componente | Versione | Linux (Ubuntu / Debian / Mint) | Windows (MSYS2, MINGW64) |
|---|---|---|---|
| Compilatore V | 0.5.2 (a1c9e93) o successiva | dai sorgenti (passo 3) | dai sorgenti |
| gcc (con OpenMP) | 13+ | `build-essential` | `mingw-w64-x86_64-gcc` |
| LibRaw | 0.21+ | `libraw-dev` | `mingw-w64-x86_64-libraw` |
| lensfun | 0.3.4 | `liblensfun-dev` | `mingw-w64-x86_64-lensfun` |
| libjpeg | qualsiasi | `libjpeg-dev` | `mingw-w64-x86_64-libjpeg-turbo` |
| SDL3, SDL3_ttf, SDL3_image | 3.2+, 3.2+, 3.4+ | dai sorgenti (passo 2), non ancora nei repository | `mingw-w64-x86_64-sdl3`, `-sdl3-ttf`, `-sdl3-image` |
| vgui | l'ultima | `git clone` (passo 4) | `git clone` |

vraw si compila solo con gcc (`-cc gcc`).

### Linux

**1. Pacchetti di sistema** — compilatore, LibRaw, lensfun, libjpeg e le
librerie con cui viene compilata SDL3:

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

Su Fedora, Arch e altre distribuzioni installate le stesse librerie con
il loro gestore di pacchetti. Se fornisce già SDL3, SDL3_ttf e
SDL3_image 3.4 o successive (con i pacchetti `-devel`/`-dev`), saltate
il passo 2.

**2. SDL3, SDL3_ttf, SDL3_image** — compilate dai sorgenti e installate
in `/usr/local`:

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

**3. Compilatore V:**

```bash
git clone https://github.com/vlang/v ~/soft/v
cd ~/soft/v && make
```

**4. vgui e vraw.** V trova il modulo `vgui` tramite `~/.vmodules`:

```bash
mkdir -p ~/.vmodules ~/projects
git clone https://github.com/Mintormo/vgui ~/projects/vgui
ln -s ~/projects/vgui ~/.vmodules/vgui
git clone https://github.com/Mintormo/vraw ~/projects/vraw
cd ~/projects/vraw
~/soft/v/v -prod -cc gcc .     # -> ./vraw
./vraw
```

`-prod` attiva le ottimizzazioni di gcc: la pipeline è circa 2,5 volte
più veloce, la compilazione richiede circa mezzo minuto. Altri comandi:

```bash
~/soft/v/v -cc gcc test .      # test
tools/portable.sh              # cartella portatile e archivio in dist/
```

**5. Profili degli obiettivi aggiornati (facoltativo).** Il database di
lensfun nei pacchetti delle distribuzioni è vecchio. vraw legge anche
uno più recente da `~/.local/share/lensfun/updates/version_1`:

```bash
mkdir -p ~/.local/share/lensfun/updates/version_1
curl -L https://lensfun.github.io/db/version_1.tar.bz2 \
  | tar -xj -C ~/.local/share/lensfun/updates/version_1
```

### Windows

**Cross-compilazione su Linux** — così vengono creati gli archivi delle
versioni. Servono V e vgui dai passi 3–4 per Linux e MinGW-w64:

```bash
sudo apt install gcc-mingw-w64-x86-64 zstd
python3 tools/win_deps.py      # SDL3, LibRaw, lensfun e le loro dipendenze
                               # dai pacchetti MSYS2 -> ~/soft/mingw64-vraw
tools/windows.sh               # -> dist/vraw-windows-x86_64.zip
```

L'archivio contiene `vraw.exe`, tutte le DLL necessarie e il database
degli obiettivi.

**Direttamente in MSYS2 (non ancora provato).** Installate
[MSYS2](https://www.msys2.org), aprite il terminale **MSYS2 MINGW64** ed
eseguite:

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

Per avviare `vraw.exe` fuori dal terminale MSYS2, mettete accanto le DLL
necessarie da `C:\msys64\mingw64\bin` (`tools/windows.sh` mostra come
raccoglierle).

### Documentazione per sviluppatori

Il codice è commentato in dettaglio. Le note di progetto sono in russo:
[PROJECT.md](PROJECT.md) — moduli e pipeline,
[ROADMAP.md](ROADMAP.md) — cosa è fatto e cosa è in programma,
[REQUIREMENTS.md](REQUIREMENTS.md) — cosa fa il programma adesso.

## Fatto con Claude Code

vraw è stato scritto in vibe coding, insieme a
[Claude Code](https://claude.com/claude-code), l'assistente di
programmazione IA di Anthropic. Il programma è scritto in
[V](https://vlang.io) sulla mia libreria grafica [vgui](https://github.com/Mintormo/vgui), con una propria
pipeline dei toni; LibRaw si occupa solo del demosaicing.

## Licenza

MIT, vedi [LICENSE](LICENSE). Il codice sorgente è in questo repository. I
componenti di terze parti inclusi negli archivi (LibRaw, lensfun, SDL3 e
altri) sono soggetti alle proprie licenze: vedi `THIRD_PARTY.md` e la
cartella `licenses/` dentro l'archivio.
