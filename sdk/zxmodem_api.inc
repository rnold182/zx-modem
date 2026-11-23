; zxmodem_api.inc - the ZX MODEM app API, version 1 (docs/app-api.md).
;
; Apps include this (with zxsys.inc and ui.inc) and call the menu's routines
; at these fixed addresses. The menu keeps a jump table here, so apps keep
; working when the menu changes inside; the menu checks every address at
; build time (ASSERTs in zx/menu/main.asm). New entries only ever go at the
; end, with a new API version.

; ---- For BASIC (also usable by apps) ------------------------------------------
ZXM_MENU	equ	32768		; JP: start the menu
ZXM_FETCH	equ	32771		; JP: basic_fetch (U$ -> BASIC_BUF), BC = length
ZXM_PRINT	equ	32774		; JP: basic_print
basic_status	equ	32777		; byte: 0 OK, 1 modem error, 2 SPACE, 3 no reply, 4 no U$
basic_http	equ	32778		; word: HTTP status
basic_len	equ	32780		; word: bytes received

; ---- Version and shared variables ---------------------------------------------
api_version	equ	32782		; byte: 1
scr_row		equ	32783		; byte: cursor row (0-23)
scr_col		equ	32784		; byte: cursor column (0-31)
scr_attr	equ	32785		; byte: attribute for new text
link_header	equ	32786		; 10 bytes: the last response header

; ---- Routines (each a JP in the table) ----------------------------------------
; Screen: 32x24 text straight to screen memory. Keep IX, IY.
scr_at		equ	32796		; B = row, C = column
scr_putc	equ	32799		; A = character (32-127, or glyph 1-15); keeps BC DE HL
scr_print	equ	32802		; HL = 0-terminated text; HL ends after the 0
scr_spaces	equ	32805		; B = how many spaces
scr_clear_row	equ	32808		; B = row, A = attribute; cursor to its column 0
scr_paint	equ	32811		; A = attribute, B = row, C = cells, E = first column
scr_cls		equ	32814		; A = attribute; border = its paper
scr_dec		equ	32817		; A = number 0-255, no leading zeros
scr_dec2	equ	32820		; A = number 0-99, two digits
; Link (docs/link-protocol.md 7):
link_request	equ	32823		; HL = request, BC = length
link_receive	equ	32826		; IX = buffer, DE = size -> carry: A = type, BC = bytes;
					;   no carry: A = LINK_ERR_*
; Keys and UI:
get_key		equ	32829		; A = new key or 0 (needs interrupts on)
wait_key	equ	32832		; wait for a key, A = its code
draw_title	equ	32835		; HL = title text: row 0 with the colour stripes
text_at		equ	32838		; HL = text, B = row, C = column, A = attribute
edit_line	equ	32841		; HL = buffer, B = max length, C = 1 to mask with *,
					;   D = first of 2 rows; carry = ENTER, no carry = CAPS+1
putc_wrap	equ	32844		; scr_putc, going on to the next row after column 31

API_END		equ	32847		; first address after the table

LINK_ERR_HEADER		equ	1	; tape error in a header block
LINK_ERR_BREAK		equ	2	; SPACE pressed
LINK_ERR_TOO_LONG	equ	3	; response longer than the buffer
LINK_ERR_DATA		equ	4	; tape error in a data block

; ---- Memory for apps ----------------------------------------------------------
APP_ADDR	equ	0xA000		; apps load and run here (CALLed; RET = back to menu)
APP_END		equ	0xFF58		; up to the UDGs; the stack is below 32768
APP_SPARE	equ	0x9000		; 0x9000-0x9FFF: free for the app while it runs
APP_SPARE_END	equ	0xA000		;   (the menu stays below; not loaded, not kept)
