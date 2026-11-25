; forms.asm - 8TML forms in the renderer (M8a): field lines drawn the way
; the reference does (spec 7, tools/tml/parser.py field_line and render.py
; field_block), and fields in the focus order with the links.
;
; A field is a block of its own: its label goes through the inline parser
; and the word wrapper like any text, its box ("[____]", "[x]", "< Go >")
; is drawn in the field / field-sel style and is never case-folded (the
; reference's box() takes the characters as they are).
;
; Fields and links share one numbering, in page order (the reference's
; doc.focus): the label's own links come first, then the field. So focus,
; the link runs and the link-sel drawing work for fields unchanged; the
; program's link_hook sees a field with lk_is_field = 1 and url_buf =
; "[type] name". Nothing is kept per field: like links, a field is found
; again by re-reading the page from its screen's bookmark.
;
; The form state lives in st_flags (F_FORM, F_SELECT), so a bookmark that
; starts a screen inside a form knows it.

FT_TEXT		equ	0		; field types, in ft_names order
FT_PASSWORD	equ	1
FT_AREA		equ	2
FT_CHECK	equ	3
FT_RADIO	equ	4
FT_SELECT	equ	5
FT_HIDDEN	equ	6
FT_SUBMIT	equ	7
FT_RESET	equ	8
CAP_MAX		equ	30		; label characters kept while counting
BOX_INNER	equ	WIDTH-2		; the widest box: 30 between [ ]
NUM_CAP		equ	9999		; max= and rows= stop here

; is_field_line: Z if the line is "? ..." or "?" (classify set st_len).
is_field_line:
	ld	a,(linebuf)
	cp	'?'
	ret	nz
	ld	a,(st_len)
	cp	1
	ret	z
	ld	a,(linebuf+1)
	cp	' '
	ret

; is_option_line: Z if the line is "- x" or "+ x" (a select's option).
is_option_line:
	ld	a,(st_len)
	cp	2
	jr	c,.no
	ld	a,(linebuf)
	cp	'-'
	jr	z,.sp
	cp	'+'
	ret	nz
.sp:
	ld	a,(linebuf+1)
	cp	' '
	ret
.no:
	or	1			; NZ
	ret

; ---- Field lines -------------------------------------------------------------

; next_token: the next space-separated word of the line from linebuf + L
; (reference next_token: a '"' runs to the next '"', spaces and all).
; NC: tk_s, tk_e = where it is, L = after it. C: no more words.
next_token:
	ld	h,linebuf>>8
	ld	a,(st_len)
	ld	b,a
.sp:
	ld	a,l
	cp	b
	jr	nc,.none
	ld	a,(hl)
	cp	' '
	jr	nz,.go
	inc	l
	jr	.sp
.none:
	scf
	ret
.go:
	ld	a,l
	ld	(tk_s),a
.l:
	ld	a,l
	cp	b
	jr	nc,.end
	ld	a,(hl)
	cp	' '
	jr	z,.end
	inc	l
	cp	'"'
	jr	nz,.l
.q:					; to the closing quote (or the end)
	ld	a,l
	cp	b
	jr	nc,.end
	ld	a,(hl)
	inc	l
	cp	'"'
	jr	nz,.q
	jr	.l
.end:
	ld	a,l
	ld	(tk_e),a
	or	a			; carry clear
	ret

; tok_is: Z if the word tk_s..tk_e is the 0-terminated lower-case word at
; DE, in any case.
tok_is:
	ld	a,(tk_s)
	ld	l,a
	ld	h,linebuf>>8
	ld	a,(tk_e)
	sub	l
	ld	c,a
.l:
	ld	a,(de)
	or	a
	jr	z,.end
	ld	b,a
	ld	a,c
	or	a
	jr	z,.short
	ld	a,(hl)
	call	to_lower
	cp	b
	ret	nz
	inc	hl
	inc	de
	dec	c
	jr	.l
.end:
	ld	a,c			; Z if the word ended too
	or	a
	ret
.short:
	inc	a			; NZ
	ret

; parse_field: the field line in linebuf. NZ: not a field (no type or
; name, or an unknown type), ignored like the reference does. Z: fl_type,
; fl_ns/fl_ne (the name), fl_max, fl_rows, fl_checked, fl_vs/fl_ve (the
; value), lab_s (where the label starts; it ends at st_len).
parse_field:
	ld	l,1			; after the '?'
	call	next_token
	jp	c,.bad
	ld	a,l
	ld	(pf_rest),a
	ld	de,ft_names		; the type
	ld	c,0
.t:
	ld	a,(de)
	or	a
	jp	z,.bad			; unknown
	push	bc
	push	de
	call	tok_is
	pop	de
	pop	bc
	jr	z,.tfound
.skip:
	ld	a,(de)
	inc	de
	or	a
	jr	nz,.skip
	inc	c
	jr	.t
.tfound:
	ld	a,c
	ld	(fl_type),a
	ld	a,(pf_rest)		; the name
	ld	l,a
	call	next_token
	jp	c,.bad
	ld	a,(tk_s)
	ld	(fl_ns),a
	ld	a,(tk_e)
	ld	(fl_ne),a
	; the defaults
	ld	hl,80
	ld	a,(fl_type)
	cp	FT_AREA
	jr	nz,.m
	ld	hl,255
.m:
	ld	(fl_max),hl
	ld	hl,4
	ld	(fl_rows),hl
	xor	a
	ld	(fl_checked),a
	ld	(fl_vs),a
	ld	(fl_ve),a
	ld	a,(tk_e)
	ld	l,a
.opt:					; options, until the first other word
	ld	a,l
	ld	(pf_rest),a
	call	next_token
	jr	c,.nolabel
	ld	a,l
	ld	(pf_after),a
	ld	de,w_checked
	call	tok_is
	jr	nz,.kv
	ld	a,1
	ld	(fl_checked),a
	jr	.next
.kv:
	call	tok_eq			; key=value with a known key?
	jr	nz,.label
	call	tok_value		; pf_vs/pf_ve: the value
	ld	a,(pf_key)
	cp	2
	jr	z,.val
	call	tok_number		; max, rows: a positive number, or ignored
	jr	nz,.next
	ld	a,(pf_key)
	or	a
	jr	nz,.rows
	ld	(fl_max),hl
	jr	.next
.rows:
	ld	(fl_rows),hl
	jr	.next
.val:
	ld	a,(pf_vs)
	ld	(fl_vs),a
	ld	a,(pf_ve)
	ld	(fl_ve),a
.next:
	ld	a,(pf_after)
	ld	l,a
	jr	.opt
.label:
	ld	a,(tk_s)		; the label: this word and the rest
	jr	.lab
.nolabel:
	ld	a,(st_len)
.lab:
	ld	(lab_s),a
	xor	a			; Z
	ret
.bad:
	or	1
	ret

; tok_eq: Z if the word is key=value with key max (pf_key 0), rows (1) or
; value (2); pf_eq = where its first '=' is.
tok_eq:
	ld	a,(tk_s)
	ld	l,a
	ld	h,linebuf>>8
	ld	a,(tk_e)
	ld	b,a
.f:
	ld	a,l
	cp	b
	jr	nc,.no
	ld	a,(hl)
	cp	'='
	jr	z,.eq
	inc	l
	jr	.f
.eq:
	ld	a,l
	ld	(pf_eq),a
	ld	a,(tk_e)		; the key alone: tk_e on the '='
	push	af
	ld	a,l
	ld	(tk_e),a
	ld	c,0
	ld	de,w_max
.k:
	push	bc
	push	de
	call	tok_is
	pop	de
	pop	bc
	jr	z,.known
.ks:
	ld	a,(de)
	inc	de
	or	a
	jr	nz,.ks
	inc	c
	ld	a,c
	cp	3
	jr	c,.k
	pop	af
	ld	(tk_e),a
.no:
	or	1
	ret
.known:
	ld	a,c
	ld	(pf_key),a
	pop	af
	ld	(tk_e),a
	xor	a
	ret

; tok_value: pf_vs..pf_ve = the value after the first '='. As the
; reference: if the word holds '="' anywhere and ends with '"', the value
; loses its first and last characters.
tok_value:
	ld	a,(pf_eq)
	inc	a
	ld	(pf_vs),a
	ld	a,(tk_e)
	ld	(pf_ve),a
	dec	a
	ld	l,a
	ld	h,linebuf>>8
	ld	a,(hl)
	cp	'"'
	ret	nz			; doesn't end with '"'
	ld	a,(tk_s)		; '="' somewhere?
	ld	l,a
	ld	a,(tk_e)
	dec	a
	ld	b,a
.f:
	ld	a,l
	cp	b
	ret	nc
	ld	a,(hl)
	inc	l
	cp	'='
	jr	nz,.f
	ld	a,(hl)
	cp	'"'
	jr	nz,.f
	ld	a,(pf_vs)		; v[1:-1]
	inc	a
	ld	(pf_vs),a
	ld	c,a
	ld	a,(pf_ve)
	dec	a
	cp	c
	jr	nc,.e
	ld	a,c			; nothing left
.e:
	ld	(pf_ve),a
	ret

; tok_number: Z and HL = pf_vs..pf_ve as a positive number (all digits,
; at least one; NUM_CAP at most). NZ: not one.
tok_number:
	ld	a,(pf_vs)
	ld	l,a
	ld	h,linebuf>>8
	ld	a,(pf_ve)
	sub	l
	jr	z,.no
	ld	b,a
	ld	de,0
.d:
	ld	a,(hl)
	sub	'0'
	jr	c,.no
	cp	10
	jr	nc,.no
	push	hl
	push	bc
	ld	hl,999			; already 4 digits: the cap (no overflow)
	or	a
	sbc	hl,de
	jr	c,.cap
	ld	h,d			; DE = DE * 10 + digit
	ld	l,e
	add	hl,hl
	add	hl,hl
	add	hl,de
	add	hl,hl
	ld	c,a
	ld	b,0
	add	hl,bc
	ex	de,hl
	ld	hl,NUM_CAP
	or	a
	sbc	hl,de
	jr	nc,.ok
.cap:
	ld	de,NUM_CAP
.ok:
	pop	bc
	pop	hl
	inc	l
	djnz	.d
	ld	a,d
	or	e
	jr	z,.no			; 0 isn't positive
	ex	de,hl
	xor	a
	ret
.no:
	or	1
	ret

; ---- Labels --------------------------------------------------------------

; label_pass: the label (linebuf + lab_s up to st_len) through the inline
; parser: into the word wrapper, or only counted when wr_mute is set. One
; line, no hard breaks (a field label isn't joined text).
label_pass:
	ld	a,(lab_s)
	ld	l,a
	ld	h,linebuf>>8
	ld	(pr_ptr),hl
	ld	a,(st_len)
	ld	l,a
	ld	(pr_end),hl
	xor	a
	ld	(pr_hard),a
	ld	(pr_eof),a
	ld	(in_link),a
	inc	a
	ld	(pr_head),a		; no continuation lines
	ld	(in_outer),a
	xor	a
	ld	hl,hist
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a
	ld	hl,win
	ld	(in_p),hl
	ld	(win_end),hl
	ld	(hl),a
	call	win_need
	call	in_reset
	ld	a,' '
	ld	(in_prev),a
	jp	inline_run

; label_count: count the label's cells (lab_len) and links (lab_links),
; keeping its first CAP_MAX characters, in their case, in cap_buf. Draws
; nothing, tells the program nothing, changes no link numbers.
label_count:
	ld	hl,(st_links)
	push	hl
	ld	hl,0
	ld	(mt_len),hl
	ld	a,1
	ld	(wr_mute),a
	call	label_pass
	xor	a
	ld	(wr_mute),a
	ld	hl,(mt_len)
	ld	(lab_len),hl
	ld	hl,(st_links)
	pop	de
	ld	(st_links),de
	or	a
	sbc	hl,de
	ld	(lab_links),hl
	ret

; label_links_only: the label's links count (and the program sees them, as
; in the reference, though they aren't drawn): buttons, hidden fields and
; select options don't show their label as text.
label_links_only:
	ld	a,2
	ld	(wr_mute),a
	call	label_pass
	xor	a
	ld	(wr_mute),a
	ret

; skip_spaces_lab: lab_s past spaces.
skip_spaces_lab:
	ld	a,(lab_s)
	ld	l,a
	ld	h,linebuf>>8
	ld	a,(st_len)
	ld	b,a
.l:
	ld	a,l
	cp	b
	jr	nc,.e
	ld	a,(hl)
	cp	' '
	jr	nz,.e
	inc	l
	jr	.l
.e:
	ld	a,l
	ld	(lab_s),a
	ret

; ---- A field ---------------------------------------------------------------

; field_block: the field line in linebuf (render_body cleared F_SELECT).
field_block:
	call	parse_field
	ret	nz			; not a field: the line goes
	ld	a,S_TEXT		; the text role (labels; the options' case)
	call	role_style
	ld	a,e
	ld	(bk_flags),a
	ld	a,d
	ld	(bk_col),a
	xor	a
	ld	(in_box),a
	ld	a,(fl_type)
	cp	FT_SELECT
	call	z,sel_scan		; its options first (reloads the line)
	call	block_begin
	xor	a			; the wrapper: full width
	ld	(bk_indent),a
	ld	(bk_mlen),a
	ld	(bk_center),a
	ld	(cur_len),a
	ld	(word_len),a
	ld	(in_box),a
	ld	hl,0
	ld	(pend_cnt),hl
	ld	(lines_out),hl
	ld	a,WIDTH
	ld	(wr_width),a
	call	label_count
	ld	a,(fl_type)
	cp	FT_HIDDEN
	jp	z,label_links_only	; not shown, not focused
	ld	hl,(st_links)		; its number: after the label's links
	ld	de,(lab_links)
	add	hl,de
	ld	(fld_id),hl
	ld	a,(fl_type)
	cp	FT_CHECK
	jp	z,.mark
	cp	FT_RADIO
	jp	z,.mark
	cp	FT_SUBMIT
	jp	z,.button
	cp	FT_RESET
	jp	z,.button
	cp	FT_SELECT
	jp	z,.select
	cp	FT_AREA
	jp	z,.area
	; text, password: "[" + (value + "_" * size)[:size] + "]"
	ld	hl,(fl_max)
	ld	a,h
	or	a
	ld	a,BOX_INNER
	jr	nz,.sz
	ld	a,l
	cp	BOX_INNER+1
	jr	c,.sz
	ld	a,BOX_INNER
.sz:
	ld	(fb_size),a
	ld	de,fbuf
	ld	a,'['
	ld	(de),a
	inc	de
	ld	a,(fl_vs)
	ld	l,a
	ld	h,linebuf>>8
	ld	a,(fl_ve)
	sub	l
	ld	c,a			; C = the value's length
	ld	a,(fb_size)
	ld	b,a			; B = the box's size
.tv:
	ld	a,b
	or	a
	jr	z,.tend
	ld	a,c
	or	a
	ld	a,'_'
	jr	z,.tput
	dec	c
	ld	a,(fl_type)
	cp	FT_PASSWORD
	ld	a,'*'
	jr	z,.tnext
	ld	a,(hl)
.tnext:
	inc	hl
.tput:
	ld	(de),a
	inc	de
	dec	b
	jr	.tv
.tend:
	ld	a,']'
	ld	(de),a
	ld	a,(fb_size)
	add	a,2
	jp	.labelbox

.mark:					; [x] [ ] (*) ( ), a space, the label, wrapped
	ld	a,(fl_checked)
	or	a
	ld	hl,s_marks
	jr	z,.m1
	ld	hl,s_marks+3
.m1:
	ld	a,(fl_type)
	cp	FT_RADIO
	jr	nz,.m2
	ld	de,6
	add	hl,de
.m2:
	ld	b,3
	call	box_wr
	ld	a,' '
	call	wr_char
	call	label_pass
	call	wr_end
	jp	.done

.button:				; "< " + label + " >", cut to the width
	call	label_links_only
	ld	de,fbuf
	ld	a,'<'
	ld	(de),a
	inc	de
	ld	a,' '
	ld	(de),a
	inc	de
	ld	hl,(lab_len)
	ld	a,h
	or	l
	jr	nz,.blab
	ld	hl,s_submit		; no label: Submit / Reset
	ld	a,(fl_type)
	cp	FT_SUBMIT
	jr	z,.bdef
	ld	hl,s_reset
.bdef:
	ld	a,(hl)
	or	a
	jr	z,.bclose
	ld	(de),a
	inc	hl
	inc	de
	jr	.bdef
.blab:
	ld	a,h
	or	a
	ld	a,CAP_MAX
	jr	nz,.bl
	ld	a,l
	cp	CAP_MAX+1
	jr	c,.bl
	ld	a,CAP_MAX
.bl:
	ld	c,a
	ld	b,0
	ld	hl,cap_buf
	ldir
.bclose:
	ld	a,' '
	ld	(de),a
	inc	de
	ld	a,'>'
	ld	(de),a
	inc	de
	ld	hl,fbuf
	ex	de,hl
	or	a
	sbc	hl,de
	ld	a,l			; its length, cut to the width
	cp	WIDTH+1
	jr	c,.bw
	ld	a,WIDTH
.bw:
	ld	hl,fbuf
	call	box_row
	jp	.done

.select:				; "[" + (name.ljust(inner-2) + " v")[:inner] + "]"
	ld	a,(sel_long)		; inner = min(longest + 2, 30)
	cp	BOX_INNER-1
	jr	c,.si
	ld	a,BOX_INNER-2
.si:
	add	a,2
	ld	(fb_size),a
	ld	hl,sel_name		; name, padded to inner-2, then " v"
	ld	de,fbuf+1
	ld	a,(sel_nlen)
	ld	c,a
	ld	a,(fb_size)
	sub	2
	ld	b,a			; B = the width for the name
.sn:
	ld	a,c
	or	a
	jr	z,.spad
	ld	a,(hl)
	ld	(de),a
	inc	hl
	inc	de
	dec	c
	ld	a,b
	or	a
	jr	z,.sn
	dec	b
	jr	.sn
.spad:
	ld	a,b
	or	a
	jr	z,.sv
	ld	a,' '
	ld	(de),a
	inc	de
	dec	b
	jr	.spad
.sv:
	ld	a,' '
	ld	(de),a
	inc	de
	ld	a,'v'
	ld	(de),a
	ld	a,'['			; then cut to inner, and the brackets
	ld	(fbuf),a
	ld	a,(fb_size)
	ld	l,a
	ld	h,0
	ld	de,fbuf+1
	add	hl,de
	ld	(hl),']'
	ld	a,(fb_size)
	add	a,2
	jr	.labelbox

.area:					; the label wrapped, then rows of [____]
	ld	hl,(lab_len)
	ld	a,h
	or	l
	jr	z,.arows
	call	label_pass
	call	wr_end
.arows:
	ld	hl,fbuf
	ld	(hl),'['
	inc	hl
	ld	b,BOX_INNER
.au:
	ld	(hl),'_'
	inc	hl
	djnz	.au
	ld	(hl),']'
	ld	hl,(fl_rows)
.ar:
	ld	a,h
	or	l
	jr	z,.done
	push	hl
	ld	hl,fbuf
	ld	a,WIDTH
	call	box_row
	pop	hl
	dec	hl
	jr	.ar

.labelbox:				; A = the box's length (fbuf), at most 32:
	ld	(fb_len),a		; the label and the box on one line if
	ld	hl,(lab_len)		; they fit, else the label wrapped above
	ld	a,h
	or	l
	jr	z,.below
	ld	de,(fb_len)
	ld	d,0
	add	hl,de
	inc	hl
	ld	de,WIDTH+1
	or	a
	sbc	hl,de
	jr	nc,.above
	call	label_pass		; label, a space, the box: one line
	ld	a,' '
	call	wr_char
	ld	hl,fbuf
	ld	a,(fb_len)
	ld	b,a
	call	box_wr
	call	wr_end
	jr	.done
.above:
	call	label_pass
	call	wr_end
.below:
	ld	hl,fbuf
	ld	a,(fb_len)
	call	box_row
	; fall through
.done:
	ld	hl,(fld_id)		; the field takes its number now
	ld	(lk_cur),hl
	inc	hl
	ld	(st_links),hl
	ld	a,(fl_type)
	cp	FT_SELECT
	jr	nz,.hook
	ld	hl,st_flags		; its options follow
	set	F_SELECT,(hl)
.hook:
	ld	a,(mode)
	cp	MODE_FIND
	ret	c
	call	field_desc		; url_buf = "[type] name"
	ld	a,1
	ld	(lk_is_field),a
	call	link_hook
	xor	a
	ld	(lk_is_field),a
	ret

; field_desc: url_buf = "[type] name", what the status line and the L
; list show for a field.
field_desc:
	ld	de,url_buf
	ld	a,'['
	ld	(de),a
	inc	de
	ld	hl,ft_names
	ld	a,(fl_type)
	or	a
	jr	z,.tn
	ld	b,a
.ts:
	ld	a,(hl)
	inc	hl
	or	a
	jr	nz,.ts
	djnz	.ts
.tn:
	ld	a,(hl)
	or	a
	jr	z,.te
	ld	(de),a
	inc	hl
	inc	de
	jr	.tn
.te:
	ld	a,']'
	ld	(de),a
	inc	de
	ld	a,' '
	ld	(de),a
	inc	de
	ld	a,(fl_ns)
	ld	l,a
	ld	h,linebuf>>8
	ld	a,(fl_ne)
	sub	l
	cp	240
	jr	c,.n
	ld	a,240			; (url_buf is 256)
.n:
	ld	c,a
	ld	b,0
	or	a
	jr	z,.z
	ldir
.z:
	xor	a
	ld	(de),a
	ret

; box_wr: B characters from HL into the wrapper, in the field style.
box_wr:
	ld	a,1
	ld	(in_box),a
.l:
	ld	a,(hl)
	push	bc
	call	wr_char			; (keeps HL)
	pop	bc
	inc	hl
	djnz	.l
	xor	a
	ld	(in_box),a
	ret

; box_row: A characters from HL as one row, in the field style.
box_row:
	push	af
	push	hl
	ld	a,1
	ld	(in_box),a
	call	cell_style		; C = the attribute, E = the field's id
	xor	a
	ld	(in_box),a
	ld	a,c
	ld	(br_attr),a
	ld	a,e
	ld	(br_id),a
	pop	hl
	pop	af
	push	af
	ld	b,a
	ld	de,rowbuf
.l:
	ld	a,(hl)
	inc	hl
	ld	(de),a
	inc	de
	ld	a,(br_attr)
	ld	(de),a
	inc	de
	ld	a,(br_id)
	ld	(de),a
	inc	de
	djnz	.l
	pop	af
	jp	row_emit

; ---- select ------------------------------------------------------------------

; sel_scan: the option lines after the select line in linebuf: the longest
; label (sel_long, at most 255) and the chosen one's label (sel_name,
; sel_nlen): the first "+" option, else the first one. Then the select
; line is read again (and parsed), src_ptr after it.
sel_scan:
	ld	hl,(line_start)
	ld	(sel_line),hl
	ld	hl,(src_ptr)
	ld	(sel_after),hl
	xor	a
	ld	(sel_long),a
	ld	(sel_nlen),a
	ld	hl,0
	ld	(sel_first),hl
	ld	(sel_plus),hl
.l:
	call	src_next
	jr	c,.done
	call	line_rstrip
	call	is_option_line
	jr	nz,.done
	call	option_label		; lab_s; NZ: no value (no option)
	jr	nz,.l
	ld	hl,(sel_first)
	ld	a,h
	or	l
	jr	nz,.f
	ld	hl,(line_start)
	ld	(sel_first),hl
.f:
	ld	a,(linebuf)
	cp	'+'
	jr	nz,.len
	ld	hl,(sel_plus)
	ld	a,h
	or	l
	jr	nz,.len
	ld	hl,(line_start)
	ld	(sel_plus),hl
.len:
	call	label_count
	ld	hl,(lab_len)
	ld	a,h
	or	a
	ld	a,255
	jr	nz,.cmp
	ld	a,l
.cmp:
	ld	hl,sel_long
	cp	(hl)
	jr	c,.l
	ld	(hl),a
	jr	.l
.done:
	ld	hl,(sel_plus)		; the chosen one
	ld	a,h
	or	l
	jr	nz,.ch
	ld	hl,(sel_first)
	ld	a,h
	or	l
	jr	z,.back
.ch:
	ld	(src_ptr),hl
	call	src_next
	call	line_rstrip
	call	option_label
	call	label_count
	ld	hl,(lab_len)
	ld	a,h
	or	a
	ld	a,CAP_MAX
	jr	nz,.nl
	ld	a,l
	cp	CAP_MAX+1
	jr	c,.nl
	ld	a,CAP_MAX
.nl:
	ld	(sel_nlen),a
	ld	c,a
	ld	b,0
	or	a
	jr	z,.back
	ld	hl,cap_buf
	ld	de,sel_name
	ldir
.back:
	ld	hl,(sel_line)		; the select line again
	ld	(src_ptr),hl
	call	src_next
	call	line_rstrip
	call	parse_field
	ld	hl,(sel_after)
	ld	(src_ptr),hl
	ret

; option_label: the option line in linebuf ("- VALUE LABEL"): Z and lab_s
; = its label (rest.strip()), NZ if it has no value.
option_label:
	ld	l,1
	call	next_token
	jr	c,.no
	ld	a,l
	ld	(lab_s),a
	call	skip_spaces_lab
	xor	a
	ret
.no:
	or	1
	ret

; option_skip: an option line in the block loop: not shown, but its
; label's links count (the reference parses them).
option_skip:
	call	option_label
	ret	nz
	jp	label_links_only

; ---- Words and the state -------------------------------------------------

ft_names:	db	"text",0, "password",0, "area",0, "check",0, "radio",0
		db	"select",0, "hidden",0, "submit",0, "reset",0, 0
w_checked:	db	"checked",0
w_max:		db	"max",0, "rows",0, "value",0
s_marks:	db	"[ ][x]( )(*)"
s_submit:	db	"Submit",0
s_reset:	db	"Reset",0

wr_mute:	db	0			; 1: count only; 2: count, links seen
mt_len:		dw	0
cap_buf:	ds	CAP_MAX
in_box:		db	0			; drawing a field's box
fld_id:		dw	0			; the field's number (with the links)
lk_is_field:	db	0			; link_hook: this is a field
lab_s:		db	0
lab_len:	dw	0
lab_links:	dw	0
tk_s:		db	0
tk_e:		db	0
pf_rest:	db	0
pf_after:	db	0
pf_eq:		db	0
pf_key:		db	0
pf_vs:		db	0
pf_ve:		db	0
fl_type:	db	0
fl_ns:		db	0
fl_ne:		db	0
fl_max:		dw	0
fl_rows:	dw	0
fl_checked:	db	0
fl_vs:		db	0
fl_ve:		db	0
fb_size:	db	0
fb_len:		db	0
br_attr:	db	0
br_id:		db	0
fbuf:		ds	WIDTH+4
sel_line:	dw	0
sel_after:	dw	0
sel_first:	dw	0
sel_plus:	dw	0
sel_long:	db	0
sel_nlen:	db	0
sel_name:	ds	CAP_MAX
