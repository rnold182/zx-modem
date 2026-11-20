# Notes from t8wn.com (checked 2026-11-20)

What the public site (https://t8wn.com/8tml/) adds to, or confirms about,
our spec package (`../spec/`, dated 2026-10-26). The spec package stays
authoritative; this file only records what the site says and what the live
server does.

## The spec itself: no newer version

- The site documents "8TML 1" and calls it a draft that can still change.
  It offers no newer package; the most recent spec news is the review post
  of 2026-10-20 ("8TML 1: ready for more browsers"), which matches our
  package's "reviewed 2026-10-20".
- The reference pages (HTTP, HTTPS proxy, client limits, URLs, cascade,
  blocks, page header) say the same as our package's sections 3, 4, 8, 9
  and 10.
- `site.8ss` caching: the site says "fetched once per site and cached, a
  missing one remembered", with no lifetime. Our package's **[proposal]**
  (keep it at least until the client restarts) is still the only rule.
- No `screen`, `petscii` or media blocks are defined on the site either.

## One rule the site adds: the Accept header

The HTTP page says clients never list `text/html` in `Accept`; they send
`Accept: text/8tml` or no `Accept` at all. Our package doesn't mention
`Accept`. **This matters on the live server** (next section): a request
that names `text/html` gets the web version instead of 8TML.

## The live server

T8wn negotiates on `Accept` (`Vary: Accept`), tested with curl:

| Request | Answer |
|---|---|
| `http://t8wn.com/...` | `301` to `https://t8wn.com/...` (any `Accept`) |
| `https://t8wn.com/index.8tml`, `Accept: text/8tml` | `200`, `Content-Type: text/8tml`, the town's 8TML home page |
| same, `Accept: */*`, `text/8tml, */*` or none | `200`, `text/8tml` |
| same, `Accept: text/html` | `302` to `https://t8wn.com/` (the HTML site) |
| `https://t8wn.com/site.8ss` | `200`, `Content-Type: text/plain`, the town stylesheet |

- **A real home page for testing:** `https://t8wn.com/index.8tml` (or
  `https://t8wn.com/`, which a client turns into `index.8tml`). It passes
  `tools/8tml check` with no errors or warnings and uses `case: mixed`,
  centring, `&nbsp;`, colour and `rev` tags, `\` hard breaks, a separator
  and relative links (`about.8tml`, `visit.8tml`, `join.8tml`,
  `write.8tml`): a good first test page.
- **Its `site.8ss`** sets a blue background and border, yellow links
  (`link-sel: cyan reverse`), white centred `h1`. Served as `text/plain`,
  which clients accept.
- Since plain `http://` always redirects to `https://`, the browser depends
  on the modem's HTTPS (the ESP32 does TLS itself; no proxy needed).
- Plots (`https://t8wn.com/@name`) are invite-only; none are listed
  publicly yet.

## VVV, the reference client (news, 2026-10-27; still a prototype)

Behaviour worth matching in zx-vvv:

- A response that isn't 8TML-capable (refused type) is refused **before the
  body is downloaded**, and the browser stays on the previous page. Status
  line: `Unsupported type: not an 8TML page`.
- A missing page shows `Server says HTTP/1.1 404 Not Found` (the server's
  status line).
- Centred lines padded with `&nbsp;` line up (the padding counts as text,
  so it isn't trimmed before centring).

## Platforms page

- ZX Spectrum: 32x24, 8 colours with a bright level per 8x8 cell,
  "ASCII-like (` = £)".
- "Getting online", ZX Spectrum row: Spectranet (Ethernet), ZX Next WiFi,
  serial WiFi modems. **The tape-port modem isn't listed**; asking the
  author to add it is an open question in `CLAUDE.md` §13.
- The site's reference PC implementation previews pages at 40, 32 and 22
  columns.

Pages read: /8tml/, /, /8tml/reference/ and its HTTP, HTTPS proxy, client
limits, URLs, cascade, blocks and page header pages, /8tml/platforms/,
/8tml/guides/ and writing-a-client, /8tml/examples/, /news/ and the posts of
2026-10-20 and 2026-10-27, /plots/. The site notes that most of its prose
(not the reference) was written with AI help.
