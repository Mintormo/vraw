#!/usr/bin/env python3
"""Проверка переводов интерфейса vraw (модуль i18n/).

Ключи перевода - русские строки из кода:
  - аргументы i18n.tr / trf / pl / tr_in; у trc - «контекст::строка»;
  - русские строки в константах (названия пунктов: переводятся там, где
    показываются - i18n.tr(wb_names[i]), i18n.tr_all(...)).

  tools/i18n_check.py            сводка: сколько ключей, чего нет в каждом языке
  tools/i18n_check.py --keys     все ключи JSON-списком (для перевода)
  tools/i18n_check.py --missing de   ключи, которых нет в lang/de.json

Код возврата 1 - где-то не хватает переводов или есть лишние.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANG_DIR = os.path.join(ROOT, 'i18n', 'lang')
CYR = re.compile('[А-Яа-яЁё]')
# Русские строки в константах, которые не текст интерфейса
NOT_UI = {
    'ГГГГ:ММ:ДД чч:мм:сс',
}


def unescape(body):
    """Тело литерала V -> строка, как её видит программа."""
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c == '\\' and i + 1 < len(body):
            n = body[i + 1]
            out.append({'n': '\n', 't': '\t', '\\': '\\', "'": "'", '"': '"', '$': '$'}.get(n, '\\' + n))
            i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def literals(line):
    """[(начало, конец, тело)] строковых литералов вне // комментариев."""
    res = []
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == '/' and line[i:i + 2] == '//':
            break
        if c == '`':
            j = line.find('`', i + 1)
            i = j + 1 if j > 0 else n
            continue
        if c in '\'"':
            j = i + 1
            while j < n and line[j] != c:
                if line[j] == '\\':
                    j += 1
                elif line[j] == '$' and line[j + 1:j + 2] == '{':
                    depth = 1
                    j += 2
                    while j < n and depth:
                        if line[j] == '{':
                            depth += 1
                        elif line[j] == '}':
                            depth -= 1
                        j += 1
                    continue
                j += 1
            res.append((i, j + 1, line[i + 1:j]))
            i = j + 1
            continue
        i += 1
    return res


# Первый строковый аргумент вызова: i18n.tr('..'), trf('..', ...),
# pl(n, '..'), tr_in(code, '..') - в том числе внутри ${...} других строк
STR = r"'((?:[^'\\]|\\.)*)'"
TRC = re.compile(r'i18n\.trc\(\s*' + STR + r',\s*' + STR)
CALLS = [
    re.compile(r'i18n\.(?:tr|trf)\(\s*' + STR),
    re.compile(r'i18n\.(?:pl|tr_in)\([^,()]*(?:\([^()]*\))?[^,()]*,\s*' + STR),
]


def code_part(line):
    """Строка без // комментария (// внутри строк не считается)."""
    lits = literals(line)
    end = len(line)
    i = 0
    for s, e, _ in lits + [(len(line), len(line), '')]:
        k = line.find('//', i, s)
        if k >= 0:
            return line[:k]
        i = e
    return line[:end]


def keys_from_file(path):
    keys = set()
    lines = open(path, encoding='utf-8').read().split('\n')
    const_depth = 0
    in_const_block = False
    for line in lines:
        stripped = line.strip()
        code = code_part(line)
        if stripped.startswith('const ('):
            in_const_block = True
        starts = re.match(r'^\s*(pub\s+)?const\s', line) is not None
        is_const = in_const_block or starts or const_depth > 0
        if starts or const_depth > 0:
            const_depth = max(0, const_depth + sum(code.count(c) for c in '[{(') - sum(code.count(c) for c in ']})'))
        if in_const_block and stripped == ')':
            in_const_block = False
        found = []
        for rx in CALLS:
            found += rx.findall(code)
        if is_const:
            found += [body for _, _, body in literals(code)]
        # омонимы: ключ «контекст::строка»
        found += [c + '::' + t for c, t in TRC.findall(code)]
        for body in found:
            if not CYR.search(body) or '${' in body:
                continue
            text = unescape(body)
            if text not in NOT_UI:
                keys.add(text)
    return keys


def all_keys():
    keys = set()
    for path in glob.glob(os.path.join(ROOT, '**', '*.v'), recursive=True):
        rel = os.path.relpath(path, ROOT)
        # i18n/ - сам модуль: самоназвания языков не переводятся
        if rel.endswith('_test.v') or rel.startswith(('dist', 'tools', 'i18n')):
            continue
        keys |= keys_from_file(path)
    return keys


def load(code):
    path = os.path.join(LANG_DIR, code + '.json')
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def main():
    keys = all_keys()
    args = sys.argv[1:]
    if args[:1] == ['--keys']:
        print(json.dumps(sorted(keys), ensure_ascii=False, indent=1))
        return 0
    if args[:1] == ['--missing']:
        t = load(args[1])
        print(json.dumps(sorted(k for k in keys if not t.get(k)), ensure_ascii=False, indent=1))
        return 0
    bad = 0
    print('ключей в коде: %d' % len(keys))
    for path in sorted(glob.glob(os.path.join(LANG_DIR, '*.json'))):
        code = os.path.basename(path)[:-5]
        t = load(code)
        missing = [k for k in keys if not t.get(k)]
        extra = [k for k in t if k not in keys]
        # подстановки {0}.. и формы числа должны совпадать с ключом
        broken = []
        for k, v in t.items():
            if k not in keys or not v:
                continue
            if sorted(re.findall(r'\{\d\}', k)) != sorted(re.findall(r'\{\d\}', v)):
                broken.append(k)
        state = 'ok' if not (missing or extra or broken) else ''
        print('%-3s нет %4d  лишних %3d  с ошибкой подстановок %3d  %s' % (code, len(missing), len(extra), len(broken), state))
        for k in broken[:5]:
            print('      подстановки: %r -> %r' % (k, t[k]))
        if missing or extra or broken:
            bad = 1
    return bad


if __name__ == '__main__':
    sys.exit(main())
