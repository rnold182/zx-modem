; screen.asm - fast 32x24 text output straight to screen memory.
;
; Faster than RST 16 and free of control codes: each character copies 8 bytes
; of glyph into the bitmap and sets one attribute byte. Codes 32-127 come
; from the ROM font; codes 1-15 from the program's own glyph table
; (scr_glyphs, 8 bytes per glyph, code 1 first), which the program defines.
;
; State: scr_row, scr_col (next cell) and scr_attr (attribute for new text),
; one byte each, defined by the including program (the menu keeps them at
; fixed addresses for apps). All routines keep IX and IY (the ROM interrupt
; routine needs IY).

ROM_FONT	equ	0x3C00		; glyph of char c at ROM_FONT + 8*c
BORDCR		equ	23624		; system variable: border colour * 8

; scr_at: move to row B, column C.
scr_at:
	ld	a,b
	ld	(scr_row),a
	ld	a,c
	ld	(scr_col),a
	ret

; scr_putc: draw character A at the cursor and advance it. Keeps BC, DE, HL.
scr_putc:
	push	hl
	push	de
	push	bc
	cp	32
	jr	nc,.rom
	dec	a			; custom glyph 1..15 -> table entry 0..14
	ld	hl,scr_glyphs
	jr	.glyph
.rom:
	ld	hl,ROM_FONT
.glyph:
	ld	e,a			; HL += 8 * A
	ld	d,0
	ex	de,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,de
	ex	de,hl			; DE = glyph
	; Bitmap address: 010r r000 | rrrc cccc, row = rr rrr (third, line in third).
	ld	a,(scr_row)
	ld	b,a
	and	0x18
	or	0x40
	ld	h,a
	ld	a,b
	and	7
	rrca
	rrca
	rrca
	ld	c,a
	ld	a,(scr_col)
	or	c
	ld	l,a
	ld	b,8
.copy:
	ld	a,(de)
	ld	(hl),a
	inc	de
	inc	h			; next pixel line is 256 bytes on
	djnz	.copy
	call	scr_attr_addr
	ld	a,(scr_attr)
	ld	(hl),a
	ld	hl,scr_col
	inc	(hl)
	pop	bc
	pop	de
	pop	hl
	ret

; scr_attr_addr: HL = attribute address of the cursor cell (0x5800 + 32*row + col).
scr_attr_addr:
	ld	a,(scr_row)
	ld	l,a
	ld	h,0
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	ld	a,(scr_col)
	or	l
	ld	l,a
	ld	a,h
	or	0x58
	ld	h,a
	ret

; scr_print: print the zero-terminated string at HL. HL ends after the 0.
scr_print:
	ld	a,(hl)
	inc	hl
	or	a
	ret	z
	call	scr_putc
	jr	scr_print

; scr_spaces: print B spaces.
scr_spaces:
	ld	a,' '
	call	scr_putc
	djnz	scr_spaces
	ret

; scr_clear_row: blank row B (bitmap) and give it attribute A.
scr_clear_row:
	push	af
	ld	c,0
	call	scr_at
	pop	af
	ld	(scr_attr),a
	ld	b,32
	call	scr_spaces
	ld	a,(scr_row)		; scr_putc doesn't wrap: put the cursor back
	ld	b,a
	ld	c,0
	jp	scr_at

; scr_paint: set attribute A for C cells of row B, from column E. Text stays.
scr_paint:
	push	af
	ld	a,b
	ld	(scr_row),a
	ld	a,e
	ld	(scr_col),a
	call	scr_attr_addr
	pop	af
	ld	b,c
.cell:
	ld	(hl),a
	inc	hl
	djnz	.cell
	ret

; scr_cls: clear the whole screen to attribute A, border colour = its paper.
scr_cls:
	ld	(scr_attr),a
	ld	hl,0x4000
	ld	de,0x4001
	ld	bc,6144-1
	ld	(hl),0
	ldir
	ld	hl,0x5800
	ld	de,0x5801
	ld	bc,768-1
	ld	(hl),a
	ldir
	and	0x38			; paper bits = border colour * 8
	ld	(BORDCR),a		; the ROM tape routines restore this one
	rrca
	rrca
	rrca
	out	(0xFE),a
	ret

; ---- Numbers ------------------------------------------------------------------

; scr_dec2: print A (0-99) as two digits.
scr_dec2:
	ld	c,'0'-1
.tens:
	inc	c
	sub	10
	jr	nc,.tens
	add	a,10+'0'
	ld	b,a
	ld	a,c
	call	scr_putc
	ld	a,b
	jp	scr_putc

; scr_dec: print A (0-255) without leading zeros.
scr_dec:
	ld	e,0			; E = 1 once a digit has been printed
	ld	c,100
	call	.digit
	ld	c,10
	call	.digit
	add	a,'0'
	jp	scr_putc
.digit:
	ld	b,'0'-1
.sub:
	inc	b
	sub	c
	jr	nc,.sub
	add	a,c
	ld	d,a
	ld	a,b
	cp	'0'
	jr	nz,.print
	bit	0,e
	jr	z,.skip
.print:
	call	scr_putc
	ld	e,1
.skip:
	ld	a,d
	ret

; scr_dec_signed: print A as a signed number (-128..127).
scr_dec_signed:
	bit	7,a
	jr	z,scr_dec
	neg
	push	af
	ld	a,'-'
	call	scr_putc
	pop	af
	jr	scr_dec

; scr_year: print HL (0-9999) as four digits.
scr_year:
	ld	a,0xFF			; A = HL / 100, HL = HL % 100
	ld	de,100
.hund:
	inc	a
	or	a
	sbc	hl,de
	jr	nc,.hund
	add	hl,de
	push	hl
	call	scr_dec2
	pop	hl
	ld	a,l
	jp	scr_dec2
