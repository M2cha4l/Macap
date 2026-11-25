#!/usr/bin/env python3
"""Lists every tr("zh", "en") string in main.swift and checks Resources/*.lproj/Localizable.strings against them.

  tools/i18n_check.py --export keys.json   write [{"en", "zh"}] for translators
  tools/i18n_check.py                      exit 1 if a language misses a key, has a stale key, or changes placeholders
"""
import json, re, subprocess, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIT = r'"((?:[^"\\]|\\.)*)"'
CALL = re.compile(r'\btr\(\s*' + LIT + r'\s*,\s*' + LIT)
PH = re.compile(r'%(?:\d+\$)?[@dfs]|%\.\d+f')

def unescape(s):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s)

def keys():
    src = (ROOT / 'main.swift').read_text(encoding='utf-8')
    out = {}
    for zh, en in CALL.findall(src):
        out.setdefault(unescape(en), unescape(zh))
    return out

def table(path):
    raw = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], capture_output=True, check=True).stdout
    return json.loads(raw)

def placeholders(s):
    return sorted(re.sub(r'\d+\$', '', p) for p in PH.findall(s))

if __name__ == '__main__':
    k = keys()
    if len(sys.argv) == 3 and sys.argv[1] == '--export':
        pathlib.Path(sys.argv[2]).write_text(json.dumps([{'en': e, 'zh': z} for e, z in k.items()], ensure_ascii=False, indent=1), encoding='utf-8')
        print(f'{len(k)} strings')
        sys.exit(0)
    bad = 0
    for f in sorted(ROOT.glob('Resources/*.lproj/Localizable.strings')):
        if f.parent.name in ('en.lproj', 'zh-Hans.lproj'):   # these texts live in main.swift
            continue
        t = table(f)
        missing = [e for e in k if e not in t]
        stale = [e for e in t if e not in k]
        wrong = [e for e in k if e in t and placeholders(e) != placeholders(t[e])]
        lang = f.parent.name.split('.')[0]
        print(f'{lang}: {len(t)} strings, missing {len(missing)}, stale {len(stale)}, placeholder mismatch {len(wrong)}')
        for e in (missing + stale + wrong)[:5]: print('   ', repr(e))
        bad += len(missing) + len(stale) + len(wrong)
    sys.exit(1 if bad else 0)
