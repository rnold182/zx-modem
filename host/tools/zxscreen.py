"""Read a Spectrum screen back as text, from an emulator screenshot.

Every 8x8 cell is matched against the 48K ROM font (both ways round, so
the colours and reverse video don't matter); cells that are one colour are
spaces. That turns a screenshot into exactly the characters the program
drew, for comparing with the 8TML reference tool's layout.

The screenshot is the 640x480 crop host tests take from Fuse (2x scale with
the border): cell (row, col) starts at pixel (64 + 16*col, 49 + 16*row).

    python zxscreen.py shot.png [--rom 48.rom]          # prints 24 rows
    python zxscreen.py --compare golden.zx.txt s1.png s2.png ...
        compares rows 1-22 of each screen, one after another, with the
        golden file (trailing blank lines ignored); exit 1 on a difference.
"""
import os
import sys

from PIL import Image

ORIGIN_X, ORIGIN_Y, CELL = 64, 49, 16
DEFAULT_ROM = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Programs', 'fuse', 'roms', '48.rom')
SHOW = {0x60: '£', 0x7F: '©'}          # how the reference tool writes these ZX glyphs


def load_font(rom):
    data = open(rom, 'rb').read()
    font = {}
    for code in range(32, 128):
        rows = data[0x3D00 + (code - 32) * 8:0x3D00 + (code - 32) * 8 + 8]
        font[tuple(rows)] = code
    return font


def read_cell(px, row, col, font):
    x0, y0 = ORIGIN_X + col * CELL, ORIGIN_Y + row * CELL
    pix = [[px[x0 + 2 * i, y0 + 2 * j] for i in range(8)] for j in range(8)]
    colours = {p for line in pix for p in line}
    if len(colours) == 1:
        return ' '
    for ink in colours:
        bits = tuple(sum(0x80 >> i for i in range(8) if line[i] == ink) for line in pix)
        if bits in font:
            code = font[bits]
            return SHOW.get(code, chr(code))
    return '�'                           # not a ROM character


def read_screen(path, font):
    img = Image.open(path).convert('RGB')
    px = img.load()
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


def main(argv):
    rom = DEFAULT_ROM
    if '--rom' in argv:
        i = argv.index('--rom')
        rom = argv[i + 1]
        del argv[i:i + 2]
    font = load_font(rom)
    if argv[1] == '--compare':
        return 0 if compare(argv[2], argv[3:], font) else 1
    for line in read_screen(argv[1], font):
        print(line)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
