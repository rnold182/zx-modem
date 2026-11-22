"""Read a Spectrum screen back as text, from an emulator screenshot.

Every 8x8 cell is matched against the 48K ROM font (both ways round, so
the colours and reverse video don't matter), and against the bold and
italic glyphs zx-vvv makes from it; cells that are one colour are spaces.
That turns a screenshot into exactly the characters the program drew, for
comparing with the 8TML reference tool's layout. Each cell's ink, paper
and BRIGHT come from the pixel colours (Fuse: 192 normal, 255 bright).

The screenshot is the 640x480 crop host tests take from Fuse (2x scale with
the border): cell (row, col) starts at pixel (64 + 16*col, 49 + 16*row).

    python zxscreen.py shot.png [--rom 48.rom]          # prints 24 rows
    python zxscreen.py --compare golden.zx.txt s1.png s2.png ...
        compares rows 1-22 of each screen, one after another, with the
        golden file (trailing blank lines ignored); exit 1 on a difference.
    python zxscreen.py --compare-style page.style.json s1.png ...
        the same for every cell's character, ink, paper, BRIGHT, bold and
        italic (golden_style.py writes the expected cells).
    python zxscreen.py --compare-links page.links.txt list.png
        the L screen's rows against the page's link addresses.
"""
import json
import os
import sys

from PIL import Image

ORIGIN_X, ORIGIN_Y, CELL = 64, 49, 16
DEFAULT_ROM = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Programs', 'fuse', 'roms', '48.rom')
SHOW = {0x60: '£', 0x7F: '©'}          # how the reference tool writes these ZX glyphs
LIST_TOP, LIST_ROWS = 2, 20             # zx-vvv's link list


def bold(rows):
    return [r | (r >> 1) for r in rows]


def italic(rows):
    return [r >> 1 if i < 4 else r for i, r in enumerate(rows)]


def load_font(rom):
    """Glyph rows -> (code, bold, italic); plain glyphs win over look-alikes."""
    data = open(rom, 'rb').read()
    font = {}
    for b, i in ((False, False), (True, False), (False, True), (True, True)):
        for code in range(32, 128):
            rows = list(data[0x3D00 + (code - 32) * 8:0x3D00 + (code - 32) * 8 + 8])
            if b:
                rows = bold(rows)
            if i:
                rows = italic(rows)
            font.setdefault(tuple(rows), (code, b, i))
    return font


def zx_colour(rgb):
    """Fuse RGB -> (colour 0-7, bright)."""
    r, g, b = rgb
    return (1 if b else 0) + (2 if r else 0) + (4 if g else 0), int(255 in rgb)


def read_cell_full(px, row, col, font):
    """(character, ink, paper, bright, bold, italic); ink None for a blank cell."""
    x0, y0 = ORIGIN_X + col * CELL, ORIGIN_Y + row * CELL
    pix = [[px[x0 + 2 * i, y0 + 2 * j] for i in range(8)] for j in range(8)]
    colours = {p for line in pix for p in line}
    if len(colours) == 1:
        paper, bright = zx_colour(pix[0][0])
        return [' ', None, paper, bright, False, False]
    for ink in colours:
        bits = tuple(sum(0x80 >> i for i in range(8) if line[i] == ink) for line in pix)
        if bits in font:
            code, b, i = font[bits]
            paper_rgb = next(c for c in colours if c != ink)
            ink_c, ink_b = zx_colour(ink)
            paper_c, paper_b = zx_colour(paper_rgb)
            return [SHOW.get(code, chr(code)), ink_c, paper_c, ink_b | paper_b, b, i]
    return ['�', None, None, 0, False, False]  # not a known glyph


def read_cell(px, row, col, font):
    return read_cell_full(px, row, col, font)[0]


def load(path):
    return Image.open(path).convert('RGB').load()


def read_screen(path, font):
    px = load(path)
    return [''.join(read_cell(px, r, c, font) for c in range(32)).rstrip() for r in range(24)]


def compare(golden, shots, font):
    got = []
    for s in shots:
        got += read_screen(s, font)[1:23]
    want = open(golden, encoding='utf-8').read().split('\n')
    for lst in (got, want):
        while lst and lst[-1] == '':
            lst.pop()
    if got == want:
        print(f'{os.path.basename(golden)}: OK ({len(want)} rows, {len(shots)} screens)')
        return True
    print(f'{os.path.basename(golden)}: DIFFERENT')
    for i in range(max(len(got), len(want))):
        g = got[i] if i < len(got) else '<none>'
        w = want[i] if i < len(want) else '<none>'
        if g != w:
            print(f'  row {i + 1} (screen {i // 22 + 1}, line {i % 22 + 1}):\n    want |{w}|\n    got  |{g}|')
    return False


def cell_differs(want, got):
    """What differs between an expected and a read cell, or None."""
    ch, ink, paper, bright, b, i = want
    gch, gink, gpaper, gbright, gb, gi = got
    if (ch if ch not in ('£', '©') else ch) != gch:
        return 'character'
    if paper != gpaper:
        return 'paper'
    if ch != ' ':
        if ink != gink:
            return 'ink'
        if (b, i) != (gb, gi):
            return 'font'
    if (paper != 0 or (ch != ' ' and ink != 0)) and bright != gbright:
        return 'bright'
    return None


def compare_style(expected, shots, font):
    want = json.load(open(expected))
    rows = []
    for s in shots:
        px = load(s)
        rows += [[read_cell_full(px, r, c, font) for c in range(32)] for r in range(1, 23)]
    blank = [' ', 7, 0, 0, False, False]
    bad = []
    for n, wrow in enumerate(want):
        if n >= len(rows):
            bad.append((n, 0, 'missing screen', None, None))
            break
        for c in range(32):
            w = wrow[c] if c < len(wrow) else blank
            why = cell_differs(w, rows[n][c])
            if why:
                bad.append((n, c, why, w, rows[n][c]))
    name = os.path.basename(expected)
    if not bad:
        print(f'{name}: OK ({len(want)} rows, colours and fonts)')
        return True
    print(f'{name}: DIFFERENT ({len(bad)} cells)')
    for n, c, why, w, g in bad[:12]:
        print(f'  row {n + 1} col {c}: {why}: want {w} got {g}')
    return False


def compare_links(expected, shot, font):
    links = open(expected, encoding='utf-8').read().split('\n')[:-1]
    screen = read_screen(shot, font)
    bad = 0
    for k in range(min(len(links), LIST_ROWS)):
        want = (f'{k + 1:3} ' + links[k])[:32].rstrip()
        got = screen[LIST_TOP + k]
        if want != got:
            bad += 1
            print(f'  link {k + 1}:\n    want |{want}|\n    got  |{got}|')
    name = os.path.basename(expected)
    print(f'{name}: ' + ('OK' if not bad else 'DIFFERENT') + f' ({len(links)} links)')
    return not bad


def main(argv):
    rom = DEFAULT_ROM
    if '--rom' in argv:
        i = argv.index('--rom')
        rom = argv[i + 1]
        del argv[i:i + 2]
    font = load_font(rom)
    if argv[1] == '--compare':
        return 0 if compare(argv[2], argv[3:], font) else 1
    if argv[1] == '--compare-style':
        return 0 if compare_style(argv[2], argv[3:], font) else 1
    if argv[1] == '--compare-links':
        return 0 if compare_links(argv[2], argv[3], font) else 1
    for line in read_screen(argv[1], font):
        print(line)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
