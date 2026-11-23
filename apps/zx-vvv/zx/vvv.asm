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
INPUT_MAX	equ	63		; edit_line's limit
RXBUF_SIZE	equ	400		; url-info: final address, 0, type; or an error
HTTP_ASCII	equ	0x01		; http G flags: UTF-8 -> ASCII,
HTTP_ONE	equ	0x02		;   one reply: url 0 type 0 body
SAVE_SIZE	equ	64		; page bytes an error reply may cover

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
	xor	a
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
	jr	z,key_next
	cp	'm'
	jp	z,key_prev
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
	xor	a
	ld	(sel_count),a
	ld	hl,(focus)		; the focused link, if it's on this screen
	call	run_has
	jp	nc,.nofocus
	call	sel_paint
	jp	show_status
.nofocus:
	call	focus_none
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
	push	hl
	call	sel_restore
	pop	hl
	ld	(focus),hl
	call	sel_paint
	ld	hl,(focus)
	ld	(find_no),hl
	ld	hl,(page_no)
	call	render_find
	jp	c,show_status
	xor	a
	ld	(found_url),a
	jp	show_status

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
	ex	de,hl
	call	runs_start
.l:
	jr	nz,.go
	or	a			; none: no carry
	ret
.go:
	ld	a,(hl)
	cp	e
	jr	nz,.n
	inc	hl
	ld	a,(hl)
	dec	hl
	cp	d
	scf
	ret	z
.n:
	call	runs_next
	jr	.l

; sel_paint: show the focused link selected (reversed, the reference's
; link-sel), saving its cells' attributes for sel_restore.
sel_paint:
	xor	a
	ld	(sel_count),a
	ld	de,sel_save
	ld	(sel_ptr),de
	ld	a,1
	jr	sel_walk
; sel_restore: the focused link's attributes as they were.
sel_restore:
	ld	a,(sel_count)
	or	a
	ret	z
	ld	(sel_left),a
	ld	de,sel_save
	ld	(sel_ptr),de
	xor	a
	ld	(sel_count),a
	; fall through (A = 0: restore)
sel_walk:
	ld	(sel_mode),a
	call	runs_start
.l:
	ret	z
	push	bc
	push	hl
	ld	e,(hl)			; this run's link = the focus?
	inc	hl
	ld	d,(hl)
	inc	hl
	push	hl
	ld	hl,(focus)
	or	a
	sbc	hl,de
	pop	hl
	jr	nz,.skip
	ld	a,(hl)			; row, column, length
	inc	hl
	ld	c,(hl)
	inc	hl
	ld	b,(hl)
	ld	l,a			; HL = 0x5800 + row * 32 + column
	ld	h,0
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	ld	a,c
	or	l
	ld	l,a
	ld	a,h
	or	0x58
	ld	h,a
.cell:
	ld	de,(sel_ptr)
	ld	a,(sel_mode)
	or	a
	jr	z,.back
	ld	a,(sel_count)
	inc	a
	jr	z,.next			; 255 saved: the rest stays
	ld	(sel_count),a
	ld	a,(hl)
	ld	(de),a
	and	0x38			; paper black: reverse it (ink on black ->
	jr	nz,.next		; black on ink), else it is reversed already
	ld	a,(hl)
	and	0x47
	ld	c,a
	and	0x07
	add	a,a
	add	a,a
	add	a,a
	ld	e,a
	ld	a,c
	and	0x40
	or	e
	ld	(hl),a
	jr	.next
.back:
	ld	a,(sel_left)		; only as many as were saved
	or	a
	jr	z,.next
	dec	a
	ld	(sel_left),a
	ld	a,(de)
	ld	(hl),a
.next:
	ld	de,(sel_ptr)
	inc	de
	ld	(sel_ptr),de
	inc	hl
	djnz	.cell
.skip:
	pop	hl
	pop	bc
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

; ---- History ----------------------------------------------------------------
; hist_buf holds entries [address][0][screen:2][entry length], newest last;
; when it is full the oldest go.

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
	ld	hl,4
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
	ld	hl,4
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
	ld	e,(hl)
	dec	hl
	ld	a,(hl)
	dec	hl
	ld	l,(hl)			; (screen low) ...
	ld	h,a
	ld	(back_screen),hl
	ld	hl,(hist_top)
	ld	d,0
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
	ld	e,(hl)
	ld	d,0
	inc	hl
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
focus:		dw	0xFFFF			; the focused link's number (0xFFFF: none)
fbest:		dw	0
find_no:	dw	0
list_first:	dw	0
list_sel:	dw	0
nav:		db	0			; NAV_NEW, NAV_RELOAD, NAV_BACK
back_screen:	dw	0
hist_top:	dw	0
hist_len:	dw	0
sel_count:	db	0
sel_left:	db	0
sel_mode:	db	0
sel_ptr:	dw	0
page_cut:	db	0
rx_end:		dw	0
http_status:	dw	0

req:		db	0x01,'G',HTTP_ASCII|HTTP_ONE	; http service, G
		dw	PAGE_MAX
code_end:					; the buffers aren't loaded from tape
req_url:	ds	URL_MAX+1+10+40		; (after req) url 0 accept 0 refuse
input:		ds	INPUT_MAX+1
tagbuf:		ds	16
cur_cells:	ds	CELL*WIDTH
pend_cells:	ds	CELL*WIDTH
word_cells:	ds	CELL*(WIDTH+2)
rowbuf:		ds	CELL*WIDTH
page_save:	ds	SAVE_SIZE		; an error reply's place in the page
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
runs:		ds	MAX_RUNS*5		; the screen's link pieces
sel_save:	ds	256			; the focused link's attributes
found_url:	ds	256			; the focused link's address
hist_buf:	ds	HIST_SIZE
snaps:		ds	MAX_SCREENS*SNAP_SIZE
	ASSERT	$ <= APP_SPARE_END

	SAVEBIN	"vvv.bin", vvv, code_end - vvv
