#!/usr/bin/env bash
# Портабельная сборка vraw для Linux: папка dist/vraw/ и архив
# dist/vraw-linux-x86_64.tar.gz. Распаковал - запустил ./vraw, ставить
# ничего не нужно.
#
#   vraw/vraw          бинарник (-prod), ищет библиотеки в vraw/lib
#   vraw/lib/          копии .so (SDL3, LibRaw, lensfun, ...)
#   vraw/lensfun/      база профилей объективов
#   vraw/licenses/     тексты лицензий, сводка - vraw/THIRD_PARTY.md
#
# Не копируются glibc и библиотеки компилятора (libstdc++, libgcc_s):
# они есть в любой системе, а своя копия ломала бы системные драйверы
# видео и звука, которые SDL подгружает сам. Поэтому папка работает на
# системах с glibc не старее той, где собрана (здесь - 2.39, Ubuntu 24.04).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
v="$HOME/soft/v/v"
dist="$root/dist"
out="$dist/vraw"

rm -rf "$out"
mkdir -p "$out/lib"

# DT_RPATH (а не новый DT_RUNPATH): путь $ORIGIN/lib действует и для
# зависимостей зависимостей (freetype у SDL3_ttf и т.п.)
echo "Сборка..."
"$v" -prod -cc gcc \
	-ldflags '-Wl,-rpath,$ORIGIN/lib -Wl,--disable-new-dtags' \
	-o "$out/vraw" "$root"

# Библиотеки: всё, что показывает ldd, кроме системных; откуда взята
# каждая - в libs.txt (для сбора лицензий)
skip='^(linux-vdso|ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so|libstdc\+\+\.so|libgcc_s\.so)'
libs="$dist/libs.txt"
ldd "$out/vraw" | awk '$2 == "=>" && $3 ~ /^\// { print $1, $3 }' |
	while read -r name path; do
		if [[ ! "$name" =~ $skip ]]; then
			cp -L "$path" "$out/lib/$name"
			echo "$name $path"
		fi
	done >"$libs"

# База lensfun: обновлённая пользовательская (полная), иначе системная
lf="$HOME/.local/share/lensfun/updates/version_1"
[[ -d "$lf" ]] || lf=/usr/share/lensfun/version_1
mkdir -p "$out/lensfun"
cp "$lf"/*.xml "$out/lensfun/"


# --- Лицензии -------------------------------------------------------------
# licenses/ - тексты всех лицензий, THIRD_PARTY.md - сводка: компонент,
# версия, лицензия, где исходники (LGPL требует их доступности - ссылки на
# исходные пакеты Ubuntu именно этих версий). Библиотеки из apt - по
# /usr/share/doc/<пакет>/copyright; собранные вручную и вшитые в бинарник -
# тексты из tools/licenses/.
lic="$out/licenses"
own="$root/tools/licenses"
mkdir -p "$lic/common"
cp "$root/LICENSE" "$out/LICENSE"
# LICENSE - в корне репозитория vgui: модуль - он сам или его подпапка
vgui_dir="$(readlink -f "$HOME/.vmodules/vgui")"
vgui_lic="$vgui_dir/LICENSE"
[[ -f "$vgui_lic" ]] || vgui_lic="$vgui_dir/../../LICENSE"
[[ -f "$vgui_lic" ]] || { echo "Нет лицензии vgui: $vgui_lic"; exit 1; }
cp "$vgui_lic" "$lic/vgui.txt"

# Краткое имя лицензии по исходному пакету Ubuntu
declare -A spdx=(
	[brotli]='MIT' [bzip2]='bzip2 (BSD-like)' [freetype]='FTL (FreeType License)'
	[glib2.0]='LGPL-2.1+' [gcc-14]='GPL-3 with GCC Runtime Library Exception'
	[graphite2]='LGPL-2.1+ / MPL-1.1 / GPL-2+' [harfbuzz]='MIT'
	[libjpeg-turbo]='IJG + BSD-3-Clause + Zlib' [lcms2]='MIT'
	[lensfun]='LGPL-3 (library), CC BY-SA 3.0 (profile database)'
	[pcre2]='BSD-3-Clause' [libpng1.6]='libpng' [libraw]='LGPL-2.1 or CDDL-1.0'
	[zlib]='Zlib'
)
# Собранные вручную (/usr/local): имя .so -> компонент, заголовок,
# префикс макросов версии, репозиторий
declare -A local_lib=(
	[libSDL3.so.0]='SDL3 SDL3/SDL_version.h SDL https://github.com/libsdl-org/SDL'
	[libSDL3_ttf.so.0]='SDL3_ttf SDL3_ttf/SDL_ttf.h SDL_TTF https://github.com/libsdl-org/SDL_ttf'
	[libSDL3_image.so.0]='SDL3_image SDL3_image/SDL_image.h SDL_IMAGE https://github.com/libsdl-org/SDL_image'
)
hver() { # заголовок, префикс макросов -> 3.5.0
	awk -v p="$2" '$1 == "#define" && $2 == p "_MAJOR_VERSION" { a = $3 }
		$1 == "#define" && $2 == p "_MINOR_VERSION" { b = $3 }
		$1 == "#define" && $2 == p "_MICRO_VERSION" { c = $3 }
		END { printf "%s.%s.%s", a, b, c }' "/usr/local/include/$1"
}

tp="$out/THIRD_PARTY.md"
cat >"$tp" <<'END'
# vraw third-party components

vraw and vgui are MIT-licensed (LICENSE and licenses/vgui.txt). Below is
everything else included in this build. Full license texts are in the
licenses/ folder, common ones (GPL, LGPL...) in licenses/common/.

## Libraries (lib/ folder)

Linked dynamically: any of them can be replaced with your own build (as
the LGPL requires). Sources of exactly these versions are linked below.

| File | Component | Version | License | Sources |
|---|---|---|---|---|
END
declare -A seen=()
while read -r name path; do
	if [[ -n "${local_lib[$name]:-}" ]]; then
		read -r comp hdr macro url <<<"${local_lib[$name]}"
		cp "$own/$comp.txt" "$lic/$comp.txt"
		echo "| $name | $comp | $(hver "$hdr" "$macro") | Zlib | $url |" >>"$tp"
		continue
	fi
	# пакет с архитектурой (libjpeg-turbo8:amd64): без неё dpkg-query
	# ответит за все установленные архитектуры сразу
	pkg_arch="$(dpkg -S "$(readlink -f "$path")" 2>/dev/null | head -1 | sed 's/: .*//')"
	[[ -n "$pkg_arch" ]] || { echo "Неизвестно, откуда $path"; exit 1; }
	pkg="${pkg_arch%%:*}"
	src="$(dpkg-query -W -f='${source:Package}' "$pkg_arch")"
	ver="$(dpkg-query -W -f='${source:Version}' "$pkg_arch")"
	[[ -n "${spdx[$src]:-}" ]] || { echo "Нет лицензии для пакета $src - дописать в spdx"; exit 1; }
	if [[ -z "${seen[$src]:-}" ]]; then
		seen[$src]=1
		cp "/usr/share/doc/$pkg/copyright" "$lic/$src.txt"
		# тексты из /usr/share/common-licenses, на которые ссылается copyright
		{ grep -o 'common-licenses/[A-Za-z0-9.-]*[A-Za-z0-9]' "/usr/share/doc/$pkg/copyright" || true; } |
			sort -u | while read -r c; do
				if [[ -f "/usr/share/$c" ]]; then cp "/usr/share/$c" "$lic/common/"; fi
			done
	fi
	echo "| $name | $src | $ver | ${spdx[$src]} | https://launchpad.net/ubuntu/+source/$src/$ver |" >>"$tp"
done <"$libs"
rm "$libs"

# Вшитое в бинарник
for f in V libgc stb Roboto-OFL Lucide-ISC; do
	cp "$own/$f.txt" "$lic/$f.txt"
done
cat >>"$tp" <<'END'

## Built into the vraw binary

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
| lensfun lens profile database (lensfun/ folder) | CC BY-SA 3.0 | licenses/lensfun.txt |

The database is the work of the lensfun project (https://lensfun.github.io),
distributed unmodified.
END

# Проверка: все библиотеки находятся (в lib/ или в системе)
if ldd "$out/vraw" | grep -q 'not found'; then
	ldd "$out/vraw" | grep 'not found'
	exit 1
fi

tar -C "$dist" -czf "$dist/vraw-linux-x86_64.tar.gz" vraw
echo "Готово: $out ($(du -sh "$out" | cut -f1)), архив $(du -sh "$dist/vraw-linux-x86_64.tar.gz" | cut -f1)"
