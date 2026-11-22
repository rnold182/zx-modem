; urltest.asm - the Spectrum self-test of url.asm: runs every case of
; host/url_cases.txt (generated into url_cases.inc) and prints the result.
;
; A ZX MODEM app for testing (not shipped in the firmware): load it as an
; overlay in an emulator, e.g. with host/tools/fake_reply.py.
; Build: python apps/zx-vvv/host/cases2asm.py apps/zx-vvv/host/url_cases.txt url_cases.inc
;        sjasmplus --inc=sdk --inc=. apps/zx-vvv/zx/urltest.asm -> urltest.bin

	DEVICE ZXSPECTRUM48

	include	"zxsys.inc"
	include	"ui.inc"
	include	"zxmodem_api.inc"

	org	APP_ADDR

url_test:
	ld	a,A_BODY
	call	scr_cls
	ld	hl,s_title
	call	draw_title
	ld	bc,2*256+0
	call	scr_at
	ld	hl,url_cases
	xor	a
	ld	(passed),a
	ld	(failed),a
.case:
	ld	a,(hl)
	cp	0xFF
	jr	z,.done
	ld	(want_code),a
	inc	hl
	ld	(c_base),hl
	call	skip0
	ld	(c_ref),hl
	call	skip0
	ld	(c_want),hl
	call	skip0
	push	hl
	ld	hl,(c_base)
	ld	de,(c_ref)
	call	url_resolve
	ld	(got_code),a
	ld	hl,want_code
	cp	(hl)
	jr	nz,.fail
	or	a
	jr	nz,.pass			; a code: nothing to compare
	ld	hl,url_out
	ld	de,(c_want)
.cmp:
	ld	a,(de)
	cp	(hl)
	jr	nz,.fail
	inc	hl
	inc	de
	or	a
	jr	nz,.cmp
.pass:
	ld	hl,passed
	inc	(hl)
	pop	hl
	jr	.case
.fail:
	ld	hl,failed
	inc	(hl)
	ld	a,(hl)
	cp	5				; show the first few
	call	c,show_fail
	pop	hl
	jr	.case
.done:
	ld	bc,21*256+0
	ld	a,(failed)
	or	a
	ld	a,A_OK
	jr	z,.col
	ld	a,A_ERR
.col:
	ld	(scr_attr),a
	call	scr_at
	ld	hl,s_url
	call	scr_print
	ld	a,(passed)
	call	scr_dec
	ld	a,'/'
	call	scr_putc
	ld	a,URL_CASES
	call	scr_dec
	ld	hl,s_passed
	call	scr_print
	ld	bc,23*256+0
	ld	a,A_HINT
	ld	hl,s_key
	call	text_at
	call	wait_key
	ret

; show_fail: the case's link and what came out, on the next rows.
show_fail:
	ld	a,A_ERR
	ld	(scr_attr),a
	ld	hl,(c_ref)
	call	print_row
	ld	a,A_BODY
	ld	(scr_attr),a
	ld	a,(got_code)
	or	a
	ld	hl,url_out
	jr	z,print_row
	ld	hl,s_code
	call	scr_print
	ld	a,(got_code)
	call	scr_dec
	; fall through: next row

; print_row: up to 64 characters of HL, then the next row.
newline:
	ld	a,(scr_row)
	inc	a
	ld	b,a
	ld	c,0
	jp	scr_at
print_row:
	ld	b,64
.l:
	ld	a,(hl)
	or	a
	jr	z,newline
	push	bc
	call	putc_wrap
	pop	bc
	inc	hl
	djnz	.l
	jr	newline

skip0:
	ld	a,(hl)
	inc	hl
	or	a
	jr	nz,skip0
	ret

	include	"url.asm"
	include	"url_cases.inc"

s_title:	db	"URL SELF-TEST",0
s_url:		db	"URL tests: ",0
s_passed:	db	" passed",0
s_code:		db	"code ",0
s_key:		db	"Any key: back",0
passed:		db	0
failed:		db	0
want_code:	db	0
got_code:	db	0
c_base:		dw	0
c_ref:		dw	0
c_want:		dw	0
end:
url_tmp:	ds	URL_TMP_SIZE
url_out:	ds	URL_OUT_SIZE
	SAVEBIN	"urltest.bin", url_test, end - url_test
