# ZX Spectrum 48K 8TML Browser — Project Brief

Handoff document from the design chat (2026-10-26). Read this fully before writing code.

**The 8TML spec lives in the repo at `apps/zx-vvv/spec/`.** This is the official spec package from the 8TML author (8tml-v1.0-specs, dated 2026-10-26): unzip it there (a `.zap` file is a plain zip). **It is not in the public repo** (its license is undecided; the folder is gitignored apart from `GET-THE-SPEC.md`), so a fresh clone has to get it from the author. `apps/zx-vvv/spec/spec/8tml-1.md` is **authoritative**. If this brief, the website or the reference tool disagrees with it, the spec file wins. §4 below is a client-oriented digest with section references, so check the spec before implementing each feature.

## 1. Goal

A real **8TML browser running on an unmodified ZX Spectrum 48K**. An **ESP32** acts as a network coprocessor, connected only through the Spectrum's **EAR** (input) and **MIC** (output) audio sockets.

- **The Spectrum is the 8TML client.** It parses the 8TML header, blocks and inline markup itself, keeps the link table, handles focus and navigation, and renders. It is **not** a dumb terminal.
- **The ESP32 is the network card, and stays a modem.** It does Wi-Fi, HTTP/HTTPS, redirects, the content-type filter the client asks for, converts UTF-8 to ASCII, and handles the tape-signal link in both directions. It knows nothing about 8TML: it must **not** pre-render or parse it, resolve links or apply 8TML rules (decided 2026-11-22).
- **Fun constraint:** no hardware mods to the Spectrum. Everything goes through the tape sockets and ROM routines.

**Two phases, modem first.**

1. **Phase 1: the "tape-port modem".** The ESP32, its tape link and a reusable Z80 link library form a general request/response network link for the Spectrum. It must stand on its own: other programs, including BASIC programs through `USR`, can use it.
   - **Phase 1 is done** (2026-11-18, proven on the real 48K): link, menu, Wi-Fi setup, saved networks, web fetch for BASIC.
2. **Phase 2: the 8TML browser, "zx-vvv".** The official ZX Spectrum port of VVV (name and go-ahead from the 8TML author, 2026-11-20). It lives in `apps/zx-vvv/` and is managed as its own project: it builds against `sdk/` and the protocol docs only. It has **no modem-side code**: it uses the general `http` service (`0x01`).

**Apps (decided 2026-11-20):** the modem is a platform. Apps live in `apps/<name>/`, build against `sdk/` (a fixed, versioned API table in the menu: `docs/app-api.md`), are registered in `esp32/main/apps.c` and listed by the menu from the `info` reply. The wire protocol is a documented standard, `docs/link-protocol.md` ("ZX Modem Link Protocol 1", with a registry of services, response types and app ids). Ideas: a Claude client app; a Zimodem-style AT service (planned, `0x04`).

**Design rule:** the modem knows nothing about 8TML. Every browser rule (link resolution, `index.8tml`, fragments, which types to ask for and refuse, the reader's messages) lives in the browser program on the Spectrum; the modem offers general services (§7.3).

## 2. Working style

- **Discuss before implementing.** Propose an approach and get an OK before large changes.
- Keep explanations concise, but always add a short "why this works" next to code.
- Offer alternatives when they are genuinely useful. Ask when something is ambiguous.
- **No logic analyzer or oscilloscope available** (see §9 for the workarounds).
- The main developer's personal notes, if present, are in `CLAUDE.local.md` (not in git).

## 3. Decisions made

| Area | Decision | Why |
|---|---|---|
| Spectrum language | **Z80 assembly**, **sjasmplus** | Smallest code, leaving the most RAM for pages. Speed isn't the bottleneck (the tape link is). sjasmplus can emit `.tap` directly. |
| ESP32 language | **C, ESP-IDF v5.x** | RMT driver, `esp_http_client`, TLS with the certificate bundle, NVS. All in C. |
| ESP32 board | **Rev B/C: ESP32-S3 SuperMini dev board** (USB-C, 4 MB flash, BOOT/RESET on board) hand-soldered onto a small carrier PCB (`hardware/`): jacks, MIC front end, TX driver, PLAY button. A classic **WROOM-32** dev board stays usable for early TX/RX tests (`idf.py set-target esp32`). Keep code portable to the C3 | Dual core: Wi-Fi on core 0, the RX edge ISR on core 1. A dev board avoids JLCPCB's Standard-PCBA fee for ESP32 modules and ~15 parts. Pins: RX GP4, ADC GP5, TX GP6, PLAY GP7. Decided 2026-11-02. **Rev C** (2026-11-20) fixes the jack pinout: signal on pin 5 (tip), pins 1/2 ground |
| Link | EAR/MIC audio, standard ROM tape encoding both ways | No Spectrum-side audio code. Uses ROM `LD-BYTES` and `SA-BYTES`. |
| Columns | **32 columns, 8×8 font** | One character per attribute cell means no attribute clash (see §6.6). |
| HTTPS | ESP32 does TLS itself (`esp_crt_bundle`) | Not needed: the spec's HTTPS proxy (§9.3, a plain HTTP forward proxy). The ESP32 does the proxy's job itself, including transliterating to ASCII, so the Spectrum only ever sees 7-bit ASCII. |
| Parse location | **Spectrum** | Raw 8TML is about the same size as pre-rendered text, so this costs nothing over the link. The spec is designed for exactly this kind of parser. |

## 4. 8TML 1: the client's view of the spec

### 4.0 The spec package (`apps/zx-vvv/spec/`)

| File | What it is |
|---|---|
| `spec/8tml-1.md` | **The spec.** Status: draft, "nearly final". Everything is decided except items marked **[proposal]**; the only open one is §8.1, how long `site.8ss` is cached. |
| `spec/publish-1.md` | Publishing API: an HMAC-signed upload over HTTP, used by editors. It's a test draft, **not part of the language and not needed for the browser.** Ignore it. |
| `spec/examples/*.8tml`, `*.8ss` | Valid example pages (`index`, `styles` = markup tour, `guestbook` = every form field) and stylesheets. **Use them as the first test pages.** |
| `tools/8tml`, `tools/tml/` | **The reference implementation** (Python 3.10+, standard library only): `parser.py` (the reference parser), `style.py` (8SS and cascade), `render.py` (screen layout), `machines.py` (widths, palettes, character substitutions). |
| `README.txt` | Package overview. |

**Reference tool commands**, run from the package folder:

```
python3 tools/8tml check -v page.8tml                     # errors/warnings/notes with line numbers; exit 1 on errors
python3 tools/8tml render -m zx --plain --links page.8tml # exactly how a 32-column ZX client lays it out
python3 tools/8tml render -m zx page.8tml                 # same, with ANSI colours
```

**This is the test oracle.**
- `render -m zx --plain` gives the expected text layout for our screen, and `--links` lists the links in focus order.
- Compare it with what the Spectrum draws, for example by dumping the Fuse screen or keeping a text mirror of the screen in RAM.
- The first output line (`zx, 32 columns - <title>`) is the tool's caption, not page content.
- Treat the tool as a *reference for layout*, not for colours (see §6.6). The machine-readable layout details below come from `render.py`.

### 4.1 Files and characters (spec §2)

- **Encoding:** 7-bit ASCII, printable 32–126.
- **Line endings:** LF ends a line. A CR directly before an LF is ignored, and a lone CR counts as an LF.
- **Tab:** shown as one space.
- **Bytes 128–255:** shown as `?`. The ESP32 already transliterates, but the Spectrum must still handle these bytes, since raw bytes can arrive.
- **Line length:** a source line SHOULD be ≤255 characters, and a client MAY cut longer lines. Our line buffer is 255 bytes, and anything past that is dropped up to the LF.
- **Keywords are case-insensitive:** header and 8SS keys, colour names, style words, tag names, block types and field types. Fold to lowercase before comparing.
- **ZX character substitutions** (`machines.py`): `` ` `` is shown as `£`, and byte 127 as `©`. This is exactly what the ROM font already does. The bullet is `*` and the rule character is `-`.
  - **Backticks in text appear as £.** Inline code isn't supported, so backticks are printed, and that is accepted behaviour.

### 4.2 Page detection and header (spec §3)

**Is it a page?**
- A response is an 8TML page **iff** its first line is exactly `---` and the **first key** of that block is `8tml`.
- Otherwise the whole response is **plain text**: no markup processing, hard-wrapped every 32 characters (`render.py: wrap_hard`).
- A `---` block with a different first key is also plain text.

**Header format**
- `key: value` lines. Spaces around the value are trimmed. Lines starting with `#` are comments. Unknown keys are ignored.
- The header ends at the next `---` line.
- **Unclosed header** (EOF before the closing `---`): the keys read so far apply, and the body is empty.

**Header keys**

| Key | Meaning |
|---|---|
| `8tml` | Version, a whole number. A higher version is still shown, and the client MAY say the page is newer. |
| `title` | Shown in our title bar (row 0) and in history. |
| `style` | The page's own stylesheet URL, relative to the page. |
| `case` | **`upper` (DEFAULT)** or `mixed`. |
| `platform` | A hint, e.g. `c64`. We MAY show "made for C64". |
| any 8SS key | Overrides that key for this page (cascade level 4). Includes `zx.`-prefixed keys. |

> ⚠️ **Default case is UPPER.** Unless the page (or a stylesheet) says `case: mixed`, the Spectrum must print every letter in uppercase. This applies to the body *and* preformatted text. The 8SS style word `upper` also forces uppercase for one role.

### 4.3 Blocks (spec §4)

The start of each line decides the block type; no lookahead is needed.

| Line | Block | Details |
|---|---|---|
| `# `, `## `, `### ` | Heading h1–h3 | **A space after the `#`s is required.** `####` and deeper count as h3. Always one source line, but it wraps like a paragraph. |
| `* `, `- ` | Bullet item | The bullet is shown as `*` on ZX. Continuation lines get a hanging indent of `len(marker)+1`. |
| `N. ` (digits, dot, space) | Numbered item | **The first item shows its written number, and every following item shows previous+1**, whatever is written (`1. 2. 4.` → 1 2 3; `5. 5. 5.` → 5 6 7). Blank lines between numbered items don't end the list; any other block does. `1984\.` or `1984&#46;` avoids starting a list. |
| line indented ≥2 spaces after an item | Continues the item | Joined with a space. There is **one list level only**, and leading spaces before a bullet are ignored. |
| `> ` | Quote line | Consecutive quote lines join like a paragraph. Role `quote`. **Indented by 2** in the reference renderer, which we do too. |
| ` ``` `… | Opens/closes preformatted text | Anything after the opening fence is ignored. Lines are shown exactly as written: no wrap, no markup, no escapes, **cut at 32 columns**. Role `pre`, and `case` applies. |
| `---` alone (not line 1) | Separator | A full-width line of `-` characters, role `rule`. |
| `:::type args` | Opens an extension block | Closed by a line that is **exactly** `:::`. **No nesting.** Unknown types are skipped up to the closing `:::`. A stray `:::` is ignored. 8TML 1 defines only `form`; `screen`, `petscii` and media types are reserved. |
| blank | Ends a paragraph | Several blank lines count as one. |
| anything else | Paragraph text | Leading spaces are dropped. Lines join with one space. **Runs of spaces inside a line are kept** (unlike HTML). |

**Vertical spacing**
- Blank line(s) in the source between two blocks give **one empty screen line** (the reference parser emits a `gap` block).
- Blocks *without* a blank line between them follow directly: a heading followed by a paragraph, or consecutive list items.
- **No empty lines at the top or bottom of the page.**

**Wrapping** (`render.py: wrap`)
- Greedy wrapping at spaces. A word longer than the width is broken at the edge.
- **The space at a wrap point is not shown.**
- Spaces inside a line are kept, and pending spaces only appear if the next word fits on the line.

**Line breaks** (§4.2)
- `<br>` starts a new line. So does a `\` as the **very last character** of a source line (a Markdown hard break).
- After a hard break at the end of a source line, the next line is joined **without** the usual space.
- `<br>` on an otherwise empty paragraph line gives an empty line.

**Centering** (§4.8)
- `<center>` at the **very start** of a paragraph, heading, quote or list item centres every line of that block.
- `</center>` is accepted and ignored.
- Centring offset is `(width - len(line)) // 2`, after any indent.
- Roles can also centre through the 8SS style word `center`.

**End of file** (§4.10)
- Everything still open simply ends: a pre block is shown up to EOF, an unknown extension block is skipped to EOF, a form keeps its fields and can still be sent.
- An open paragraph, emphasis or style just ends.

### 4.4 Inline markup (spec §5)

Inline markup applies in paragraphs, headings, quotes, list items, form labels and link text. It is read from the **joined** block text, so markup may span source lines, and the joining space is part of the text.

**Emphasis**
- `*x*` is `em` and `**x**` is `strong`.
- A `*` **opens only if followed by a non-space** and **closes only if preceded by a non-space**. Any other `*` is printed (`5 * 3`).
- `_` is never emphasis.
- An unclosed emphasis runs to the end of the block.

**Tags**
- Recognised tags: **exactly** the colour names and aliases, `b`, `i`, `rev`, `br`, `center`. Anything else between `<` and `>` (`<3`, `a < b`, `<hello>`) is **printed as written**.
- **State model:** an optional colour plus `b`, `i`, `rev` flags.
  - A colour tag *replaces* the colour, while `b`, `i` and `rev` *add* their effect.
  - **Closing** is `</>` or `</name>`. **Any** closing tag, or a closing `*`/`**`, resets **all** inline state to the role's style.
  - There is no stack and no nesting. The end of a block resets everything.

**Colours:** black, white, red, cyan, purple, green, blue, yellow, orange, brown, pink, darkgrey, grey, lightgreen, lightblue, lightgrey. Aliases: magenta=purple, lightred=pink, gray=grey, darkgray=darkgrey, lightgray=lightgrey.

**Links** (`[text](url)`)
- **Buffering:** buffer from `[` to `]`. If the next character after `]` is `(`, read the URL up to `)` and show the buffered text as a link (role `link`, or `link-sel` when focused).
- If `]` isn't followed by `(`, print the buffer as written, brackets included.
- **Limits:** link text is at most **80** characters and a URL at most **255**. If a limit is hit before `]` or `)`, print the buffer as plain text.
- The link text may contain tags and escapes, and it ends at the first `]`, even an escaped one.
- **Empty link text** (`[](url)`) shows the URL.
- **The URL is raw:** taken exactly as written, with spaces trimmed at its ends. No escapes, entities or markup apply inside it.
- Links with schemes other than http and https are **shown but can't be followed**.
- The Spectrum resolves the URL itself (§4.7, `apps/zx-vvv/zx/url.asm`) and sends the modem only absolute addresses.

**Escapes**
- `&lt; &gt; &amp; &quot;` give `< > & "`.
- `&nbsp;` is a space that **never wraps or collapses**, so it counts as a word character in the wrapper.
- `&#N;` gives ASCII N for 32–126; anything else becomes `?`.
- `\` followed by any ASCII punctuation character gives that character literally. A `\` before anything else is printed.
- An unknown `&name;` is printed as written.

**Buffers needed:** link text 80, URL 255, a tag name (longest is `lightgreen` at 10, so 12 is enough), an entity (`&#126;` or `&nbsp;`, about 8), and the line buffer of 255.

### 4.5 Styles in the client (spec §6, §8)

**Per page and per role**
- **At the start of every page, reset** colours, case and inline state.
- A role's style is a colour (optional) plus style words.

**How a cell's look is computed** (`render.py: cells`), where `role` is the block's role or `link` / `link-sel`:
1. `color = role.color or text.color`; `rev = role.reverse`; `upper = role.upper or (case != mixed)`.
2. If `i` is set, apply `em` on top: its colour (if any) replaces, and its `reverse` and `upper` are ORed in. If `b` is set, apply `strong` the same way.
3. An inline colour tag overrides the colour, and inline `rev` is ORed in.

**8SS format**
- The same `key: value` lines as the header, with no `---` lines. `#` starts a comment.
- **Style value:** words in any order. At most one colour (if there are several, the last wins) plus style words: `reverse`, `center` (block roles only), `upper`.

**8SS keys**

| Key | Takes |
|---|---|
| `text` | role style |
| `bg` | colour only (screen background) |
| `border` | colour only (screen border) |
| `h1` `h2` `h3` | role style |
| `em` `strong` | role style |
| `link` `link-sel` | role style |
| `quote` | role style |
| `pre` | role style |
| `rule` | role style |
| `field` `field-sel` | role style |
| `case` | `upper` or `mixed` |

- `charset` is reserved for later versions. Unknown keys are ignored.

**Machine prefixes**
- `zx.key: value` applies only on the Spectrum and beats the plain key **within the same source**.
- Sources still apply in priority order, so a plain key in a later source beats a `zx.` key in an earlier one.

**Cascade, rising priority** (single keys override, not whole sheets)
1. Client defaults
2. `/site.8ss` of the host
3. The page's `style:` sheet
4. Header keys

**Site stylesheet**
- A site is scheme, host and port.
- Fetch `site.8ss` once per site and remember a missing one too. Keep it at least until the client restarts **[proposal]**.
- A sheet that fails to load (network error, non-2xx status after redirects, or a refused content type) counts as missing.
- URLs inside a stylesheet resolve relative to the stylesheet itself.

**Reference client defaults** (`style.py: DEFAULTS`). We adopt these as our cascade level 1, mapped to ZX colours in §6.6:

```
text: lightgrey   bg: black   border: black   case: upper
h1: white reverse   h2: white   h3: white
em: white   strong: white
link: lightblue   link-sel: lightblue reverse
quote: grey   pre: lightgreen   rule: darkgrey
field: white   field-sel: white reverse
```

**Conformance**
- Without colour, still apply the style words you can show.
- The 48K can do all of them: reverse is an ink/paper swap, centre is a layout change, and upper is case folding.

### 4.6 Forms (spec §7): milestone M8, but the parser must skip them correctly from M3

**Form block**
- Opened by `:::form METHOD URL` and closed by `:::`.
- `METHOD` is `get` or `post`; a missing or unknown method means **get**. A missing URL means the page's own URL.
- A `:::form` line *inside* a form is ignored. A page can have several forms, and forms don't nest.
- Inside a form, `? ` lines are fields, option lines follow a `select`, and everything else is normal 8TML. Outside a form, `? ` lines are ordinary text.

**Field line format:** `? TYPE NAME OPTIONS LABEL`
- `NAME` is ASCII letters, digits, `-` and `.`.
- Options are `max=`, `rows=`, `value=` (quotes are allowed: `value="a b"`) and the bare word `checked`. A non-positive `max` or `rows` is ignored.
- After the name, read word by word: known options are consumed, and **the first other word starts the label**. The label is the rest of the line, with inline markup.
- **Types:**
  - `text` and `password`: default `max=80`.
  - `area`: defaults `rows=4 max=255`; line breaks are sent as CR LF.
  - `check`: `value` defaults to `on`.
  - `radio`: grouped by name.
  - `select`, followed by option lines `- VALUE LABEL`, with `+ VALUE LABEL` marking the preselected one (default: the first option).
  - `hidden`, `submit`, `reset`.
- A field with an unknown type or no name is ignored.

**Layout** (`render.py: field_block`)

| Field | Rendering |
|---|---|
| `text` | `[value____]`, box width `min(max, width-2)`. Label and box on one line if `len(label)+1+len(box) ≤ 32`, otherwise the label is wrapped above the box. |
| `password` | Same, with `*` for each character. |
| `area` | The label wrapped, then `rows` lines of `[` + `_`×30 + `]`. |
| `check` | `[x]` / `[ ]` + label. |
| `radio` | `(*)` / `( )` + label. |
| `select` | `[Chosen  v]`. |
| `submit` / `reset` | `< Label >` (defaults: Submit / Reset). |
| `hidden` | Not shown. |

- Roles are `field` and `field-sel`.
- **Links and fields share one focus order**, in page order.

**Sending**
- Data is `name=value` pairs joined with `&`, in page order, encoded as `application/x-www-form-urlencoded` (space becomes `+`, reserved bytes become `%XX`).
- **GET:** append `?data`, or `&data` if the URL already has a query. **POST:** the data is the body, with `Content-Type` and `Content-Length`.
- **Never auto-resend a POST.** Back and Reload don't resubmit.
- **Passwords:** shown masked, never stored in history or caches, and cleared when the page is left.
- **Minimums:** at least 16 fields per form, 80 characters per text/password field and 255 per area.
- **Without form support** (M3–M7): skip `:::form` like an unknown block, and **SHOULD tell the reader** "page has a form this client can't show".

### 4.7 Addresses and HTTP (spec §9): addresses on the Spectrum, HTTP on the ESP32

Addresses (resolution, `index.8tml`, fragments, typed `host/path`) are done by the Spectrum: `apps/zx-vvv/zx/url.asm`, modelled and host-tested as `apps/zx-vvv/host/url.c` against `url_cases.txt`. HTTP (redirects, TLS, the type filter) is the modem's `http` service, with the Accept value and the refused types sent by the browser.

**URLs**
- **Absolute forms:** `http://host[:port]/path` and `https://…`.
- A client MAY accept a typed `host/path` as `http://host/path`. **We do this** for the G-key URL entry.
- **Relative forms:** `/path`, `path`, `../path`, `?query`.
  - Resolve them per **RFC 3986 §5.2** against the page's **final** URL after redirects, or against the stylesheet's URL for URLs inside a stylesheet.
  - Remove `.` and `..` segments; **`..` never goes above the host root.**
- A bare host, or a path ending in `/`, loads **`index.8tml`** from there. For example, `http://v8id.example/` becomes `http://v8id.example/index.8tml`, as the reference tool shows.
- URLs keep their case and are sent exactly as written.
- **Fragments:** 8TML has no anchors, so drop `#…` before sending. **A fragment-only link (`#top`) means the current page:** the Spectrum just re-renders from the top with no request. Handle this on the Spectrum side.

**HTTP behaviour**
- HTTP/1.0 `GET`/`POST` with `Host:`.
  - With `esp_http_client`, prefer an HTTP/1.0 request line if it's configurable, otherwise use 1.1 without keep-alive and accept chunked decoding.
  - The spec only says servers answer **1.0** requests without chunked encoding.
- **2xx:** display the body.
- **301/302/303/307:** follow to `Location`, at most 5 times in a row; 303 becomes GET. Redirects are followed whatever their content type.
- **Any other status:** report it to the reader, **and if the body is an 8TML page, display it.** So the ESP32 must forward the status code *and* the body (see §7.4).
- **Content-Type decides, never the file extension.**
  - Refuse `text/html`, and anything starting with `image/`, `audio/`, `video/` or `font/` (case-insensitive, parameters ignored).
  - On refusal the client **reports "unsupported type" and STAYS ON THE CURRENT PAGE.** So the ESP32 sends an `error` response, and the Spectrum must not overwrite its page buffer for it.
  - Anything else, or no type at all, is read. Servers should send `text/8tml`, but `application/octet-stream` and `text/plain` are common too.
- **Body:** read until the connection closes; a client MAY stop at `Content-Length`. Accept 1.0 and 1.1 status lines and ignore unused headers.
- **No proxy needed:** the ESP32 does HTTPS natively.

### 4.8 Client limits (spec §10)

- **MUST implement:** §2–5 and §9.
- **SHOULD implement:** §6 and §8 (styles) and §7 (forms).
- **Memory:** use what's available. If a page doesn't fit, show what fits **and tell the reader the page was cut.**
- MAY refuse or cut anything over the limits.
- **MUST NOT crash or hang on any input**, which makes it a test requirement (§10).

### 4.9 Ecosystem

- **VVV** (C64) is the reference client.
- **SEE64YOU** is an 8TML editor on the C64 Ultimate, which uses the publishing API.
- **T8wn** (https://t8wn.com) hosts sites ("plots").
- **Example site in the docs:** "V8rms", a Worms-style artillery game for the C64, part of the "V8id network". Its addresses are `.example`, so it is not live.
- **Public docs:** https://t8wn.com/8tml/. **If they disagree with the spec files, the spec files win.**
- **Checked 2026-11-20** (details: `apps/zx-vvv/docs/website-notes.md`): no newer spec than our package; the `site.8ss` cache lifetime is still open. The site adds one rule: **never list `text/html` in `Accept`**. And **t8wn.com serves live 8TML**: `https://t8wn.com/index.8tml` is valid 8TML (`text/8tml`), negotiated on `Accept` (`text/html` gets the web site instead), and `http://` always redirects to `https://`. VVV (prototype) refuses non-8TML types before downloading the body ("Unsupported type: not an 8TML page") and shows "Server says HTTP/1.1 404 Not Found".

## 5. Architecture

```
 Web (HTTP/HTTPS)
       │ Wi-Fi
 ┌─────▼──────────────────────────┐        EAR (tape signal in)       ┌──────────────────────────┐
 │ ESP32                          │ ─────────────────────────────────▶│ ZX Spectrum 48K          │
 │  fetch, redirects, URL resolve │                                    │  8TML parser + renderer  │
 │  content-type check, UTF-8→ASCII│◀───────────────────────────────── │  link table, focus, keys │
 │  tape encoder (RMT TX)         │        MIC (tape signal out)       │  history, page buffer    │
 │  tape decoder (GPIO edge ISR)  │                                    │  ROM LD-BYTES / SA-BYTES │
 └────────────────────────────────┘                                    └──────────────────────────┘
```

**Half-duplex, strictly one side talks at a time.**
- ESP32 state machine: `LISTEN → (request decoded) → FETCH (Wi-Fi active) → TRANSMIT (Wi-Fi quiet) → LISTEN`.
- **Ignore RX while transmitting.** On the 48K, EAR and MIC both connect to ULA pin 28, so the ESP32's own TX may echo onto MIC.
- **Fetch the whole body before transmitting.** Network activity during TX could cause timing jitter.

**Bootstrap**
1. The user types `LOAD ""`.
2. The user presses a button on the ESP32.
3. The ESP32 plays the embedded `browser.tap` as a normal ROM tape: a BASIC loader (`10 CLEAR 32767: LOAD ""CODE: RANDOMIZE USR 32768`) followed by the code block.

## 6. Spectrum side (Z80, sjasmplus)

### 6.1 ROM routines (verify against the 48K ROM disassembly: https://skoolkid.github.io/rom/)

**`LD-BYTES` at `0x0556`**
- Inputs: `IX` = destination, `DE` = length, `A` = expected flag byte, carry **set** = LOAD (reset = VERIFY).
- Returns carry set on success.
- Handles DI/EI itself (returns via `SA/LD-RET`).
- **SPACE (BREAK) aborts.**
- **Waits indefinitely for a pilot tone.** So the Spectrum can simply wait while the ESP32 fetches, showing "Loading…".

**`SA-BYTES` at `0x04C2`**
- Inputs: `IX` = start, `DE` = length, `A` = flag.
- A flag < `0x80` gives a long (header) pilot; ≥ `0x80` gives a short pilot.
- **Use flags ≥ `0x80`** for our packets.

**Why this approach:** LD-BYTES needs the length up front. So every reply is a fixed-size header block followed by a data block of the announced length, exactly like real tapes.

### 6.2 Memory map (proposal)

| Range | Use |
|---|---|
| `4000–57FF` | Screen bitmap |
| `5800–5AFF` | Attributes (`FLASH, BRIGHT, PAPER[3], INK[3]` per cell) |
| `5B00–7FFF` | System variables, BASIC, stack. Contended memory, so avoid placing code here. |
| `8000–8FFF` | The ZX MODEM menu and its API table (the browser borrows its screen, link and text-entry routines); the menu stays below 0x9000 (build check) |
| `9000–9FFF` | The menu's spare area, the running app's (`APP_SPARE`, decided 2026-11-23): zx-vvv's big buffers (address and fetch buffers, text window, link runs, focus save, history, 64 bookmarks) |
| `A000–` | Browser code and data (~8 KB in M4: no font tables, glyphs are made from the ROM font while drawing), then its buffers (not loaded from tape; the fetch and renderer buffers share memory): 64 screen bookmarks, the screen's link runs, the focused link's saved attributes and address, a 512-byte history
| `–FF57` | Raw page buffer: the rest, up to the UDGs (~15.3 KB since 2026-11-23) |
| `5B00–5BFF` | The printer buffer: the renderer's source line buffer (256-aligned) |

*Decided 2026-11-22: zx-vvv is a kind 1 app (loaded at 0xA000, returns to the menu), not a program replacing the menu. If the page buffer gets too small, a kind 2 program with its own link code is still possible.*
| top | Stack |

**Contended memory explained:** in the lower 16 KB of RAM, the ULA steals CPU cycles while drawing the screen. So code placed there runs slower and less predictably.

### 6.3 Modules (proposal)

- `main.asm`: init, main loop, state.
- `net.asm`: `send_request` (SA-BYTES wrapper), `recv_response` (LD-BYTES loop, chunk reassembly), handling of load errors and BREAK.
- `parse.asm`:
  - header parser
  - line/block classifier
  - inline state machine
  - entity and escape decoding
  - emits `(char, style)` into layout.
- `layout.asm`: word wrap at spaces (break a word only if it is longer than a line), hanging indent, centering, preformatted cut, line buffer of 32 characters plus attributes.
- `screen.asm`: fast `putchar(row, col, glyph, attr)` writing directly to screen memory (**not** `RST 16`, which is slow and interprets control codes), clear lines, title and status bars.
- `links.asm`: link table holding the screen cell range and the URL (offset and length into the page buffer where possible, otherwise copied into a bounded pool), plus focus handling.
- `keys.asm`: keyboard scan, cursor keys (CAPS+5/6/7/8), line input for URL entry.
- `fonts.asm`: normal font = ROM font at `0x3D00` (char 32 starts at `0x3D00`); bold and italic fonts generated at startup.
- `hist.asm`: URL history stack for BACK.

### 6.3a Z80 link library (Phase 1, `zx/lib/`)

`net.asm` is a **standalone, reusable library**, not part of the browser. Both the browser and the Phase 1 test programs include it.

- **Calling convention** (documented in `docs/link-protocol.md`):
  - `link_request`: `HL` = request buffer, `BC` = length, then SA-BYTES with flag `0x80`.
  - `link_receive`: `IX` = buffer, `DE` = max length. Loads the 10-byte header, checks `chunk_len` against `DE`, then loads the data block. Returns `A` = type, carry set on success, `NC` + error code on a tape error or BREAK.
- **BASIC wrapper:** a small entry point callable as `RANDOMIZE USR addr`. The request string sits at a fixed address and the reply lands in a buffer, so BASIC programs can use the modem. This is the proof that the link is general.
- **No assumptions about 8TML** in this library.

### 6.3b Wi-Fi setup screen (app 1, `apps/wifisetup/`)

*Built as described below, then generalised into the app system (`docs/app-api.md`): it is app 1, fetched with system `O 1`. The original design notes follow.*

**On the Spectrum, not on a phone.**
- Boot: the program sends system `V`. If Wi-Fi isn't connected, it loads overlay 1 (system `O 1`) into the **page buffer** (`0xA000`+) and runs it.
- Screen: a network list from `L` (signal bars, lock icon, SSID, *Other…* for hidden networks), a rescan key, and password entry (masked with a reveal toggle, scrolling field up to 63 characters, SYMBOL SHIFT symbols, CAPS SHIFT+2 caps lock) → `J`.
- On success, control returns to the main program, and the first real page later overwrites the overlay.

**Why an overlay:**
- The page buffer is empty at boot, and setup and a page are never needed at the same time.
- **Result:** zero permanent RAM and a single tape load at boot.
- **Changing Wi-Fi later** from a menu key re-requests the overlay, about 8 s for ~1 KB.

**Overwriting rule:**
- Code that loads over a region must not run from that region, and the stack must not be in it either. When LD-BYTES returns, it jumps back into the caller's code, so overwritten code means a crash.
- Anything that loads over itself copies a ~15-byte loader stub elsewhere first: just below the stack, or the printer buffer at `0x5B00`.

**Bootstrap selection:**
- When `LOAD ""` is pressed, the ESP32 plays the configured program: the Phase 1 test program, or later the browser.
- The program handles setup itself via the overlay, so the bootstrap doesn't depend on the Wi-Fi state.

**Phone captive portal:** an optional fallback only, not planned.

### 6.4 Screen layout (proposal)

- **Row 0:** title bar (page `title:` from the header), inverse.
- **Rows 1–22:** content (22 lines).
- **Row 23:** status bar (URL, "Loading…", errors, key hints).

### 6.5 Keys (decided 2026-11-22)

| Key | Action |
|---|---|
| 6 / 7, or the cursor keys (CAPS+6 / CAPS+7) | Next / previous link (like the menu); past the last / first, the next / previous screen |
| ENTER | Follow the focused link |
| N / M | Next / previous screen |
| B | Back: the previous page, at the screen it was on |
| L | The page's links, numbered (6/7, ENTER, N/M, L back) |
| G | Go to a URL (line input) |
| R | Reload |
| H | Home |
| ? | Help: the keys, page size and free buffer (title row: "?: help") |
| Q | Back to the menu |

**Focus highlight:** the focused link's cells are reversed (only attribute bytes change), as the spec's default `link-sel` (lightblue reverse) is the link colour reversed.

### 6.6 Colour and style mapping

**Facts that drive the design**
- Each 8×8 cell has exactly **one ink, one paper and one BRIGHT bit**. Different cells can have different colours.
- At 32 columns, each character owns its own cell, so it can have its own colour pair. Only 64-column mode would clash.
- **BRIGHT affects both ink and paper of the cell.** Therefore the **default paper is black**, because bright black is still black, so BRIGHT only visibly changes the ink. If a page sets a non-black background, bright inks will also brighten the paper. Accept this.

**Spectrum colours:** 0 black, 1 blue, 2 red, 3 magenta, 4 green, 5 cyan, 6 yellow, 7 white.

**Don't copy the reference tool's ZX colours.**
- `machines.py` maps colours by plain RGB distance from the C64 palette, which on the ZX gives:
  - cyan, yellow, pink, grey, lightgrey, lightgreen and lightblue → white
  - orange → red
  - brown and darkgrey → black
- So `link: lightblue` would be indistinguishable from `text: lightgrey`.
- That table is only a preview helper, and the spec says "nearest colour" without defining it. Use the hand-tuned mapping below, and raise the issue with the 8TML author.

**Starting mapping (hand-tuned and tunable, check it on real hardware):**

| 8TML | Spectrum |
|---|---|
| black | 0 |
| blue | 1 |
| lightblue | 5+B (was 1+B: blue on black is too dark on a real 48K, 2026-11-23) |
| red | 2 |
| pink / lightred | 2+B |
| purple / magenta | 3 |
| green | 4 |
| lightgreen | 4+B |
| cyan | 5 |
| yellow | 6+B |
| orange | 6 |
| brown | 2 |
| darkgrey | 7 |
| grey | 7 |
| lightgrey | 7 |
| white | 7+B |

**Note on `darkgrey`:**
- `darkgrey` must stay visible on black, because the default `rule` is darkgrey. Hence it maps to non-bright white rather than black.
- With this mapping, the defaults give:
  - text: white
  - h1: bright white, reversed
  - h2/h3/em/strong: bright white
  - link: bright cyan (lightblue; bright blue was too dark on real hardware)
  - quote: white
  - pre: bright green
  - rule: white
- **Problem:** em, strong and h2 are all just bright white, so they're barely distinguishable from white text. That's why the bold and italic fonts matter (see the next paragraph).

**Where the spec's `b`/`i` sit:**
- The spec defines `b` and `i` as applying the `em`/`strong` *styles*, a colour plus style words, on top of the role.
- Bold and italic *fonts* are therefore our own extra presentation. That's allowed, since presentation is a hint, and it's useful on the ZX.

**Style flags**
- `rev`: swap ink and paper.
- `b`: bold font, generated by ORing each glyph row with itself shifted right by 1.
- `i`: slanted font, generated by shifting the top rows right by 1 pixel. If both `b` and `i` are set, bold wins for now (a fourth font is an option).

**Characters**
- The ROM font shows `` ` `` as `£` (as the spec expects), `^` as `↑`, and 127 as `©`.
- A custom font can override any of these later.

### 6.7 Paging and scrolling

- **The page is stored raw** in the page buffer, and rendering is a **single-pass parse from a saved point**.
- At each screen boundary, store a **snapshot**: the source offset plus the parser, block and inline state, which is only a few bytes.
- **Previous screen:** restore the snapshot and re-render.
- **Truncation:** if the page exceeds the buffer, render what fits and show "page cut" (required by the spec).
- **Progressive rendering later:** render the first screen as soon as the first chunk arrives. The parser's small state allows this.

## 7. Link protocol (ESP32 ⇄ Spectrum)

### 7.1 Physical tape encoding (standard ROM timing, 48K at 3.5 MHz, 1 T-state ≈ 0.2857 µs)

| Element | T-states | Duration |
|---|---|---|
| Pilot pulse | 2168 | 619.4 µs |
| Pilot count: header block (flag < 0x80) | 8063 pulses | ~5 s |
| Pilot count: data block | 3223 pulses | ~2 s |
| Sync 1 / sync 2 | 667 / 735 | 190.6 / 210.0 µs |
| Bit 0 | 2 × 855 | 2 × 244.3 µs |
| Bit 1 | 2 × 1710 | 2 × 488.6 µs |

**Block format and speed**
- A block is `flag byte, payload, checksum`. The checksum is the XOR of all bytes including the flag. Bits are sent MSB first.
- Average speed is roughly 1365 bps, about 170 B/s. A 4 KB page takes ~25 s, which is the motivation for a turbo loader later.

**Optimizations to test**
- **Shorter pilots for ESP32 replies: not with the ROM loader.** After the first edge LD-BYTES waits almost 1 s (`LD-WAIT`, 0571), then needs 256 pairs of pilot pulses, so a pilot under ~2200 pulses is missed (found on real hardware, 2026-11-18; Fuse's tape traps hide it). Shorter pilots need our own loader (M6/M9).
- **Signal polarity doesn't matter.** The loader detects edges.

**`.tap` file format:** for each block, a 2-byte little-endian length, then the block itself (flag + payload + checksum).

### 7.2 Packet flags

| Flag | Direction | Meaning |
|---|---|---|
| `0x00` / `0xFF` | ESP32 → Spectrum | Standard ROM header/data (bootstrap tape only) |
| `0x80` | Spectrum → ESP32 | Request |
| `0x90` | ESP32 → Spectrum | Response header (fixed 10 bytes) |
| `0x91` | ESP32 → Spectrum | Response data chunk |

### 7.3 Request payload (`0x80`, variable length, ≤ 300 bytes)

The ESP32 detects the end of the block from the following silence, so no length field is needed.

`[service:1][cmd:1][args…]`

**Why a service byte:** it lets new uses of the modem coexist without clashing with the browser's command letters. Keep the full link protocol in `docs/link-protocol.md` as the modem's own spec; this section is the summary.

| Service | Name | Purpose |
|---|---|---|
| `0x00` | system | Ping/version, Wi-Fi setup, fetching code overlays (Phase 1) |
| `0x01` | browser | 8TML navigation (Phase 2) |
| `0x02` | files | Reserved: tape library and storage of SAVEd files (later) |
| `0x03` | basic | Simple fetch for BASIC programs (M2c): `F url` → `body` with the raw response, transliterated to ASCII, clamped to the caller's buffer |

**System service (`0x00`)**

| Cmd | Args | Reply |
|---|---|---|
| `V` | none | `info`: modem firmware version, protocol version, Wi-Fi state (0 = not configured, 1 = connecting, 2 = connected), IP address |
| `L` | none | Scan for networks. `netlist` (type 4) = records `[rssi:1 signed][auth:1][len:1][ssid…]`, at most 20, strongest first. SSIDs are transliterated for display; **the ESP32 keeps the raw SSIDs and the list order.** |
| `J` | `index \0 password`, or `0xFF ssid \0 password` for a hidden network | Join. The ESP32 tries to connect (2–8 s; the Spectrum waits in LD-BYTES). Reply: `wifi` (type 5: connected + IP; credentials saved to NVS only after success), or `error` with the reason ("Wrong password", "Network not found", "No IP address"). |
| `O` | overlay id | Send a code overlay (type 6) for the caller to load at the address in the header. Id 1 = the Wi-Fi setup screen. |

**HTTP service (`0x01`)** (authoritative: `docs/link-protocol.md` §6.4; firmware 0.7)

| Cmd | Args | Meaning |
|---|---|---|
| `G` | `[flags][max:2] url \0 accept \0 refuse` | Fetch an **absolute** address (the browser resolved it). `flags` bit 0 = UTF-8 → ASCII; `max` = body limit; `accept` = the `Accept` header; `refuse` = space-separated types (`image/` = prefix). Reply: `url-info` (final URL `\0` content type) then `body`; or `error [code][text]` (1 no Wi-Fi, 2 bad address, 3 connect, 4 timeout, 5 redirects, 6 refused type, 7 bad request). Stylesheets use `G` too; reload is `G` with the current URL. |
| `C` | chunk index | Re-send from chunk n (after a load error) *(planned, M6)* |
| `P` | | POST a form *(planned, M8)* |

### 7.4 Response

A response is a sequence of `header(0x90)` + optional `data(0x91)` pairs.

**Header layout (10 bytes)**
```
0   type      0=body, 1=error (data = human-readable ASCII message; Spectrum KEEPS current page),
              2=reserved, 3=url-info (data = final absolute URL after redirects, 0, content type),
              4=netlist, 5=wifi status, 6=overlay (code; load address in bytes 4-5 instead of total_len),
              7=info (reply to system V)
1   flags     bit0 = final chunk, bit1 = body truncated by ESP32
2-3 chunk_len (LE)  — length of the following data block, 0 = none
4-5 total_len (LE)  — whole body length, clamped to 65535
6   chunk_index
7   proto_version (=1)
8-9 http_status (LE) — final HTTP status (200, 404, …); 0 for non-HTTP errors
```

**How the spec's HTTP rules map onto this protocol**
- **Content-type refused, network failure, or too many redirects:** the ESP32 sends a single `error` response. The Spectrum shows the message in the status bar and **stays on the current page**, as spec §9.2 requires.
- **Non-2xx with a body** (e.g. 404): the ESP32 sends `url-info` and `body` as normal, with `http_status` set. The Spectrum shows "HTTP 404" in the status bar and renders the body.
  - If the body isn't an 8TML page, the spec only requires reporting the status. Show the body as plain text anyway, since it's harmless.
- **`site.8ss` and `style:` sheets:** a non-2xx status or a refused type counts as **missing** (§8.1): the Spectrum checks the status in `url-info` (or gets an `error` for a refused type) and caches "missing".
- **One page buffer:** because of the stay-on-page rule, the Spectrum overwrites its page buffer only once a `url-info` arrives. `error` responses never touch it.

**Typical navigation sequence:** `url-info` → `body` chunk 0 … chunk n (final).

**Details**
- The **Spectrum** decides page vs plain text by checking the first line, as the spec requires. The ESP32 just sends the body.
- **Chunk size:** every reply is **one chunk** (decided 2026-11-22; was 1024 bytes). Every block costs a ~2 s pilot, and without `C n` small chunks only add pilots. Revisit (smaller chunks + `C n`) only if tape errors show up in use.
- **Gaps:** the ESP32 waits ≥100 ms after each header block and ≥200 ms after each data block, so the Spectrum can process them. Tune these.
- **History:** the Spectrum keeps a history of `url-info` URLs. BACK sends `G <absolute url>`.

## 8. ESP32 side (ESP-IDF, C)

### 8.1 Components (proposal)

- `components/tape/`: **portable C** with no IDF dependencies, shared with the host tools.
  - `tape_encode`: block → stream of pulse durations, via a callback.
  - `tape_decode`: pulse durations → blocks, with pilot/sync detection and checksum verification.
- `components/tapeio/`: hardware glue.
  - TX via **RMT** with a custom or simple encoder that streams symbols generated from bytes. Use 1 MHz resolution or better; idle level low.
  - RX via a **GPIO any-edge ISR** that timestamps each edge (`esp_timer_get_time` or the cycle counter) into a ring buffer, plus a decode task.
  - **Why not RMT RX:** on the classic ESP32, RMT RX symbol memory is too small for multi-kilobit blocks without ping-pong. Edges arrive at only ~4 kHz, which is trivial for an ISR.
  - **Install the ISR on core 1** (Wi-Fi runs on core 0).
  - **RX thresholds** (wide margins so they tolerate jitter):
    - pulse < 350 µs → bit-0 half
    - 350–560 µs → bit-1 half
    - > 560 µs → pilot
    - sync = one short pulse pair in the 150–230 µs range after the pilot
    - end of block = a gap > 2 ms
- `components/proto/`: request parsing, response framing, chunking.
- `components/fetch/`:
  - `esp_http_client` with TLS via `esp_crt_bundle`.
  - **Handle redirects manually** so that 303→GET and the final URL are under our control. Maximum 5.
  - Content-type refusal: the list comes from the client in each request (§7.3), checked before the body is read.
  - (Fragments and RFC 3986 resolution moved to the Spectrum, 2026-11-22.)
  - Body buffer cap of ~32 KB, setting `truncated` if exceeded.
  - HTTP version: see §4.7. Accept both status-line versions, and follow §7.4 for how statuses and refusals are reported.
  - The browser sends `Accept: text/8tml`. **Never list `text/html`:** t8wn.com negotiates on `Accept` and would send its HTML site instead (the site's HTTP page: send `text/8tml` or no `Accept`).
- `components/translit/`: UTF-8 → ASCII.
  - Curly quotes → `'` / `"`, en and em dashes → `-`, `…` → `...`, NBSP → space.
  - Accented Latin letters → their base letter (including Hungarian: á é í ó ö ő ú ü ű → a e i o o o u u u).
  - Everything else ≥ 128 → `?`.
- `main/`:
  - state machine
  - bootstrap button (plays the embedded `browser.tap` via `EMBED_FILES`)
  - status LED
  - Wi-Fi credentials: Kconfig/menuconfig defaults for early development; then NVS, written only after a successful `J` from the Spectrum's setup screen. A long press (5 s) of the button erases them.
  - Wi-Fi scan (`L`) and join (`J`) run in plain STA mode (no access point needed). Scanning while disconnected is fine.
  - home URL from Kconfig.

### 8.2 C3 portability notes

- The C3 is single-core, so RX ISR jitter is possible while Wi-Fi is active. The wide thresholds should absorb this, since RX only happens while idle.
- The C3 has no MCPWM capture, so stick to the GPIO ISR approach.

## 9. Hardware (no scope or logic analyzer: see the workarounds)

```
ESP32 TX GPIO ──[1 kΩ]────────────────────── Spectrum EAR socket (tip)
ESP32 RX GPIO ◀── comparator (LM393) ◀──[C]── Spectrum MIC socket (tip)
GND ─────────────────────────────────────── both sleeves (common ground)
ESP32 power: its own USB supply. Never from the Spectrum (the 48K's 7805 already runs hot).
```

**TX (ESP32 → EAR)**
- A 0/3.3 V square wave works. TZXDuino-style players even drive EAR with 5 V logic.
- The series resistor protects both sides, because the EAR socket also carries the Spectrum's beeper output.

**RX (MIC → ESP32)**
- MIC is a low-level analog signal (a few hundred mV), so it must be squared into a clean 3.3 V logic signal.
- Proposed circuit: AC-couple through a capacitor into an LM393 comparator. Bias the input to mid-rail, add a small hysteresis resistor, and use a pull-up to 3.3 V on the open-collector output. A single NPN transistor stage is a cheaper alternative.
- **Measured (2026-11-02, `host/tests/data/zx48k-save-test.wav`):** clean square wave with sharp edges and ~44 dB SNR; ROM timings within 0.3%. The absolute level is uncalibrated (~0.5 V p-p estimated). A bad capture showed 50 Hz hum larger than the signal, so the board needs a high-pass before the comparator.
- **The PCB front end is in `hardware/DESIGN.md`:** a passive 2-pole 234 Hz high-pass, a TLV7031 push-pull comparator with fixed 10.5 mV hysteresis (rev B; R11 = 1.5k), and an ADC tap. It was simulated on the real recording with `hardware/sim/frontend_sim.py`.
- **Verify all levels against a 48K schematic** (EAR and MIC share ULA pin 28 through resistors).

**Debugging without instruments**
1. **PC sound card as a scope:**
   - Record the Spectrum's MIC output into the PC's line-in with Audacity to see the amplitude and waveform.
   - **`audio2tape` from fuse-utils** decodes a recording into a `.tap`. This is a strong signal-integrity check for both directions.
   - For ESP32 TX, record through a divider (e.g. 10 kΩ/1.5 kΩ, giving ~0.4 V) into line-in.
2. **Raspberry Pi Pico as a logic analyzer:** sigrok-pico firmware turns an RP2040 into a logic analyzer for PulseView. Inputs are 3.3 V digital only, so probe after the comparator.
3. **ESP32 loopback:** jumper TX → RX and decode its own output. This validates the encoder and decoder without a Spectrum.
4. **ESP32 as its own analyzer:** log measured pulse widths over serial (the RX ISR already timestamps edges).
5. **PC → real Spectrum:** play WAVs generated by the host tool from the PC's headphone output into EAR. This tests Spectrum code on real hardware before the ESP32 TX works.

## 10. Host tools and testing

- `host/` builds against `components/tape/` (shared code).
  - `tap2wav`: verify against `audio2tape` round trips.
  - `8tml2tap`: wraps an 8TML file in protocol framing (`url-info` + body chunks) for an **offline mode** in Fuse. Done as `host/tools/fake_reply.py` reply kinds `page:FILE[@URL[@STATUS]]` and `httperr:CODE:TEXT`.
    - **Fuse limitation:** it can't answer requests, so in offline mode the browser's request SAVE simply goes nowhere useful, and the next blocks on the tape act as the reply.
  - A BASIC loader generator, if sjasmplus can't emit the loader itself. Verify sjasmplus `SAVETAP` capabilities.
- **Emulator:** Fuse (loads TAP and WAV) plus fuse-utils (`tape2wav`, `audio2tape`, `tapeconv`). ZEsarUX is an alternative.
- **Test pages:**
  - `apps/zx-vvv/spec/spec/examples/*.8tml` first.
  - Then `apps/zx-vvv/testpages/` with edge cases taken from the spec text: list renumbering, `1984\.`, `<3` and `a < b`, `5 * 3`, an unclosed header, an unclosed pre block or `:::` block at EOF, `#` comments in the header, `####` headings, `\` hard breaks, `&nbsp;`, `&#200;`, `[](url)`, an 81-character link text, a 256-character URL, a `---` block whose first key isn't `8tml`, a higher `8tml:` version, and a form on a client without forms.
  - Then hostile inputs: huge lines, bytes ≥128, an empty file, NULs, endless `[[[[`.
- **Every test page must pass `tools/8tml check`.** Hostile pages are the exception: record the expected warnings instead.
- **Golden files:** for each test page, store `render -m zx --plain --links` output as `apps/zx-vvv/testpages/<name>.zx.txt`.
  - The Spectrum build gets a debug option that mirrors the content area into a 32×22 RAM text buffer and dumps it, for example via a Fuse memory dump or by saving it over MIC.
  - A host script diffs that dump against the golden file.
  - **Paging:** the golden file is one long column, while the Spectrum shows 22-line screens. Compare the concatenation of the screens.
  - The reference prints a caption line first; strip it before comparing.
  - Colours are not compared, because of the palette issue in §6.6.
- **The "never crash or hang" rule is a test requirement:** fuzz the parser. Once it is stable, a C model of the Z80 parser on the host could also be fuzzed against `tml/parser.py`.

## 11. Repo layout

```
/CLAUDE.md
/docs/            link-protocol.md (the modem standard: tape layer, framing, registry, services),
                  app-api.md (the Spectrum-side API for apps and BASIC), hardware.md
/sdk/             what apps build against: zxmodem_api.inc (API contract), ui.inc, zxsys.inc
/zx/lib/          modem-side Z80 code in the menu: link (net.asm), screen, UI, BASIC wrapper
/zx/menu/         the ZX MODEM menu (holds the API table) → zxmenu.tap, embedded in the firmware
/zx/basic/        BASIC examples (fetchdemo)
/apps/wifisetup/  app 1: Wi-Fi setup
/apps/zx-vvv/     app 2: the 8TML browser — its own project: spec/ (read-only), testpages/, zx/ (browser, url.asm), host/ (url.c reference + cases), docs/
/components/      portable C shared by firmware and host: tape, translit
/esp32/           ESP-IDF firmware (main/: link, netmgr, fetch, apps registry; components/tapeio)
/host/            host tools and tests (fake_reply.py for Fuse offline tests)
/hardware/        PCB: DESIGN.md, bom.csv, sim/, KiCad project, fab files
```

## 12. Milestones (each with an acceptance test)

| # | Milestone | Done when |
|---|---|---|
| M0 | Scaffold repo, toolchains (ESP-IDF 5.x, sjasmplus, Fuse + fuse-utils, Audacity, optionally sigrok-pico/PulseView) | All three parts build, even if they're empty |
| M1a | Portable tape lib and `tap2wav` | `tap2wav` → `audio2tape` round trip is byte-identical; a WAV played from the PC loads on the real Spectrum |
| M1b | ESP32 TX (RMT) | Button press plays an embedded test TAP and `LOAD ""` works on the real 48K |
| M1c | ESP32 RX (edge ISR + decoder) | Loopback decode works; a BASIC `SAVE "x"` from the Spectrum is decoded with a valid checksum and hex-dumped to serial |
| M1d | MIC interface hardware | MIC level measured with the sound card, comparator values chosen, reliable decodes |
| **M2** | **Modem: link layer + system service** | `docs/link-protocol.md` written. The Z80 link library works: `modemtest` sends system `V` and prints the `info` reply. A chunked multi-block reply is reassembled correctly, and a tape error or BREAK is reported without a hang |
| **M2b** | **Modem: Wi-Fi from the Spectrum** | Overlay 1 loads into `0xA000` and lists networks; `J` with a wrong password reports an error; a right password connects and saves to NVS; after a power cycle the ESP32 reconnects by itself; a 5-s button press forgets the credentials |
| **M2c** | **Modem: proof of generality** | A BASIC program uses the `USR` wrapper to fetch a plain-text URL (e.g. a weather or quote page) and `PRINT`s it. **End of Phase 1.** Review before starting Phase 2 |
| M2d | Browser skeleton | **Done 2026-11-22, proven on the real 48K.** Http service `G` returns `url-info` + body; the Spectrum resolves addresses (62/62 cases in C and in Z80) and pages raw text. Fuse offline mode via `fake_reply.py page:`/`httperr:` |
| M3 | Renderer core | Page detection and plain-text fallback, the header (`#` comments, unclosed header, **default uppercase**, `case: mixed`), all blocks from §4.3 (incl. list renumbering, continuation lines, gap/no-gap spacing, `\` and `<br>` breaks, `<center>`), skipping of unknown and `:::form` blocks with a "has a form" notice, wrapping, preformatted cut, title and status bars, default role styles from §4.5, paging with snapshots, page-cut notice. **Text layout matches the `render -m zx --plain` golden files for the examples** (inline markup is stripped at this stage). **Done 2026-11-22, proven on the real 48K** (13 test pages + the spec examples + the live T8wn page match screen for screen; `apps/zx-vvv/host/fusetest.ps1`). Inline *text* handling (tags, entities, escapes, link text, emphasis flanking) moved here from M4; M4 keeps colours, fonts and links. Title row: page title + "?: help"; the help page shows the page size and free buffer |
| M4 | Inline and links | Emphasis with the flanking rules, exact-name tags, the colour/flag state model, escapes and entities (incl. `&nbsp;` no-wrap), link buffering and limits, empty link text, non-http links shown but not followable, fragment-only links, bold/italic fonts, link table, focus, follow, back/history. **All golden files match, including `--links` order**. **Done 2026-11-22, proven on the real 48K**: inline colours through the ZX table, bold/italic glyphs made from the ROM font while drawing (cell = char with italic bit, attribute with bold in the FLASH bit, link id), link runs per screen (addresses found by re-reading from the screen's bookmark, no address table), focus 6/7, ENTER, B with a 512-byte history that returns to the same screen, L link list. Checked cell by cell against the reference (`golden_style.py`: colours, fonts, `--select 1`, `--links`) and by `navtest.ps1` |
| M5 | Real network | HTTP/HTTPS, redirects, refusal of HTML and other blocked types, URL resolution, transliteration, error pages, URL entry screen |
| M6 | Robustness | Chunk re-request (`C`), shorter pilots, parser fuzzing passes, progressive first-screen render |
| M7 | Stylesheets | 8SS parsing, the cascade, `zx.` prefixes, `site.8ss` caching |
| M8 | Forms | Fields, shared focus order, password masking, POST (never auto-resent) |
| M1p | PCB rev A (runs in parallel with M1a–M1c) | `hardware/DESIGN.md` reviewed → KiCad schematic + layout pass ERC/DRC → Gerbers, BOM, CPL accepted by JLCPCB → boards arrive, USB enumerates, and TX/RX pass the M1b/M1c tests on the board |
| M9 | Extras | Turbo loader (custom Z80 loader + ESP32 timings), files service (tape library and SAVE storage), C3 port, enclosure |

## 13. Open questions

1. **The 8TML author** (the spec package already answered the earlier questions about the reference source, previews and stability):
   - **ZX colour mapping:** the reference tool's RGB-nearest table collapses most colours to white on the ZX (§6.6). Would the author accept a hand-tuned ZX table in `machines.py`, so previews match our client?
   - ~~A live site for the home URL~~ **Answered 2026-11-20:** `https://t8wn.com/index.8tml` serves the town's home page as `text/8tml`.
   - **Licensing** of the spec and tools isn't decided yet, so `apps/zx-vvv/spec/` stays out of the public repo until the author agrees.
   - **Listing:** would the author list the ESP32 tape-port link as a Spectrum "way online" on the platforms page?
2. **Default home URL:** `https://t8wn.com/index.8tml` (live, see §4.9). Serving `apps/zx-vvv/spec/spec/examples/` from the ESP32's flash (e.g. `http://local/`) is still useful as an offline demo.
3. Confirm the key bindings (§6.5) and the screen layout (§6.4).
