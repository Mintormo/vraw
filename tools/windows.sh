#!/usr/bin/env bash
# Портабельная сборка vraw для Windows (x64) - кросс-компиляцией на Linux:
# папка dist/vraw-windows/ и архив dist/vraw-windows-x86_64.zip.
# Распаковал - запустил vraw.exe, ставить ничего не нужно.
#
#   vraw-windows/vraw.exe      бинарник (-prod, без окна консоли)
#   vraw-windows/*.dll         SDL3, LibRaw, lensfun и их зависимости -
#                              рядом с exe (Windows ищет DLL сначала там)
#   vraw-windows/lensfun/      база профилей объективов
#   vraw-windows/licenses/     тексты лицензий, сводка - THIRD_PARTY.md
#
# Нужно: MinGW-w64 (apt: gcc-mingw-w64-x86-64) и библиотеки из MSYS2 -
# python3 tools/win_deps.py (кладёт в ~/soft/mingw64-vraw, путь меняет
# переменная VRAW_MINGW). Настройки, models/ и onnxruntime/ программа
# держит рядом с exe, как и на Linux; модель и ONNX Runtime для Windows
# кладёт tools/fetch_ai.sh.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
v="$HOME/soft/v/v"
pfx="${VRAW_MINGW:-$HOME/soft/mingw64-vraw}"
cc=x86_64-w64-mingw32-gcc-posix # OpenMP (libgomp) - с потоками posix
objdump=x86_64-w64-mingw32-objdump
dist="$root/dist"
out="$dist/vraw-windows"
zipf="$dist/vraw-windows-x86_64.zip"

[[ -f "$pfx/dlls.tsv" ]] || { echo "Нет библиотек MSYS2 в $pfx - запустить tools/win_deps.py"; exit 1; }
command -v "$cc" >/dev/null || { echo "Нет $cc - apt install gcc-mingw-w64-x86-64"; exit 1; }

rm -rf "$out" "$zipf"
mkdir -p "$out"

# Нужен V с исправленным трамплином замыканий: исходный портит xmm15, на
# Windows x64 он сохраняемый (vlang/v#29822) - пустое окно, пустое превью
# после кадрирования. Пока не исправлено в upstream - локальная правка
# vlib/builtin/closure/closure.c.v (xmm5 под Windows), проверка ниже.
grep -q 'amd64 && windows' "$HOME/soft/v/vlib/builtin/closure/closure.c.v" ||
	{ echo "V без правки трамплина замыканий (vlang/v#29822) - см. комментарий"; exit 1; }
echo "Сборка..."
"$v" -prod -os windows -cc "$cc" -subsystem windows \
	-cflags "-I$pfx/include" -ldflags "-L$pfx/lib" \
	-o "$out/vraw.exe" "$root"

# DLL: обход зависимостей от vraw.exe; берутся те, что есть в $pfx/bin,
# остальные - системные (KERNEL32, msvcrt...), они есть в любой Windows
declare -A have=()
todo=("$out/vraw.exe")
while ((${#todo[@]})); do
	f="${todo[-1]}"
	unset 'todo[-1]'
	while read -r dll; do
		[[ -n "${have[$dll]:-}" ]] && continue
		[[ -f "$pfx/bin/$dll" ]] || continue
		have[$dll]=1
		cp "$pfx/bin/$dll" "$out/"
		todo+=("$out/$dll")
	done < <("$objdump" -p "$f" | awk '/DLL Name:/ { print $3 }')
done

# База lensfun: обновлённая пользовательская (полная), иначе из пакета
lf="$HOME/.local/share/lensfun/updates/version_1"
[[ -d "$lf" ]] || lf="$pfx/share/lensfun/version_1"
mkdir -p "$out/lensfun"
cp "$lf"/*.xml "$out/lensfun/"

# AI-шумодав: модель и ONNX Runtime для Windows
"$root/tools/fetch_ai.sh" "$out" windows
rm -f "$out/onnxruntime/.version"


# --- Лицензии -------------------------------------------------------------
# licenses/ - тексты лицензий, THIRD_PARTY.md - сводка. DLL - из пакетов
# MSYS2: лицензия - из описания пакета, тексты - share/licenses/<пакет>,
# исходники именно этих версий - в архиве исходных пакетов MSYS2.
lic="$out/licenses"
own="$root/tools/licenses"
mkdir -p "$lic"
cp "$root/LICENSE" "$out/LICENSE"
# LICENSE - в корне репозитория vgui: модуль - он сам или его подпапка
vgui_dir="$(readlink -f "$HOME/.vmodules/vgui")"
vgui_lic="$vgui_dir/LICENSE"
[[ -f "$vgui_lic" ]] || vgui_lic="$vgui_dir/../../LICENSE"
[[ -f "$vgui_lic" ]] || { echo "Нет лицензии vgui: $vgui_lic"; exit 1; }
cp "$vgui_lic" "$lic/vgui.txt"

tp="$out/THIRD_PARTY.md"
cat >"$tp" <<'END'
# vraw third-party components

vraw and vgui are MIT-licensed (LICENSE and licenses/vgui.txt). Below is
everything else included in this build. Full license texts are in the
licenses/ folder.

## Libraries (DLLs next to vraw.exe)

Prebuilt by the MSYS2 project (https://www.msys2.org, mingw64 packages).
Linked dynamically: any of them can be replaced with your own build (as
the LGPL requires). Sources of exactly these versions are linked below.

| File | Component | Version | License | Sources |
|---|---|---|---|---|
END
declare -A seen=()
for dll in $(printf '%s\n' "${!have[@]}" | sort -f); do
	pkg="$(awk -F'\t' -v d="$dll" '$1 == d { print $2 }' "$pfx/dlls.tsv")"
	IFS=$'\t' read -r _ ver license base < <(awk -F'\t' -v p="$pkg" '$1 == p' "$pfx/packages.tsv")
	src="${base#mingw-w64-}"
	echo "| $dll | $pkg | $ver | ${license#spdx:} | https://repo.msys2.org/mingw/sources/$base-$ver.src.tar.zst |" >>"$tp"
	if [[ -z "${seen[$pkg]:-}" ]]; then
		seen[$pkg]=1
		# папка лицензий пакета: имя пакета без учёта регистра и с «_»
		# вместо «-» (SDL3_image у sdl3-image)
		d="$(find "$pfx/share/licenses" -maxdepth 1 \( -iname "$pkg" -o -iname "${pkg//-/_}" \) | head -1)"
		[[ -n "$d" ]] || d="$(find "$pfx/share/licenses" -maxdepth 1 -iname "$src" | head -1)"
		[[ -n "$d" ]] || { echo "Нет текста лицензии пакета $pkg"; exit 1; }
		mkdir -p "$lic/$pkg"
		cp -r "$d"/. "$lic/$pkg/"
	fi
done

for f in V libgc stb Roboto-OFL Lucide-ISC SCUNet; do
	cp "$own/$f.txt" "$lic/$f.txt"
done
cat >>"$tp" <<'END'

## Built into vraw.exe

| Component | License | Text |
|---|---|---|
| vgui (GUI library) | MIT | licenses/vgui.txt |
| V standard library | MIT | licenses/V.txt |
| Boehm GC (V garbage collector) | Boehm GC license (MIT-like) | licenses/libgc.txt |
| stb_image, stb_image_write, stb_image_resize2 | MIT / public domain | licenses/stb.txt |
| Roboto font | SIL Open Font License 1.1 | licenses/Roboto-OFL.txt |
| Lucide icons | ISC | licenses/Lucide-ISC.txt |

## Data

| Component | License | Text |
|---|---|---|
| lensfun lens profile database (lensfun/ folder) | CC BY-SA 3.0 | licenses/lensfun/ |

The database is the work of the lensfun project (https://lensfun.github.io),
distributed unmodified.

## AI denoise

| Component | License | Text |
|---|---|---|
| ONNX Runtime (onnxruntime/ folder) | MIT | onnxruntime/LICENSE, onnxruntime/ThirdPartyNotices.txt |
| SCUNet model, real PSNR weights (models/ folder) | Apache-2.0 | licenses/SCUNet.txt, licenses/Apache-2.0.txt |

SCUNet is the work of Kai Zhang, Yawei Li, Jingyun Liang, Jiezhang Cao,
Yulun Zhang, Hao Tang, Deng-Ping Fan, Radu Timofte and Luc Van Gool
(https://github.com/cszn/SCUNet). The weights are distributed in ONNX
format, converted from the original PyTorch weights by Heliosoph
(https://huggingface.co/Heliosoph/scunet-onnx), otherwise unmodified.

ONNX Runtime for Windows needs the Microsoft Visual C++ Redistributable
(x64). Most computers already have it; if not, vraw says where to get it
when AI denoise is turned on.
END
# Apache-2.0 (SCUNet) - общий текст
cp /usr/share/common-licenses/Apache-2.0 "$lic/Apache-2.0.txt"

(cd "$dist" && zip -qr "$zipf" vraw-windows)
echo "Готово: $out ($(du -sh "$out" | cut -f1), DLL: ${#have[@]}), архив $(du -sh "$zipf" | cut -f1)"
