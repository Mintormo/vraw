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

## Fait avec Claude Code

vraw a été créé en vibe coding : écrit avec
[Claude Code](https://claude.com/claude-code), l'assistant de
programmation IA d'Anthropic. Le programme est écrit en
[V](https://vlang.io) sur ma propre bibliothèque graphique vgui, avec son
propre pipeline de tons ; LibRaw se charge uniquement du dématriçage.

## Licence

MIT, voir [LICENSE](LICENSE). Le code source n'est pas publié. Les
composants tiers inclus dans les archives (LibRaw, lensfun, SDL3
et d'autres) relèvent de leurs propres licences :
voir `THIRD_PARTY.md` et le dossier `licenses/` dans l'archive.
