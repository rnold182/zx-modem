; modemtest - Phase 1 test program (M0: prints "MODEM OK" and returns).
;
; Build: sjasmplus main.asm  -> modemtest.tap (BASIC loader + CODE block)
; Run:   LOAD "" in Fuse or on the real 48K.

	DEVICE ZXSPECTRUM48

CHAN_OPEN	equ	0x1601		; ROM: open channel for stream in A

; --- Code block: loaded to and run from 32768 (uncontended RAM) -------------

	org	32768
start:
	ld	a,2			; stream 2 = upper screen
	call	CHAN_OPEN
	ld	hl,msg
.loop:
	ld	a,(hl)
	or	a
	ret	z			; back to BASIC (BC = USR result, ignored)
	push	hl			; RST 16 doesn't promise to keep HL
	rst	16			; PRINT-A: print character in A
	pop	hl
	inc	hl
	jr	.loop

msg:	db	"MODEM OK",13,0
code_end:

; --- BASIC loader: 10 CLEAR 32767: LOAD ""CODE: RANDOMIZE USR 32768 --------
; Assembled into spare device memory only to be saved; it never runs here.
; Line format: number (2 bytes, big-endian), length of the rest (2 bytes,
; little-endian), tokens/text, 0x0D. Every number literal is followed by
; 0x0E and its hidden 5-byte form: 00 (integer), sign 00, value LE, 00.

T_CLEAR		equ	0xFD
T_LOAD		equ	0xEF
T_CODE		equ	0xAF
T_RANDOMIZE	equ	0xF9
T_USR		equ	0xC0

	org	0xC000
basic:
	db	0,10			; line 10
	dw	.end - .text		; length of the line body
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

; --- Tape image ---------------------------------------------------------------

	EMPTYTAP "modemtest.tap"
	SAVETAP  "modemtest.tap", BASIC, "modemtest", basic, basic_end - basic, 10
	SAVETAP  "modemtest.tap", CODE, "modemcode", start, code_end - start
