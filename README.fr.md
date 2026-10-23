# vraw

[English](README.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | **Français** | [Español](README.es.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Português](README.pt.md) | [Polski](README.pl.md)

Un développeur RAW gratuit pour Linux et Windows. Ouvre le Canon CR3 et
tous les autres formats reconnus par LibRaw, permet une retouche non
destructive et exporte en JPEG, PNG, TIFF, BMP, QOI ou GIF. Portable :
on décompresse et on lance, rien à installer.

![Fenêtre principale de vraw](screenshots/main.jpg)

## Téléchargement

La dernière archive se trouve dans [Releases](../../releases/latest) :

- **Linux x86_64** — `vraw-linux-x86_64.tar.gz`. Décompresser n'importe
  où et lancer `vraw/vraw`. Nécessite glibc 2.39 ou plus récent
  (Ubuntu 24.04, Linux Mint 22, Fedora et Arch récents).
- **Windows x64** — `vraw-windows-x86_64.zip`. Décompresser et lancer
  `vraw.exe`. La version Windows est expérimentale : testée pour l'instant sous Wine.

Les réglages et les préréglages sont rangés à côté du programme : le
dossier peut donc vivre sur une clé USB.

Rien d'autre à installer : toutes les bibliothèques sont dans l'archive.

## Configuration requise

| | Minimum | Recommandé |
|---|---|---|
| Système | Linux x86_64 avec glibc 2.39+ (X11 ou Wayland) ; Windows 10 64 bits | idem |
| Processeur | tout x86 64 bits | 4 cœurs ou plus (le pipeline et l'export utilisent tous les cœurs) |
| Mémoire | 4 Go | 8 Go ou plus |
| Disque | 100 Mo pour le programme | plus la place pour les photos |
| Écran | 1280×720 | 1920×1080 |

Aucune carte graphique n'est nécessaire : tout tourne sur le processeur,
et tous les outils réagissent instantanément.

## Fonctionnalités

**Retouche**
- Non destructive : le fichier RAW n'est jamais modifié. Les réglages et
  tout l'historique sont enregistrés automatiquement dans un fichier
  annexe à côté de la photo.
- Exposition, contraste, ombres/hautes lumières, points noir et blanc,
  égaliseur de tons, texture, clarté, correction du voile, vibrance et
  saturation.
- Balance des blancs, courbes RVB/R/V/B, égaliseur TSL, noir et blanc,
  étalonnage des couleurs.
- « Comme le JPEG de l'appareil » : les tons et la saturation sont
  ajustés sur le JPEG intégré à la même prise de vue.
- Tons automatiques (Ctrl+U).
- Correction d'objectif d'après la base lensfun : vignetage, distorsion,
  aberrations chromatiques.
- Recadrage et redressement, correction de perspective, suppression des
  taches, masques.
- Réduction du bruit, netteté, vignetage et grain argentique.

**Visualisation et tri**
- Bande de vignettes avec tous les RAW du dossier ; les images voisines
  sont développées à l'avance, le passage avec ←/→ est donc instantané.
- Notes de 0 à 5, marqueurs « retenue/rejetée », filtres ; les images
  rejetées partent dans la corbeille du système.
- Avant/après : maintenir `\` ou vue partagée (Y).
- Comparaison de deux images côte à côte (C) avec zoom commun.
- Alerte d'écrêtage, histogramme RVB, informations de prise de vue (ISO,
  vitesse, ouverture, objectif), mini-carte à 100 %.
- Mode plein écran, 15 thèmes (dont macOS et Mac OS 9 Platinum).

**Traitement par lots et export**
- Copier-coller des réglages (au choix des groupes) vers une ou plusieurs
  images.
- Préréglages : enregistrer, renommer, importer et exporter.
- Export de l'image ouverte, des images sélectionnées, de la bande
  filtrée ou de tout le dossier ; modèles de nom (`{name}`, `{num}`,
  `{date}`), réduction de taille, qualité JPEG.
- EXIF et profil ICC sRGB dans les JPEG, PNG et TIFF.
- TIFF et PNG en 16 bits au choix.

**Interface en 31 langues**, dans la langue du système par défaut. Tous
les raccourcis clavier peuvent être réattribués.

## Captures d'écran

![Avant/après en vue partagée](screenshots/before-after.jpg)

![Fenêtre d'export](screenshots/export.png)

![Thème clair macOS](screenshots/light.jpg)

## Compiler depuis les sources

vraw est écrit en [V](https://vlang.io) avec ma bibliothèque graphique
[vgui](https://github.com/Mintormo/vgui). La plateforme principale est
Linux (testé sous Ubuntu 24.04). La version Windows est compilée de
façon croisée sous Linux ; la compilation directement sous Windows dans
MSYS2 devrait aussi fonctionner, mais n'a pas encore été testée.

### Dépendances

| Composant | Version | Linux (Ubuntu / Debian / Mint) | Windows (MSYS2, MINGW64) |
|---|---|---|---|
| Compilateur V | 0.5.2 (a1c9e93) ou plus récent | depuis les sources (étape 3) | depuis les sources |
| gcc (avec OpenMP) | 13+ | `build-essential` | `mingw-w64-x86_64-gcc` |
| LibRaw | 0.21+ | `libraw-dev` | `mingw-w64-x86_64-libraw` |
| lensfun | 0.3.4 | `liblensfun-dev` | `mingw-w64-x86_64-lensfun` |
| libjpeg | toute version | `libjpeg-dev` | `mingw-w64-x86_64-libjpeg-turbo` |
| SDL3, SDL3_ttf, SDL3_image | 3.2+, 3.2+, 3.4+ | depuis les sources (étape 2), pas encore dans les dépôts | `mingw-w64-x86_64-sdl3`, `-sdl3-ttf`, `-sdl3-image` |
| vgui | dernière | `git clone` (étape 4) | `git clone` |

vraw se compile uniquement avec gcc (`-cc gcc`).

### Linux

**1. Paquets système** — compilateur, LibRaw, lensfun, libjpeg et les
bibliothèques avec lesquelles SDL3 est compilée :

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

Sous Fedora, Arch et les autres distributions, installez les mêmes
bibliothèques avec leur gestionnaire de paquets. S'il fournit déjà SDL3,
SDL3_ttf et SDL3_image 3.4 ou plus récents (avec les paquets
`-devel`/`-dev`), passez l'étape 2.

**2. SDL3, SDL3_ttf, SDL3_image** — compilées depuis les sources et
installées dans `/usr/local` :

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

**3. Compilateur V :**

```bash
git clone https://github.com/vlang/v ~/soft/v
cd ~/soft/v && make
```

**4. vgui et vraw.** V trouve le module `vgui` via `~/.vmodules` :

```bash
mkdir -p ~/.vmodules ~/projects
git clone https://github.com/Mintormo/vgui ~/projects/vgui
ln -s ~/projects/vgui ~/.vmodules/vgui
git clone https://github.com/Mintormo/vraw ~/projects/vraw
cd ~/projects/vraw
~/soft/v/v -prod -cc gcc .     # -> ./vraw
./vraw
```

`-prod` active les optimisations de gcc : le pipeline est environ
2,5 fois plus rapide, la compilation prend environ une demi-minute.
Autres commandes :

```bash
~/soft/v/v -cc gcc test .      # tests
tools/portable.sh              # dossier portable et archive dans dist/
```

**5. Profils d'objectifs à jour (facultatif).** La base lensfun des
paquets des distributions est ancienne. vraw lit aussi une base plus
récente dans `~/.local/share/lensfun/updates/version_1` :

```bash
mkdir -p ~/.local/share/lensfun/updates/version_1
curl -L https://lensfun.github.io/db/version_1.tar.bz2 \
  | tar -xj -C ~/.local/share/lensfun/updates/version_1
```

### Windows

**Compilation croisée sous Linux** — c'est ainsi que sont produites les
archives des versions. Il faut V et vgui (étapes 3–4 pour Linux) ainsi
que MinGW-w64 :

```bash
sudo apt install gcc-mingw-w64-x86-64 zstd
python3 tools/win_deps.py      # SDL3, LibRaw, lensfun et leurs dépendances
                               # depuis les paquets MSYS2 -> ~/soft/mingw64-vraw
tools/windows.sh               # -> dist/vraw-windows-x86_64.zip
```

L'archive contient `vraw.exe`, toutes les DLL nécessaires et la base
des objectifs.

**Directement dans MSYS2 (pas encore testé).** Installez
[MSYS2](https://www.msys2.org), ouvrez le terminal **MSYS2 MINGW64** et
lancez :

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

Pour lancer `vraw.exe` hors du terminal MSYS2, placez à côté de lui les
DLL nécessaires de `C:\msys64\mingw64\bin` (`tools/windows.sh` montre
comment les rassembler).

### Documentation pour les développeurs

Le code est commenté en détail. Les notes de conception sont en russe :
[PROJECT.md](PROJECT.md) — modules et pipeline,
[ROADMAP.md](ROADMAP.md) — ce qui est fait et ce qui est prévu,
[REQUIREMENTS.md](REQUIREMENTS.md) — ce que fait le programme
aujourd'hui.

## Fait avec Claude Code

vraw a été créé en vibe coding : écrit avec
[Claude Code](https://claude.com/claude-code), l'assistant de
programmation IA d'Anthropic. Le programme est écrit en
[V](https://vlang.io) sur ma propre bibliothèque graphique [vgui](https://github.com/Mintormo/vgui), avec son
propre pipeline de tons ; LibRaw se charge uniquement du dématriçage.

## Licence

MIT, voir [LICENSE](LICENSE). Le code source se trouve dans ce dépôt. Les
composants tiers inclus dans les archives (LibRaw, lensfun, SDL3
et d'autres) relèvent de leurs propres licences :
voir `THIRD_PARTY.md` et le dossier `licenses/` dans l'archive.
