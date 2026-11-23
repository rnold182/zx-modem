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
preview. Styles cascade as in the reference CLI: the folder's site.8ss, the
page's style: sheet, the header. Needs the spec package in apps/zx-vvv/spec.

Usage: python golden_style.py [pages or folders...]   (default: testpages/)
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
    'black': (0, 0), 'blue': (1, 0), 'lightblue': (5, 1), 'red': (2, 0), 'pink': (2, 1),
    'purple': (3, 0), 'green': (4, 0), 'lightgreen': (4, 1), 'cyan': (5, 0), 'yellow': (6, 1),
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


def zx_cell(c, text_color, bg):
    """A reference cell as zx-vvv draws it: ink and paper on the page's
    background; on a coloured background the whole page takes its BRIGHT
    (an even background), on black the colour's own."""
    ch = ' ' if c.ch == parser.NBSP else c.ch
    ink, bright = ZX[c.color or text_color or 'lightgrey']
    bg_ink, bg_bright = ZX[bg]
    if bg_ink:
        bright = bg_bright
    bold, italic = getattr(c, 'b', False), getattr(c, 'i', False)
    if c.rev:
        return [ch, bg_ink, ink, bright, bold, italic]
    return [ch, ink, bg_ink, bright, bold, italic]


def load_sources(page, doc):
    """The cascade's sources as the reference CLI loads them: the page
    folder's site.8ss, the page's style: sheet (a local file), the header."""
    sources = []
    files = [os.path.join(os.path.dirname(page), 'site.8ss')]
    if 'style' in doc.header and '://' not in doc.header['style']:
        files.append(os.path.join(os.path.dirname(page), doc.header['style'].split('?')[0]))
    for path in files:
        if os.path.exists(path):
            entries = style.parse_8ss(open(path, 'rb').read().decode('latin-1'), lambda *a: None)
            sources.append([(k, v) for _, k, v in entries])
    sources.append([(k, v) for _, k, v in doc.header_entries])
    return sources


def rows_of(doc, page, selected=None):
    styles = style.resolve(load_sources(page, doc), 'zx')
    r = StyledRenderer(doc, styles, MACHINES['zx'], None, selected)
    r.render()
    text = r.style('text').color
    rows = [[zx_cell(c, text, r.bg) for c in row] for row in r.rows]
    blank = zx_cell(render.Cell(' ', None), text, r.bg)
    return [row + [blank] * (32 - len(row)) for row in rows], r


def main(argv):
    args = argv[1:] or [PAGES]
    pages = []
    for a in args:                       # pages, or folders of pages
        if os.path.isdir(a):
            pages += sorted(glob.glob(os.path.join(a, '*.8tml')) + glob.glob(os.path.join(a, '*.txt')))
        else:
            pages.append(a)
    for page in pages:
        if page.endswith('.zx.txt') or page.endswith('.expect.txt') or page.endswith('.links.txt'):
            continue
        name = os.path.splitext(page)[0]
        doc = parser.parse(open(page, 'rb').read())
        rows, _ = rows_of(doc, page)
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
            selrows, _ = rows_of(doc, page, ('link', 0))
            first = next((i for i, (a, b) in enumerate(zip(rows, selrows)) if a != b), None)
            if first is not None and first < 22:
                json.dump(selrows[:22], open(sel, 'w'), separators=(',', ':'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
