# ZX MODEM apps: the Spectrum-side API, version 1

How Spectrum programs use the modem: **apps** started from the ZX MODEM menu,
and **BASIC programs** through `USR`. The wire protocol underneath is in
[`link-protocol.md`](link-protocol.md). The contract for assembler programs
is one include file, [`sdk/zxmodem_api.inc`](../sdk/zxmodem_api.inc); this
page explains it.

## 1. What an app is

An app is Z80 code that the modem keeps in its flash and the menu fetches
on demand (system `O <id>`):

| Kind | Loads at | Runs | Example |
|---|---|---|---|
| 1, app | `APP_ADDR` (0xA000) | `CALL`ed by the menu; `RET` goes back to it | Wi-Fi Setup, the browser zx-vvv |
| 2, program | its own address | replaces the menu; "back" reloads the menu *(planned)* | |

The menu lists the modem's apps (from the `info` reply), so adding an app
needs no change to the menu. A kind 1 app uses the menu's routines through
the API table, so it stays small and can be built on its own.

An app can need **modem-side code** the modem doesn't have yet: that is a
new service with its own number (registry: `link-protocol.md` §4), kept
general so other programs can use it too. The browser needed none of its
own: it uses the general `http` service (§6.4) and keeps every 8TML rule on
the Spectrum.

## 2. Memory while an app runs

| Range | Use |
|---|---|
| 0x4000-0x5AFF | screen; the app owns it while it runs (the menu redraws after) |
| 0x5B00-0x7FFF | system variables, BASIC, the machine stack (below 32768) |
| 0x8000-0x9FFF | the menu, its API table and buffers: **don't touch** |
| 0xA000-0xFF57 | **the app**: code, data, buffers (about 24 KB) |
| 0xFF58-0xFFFF | user-defined graphics |

The ROM and its interrupt routine stay active (IM 1), so keep **IY** at its
BASIC value (0x5C3A). Interrupts are on when the app starts; the link calls
disable them while the tape runs and switch them on again. `get_key` reads
the ROM's keyboard scan, so it needs interrupts on (a `HALT` before it waits
for the next frame).

## 3. The API table

The menu starts with fixed addresses that never change within API version 1:

**Shared variables**

| Address | Name | Size | Meaning |
|---|---|---|---|
| 32782 | `api_version` | 1 | 1; a newer menu has a higher number and only adds entries |
| 32783 | `scr_row` | 1 | cursor row 0-23 |
| 32784 | `scr_col` | 1 | cursor column 0-31 |
| 32785 | `scr_attr` | 1 | attribute for new text (FLASH BRIGHT PAPER INK) |
| 32786 | `link_header` | 10 | the last response header (`link-protocol.md` §5.2) |

**Routines** (each address is a `JP`; `CALL` it)

| Address | Name | In | Out / notes |
|---|---|---|---|
| 32796 | `scr_at` | B row, C column | |
| 32799 | `scr_putc` | A character: 32-127, or glyph 1-15 | keeps BC DE HL; cursor moves right (no wrap) |
| 32802 | `scr_print` | HL text, 0-terminated | HL ends after the 0 |
| 32805 | `scr_spaces` | B count | |
| 32808 | `scr_clear_row` | B row, A attribute | blank row, cursor to its column 0 |
| 32811 | `scr_paint` | A attribute, B row, C cells, E first column | colours only, text stays |
| 32814 | `scr_cls` | A attribute | whole screen; border = its paper |
| 32817 | `scr_dec` | A 0-255 | printed without leading zeros |
| 32820 | `scr_dec2` | A 0-99 | two digits |
| 32823 | `link_request` | HL request, BC length | sends one request (`link-protocol.md` §5.1) |
| 32826 | `link_receive` | IX buffer, DE size | carry: A = type, BC = bytes; no carry: A = `LINK_ERR_*` |
| 32829 | `get_key` | | A = new key code from the ROM, or 0 |
| 32832 | `wait_key` | | waits; A = key code |
| 32835 | `draw_title` | HL text | row 0: title and the colour stripes |
| 32838 | `text_at` | HL text, B row, C column, A attribute | |
| 32841 | `edit_line` | HL buffer, B max length (up to 63), C 1 = show `*`, D first row | two-row text field; carry = ENTER, no carry = CAPS+1; CAPS+0 deletes, CAPS+2 caps lock, CAPS+4 shows a masked text |
| 32844 | `putc_wrap` | A character | `scr_putc`, going to the next row after column 31 |

All routines keep IY; the screen and UI routines also keep IX, while
`link_request` and `link_receive` change it. Unless noted, AF, BC, DE and HL
may change.
`link_receive` error codes: 1 tape error in a header, 2 SPACE pressed,
3 response longer than the buffer, 4 tape error in data. `link_request` and
`link_receive` each take about 2-3 s of tape time per block.

Colours, glyph numbers and key codes the menu uses are in `sdk/ui.inc` and
`sdk/zxsys.inc`.

## 4. Writing an app

```asm
	DEVICE ZXSPECTRUM48
	include "zxsys.inc"
	include "ui.inc"
	include "zxmodem_api.inc"

	org	APP_ADDR
hello:
	ld	a,A_BODY
	call	scr_cls
	ld	hl,title
	call	draw_title
	ld	bc,4*256+1		; row 4, column 1
	ld	a,A_ITEM
	ld	hl,msg
	call	text_at
	call	wait_key
	ret				; back to the menu
title:	db	"HELLO",0
msg:	db	"Any key: back",0
end:
	SAVEBIN	"hello.bin", hello, end - hello
```

Build: `sjasmplus --inc=sdk apps/hello/hello.asm`.

To ship it in the modem:

1. Put it in `apps/<name>/`, with a README.
2. `esp32/main/CMakeLists.txt`: assemble it and embed the `.bin`
   (`target_add_binary_data`), like `wifisetup.bin`.
3. `esp32/main/apps.c`: one line with a new id, kind 1, its name (up to 24
   characters), the embedded code and `APP_ADDR`.
4. Add the id to the registry in `link-protocol.md` §4.3.

## 5. BASIC programs

After "BASIC" in the menu, the menu stays in memory and its first entries
work from BASIC:

| Use | What it does |
|---|---|
| `RANDOMIZE USR 32768` | back to the menu |
| `LET n=USR 32771` | fetch the address in `U$` (1-255 characters) through the basic service into the buffer at 49152 (up to 16000 bytes); n = bytes received |
| `RANDOMIZE USR 32774` | print the buffer: LF = new line, CR dropped, other controls skipped |
| `PEEK 32777` | 0 OK, 1 modem error (its message is in the buffer), 2 SPACE pressed, 3 no reply / tape error, 4 no usable `U$` |
| `PEEK 32778+256*PEEK 32779` | HTTP status |
| `PEEK 32780+256*PEEK 32781` | bytes received (as n) |

`PEEK 32771 = 195` (a `JP`) tells a program the menu is in memory.
`zx/basic/fetchdemo.asm` is a complete example.

## 6. Versions

- Within API version 1, new routines only go at the end of the table
  (`API_END` moves on). An app that needs a newer routine checks
  `api_version` first.
- The menu checks every address against `zxmodem_api.inc` when it is built
  (`ASSERT`s in `zx/menu/main.asm`), so the table and the include file
  can't drift apart.
