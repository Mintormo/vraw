#!/usr/bin/env bash
# Файлы AI-шумодава для vraw: модель SCUNet и ONNX Runtime - в папку
# рядом с бинарником (vraw ищет их там: models/ и onnxruntime/).
#
#   tools/fetch_ai.sh [папка] [linux|windows]
#
# Папка по умолчанию - корень проекта (для ./vraw и тестов ai/), система -
# linux. Скачанное проверяется по sha256 и хранится в ~/.cache/vraw-ai/:
# повторный запуск ничего не качает. Уже лежащие на месте файлы нужного
# размера не трогаются.
#
# Лицензии: SCUNet (cszn/SCUNet, Kai Zhang et al.) - Apache-2.0, ONNX-перевод
# весов - Heliosoph/scunet-onnx (та же лицензия); ONNX Runtime - MIT
# (LICENSE и ThirdPartyNotices.txt - в архиве, распаковываются с ним).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="${1:-$root}"
os="${2:-linux}"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/vraw-ai"
mkdir -p "$cache" "$dest/models"

ort_ver="$(grep -oP "runtime_version = '\K[^']+" "$root/ai/catalog.v")"
hf='https://huggingface.co/Heliosoph/scunet-onnx/resolve/main'
gh="https://github.com/microsoft/onnxruntime/releases/download/v$ort_ver"

# get URL ФАЙЛ SHA256 - скачать в кэш (если там нет целого) и проверить
get() {
	local url="$1" f="$cache/$2" sum="$3"
	if [[ -f "$f" ]] && echo "$sum  $f" | sha256sum -c --status; then
		return
	fi
	echo "Скачивание $2..."
	curl -fsSL --retry 5 -C - -o "$f.part" "$url"
	if ! echo "$sum  $f.part" | sha256sum -c --status; then
		rm -f "$f.part"
		echo "Не сошлась sha256: $2" >&2
		exit 1
	fi
	mv "$f.part" "$f"
}

# Модель: граф и веса (имена и размеры - как в ai/catalog.v)
model=(
	'scunet_color_real_psnr.onnx 231be201ab413dbc999d7951caa9844846b93a12a40a41e037d6b5888ed4e88c'
	'scunet_color_real_psnr.onnx.data 98825ea1210b641c71e5f052f582c70c49fd44b35387ebe2c034268c17df3feb'
)
for m in "${model[@]}"; do
	read -r name sum <<<"$m"
	get "$hf/$name" "$name" "$sum"
	cmp -s "$cache/$name" "$dest/models/$name" || cp "$cache/$name" "$dest/models/$name"
done

# ONNX Runtime: содержимое архива без верхней папки (lib/, лицензии), без
# заголовков и отладочных символов (.pdb в zip для Windows - 400 МБ)
if [[ "$os" == windows ]]; then
	arc="onnxruntime-win-x64-$ort_ver.zip"
	sum='c6ba983baf5681af108599675d2a89c2d145512d02de28aed0bff177cd0ba949'
	lib='lib/onnxruntime.dll'
else
	arc="onnxruntime-linux-x64-$ort_ver.tgz"
	sum='a5ed5a3cac51fbb2e90da632ae43d19212faaa20e76484e62bcb7c23ddb3b3fd'
	lib='lib/libonnxruntime.so.1'
fi
get "$gh/$arc" "$arc" "$sum"
stamp="$dest/onnxruntime/.version"
if [[ ! -f "$dest/onnxruntime/$lib" || "$(cat "$stamp" 2>/dev/null)" != "$arc" ]]; then
	tmp="$(mktemp -d)"
	if [[ "$os" == windows ]]; then
		unzip -q "$cache/$arc" -d "$tmp/x" -x '*.pdb' '*.lib' '*/include/*'
	else
		mkdir -p "$tmp/x/o"
		tar -xzf "$cache/$arc" -C "$tmp/x/o" --strip-components=1 --exclude='*/include'
	fi
	rm -rf "$dest/onnxruntime"
	mkdir -p "$dest/onnxruntime"
	cp -r "$tmp"/x/*/. "$dest/onnxruntime/"
	rm -rf "$tmp"
	echo "$arc" >"$stamp"
fi
echo "AI-шумодав: $dest/models, $dest/onnxruntime"
