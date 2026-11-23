; style.asm - zx-vvv's stylesheets (M7): 8SS parsing and the cascade.
;
; As the reference (spec tools/tml/style.py, 8TML spec 6 and 8): a source
; (a stylesheet, or the page header) is `key: value` lines; keys are
; folded to lower case; `zx.key` applies on the Spectrum only and beats the
; plain key within the same source; other machines' keys are ignored. The
; sources apply in rising priority, key by key: the client's defaults,
; /site.8ss, the page's style: sheet, the header.
;
; A source is parsed into a "partial": for each of the 16 keys
; [set (bit 0; bit 1 = set by a zx. key)][colour][flags]. The cascade
; copies set keys over the defaults into sty: [colour][flags] per key.
; Colours are ZX ink + BRIGHT (0x40), 0xFF = none; flags bit 0 reverse,
; bit 1 center, bit 2 upper. bg and border take one colour (anything else
; counts as black, as in the reference); case: flags bit 2 = upper.

NKEYS		equ	16
PARTIAL_SIZE	equ	NKEYS*3
S_TEXT		equ	0		; key numbers (sty offsets / 2)
S_H1		equ	1
S_H2		equ	2
S_H3		equ	3
S_EM		equ	4
S_STRONG	equ	5
S_LINK		equ	6
S_LINKSEL	equ	7
S_QUOTE		equ	8
S_PRE		equ	9
S_RULE		equ	10
S_FIELD		equ	11
S_FIELDSEL	equ	12
S_BG		equ	13
S_BORDER	equ	14
S_CASE		equ	15
SF_REV		equ	1
SF_CENTER	equ	2
SF_UPPER	equ	4
NO_COLOUR	equ	0xFF
LIGHTGREY	equ	0x07		; the reference's colour for "none"

; sheet_parse: the source text from HL to DE into the partial at BC.
sheet_parse:
	ld	(sp_dst),bc
	push	hl
	push	de
	ld	h,b			; nothing set yet
	ld	l,c
	ld	b,PARTIAL_SIZE
.clr:
	ld	(hl),0
	inc	hl
	djnz	.clr
	ld	hl,(src_ptr)		; src_next reads src_ptr .. page_end
	ld	(sp_save_src),hl
	ld	hl,(page_end)
	ld	(sp_save_end),hl
	pop	de
	pop	hl
	ld	(src_ptr),hl
	ld	(page_end),de
.line:
	call	src_next
	jp	c,.done
	call	line_strip		; HL, B = the line, stripped
	ld	a,b
	or	a
	jr	z,.line
	ld	a,(hl)
	cp	'#'
	jr	z,.line
	ld	(sp_s),hl		; find ':'
	ld	c,0
.colon:
	ld	a,(hl)
	cp	':'
	jr	z,.split
	inc	hl
	inc	c
	djnz	.colon
	jr	.line
.split:
	dec	b			; B = after the ':'
	inc	hl
	ld	(sp_v),hl
	ld	a,b
	ld	(sp_vlen),a
	ld	hl,(sp_s)		; the key, C characters
	ld	b,c
	call	strip_span
	ld	a,b
	or	a
	jr	z,.line
	; a machine prefix: "zx." applies, any other machine's key doesn't
	xor	a
	ld	(sp_pref),a
	push	hl
	push	bc
	ld	c,b
.dot:
	ld	a,(hl)
	cp	'.'
	jr	z,.dotted
	inc	hl
	dec	c
	jr	nz,.dot
	pop	bc
	pop	hl
	jr	.key
.dotted:
	pop	bc
	pop	hl
	ld	a,b			; "zx." (any case) + the base key
	cp	4
	jr	c,.line
	ld	a,(hl)
	call	to_lower
	cp	'z'
	jr	nz,.line
	inc	hl
	ld	a,(hl)
	call	to_lower
	cp	'x'
	jr	nz,.line
	inc	hl
	ld	a,(hl)
	cp	'.'
	jr	nz,.line
	inc	hl
	dec	b
	dec	b
	dec	b
	ld	a,2
	ld	(sp_pref),a
.key:
	ld	c,b			; which key?
	ld	de,style_keys
	ld	b,0
.find:
	ld	a,(de)
	or	a
	jp	z,.line			; unknown: ignored
	push	hl
	push	bc
	push	de
	call	word_is
	pop	de
	pop	bc
	pop	hl
	jr	z,.found
.skip:
	ld	a,(de)
	inc	de
	or	a
	jr	nz,.skip
	inc	b
	jr	.find
.found:
	ld	a,b
	ld	(sp_key),a
	; the value, without spaces around it
	ld	hl,(sp_v)
	ld	a,(sp_vlen)
	ld	b,a
	call	strip_span
	ld	(sp_v),hl
	ld	a,b
	ld	(sp_vlen),a
	ld	a,(sp_key)
	cp	S_CASE
	jr	z,.case
	cp	S_BG
	jr	z,.onecolour
	cp	S_BORDER
	jr	z,.onecolour
	call	style_value		; D = colour, E = flags
	jr	.store
.case:
	ld	hl,(sp_v)		; "mixed" (any case), anything else is upper
	ld	a,(sp_vlen)
	ld	c,a
	ld	de,w_mixed
	call	word_is
	ld	e,0
	jr	z,.cased
	ld	e,SF_UPPER
.cased:
	ld	d,NO_COLOUR
	jr	.store
.onecolour:
	ld	hl,(sp_v)		; exactly one colour word, or none (= black)
	ld	a,(sp_vlen)
	ld	c,a
	call	colour_word
	ld	d,a
	ld	e,0
.store:
	; entry = partial + key * 3; a plain key doesn't replace a zx. one
	ld	a,(sp_key)
	ld	l,a
	add	a,a
	add	a,l
	ld	l,a
	ld	h,0
	ld	bc,(sp_dst)
	add	hl,bc
	ld	a,(sp_pref)
	or	a
	jr	nz,.put
	bit	1,(hl)
	jp	nz,.line
.put:
	or	1
	ld	(hl),a
	inc	hl
	ld	(hl),d
	inc	hl
	ld	(hl),e
	jp	.line
.done:
	ld	hl,(sp_save_src)
	ld	(src_ptr),hl
	ld	hl,(sp_save_end)
	ld	(page_end),hl
	ret

; style_value: the value (sp_v, sp_vlen) as a role style: D = its colour
; (the last colour word; NO_COLOUR if none), E = flags (reverse, center,
; upper). Other words are ignored.
style_value:
	ld	d,NO_COLOUR
	ld	e,0
	ld	hl,(sp_v)
	ld	a,(sp_vlen)
	ld	b,a
.word:
	ld	a,b			; past spaces
	or	a
	ret	z
	ld	a,(hl)
	cp	' '
	jr	nz,.start
	inc	hl
	dec	b
	jr	.word
.start:
	push	hl			; C = the word's length
	ld	c,0
.len:
	ld	a,b
	or	a
	jr	z,.got
	ld	a,(hl)
	cp	' '
	jr	z,.got
	inc	hl
	inc	c
	dec	b
	jr	.len
.got:
	ex	(sp),hl			; HL = the word, the rest waits
	push	bc
	push	de
	ld	de,style_words		; reverse, center, upper
	ld	b,1
.sw:
	ld	a,(de)
	or	a
	jr	z,.colour
	push	hl
	push	bc
	push	de
	call	word_is
	pop	de
	pop	bc
	pop	hl
	jr	z,.flag
.swskip:
	ld	a,(de)
	inc	de
	or	a
	jr	nz,.swskip
	sla	b
	jr	.sw
.flag:
	pop	de
	ld	a,e
	or	b
	ld	e,a
	pop	bc
	pop	hl
	jr	.word
.colour:
	call	tag_name_kind		; a colour name (or alias)?
	pop	de
	cp	1
	jr	nz,.notc
	ld	a,(tag_val)
	ld	d,a
.notc:
	pop	bc
	pop	hl
	jr	.word

; colour_word: the C characters at HL: A = the colour if they are one
; colour name, else 0 (black).
colour_word:
	ld	a,c
	or	a
	ret	z
	push	hl			; one word only
	ld	b,c
.sp:
	ld	a,(hl)
	cp	' '
	jr	z,.no
	inc	hl
	djnz	.sp
	pop	hl
	call	tag_name_kind
	cp	1
	ld	a,(tag_val)
	ret	z
	xor	a
	ret
.no:
	pop	hl
	xor	a
	ret

; cascade: sty = the defaults, then the partials at site_part, page_part
; and hdr_part (each 0 = none), key by key. Then the attributes the
; renderer uses everywhere.
cascade:
	ld	hl,sty_defaults
	ld	de,sty
	ld	bc,NKEYS*2
	ldir
	ld	hl,(site_part)
	call	.apply
	ld	hl,(page_part)
	call	.apply
	ld	hl,hdr_part
	call	.apply
	; the page's case, the plain attributes, the border
	ld	a,(sty+S_CASE*2+1)
	and	SF_UPPER
	ld	(upper),a
	ld	a,(sty+S_TEXT*2)	; text: its colour, reversed or not
	ld	c,0
	call	mk_attr
	ld	(att_plain),a		; markers, indents, empty cells
	ld	a,(sty+S_TEXT*2)
	ld	c,a
	ld	a,(sty+S_TEXT*2+1)
	ld	b,a
	ld	a,c
	ld	c,b
	call	mk_attr
	ld	(att_text),a		; plain text (not a page)
	ld	a,(sty+S_PRE*2)
	ld	c,a
	ld	a,(sty+S_PRE*2+1)
	ld	b,a
	ld	a,c
	ld	c,b
	call	mk_attr
	ld	(att_pre),a
	ld	a,(sty+S_RULE*2)
	ld	c,0			; a rule is never reversed
	call	mk_attr
	ld	(att_rule),a
	ld	a,(sty+S_BORDER*2)
	cp	NO_COLOUR
	jr	nz,.b
	xor	a
.b:
	and	7
	ld	(border),a
	ret
.apply:
	ld	a,h
	or	l
	ret	z
	ld	de,sty
	ld	b,NKEYS
.k:
	ld	a,(hl)
	inc	hl
	rra				; set?
	jr	nc,.not
	ldi
	ldi
	inc	bc			; (ldi counted BC down)
	inc	bc
	jr	.n
.not:
	inc	hl
	inc	hl
	inc	de
	inc	de
.n:
	djnz	.k
	ret

; mk_attr: A = a colour (NO_COLOUR: the text colour, or light grey),
; C bit 0 = reversed: A = the attribute on the page background. On a
; coloured background the whole page takes the background's BRIGHT, so the
; background stays even (decided 2026-11-23); on black, the colour's.
mk_attr:
	cp	NO_COLOUR
	jr	nz,.c
	ld	a,(sty+S_TEXT*2)
	cp	NO_COLOUR
	jr	nz,.c
	ld	a,LIGHTGREY
.c:
	ld	b,a			; B = the colour
	ld	a,(sty+S_BG*2)
	cp	NO_COLOUR
	jr	nz,.bg
	xor	a
.bg:
	ld	e,a			; E = the background
	and	7
	ld	a,b
	jr	z,.bright		; black background: the colour's BRIGHT
	ld	a,e
.bright:
	and	0x40
	ld	d,a			; D = BRIGHT
	bit	0,c
	jr	nz,.rev
	ld	a,e			; ink = colour, paper = background
	and	7
	add	a,a
	add	a,a
	add	a,a
	ld	e,a
	ld	a,b
	and	7
	or	e
	or	d
	ret
.rev:
	ld	a,b			; paper = colour, ink = background
	and	7
	add	a,a
	add	a,a
	add	a,a
	ld	b,a
	ld	a,e
	and	7
	or	b
	or	d
	ret

; role_style: A = a key number: D = its colour (the text colour if it has
; none: render.py's "role.color or text.color"), E = its flags.
role_style:
	add	a,a
	ld	l,a
	ld	h,0
	ld	bc,sty
	add	hl,bc
	ld	d,(hl)
	inc	hl
	ld	e,(hl)
	ld	a,d
	cp	NO_COLOUR
	ret	nz
	ld	a,(sty+S_TEXT*2)
	ld	d,a
	ret

; The keys, in key-number order, then 0
style_keys:
		db	"text",0, "h1",0, "h2",0, "h3",0, "em",0, "strong",0
		db	"link",0, "link-sel",0, "quote",0, "pre",0, "rule",0
		db	"field",0, "field-sel",0, "bg",0, "border",0, "case",0
		db	0
style_words:	db	"reverse",0, "center",0, "upper",0, 0

; The reference client's defaults (style.py DEFAULTS), as ZX colours
sty_defaults:
		db	0x07,0			; text: lightgrey
		db	0x47,SF_REV		; h1: white reverse
		db	0x47,0			; h2: white
		db	0x47,0			; h3: white
		db	0x47,0			; em: white
		db	0x47,0			; strong: white
		db	0x45,0			; link: lightblue
		db	0x45,SF_REV		; link-sel: lightblue reverse
		db	0x07,0			; quote: grey
		db	0x44,0			; pre: lightgreen
		db	0x07,0			; rule: darkgrey
		db	0x47,0			; field: white
		db	0x47,SF_REV		; field-sel: white reverse
		db	0x00,0			; bg: black
		db	0x00,0			; border: black
		db	NO_COLOUR,SF_UPPER	; case: upper

sty:		ds	NKEYS*2			; the cascade's result
att_plain:	db	0x07
att_text:	db	0x07
att_pre:	db	0x44
att_rule:	db	0x07
border:		db	0
site_part:	dw	0			; the sources' partials (0: none)
page_part:	dw	0
sp_dst:		dw	0
sp_save_src:	dw	0
sp_save_end:	dw	0
sp_s:		dw	0
sp_v:		dw	0
sp_vlen:	db	0
sp_pref:	db	0
sp_key:		db	0
