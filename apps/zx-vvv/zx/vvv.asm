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
; 6/7 (or the cursor keys) next/previous link, ENTER follow it, B back,
; L the list of links, ? help (the keys, how full the page buffer is),
; Q back to the menu. SPACE stops a load.

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
ADDR_MAX	equ	URL_MAX		; the address field: up to 255 characters,
ADDR_ROW	equ	20		;   seen through two rows (64 cells)
K_RIGHT		equ	9		; CAPS+8
RXBUF_SIZE	equ	400		; url-info: final address, 0, type; or an error
HTTP_ASCII	equ	0x01		; http G flags: UTF-8 -> ASCII,
HTTP_ONE	equ	0x02		;   one reply: url 0 type 0 body
SAVE_SIZE	equ	64		; page bytes an error reply may cover
BORDCR		equ	23624		; system variable: border colour * 8
SHEET_MAX	equ	1200		; a stylesheet's reply: url 0 type 0 sheet
SITES		equ	4		; sites whose site.8ss (or its absence) is kept
SITE_KEY	equ	64		; scheme://host:port, cut to 63
SITE_SIZE	equ	SITE_KEY+PARTIAL_SIZE

LIST_TOP	equ	2		; the link list: rows 2-21
LIST_ROWS	equ	20
HIST_SIZE	equ	512		; history: about 10 addresses
NAV_NEW		equ	0		; how a page is being fetched
NAV_RELOAD	equ	1
NAV_BACK	equ	2

RESP_BODY	equ	0
RESP_ERROR	equ	1
RESP_URLINFO	equ	3

	org	APP_ADDR

vvv:
	ld	(app_sp),sp
	ld	a,(BORDCR)		; the menu's border, for when we go back
	ld	(bordcr_save),a
	ld	hl,site_cache		; no stylesheets known yet
	ld	de,site_cache+1
	ld	bc,SITES*SITE_SIZE-1
	ld	(hl),0
	ldir
	xor	a
	ld	(site_next),a
	ld	(ps_valid),a
	ld	(cur_url),a
	ld	(page_cut),a
	ld	hl,0
	ld	(page_len),hl
	ld	(http_status),hl
	ld	hl,hist_buf
	ld	(hist_top),hl
	ld	hl,0xFFFF
	ld	(focus),hl
	call	new_page		; an empty page, so its bookmarks exist
	call	show_page
	ld	hl,s_home
	call	go_typed
main_loop:
	xor	a
	ld	(nav),a
	call	wait_key
	cp	K_DOWN
	jp	z,key_down
	cp	'6'
	jp	z,key_down
	cp	K_UP
	jp	z,key_up
	cp	'7'
	jp	z,key_up
	cp	K_ENTER
	jp	z,key_enter
	or	0x20			; letters to lower case
	cp	'b'
	jp	z,key_back
	cp	'l'
	jp	z,key_list
	cp	'g'
	jp	z,key_go
	cp	'r'
	jr	z,key_reload
	cp	'h'
	jr	z,key_home
	cp	'n'
	jp	z,key_next
	cp	'm'
	jp	z,key_prev
	cp	'?'
	jr	z,key_help
	cp	'q'
	jr	nz,main_loop
	ld	a,(bordcr_save)		; back to the menu, with its border
	ld	(BORDCR),a
	ld	sp,(app_sp)
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
	ld	a,NAV_RELOAD
	ld	(nav),a
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
	call	focus_none
	call	show_page
	jp	main_loop

key_prev:
	ld	hl,(page_no)
	ld	a,h
	or	l
	jp	z,main_loop
	dec	hl
	ld	(page_no),hl
	call	focus_none
	call	show_page
	jp	main_loop

key_go:
	ld	hl,cur_url		; start from the current address
	ld	de,input
	call	u_strcpy
	ld	hl,input
	call	u_strlen
	ld	a,c
	ld	(ad_len),a
	ld	(ad_cur),a
	xor	a
	ld	(ad_off),a
	ld	b,19
.clr:
	push	bc
	ld	a,A_PAGE
	call	scr_clear_row
	pop	bc
	inc	b
	ld	a,b
	cp	24
	jr	c,.clr
	ld	bc,19*256+0
	ld	a,A_MSG
	ld	hl,s_address
	call	text_at
	ld	bc,22*256+0
	ld	a,A_HINT
	ld	hl,s_adkeys1
	call	text_at
	ld	bc,23*256+0
	ld	a,A_HINT
	ld	hl,s_adkeys2
	call	text_at
.draw:
	call	ad_draw
.key:
	call	wait_key
	cp	K_ENTER
	jp	z,.done
	cp	K_EDIT
	jp	z,.cancel
	cp	K_DELETE
	jr	z,.del
	cp	K_LEFT
	jr	z,.left
	cp	K_RIGHT
	jr	z,.right
	cp	K_TRUE_VIDEO
	jp	z,.clear
	cp	K_CAPS_LOCK
	jp	z,.caps
	cp	32			; printable ASCII only (no keyword tokens)
	jr	c,.key
	cp	127
	jr	nc,.key
	ld	(ad_tmp),a		; insert at the cursor
	ld	a,(ad_len)
	cp	ADDR_MAX
	jr	nc,.key			; full
	ld	b,a
	ld	a,(ad_cur)
	ld	c,a
	ld	a,b
	sub	c			; len - cur characters move up by one
	jr	z,.ins
	ld	c,a
	ld	b,0
	ld	a,(ad_len)
	call	ad_ptr			; HL = input + len
	ld	d,h
	ld	e,l
	dec	hl			; from the last character, backwards
	lddr
.ins:
	ld	a,(ad_cur)
	call	ad_ptr
	ld	a,(ad_tmp)
	ld	(hl),a
	ld	hl,ad_len
	inc	(hl)
	ld	hl,ad_cur
	inc	(hl)
	jr	.draw
.del:					; the character before the cursor
	ld	a,(ad_cur)
	or	a
	jr	z,.key
	dec	a
	ld	(ad_cur),a
	call	ad_ptr
	ld	d,h
	ld	e,l
	inc	hl
	ld	a,(ad_len)
	ld	b,a
	ld	a,(ad_cur)
	ld	c,a
	ld	a,b
	sub	c
	dec	a			; len - cur - 1 characters move down
	ld	c,a
	ld	b,0
	jr	z,.deld
	ldir
.deld:
	ld	hl,ad_len
	dec	(hl)
	jp	.draw
.left:
	ld	a,(ad_cur)
	or	a
	jp	z,.key
	dec	a
	ld	(ad_cur),a
	jp	.draw
.right:
	ld	a,(ad_len)
	ld	b,a
	ld	a,(ad_cur)
	cp	b
	jp	nc,.key
	inc	a
	ld	(ad_cur),a
	jp	.draw
.clear:
	xor	a
	ld	(ad_len),a
	ld	(ad_cur),a
	ld	(ad_off),a
	jp	.draw
.caps:
	ld	hl,FLAGS2
	ld	a,(hl)
	xor	8
	ld	(hl),a
	jp	.key
.done:
	ld	a,(ad_len)
	or	a
	jr	z,.cancel
	call	ad_ptr			; the end: a 0
	ld	(hl),0
	call	show_page		; the page back under the field
	ld	hl,input
	call	go_typed
	jp	main_loop
.cancel:
	call	show_page
	jp	main_loop

; ad_ptr: HL = input + A.
ad_ptr:
	ld	hl,input
	ld	e,a
	ld	d,0
	add	hl,de
	ret

; ad_draw: the field: 64 cells of the address around the cursor, the
; cursor's cell highlighted.
ad_draw:
	ld	a,(ad_off)		; keep the cursor in view
	ld	b,a
	ld	a,(ad_cur)
	cp	b
	jr	nc,.notleft
	ld	(ad_off),a
	jr	.view
.notleft:
	sub	b
	cp	64
	jr	c,.view
	ld	a,(ad_cur)
	sub	63
	ld	(ad_off),a
.view:
	ld	c,0			; C = the cell, 0-63
.cell:
	ld	a,c
	and	31
	push	bc
	ld	b,ADDR_ROW
	bit	5,c
	jr	z,.r
	inc	b
.r:
	ld	c,a
	call	scr_at
	pop	bc
	ld	a,(ad_off)		; E = the character's place in the address
	add	a,c
	ld	e,a
	ld	a,A_FIELD
	jr	c,.attr			; past 255
	ld	a,(ad_cur)
	cp	e
	ld	a,A_FIELD
	jr	nz,.attr
	ld	a,A_SEL			; the cursor
.attr:
	ld	(scr_attr),a
	ld	a,(ad_off)
	add	a,c
	jr	c,.blank		; past 255
	ld	a,(ad_len)
	cp	e
	jr	c,.blank		; past the end
	jr	z,.blank
	ld	a,e
	push	bc
	call	ad_ptr
	ld	a,(hl)
	pop	bc
	jr	.put
.blank:
	ld	a,' '
.put:
	push	bc
	call	scr_putc
	pop	bc
	inc	c
	ld	a,c
	cp	64
	jr	c,.cell
	ret

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
	ld	hl,PAGE_MAX
	call	send_get
	; One reply: [final address] 0 [type] 0 [page], straight into the page
	; buffer. Only a page replaces the page: an error reply (short) lands
	; on its first bytes, so they are saved first and put back.
	ld	hl,page_buf
	ld	de,page_save
	ld	bc,SAVE_SIZE
	ldir
	ld	ix,page_buf
	ld	de,PAGE_MAX
	call	link_receive
	jp	nc,.failed
	cp	RESP_BODY
	jr	z,.page
	cp	RESP_ERROR
	ld	hl,s_badreply
	jr	nz,.restore
	ld	a,b			; the error (at most SAVE_SIZE) -> rxbuf
	or	a
	jr	nz,.restore
	ld	a,c
	cp	SAVE_SIZE
	jr	nc,.restore
	ld	hl,page_buf
	ld	de,rxbuf
	or	a
	jr	z,.e0
	ldir
.e0:
	xor	a
	ld	(de),a
	call	page_restore
	jp	modem_error
.restore:
	push	hl
	call	page_restore
	pop	hl
	jp	status_error
.page:
	ld	hl,page_buf		; a 0 after the data: the strings end
	add	hl,bc
	ld	(hl),0
	ld	(rx_end),hl
	call	hist_on_success
	ld	hl,page_buf		; the final address
	ld	de,cur_url
	ld	b,URL_MAX
.copy:
	ld	a,(hl)
	inc	hl
	ld	(de),a
	or	a
	jr	z,.type
	inc	de
	djnz	.copy
	xor	a
	ld	(de),a
.skip:					; (longer than URL_MAX: the rest goes)
	ld	a,(hl)
	inc	hl
	or	a
	jr	nz,.skip
.type:
	ld	a,(hl)			; the type, not needed: past its 0
	inc	hl
	or	a
	jr	nz,.type
	ex	de,hl			; the page, down to the start of the buffer
	ld	hl,(rx_end)
	or	a
	sbc	hl,de
	jr	nc,.len
	ld	hl,0			; (no page after the strings)
	ld	de,(rx_end)
.len:
	ld	(page_len),hl
	ld	b,h
	ld	c,l
	ex	de,hl
	ld	de,page_buf
	ld	a,b
	or	c
	jr	z,.moved
	ldir
.moved:
	ld	hl,(link_header+8)
	ld	(http_status),hl
	ld	hl,0
	ld	(page_no),hl
	ld	a,(link_header+1)
	and	2			; cut by the modem
	ld	(page_cut),a
	ld	hl,(page_len)		; (page_end, for parse_header)
	ld	de,page_buf
	add	hl,de
	ld	(page_end),hl
	call	styles_fetch		; site.8ss (once per site), the page's sheet
	call	new_page
	ld	a,(nav)			; back: to the screen we were on
	cp	NAV_BACK
	jp	nz,show_page
	ld	hl,(back_screen)
	ld	de,(screens)
	or	a
	sbc	hl,de
	jp	nc,show_page
	add	hl,de
	ld	(page_no),hl
	jp	show_page
.failed:				; no reply, a tape error or SPACE: the page
	push	af			; stays if its first bytes are untouched
	ld	hl,page_buf
	ld	de,page_save
	ld	b,SAVE_SIZE
.cmp:
	ld	a,(de)
	cp	(hl)
	jr	nz,.lost
	inc	hl
	inc	de
	djnz	.cmp
	pop	af
	jp	link_failed
.lost:
	ld	hl,0			; partly overwritten: an empty page
	ld	(page_len),hl
	ld	(http_status),hl
	call	new_page
	call	show_page
	pop	af
	ld	hl,s_stopped
	cp	LINK_ERR_BREAK
	jp	z,status_error
	ld	hl,s_loaderr
	jp	status_error

; page_restore: the page buffer's first bytes as they were.
page_restore:
	ld	hl,page_save
	ld	de,page_buf
	ld	bc,SAVE_SIZE
	ldir
	ret

; send_get: ask the http service for url_out (one reply), at most HL
; bytes back; Accept text/8tml, HTML and media refused.
send_get:
	ld	(req+3),hl
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
	jp	link_request

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
.type:					; a refused type: if the server's status
	ld	hl,(link_header+8)	; wasn't 2xx (firmware 0.8 sends it), that
	ld	a,h			; is the news, e.g. a 404 as an HTML page
	or	l
	jr	z,.unsup		; (0: an older modem, or none)
	ld	de,200
	or	a
	sbc	hl,de
	jr	c,.http
	ld	de,100
	sbc	hl,de
	jr	c,.unsup		; 2xx: the type is the problem
.http:
	ld	b,STATUS_ROW
	ld	a,A_STAT_ERR
	call	scr_clear_row
	ld	hl,s_server
	call	scr_print
	ld	hl,(link_header+8)
	jp	print_status_code
.unsup:
	ld	hl,s_unsupported	; VVV's words (shortened to fit 32 columns)
	jp	status_error
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
	jr	nz,.note
	ld	a,(focus+1)		; a link is focused: its address
	inc	a
	jr	z,.addr
	ld	hl,found_url
	ld	b,STATUS_TEXT
	call	print_max
	jr	.count
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
	call	focus_none
	call	parse_header
	call	styles_apply		; the cascade for this page
	jp	render_measure

; show_page: the title bar and screen page_no of the page, then the status.
show_page:
	ld	a,(att_plain)		; the page's background
	call	scr_cls
	ld	a,(border)
	out	(0xFE),a
	add	a,a
	add	a,a
	add	a,a
	ld	(BORDCR),a		; (the tape routines put it back after loads)
	call	make_title
	ld	hl,title_disp
	call	draw_title
	ld	bc,0*256+17		; the help hint, before the stripes
	ld	a,A_HINT
	ld	hl,s_keyhint
	call	text_at
	ld	hl,(focus)		; the focused link is drawn in link-sel
	ld	(sel_link),hl
	ld	hl,(page_no)
	call	render_draw
	ld	hl,(focus)		; is it on this screen?
	call	run_has
	call	nc,focus_none
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

; ---- Links ------------------------------------------------------------------

; focus_none: no link focused.
focus_none:
	ld	hl,0xFFFF
	ld	(focus),hl
	ld	(sel_link),hl
	ret

; key_down / key_up: the next / previous link on the screen; past the
; last / first, the next / previous screen.
key_down:
	call	focus_next
	jr	c,.set
	ld	hl,(page_no)
	inc	hl
	ld	de,(screens)
	or	a
	sbc	hl,de
	jp	nc,main_loop		; the last screen
	add	hl,de
	ld	(page_no),hl
	call	focus_none
	call	show_page
	call	focus_next
	jp	nc,main_loop
.set:
	call	focus_set
	jp	main_loop

key_up:
	call	focus_prev
	jr	c,.set
	ld	hl,(page_no)
	ld	a,h
	or	l
	jp	z,main_loop
	dec	hl
	ld	(page_no),hl
	call	focus_none
	call	show_page
	call	focus_prev
	jp	nc,main_loop
.set:
	call	focus_set
	jp	main_loop

; key_enter: follow the focused link.
key_enter:
	ld	a,(focus+1)
	inc	a
	jp	z,main_loop		; none
	ld	hl,cur_url
	ld	de,found_url
	call	go_resolve
	jp	main_loop

; focus_set: focus link HL: highlight it, find its address, show it.
focus_set:
	ld	(focus),hl
	ld	(find_no),hl		; its address, for the status line and ENTER
	ld	hl,(page_no)
	call	render_find
	jr	c,.found
	xor	a
	ld	(found_url),a
.found:
	jp	show_page		; drawn again, the link in link-sel

; focus_next: carry and HL = the first link on the screen after the focus
; (the first of all if none is focused).
focus_next:
	ld	hl,0xFFFF		; the best so far
	ld	(fbest),hl
	call	runs_start
.l:
	jr	z,focus_result
	push	bc
	push	hl
	ld	e,(hl)
	inc	hl
	ld	d,(hl)			; DE = this run's link
	ld	hl,(focus)
	ld	a,h
	and	l
	inc	a
	jr	z,.any			; nothing focused
	or	a
	sbc	hl,de
	jr	nc,.skip		; not after the focus
.any:
	ld	hl,(fbest)
	or	a
	sbc	hl,de
	jr	c,.skip
	ld	(fbest),de
.skip:
	pop	hl
	pop	bc
	call	runs_next
	jr	.l

; focus_result: carry and HL = fbest, unless it is none.
focus_result:
	ld	hl,(fbest)
	ld	a,h
	and	l
	inc	a			; Z if none
	scf
	ret	nz
	or	a
	ret

; focus_prev: carry and HL = the last link on the screen before the focus
; (the last of all if none is focused).
focus_prev:
	ld	hl,0xFFFF
	ld	(fbest),hl
	call	runs_start
.l:
	jr	z,focus_result
	push	bc
	push	hl
	ld	e,(hl)
	inc	hl
	ld	d,(hl)
	ld	hl,(focus)
	ld	a,h
	and	l
	inc	a
	jr	z,.any
	or	a
	sbc	hl,de
	jr	z,.skip
	jr	c,.skip			; not before the focus
.any:
	ld	hl,(fbest)		; none yet, or this one is later
	ld	a,h
	and	l
	inc	a
	jr	z,.take
	or	a
	sbc	hl,de
	jr	nc,.skip
.take:
	ld	(fbest),de
.skip:
	pop	hl
	pop	bc
	call	runs_next
	jr	.l

; runs_start: HL = the first link run, B = how many; Z if none.
runs_start:
	ld	hl,runs
	ld	a,(run_n)
	ld	b,a
	or	a
	ret
; runs_next: the next run; Z when none are left.
runs_next:
	ld	de,5
	add	hl,de
	dec	b
	ret

; run_has: carry if link HL has a run on this screen.
run_has:
	ld	(rh_link),hl		; (runs_next uses DE)
	call	runs_start
.l:
	jr	nz,.go
	or	a			; none: no carry
	ret
.go:
	ld	a,(rh_link)
	cp	(hl)
	jr	nz,.n
	inc	hl
	ld	a,(rh_link+1)
	cp	(hl)
	dec	hl			; (flags unchanged)
	scf
	ret	z
.n:
	call	runs_next
	jr	.l

; link_hook: the renderer calls this for every link while finding
; (MODE_FIND: link find_no's address -> found_url) or listing (MODE_LIST:
; the list's rows). lk_cur = the link's number, url_buf = its address.
link_hook:
	ld	a,(mode)
	cp	MODE_FIND
	jr	nz,.list
	ld	hl,(lk_cur)
	ld	de,(find_no)
	or	a
	sbc	hl,de
	ret	nz
	ld	hl,url_buf
	ld	de,found_url
	ld	bc,256
	ldir
	ld	a,1
	ld	(found),a
	jp	render_abort
.list:
	ld	hl,(lk_cur)
	ld	de,(list_first)
	or	a
	sbc	hl,de
	ret	c			; before the list
	ld	a,h
	or	a
	jp	nz,render_abort
	ld	a,l
	cp	LIST_ROWS
	jp	nc,render_abort		; after it
	add	a,LIST_TOP
	ld	b,a
	ld	a,A_BODY
	call	scr_clear_row
	ld	hl,(lk_cur)
	inc	hl
	call	print_num3
	ld	a,' '
	call	scr_putc
	ld	hl,url_buf
	ld	b,28
	jp	print_max

; print_num3: HL right-aligned in 3 columns (more if it needs them).
print_num3:
	ld	de,100
	or	a
	sbc	hl,de
	add	hl,de
	jr	nc,.n
	ld	a,' '
	call	scr_putc
	ld	de,10
	or	a
	sbc	hl,de
	add	hl,de
	jr	nc,.n
	ld	a,' '
	call	scr_putc
.n:
	jp	print_dec16

; key_list: the page's links, 20 at a time; 6/7 move, ENTER follows,
; N/M more, L or Q back to the page.
key_list:
	ld	hl,(lk_total)
	ld	a,h
	or	l
	ld	hl,s_nolinks
	jp	z,.none
	ld	hl,(focus)		; start at the focused link, or the first
	ld	a,h
	and	l
	inc	a
	jr	nz,.sel
	ld	hl,0
.sel:
	ld	(list_sel),hl
.page:
	ld	hl,(list_sel)		; the page of 20 with list_sel on it
	ld	b,0
.div:
	ld	de,LIST_ROWS
	or	a
	sbc	hl,de
	jr	c,.divd
	inc	b
	jr	.div
.divd:
	ld	l,b
	ld	h,0
	add	hl,hl
	add	hl,hl
	ld	d,h
	ld	e,l
	add	hl,hl
	add	hl,hl
	add	hl,de			; * 20
	ld	(list_first),hl
	ld	a,A_PAGE
	call	scr_cls
	ld	hl,s_links
	call	draw_title
	ld	bc,STATUS_ROW*256+0
	ld	a,A_HINT
	ld	hl,s_listkeys
	call	text_at
	call	render_list
.mark:
	call	.paint
	call	wait_key
	cp	K_DOWN
	jr	z,.down
	cp	'6'
	jr	z,.down
	cp	K_UP
	jr	z,.up
	cp	'7'
	jr	z,.up
	cp	K_ENTER
	jr	z,.go
	or	0x20
	cp	'n'
	jr	z,.more
	cp	'm'
	jr	z,.less
	cp	'l'
	jr	z,.back
	cp	'q'
	jr	nz,.mark
.back:
	call	show_page
	jp	main_loop
.down:
	ld	hl,(list_sel)
	inc	hl
	ld	de,(lk_total)
	or	a
	sbc	hl,de
	jr	nc,.mark
	add	hl,de
	jr	.to
.up:
	ld	hl,(list_sel)
	ld	a,h
	or	l
	jr	z,.mark
	dec	hl
.to:
	push	hl
	ld	a,A_BODY		; the old row back to normal
	call	.attr
	pop	hl
	ld	(list_sel),hl
	ld	de,(list_first)		; still on this page of the list?
	or	a
	sbc	hl,de
	jp	c,.page
	ld	de,LIST_ROWS
	or	a
	sbc	hl,de
	jp	nc,.page
	jr	.mark
.more:
	ld	hl,(list_first)
	ld	de,LIST_ROWS
	add	hl,de
	ex	de,hl
	ld	hl,(lk_total)
	or	a
	sbc	hl,de
	jr	z,.mark
	jr	c,.mark
	ld	(list_sel),de
	jp	.page
.less:
	ld	hl,(list_first)
	ld	de,LIST_ROWS
	or	a
	sbc	hl,de
	jp	c,.mark
	ld	(list_sel),hl
	jp	.page
.go:
	ld	hl,(list_sel)
	ld	(find_no),hl
	ld	hl,0
	call	render_find
	jp	nc,.back
	call	show_page		; the page behind, then follow
	ld	hl,cur_url
	ld	de,found_url
	call	go_resolve
	jp	main_loop
.paint:
	ld	a,A_SEL
.attr:					; the selected row in colour A
	push	af
	ld	hl,(list_sel)
	ld	de,(list_first)
	or	a
	sbc	hl,de
	ld	a,l
	add	a,LIST_TOP
	ld	b,a
	pop	af
	ld	c,32
	ld	e,0
	jp	scr_paint
.none:
	call	status_error
	jp	main_loop

; ---- Stylesheets (M7) ------------------------------------------------------
; site.8ss is fetched once per site (scheme://host:port) and kept, missing
; or not, for the last SITES sites; the page's style: sheet is kept for the
; last one. A site's sheet that couldn't be loaded counts as missing (spec
; 8.1); only a reply that never came (SPACE, a tape error) isn't kept.

; styles_fetch: the new page (in page_buf, cur_url set) may need its site's
; sheet and its own: fetch whichever isn't known yet.
styles_fetch:
	call	parse_header
	call	site_key
	ld	a,(skey)
	or	a
	ret	z
	call	site_find
	jr	c,.page
	ld	hl,cur_url		; /site.8ss of this site
	ld	de,s_site8ss
	call	url_resolve
	or	a
	jr	nz,.page
	ld	a,(site_next)		; the next slot, round the 4
	ld	l,a
	ld	h,0
	ld	de,SITE_SIZE
	call	mul_hl_de
	ld	de,site_cache
	add	hl,de
	push	hl
	ld	de,SITE_KEY
	add	hl,de
	ld	b,h
	ld	c,l
	call	sheet_get		; -> the partial at BC
	pop	de
	jr	c,.page			; no reply at all: not kept
	ld	hl,skey			; keep it under the site's name
	call	u_strcpy
	ld	a,(site_next)
	inc	a
	and	SITES-1
	ld	(site_next),a
.page:
	call	page_sheet_url		; the page's style:, resolved -> url_out
	ret	nc
	call	page_sheet_known
	ret	c
	ld	hl,url_out
	ld	de,ps_url
	call	u_strcpy
	ld	bc,ps_part
	call	sheet_get
	ld	a,0
	jr	c,.ps
	inc	a
.ps:
	ld	(ps_valid),a
	ret

; styles_apply: the cascade for the page: its header, its site's sheet and
; its own sheet, as far as they are known.
styles_apply:
	ld	hl,0
	ld	(site_part),hl
	ld	(page_part),hl
	ld	a,(is_page)
	or	a
	jr	z,.nohdr
	ld	hl,page_buf		; the header's lines are a source too
	ld	de,(body_ptr)
	ld	bc,hdr_part
	call	sheet_parse
	jr	.site
.nohdr:
	ld	hl,hdr_part
	ld	b,PARTIAL_SIZE
.clr:
	ld	(hl),0
	inc	hl
	djnz	.clr
.site:
	call	site_key
	ld	a,(skey)
	or	a
	jr	z,.page
	call	site_find
	jr	nc,.page
	ld	de,SITE_KEY
	add	hl,de
	ld	(site_part),hl
.page:
	call	page_sheet_url
	jr	nc,.done
	call	page_sheet_known
	jr	nc,.done
	ld	hl,ps_part
	ld	(page_part),hl
.done:
	jp	cascade

; page_sheet_url: carry and url_out = the page's style: sheet, resolved
; against the page, if it has one.
page_sheet_url:
	ld	a,(is_page)
	or	a
	ret	z
	ld	a,(hd_stylelen)
	or	a
	ret	z
	ld	hl,cur_url		; (parse_header copied the value)
	ld	de,hd_style
	call	url_resolve
	or	a
	ret	nz			; (no carry)
	scf
	ret

; page_sheet_known: carry if the kept page sheet is url_out's.
page_sheet_known:
	ld	a,(ps_valid)
	or	a
	ret	z
	ld	hl,url_out
	ld	de,ps_url
	call	str_eq
	scf
	ret	z
	ccf				; (str_eq's compare may leave carry set)
	ret

; sheet_get: fetch url_out as a stylesheet into the partial at BC: parsed
; if it came with a 2xx status, empty (missing) otherwise. Carry: no
; reply came at all (SPACE or a tape error), so it shouldn't be kept.
sheet_get:
	ld	(sg_part),bc
	call	status_loading
	ld	hl,SHEET_MAX
	call	send_get
	ld	ix,sheet_buf
	ld	de,SHEET_MAX
	call	link_receive
	jr	c,.reply
	ld	hl,(sg_part)		; no reply: nothing known (not kept)
	call	.clear
	scf
	ret
.reply:
	cp	RESP_BODY
	jr	nz,.missing
	ld	hl,(link_header+8)	; 2xx only
	ld	de,200
	or	a
	sbc	hl,de
	jr	c,.missing
	ld	de,100
	sbc	hl,de
	jr	nc,.missing
	ld	hl,sheet_buf		; [url] 0 [type] 0 [sheet]
	add	hl,bc
	ld	(hl),0
	ex	de,hl			; DE = the end
	ld	hl,sheet_buf
.s1:
	ld	a,(hl)
	inc	hl
	or	a
	jr	nz,.s1
.s2:
	ld	a,(hl)
	inc	hl
	or	a
	jr	nz,.s2
	push	hl
	or	a
	sbc	hl,de
	pop	hl
	jr	nc,.missing		; (no sheet after the strings)
	ld	bc,(sg_part)
	call	sheet_parse
	or	a
	ret
.missing:
	ld	hl,(sg_part)
	call	.clear
	or	a
	ret
.clear:
	ld	b,PARTIAL_SIZE
.c:
	ld	(hl),0
	inc	hl
	djnz	.c
	ret

; site_key: skey = the site of cur_url (scheme://host:port), or "".
site_key:
	ld	a,(cur_url)
	ld	(skey),a
	or	a
	ret	z
	ld	hl,cur_url
	call	auth_end
	ld	de,cur_url
	or	a
	sbc	hl,de
	ld	a,h
	or	a
	jr	nz,.cut
	ld	a,l
	cp	SITE_KEY
	jr	c,.n
.cut:
	ld	a,SITE_KEY-1
.n:
	ld	c,a
	ld	b,0
	ld	hl,cur_url
	ld	de,skey
	ldir
	xor	a
	ld	(de),a
	ret

; site_find: carry and HL = skey's entry in the cache.
site_find:
	ld	hl,site_cache
	ld	b,SITES
.l:
	push	hl
	push	bc
	ld	de,skey
	call	str_eq
	pop	bc
	pop	hl
	scf
	ret	z
	ld	de,SITE_SIZE
	add	hl,de
	djnz	.l
	or	a
	ret

; str_eq: Z if the strings at HL and DE are the same.
str_eq:
	ld	a,(de)
	cp	(hl)
	ret	nz
	or	a
	ret	z
	inc	hl
	inc	de
	jr	str_eq

; mul_hl_de: HL = L * DE (L small).
mul_hl_de:
	ld	b,l
	ld	hl,0
	ld	a,b
	or	a
	ret	z
.m:
	add	hl,de
	djnz	.m
	ret

; ---- History ----------------------------------------------------------------
; hist_buf holds entries [address][0][screen:2][entry length:2], newest
; last; when it is full the oldest go. (The length takes 2 bytes: an
; address of 255 characters makes an entry of 260.)

; hist_on_success: a new page is arriving: remember the one we leave (not
; for a reload; going back drops the entry we went back to).
hist_on_success:
	ld	a,(nav)
	cp	NAV_RELOAD
	ret	z
	cp	NAV_BACK
	jp	z,hist_drop
	ld	a,(cur_url)
	or	a
	ret	z			; nothing shown yet
	ld	hl,cur_url
	call	u_strlen		; BC = length
	ld	hl,5
	add	hl,bc
	ld	(hist_len),hl
.room:
	ld	hl,(hist_top)
	ld	de,(hist_len)
	add	hl,de
	ld	de,hist_buf+HIST_SIZE
	or	a
	sbc	hl,de
	jr	c,.fits
	jr	z,.fits
	ld	hl,hist_buf		; drop the oldest
	call	u_strlen
	ld	hl,5
	add	hl,bc
	ex	de,hl			; DE = its length
	ld	hl,(hist_top)
	or	a
	sbc	hl,de
	ld	(hist_top),hl
	ld	bc,hist_buf
	or	a
	sbc	hl,bc			; what is left after it
	ld	b,h
	ld	c,l
	ld	hl,hist_buf
	add	hl,de
	ld	de,hist_buf
	ld	a,b
	or	c
	jr	z,.room
	ldir
	jr	.room
.fits:
	ld	de,(hist_top)
	ld	hl,cur_url
	call	u_strcpy		; DE on the 0
	inc	de
	ld	hl,(page_no)
	ex	de,hl
	ld	(hl),e
	inc	hl
	ld	(hl),d
	inc	hl
	ld	a,(hist_len)
	ld	(hl),a
	inc	hl
	ld	a,(hist_len+1)
	ld	(hl),a
	inc	hl
	ld	(hist_top),hl
	ret

; hist_peek: carry and HL = the newest address, back_screen = its screen.
hist_peek:
	ld	hl,(hist_top)
	ld	de,hist_buf
	or	a
	sbc	hl,de
	ret	z			; empty (no carry)
	ld	hl,(hist_top)
	dec	hl
	ld	d,(hl)			; the entry's length
	dec	hl
	ld	e,(hl)
	dec	hl
	ld	a,(hl)
	dec	hl
	ld	l,(hl)			; (screen low) ...
	ld	h,a
	ld	(back_screen),hl
	ld	hl,(hist_top)
	or	a
	sbc	hl,de			; the entry's start
	scf
	ret

; hist_drop: forget the newest entry.
hist_drop:
	ld	hl,(hist_top)
	ld	de,hist_buf
	or	a
	sbc	hl,de
	ret	z
	ld	hl,(hist_top)
	dec	hl
	ld	d,(hl)			; the entry's length
	dec	hl
	ld	e,(hl)
	ld	hl,(hist_top)
	or	a
	sbc	hl,de
	ld	(hist_top),hl
	ret

; key_back: the previous page, at the screen we were on.
key_back:
	call	hist_peek
	ld	hl,s_noback
	jr	nc,.none
	ld	a,NAV_BACK
	ld	(nav),a
	call	hist_peek
	call	go_typed
	jp	main_loop
.none:
	call	status_error
	jp	main_loop

	include	"render.asm"
	include	"url.asm"

; ---- Text ------------------------------------------------------------------

s_title:	db	"zx-vvv",0
s_keyhint:	db	"?: help",0
s_pagesize:	db	"Page: ",0
s_bytes:	db	" bytes, ",0
s_free:		db	" free",0
s_form:		db	"Form not shown (yet)",0
s_newer:	db	"Newer 8TML version",0
help_lines:
		db	2,1,A_MSG,"Keys",0
		db	3,1,A_ITEM,"G",0,	3,8,A_BODY,"go to an address",0
		db	4,1,A_ITEM,"R",0,	4,8,A_BODY,"reload the page",0
		db	5,1,A_ITEM,"H",0,	5,8,A_BODY,"home (T8wn)",0
		db	6,1,A_ITEM,"N  M",0,	6,8,A_BODY,"next, previous screen",0
		db	7,1,A_ITEM,"6  7",0,	7,8,A_BODY,"next, previous link",0
		db	8,1,A_ITEM,"ENTER",0,	8,8,A_BODY,"follow the link",0
		db	9,1,A_ITEM,"B",0,	9,8,A_BODY,"back",0
		db	10,1,A_ITEM,"L",0,	10,8,A_BODY,"list the links",0
		db	11,1,A_ITEM,"?",0,	11,8,A_BODY,"this help",0
		db	12,1,A_ITEM,"Q",0,	12,8,A_BODY,"back to the menu",0
		db	13,1,A_ITEM,"SPACE",0,	13,8,A_BODY,"stops a page loading",0
		db	15,1,A_MSG,"Typing an address",0
		db	16,1,A_BODY,"CAPS+0 delete  CAPS+2 caps lock",0
		db	17,1,A_BODY,"CAPS+1 cancel  ENTER go",0
		db	23,1,A_HINT,"Any key: back to the page",0
		db	0
s_links:	db	"Links",0
s_listkeys:	db	"6/7 ENTER go  N/M more  L back",0
s_nolinks:	db	"No links on this page",0
s_noback:	db	"No page to go back to",0
s_site8ss:	db	"/site.8ss",0
s_home:		db	"https://t8wn.com/index.8tml",0
s_empty:	db	0
s_accept:	db	"text/8tml",0
s_refuse:	db	"text/html image/ audio/ video/ font/",0
s_address:	db	"Address:",0
s_adkeys1:	db	"ENTER go  CAPS+1 cancel",0
s_adkeys2:	db	"CAPS+5/8 move CAPS+3 clear",0
s_loading:	db	"Loading ",0
s_server:	db	"Server says HTTP ",0
s_cut:		db	"Page cut: too long",0
s_stopped:	db	"Stopped",0
s_noreply:	db	"No reply from the modem",0
s_loaderr:	db	"Load error: R loads it again",0
s_badreply:	db	"Unexpected reply",0
s_nofollow:	db	"Can't follow this link",0
s_long:		db	"Address too long",0
s_unsupported:	db	"Unsupported type: not 8TML page",0
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
focus:		dw	0xFFFF			; the focused link's number (0xFFFF: none)
fbest:		dw	0
rh_link:	dw	0			; run_has: the link looked for
find_no:	dw	0
list_first:	dw	0
list_sel:	dw	0
nav:		db	0			; NAV_NEW, NAV_RELOAD, NAV_BACK
back_screen:	dw	0
hist_top:	dw	0
hist_len:	dw	0
bordcr_save:	db	0
site_next:	db	0
ps_valid:	db	0			; 1: ps_url's sheet is in ps_part
sg_part:	dw	0
page_cut:	db	0
ad_len:		db	0			; the address field: length,
ad_cur:		db	0			;   cursor,
ad_off:		db	0			;   first character shown
ad_tmp:		db	0
rx_end:		dw	0
http_status:	dw	0

req:		db	0x01,'G',HTTP_ASCII|HTTP_ONE	; http service, G
		dw	PAGE_MAX
code_end:					; the buffers aren't loaded from tape
req_url:	ds	URL_MAX+1+10+40		; (after req) url 0 accept 0 refuse
input:		ds	ADDR_MAX+1
tagbuf:		ds	16
cur_cells:	ds	CELL*WIDTH
pend_cells:	ds	CELL*WIDTH
word_cells:	ds	CELL*(WIDTH+2)
rowbuf:		ds	CELL*WIDTH
page_save:	ds	SAVE_SIZE		; an error reply's place in the page
site_cache:	ds	SITES*SITE_SIZE		; [site 64][partial] x 4
ps_part:	ds	PARTIAL_SIZE		;   and its partial
hdr_part:	ds	PARTIAL_SIZE		; the page header's styles
skey:		ds	SITE_KEY
title_buf:	ds	32
title_disp:	ds	16
page_buf:					; the page, up to APP_END
PAGE_MAX	equ	APP_END - page_buf
linebuf		equ	0x5B00			; the printer buffer: a source line (256-aligned)

; The menu's spare area (APP_SPARE, docs/app-api.md 2): the big buffers, so
; the page buffer above gets 4 KB more. Not loaded, gone when zx-vvv quits.
	org	APP_SPARE
cur_url:	ds	URL_MAX+1		; the page's final address ("" = none)
; Used while finding and fetching an address, then free while a page is
; laid out: the renderer's buffers share their memory.
url_tmp:	ds	URL_TMP_SIZE		; url.asm
url_out:	ds	URL_OUT_SIZE
win:		ds	WIN_SIZE+1		; the renderer's text window...
rxbuf		equ	win			; ... or a reply (RXBUF_SIZE)
url_buf		equ	url_tmp			; a link's address (256)
label_buf	equ	url_out			; a link's text (256)
	ASSERT	RXBUF_SIZE <= WIN_SIZE+1 && URL_TMP_SIZE >= 256 && URL_OUT_SIZE >= 256
sheet_buf	equ	url_tmp			; a stylesheet's reply: url_tmp .. win
	ASSERT	url_out == url_tmp+URL_TMP_SIZE && win == url_out+URL_OUT_SIZE
	ASSERT	URL_TMP_SIZE+URL_OUT_SIZE+WIN_SIZE >= SHEET_MAX+1
runs:		ds	MAX_RUNS*5		; the screen's link pieces
found_url:	ds	256			; the focused link's address
hist_buf:	ds	HIST_SIZE
snaps:		ds	MAX_SCREENS*SNAP_SIZE
ps_url:		ds	URL_MAX+1		; the last page sheet's address
	ASSERT	$ <= APP_SPARE_END

	SAVEBIN	"vvv.bin", vvv, code_end - vvv
