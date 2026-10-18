# vraw

[English](README.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | **Nederlands** | [Português](README.pt.md) | [Polski](README.pl.md)

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
  starten. De AI-ruisonderdrukking heeft het
  [Microsoft Visual C++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe)
  nodig. De Windows-versie is experimenteel: tot nu toe getest onder Wine.

Instellingen, voorinstellingen en het AI-model staan naast het programma,
dus de map kan op een USB-stick staan.

Verder hoeft er niets geïnstalleerd te worden: alle bibliotheken zitten
in het archief. De enige uitzondering is het Visual C++ Redistributable
op Windows, en alleen voor de AI-ruisonderdrukking; zonder werkt al het
andere.

## Systeemvereisten

| | Minimaal | Aanbevolen |
|---|---|---|
| Systeem | Linux x86_64 met glibc 2.39+ (X11 of Wayland); Windows 10 64-bit | hetzelfde |
| Processor | elke 64-bit x86 | 4+ kernen (de verwerking en export gebruiken alle kernen) |
| Geheugen | 4 GB | 8 GB of meer |
| Schijf | 300 MB voor het programma | plus ruimte voor de foto's |
| Scherm | 1280×720 | 1920×1080 |

Een videokaart is niet nodig. De AI-ruisonderdrukking draait op de
processor en is traag: op een Intel Core i5-1235U (10 kernen) met 16 GB
RAM duurt het voorbeeld ongeveer 4 minuten en een volledige foto van
24 MP ongeveer 16 minuten. Alle andere gereedschappen reageren meteen.

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
- **AI-ruisonderdrukking** met het neurale netwerk SCUNet (meegeleverd,
  werkt offline): verwijdert ruis en behoudt details. Draait op de
  achtergrond met voortgang en annuleren.

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

## Gemaakt met Claude Code

vraw is gevibecodeerd: samen geschreven met
[Claude Code](https://claude.com/claude-code), de AI-programmeerassistent
van Anthropic. Het programma is geschreven in [V](https://vlang.io) op
mijn eigen GUI-bibliotheek vgui, met een eigen toonverwerking; LibRaw
doet alleen de demosaicing.

## Licentie

MIT, zie [LICENSE](LICENSE). De broncode wordt niet gepubliceerd. De
componenten van derden in de archieven (LibRaw, lensfun, SDL3,
ONNX Runtime, SCUNet en andere) vallen onder hun eigen licenties: zie
`THIRD_PARTY.md` en de map `licenses/` in het archief.
