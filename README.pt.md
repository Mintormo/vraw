# vraw

[English](README.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | **Português** | [Polski](README.pl.md)

Um revelador RAW gratuito para Linux e Windows. Abre Canon CR3 e todos os
outros formatos que o LibRaw entende, permite editar de forma não
destrutiva e exporta para JPEG, PNG, TIFF, BMP, QOI ou GIF. Portátil:
basta descompactar e executar, sem instalar nada.

![Janela principal do vraw](screenshots/main.jpg)

## Download

O arquivo mais recente está em [Releases](../../releases/latest):

- **Linux x86_64** — `vraw-linux-x86_64.tar.gz`. Descompactar em
  qualquer lugar e executar `vraw/vraw`. Requer glibc 2.39 ou mais
  recente (Ubuntu 24.04, Linux Mint 22, Fedora e Arch recentes).
- **Windows x64** — `vraw-windows-x86_64.zip`. Descompactar e executar
  `vraw.exe`. A versão para Windows é experimental: até agora testada no Wine.

As configurações e as predefinições ficam ao lado do programa, por isso a
pasta pode ficar num pen drive.

Não é preciso instalar mais nada: todas as bibliotecas estão dentro do
arquivo.

## Requisitos do sistema

| | Mínimo | Recomendado |
|---|---|---|
| Sistema | Linux x86_64 com glibc 2.39+ (X11 ou Wayland); Windows 10 de 64 bits | o mesmo |
| Processador | qualquer x86 de 64 bits | 4 núcleos ou mais (o processamento e a exportação usam todos os núcleos) |
| Memória | 4 GB | 8 GB ou mais |
| Disco | 100 MB para o programa | mais espaço para as fotos |
| Ecrã/tela | 1280×720 | 1920×1080 |

Não é preciso placa de vídeo: tudo corre no processador e todas as
ferramentas respondem de imediato.

## Funcionalidades

**Edição**
- Não destrutiva: o ficheiro RAW nunca é alterado. As edições e todo o
  histórico são guardados automaticamente num ficheiro auxiliar ao lado
  da foto.
- Exposição, contraste, sombras/realces, pontos de preto e branco,
  equalizador de tons, textura, nitidez local, remoção de névoa,
  vivacidade e saturação.
- Balanço de brancos, curvas RGB/R/G/B, equalizador HSL, preto e branco,
  gradação de cor.
- «Como o JPEG da câmara»: o tom e a saturação são ajustados ao JPEG
  incorporado na mesma foto.
- Tom automático (Ctrl+U).
- Correção de objetiva pela base de dados lensfun: vinheta, distorção,
  aberração cromática.
- Recorte e endireitamento, correção de perspetiva, remoção de manchas,
  máscaras.
- Redução de ruído, nitidez, vinheta e grão de filme.

**Visualização e seleção**
- Faixa de miniaturas com todos os RAW da pasta; as fotos vizinhas são
  reveladas antecipadamente, por isso passar com ←/→ é instantâneo.
- Classificação de 0 a 5, marcas «escolhida/rejeitada», filtros; as fotos
  rejeitadas vão para a reciclagem do sistema.
- Antes/depois: manter `\` premido ou vista dividida (Y).
- Comparar duas fotos lado a lado (C) com zoom partilhado.
- Aviso de altas luzes e sombras cortadas, histograma RGB, dados da foto
  (ISO, velocidade, abertura, objetiva), minimapa a 100%.
- Modo de ecrã inteiro, 15 temas (incluindo macOS e Mac OS 9 Platinum).

**Trabalho em lote e exportação**
- Copiar e colar configurações (escolhendo os grupos) para uma ou várias
  fotos.
- Predefinições: guardar, renomear, importar e exportar.
- Exportar a foto aberta, as selecionadas, a faixa filtrada ou a pasta
  inteira; modelos de nome (`{name}`, `{num}`, `{date}`), redução de
  tamanho, qualidade JPEG.
- EXIF e perfil ICC sRGB em JPEG, PNG e TIFF.
- TIFF e PNG em 16 bits, se desejado.

**Interface em 31 idiomas**, por omissão no idioma do sistema. Todos os
atalhos de teclado podem ser redefinidos.

## Capturas de ecrã

![Antes/depois em vista dividida](screenshots/before-after.jpg)

![Janela de exportação](screenshots/export.png)

![Tema claro macOS](screenshots/light.jpg)

## Feito com Claude Code

O vraw foi criado com vibe coding: escrito em conjunto com o
[Claude Code](https://claude.com/claude-code), o assistente de
programação com IA da Anthropic. O programa está escrito em
[V](https://vlang.io) sobre a minha própria biblioteca gráfica vgui, com
processamento de tons próprio; o LibRaw faz apenas o demosaico.

## Licença

MIT, ver [LICENSE](LICENSE). O código-fonte não é publicado. Os
componentes de terceiros incluídos nos arquivos (LibRaw, lensfun, SDL3
e outros) estão sob as suas próprias licenças: ver
`THIRD_PARTY.md` e a pasta `licenses/` dentro do arquivo.
