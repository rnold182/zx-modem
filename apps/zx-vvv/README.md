# zx-vvv: the 8TML browser for the ZX Spectrum 48K

The official ZX Spectrum port of VVV, the reference 8TML client (name and go-ahead
from the 8TML author). It runs on an unmodified 48K and reaches the web
through the ZX MODEM.

**Status:** M2d. It fetches pages through the modem and shows them as raw
text, 32 columns, screen by screen. The 8TML parser and renderer come next
(M3; see the project brief, `CLAUDE.md` §12).

## How it fits the modem

- **App 2, kind 1:** the menu loads it at 0xA000 and `CALL`s it; Q goes
  back to the menu. It borrows the menu's screen, link and text-entry
  routines through the API table (`docs/app-api.md`), so it's about 2 KB
  on tape and leaves ~20 KB for the page.
- **The Spectrum is the browser.** Everything 8TML-specific happens here:
  resolving links (`zx/url.asm`, RFC 3986), `index.8tml` for directories,
  dropping `#fragments`, asking for `text/8tml`, refusing `text/html` and
  media types, the messages the reader sees, and (from M3) parsing and
  laying out the page.
- **The modem stays a modem.** It has no zx-vvv code: the browser uses the
  general **http service** (`0x01`, `docs/link-protocol.md` §6.4), which
  fetches an absolute address, follows redirects, filters by content type
  before the body goes on tape, and converts UTF-8 to ASCII.

## Using it (M2d)

| Key | |
|---|---|
| G | type an address (`t8wn.com` means `http://t8wn.com/index.8tml`) |
| R | reload |
| H | home: `https://t8wn.com/index.8tml` |
| N / M | next / previous screen |
| Q | back to the menu |
| SPACE | stop a load (the page stays) |

Row 23 shows the address, "Server says HTTP 404", "Page cut" or an error;
the screen counter is on the right. An error (no Wi-Fi, a refused type...)
never replaces the page on screen, as the 8TML spec asks.

## Folder

| Path | What |
|---|---|
| `zx/vvv.asm` | the browser (→ `vvv.bin`, embedded in the firmware as app 2) |
| `zx/url.asm` | address rules in Z80 |
| `zx/urltest.asm` | the Spectrum self-test of `url.asm` (not shipped) |
| `host/url.c` | the C reference of the address rules, with the rules spelled out |
| `host/url_cases.txt` | the test cases both run: 62 so far, including RFC 3986 §5.4 |
| `host/cases2asm.py` | turns the cases into `url_cases.inc` for the self-test |
| `spec/` | the 8TML 1 spec package from its author, unzipped as-is (read-only). Not in the public repo: see `spec/GET-THE-SPEC.md` |
| `testpages/` | test pages and golden files (`render -m zx --plain --links`) |
| `docs/` | notes (`website-notes.md`: what t8wn.com adds, the live server) |

## Testing

- `ctest` (host build) runs `host/url.c` against the cases.
- **The Z80 resolver** runs the same cases on the Spectrum: load the menu
  with `urltest.bin` as an app in Fuse (it shows "URL tests: 62/62
  passed"):
  ```
  python host/tools/fake_reply.py build/zxmenu.tap build/urltest-session.tap info overlay:build/urltest.bin
  ```
  then choose item 3 (the canned app list's Wi-Fi Setup slot loads it).
- **The browser offline:** canned http replies (`page:` and `httperr:` in
  `host/tools/fake_reply.py`, the "8tml2tap" of the brief) stand in for the
  modem:
  ```
  python host/tools/fake_reply.py build/zxmenu.tap build/vvv-session.tap info overlay:build/vvv.bin page:my.8tml httperr:6:text/html
  ```
  choose item 1; the first reply answers the home page request, the next
  one the next request.

The spec's reference tool is the layout oracle (from M3):

```
python apps/zx-vvv/spec/tools/8tml render -m zx --plain --links page.8tml
```
