#!/usr/bin/env python3
"""Библиотеки для сборки vraw под Windows: готовые пакеты MSYS2 (mingw64).

Скачивает SDL3, SDL3_ttf, SDL3_image, LibRaw, lensfun и все их
зависимости из репозитория MSYS2, сверяет SHA-256 и распаковывает в
префикс (по умолчанию ~/soft/mingw64-vraw): заголовки - include/,
библиотеки импорта - lib/, DLL - bin/. Сборка - tools/windows.sh.

    python3 tools/win_deps.py [префикс]

Повторный запуск докачивает только новое (кэш - префикс/cache/).
Пакеты mingw64 собраны с msvcrt, как и MinGW из Ubuntu
(x86_64-w64-mingw32-gcc), - библиотеки совместимы.
"""
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request

REPO = 'https://repo.msys2.org/mingw/mingw64'
PREFIX = 'mingw-w64-x86_64-'
ROOTS = ['sdl3', 'sdl3-ttf', 'sdl3-image', 'libraw', 'lensfun']
# Не нужны для работы библиотек: утилиты сборки и интерпретаторы, которые
# пакеты тянут ради своих скриптов (glib - python для gdbus-codegen)
SKIP = {'python', 'python-packaging', 'pkgconf', 'tzdata', 'gettext-tools'}


def fetch(url):
    with urllib.request.urlopen(url) as r:
        return r.read()


def unzstd(data):
    return subprocess.run(['zstd', '-dc'], input=data, capture_output=True, check=True).stdout


def read_db(cache):
    """Пакеты репозитория: имя -> {'file', 'sha', 'deps', 'provides'}"""
    path = os.path.join(cache, 'mingw64.db')
    if not os.path.exists(path) or '--refresh' in sys.argv:
        with open(path, 'wb') as f:
            f.write(fetch(f'{REPO}/mingw64.db'))
    with open(path, 'rb') as f:
        raw = f.read()
    if raw[:4] == b'\x28\xb5\x2f\xfd':  # база сжата zstd
        raw = unzstd(raw)
    pkgs = {}
    with tarfile.open(fileobj=io.BytesIO(raw)) as tar:
        for m in tar:
            if not m.name.endswith('/desc'):
                continue
            fields, key = {}, None
            for line in tar.extractfile(m).read().decode().splitlines():
                if line.startswith('%') and line.endswith('%'):
                    key = line.strip('%')
                    fields[key] = []
                elif line and key:
                    fields[key].append(line)
            name = fields['NAME'][0]
            pkgs[name] = {
                'file': fields['FILENAME'][0],
                'base': fields['BASE'][0],
                'version': fields['VERSION'][0],
                'license': ' '.join(fields.get('LICENSE', [])),
                'sha': fields['SHA256SUM'][0],
                'deps': fields.get('DEPENDS', []),
                'provides': fields.get('PROVIDES', []),
            }
    return pkgs


def resolve(pkgs):
    """Корни и все их зависимости (имена пакетов)"""
    provided = {}
    for name, p in pkgs.items():
        for pr in p['provides']:
            provided[re.split('[<>=]', pr)[0]] = name
    need, todo = [], [PREFIX + r for r in ROOTS]
    while todo:
        dep = re.split('[<>=]', todo.pop())[0]
        name = dep if dep in pkgs else provided.get(dep)
        if name is None:
            sys.exit(f'Нет пакета {dep}')
        if name in need or name[len(PREFIX):] in SKIP:
            continue
        need.append(name)
        todo += pkgs[name]['deps']
    return sorted(need)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    prefix = os.path.abspath(args[0] if args else os.path.expanduser('~/soft/mingw64-vraw'))
    cache = os.path.join(prefix, 'cache')
    os.makedirs(cache, exist_ok=True)
    pkgs = read_db(cache)
    need = resolve(pkgs)
    print(f'Пакетов: {len(need)}')
    for name in need:
        p = pkgs[name]
        file = os.path.join(cache, p['file'])
        if not os.path.exists(file):
            print('  скачиваю', p['file'])
            data = fetch(f"{REPO}/{p['file']}")
            if hashlib.sha256(data).hexdigest() != p['sha']:
                sys.exit(f"Не совпала SHA-256: {p['file']}")
            with open(file, 'wb') as f:
                f.write(data)
    # Распаковка начисто: в префиксе - ровно эти версии
    for d in ('bin', 'include', 'lib', 'share'):
        shutil.rmtree(os.path.join(prefix, d), ignore_errors=True)
    # dlls.tsv - DLL и её пакет (для лицензий портабельной сборки),
    # packages.tsv - пакет, версия, лицензия, исходный пакет
    dlls = []
    for name in need:
        with open(os.path.join(cache, pkgs[name]['file']), 'rb') as f:
            data = unzstd(f.read())
        with tarfile.open(fileobj=io.BytesIO(data)) as tar:
            for m in tar:
                if not m.name.startswith('mingw64/') or not (m.isfile() or m.issym() or m.isdir()):
                    continue
                m.name = m.name[len('mingw64/'):]
                tar.extract(m, prefix, filter='data')
                if m.name.startswith('bin/') and m.name.endswith('.dll'):
                    dlls.append((m.name[4:], name[len(PREFIX):]))
    with open(os.path.join(prefix, 'dlls.tsv'), 'w') as f:
        for dll, name in sorted(dlls):
            f.write(f'{dll}\t{name}\n')
    with open(os.path.join(prefix, 'packages.tsv'), 'w') as f:
        for name in need:
            p = pkgs[name]
            f.write(f"{name[len(PREFIX):]}\t{p['version']}\t{p['license']}\t{p['base']}\n")
    print('Готово:', prefix)


if __name__ == '__main__':
    main()
