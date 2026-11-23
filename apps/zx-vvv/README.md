# zx-vvv: the 8TML browser for the ZX Spectrum 48K

The official ZX Spectrum port of VVV, the reference 8TML client (name and go-ahead
from the 8TML author). It runs on an unmodified 48K and reaches the web
through the ZX MODEM.

**Status:** M4. It fetches pages through the modem and lays them out
itself, line for line like the 8TML reference tool: headings, paragraphs,
lists (renumbered), quotes, preformatted text, rules, centring, line
breaks, upper case unless the page says `case: mixed`. Inline markup shows
in colour (Spectrum colours for the 8TML ones), with bold and italic
glyphs made from the ROM font; links can be focused, followed and listed,
and B goes back to the screen you were on. Stylesheets (M7) work:
`site.8ss`, a page's own `style:` sheet and style keys in the header, with
`zx.` overrides, as the 8TML cascade says. Next: forms (M8), robustness (M6).

## How it fits the modem

- **App 2, kind 1:** the menu loads it at 0xA000 and `CALL`s it; Q goes
  back to the menu. It borrows the menu's screen, link and text-entry
  routines through the API table (`docs/app-api.md`), so it's about 8 KB
  on tape and leaves ~15.3 KB for the page (its big buffers sit in the
  menu's spare area, 0x9000-0x9FFF).
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
| G | edit the address (up to 255 characters; it starts as the current one): CAPS+5/8 move, CAPS+0 deletes, CAPS+3 clears, ENTER goes, CAPS+1 cancels. `t8wn.com` means `http://t8wn.com/index.8tml` |
| R | reload |
| H | home: `https://t8wn.com/index.8tml` |
| N / M | next / previous screen |
| 6 / 7 (or the cursor keys) | next / previous link; past the last one, the next screen |
| ENTER | follow the focused link (`#top`-style links go to the top of the page) |
| B | back: the previous page, at the screen you were on (about 10 pages) |
| L | the page's links, numbered: 6/7 move, ENTER follows, N/M more, L back |
| ? | help: the keys, and how full the page buffer is (the title row shows "?: help"; SYMBOL SHIFT + C) |
| Q | back to the menu |
| SPACE | stop a load (the page stays) |

Row 0 shows the page's title. Row 23 shows the address (or the focused
link's), or "Server says HTTP 404", "Page cut: too long", "Form not shown
(yet)", "Newer 8TML version", or an error; the screen counter is on the
right. An error (no Wi-Fi, a refused type...) never replaces the page on
screen, as the 8TML spec asks. Forms are skipped until M8.

**Colours** follow the stylesheets through a hand-tuned ZX table
(`CLAUDE.md` §6.6). Without any sheet: text white, `#` headings reversed,
emphasis and strong bright white, links bright cyan, preformatted text
bright green, a focused link reversed (the spec's `link-sel`).

**Stylesheets:** the first page of a site also fetches its `/site.8ss`
(once: it is kept, missing or not, for the last 4 sites while zx-vvv runs),
and a page with `style:` fetches that sheet (the last one is kept). Each
costs one more request, about 6-8 s of tape. The page's background and
border come from `bg` and `border`; on a coloured background the whole page
takes the background's BRIGHT, so the background stays even (a bright
yellow link on blue shows as plain yellow).

## How the renderer works

The page stays raw in the page buffer. After it loads, one pass lays it out
without drawing and keeps a bookmark at the start of every screen (up to
64): the block that screen starts in, the parser's state there (including
how many links came before), and how many of the block's rows came before.
N and M redraw from a bookmark. Text blocks are read as one joined text, as
in the reference parser, with enough lookahead for the longest construct (a
link: 80 characters of text, 255 of address).

Each cell carries its character (bit 7: italic), its attribute (bit 7, the
FLASH bit: bold) and a link id. Characters are drawn straight from the ROM
font: bold ORs every glyph row with itself shifted one pixel, italic shifts
the top four rows. No font tables in memory.

Links take no memory for their addresses: the screen keeps where each
link's characters are, and when one is focused, followed or listed the
renderer reads the page again from that screen's bookmark until it reaches
that link. Details: the comments in `zx/render.asm`.

## Folder

| Path | What |
|---|---|
| `zx/vvv.asm` | the browser (→ `vvv.bin`, embedded in the firmware as app 2): keys, focus, history, the link list |
| `zx/render.asm` | the 8TML renderer: header, blocks, inline markup, colours and fonts, wrap, screen bookmarks, link runs |
| `zx/style.asm` | stylesheets: 8SS parsing, the cascade, role colours as ZX attributes |
| `zx/url.asm` | address rules in Z80 |
| `zx/urltest.asm` | the Spectrum self-test of `url.asm` (not shipped) |
| `host/url.c` | the C reference of the address rules, with the rules spelled out |
| `host/url_cases.txt` | the test cases both run: 62 so far, including RFC 3986 §5.4 |
| `host/cases2asm.py` | turns the cases into `url_cases.inc` for the self-test |
| `host/golden.py` | writes the layout golden files from the reference tool |
| `host/golden_style.py` | writes the expected colours, fonts, focused link and link list |
| `host/fusetest.ps1` | the renderer test in Fuse: every screen and every cell of every test page |
| `host/navtest.ps1` | following links, Back to the same screen, the link list, an error keeping the page |
| `host/edittest.ps1` | the address field: editing, scrolling, loading what was typed |
| `host/testsite.py` | the network test site (M5): every case, to browse from the 48K |
| `host/fusectl.ps1` | runs Fuse off-screen without taking the keyboard focus |
| `testpages/` | test pages and their expected files (`.zx.txt`, `.expect.txt`, `.style.json`, `.sel.json`, `.links.txt`); `styled/` has its own `site.8ss` and a page sheet |
| `spec/` | the 8TML 1 spec package from its author, unzipped as-is (read-only). Not in the public repo: see `spec/GET-THE-SPEC.md` |
| `docs/` | notes (`website-notes.md`: what t8wn.com adds, the live server) |

## Testing

Fuse runs off-screen and gets its keys as window messages, so the tests
never take the keyboard focus: the PC stays usable while they run.

- **The renderer** (14 test pages: blocks, inline markup, wrapping,
  headers, plain text, open blocks at the end, a form, links, many screens,
  too many screens, hostile input):
  ```
  powershell -File apps/zx-vvv/host/fusetest.ps1
  ```
  It loads every page into the browser in Fuse (canned modem replies) and
  reads every screen back (`host/tools/zxscreen.py` matches each cell
  against the ROM font, plain, bold and italic, and reads its colours). It
  checks the text of every screen, every cell's ink, paper, BRIGHT, bold
  and italic, screen 1 with the first link focused, and the L list.
  `-Dir folder` runs pages from elsewhere (`testpages/styled`, or the
  spec's examples, which aren't in the repo); `-Pages a.8tml,b.8tml` only
  some. The canned replies include the stylesheets zx-vvv asks for: the
  folder's `site.8ss` (or a 404) after the first page, and each page's
  `style:` sheet.
- **The real network** (M5): `python apps/zx-vvv/host/testsite.py` on a PC on
  the modem's network, then G and the address it prints. Its home page links
  every case with the expected result: content types (shown or refused),
  each kind of redirect and the 5-redirect limit, 404/500 bodies, UTF-8
  accents, chunked and connection-close bodies, a page too big, a server
  too slow, unreachable hosts, relative links of every form. It logs each
  request and its answer. HTTPS: the live T8wn site.
- **The address field:** `powershell -File apps/zx-vvv/host/edittest.ps1`.
- **Links and history:** `powershell -File apps/zx-vvv/host/navtest.ps1`
  follows a link from screen 3, comes back with B to screen 3, then follows
  one from the L list and comes back again.
- **Expected files:** `python apps/zx-vvv/host/golden.py --check` writes the
  layout (`8tml render -m zx --plain`, without the caption line) and runs
  `8tml check`; `python apps/zx-vvv/host/golden_style.py` writes the
  colours and fonts (the reference renderer's cells through zx-vvv's ZX
  colour table), the focused-link screen and the link list. A page with a
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
