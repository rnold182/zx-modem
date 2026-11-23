r"""Differential test: zx-vvv's layout against the 8TML reference tool (M6).

Makes random but valid 8TML pages (every block type, inline markup, links,
escapes, odd spacing), keeps those the reference checker accepts, and lays
each one out twice:
  - the reference: tools/8tml render -m zx --plain (from apps/zx-vvv/spec);
  - zx-vvv's own Z80 code: zxfuzz render, which runs the browser in an
    emulated 48K and dumps every screen; the text is read back from screen
    memory against the ROM font (the bold and italic glyphs too).
The rows must be the same, screen after screen. A page that differs is kept
in OUT_DIR with both layouts.

    python difftest.py COUNT SEED OUT_DIR [--build build]

Forms are left out (zx-vvv shows them from M8 on), so are pages longer than
the browser's 64 screens and source lines over 255 characters (zx-vvv cuts
them, which the spec allows).
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'host', 'tools'))
import zxscreen  # noqa: E402

SPEC = os.path.join(ROOT, 'apps', 'zx-vvv', 'spec')
TOOL = os.path.join(SPEC, 'tools', '8tml')

WORDS = ('the spectrum has rubber keys and a beeper loads from tape zx 48k '
         'basic print colour attribute border ink paper sinclair 1982 a an of to '
         'extraordinarilylongwordthatneedsbreaking x y z 12345 3.5MHz').split()
COLOURS = ('red', 'cyan', 'yellow', 'lightblue', 'grey', 'magenta', 'lightgreen', 'orange')


def word(r):
    w = r.choice(WORDS)
    if r.random() < 0.1:
        w = w.capitalize()
    return w


def inline(r, n):
    """n words of text with inline markup now and then."""
    out = []
    for _ in range(n):
        x = r.random()
        if x < 0.06:
            out.append('*' + word(r) + '*')
        elif x < 0.1:
            out.append('**' + word(r) + ' ' + word(r) + '**')
        elif x < 0.14:
            out.append(f'<{r.choice(COLOURS)}>{word(r)}</>')
        elif x < 0.16:
            out.append(f'<{r.choice(("b", "i", "rev"))}>{word(r)}</{r.choice(("b", "i", "rev", ""))}>')
        elif x < 0.22:
            text = ' '.join(word(r) for _ in range(r.randint(0, 3)))
            out.append(f'[{text}]({r.choice(("a.8tml", "/x/", "../up.8tml", "#top", "http://h.example/", "mailto:x@y"))})')
        elif x < 0.25:
            out.append(r.choice(('&lt;', '&gt;', '&amp;', '&quot;', '&#65;', '&#200;', '\\*', '\\[', '5 * 3',
                                 '<3', 'a < b', '&nbsp;', 'x&nbsp;y', '&bogus;', '_x_', '`code`')))
        elif x < 0.27:
            out.append('<br>')
        elif x < 0.29:
            out.append(word(r) + '  ' + word(r))     # runs of spaces are kept
        else:
            out.append(word(r))
    return ' '.join(out)


def block(r, state):
    x = r.random()
    if x < 0.08:
        return '#' * r.randint(1, 4) + ' ' + ('<center>' if r.random() < 0.2 else '') + inline(r, r.randint(1, 8))
    if x < 0.2:
        marker = r.choice(('* ', '- '))
        lines = [marker + inline(r, r.randint(1, 15)) for _ in range(r.randint(1, 4))]
        if r.random() < 0.3:
            lines.insert(1, '  ' + inline(r, r.randint(1, 6)))   # a continuation line
        return '\n'.join(lines)
    if x < 0.28:
        n = r.choice((1, 1, 5, 99, 1984))
        lines = []
        for _ in range(r.randint(1, 5)):
            lines.append(f'{n}. ' + inline(r, r.randint(1, 10)))
            n = r.choice((n + 1, n, 1, n + 3))
        return '\n'.join(lines)
    if x < 0.36:
        return '\n'.join('> ' + inline(r, r.randint(1, 12)) for _ in range(r.randint(1, 3)))
    if x < 0.43:
        body = []
        for _ in range(r.randint(0, 5)):
            body.append(' ' * r.randint(0, 4) + ' '.join(word(r) for _ in range(r.randint(0, 9))))
        return '```' + r.choice(('', 'basic', ' x')) + '\n' + '\n'.join(body) + '\n```'
    if x < 0.47:
        return '---'
    if x < 0.5:
        return ':::petscii\nSKIPPED <red>text</>\n:::'
    lines = []
    for _ in range(r.randint(1, 4)):
        line = inline(r, r.randint(1, 14))
        if r.random() < 0.1:
            line += '\\'
        lines.append(line)
    text = '\n'.join(lines)
    if r.random() < 0.1:
        text = '<center>' + text
    return text


def make_page(r):
    head = ['---', '8tml: 1']
    if r.random() < 0.8:
        head.append('title: ' + inline(r, r.randint(1, 4)).replace('<br>', ''))
    if r.random() < 0.5:
        head.append('case: ' + r.choice(('mixed', 'upper', 'Mixed')))
    if r.random() < 0.2:
        head.append('# a comment')
    head.append('---')
    blocks = [block(r, None) for _ in range(r.randint(1, 25))]
    sep = []
    for b in blocks:
        sep.append(b)
        sep.append('\n' * r.choice((1, 2, 2, 3)))
    return '\n'.join(head) + '\n' + ''.join(sep)


def reference(path):
    """The reference layout's rows, or None if the checker finds errors."""
    chk = subprocess.run([sys.executable, TOOL, 'check', path], capture_output=True, text=True, cwd=SPEC)
    if chk.returncode:
        return None
    out = subprocess.run([sys.executable, TOOL, 'render', '-m', 'zx', '--plain', path],
                         capture_output=True, text=True, cwd=SPEC, encoding='utf-8')
    rows = out.stdout.split('\n')[1:]                 # the first line is the tool's caption
    while rows and rows[-1] == '':
        rows.pop()
    return rows


def cell_text(scr, row, col, font):
    third, line_in = row // 8, row % 8
    rows = []
    for y in range(8):
        rows.append(scr[(third << 11) | (y << 8) | (line_in << 5) | col])
    if all(b == rows[0] for b in rows) and rows[0] in (0, 0xFF):
        return ' '
    for bits in (tuple(rows), tuple(b ^ 0xFF for b in rows)):
        if bits in font:
            return zxscreen.SHOW.get(font[bits][0], chr(font[bits][0]))
    return '�'


def zx_rows(page_path, build, font):
    scr = os.path.splitext(page_path)[0] + '.scr'
    out = subprocess.run([os.path.join(build, 'host', 'zxfuzz'), '--build', build, 'render', page_path, scr],
                         capture_output=True, text=True)
    if out.returncode:
        return None, out.stdout + out.stderr
    data = open(scr, 'rb').read()
    rows = []
    for s in range(len(data) // 6912):
        screen = data[s * 6912:(s + 1) * 6912]
        for row in range(1, 23):
            rows.append(''.join(cell_text(screen, row, c, font) for c in range(32)).rstrip())
    while rows and rows[-1] == '':
        rows.pop()
    os.remove(scr)
    return rows, None


def main(argv):
    if len(argv) < 4:
        raise SystemExit(__doc__)
    count, seed, out_dir = int(argv[1]), int(argv[2]), os.path.abspath(argv[3])
    build = argv[argv.index('--build') + 1] if '--build' in argv else os.path.join(ROOT, 'build')
    os.makedirs(out_dir, exist_ok=True)
    font = zxscreen.load_font(zxscreen.DEFAULT_ROM)
    r = random.Random(seed)
    checked = differ = skipped = 0
    for i in range(count):
        page = make_page(r)
        if any(len(line) > 255 for line in page.split('\n')):
            skipped += 1                              # zx-vvv cuts these (spec 2: MAY)
            continue
        path = os.path.join(out_dir, f'p{seed}-{i}.8tml')
        with open(path, 'w', newline='\n') as f:
            f.write(page)
        want = reference(path)
        if want is None or len(want) > 64 * 22:
            skipped += 1
            os.remove(path)
            continue
        got, err = zx_rows(path, build, font)
        checked += 1
        if got == want:
            os.remove(path)
            continue
        differ += 1
        with open(path + '.diff.txt', 'w', encoding='utf-8') as f:
            if err:
                f.write(err)
            else:
                for n in range(max(len(got), len(want))):
                    g = got[n] if n < len(got) else '<none>'
                    w = want[n] if n < len(want) else '<none>'
                    f.write(f'{"  " if g == w else "!!"} {n + 1:4} want |{w}|\n{"  " if g == w else "!!"}      got  |{g}|\n')
        print(f'DIFFERENT: {path}')
    print(f'{checked} pages compared, {differ} different, {skipped} skipped (checker errors or too long)')
    return 1 if differ else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
