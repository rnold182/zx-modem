; wifisetup.asm - app 1: the Wi-Fi setup screen.
;
; Build: sjasmplus --inc=sdk apps/wifisetup/wifisetup.asm -> wifisetup.bin
; A ZX MODEM app (docs/app-api.md): the menu fetches it with system O 1 into
; APP_ADDR and CALLs it there; it returns with RET. It uses the menu's
; screen, link and text-entry routines through the API table.
;
; Flow: scan (system L) -> pick a network -> type the password -> join
; (system J). The modem keeps the real network names and the list order,
; so a join sends only the list position and the password. Networks the
; modem has saved (up to 5) are marked; they join without a password, and
; F forgets one (system F).

	DEVICE ZXSPECTRUM48

	include	"zxsys.inc"
	include	"ui.inc"
	include	"zxmodem_api.inc"

NET_MAX		equ	19		; list rows 2-20, "Other network..." below
LIST_ROW	equ	2
FIELD_ROW	equ	8		; text entry: rows 8-9, 64 cells
HINT_ROW	equ	23
NETBUF_SIZE	equ	NET_MAX*36	; [rssi][auth][flags][len][name up to 32]
MARK_ROW	equ	22		; legend for the marks
REPLY_SIZE	equ	64		; join reply: IP address or error text
A_BAR_ON	equ	0x45		; bright cyan on black
A_BAR_DIM	equ	0x01		; blue on black
A_LOCK		equ	0x46		; bright yellow on black

	org	APP_ADDR

wifi_setup:
	xor	a
	ld	(cur),a
.scan:
	call	frame
	ld	bc,LIST_ROW*256+1
	ld	a,A_MSG
	ld	hl,s_scanning
	call	text_at
	ld	hl,req_scan
	ld	bc,2
	call	link_request
	ld	ix,netbuf
	ld	de,NETBUF_SIZE
	call	link_receive
	jp	nc,no_reply_menu
	cp	4			; netlist?
	jp	nz,error_reply_menu
	call	index_records
.list:
	call	frame
	ld	a,(net_count)
	or	a
	jr	nz,.rows
	ld	bc,(LIST_ROW+2)*256+1
	ld	a,A_MSG
	ld	hl,s_none
	call	text_at
.rows:
	call	draw_list
	call	highlight
.keys:
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
	jr	z,.pick
	cp	' '
	ret	z			; SPACE: back to the menu
	or	0x20
	cp	'f'
	jp	z,.forget
	cp	's'
	jr	nz,.keys
	xor	a
	ld	(cur),a
	jp	.scan
.down:
	ld	a,(net_count)		; the last row (index = count) is "Other"
	ld	b,a
	ld	a,(cur)
	cp	b
	jr	nc,.top
	inc	a
	jr	.move
.top:
	xor	a
	jr	.move
.up:
	ld	a,(cur)
	or	a
	jr	nz,.prev
	ld	a,(net_count)
	jr	.move
.prev:
	dec	a
.move:
	call	move_cur
	jr	.keys

.pick:
	ld	a,(cur)
	ld	hl,net_count
	cp	(hl)
	jr	z,.other
	call	rec_ptr			; HL = [rssi][auth][flags][len][name]
	inc	hl
	ld	c,(hl)			; auth
	inc	hl
	ld	a,(hl)			; flags
	dec	hl
	push	bc
	push	af
	call	copy_name		; for the screens that follow
	pop	af
	pop	bc
	and	1			; saved: the modem has the password
	jr	nz,.open
	ld	a,c
	or	a
	jr	z,.open			; open network: no password
	call	ask_password
	jp	nc,.list		; CAPS+1: back to the list
	jr	.by_index
.open:
	xor	a
	ld	(pass_buf),a
.by_index:
	ld	hl,reqbuf		; 00 'J' index password
	ld	(hl),0
	inc	hl
	ld	(hl),'J'
	inc	hl
	ld	a,(cur)
	ld	(hl),a
	inc	hl
	call	append_pass
	jp	do_join

.other:
	call	ask_name
	jp	nc,.list
	ld	a,(ssid_buf)
	or	a
	jp	z,.list			; no name typed
	call	ask_password		; may stay empty: an open network
	jp	nc,.list
	ld	hl,reqbuf		; 00 'J' FF name 0 password
	ld	(hl),0
	inc	hl
	ld	(hl),'J'
	inc	hl
	ld	(hl),0xFF
	inc	hl
	ld	de,ssid_buf
.name:
	ld	a,(de)
	ld	(hl),a
	inc	hl
	inc	de
	or	a
	jr	nz,.name
	call	append_pass
	jp	do_join

.forget:
	ld	a,(cur)			; only a saved network, not "Other"
	ld	hl,net_count
	cp	(hl)
	jp	nc,.keys
	call	rec_ptr
	inc	hl
	inc	hl
	ld	a,(hl)			; flags
	and	1
	jp	z,.keys
	ld	b,MARK_ROW
	ld	a,A_BODY
	call	scr_clear_row
	ld	bc,MARK_ROW*256+1
	ld	a,A_MSG
	ld	hl,s_forgetting
	call	text_at
	ld	a,(cur)
	ld	(req_forget+2),a
	ld	hl,req_forget
	ld	bc,3
	call	link_request
	ld	ix,netbuf		; the reply is the list again, marks updated
	ld	de,NETBUF_SIZE
	call	link_receive
	jp	nc,no_reply_menu
	cp	4
	jp	nz,error_reply_menu
	call	index_records
	jp	.list

; ---- Joining -------------------------------------------------------------------

; do_join: send the request built in reqbuf (HL = its end) and show the result.
do_join:
	ld	de,reqbuf
	or	a
	sbc	hl,de
	push	hl
	call	frame_plain
	ld	bc,4*256+1
	ld	a,A_ITEM
	ld	hl,s_connecting
	call	text_at
	ld	bc,5*256+1
	ld	a,A_ITEM
	ld	hl,ssid_buf
	call	text_at
	ld	bc,7*256+1
	ld	a,A_HINT
	ld	hl,s_wait
	call	text_at
	pop	bc
	ld	hl,reqbuf
	call	link_request
	call	wipe_secrets		; the password isn't needed any more
	ld	ix,replybuf		; not netbuf: the list must survive a retry
	ld	de,REPLY_SIZE
	call	link_receive
	jr	nc,.noreply
	cp	5			; wifi: connected
	jr	z,.ok
	cp	1			; error: the modem says why
	jr	nz,.noreply
	ld	hl,replybuf
	call	terminate_reply
	ld	bc,10*256+1
	ld	a,A_ERR
	ld	hl,s_failed
	call	text_at
	ld	bc,11*256+1
	ld	a,A_ITEM
	ld	hl,replybuf
	call	text_at
	jr	.again
.noreply:
	ld	bc,10*256+1
	ld	a,A_ERR
	ld	hl,s_noreply
	call	text_at
.again:
	ld	bc,HINT_ROW*256+1
	ld	a,A_HINT
	ld	hl,s_key_list
	call	text_at
	call	wait_key
	jp	wifi_setup.list
.ok:
	ld	bc,10*256+1
	ld	a,A_OK
	ld	hl,s_connected
	call	text_at
	ld	bc,12*256+1
	ld	a,A_ITEM
	ld	hl,s_ip
	call	text_at
	ld	hl,replybuf		; [ip0][ip1][ip2][ip3]
	ld	b,4
.octet:
	push	bc
	ld	a,(hl)
	call	scr_dec
	pop	bc
	inc	hl
	dec	b
	jr	z,.saved
	ld	a,'.'
	call	scr_putc
	jr	.octet
.saved:
	ld	bc,14*256+1
	ld	a,A_ITEM
	ld	hl,s_saved
	call	text_at
	ld	bc,HINT_ROW*256+1
	ld	a,A_HINT
	ld	hl,s_key_menu
	call	text_at
	call	wait_key
	ret				; to the menu

; Scan failures: show why, then back to the menu.
no_reply_menu:
	ld	bc,(LIST_ROW+2)*256+1
	ld	a,A_ERR
	ld	hl,s_noreply
	call	text_at
	jr	back_to_menu
error_reply_menu:
	cp	1
	jr	nz,no_reply_menu
	ld	hl,netbuf
	call	terminate_reply
	ld	bc,(LIST_ROW+2)*256+1
	ld	a,A_ERR
	ld	hl,netbuf
	call	text_at
back_to_menu:
	ld	bc,HINT_ROW*256+1
	ld	a,A_HINT
	ld	hl,s_key_menu
	call	text_at
	call	wait_key
	ret

; terminate_reply: an error reply's text is at HL, BC long: end it with 0
; (at most 31 characters, one screen line).
terminate_reply:
	ld	a,b
	or	a
	jr	nz,.cap
	ld	a,c
	cp	31
	jr	c,.len
.cap:
	ld	c,31
.len:
	ld	b,0
	add	hl,bc
	ld	(hl),0
	ret

; wipe_secrets: clear the password and the request that carried it.
wipe_secrets:
	ld	hl,pass_buf
	ld	b,pass_end-pass_buf
	call	.zero
	ld	hl,reqbuf
	ld	b,req_end-reqbuf
.zero:
	ld	(hl),0
	inc	hl
	djnz	.zero
	ret

; append_pass: copy pass_buf (without its 0) to HL; HL ends after it.
append_pass:
	ld	de,pass_buf
.ch:
	ld	a,(de)
	or	a
	ret	z
	ld	(hl),a
	inc	hl
	inc	de
	jr	.ch

; ---- Network list --------------------------------------------------------------

; index_records: find the records in netbuf (BC bytes) -> net_ptrs, net_count.
index_records:
	ld	hl,netbuf
	add	hl,bc
	ld	(rec_end),hl
	ld	hl,netbuf
	ld	de,net_ptrs
	xor	a
	ld	(net_count),a
.next:
	push	hl			; a whole 4-byte record head left?
	inc	hl
	inc	hl
	inc	hl
	inc	hl
	ld	bc,(rec_end)
	or	a
	sbc	hl,bc
	pop	hl
	ret	z
	ret	nc
	ld	a,l			; net_ptrs[count] = HL
	ld	(de),a
	inc	de
	ld	a,h
	ld	(de),a
	inc	de
	ld	a,(net_count)
	inc	a
	ld	(net_count),a
	cp	NET_MAX
	ret	z
	inc	hl			; skip rssi, auth, flags
	inc	hl
	inc	hl
	ld	c,(hl)			; name length
	ld	b,0
	inc	hl
	add	hl,bc
	jr	.next

; rec_ptr: HL = record of list entry A.
rec_ptr:
	ld	l,a
	ld	h,0
	add	hl,hl
	ld	de,net_ptrs
	add	hl,de
	ld	a,(hl)
	inc	hl
	ld	h,(hl)
	ld	l,a
	ret

; copy_name: the record's name (HL points at its auth byte) -> ssid_buf.
copy_name:
	inc	hl
	inc	hl
	ld	a,(hl)			; length
	inc	hl
	cp	33
	jr	c,.len
	ld	a,32
.len:
	ld	de,ssid_buf
	or	a
	jr	z,.end
	ld	c,a
	ld	b,0
	ldir
.end:
	xor	a
	ld	(de),a
	ret

draw_list:
	xor	a
.row:
	push	af
	call	draw_row
	pop	af
	ld	hl,net_count
	cp	(hl)
	ret	z
	inc	a
	jr	.row

; draw_row: draw entry A (A = net_count: "Other network...") unhighlighted.
draw_row:
	push	af
	add	a,LIST_ROW
	ld	b,a
	ld	a,A_BODY
	call	scr_clear_row
	pop	af
	ld	hl,net_count
	cp	(hl)
	jr	nz,.network
	ld	a,(scr_row)
	ld	b,a
	ld	c,8
	ld	a,A_ITEM
	ld	hl,s_other
	jp	text_at
.network:
	call	rec_ptr
	call	draw_mark
	ld	a,(hl)			; RSSI, signed dBm -> C = bars (1-4)
	add	a,128
	ld	c,4
	cp	128-55
	jr	nc,.bars
	dec	c
	cp	128-65
	jr	nc,.bars
	dec	c
	cp	128-75
	jr	nc,.bars
	dec	c
.bars:
	push	hl
	ld	a,(scr_row)
	ld	b,a
	push	bc
	ld	c,1
	call	scr_at
	pop	bc
	ld	b,1
.bar:
	ld	a,A_BAR_ON
	ld	(scr_attr),a
	ld	a,c
	cp	b
	jr	nc,.lit
	ld	a,A_BAR_DIM
	ld	(scr_attr),a
.lit:
	ld	a,b
	add	a,G_BAR1-1
	call	scr_putc
	inc	b
	ld	a,b
	cp	5
	jr	c,.bar
	pop	hl
	inc	hl
	ld	a,(hl)			; auth mode: 0 = open
	or	a
	jr	z,.name
	ld	a,(scr_row)
	ld	b,a
	ld	c,6
	call	scr_at
	ld	a,A_LOCK
	ld	(scr_attr),a
	ld	a,G_LOCK
	call	scr_putc
.name:
	inc	hl			; flags
	inc	hl
	ld	b,(hl)			; length
	inc	hl
	ld	a,(scr_row)
	push	bc
	ld	b,a
	ld	c,8
	call	scr_at
	pop	bc
	ld	a,A_ITEM
	ld	(scr_attr),a
	ld	a,b
	or	a
	ret	z
	cp	24			; columns 8-30
	jr	c,.chars
	ld	b,23
.chars:
	ld	a,(hl)
	call	scr_putc
	inc	hl
	djnz	.chars
	ret

; draw_mark: column 0 of the current row: a tick if connected, a dot if
; saved. HL = the record; kept.
draw_mark:
	push	hl
	inc	hl
	inc	hl
	ld	a,(hl)			; flags: bit 0 saved, bit 1 connected
	ld	e,G_CHECK
	bit	1,a
	jr	nz,.put
	ld	e,G_DOT
	bit	0,a
	jr	z,.done
.put:
	ld	a,(scr_row)
	ld	b,a
	ld	c,0
	call	scr_at
	ld	a,A_OK
	ld	(scr_attr),a
	ld	a,e
	call	scr_putc
.done:
	pop	hl
	ret

; highlight: bar across the current entry.
highlight:
	ld	a,(cur)
	add	a,LIST_ROW
	ld	b,a
	ld	c,32
	ld	e,0
	ld	a,A_SEL
	jp	scr_paint

; move_cur: make entry A current.
move_cur:
	push	af
	ld	a,(cur)
	call	draw_row
	pop	af
	ld	(cur),a
	jp	highlight

; ---- Text entry ----------------------------------------------------------------

; ask_password: password for ssid_buf into pass_buf. Carry set = ENTER.
ask_password:
	call	frame_plain
	ld	bc,3*256+1
	ld	a,A_HINT
	ld	hl,s_network
	call	text_at
	ld	bc,4*256+1
	ld	a,A_ITEM
	ld	hl,ssid_buf
	call	text_at
	ld	bc,6*256+1
	ld	a,A_ITEM
	ld	hl,s_password
	call	text_at
	ld	hl,s_pass_hints
	call	hints
	ld	hl,pass_buf
	ld	b,63
	ld	c,1			; masked
	ld	d,FIELD_ROW
	jp	edit_line

; ask_name: a network name (hidden network) into ssid_buf. Carry set = ENTER.
ask_name:
	call	frame_plain
	ld	bc,6*256+1
	ld	a,A_ITEM
	ld	hl,s_name
	call	text_at
	ld	hl,s_name_hints
	call	hints
	ld	hl,ssid_buf
	ld	b,32
	ld	c,0
	ld	d,FIELD_ROW
	jp	edit_line

; hints: the zero-terminated lines at HL on rows 17, 18, ...
hints:
	ld	b,17
.line:
	ld	a,(hl)
	or	a
	ret	z
	push	bc
	ld	c,1
	ld	a,A_HINT
	call	text_at			; HL moves on to the next line
	pop	bc
	inc	b
	jr	.line

; ---- Screen helpers ------------------------------------------------------------

; frame: title and list hint. frame_plain: title only.
frame:
	call	frame_plain
	ld	bc,HINT_ROW*256+0
	ld	a,A_HINT
	ld	hl,s_list_hint
	call	text_at
	ld	bc,MARK_ROW*256+1	; legend: tick = connected, dot = saved
	call	scr_at
	ld	a,A_OK
	ld	(scr_attr),a
	ld	a,G_CHECK
	call	scr_putc
	ld	a,A_HINT
	ld	hl,s_connected_mark
	call	print_attr
	ld	a,A_OK
	ld	(scr_attr),a
	ld	a,G_DOT
	call	scr_putc
	ld	a,A_HINT
	ld	hl,s_saved_mark
print_attr:
	ld	(scr_attr),a
	jp	scr_print
frame_plain:
	ld	a,A_BODY
	call	scr_cls
	ld	hl,s_title
	jp	draw_title

; ---- Data ----------------------------------------------------------------------

req_scan:	db	0x00,'L'
req_forget:	db	0x00,'F',0

s_title:	db	"WI-FI SETUP",0
s_scanning:	db	"Looking for networks...",0
s_none:		db	"No networks found.",0
s_list_hint:	db	"ENTER S=scan F=forget SPACE=back",0
s_connected_mark: db	" connected  ",0
s_saved_mark:	db	" saved",0
s_forgetting:	db	"Forgetting...",0
s_other:	db	"Other network...",0
s_network:	db	"Network:",0
s_password:	db	"Password:",0
s_name:		db	"Network name:",0
s_pass_hints:	db	"ENTER   connect",0
		db	"CAPS+0  delete",0
		db	"CAPS+4  show/hide password",0
		db	"CAPS+1  back",0
		db	0
s_name_hints:	db	"ENTER   next",0
		db	"CAPS+0  delete",0
		db	"CAPS+1  back",0
		db	0
s_connecting:	db	"Connecting to",0
s_wait:		db	"This can take 20 seconds.",0
s_failed:	db	"Could not connect:",0
s_noreply:	db	"No reply from the modem.",0
s_connected:	db	"Connected!",0
s_ip:		db	"IP address ",0
s_saved:	db	"The modem will remember it.",0
s_key_list:	db	"Any key: back to the list",0
s_key_menu:	db	"Any key: back to the menu",0

ovl_end:

; Variables and buffers: after ovl_end, so not part of the loaded code.
cur:		ds	1		; current list entry
net_count:	ds	1
rec_end:	ds	2
net_ptrs:	ds	NET_MAX*2
ssid_buf:	ds	33
pass_buf:	ds	64
pass_end:
reqbuf:		ds	3+33+64
req_end:
netbuf:		ds	NETBUF_SIZE
replybuf:	ds	REPLY_SIZE

	SAVEBIN	"wifisetup.bin", wifi_setup, ovl_end - wifi_setup
