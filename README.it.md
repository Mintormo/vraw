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

## Fatto con Claude Code

vraw è stato scritto in vibe coding, insieme a
[Claude Code](https://claude.com/claude-code), l'assistente di
programmazione IA di Anthropic. Il programma è scritto in
[V](https://vlang.io) sulla mia libreria grafica vgui, con una propria
pipeline dei toni; LibRaw si occupa solo del demosaicing.

## Licenza

MIT, vedi [LICENSE](LICENSE). Il codice sorgente non è pubblicato. I
componenti di terze parti inclusi negli archivi (LibRaw, lensfun, SDL3 e
altri) sono soggetti alle proprie licenze: vedi `THIRD_PARTY.md` e la
cartella `licenses/` dentro l'archivio.
