# zx-vvv: the 8TML browser for the ZX Spectrum 48K

The official ZX Spectrum port of VVV, the reference 8TML client (name and go-ahead
from the 8TML author). It runs on an unmodified 48K and reaches the web
through the ZX MODEM.

**Status:** M3. It fetches pages through the modem and lays them out
itself, line for line like the 8TML reference tool: headings, paragraphs,
lists (renumbered), quotes, preformatted text, rules, centring, line
breaks, upper case unless the page says `case: mixed`. Inline markup is
handled for the text (tags vanish, entities and escapes decode, links show
their text). Next (M4): colours and bold/italic fonts for inline markup,
following links, Back.

## How it fits the modem

- **App 2, kind 1:** the menu loads it at 0xA000 and `CALL`s it; Q goes
  back to the menu. It borrows the menu's screen, link and text-entry
  routines through the API table (`docs/app-api.md`), so it's about 6 KB
  on tape and leaves ~15 KB for the page.
- **The Spectrum is the browser.** Everything 8TML-specific happens here:
  resolving links (`zx/url.asm`, RFC 3986), `index.8tml` for directories,
  dropping `#fragments`, asking for `text/8tml`, refusing `text/html` and
  media types, the messages the reader sees, and parsing and laying out the
  page (`zx/render.asm`).
- **The modem stays a modem.** It has no zx-vvv code: the browser uses the
  general **http service** (`0x01`, `docs/link-protocol.md` §6.4), which
  fetches an absolute address, follows redirects, filters by content type
  before the body goes on tape, and converts UTF-8 to ASCII.

## Using it

| Key | |
|---|---|
| G | type an address (`t8wn.com` means `http://t8wn.com/index.8tml`) |
| R | reload |
| H | home: `https://t8wn.com/index.8tml` |
| N / M | next / previous screen |
| K or ? | help: the keys, and how full the page buffer is (the title row shows "K: help") |
| Q | back to the menu |
| SPACE | stop a load (the page stays) |

Row 0 shows the page's title. Row 23 shows the address, or "Server says
HTTP 404", "Page cut: too long", "Form not shown (yet)", "Newer 8TML
version", or an error; the screen counter is on the right. An error (no
Wi-Fi, a refused type...) never replaces the page on screen, as the 8TML
spec asks. Forms are skipped until M8.

## How the renderer works

The page stays raw in the page buffer. After it loads, one pass lays it out
without drawing and keeps a bookmark at the start of every screen (up to
64): the block that screen starts in, the parser's state there, and how
many of the block's rows came before. N and M redraw from a bookmark.
Text blocks are read as one joined text, as in the reference parser, with
enough lookahead for the longest construct (a link: 80 characters of text,
255 of address). Details: the comments in `zx/render.asm`.

## Folder

| Path | What |
|---|---|
| `zx/vvv.asm` | the browser (→ `vvv.bin`, embedded in the firmware as app 2) |
| `zx/render.asm` | the 8TML renderer: header, blocks, inline text, wrap, screen bookmarks |
| `zx/url.asm` | address rules in Z80 |
| `zx/urltest.asm` | the Spectrum self-test of `url.asm` (not shipped) |
| `host/url.c` | the C reference of the address rules, with the rules spelled out |
| `host/url_cases.txt` | the test cases both run: 62 so far, including RFC 3986 §5.4 |
| `host/cases2asm.py` | turns the cases into `url_cases.inc` for the self-test |
| `host/golden.py` | writes the golden files from the reference tool |
| `host/fusetest.ps1` | the renderer test in Fuse: every screen of every test page against its golden file |
| `testpages/` | test pages, their golden files (`.zx.txt`) and hand-written expectations (`.expect.txt`) |
| `spec/` | the 8TML 1 spec package from its author, unzipped as-is (read-only). Not in the public repo: see `spec/GET-THE-SPEC.md` |
| `docs/` | notes (`website-notes.md`: what t8wn.com adds, the live server) |

## Testing

- **The renderer** (13 test pages: blocks, inline markup, wrapping,
  headers, plain text, open blocks at the end, a form, many screens, too
  many screens, hostile input):
  ```
  powershell -File apps/zx-vvv/host/fusetest.ps1
  ```
  It loads every page into the browser in Fuse (canned modem replies),
  captures every screen, reads it back as text by matching each cell
  against the ROM font (`host/tools/zxscreen.py`) and compares the screens,
  one after another, with the page's golden file. `-Dir folder` runs pages
  from elsewhere (e.g. the spec's examples, which aren't in the repo).
  Don't use the keyboard while it runs.
- **Golden files:** `python apps/zx-vvv/host/golden.py --check` renders
  every test page with the reference tool (`8tml render -m zx --plain`,
  without the caption line) and runs `8tml check` on it. A page with a
  `.expect.txt` keeps that instead: forms (the reference draws them; zx-vvv
  skips them for now) and the page over 64 screens. Needs the spec package.
- **Addresses:** `ctest` (host build) runs `host/url.c` against the cases;
  the Spectrum runs the same cases in `urltest.bin` ("URL tests: 62/62
  passed"):
  ```
  python host/tools/fake_reply.py build/zxmenu.tap build/urltest-session.tap info overlay:build/urltest.bin
  ```
  then choose item 3 (the canned app list's Wi-Fi Setup slot loads it).
- **By hand:** canned http replies (`page:` and `httperr:` in
  `host/tools/fake_reply.py`) stand in for the modem:
  ```
  python host/tools/fake_reply.py build/zxmenu.tap build/vvv-session.tap info overlay:build/vvv.bin page:my.8tml httperr:6:text/html
  ```
  choose item 1; the first reply answers the home page request, the next
  one the next request.
