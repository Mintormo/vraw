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

## Compilar a partir do código-fonte

O vraw está escrito em [V](https://vlang.io) sobre a minha biblioteca
gráfica [vgui](https://github.com/Mintormo/vgui). A plataforma principal
é o Linux (testado no Ubuntu 24.04). A versão para Windows é compilada
de forma cruzada no Linux; compilar diretamente no Windows com o MSYS2
também deverá funcionar, mas ainda não foi testado.

### Dependências

| Componente | Versão | Linux (Ubuntu / Debian / Mint) | Windows (MSYS2, MINGW64) |
|---|---|---|---|
| Compilador V | 0.5.2 (a1c9e93) ou mais recente | a partir do código-fonte (passo 3) | a partir do código-fonte |
| gcc (com OpenMP) | 13+ | `build-essential` | `mingw-w64-x86_64-gcc` |
| LibRaw | 0.21+ | `libraw-dev` | `mingw-w64-x86_64-libraw` |
| lensfun | 0.3.4 | `liblensfun-dev` | `mingw-w64-x86_64-lensfun` |
| libjpeg | qualquer | `libjpeg-dev` | `mingw-w64-x86_64-libjpeg-turbo` |
| SDL3, SDL3_ttf, SDL3_image | 3.2+, 3.2+, 3.4+ | a partir do código-fonte (passo 2), ainda não estão nos repositórios | `mingw-w64-x86_64-sdl3`, `-sdl3-ttf`, `-sdl3-image` |
| vgui | a mais recente | `git clone` (passo 4) | `git clone` |

O vraw só compila com o gcc (`-cc gcc`).

### Linux

**1. Pacotes do sistema** — compilador, LibRaw, lensfun, libjpeg e as
bibliotecas com que o SDL3 é compilado:

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

No Fedora, Arch e noutras distribuições instale as mesmas bibliotecas
com o respetivo gestor de pacotes. Se ele já tiver SDL3, SDL3_ttf e
SDL3_image 3.4 ou mais recentes (com pacotes `-devel`/`-dev`), salte o
passo 2.

**2. SDL3, SDL3_ttf, SDL3_image** — compiladas a partir do código-fonte
e instaladas em `/usr/local`:

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

**3. Compilador V:**

```bash
git clone https://github.com/vlang/v ~/soft/v
cd ~/soft/v && make
```

**4. vgui e vraw.** O V encontra o módulo `vgui` através de
`~/.vmodules`:

```bash
mkdir -p ~/.vmodules ~/projects
git clone https://github.com/Mintormo/vgui ~/projects/vgui
ln -s ~/projects/vgui ~/.vmodules/vgui
git clone https://github.com/Mintormo/vraw ~/projects/vraw
cd ~/projects/vraw
~/soft/v/v -prod -cc gcc .     # -> ./vraw
./vraw
```

`-prod` ativa as otimizações do gcc: o pipeline fica cerca de 2,5 vezes
mais rápido e a compilação demora cerca de meio minuto. Outros comandos:

```bash
~/soft/v/v -cc gcc test .      # testes
tools/portable.sh              # pasta portátil e arquivo em dist/
```

**5. Perfis de objetivas atualizados (opcional).** A base de dados do
lensfun nos pacotes das distribuições é antiga. O vraw também lê uma
mais recente de `~/.local/share/lensfun/updates/version_1`:

```bash
mkdir -p ~/.local/share/lensfun/updates/version_1
curl -L https://lensfun.github.io/db/version_1.tar.bz2 \
  | tar -xj -C ~/.local/share/lensfun/updates/version_1
```

### Windows

**Compilação cruzada no Linux** — é assim que são feitos os arquivos
das versões. São necessários o V e o vgui dos passos 3–4 para Linux e o
MinGW-w64:

```bash
sudo apt install gcc-mingw-w64-x86-64 zstd
python3 tools/win_deps.py      # SDL3, LibRaw, lensfun e as suas dependências
                               # dos pacotes MSYS2 -> ~/soft/mingw64-vraw
tools/windows.sh               # -> dist/vraw-windows-x86_64.zip
```

O arquivo contém o `vraw.exe`, todas as DLL de que precisa e a base de
dados de objetivas.

**Diretamente no MSYS2 (ainda não testado).** Instale o
[MSYS2](https://www.msys2.org), abra o terminal **MSYS2 MINGW64** e
execute:

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

Para executar o `vraw.exe` fora do terminal do MSYS2, coloque ao lado
dele as DLL necessárias de `C:\msys64\mingw64\bin` (o
`tools/windows.sh` mostra como reuni-las).

### Documentação para programadores

O código está comentado em pormenor. As notas de conceção estão em
russo: [PROJECT.md](PROJECT.md) — módulos e pipeline,
[ROADMAP.md](ROADMAP.md) — o que está feito e o que está planeado,
[REQUIREMENTS.md](REQUIREMENTS.md) — o que o programa faz agora.

## Feito com Claude Code

O vraw foi criado com vibe coding: escrito em conjunto com o
[Claude Code](https://claude.com/claude-code), o assistente de
programação com IA da Anthropic. O programa está escrito em
[V](https://vlang.io) sobre a minha própria biblioteca gráfica [vgui](https://github.com/Mintormo/vgui), com
processamento de tons próprio; o LibRaw faz apenas o demosaico.

## Licença

MIT, ver [LICENSE](LICENSE). O código-fonte está neste repositório. Os
componentes de terceiros incluídos nos arquivos (LibRaw, lensfun, SDL3
e outros) estão sob as suas próprias licenças: ver
`THIRD_PARTY.md` e a pasta `licenses/` dentro do arquivo.
