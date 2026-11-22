"""Expected colours, fonts and links for zx-vvv, from the 8TML reference.

For every test page this writes, next to the layout golden file:
  <name>.style.json  every cell: [character, ink, paper, bright, bold, italic]
                     as zx-vvv must draw it (rows as in .zx.txt)
  <name>.sel.json    screen 1 with the first link selected (only when that
                     link is on screen 1): what moving the focus to it shows
  <name>.links.txt   the page's link addresses, in order (the L list), if any

The reference renderer (spec tools/tml/render.py) gives each cell an 8TML
colour and reverse; b and i come from its parser's runs. The colours are
mapped with zx-vvv's ZX table (CLAUDE.md 6.6), not the tool's RGB-nearest
preview. Styles are the reference defaults plus the page's case: zx-vvv has
no stylesheets yet (M7). Needs the spec package in apps/zx-vvv/spec.

Usage: python golden_style.py [pages...]   (default: all of testpages/)
"""
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'spec', 'tools'))
from tml import parser, render, style  # noqa: E402
from tml.machines import MACHINES  # noqa: E402

PAGES = os.path.join(HERE, '..', 'testpages')

# 8TML colour -> (ZX ink, bright): the hand-tuned table of CLAUDE.md 6.6
ZX = {
    'black': (0, 0), 'blue': (1, 0), 'lightblue': (1, 1), 'red': (2, 0), 'pink': (2, 1),
    'purple': (3, 0), 'green': (4, 0), 'lightgreen': (4, 1), 'cyan': (5, 1), 'yellow': (6, 1),
    'orange': (6, 0), 'brown': (2, 0), 'darkgrey': (7, 0), 'grey': (7, 0), 'lightgrey': (7, 0),
    'white': (7, 1),
}


class StyledRenderer(render.Renderer):
    """The reference renderer, with b and i kept on each cell."""

    def cells(self, runs, role):
        out = []
        for r in runs:
            part = render.Renderer.cells(self, [r], role)
            for c in part:
                c.b, c.i = r.b, r.i
            out += part
        return out


def zx_cell(c, text_color):
    ch = ' ' if c.ch == parser.NBSP else c.ch
    ink, bright = ZX[c.color or text_color]
    bold, italic = getattr(c, 'b', False), getattr(c, 'i', False)
    if c.rev:
        return [ch, 0, ink, bright, bold, italic]
    return [ch, ink, 0, bright, bold, italic]


def rows_of(doc, selected=None):
    styles = dict(style.DEFAULTS)
    if 'case' in doc.header:
        styles['case'] = doc.header['case']
    r = StyledRenderer(doc, styles, MACHINES['zx'], None, selected)
    r.render()
    text = r.style('text').color
    return [[zx_cell(c, text) for c in row] for row in r.rows], r


def main(argv):
    pages = argv[1:] or sorted(glob.glob(os.path.join(PAGES, '*.8tml')) + glob.glob(os.path.join(PAGES, '*.txt')))
    for page in pages:
        if page.endswith('.zx.txt') or page.endswith('.expect.txt') or page.endswith('.links.txt'):
            continue
        name = os.path.splitext(page)[0]
        doc = parser.parse(open(page, 'rb').read())
        rows, _ = rows_of(doc)
        if os.path.exists(name + '.expect.txt'):
            n = len(open(name + '.expect.txt', encoding='utf-8').read().rstrip('\n').split('\n'))
            rows = rows[:n] if 'toolong' in name else None   # forms: the reference draws them
        if rows is not None:
            json.dump(rows, open(name + '.style.json', 'w'), separators=(',', ':'))
        links = [link.url for link in doc.links]
        if links:
            with open(name + '.links.txt', 'w', encoding='utf-8', newline='\n') as f:
                f.write(''.join(u + '\n' for u in links))
        elif os.path.exists(name + '.links.txt'):
            os.remove(name + '.links.txt')
        sel = name + '.sel.json'
        if os.path.exists(sel):
            os.remove(sel)
        if doc.links and rows is not None:
            selrows, _ = rows_of(doc, ('link', 0))
            first = next((i for i, (a, b) in enumerate(zip(rows, selrows)) if a != b), None)
            if first is not None and first < 22:
                json.dump(selrows[:22], open(sel, 'w'), separators=(',', ':'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
