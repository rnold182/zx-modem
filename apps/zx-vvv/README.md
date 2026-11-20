# zx-vvv: the 8TML browser for the ZX Spectrum 48K

The official ZX Spectrum port of VVV, the reference 8TML client (name and go-ahead
from the 8TML author). It runs on an unmodified 48K and reaches the web
through the ZX MODEM.

**Status:** not started; next milestone M2d (see the project brief,
`CLAUDE.md` §12).

## How it fits the modem

- **App 2, kind 2 (a program):** it replaces the ZX MODEM menu while it
  runs, since it needs all the memory from 32768 up (code, fonts, link table
  and a ~24 KB page buffer). It is listed in the menu as "8TML Browser".
- **Spectrum side** builds against `sdk/` only, like any app.
- **Modem side:** the browser service (`0x01`) as its own ESP-IDF component
  in this folder: URL resolution, redirects, content-type rules, `url-info`
  replies. The firmware pulls it in; the modem's link layer stays free of
  8TML rules.

## Folder

| Path | What |
|---|---|
| `spec/` | the 8TML 1 spec package from its author, unzipped as-is (read-only). Not in the public repo: see `spec/GET-THE-SPEC.md` |
| `testpages/` | test pages and golden files (`render -m zx --plain --links`) |
| `zx/` | the Spectrum program *(to come)* |
| `esp32/` | the browser service, an ESP-IDF component *(to come)* |
| `docs/` | notes (`website-notes.md`: what t8wn.com adds, the live server); later the browser service's commands |

The spec's reference tool is the layout oracle:

```
python apps/zx-vvv/spec/tools/8tml render -m zx --plain --links page.8tml
```
