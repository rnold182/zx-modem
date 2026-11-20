; ZX MODEM menu - the launcher the modem plays when PLAY is pressed.
;
; Build: sjasmplus --inc=zx/lib --inc=sdk zx/menu/main.asm -> zxmenu.tap
;        (BASIC loader + CODE block; esp32/main/CMakeLists.txt does this)
;
; Shows the menu, asks the modem for its status (system V) and keeps the
; clock running from the 50 Hz frame counter between requests. Each request
; costs ~6 s of tape time, so it asks only at start, on R, for Modem Info, at
; midnight (to get the new date) and after an app.
;
; The menu items are the modem's apps (listed in the V reply) plus Modem Info
; and BASIC. An app is fetched with system O into APP_ADDR and CALLed; it
; uses the menu's routines through the API table below (sdk/zxmodem_api.inc,
; docs/app-api.md).

	DEVICE ZXSPECTRUM48

	include	"zxsys.inc"
	include	"ui.inc"
	MODULE	sdk			; the API contract, as sdk.name
	include	"zxmodem_api.inc"
	ENDMODULE

ITEM_ROW	equ	3		; first menu row; items are 2 rows apart
MAX_APPS	equ	5
MAX_ITEMS	equ	MAX_APPS+2	; + Modem Info, BASIC
ID_INFO		equ	0xFE		; item ids of the built-in items
ID_BASIC	equ	0xFF
KIND_APP	equ	1		; runs at APP_ADDR, returns to the menu
KIND_PROGRAM	equ	2		; replaces the menu (later: the browser)
A_DIM		equ	0x07		; an item that isn't available yet
HINT_ROW	equ	18
MSG_ROW		equ	20
STATUS_ROW	equ	22		; rows 22 and 23

; Offsets in the info reply (docs/link-protocol.md, system V)
I_FW_MAJ	equ	0
I_FW_MIN	equ	1
I_PROTO		equ	2
I_WIFI		equ	3
I_IP		equ	4
I_RSSI		equ	8
I_CLK		equ	9
I_YEAR		equ	10
I_MONTH		equ	12
I_DAY		equ	13
I_HOUR		equ	14
I_MIN		equ	15
I_SEC		equ	16
I_SSID_LEN	equ	18
I_SSID		equ	19
INFO_FIXED	equ	19

RXBUF_SIZE	equ	256		; info + app list

	org	32768
code_start:

; Entry points for BASIC, at fixed addresses (see zx/lib/basic.asm):
	jp	start			; 32768  RANDOMIZE USR 32768: the menu
	jp	basic_fetch		; 32771  LET n=USR 32771: fetch U$
	jp	basic_print		; 32774  RANDOMIZE USR 32774: print it
basic_status:	db	0		; 32777  0 OK, 1 modem error, 2 SPACE, 3 no reply, 4 no U$
basic_http:	dw	0		; 32778  HTTP status
basic_len:	dw	0		; 32780  bytes received
	ASSERT	basic_status == sdk.basic_status && basic_len == sdk.basic_len

; App API, version 1: shared variables, then one JP per routine. The
; addresses are the contract in sdk/zxmodem_api.inc; the ASSERTs keep them.
api_version:	db	1
scr_row:	db	0
scr_col:	db	0
scr_attr:	db	0x07
link_header:	ds	10
	ASSERT	api_version == sdk.api_version && scr_row == sdk.scr_row
	ASSERT	scr_col == sdk.scr_col && scr_attr == sdk.scr_attr
	ASSERT	link_header == sdk.link_header
	ASSERT	$ == sdk.scr_at
	jp	scr_at
	ASSERT	$ == sdk.scr_putc
	jp	scr_putc
	ASSERT	$ == sdk.scr_print
	jp	scr_print
	ASSERT	$ == sdk.scr_spaces
	jp	scr_spaces
	ASSERT	$ == sdk.scr_clear_row
	jp	scr_clear_row
	ASSERT	$ == sdk.scr_paint
	jp	scr_paint
	ASSERT	$ == sdk.scr_cls
	jp	scr_cls
	ASSERT	$ == sdk.scr_dec
	jp	scr_dec
	ASSERT	$ == sdk.scr_dec2
	jp	scr_dec2
	ASSERT	$ == sdk.link_request
	jp	link_request
	ASSERT	$ == sdk.link_receive
	jp	link_receive
	ASSERT	$ == sdk.get_key
	jp	get_key
	ASSERT	$ == sdk.wait_key
	jp	wait_key
	ASSERT	$ == sdk.draw_title
	jp	draw_title
	ASSERT	$ == sdk.text_at
	jp	text_at
	ASSERT	$ == sdk.edit_line
	jp	edit_line
	ASSERT	$ == sdk.putc_wrap
	jp	putc_wrap
	ASSERT	$ == sdk.API_END

start:
	ei
	ld	a,(BORDCR)
	ld	(saved_bordcr),a
	call	reset_items		; built-in items until the modem lists its apps
	call	add_builtins
	call	draw_menu
	call	fetch_items

main_loop:
	halt				; wait for the next frame (keyboard is read then)
	call	tick_clock
	ld	a,(need_refresh)
	or	a
	call	nz,fetch_items
	call	get_key
	or	a
	jr	z,main_loop
	cp	K_DOWN
	jr	z,.down
	cp	'6'
	jr	z,.down
	cp	K_UP
	jr	z,.up
	cp	'7'
	jr	z,.up
	cp	K_ENTER
	jr	z,.enter
	or	0x20			; letters: either case
	cp	'r'
	jr	z,.refresh
	sub	'1'			; digits pick an item directly
	ld	hl,n_items
	cp	(hl)
	jr	nc,main_loop
	call	select
	jr	.enter
.down:
	ld	a,(n_items)
	ld	b,a
	ld	a,(sel)
	inc	a
	cp	b
	jr	c,.move
	xor	a
	jr	.move
.up:
	ld	a,(sel)
	dec	a
	jp	p,.move
	ld	a,(n_items)
	dec	a
.move:
	call	select
	jr	main_loop
.refresh:
	call	fetch_items
	jr	main_loop
.enter:
	ld	a,(sel)
	ld	hl,item_id
	call	add_a_hl
	ld	a,(hl)
	cp	ID_INFO
	jr	z,.info
	cp	ID_BASIC
	jr	z,.quit
	call	run_app
	jp	main_loop
.info:
	call	show_info
	call	draw_menu
	jp	main_loop
.quit:
	ld	a,(saved_bordcr)	; leave BASIC's colours as they were
	ld	(BORDCR),a
	rrca
	rrca
	rrca
	and	7
	out	(0xFE),a		; CLS doesn't touch the border
	call	ROM_CLS
	ret				; back to BASIC

; ---- Menu screen ---------------------------------------------------------------

draw_menu:
	ld	a,A_BODY
	call	scr_cls
	ld	hl,s_title
	call	draw_title
	ld	b,HINT_ROW
	ld	c,1
	call	scr_at
	ld	a,A_HINT
	ld	(scr_attr),a
	ld	hl,s_hint
	call	scr_print
	call	draw_items
	jp	draw_status

; draw_items: the item list, numbered, with the bar on the current one.
draw_items:
	ld	b,ITEM_ROW
.clear:
	push	bc
	ld	a,A_BODY
	call	scr_clear_row
	pop	bc
	inc	b
	ld	a,b
	cp	ITEM_ROW+2*MAX_ITEMS
	jr	c,.clear
	ld	a,(n_items)		; keep the bar on an item that exists
	ld	b,a
	ld	a,(sel)
	cp	b
	jr	c,.sel_ok
	xor	a
	ld	(sel),a
.sel_ok:
	ld	c,0
.item:
	ld	a,c
	ld	hl,n_items
	cp	(hl)
	jr	nc,.done
	push	bc
	ld	a,c
	add	a,a
	add	a,ITEM_ROW
	ld	b,a
	ld	c,3
	call	scr_at
	pop	bc
	ld	a,c
	call	item_attr
	ld	(scr_attr),a
	ld	a,c
	add	a,'1'
	call	scr_putc
	ld	a,' '
	call	scr_putc
	ld	a,' '			; scr_putc doesn't keep A
	call	scr_putc
	ld	a,c
	add	a,a
	ld	hl,item_name
	call	add_a_hl
	ld	a,(hl)
	inc	hl
	ld	h,(hl)
	ld	l,a
	call	scr_print
	inc	c
	jr	.item
.done:
	ld	a,(sel)
	ld	c,A_SEL
	jp	paint_item

; item_attr: A = the attribute for item A (dim if not available yet).
item_attr:
	ld	hl,item_avail
	call	add_a_hl
	ld	a,(hl)
	or	a
	ld	a,A_ITEM
	ret	nz
	ld	a,A_DIM
	ret

; draw_title: title bar on row 0 with text HL and the colour stripes.
draw_title:
	push	hl
	ld	b,0
	ld	a,A_TITLE
	call	scr_clear_row
	ld	c,1
	call	scr_at
	pop	hl
	call	scr_print
	ld	b,0
	ld	c,26
	call	scr_at
	ld	hl,stripe_attrs
	ld	b,5
.stripe:
	ld	a,(hl)
	ld	(scr_attr),a
	ld	a,1			; glyph 1: diagonal
	call	scr_putc
	inc	hl
	djnz	.stripe
	ret

; select: move the highlight bar to item A, clear the message line.
select:
	push	af
	ld	a,(sel)
	push	af
	call	item_attr
	ld	c,a
	pop	af
	call	paint_item
	pop	af
	ld	(sel),a
	ld	c,A_SEL
	call	paint_item
	ld	b,MSG_ROW
	ld	a,A_BODY
	jp	scr_clear_row

; paint_item: give item A's row attribute C (columns 1-30).
paint_item:
	add	a,a
	add	a,ITEM_ROW
	ld	b,a
	ld	a,c
	ld	c,30
	ld	e,1
	jp	scr_paint

; show_msg: string HL on the message line.
show_msg:
	push	hl
	ld	b,MSG_ROW
	ld	a,A_MSG
	call	scr_clear_row
	ld	c,1
	call	scr_at
	pop	hl
	jp	scr_print

; ---- Status line (rows 22-23) --------------------------------------------------

draw_status:
	ld	b,STATUS_ROW
	ld	a,A_STATUS
	call	scr_clear_row
	ld	b,STATUS_ROW+1
	ld	a,A_STATUS
	call	scr_clear_row
	ld	b,STATUS_ROW
	ld	c,1
	call	scr_at
	ld	a,(st_have)
	cp	1
	jr	z,.have
	or	a
	ld	hl,s_asking
	jp	z,scr_print
	ld	hl,s_noreply
	jp	scr_print
.have:
	ld	a,(info+I_WIFI)
	ld	hl,s_notsetup
	or	a
	jr	z,.text
	ld	hl,s_connecting
	dec	a
	jr	z,.text
	ld	hl,s_wifi
	call	scr_print
	ld	b,20			; room before the signal bars
	call	print_ssid
	call	draw_bars
	call	draw_ip
	jr	draw_time
.text:
	call	scr_print
	jr	draw_time

; print_ssid: the network name, at most B characters (it can be 32 long).
print_ssid:
	ld	hl,ssid
.ch:
	ld	a,(hl)
	or	a
	ret	z
	call	scr_putc
	inc	hl
	djnz	.ch
	ret

; draw_bars: signal strength as 4 bars in columns 27-30 of row 22.
draw_bars:
	ld	a,(info+I_RSSI)		; signed dBm; +128 makes it unsigned
	add	a,128
	ld	c,4
	cp	128-55
	jr	nc,.level
	dec	c
	cp	128-65
	jr	nc,.level
	dec	c
	cp	128-75
	jr	nc,.level
	dec	c
.level:					; C = bars to light (1-4)
	ld	b,STATUS_ROW
	push	bc
	ld	c,27
	call	scr_at
	pop	bc
	ld	b,1
.bar:
	ld	a,A_STATUS
	ld	(scr_attr),a
	ld	a,c
	cp	b
	jr	nc,.lit
	ld	a,A_BAR_OFF
	ld	(scr_attr),a
.lit:
	ld	a,b
	inc	a			; glyphs 2-5: bars of rising height
	call	scr_putc
	inc	b
	ld	a,b
	cp	5
	jr	c,.bar
	ld	a,A_STATUS
	ld	(scr_attr),a
	ret

; draw_ip: the IP address at the start of row 23.
draw_ip:
	ld	b,STATUS_ROW+1
	ld	c,1
	call	scr_at
	ld	hl,info+I_IP
	ld	b,4
.octet:
	push	bc
	ld	a,(hl)
	call	scr_dec
	pop	bc
	inc	hl
	dec	b
	ret	z
	ld	a,'.'
	call	scr_putc
	jr	.octet

; draw_time: date and time at the end of row 23, if the modem's clock is set.
draw_time:
	ld	a,(info+I_CLK)
	or	a
	ret	z
	ld	b,STATUS_ROW+1
	ld	c,16
	call	scr_at
	ld	hl,(info+I_YEAR)
	call	scr_year
	ld	a,'-'
	call	scr_putc
	ld	a,(info+I_MONTH)
	call	scr_dec2
	ld	a,'-'
	call	scr_putc
	ld	a,(info+I_DAY)
	call	scr_dec2
	ld	a,' '
	call	scr_putc
	ld	a,(info+I_HOUR)
	call	scr_dec2
	ld	a,':'
	call	scr_putc
	ld	a,(info+I_MIN)
	jp	scr_dec2

; ---- Talking to the modem ------------------------------------------------------

; fetch_items: fetch_status, then redraw the items (the app list may have
; changed). Only on the menu screen.
fetch_items:
	call	fetch_status
	jp	draw_items

; fetch_status: system V -> info and the app list, then redraw the status line.
fetch_status:
	xor	a
	ld	(need_refresh),a
	ld	(st_have),a
	call	draw_status		; "Asking the modem..."
	ld	hl,req_info
	ld	bc,2
	call	link_request
	ld	ix,rxbuf
	ld	de,RXBUF_SIZE
	call	link_receive
	jr	nc,.fail
	cp	7			; info reply?
	jr	nz,.fail
	ld	(rx_len),bc
	ld	hl,INFO_FIXED-1		; at least the fixed part?
	or	a
	sbc	hl,bc
	jr	nc,.fail
	ld	hl,rxbuf
	ld	de,info
	ld	bc,INFO_FIXED
	ldir
	ld	a,(info+I_SSID_LEN)
	cp	33
	jr	c,.len
	ld	a,32
.len:
	ld	de,ssid
	or	a
	jr	z,.term
	ld	c,a
	ld	b,0
	ld	hl,rxbuf+I_SSID
	ldir
.term:
	xor	a
	ld	(de),a
	ld	hl,rxbuf		; the app list follows the SSID (if the modem sends one)
	ld	de,(rx_len)
	add	hl,de
	ld	(apps_end),hl
	call	reset_items
	ld	a,(info+I_SSID_LEN)
	add	a,I_SSID
	ld	hl,rxbuf
	call	add_a_hl
	call	parse_apps
	call	add_builtins
	ld	a,(FRAMES)		; the clock starts counting from now
	ld	(frames_last),a
	xor	a
	ld	(frame_acc),a
	ld	a,1
	jr	.done
.fail:
	ld	a,2
.done:
	ld	(st_have),a
	jp	draw_status

; tick_clock: advance the clock by the frames counted since the last call;
; redraw the time when the minute changes.
tick_clock:
	ld	a,(st_have)
	dec	a
	ret	nz
	ld	a,(info+I_CLK)
	or	a
	ret	z
	ld	a,(FRAMES)
	ld	hl,frames_last
	ld	b,(hl)
	ld	(hl),a
	sub	b			; frames since last time (mod 256)
	ld	hl,frame_acc
	add	a,(hl)
	ld	(hl),a
	cp	50
	ret	c
	sub	50
	ld	(hl),a
	ld	hl,info+I_SEC
	inc	(hl)
	ld	a,(hl)
	cp	60
	ret	c
	ld	(hl),0
	dec	hl			; minutes
	inc	(hl)
	ld	a,(hl)
	cp	60
	jr	c,.redraw
	ld	(hl),0
	dec	hl			; hours
	inc	(hl)
	ld	a,(hl)
	cp	24
	jr	c,.redraw
	ld	(hl),0
	ld	a,1			; a new day: ask the modem for the date
	ld	(need_refresh),a
.redraw:
	jp	draw_time

; get_key: A = new key from the ROM's keyboard scan, or 0.
get_key:
	ld	hl,FLAGS
	xor	a
	bit	5,(hl)
	ret	z
	res	5,(hl)
	ld	a,(LAST_K)
	ret

; ---- Apps ----------------------------------------------------------------------

; run_app: the current item is app A. Fetch it (system O) into APP_ADDR and
; CALL it; it returns with RET. Then ask for the status again (an app may
; have changed it, e.g. the Wi-Fi network).
run_app:
	ld	(req_app+2),a
	ld	a,(sel)
	ld	hl,item_avail
	call	add_a_hl
	ld	a,(hl)
	or	a
	jr	z,.soon
	ld	a,(sel)
	ld	hl,item_kind
	call	add_a_hl
	ld	a,(hl)
	cp	KIND_APP		; whole programs (the browser): not yet
	jr	nz,.soon
	ld	hl,s_loading
	call	show_msg
	ld	hl,req_app
	ld	bc,3
	call	link_request
	ld	ix,sdk.APP_ADDR
	ld	de,sdk.APP_END-sdk.APP_ADDR
	call	link_receive
	jr	nc,.fail
	cp	6			; app code?
	jr	nz,.fail
	ld	hl,(link_header+4)	; for our load address?
	ld	de,sdk.APP_ADDR
	or	a
	sbc	hl,de
	jr	nz,.fail
	call	sdk.APP_ADDR
	call	draw_menu
	jp	fetch_items
.soon:
	ld	hl,s_soon
	jp	show_msg
.fail:
	ld	hl,s_load_fail
	jp	show_msg

; ---- Item list -------------------------------------------------------------------

; reset_items: an empty list.
reset_items:
	xor	a
	ld	(n_items),a
	ld	hl,name_pool
	ld	(pool_ptr),hl
	ret

; add_builtins: Modem Info and BASIC, always last.
add_builtins:
	ld	a,ID_INFO
	ld	bc,1*256+0		; available, kind 0
	ld	hl,s_item_info
	call	add_item
	ld	a,ID_BASIC
	ld	bc,1*256+0
	ld	hl,s_item_basic
	; fall through

; add_item: id A, kind C, available B (0/1), name HL (0-terminated, kept).
add_item:
	push	hl
	ld	e,a
	ld	a,(n_items)
	cp	MAX_ITEMS
	jr	nc,.full
	ld	hl,item_id
	call	add_a_hl
	ld	(hl),e
	ld	a,(n_items)
	ld	hl,item_kind
	call	add_a_hl
	ld	(hl),c
	ld	a,(n_items)
	ld	hl,item_avail
	call	add_a_hl
	ld	(hl),b
	ld	a,(n_items)
	add	a,a
	ld	hl,item_name
	call	add_a_hl
	pop	de
	ld	(hl),e
	inc	hl
	ld	(hl),d
	ld	hl,n_items
	inc	(hl)
	ret
.full:
	pop	hl
	ret

; parse_apps: the app list at HL (up to apps_end) -> items. It is
; [count] then per app [id][kind][flags][name length][name], flags bit 0 =
; available. Names are copied (at most 24 characters) into name_pool.
parse_apps:
	ld	de,1
	call	fits
	ret	nc
	ld	b,(hl)			; count
	inc	hl
.rec:
	ld	a,b
	or	a
	ret	z
	ld	a,(n_items)
	cp	MAX_APPS
	ret	nc
	push	bc
	ld	de,4
	call	fits
	jr	nc,.end
	ld	a,(hl)
	ld	(app_id),a
	inc	hl
	ld	a,(hl)
	ld	(app_kind),a
	inc	hl
	ld	a,(hl)
	and	1
	ld	(app_avail),a
	inc	hl
	ld	c,(hl)			; name length
	inc	hl
	ld	e,c
	ld	d,0
	push	de
	call	fits
	pop	de
	jr	nc,.end
	push	hl
	add	hl,de
	ld	(app_next),hl
	pop	hl
	ld	a,c
	cp	25
	jr	c,.copy
	ld	a,24
.copy:
	ld	de,(pool_ptr)
	push	de
	or	a
	jr	z,.zero
	ld	c,a
	ld	b,0
	ldir
.zero:
	xor	a
	ld	(de),a
	inc	de
	ld	(pool_ptr),de
	pop	hl			; the name, now 0-terminated
	ld	a,(app_kind)
	ld	c,a
	ld	a,(app_avail)
	ld	b,a
	ld	a,(app_id)
	call	add_item
	ld	hl,(app_next)
	pop	bc
	dec	b
	jr	.rec
.end:
	pop	bc
	ret

; fits: carry set if DE bytes from HL end by apps_end. Keeps HL; DE lost.
fits:
	push	hl
	add	hl,de
	ex	de,hl
	ld	hl,(apps_end)
	or	a
	sbc	hl,de
	pop	hl
	ccf
	ret

; add_a_hl: HL += A.
add_a_hl:
	add	a,l
	ld	l,a
	ret	nc
	inc	h
	ret

; ---- Modem Info screen ---------------------------------------------------------

show_info:
	ld	a,A_BODY
	call	scr_cls
	ld	hl,s_info_title
	call	draw_title
	call	draw_status
	call	fetch_status
	ld	a,A_ITEM
	ld	(scr_attr),a
	ld	a,(st_have)
	cp	1
	jr	z,.lines
	ld	b,3
	ld	c,1
	call	scr_at
	ld	hl,s_noreply_long
	call	scr_print
	jp	.wait
.lines:
	ld	b,3
	call	at_row
	ld	hl,s_l_fw
	call	scr_print
	ld	a,(info+I_FW_MAJ)
	call	scr_dec
	ld	a,'.'
	call	scr_putc
	ld	a,(info+I_FW_MIN)
	call	scr_dec

	ld	b,5
	call	at_row
	ld	hl,s_l_proto
	call	scr_print
	ld	a,(info+I_PROTO)
	call	scr_dec

	ld	b,7
	call	at_row
	ld	hl,s_l_wifi
	call	scr_print
	ld	a,(info+I_WIFI)
	ld	hl,s_w0
	or	a
	jr	z,.w
	ld	hl,s_w1
	dec	a
	jr	z,.w
	ld	hl,s_w2
.w:
	call	scr_print

	ld	b,9
	call	at_row
	ld	hl,s_l_net
	call	scr_print
	ld	b,20
	call	print_ssid

	ld	b,11
	call	at_row
	ld	hl,s_l_ip
	call	scr_print
	ld	hl,info+I_IP
	ld	b,4
.octet:
	push	bc
	ld	a,(hl)
	call	scr_dec
	pop	bc
	inc	hl
	dec	b
	jr	z,.signal
	ld	a,'.'
	call	scr_putc
	jr	.octet
.signal:
	ld	b,13
	call	at_row
	ld	hl,s_l_signal
	call	scr_print
	ld	a,(info+I_RSSI)
	call	scr_dec_signed
	ld	hl,s_dbm
	call	scr_print

	ld	b,15
	call	at_row
	ld	hl,s_l_clock
	call	scr_print
	ld	a,(info+I_CLK)
	ld	hl,s_clk_set
	or	a
	jr	nz,.c
	ld	hl,s_clk_unset
.c:
	call	scr_print
.wait:
	ld	b,HINT_ROW
	ld	c,1
	call	scr_at
	ld	a,A_HINT
	ld	(scr_attr),a
	ld	hl,s_back
	call	scr_print
.key:
	halt
	call	tick_clock
	call	get_key
	or	a
	jr	z,.key
	ret

; at_row: cursor to row B, column 1.
at_row:
	ld	c,1
	jp	scr_at

; ---- Data ----------------------------------------------------------------------

req_info:	db	0x00,'V'		; system service, version/status
req_app:	db	0x00,'O',0		; system service, app code (id patched in)

s_title:	db	"ZX MODEM",0
s_info_title:	db	"MODEM INFO",0
s_item_info:	db	"Modem Info",0
s_item_basic:	db	"BASIC",0
s_hint:		db	"6/7 move  ENTER go  R refresh",0
s_soon:		db	"Coming soon.",0
s_loading:	db	"Loading... SPACE=stop",0
s_load_fail:	db	"Could not load it. Try again.",0
s_asking:	db	"Asking modem... SPACE=stop",0
s_noreply:	db	"No reply from modem (R: retry)",0
s_noreply_long:	db	"No reply from the modem.",0
s_notsetup:	db	"WiFi: not set up",0
s_connecting:	db	"WiFi: connecting...",0
s_wifi:		db	"WiFi: ",0
s_l_fw:		db	"Firmware   ",0
s_l_proto:	db	"Protocol   ",0
s_l_wifi:	db	"Wi-Fi      ",0
s_l_net:	db	"Network    ",0
s_l_ip:		db	"IP address ",0
s_l_signal:	db	"Signal     ",0
s_l_clock:	db	"Clock      ",0
s_w0:		db	"not set up",0
s_w1:		db	"connecting",0
s_w2:		db	"connected",0
s_dbm:		db	" dBm",0
s_clk_set:	db	"set by NTP",0
s_clk_unset:	db	"not set yet",0
s_back:		db	"Any key: back to the menu",0

; Title stripes: each cell is the diagonal glyph, ink = this stripe's colour,
; paper = the previous one (black, red, yellow, green, cyan, black), BRIGHT.
stripe_attrs:	db	0x42,0x56,0x74,0x65,0x68

; Custom glyphs for scr_putc, codes 1-5.
scr_glyphs:
	db	0x01,0x03,0x07,0x0F,0x1F,0x3F,0x7F,0xFF	; 1: diagonal
	db	0x00,0x00,0x00,0x00,0x00,0x7E,0x7E,0x00	; 2: bar, height 2
	db	0x00,0x00,0x00,0x7E,0x7E,0x7E,0x7E,0x00	; 3: height 4
	db	0x00,0x7E,0x7E,0x7E,0x7E,0x7E,0x7E,0x00	; 4: height 6
	db	0x7E,0x7E,0x7E,0x7E,0x7E,0x7E,0x7E,0x00	; 5: height 7
	db	0x00,0x18,0x24,0x24,0x7E,0x7E,0x7E,0x00	; 6: padlock
	db	0x00,0x01,0x02,0x04,0x88,0x50,0x20,0x00	; 7: tick
	db	0x00,0x00,0x18,0x3C,0x3C,0x18,0x00,0x00	; 8: dot

sel:		db	0
saved_bordcr:	db	0
st_have:	db	0		; 0 asking, 1 info valid, 2 no reply
need_refresh:	db	0
frames_last:	db	0
frame_acc:	db	0
info:		ds	INFO_FIXED
ssid:		ds	33
rx_len:		dw	0
apps_end:	dw	0
app_id:		db	0
app_kind:	db	0
app_avail:	db	0
app_next:	dw	0
n_items:	db	0
item_id:	ds	MAX_ITEMS
item_kind:	ds	MAX_ITEMS
item_avail:	ds	MAX_ITEMS
item_name:	ds	MAX_ITEMS*2
pool_ptr:	dw	0

	include	"screen.asm"
	include	"net.asm"
	include	"basic.asm"
	include	"ui.asm"

code_end:

; Buffers past code_end: reserved, not saved to tape.
basic_req:	ds	4+255
rxbuf:		ds	RXBUF_SIZE
name_pool:	ds	MAX_APPS*25
	ASSERT	$ <= sdk.APP_ADDR


; ---- BASIC loader: 10 CLEAR 32767: LOAD ""CODE: RANDOMIZE USR 32768 ------------
; Assembled into spare memory only to be saved. Number literals are followed
; by 0x0E and their hidden 5-byte integer form.

T_CLEAR		equ	0xFD
T_LOAD		equ	0xEF
T_CODE		equ	0xAF
T_RANDOMIZE	equ	0xF9
T_USR		equ	0xC0

	org	0xC000
basic:
	db	0,10
	dw	.end - .text
.text:
	db	T_CLEAR,"32767",0x0E,0,0
	dw	32767
	db	0
	db	':',T_LOAD,0x22,0x22,T_CODE
	db	':',T_RANDOMIZE,T_USR,"32768",0x0E,0,0
	dw	32768
	db	0
	db	0x0D
.end:
basic_end:

	EMPTYTAP "zxmenu.tap"
	SAVETAP  "zxmenu.tap", BASIC, "ZX MODEM", basic, basic_end - basic, 10
	SAVETAP  "zxmenu.tap", CODE, "zxmodem", code_start, code_end - code_start
