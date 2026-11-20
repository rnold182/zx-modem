; ui.asm - text entry and small screen helpers, shared by the menu and its
; apps (exported through the API table, sdk/zxmodem_api.inc).
; Needs screen.asm, get_key and the constants in sdk/zxsys.inc and sdk/ui.inc.

; text_at: string HL at row B, column C, attribute A. HL ends after the 0.
text_at:
	push	af
	call	scr_at
	pop	af
	ld	(scr_attr),a
	jp	scr_print

; wait_key: wait for a key; A = its code.
wait_key:
	halt
	call	get_key
	or	a
	jr	z,wait_key
	ret

; edit_line: edit the text at HL, at most B characters (up to 63), masked
; with '*' if C = 1, on rows D and D+1; "CAPS LOCK" shows on row D+3.
; ENTER: carry set, text ends with 0. CAPS+1: carry clear.
; CAPS+0 deletes, CAPS+2 is caps lock, CAPS+4 shows/hides a masked text.
edit_line:
	ld	a,d
	ld	(ed_row),a
	ld	(ed_buf),hl
	ld	a,b
	ld	(ed_max),a
	ld	a,c
	ld	(ed_masked),a
	xor	a
	ld	(ed_len),a
	ld	(ed_reveal),a
.draw:
	call	ed_draw
.key:
	call	wait_key
	cp	K_ENTER
	jr	z,.done
	cp	K_EDIT
	jr	z,.cancel
	cp	K_DELETE
	jr	z,.del
	cp	K_CAPS_LOCK
	jr	z,.caps
	cp	K_INV_VIDEO
	jr	z,.reveal
	cp	32			; printable ASCII only (no keyword tokens)
	jr	c,.key
	cp	127
	jr	nc,.key
	ld	c,a
	ld	a,(ed_max)
	ld	b,a
	ld	a,(ed_len)
	cp	b
	jr	nc,.key			; full
	ld	hl,(ed_buf)
	ld	e,a
	ld	d,0
	add	hl,de
	ld	(hl),c
	inc	a
	ld	(ed_len),a
	jr	.draw
.del:
	ld	a,(ed_len)
	or	a
	jr	z,.key
	dec	a
	ld	(ed_len),a
	jr	.draw
.caps:
	ld	hl,FLAGS2
	ld	a,(hl)
	xor	8
	ld	(hl),a
	jr	.draw
.reveal:
	ld	hl,ed_reveal
	ld	a,(hl)
	xor	1
	ld	(hl),a
	jr	.draw
.done:
	call	.end
	scf
	ret
.cancel:
	call	.end
	or	a
	ret
.end:
	ld	a,(ed_len)
	ld	hl,(ed_buf)
	ld	e,a
	ld	d,0
	add	hl,de
	ld	(hl),0
	ret

; ed_draw: the field on rows ed_row and ed_row+1, cursor, caps lock.
ed_draw:
	ld	a,(ed_row)
	ld	b,a
	ld	a,A_FIELD
	call	scr_clear_row
	ld	a,(ed_row)
	inc	a
	ld	b,a
	ld	a,A_FIELD
	call	scr_clear_row
	ld	a,(ed_row)
	ld	b,a
	ld	c,0
	call	scr_at
	ld	a,(ed_len)
	or	a
	jr	z,.cursor
	ld	b,a
	ld	hl,(ed_buf)
.ch:
	ld	a,(ed_masked)
	ld	c,a
	ld	a,(ed_reveal)
	cpl
	and	c			; masked and not revealed?
	ld	a,(hl)
	jr	z,.put
	ld	a,'*'
.put:
	call	putc_wrap
	inc	hl
	djnz	.ch
.cursor:
	ld	a,(ed_max)
	ld	b,a
	ld	a,(ed_len)
	cp	b
	jr	nc,.caps
	ld	a,'_'
	call	putc_wrap
.caps:
	ld	a,(ed_row)
	add	a,3
	ld	b,a
	ld	a,A_BODY
	call	scr_clear_row
	ld	a,(FLAGS2)
	and	8
	ret	z
	ld	a,(ed_row)
	add	a,3
	ld	b,a
	ld	c,1
	ld	a,A_MSG
	ld	hl,s_capslock
	jp	text_at

; putc_wrap: scr_putc, going on to the next row after column 31.
putc_wrap:
	push	af
	ld	a,(scr_col)
	cp	32
	jr	c,.put
	xor	a
	ld	(scr_col),a
	ld	a,(scr_row)
	inc	a
	ld	(scr_row),a
.put:
	pop	af
	jp	scr_putc

s_capslock:	db	"CAPS LOCK",0
ed_buf:		dw	0
ed_max:		db	0
ed_len:		db	0
ed_masked:	db	0
ed_reveal:	db	0
ed_row:		db	0
