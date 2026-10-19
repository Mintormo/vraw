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

## Zrobione z Claude Code

vraw powstał metodą vibe codingu: napisany wspólnie z
[Claude Code](https://claude.com/claude-code), asystentem programowania
AI od Anthropic. Program jest napisany w [V](https://vlang.io) na mojej
własnej bibliotece GUI vgui, z własnym przetwarzaniem tonów; LibRaw
wykonuje tylko demozaikowanie.

## Licencja

MIT, zobacz [LICENSE](LICENSE). Kod źródłowy nie jest publikowany.
Komponenty zewnętrzne zawarte w archiwach (LibRaw, lensfun, SDL3
i inne) podlegają własnym licencjom: zobacz
`THIRD_PARTY.md` i folder `licenses/` w archiwum.
