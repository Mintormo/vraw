# vraw

[English](README.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | **Español** | [Nederlands](README.nl.md) | [Português](README.pt.md) | [Polski](README.pl.md)

Un revelador RAW gratuito para Linux y Windows. Abre Canon CR3 y todos
los demás formatos que entiende LibRaw, permite editar de forma no
destructiva y exporta a JPEG, PNG, TIFF, BMP, QOI o GIF. Portátil:
descomprimir y ejecutar, sin instalar nada.

![Ventana principal de vraw](screenshots/main.jpg)

## Descarga

El archivo más reciente está en [Releases](../../releases/latest):

- **Linux x86_64** — `vraw-linux-x86_64.tar.gz`. Descomprimir en
  cualquier lugar y ejecutar `vraw/vraw`. Requiere glibc 2.39 o posterior
  (Ubuntu 24.04, Linux Mint 22, Fedora y Arch recientes).
- **Windows x64** — `vraw-windows-x86_64.zip`. Descomprimir y ejecutar
  `vraw.exe`. La reducción de ruido con IA necesita el
  [Microsoft Visual C++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe).
  La versión para Windows es experimental: por ahora probada bajo Wine.

Los ajustes, los preajustes y el modelo de IA se guardan junto al
programa, así que la carpeta puede vivir en una memoria USB.

No hace falta instalar nada más: todas las bibliotecas están dentro del
archivo. La única excepción es el Visual C++ Redistributable en Windows,
y solo para la reducción de ruido con IA; sin él todo lo demás funciona.

## Requisitos del sistema

| | Mínimo | Recomendado |
|---|---|---|
| Sistema | Linux x86_64 con glibc 2.39+ (X11 o Wayland); Windows 10 de 64 bits | lo mismo |
| Procesador | cualquier x86 de 64 bits | 4 núcleos o más (el procesado y la exportación usan todos los núcleos) |
| Memoria | 4 GB | 8 GB o más |
| Disco | 300 MB para el programa | más espacio para las fotos |
| Pantalla | 1280×720 | 1920×1080 |

No se necesita tarjeta gráfica. La reducción de ruido con IA funciona en
el procesador y es lenta: en un Intel Core i5-1235U (10 núcleos) con
16 GB de RAM, la vista previa tarda unos 4 minutos y una foto completa de
24 MP unos 16 minutos. Las demás herramientas responden al instante.

## Funciones

**Edición**
- No destructiva: el archivo RAW nunca se modifica. Los ajustes y todo el
  historial se guardan automáticamente en un archivo adjunto junto a la
  foto.
- Exposición, contraste, sombras/luces, puntos de negro y blanco,
  ecualizador de tonos, textura, claridad, eliminación de neblina,
  intensidad y saturación.
- Balance de blancos, curvas RGB/R/G/B, ecualizador HSL, blanco y negro,
  gradación de color.
- «Como el JPEG de la cámara»: el tono y la saturación se ajustan al JPEG
  incrustado en la misma toma.
- Tono automático (Ctrl+U).
- Corrección de objetivo con la base de datos lensfun: viñeteo,
  distorsión, aberración cromática.
- Recorte y enderezado, corrección de perspectiva, eliminación de
  manchas, máscaras.
- Reducción de ruido, enfoque, viñeta y grano de película.
- **Reducción de ruido con IA** mediante la red neuronal SCUNet (incluida,
  funciona sin conexión): elimina el ruido conservando el detalle. Se
  ejecuta en segundo plano con progreso y cancelación.

**Visualización y selección**
- Tira de miniaturas con todos los RAW de la carpeta; las fotos vecinas
  se revelan por adelantado, así que pasar con ←/→ es instantáneo.
- Valoraciones de 0 a 5, marcas «elegida/rechazada», filtros; las fotos
  rechazadas van a la papelera del sistema.
- Antes/después: mantener `\` o vista dividida (Y).
- Comparar dos fotos lado a lado (C) con zoom compartido.
- Aviso de recorte de luces y sombras, histograma RGB, datos de la toma
  (ISO, velocidad, diafragma, objetivo), minimapa al 100 %.
- Modo de pantalla completa, 15 temas (entre ellos macOS y Mac OS 9
  Platinum).

**Trabajo por lotes y exportación**
- Copiar y pegar ajustes (eligiendo los grupos) en una o muchas fotos.
- Preajustes: guardar, renombrar, importar y exportar.
- Exportar la foto abierta, las seleccionadas, la tira filtrada o toda la
  carpeta; plantillas de nombre (`{name}`, `{num}`, `{date}`), reducción
  de tamaño, calidad JPEG.
- EXIF y perfil ICC sRGB en JPEG, PNG y TIFF.
- TIFF y PNG en 16 bits si se desea.

**Interfaz en 31 idiomas**, por defecto en el idioma del sistema. Todos
los atajos de teclado se pueden reasignar.

## Capturas de pantalla

![Antes/después en vista dividida](screenshots/before-after.jpg)

![Ventana de exportación](screenshots/export.png)

![Tema claro macOS](screenshots/light.jpg)

## Hecho con Claude Code

vraw se creó con vibe coding: escrito junto con
[Claude Code](https://claude.com/claude-code), el asistente de
programación con IA de Anthropic. El programa está escrito en
[V](https://vlang.io) sobre mi propia biblioteca gráfica vgui, con su
propio procesado de tonos; LibRaw solo realiza el demosaico.

## Licencia

MIT, ver [LICENSE](LICENSE). El código fuente no se publica. Los
componentes de terceros incluidos en los archivos (LibRaw, lensfun, SDL3,
ONNX Runtime, SCUNet y otros) se rigen por sus propias licencias: ver
`THIRD_PARTY.md` y la carpeta `licenses/` dentro del archivo.
