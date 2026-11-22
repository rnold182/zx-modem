"""Golden files for zx-vvv: what the 8TML reference tool lays out on a ZX.

For every page in apps/zx-vvv/testpages (*.8tml, *.txt) this writes
<name>.zx.txt: the output of `8tml render -m zx --plain`, without the
tool's caption line. The Spectrum's screens, read back as text
(host/tools/zxscreen.py) and put one after another, must match it.

A page with a hand-written <name>.expect.txt is left alone: that is for
behaviour the reference tool doesn't have (forms, which zx-vvv skips until
M8, are drawn by the tool).

Usage: python golden.py [--check]   (--check: run `8tml check` on the pages too)
Needs the spec package in apps/zx-vvv/spec (not in the public repo).
"""
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PAGES = os.path.join(HERE, '..', 'testpages')
TOOL = os.path.join(HERE, '..', 'spec', 'tools', '8tml')


def render(page):
    out = subprocess.run([sys.executable, TOOL, 'render', '-m', 'zx', '--plain', page],
                         capture_output=True, text=True, encoding='utf-8')
    if out.returncode:
        raise SystemExit(f'{page}: {out.stderr}')
    lines = out.stdout.split('\n')[1:]          # the caption
    while lines and lines[-1] == '':
        lines.pop()
    return '\n'.join(lines) + '\n'


def main():
    check = '--check' in sys.argv
    for page in sorted(glob.glob(os.path.join(PAGES, '*.8tml')) + glob.glob(os.path.join(PAGES, '*.txt'))):
        if page.endswith(('.zx.txt', '.expect.txt', '.links.txt')):
            continue
        name = os.path.splitext(page)[0]
        if check and page.endswith('.8tml'):
            r = subprocess.run([sys.executable, TOOL, 'check', page], capture_output=True, text=True)
            print(f'{os.path.basename(page)}: check exit {r.returncode}{" " + r.stdout.strip() if r.returncode else ""}')
        if os.path.exists(name + '.expect.txt'):
            continue
        with open(name + '.zx.txt', 'w', encoding='utf-8', newline='\n') as f:
            f.write(render(page))


if __name__ == '__main__':
    main()
