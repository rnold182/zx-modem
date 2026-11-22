; vvv.asm - zx-vvv, the 8TML browser for the ZX Spectrum 48K (app 2).
;
; Build: sjasmplus --inc=sdk --inc=apps/zx-vvv/zx apps/zx-vvv/zx/vvv.asm -> vvv.bin
; A ZX MODEM app (docs/app-api.md): the menu loads it at APP_ADDR and CALLs
; it; Q returns. It uses the menu's screen, link and text-entry routines.
;
; The Spectrum does the browser's work: it resolves addresses (url.asm),
; chooses what to ask for and what to refuse, turns the modem's error codes
; into messages, and lays out 8TML pages itself (render.asm, M3). The
; modem only fetches (http service, docs/link-protocol.md 6.4).
;
; Screen: row 0 title, rows 1-22 the page, row 23 status.
; Keys: G go to an address, R reload, H home, N/M next/previous screen,
; K or ? the list of keys, Q back to the menu. SPACE stops a load.

	DEVICE ZXSPECTRUM48

	include	"zxsys.inc"
	include	"ui.inc"
	include	"zxmodem_api.inc"

PAGE_TOP	equ	1
PAGE_ROWS	equ	22
STATUS_ROW	equ	23
STATUS_TEXT	equ	25		; columns for the message; the screen counter after
A_PAGE		equ	A_BODY
A_STAT_ERR	equ	0x4E		; bright yellow on blue
INPUT_MAX	equ	63		; edit_line's limit
RXBUF_SIZE	equ	400		; url-info: final address, 0, type; or an error
HTTP_ASCII	equ	0x01		; http G flag: UTF-8 -> ASCII

RESP_ERROR	equ	1
RESP_URLINFO	equ	3

	org	APP_ADDR

vvv:
	ld	(app_sp),sp
	xor	a
	ld	(cur_url),a
	ld	(page_cut),a
	ld	hl,0
	ld	(page_len),hl
	ld	(http_status),hl
	call	show_page
	ld	hl,s_home
	call	go_typed
main_loop:
	call	wait_key
	or	0x20			; letters to lower case
	cp	'g'
	jp	z,key_go
	cp	'r'
	jr	z,key_reload
	cp	'h'
	jr	z,key_home
	cp	'n'
	jr	z,key_next
	cp	'm'
	jp	z,key_prev
	cp	'k'
	jr	z,key_help
	cp	'?'
	jr	z,key_help
	cp	'q'
	jr	nz,main_loop
	ld	sp,(app_sp)		; back to the menu
	ret

; key_help: the keys, until any key; then the page again.
key_help:
	ld	a,A_PAGE
	call	scr_cls
	ld	hl,s_title
	call	draw_title
	ld	hl,help_lines		; [row][column][attribute] text 0, ...; row 0 ends
.line:
	ld	b,(hl)
	inc	b
	dec	b
	jr	z,.wait
	inc	hl
	ld	c,(hl)
	inc	hl
	ld	a,(hl)
	inc	hl
	call	text_at			; HL ends after the 0
	jr	.line
.wait:
	ld	bc,21*256+1		; how full the page buffer is
	ld	a,A_HINT
	ld	hl,s_pagesize
	call	text_at
	ld	hl,(page_len)
	call	print_dec16
	ld	hl,s_bytes
	call	scr_print
	ld	hl,PAGE_MAX
	ld	de,(page_len)
	or	a
	sbc	hl,de
	call	print_dec16
	ld	hl,s_free
	call	scr_print
	call	wait_key
	call	show_page
	jp	main_loop

key_home:
	ld	hl,s_home
	call	go_typed
	jp	main_loop

key_reload:
	ld	hl,cur_url
	ld	a,(hl)
	or	a
	jr	z,key_home		; nothing loaded yet
	call	go_typed
	jp	main_loop

key_next:
	ld	hl,(page_no)
	inc	hl
	ld	de,(screens)
	or	a
	sbc	hl,de
	jp	nc,main_loop		; the last screen
	add	hl,de
	ld	(page_no),hl
	call	show_page
	jp	main_loop

key_prev:
	ld	hl,(page_no)
	ld	a,h
	or	l
	jp	z,main_loop
	dec	hl
	ld	(page_no),hl
	call	show_page
	jp	main_loop

key_go:
	ld	b,19
	ld	a,A_PAGE
	call	scr_clear_row
	ld	b,22
	ld	a,A_PAGE
	call	scr_clear_row
	ld	bc,19*256+0
	ld	a,A_MSG
	ld	hl,s_address
	call	text_at
	ld	hl,input
	ld	b,INPUT_MAX
	ld	c,0
	ld	d,20
	call	edit_line
	jr	nc,.cancel
	ld	a,(input)
	or	a
	jr	z,.cancel
	call	show_page		; the page back under the field
	ld	hl,input
	call	go_typed
	jp	main_loop
.cancel:
	call	show_page
	jp	main_loop

; go_typed: HL = an address the reader typed (or home, or reload).
go_typed:
	ex	de,hl
	ld	hl,s_empty		; no base: a typed address
	; fall through

; go_resolve: HL = base, DE = link. Resolve, then fetch or say why not.
go_resolve:
	call	url_resolve
	or	a
	jr	z,fetch_url
	cp	URL_SAME
	jr	nz,.no
	ld	hl,0			; the same page: back to its top
	ld	(page_no),hl
	jp	show_page
.no:
	ld	hl,s_nofollow
	cp	URL_NOFOLLOW
	jp	z,status_error
	ld	hl,s_long
	jp	status_error

; fetch_url: get url_out with the http service. The page buffer is only
; replaced once the modem answers with url-info; an error keeps the page.
fetch_url:
	call	status_loading
	ld	de,req_url
	ld	hl,url_out
	call	u_strcpy
	inc	de
	ld	hl,s_accept
	call	u_strcpy
	inc	de
	ld	hl,s_refuse
	call	u_strcpy		; the last field needs no 0
	ex	de,hl
	ld	de,req
	or	a
	sbc	hl,de
	ld	b,h
	ld	c,l
	ld	hl,req
	call	link_request
	ld	ix,rxbuf
	ld	de,RXBUF_SIZE-1
	call	link_receive
	jr	nc,link_failed
	ld	hl,rxbuf		; 0 after the data
	add	hl,bc
	ld	(hl),0
	cp	RESP_ERROR
	jr	z,modem_error
	cp	RESP_URLINFO
	ld	hl,s_badreply
	jp	nz,status_error
	; the new page: its final address, status, then the body
	ld	hl,rxbuf
	ld	de,cur_url
	ld	b,URL_MAX
.copy:
	ld	a,(hl)
	ld	(de),a
	or	a
	jr	z,.copied
	inc	hl
	inc	de
	djnz	.copy
	xor	a
	ld	(de),a
.copied:
	ld	hl,(link_header+8)
	ld	(http_status),hl
	ld	hl,0
	ld	(page_len),hl
	ld	(page_no),hl
	ld	ix,page_buf
	ld	de,PAGE_MAX
	call	link_receive
	jr	nc,.body_failed
	ld	(page_len),bc
	ld	a,(link_header+1)
	and	2			; cut by the modem
	ld	(page_cut),a
	call	new_page
	jp	show_page
.body_failed:
	push	af
	call	new_page		; an empty page
	call	show_page
	pop	af
	ld	hl,s_stopped
	cp	LINK_ERR_BREAK
	jp	z,status_error
	ld	hl,s_loaderr
	jp	status_error

; link_failed: no answer (A = LINK_ERR_*); the page stays.
link_failed:
	ld	hl,s_stopped
	cp	LINK_ERR_BREAK
	jr	z,.show
	ld	hl,s_noreply
.show:
	jp	status_error

; modem_error: rxbuf = [code][message]. Our own words for the codes we know.
modem_error:
	ld	a,(rxbuf)
	cp	6
	jr	z,.type
	ld	hl,err_msgs
	or	a
	jr	z,.text
	cp	8
	jr	nc,.text
	ld	b,a			; the code's message: skip code-1 of them
	dec	b
	jr	z,.found
.find:
	call	skip0
	djnz	.find
.found:
	jp	status_error
.type:
	ld	hl,s_unsupported
	call	status_error
	ld	hl,rxbuf+1
	ld	b,32-18
	jp	print_max
.text:						; unknown code: the modem's text
	ld	hl,rxbuf
	ld	a,(hl)
	cp	32
	jr	nc,status_error
	inc	hl
	jr	status_error

; ---- Status line -----------------------------------------------------------

; status_error: message HL on the status line, in error colours.
status_error:
	ld	b,STATUS_ROW
	ld	a,A_STAT_ERR
	push	hl
	call	scr_clear_row
	pop	hl
	ld	b,32
	jp	print_max

status_loading:
	ld	b,STATUS_ROW
	ld	a,A_STATUS
	call	scr_clear_row
	ld	hl,s_loading
	call	scr_print
	ld	hl,url_out
	call	skip_scheme
	ld	b,32-8
	jp	print_max

; show_status: the address (or what's wrong with the page), screen n/m.
show_status:
	ld	b,STATUS_ROW
	ld	a,A_STATUS
	call	scr_clear_row
	ld	hl,(http_status)
	ld	a,h
	or	l
	jr	z,.addr			; nothing loaded
	ld	de,200
	or	a
	sbc	hl,de
	jr	c,.http
	ld	de,100
	sbc	hl,de
	jr	nc,.http
	ld	hl,s_cut		; then what the reader should know
	ld	a,(page_cut)
	ld	b,a
	ld	a,(too_long)
	or	b
	jr	nz,.note
	ld	hl,s_form
	ld	a,(has_form)
	or	a
	jr	nz,.note
	ld	hl,s_newer
	ld	a,(newer)
	or	a
	jr	z,.addr
.note:
	call	scr_print
	jr	.count
.http:
	ld	hl,s_server
	call	scr_print
	ld	hl,(http_status)
	call	print_status_code
	jr	.count
.addr:
	ld	hl,cur_url
	call	skip_scheme
	ld	b,STATUS_TEXT
	call	print_max
.count:
	ld	hl,(screens)
	ld	a,h
	or	l
	ret	z
	ld	bc,STATUS_ROW*256+STATUS_TEXT+1
	call	scr_at
	ld	hl,(page_no)
	inc	hl
	call	print_small
	ld	a,'/'
	call	scr_putc
	ld	hl,(screens)
	; fall through

; print_small: HL as a number, 255 at most (shown as 255).
print_small:
	ld	a,h
	or	a
	ld	a,l
	jr	z,.ok
	ld	a,255
.ok:
	jp	scr_dec

; print_status_code: HL = 100-999, three digits.
print_status_code:
	ld	a,'0'-1
	ld	de,100
.h:
	inc	a
	or	a
	sbc	hl,de
	jr	nc,.h
	add	hl,de
	push	hl
	call	scr_putc
	pop	hl
	ld	a,l
	jp	scr_dec2

; print_max: HL = text, at most B characters.
print_max:
	ld	a,(hl)
	or	a
	ret	z
	call	scr_putc
	inc	hl
	djnz	print_max
	ret

; skip_scheme: HL past "http://" or "https://", if there.
skip_scheme:
	push	hl
	call	has_scheme_sep		; found: HL on the first '/'
	pop	de
	jr	z,.found
	ex	de,hl
	ret
.found:
	inc	hl
	inc	hl
	ret

skip0:
	ld	a,(hl)
	inc	hl
	or	a
	jr	nz,skip0
	ret

; ---- The page ------------------------------------------------------------

; new_page: a page has arrived (page_len bytes): read its header and find
; where each screen starts.
new_page:
	ld	hl,(page_len)
	ld	de,page_buf
	add	hl,de
	ld	(page_end),hl
	ld	hl,0
	ld	(page_no),hl
	call	parse_header
	jp	render_measure

; show_page: the title bar and screen page_no of the page, then the status.
show_page:
	ld	a,A_PAGE
	call	scr_cls
	call	make_title
	ld	hl,title_disp
	call	draw_title
	ld	bc,0*256+17		; the help hint, before the stripes
	ld	a,A_HINT
	ld	hl,s_keyhint
	call	text_at
	ld	hl,(page_no)
	call	render_draw
	jp	show_status

; make_title: title_disp = the page's title (in its case, up to 15
; characters), or the browser's name.
make_title:
	ld	hl,s_title
	ld	a,(is_page)
	or	a
	jr	z,.copy
	ld	a,(title_buf)
	or	a
	jr	z,.copy
	ld	hl,title_buf
.copy:
	ld	de,title_disp
	ld	b,15
.l:
	ld	a,(hl)
	or	a
	jr	z,.end
	call	to_case
	ld	(de),a
	inc	hl
	inc	de
	djnz	.l
.end:
	xor	a
	ld	(de),a
	ret

; print_dec16: HL as a decimal number, no leading zeros.
print_dec16:
	ld	b,0			; 1 once a digit is shown
	ld	de,10000
	call	.digit
	ld	de,1000
	call	.digit
	ld	de,100
	call	.digit
	ld	de,10
	call	.digit
	ld	a,l
	add	a,'0'
	jp	scr_putc
.digit:
	ld	a,'0'-1
.sub:
	inc	a
	or	a
	sbc	hl,de
	jr	nc,.sub
	add	hl,de
	cp	'0'
	jr	nz,.show
	inc	b
	dec	b
	ret	z			; a leading zero
.show:
	ld	b,1
	jp	scr_putc		; keeps BC DE HL

	include	"render.asm"
	include	"url.asm"

; ---- Text ------------------------------------------------------------------

s_title:	db	"zx-vvv",0
s_keyhint:	db	"K: help",0
s_pagesize:	db	"Page: ",0
s_bytes:	db	" bytes, ",0
s_free:		db	" free",0
s_form:		db	"Form not shown (yet)",0
s_newer:	db	"Newer 8TML version",0
help_lines:
		db	2,1,A_MSG,"Keys",0
		db	4,1,A_ITEM,"G",0,	4,8,A_BODY,"go to an address",0
		db	5,1,A_ITEM,"R",0,	5,8,A_BODY,"reload the page",0
		db	6,1,A_ITEM,"H",0,	6,8,A_BODY,"home (T8wn)",0
		db	7,1,A_ITEM,"N",0,	7,8,A_BODY,"next screen",0
		db	8,1,A_ITEM,"M",0,	8,8,A_BODY,"previous screen",0
		db	9,1,A_ITEM,"K or ?",0,	9,8,A_BODY,"this help",0
		db	10,1,A_ITEM,"Q",0,	10,8,A_BODY,"back to the menu",0
		db	12,1,A_ITEM,"SPACE",0,	12,8,A_BODY,"stops a page loading",0
		db	14,1,A_MSG,"Typing an address",0
		db	16,1,A_ITEM,"CAPS+0",0,	16,8,A_BODY,"delete",0
		db	17,1,A_ITEM,"CAPS+2",0,	17,8,A_BODY,"caps lock",0
		db	18,1,A_ITEM,"CAPS+1",0,	18,8,A_BODY,"cancel",0
		db	19,1,A_ITEM,"ENTER",0,	19,8,A_BODY,"go",0
		db	23,1,A_HINT,"Any key: back to the page",0
		db	0
s_home:		db	"https://t8wn.com/index.8tml",0
s_empty:	db	0
s_accept:	db	"text/8tml",0
s_refuse:	db	"text/html image/ audio/ video/ font/",0
s_address:	db	"Address (CAPS+1 cancels):",0
s_loading:	db	"Loading ",0
s_server:	db	"Server says HTTP ",0
s_cut:		db	"Page cut: too long",0
s_stopped:	db	"Stopped",0
s_noreply:	db	"No reply from the modem",0
s_loaderr:	db	"Load error: R loads it again",0
s_badreply:	db	"Unexpected reply",0
s_nofollow:	db	"Can't follow this link",0
s_long:		db	"Address too long",0
s_unsupported:	db	"Unsupported type: ",0
err_msgs:					; http service error codes 1-7 (6 above)
		db	"No Wi-Fi",0
		db	"Bad address",0
		db	"Could not connect",0
		db	"Timed out",0
		db	"Too many redirects",0
		db	0
		db	"Modem: bad request",0

; ---- Variables and buffers -------------------------------------------------

app_sp:		dw	0
page_len:	dw	0
page_end:	dw	page_buf
page_no:	dw	0
page_cut:	db	0
http_status:	dw	0

req:		db	0x01,'G',HTTP_ASCII	; http service, G
		dw	PAGE_MAX
code_end:					; the buffers aren't loaded from tape
req_url:	ds	URL_MAX+1+10+40		; (after req) url 0 accept 0 refuse
cur_url:	ds	URL_MAX+1		; the page's final address ("" = none)
input:		ds	INPUT_MAX+1
; Used while finding and fetching an address, then free while a page is
; laid out: the renderer's buffers share their memory.
url_tmp:	ds	URL_TMP_SIZE		; url.asm
url_out:	ds	URL_OUT_SIZE
win:		ds	WIN_SIZE+1		; the renderer's text window...
rxbuf		equ	win			; ... or a reply (RXBUF_SIZE)
url_buf		equ	url_tmp			; a link's address (256)
label_buf	equ	url_out			; a link's text (256)
	ASSERT	RXBUF_SIZE <= WIN_SIZE+1 && URL_TMP_SIZE >= 256 && URL_OUT_SIZE >= 256
tagbuf:		ds	16
cur_cells:	ds	2*WIDTH
pend_cells:	ds	2*WIDTH
word_cells:	ds	2*(WIDTH+2)
rowbuf:		ds	2*WIDTH
title_buf:	ds	32
title_disp:	ds	16
snaps:		ds	MAX_SCREENS*SNAP_SIZE
page_buf:					; the page, up to APP_END
PAGE_MAX	equ	APP_END - page_buf
linebuf		equ	0x5B00			; the printer buffer: a source line (256-aligned)

	SAVEBIN	"vvv.bin", vvv, code_end - vvv
