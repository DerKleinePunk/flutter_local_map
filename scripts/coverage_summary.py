#!/usr/bin/env python3
"""Fasst lcov.info-Dateien als Markdown zusammen (fuer $GITHUB_STEP_SUMMARY).

Aufruf: coverage_summary.py NAME=PFAD [NAME=PFAD ...]

Gezaehlt werden nur Dateien, die ein Test geladen hat; eine Datei ohne
jeden Test fehlt in der Summe.
"""
import os
import sys


def read(path):
    rows, cur, lf = [], None, 0
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line.startswith('SF:'):
                cur = line[3:]
            elif line.startswith('LF:'):
                lf = int(line[3:])
            elif line.startswith('LH:'):
                rows.append((cur, lf, int(line[3:])))
    return rows


def pct(hit, total):
    return f'{100 * hit / total:.1f} %' if total else '–'


def main(args):
    print('## Testabdeckung (Zeilen)\n')
    print('| Teil | Zeilen | Abdeckung |')
    print('|---|---:|---:|')
    details = []
    for arg in args:
        name, path = arg.split('=', 1)
        if not os.path.exists(path):
            print(f'| {name} | – | kein Bericht |')
            continue
        rows = read(path)
        total = sum(r[1] for r in rows)
        hit = sum(r[2] for r in rows)
        print(f'| {name} | {hit} / {total} | **{pct(hit, total)}** |')
        details.append((name, rows))
    for name, rows in details:
        print(f'\n<details><summary>{name}: Dateien nach fehlenden Zeilen</summary>\n')
        print('| Datei | Zeilen | Abdeckung |')
        print('|---|---:|---:|')
        for src, total, hit in sorted(rows, key=lambda r: r[2] - r[1]):
            short = src.split('lib/', 1)[-1]
            print(f'| `{short}` | {hit} / {total} | {pct(hit, total)} |')
        print('\n</details>')


if __name__ == '__main__':
    main(sys.argv[1:])
