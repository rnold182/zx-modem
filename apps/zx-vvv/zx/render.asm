; render.asm - zx-vvv's 8TML renderer (M3, M4, M8): header, blocks, inline
; markup with colours and bold/italic, word wrap, screen bookmarks for
; paging, where the links are, and form fields (forms.asm).
;
; It follows the 8TML 1 reference tool (spec tools/tml/parser.py and
; render.py) step for step, so its screens match `8tml render -m zx
; --plain` (the golden files in testpages/), with the reference's colours
; mapped to the ZX (CLAUDE.md 6.6) and b/i drawn in bold and italic
; glyphs made from the ROM font.
;
; How it runs: the page stays raw in the page buffer. One pass over it
; (render_measure) records a bookmark at the start of every screen: the
; block where that screen's first row comes from, the parser state at that
; block, and how many of the block's rows went on the screen before.
; render_draw(n) restarts from bookmark n and draws 22 rows.
;
; Text blocks (paragraph, heading, list item, quote) are read as one
; joined text, like the reference: lines join with a space (none after a
; hard break or <br>). A producer joins the source lines into a window
; buffer; the inline parser reads it with enough lookahead for the longest
; construct (a link: 1 + 80 + 1 + 1 + 255 characters).
;
; The program provides: page_buf, page_end, and the buffers listed at the
; end (linebuf 256-aligned, win, label_buf, url_buf, tagbuf, the cell
; buffers, snaps), and PAGE_TOP (the first screen row of the page).

WIDTH		equ	32
SCREEN_ROWS	equ	22
BRK		equ	10		; a forced line break in joined text
NBSP		equ	127		; &nbsp;: shown as a space, never wrapped (byte 127
					; of a page is '?', so the code is free)
LOOK		equ	340		; lookahead the inline parser needs
WIN_SIZE	equ	512
MAX_SCREENS	equ	64		; 1408 rows: more than a full buffer of text
STATE_SIZE	equ	1+NUM_MAX+1+2	; flags, last list number, links so far
SNAP_SIZE	equ	4+STATE_SIZE	; src(2) rows to skip(2) state
CELL		equ	3		; a cell: character (bit 7 italic),
					; attribute (bit 7 bold), link id (0: none)
MAX_RUNS	equ	64		; link pieces on one screen
MODE_DRAW	equ	0
MODE_MEASURE	equ	1
MODE_FIND	equ	2		; find link find_no's address
MODE_LIST	equ	3		; the link list (L)
NUM_MAX		equ	10		; digits of a list number

; Colours and style words come from the stylesheet cascade (style.asm):
; role_style, mk_attr, and the attributes att_plain, att_text, att_pre,
; att_rule it works out for whole rows.

; Line kinds (classify)
K_TEXT		equ	0
K_BLANK		equ	1
K_PRE		equ	2
K_FENCE		equ	3
K_RULE		equ	4
K_HEAD		equ	5
K_BULLET	equ	6
K_NUM		equ	7
K_QUOTE		equ	8

; st_flags
F_GAP		equ	0		; a blank line is waiting to become an empty row
F_BLOCKS	equ	1		; a block has been shown
F_FORM		equ	2		; inside :::form (forms.asm)
F_SELECT	equ	3		; after a select: option lines follow

; =============================================================================
; Header

; parse_header: the page's header. Sets is_page, body_ptr, upper, title_buf,
; newer. Not a page (plain text) unless line 1 is "---" and the first key
; is 8tml; an unclosed header leaves an empty body.
parse_header:
	xor	a
	ld	(is_page),a
	ld	(newer),a
	ld	(has_form),a
	ld	(title_buf),a
	ld	(hd_stylelen),a
	inc	a
	ld	(upper),a
	ld	(hd_first),a
	ld	hl,page_buf
	ld	(src_ptr),hl
	ld	(body_ptr),hl
	call	src_next
	ret	c			; empty: plain text, no lines
	call	line_rstrip
	cp	3
	ret	nz
	ld	hl,linebuf
	ld	de,s_dashes
	call	starts3
	ret	nz
.next:
	call	src_next
	jp	c,.unclosed
	call	line_strip		; HL, B = the line without spaces around
	ld	a,b
	or	a
	jr	z,.next
	ld	a,(hl)
	cp	'#'
	jr	z,.next			; a comment
	ld	a,b
	cp	3
	jr	nz,.kv
	push	hl
	push	bc
	ld	de,s_dashes
	call	starts3
	pop	bc
	pop	hl
	jp	z,.closed
.kv:
	ld	(hd_s),hl
	ld	c,0
.colon:
	ld	a,(hl)
	cp	':'
	jr	z,.split
	inc	hl
	inc	c
	djnz	.colon
	jr	.next			; no ':'
.split:
	dec	b			; B = characters after the ':'
	inc	hl
	ld	(hd_v),hl
	ld	a,b
	ld	(hd_vlen),a
	ld	hl,(hd_s)		; the key: C characters
	ld	b,c
	call	strip_span
	ld	(hd_k),hl
	ld	a,b
	ld	(hd_klen),a
	ld	hl,(hd_v)
	ld	a,(hd_vlen)
	ld	b,a
	call	strip_span
	ld	(hd_v),hl
	ld	a,b
	ld	(hd_vlen),a
	; the first key must be 8tml
	ld	de,w_8tml
	call	hd_key_is
	jr	nz,.not8
	call	hd_version
	xor	a
	ld	(hd_first),a
	jr	.next
.not8:
	ld	a,(hd_first)
	or	a
	ret	nz			; plain text after all
	ld	de,w_title
	call	hd_key_is
	jp	nz,.style
	ld	hl,(hd_v)		; title: up to 31 characters
	ld	a,(hd_vlen)
	cp	32
	jr	c,.t
	ld	a,31
.t:
	ld	de,title_buf
	ld	c,a
	ld	b,0
	or	a
	jr	z,.t0
	ldir
.t0:
	xor	a
	ld	(de),a
	jp	.next
.style:
	ld	de,w_style		; the page's stylesheet: kept for styles_fetch
	call	hd_key_is
	jr	nz,.case
	ld	hl,(hd_v)		; copied now: the line buffer gets the next line
	ld	a,(hd_vlen)
	ld	(hd_stylelen),a
	ld	de,hd_style
	ld	c,a
	ld	b,0
	or	a
	jr	z,.s0
	ldir
.s0:
	xor	a
	ld	(de),a
	jp	.next
.case:
	ld	de,w_case
	call	hd_key_is
	jp	nz,.next
	ld	hl,(hd_v)
	ld	a,(hd_vlen)
	ld	c,a
	ld	de,w_mixed
	call	word_is
	ld	a,0
	jr	z,.mixed
	inc	a
.mixed:
	ld	(upper),a
	jp	.next
.closed:
	ld	hl,(src_ptr)
	ld	(body_ptr),hl
	ld	a,1
	ld	(is_page),a
	ret
.unclosed:
	ld	hl,(page_end)
	ld	(body_ptr),hl
	ld	a,1
	ld	(is_page),a
	ret

; hd_key_is: Z if the key (hd_k, hd_klen) is the lower-case word at DE.
hd_key_is:
	ld	hl,(hd_k)
	ld	a,(hd_klen)
	ld	c,a
	; fall through

; word_is: Z if the C characters at HL equal the lower-case 0-terminated
; word at DE, ignoring case.
word_is:
	ld	a,(de)
	or	a
	jr	z,.end
	ld	a,c
	or	a
	jr	z,.no
	ld	a,(hl)
	call	to_lower
	ex	de,hl
	cp	(hl)
	ex	de,hl
	ret	nz
	inc	hl
	inc	de
	dec	c
	jr	word_is
.end:
	ld	a,c			; both ended?
	or	a
	ret
.no:
	inc	a			; NZ
	ret

; hd_version: newer = 1 if the 8tml value is a number above 1.
hd_version:
	ld	hl,(hd_v)
	ld	a,(hd_vlen)
	or	a
	ret	z
	ld	b,a
	ld	c,0			; the value, saturating at 255
.d:
	ld	a,(hl)
	sub	'0'
	ret	c
	cp	10
	ret	nc			; not a number
	ld	e,a
	ld	a,c
	cp	26
	ld	a,255
	jr	nc,.sat
	ld	a,c
	add	a,a
	add	a,a
	add	a,c
	add	a,a			; c * 10
	add	a,e
	jr	nc,.sat
	ld	a,255
.sat:
	ld	c,a
	inc	hl
	djnz	.d
	ld	a,c
	cp	2
	ret	c
	ld	a,1
	ld	(newer),a
	ret

; =============================================================================
; Source lines

; src_next: the line at src_ptr into linebuf (0-terminated, line_len), the
; way the reference loads it: CR LF and a lone CR end a line, a tab is a
; space, other control bytes and bytes over 126 are '?'. Lines are cut at
; 255 characters. line_start = where it began, src_ptr = the next line.
; Carry set: no more lines.
src_next:
	ld	hl,(src_ptr)
	ld	(line_start),hl
	ld	bc,(page_end)
	ld	a,l
	cp	c
	jr	nz,.go
	ld	a,h
	cp	b
	jr	nz,.go
	scf
	ret
.go:
	ld	de,linebuf		; 256-aligned: E = the length so far
.l:
	ld	a,l
	cp	c
	jr	nz,.ch
	ld	a,h
	cp	b
	jr	z,.done
.ch:
	ld	a,(hl)
	inc	hl
	cp	10
	jr	z,.done
	cp	13
	jr	z,.cr
	cp	9
	jr	nz,.notab
	ld	a,' '
.notab:
	cp	32
	jr	c,.bad
	cp	127
	jr	c,.put
.bad:
	ld	a,'?'
.put:
	inc	e
	jr	z,.full			; 255 already: drop the rest of the line
	dec	e
	ld	(de),a
	inc	e
	jr	.l
.full:
	dec	e
	jr	.l
.cr:
	ld	a,l
	cp	c
	jr	nz,.cr2
	ld	a,h
	cp	b
	jr	z,.done
.cr2:
	ld	a,(hl)
	cp	10
	jr	nz,.done
	inc	hl
.done:
	ld	(src_ptr),hl
	xor	a
	ld	(de),a
	ld	a,e
	ld	(line_len),a
	ret				; carry clear

; line_rstrip: A = st_len = the line's length without trailing spaces.
line_rstrip:
	ld	hl,linebuf
	ld	a,(line_len)
	ld	l,a
.l:
	ld	a,l
	or	a
	jr	z,.done
	dec	l
	ld	a,(hl)
	cp	' '
	jr	z,.l
	inc	l
.done:
	ld	a,l
	ld	(st_len),a
	ret

; line_strip: HL = the first non-space of the line, B = the length up to
; the last non-space (0 for a blank line).
line_strip:
	call	line_rstrip
	ld	b,a
	ld	hl,linebuf
	; fall through

; strip_span: the B characters at HL without spaces at either end.
strip_span:
	ld	a,b
	or	a
	ret	z
	ld	a,(hl)
	cp	' '
	jr	nz,.right
	inc	hl
	dec	b
	jr	strip_span
.right:
	push	hl
	ld	e,b
	ld	d,0
	add	hl,de
	dec	hl
.r:
	ld	a,(hl)
	cp	' '
	jr	nz,.done
	dec	hl
	dec	b
	jr	.r			; stops: the first character isn't a space
.done:
	pop	hl
	ret

; starts3: Z if the text at HL starts with the 3 characters at DE.
starts3:
	ld	b,3
.l:
	ld	a,(de)
	cp	(hl)
	ret	nz
	inc	hl
	inc	de
	djnz	.l
	ret

; classify: what the line in linebuf is (reference parser.line()):
; k_kind, k_text (where its text starts; it ends at linebuf + st_len),
; k_level (heading 1-3), k_num/k_numlen (a list number's digits),
; k_indent2 (it starts with two spaces).
classify:
	call	line_rstrip
	ld	c,a			; C = st_len
	ld	b,0
	ld	a,(linebuf)
	cp	' '
	jr	nz,.i
	ld	a,(linebuf+1)
	cp	' '
	jr	nz,.i
	inc	b
.i:
	ld	a,b
	ld	(k_indent2),a
	ld	a,c
	or	a
	ld	a,K_BLANK
	jp	z,.kind
	push	bc
	ld	hl,linebuf
	ld	de,s_pre
	call	starts3
	pop	bc
	ld	a,K_PRE
	jp	z,.kind
	push	bc
	ld	hl,linebuf
	ld	de,s_fence
	call	starts3
	pop	bc
	ld	a,K_FENCE
	jp	z,.kind
	ld	hl,linebuf		; ls: past the leading spaces
.sp:
	ld	a,(hl)
	cp	' '
	jr	nz,.ls
	inc	l
	jr	.sp
.ls:
	ld	(k_ls),hl
	ld	a,c
	sub	l
	cp	3			; ls == "---"?
	jr	nz,.head
	push	hl
	push	bc
	ld	de,s_dashes
	call	starts3
	pop	bc
	pop	hl
	ld	a,K_RULE
	jp	z,.kind
.head:
	ld	a,(hl)
	cp	'#'
	jr	nz,.bullet
	ld	d,0
.hc:
	ld	a,(hl)
	cp	'#'
	jr	nz,.hend
	inc	l
	inc	d
	jr	.hc
.hend:
	cp	' '
	jr	nz,.retext
	ld	a,l
	cp	c
	jr	nc,.retext		; only a trailing space
	inc	l
	ld	(k_text),hl
	ld	a,d
	cp	4
	jr	c,.lv
	ld	a,3
.lv:
	ld	(k_level),a
	ld	a,K_HEAD
	jr	.kind
.retext:
	ld	hl,(k_ls)
.bullet:
	ld	a,(hl)
	cp	'*'
	jr	z,.b2
	cp	'-'
	jr	nz,.num
.b2:
	inc	l
	ld	a,(hl)
	dec	l
	cp	' '
	jr	nz,.num
	ld	a,l
	inc	a
	cp	c
	jr	nc,.num			; "* " with nothing after (can't be: rstripped)
	inc	l
	inc	l
	ld	(k_text),hl
	ld	a,K_BULLET
	jr	.kind
.num:
	ld	hl,(k_ls)
	ld	(k_num),hl
	ld	d,0
.nd:
	ld	a,(hl)
	sub	'0'
	jr	c,.ne
	cp	10
	jr	nc,.ne
	inc	l
	inc	d
	jr	.nd
.ne:
	ld	a,d
	or	a
	jr	z,.quote
	ld	a,(hl)
	cp	'.'
	jr	nz,.quote
	inc	l
	ld	a,(hl)
	cp	' '
	jr	nz,.quote
	ld	a,l
	cp	c
	jr	nc,.quote		; the space is trailing
	inc	l
	ld	(k_text),hl
	ld	a,d
	ld	(k_numlen),a
	ld	a,K_NUM
	jr	.kind
.quote:
	ld	hl,(k_ls)
	ld	a,(hl)
	cp	'>'
	jr	nz,.text
	inc	l
	ld	a,l
	cp	c
	jr	z,.q			; ">" alone
	ld	a,(hl)
	cp	' '
	jr	nz,.text
	inc	l
.q:
	ld	(k_text),hl
	ld	a,K_QUOTE
	jr	.kind
.text:
	ld	hl,(k_ls)
	ld	(k_text),hl
	ld	a,K_TEXT
.kind:
	ld	(k_kind),a
	ret

; =============================================================================
; Render passes
;
; mode: MODE_MEASURE lays the page out without drawing and records the
; bookmarks; MODE_DRAW draws one screen; MODE_FIND looks for link find_no
; (its address goes to found_url); MODE_LIST shows the link list, through
; link_hook in the program.

; render_measure: lay out the whole page without drawing; screens = how
; many screens it fills (at least 1), snaps = where each starts, lk_total =
; how many links it has. too_long = 1 if it has more than MAX_SCREENS.
render_measure:
	ld	a,MODE_MEASURE
	ld	(mode),a
	xor	a
	ld	(too_long),a
	ld	(scr_rowcnt),a
	ld	hl,0
	ld	(screens),hl
	ld	hl,(body_ptr)
	ld	(src_ptr),hl
	xor	a
	ld	(st_flags),a
	ld	(st_num),a
	ld	hl,0
	ld	(st_links),hl
	call	save_block_start
	call	snap_record		; screen 1 starts at the body
	call	render_go
	ld	hl,(st_links)
	ld	(lk_total),hl
	ret

; render_draw: draw screen HL (from 0) on rows PAGE_TOP..., noting where
; its links are (runs).
render_draw:
	xor	a			; MODE_DRAW
	ld	(mode),a
	ld	(run_n),a
	ld	a,PAGE_TOP
	ld	(dr_row),a
	push	hl
	call	snap_addr
	ld	de,4+1+NUM_MAX+1	; the links before the screen's first block
	add	hl,de
	ld	e,(hl)
	inc	hl
	ld	d,(hl)
	ld	(base_links),de
	pop	hl
	jr	render_snap

; render_find: link find_no's address -> found_url, searching from screen
; HL. Carry set if found.
render_find:
	ld	a,MODE_FIND
	ld	(mode),a
	xor	a
	ld	(found),a
	call	render_snap
	ld	a,(found)
	rra
	ret

; render_list: the link list from link list_first on, through link_hook.
render_list:
	ld	a,MODE_LIST
	ld	(mode),a
	ld	hl,0
	; fall through

; render_snap: run the page from bookmark HL.
render_snap:
	call	snap_addr
	ld	de,src_ptr
	ldi
	ldi
	ld	de,skip
	ldi
	ldi
	ld	de,st_flags
	ld	bc,STATE_SIZE
	ldir
	; fall through

; render_go: run the page from src_ptr. A full screen, too many screens or
; a found link ends it early through render_abort.
render_go:
	ld	(render_sp),sp
	xor	a
	ld	(lk_is_field),a
	ld	(wr_mute),a
	ld	(in_box),a
	ld	a,(is_page)
	or	a
	jp	z,render_plain
	jp	render_body

render_abort:
	ld	sp,(render_sp)
	ret

; snap_addr: HL = the address of bookmark HL (snaps + HL * 18).
snap_addr:
	add	hl,hl
	ld	d,h
	ld	e,l
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,de
	ld	de,snaps
	add	hl,de
	ret

; save_block_start: where the next block starts, for a bookmark.
save_block_start:
	ld	hl,(src_ptr)
	ld	(bs_src),hl
	ld	hl,st_flags
	ld	de,bs_flags
	ld	bc,STATE_SIZE
	ldir
	ld	hl,0
	ld	(blk_rows),hl
	ret

; snap_record: a bookmark for the screen that starts now.
snap_record:
	ld	hl,(screens)
	ld	de,MAX_SCREENS
	or	a
	sbc	hl,de
	jr	c,.ok
	ld	a,1
	ld	(too_long),a
	jr	render_abort
.ok:
	ld	hl,(screens)
	call	snap_addr
	ex	de,hl
	ld	hl,bs_src
	ldi
	ldi
	ld	hl,blk_rows
	ldi
	ldi
	ld	hl,bs_flags
	ld	bc,STATE_SIZE
	ldir
	ld	hl,(screens)
	inc	hl
	ld	(screens),hl
	ret

; row_emit: one row of A cells from rowbuf. Measuring: count it (a new
; screen every 22 rows). Drawing: skip the rows before the screen, draw the
; rest and note where the links are, stop when the screen is full.
row_emit:
	ld	(row_len),a
	ld	a,(mode)
	cp	MODE_MEASURE
	jr	z,.measure
	or	a
	ret	nz			; finding or listing links: no rows
	ld	hl,(skip)
	ld	a,h
	or	l
	jr	z,.show
	dec	hl
	ld	(skip),hl
	ret
.measure:
	ld	a,(scr_rowcnt)
	cp	SCREEN_ROWS
	jr	nz,.count
	call	snap_record
	xor	a
.count:
	inc	a
	ld	(scr_rowcnt),a
	ld	hl,(blk_rows)
	inc	hl
	ld	(blk_rows),hl
	ret
.show:
	xor	a
	ld	(re_col),a
	ld	(re_prev),a
	ld	hl,rowbuf
	ld	(re_ptr),hl
.c:
	ld	a,(re_col)
	ld	hl,row_len
	cp	(hl)
	jr	nc,.next
	ld	c,a
	ld	hl,(re_ptr)
	ld	d,(hl)
	inc	hl
	ld	e,(hl)
	inc	hl
	ld	a,(hl)
	inc	hl
	ld	(re_ptr),hl
	ld	(re_id),a
	ld	a,(dr_row)
	ld	b,a
	call	put_cell
	call	note_link
	ld	hl,re_col
	inc	(hl)
	jr	.c
.next:
	ld	a,(dr_row)
	inc	a
	ld	(dr_row),a
	cp	PAGE_TOP+SCREEN_ROWS
	ret	nz
	jp	render_abort

; note_link: the cell just drawn (re_col, re_id) into the screen's link
; runs: [link number:2][row][column][length], in the order drawn.
note_link:
	ld	a,(re_id)
	ld	b,a
	ld	a,(re_prev)
	cp	b
	ld	a,b
	ld	(re_prev),a
	jr	nz,.new
	or	a
	ret	z			; no link
	ld	hl,(run_last)		; the same link goes on: one longer
	inc	(hl)
	ret
.new:
	or	a
	ret	z
	ld	a,(run_n)
	cp	MAX_RUNS
	ret	nc
	inc	a
	ld	(run_n),a
	dec	a
	ld	l,a
	ld	h,0
	ld	d,h
	ld	e,l
	add	hl,hl
	add	hl,hl
	add	hl,de			; * 5
	ld	de,runs
	add	hl,de
	push	hl
	ld	a,(base_links)		; the link's number from its id: the
	and	0x7F			; next one with these low 7 bits
	ld	e,a
	ld	a,b
	and	0x7F
	sub	e
	and	0x7F
	ld	e,a
	ld	d,0
	ld	hl,(base_links)
	add	hl,de
	ex	de,hl
	pop	hl
	ld	(hl),e
	inc	hl
	ld	(hl),d
	inc	hl
	ld	a,(dr_row)
	ld	(hl),a
	inc	hl
	ld	a,(re_col)
	ld	(hl),a
	inc	hl
	ld	(hl),1
	ld	(run_last),hl
	ret

; put_cell: draw character D (bit 7: italic; NBSP is a space) at row B,
; column C with attribute E (bit 7: bold), from the ROM font. Bold ORs each
; glyph row with itself one pixel to the right; italic shifts the top four
; rows one pixel to the right.
put_cell:
	ld	a,e
	ld	(pc_attr),a
	ld	a,d
	and	0x80
	ld	(pc_ital),a
	ld	a,b			; HL = the cell's top pixel row
	and	0x18
	or	0x40
	ld	h,a
	ld	a,b
	and	7
	rrca
	rrca
	rrca
	or	c
	ld	l,a
	push	hl
	ld	a,d
	and	0x7F
	cp	NBSP
	jr	nz,.g
	ld	a,' '
.g:
	sub	32
	ld	l,a
	ld	h,0
	add	hl,hl
	add	hl,hl
	add	hl,hl
	ld	bc,0x3D00		; the ROM font, from character 32
	add	hl,bc
	ex	de,hl
	pop	hl
	ld	b,8
.row:
	ld	a,(de)
	ld	c,a
	ld	a,(pc_attr)
	rla
	jr	nc,.nb
	ld	a,c			; bold
	srl	a
	or	c
	ld	c,a
.nb:
	ld	a,(pc_ital)
	or	a
	jr	z,.put
	ld	a,b
	cp	5
	jr	c,.put
	srl	c			; italic: rows 0-3
.put:
	ld	(hl),c
	inc	de
	inc	h
	djnz	.row
	ld	a,h			; the attribute: 0x5800 + row * 32 + column
	sub	8
	and	0x18
	rrca
	rrca
	rrca
	or	0x58
	ld	h,a
	ld	a,(pc_attr)
	and	0x7F
	ld	(hl),a
	ret

; row_text: a row of A characters from HL (cut by the caller), attribute
; C, in the page's case.
row_text:
	ld	de,rowbuf
	ld	b,a
	push	af
	or	a
	jr	z,.e
.l:
	ld	a,(hl)
	inc	hl
	call	to_case
	ld	(de),a
	inc	de
	ld	a,c
	ld	(de),a
	inc	de
	xor	a
	ld	(de),a
	inc	de
	djnz	.l
.e:
	pop	af
	jp	row_emit

; empty_row / block_begin: a waiting blank line becomes an empty row when
; the next block starts (blank lines at the end show nothing).
block_begin:
	ld	hl,st_flags
	set	F_BLOCKS,(hl)
	bit	F_GAP,(hl)
	ret	z
	res	F_GAP,(hl)
empty_row:
	xor	a
	jp	row_emit

; =============================================================================
; Plain text: not an 8TML page. Every line is cut every 32 characters.

render_plain:
.loop:
	call	save_block_start
	call	src_next
	ret	c
	ld	a,(line_len)
	or	a
	jr	nz,.chunks
	call	empty_row
	jr	.loop
.chunks:
	ld	(pl_left),a
	ld	hl,linebuf
	ld	(pl_p),hl
.c:
	ld	a,(pl_left)
	cp	WIDTH+1
	jr	c,.n
	ld	a,WIDTH
.n:
	ld	(pl_n),a
	ld	hl,(pl_p)
	push	af
	ld	a,(att_text)
	ld	c,a
	pop	af
	call	row_text
	ld	a,(pl_n)
	ld	e,a
	ld	d,0
	ld	hl,(pl_p)
	add	hl,de
	ld	(pl_p),hl
	ld	a,(pl_left)
	sub	e
	ld	(pl_left),a
	jr	nz,.c
	jr	.loop

; =============================================================================
; 8TML body: the block loop (reference parser.line())

render_body:
.loop:
	call	save_block_start
	call	src_next
	ret	c
	call	classify
	ld	a,(k_kind)
	cp	K_PRE
	jp	z,.pre
	cp	K_FENCE
	jp	z,.fence
	ld	hl,st_flags		; in a form: field lines
	bit	F_FORM,(hl)
	jr	z,.nofield
	call	is_field_line
	jr	nz,.nofield
	ld	hl,st_flags
	res	F_SELECT,(hl)
	call	field_block
	jr	.loop
.nofield:
	ld	hl,st_flags		; after a select: its option lines
	bit	F_SELECT,(hl)
	jr	z,.noopt
	call	is_option_line
	jr	nz,.noopt
	call	option_skip
	jr	.loop
.noopt:
	ld	hl,st_flags		; any other line ends the options
	res	F_SELECT,(hl)
	ld	a,(k_kind)
	cp	K_BLANK
	jr	z,.blank
	ld	hl,st_num		; number, last_number = last_number, None
	ld	de,num_prev
	ld	bc,NUM_MAX+1
	ldir
	xor	a
	ld	(st_num),a
	ld	a,(k_kind)
	cp	K_RULE
	jr	z,.rule
	call	text_block
	jr	.loop
.blank:
	ld	hl,st_flags
	bit	F_BLOCKS,(hl)
	jr	z,.loop
	set	F_GAP,(hl)
	jr	.loop
.rule:
	call	block_begin
	ld	hl,rowbuf
	ld	b,WIDTH
	ld	a,(att_rule)
	ld	c,a
.r:
	ld	(hl),'-'
	inc	hl
	ld	(hl),c
	inc	hl
	ld	(hl),0
	inc	hl
	djnz	.r
	ld	a,WIDTH
	call	row_emit
	jp	.loop
.pre:
	xor	a
	ld	(st_num),a
	call	block_begin
.pl:
	call	src_next
	ret	c			; open at the end: shown up to here
	ld	hl,linebuf
	ld	de,s_pre
	call	starts3			; (the line's end has spaces or a 0)
	jp	z,.loop
	ld	a,(line_len)
	cp	WIDTH+1
	jr	c,.pc
	ld	a,WIDTH
.pc:
	ld	hl,linebuf
	push	af
	ld	a,(att_pre)
	ld	c,a
	pop	af
	call	row_text
	jr	.pl
.fence:
	xor	a
	ld	(st_num),a
	ld	hl,linebuf+3		; the block type after ":::"
	ld	a,(st_len)
	sub	3
	ld	b,a
	call	strip_span
	ld	a,b
	or	a
	jr	nz,.word
	ld	hl,st_flags		; ":::" alone: the end of a form (or stray)
	res	F_FORM,(hl)
	res	F_SELECT,(hl)
	jp	.loop
.word:
	ld	c,b			; the first word
	push	hl
.w:
	ld	a,(hl)
	cp	' '
	jr	z,.wend
	inc	hl
	djnz	.w
.wend:
	ld	a,c
	sub	b
	ld	c,a
	pop	hl
	ld	de,w_form
	call	word_is
	jr	nz,.skip
	ld	hl,st_flags		; :::form (inside a form: ignored)
	set	F_FORM,(hl)
	jp	.loop
.skip:
	call	src_next
	ret	c			; open at the end
	call	line_rstrip
	cp	3
	jr	nz,.skip
	ld	hl,linebuf
	ld	de,s_fence
	call	starts3
	jr	nz,.skip
	jp	.loop

; =============================================================================
; Text blocks: paragraph, heading, list item, quote

text_block:
	call	block_begin
	xor	a
	ld	(bk_indent),a
	ld	(bk_mlen),a
	ld	(bk_center),a
	ld	(pr_head),a
	ld	a,(k_kind)
	ld	(pr_kind),a
	cp	K_HEAD
	jr	nz,.bul
	ld	(pr_head),a		; no continuation lines
	ld	a,(k_level)		; h1-h3 are keys 1-3
	jr	.attr
.bul:
	cp	K_BULLET
	jr	nz,.numb
	ld	a,'*'
	ld	(bk_marker),a
	ld	a,1
	ld	(bk_mlen),a
	ld	a,2
	ld	(bk_indent),a
	ld	a,S_TEXT
	jr	.attr
.numb:
	cp	K_NUM
	jr	nz,.quo
	call	list_number
	ld	a,S_TEXT
	jr	.attr
.quo:
	cp	K_QUOTE
	ld	a,S_TEXT		; paragraphs and items: the text role
	jr	nz,.attr
	ld	a,2
	ld	(bk_indent),a
	ld	a,S_QUOTE
.attr:
	call	role_style		; the block's role: colour and words
	ld	a,e
	ld	(bk_flags),a
	ld	a,d
	ld	(bk_col),a
	ld	a,(bk_indent)
	ld	b,a
	ld	a,WIDTH
	sub	b
	ld	(wr_width),a
	; the first part, and the window
	ld	hl,(k_text)
	call	pr_part
	xor	a
	ld	(pr_eof),a
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
	; <center> at the very start centres the block
	ld	hl,(in_p)
	ld	c,8
	ld	de,w_center
	call	word_is_prefix
	jr	nz,.nocenter
	ld	(in_p),hl
	ld	a,1
	ld	(bk_center),a
.sp:
	call	win_need
	ld	hl,(in_p)
	ld	a,(hl)
	cp	' '
	jr	nz,.nocenter
	inc	hl
	ld	(in_p),hl
	jr	.sp
.nocenter:
	ld	a,(bk_flags)		; the role's "center" word centres it too
	and	SF_CENTER
	jr	z,.nocw
	ld	a,1
	ld	(bk_center),a
.nocw:
	; wrap and inline state
	xor	a
	ld	(cur_len),a
	ld	(word_len),a
	ld	(in_link),a
	call	in_reset
	ld	hl,0
	ld	(pend_cnt),hl
	ld	(lines_out),hl
	ld	a,1
	ld	(in_outer),a
	ld	a,' '
	ld	(in_prev),a
	call	inline_run
	call	wr_end
	ld	hl,(stop_ptr)		; the line that ended the block
	ld	(src_ptr),hl
	ret

; word_is_prefix: Z if the C characters at HL start with the lower-case
; word at DE (ignoring case); then HL is just past it.
word_is_prefix:
	ld	a,(de)
	or	a
	ret	z
	ld	a,(hl)
	call	to_lower
	ex	de,hl
	cp	(hl)
	ex	de,hl
	ret	nz
	inc	hl
	inc	de
	jr	word_is_prefix

; list_number: the shown number of a numbered item: the written one
; (without leading zeros) for the first, the previous + 1 after that. It
; becomes st_num, and the marker "N." (bk_marker, bk_mlen, bk_indent).
list_number:
	ld	a,(num_prev)
	or	a
	jr	nz,.inc
	ld	hl,(k_num)
	ld	a,(k_numlen)
	ld	b,a
.z:
	ld	a,b
	cp	1
	jr	z,.copy
	ld	a,(hl)
	cp	'0'
	jr	nz,.copy
	inc	hl
	dec	b
	jr	.z
.copy:
	ld	a,b
	cp	NUM_MAX+1
	jr	c,.c2
	ld	b,NUM_MAX
.c2:
	ld	a,b
	ld	(st_num),a
	ld	de,st_num+1
	ld	c,b
	ld	b,0
	ldir
	jr	.marker
.inc:
	ld	hl,num_prev
	ld	de,st_num
	ld	bc,NUM_MAX+1
	ldir
	ld	a,(st_num)		; + 1, in decimal digits
	ld	e,a
	ld	d,0
	ld	hl,st_num
	add	hl,de
	ld	b,a
.d:
	ld	a,(hl)
	cp	'9'
	jr	nz,.plus
	ld	(hl),'0'
	dec	hl
	djnz	.d
	ld	a,(st_num)		; all nines: a 1 in front
	cp	NUM_MAX
	jr	nc,.marker
	ld	c,a
	ld	b,0
	ld	hl,st_num
	add	hl,bc
	ld	d,h
	ld	e,l
	inc	de
	lddr
	ld	a,'1'
	ld	(st_num+1),a
	ld	hl,st_num
	inc	(hl)
	jr	.marker
.plus:
	inc	a
	ld	(hl),a
.marker:
	ld	a,(st_num)
	ld	c,a
	ld	b,0
	ld	hl,st_num+1
	ld	de,bk_marker
	ldir
	ld	a,'.'
	ld	(de),a
	ld	a,(st_num)
	inc	a
	ld	(bk_mlen),a
	inc	a
	ld	(bk_indent),a
	ret

; =============================================================================
; The producer: a text block's lines joined into one text, into the window

; pr_part: a part starting at HL, ending at linebuf + st_len; a trailing
; odd run of backslashes is a hard break (one backslash goes).
pr_part:
	ld	(pr_ptr),hl
	ld	a,(st_len)
	ld	hl,linebuf
	ld	l,a
	ld	(pr_end),hl
	ld	de,(pr_ptr)
	ld	b,0
.bs:
	ld	a,l
	cp	e
	jr	z,.counted
	dec	l
	ld	a,(hl)
	cp	'\'
	jr	nz,.counted
	inc	b
	jr	.bs
.counted:
	ld	a,b
	and	1
	ld	(pr_hard),a
	ret	z
	ld	hl,(pr_end)
	dec	hl
	ld	(pr_end),hl
	ret

; produce_char: A = the next character of the joined text; carry = the
; block's text has ended (stop_ptr = the line after it).
produce_char:
.again:
	ld	hl,(pr_ptr)
	ld	de,(pr_end)
	ld	a,l
	cp	e
	jr	z,.partend
	ld	a,(hl)
	inc	hl
	ld	(pr_ptr),hl
	jr	.out
.partend:
	ld	a,(pr_hard)
	or	a
	jr	z,.nextline
	xor	a
	ld	(pr_hard),a
	ld	a,BRK
	jr	.out
.nextline:
	ld	a,(pr_head)
	or	a
	jr	nz,.end
	call	src_next
	jr	c,.end
	call	classify
	ld	a,(k_kind)
	ld	b,a
	ld	a,(pr_kind)
	cp	K_QUOTE
	jr	z,.quote
	cp	K_TEXT
	jr	z,.para
	ld	a,b			; a list item: lines indented by 2
	cp	K_TEXT
	jr	nz,.stop
	ld	a,(k_indent2)
	or	a
	jr	z,.stop
	jr	.cont
.quote:
	ld	a,b
	cp	K_QUOTE
	jr	nz,.stop
	jr	.cont
.para:
	ld	a,b
	cp	K_TEXT
	jr	nz,.stop
	ld	a,(st_flags)		; in a form a field line ends it
	bit	F_FORM,a
	jr	z,.cont
	call	is_field_line
	jr	z,.stop
.cont:
	ld	hl,(k_text)
	call	pr_part
	ld	a,(hist+3)		; a space between parts, unless after a break
	cp	BRK
	jr	z,.again
	call	hist_is_br
	jr	z,.again
	ld	a,' '
.out:
	ld	hl,hist+1
	ld	de,hist
	ldi
	ldi
	ldi
	ld	(hist+3),a
	or	a			; carry clear
	ret
.stop:
	ld	hl,(line_start)		; this line starts the next block
	ld	(stop_ptr),hl
	scf
	ret
.end:
	ld	hl,(src_ptr)
	ld	(stop_ptr),hl
	scf
	ret

; hist_is_br: Z if the text so far ends with "<br>" (any case).
hist_is_br:
	ld	a,(hist)
	cp	'<'
	ret	nz
	ld	a,(hist+1)
	call	to_lower
	cp	'b'
	ret	nz
	ld	a,(hist+2)
	call	to_lower
	cp	'r'
	ret	nz
	ld	a,(hist+3)
	cp	'>'
	ret

; win_need: at least LOOK characters ahead of in_p in the window (or the
; whole rest of the block). The window ends with a 0.
win_need:
	ld	a,(pr_eof)
	or	a
	ret	nz
	ld	hl,(win_end)
	ld	de,(in_p)
	or	a
	sbc	hl,de
	ld	bc,LOOK
	or	a
	sbc	hl,bc
	ret	nc
	add	hl,bc			; HL = what is left: move it to the start
	ld	b,h
	ld	c,l
	ld	hl,(in_p)
	ld	de,win
	ld	a,b
	or	c
	jr	z,.moved
	ldir
.moved:
	ld	(win_end),de
	ld	hl,win
	ld	(in_p),hl
.fill:
	ld	hl,(win_end)
	ld	de,win+WIN_SIZE
	or	a
	sbc	hl,de
	jr	nc,.full
	call	produce_char
	jr	c,.eof
	ld	hl,(win_end)
	ld	(hl),a
	inc	hl
	ld	(win_end),hl
	jr	.fill
.eof:
	ld	a,1
	ld	(pr_eof),a
.full:
	ld	hl,(win_end)
	ld	(hl),0
	ret

; =============================================================================
; Inline markup (reference parser.inline()): the text side. Reads the
; 0-terminated text at in_p (the window when in_outer = 1, else a link's
; label) and sends the characters it shows to wr_char.

inline_run:
.step:
	ld	a,(in_outer)
	or	a
	call	nz,win_need
	ld	hl,(in_p)
	ld	a,(hl)
	or	a
	ret	z
	cp	'\'
	jr	z,.bslash
	cp	'&'
	jr	z,.amp
	cp	'<'
	jp	z,.lt
	cp	'*'
	jp	z,.star
	cp	'['
	jp	z,.bracket
.emit:
	call	wr_char
	inc	hl
.adv:
	ld	(in_p),hl
	dec	hl
	ld	a,(hl)
	ld	(in_prev),a
	jr	.step

.bslash:				; \ + punctuation = that character
	inc	hl
	ld	a,(hl)
	call	is_punct
	jr	c,.emit
	ld	a,'\'
	call	wr_char
	jr	.adv

.amp:					; &name; within 9 characters
	push	hl
	ld	b,0
.af:
	inc	hl
	inc	b
	ld	a,b
	cp	10
	jr	z,.anone
	ld	a,(hl)
	or	a
	jr	z,.anone
	cp	';'
	jr	nz,.af
	ld	(tok_end),hl
	pop	hl
	push	hl
	inc	hl
	ld	a,b
	dec	a
	ld	c,a
	call	entity_value
	jr	nc,.anone
	pop	hl
	call	wr_char
	ld	hl,(tok_end)
	inc	hl
	jr	.adv
.anone:
	pop	hl
	ld	a,'&'
	jr	.emit

.lt:					; <tag> within 13 characters
	push	hl
	ld	b,0
.lf:
	inc	hl
	inc	b
	ld	a,b
	cp	14
	jr	z,.lnone
	ld	a,(hl)
	or	a
	jr	z,.lnone
	cp	'>'
	jr	nz,.lf
	ld	(tok_end),hl
	pop	hl
	push	hl
	inc	hl
	ld	a,b
	dec	a
	ld	c,a
	call	tag_kind
	or	a
	jr	z,.lnone
	cp	2
	jr	nz,.l3
	call	in_reset
	jr	.lok
.l3:
	cp	3
	jr	nz,.l4
	ld	a,BRK
	call	wr_char
	jr	.lok
.l4:
	cp	4
	jr	nz,.l5
	ld	a,(tag_val)		; <colour>
	ld	(in_color),a
	jr	.lok
.l5:
	cp	5
	jr	nz,.lok
	ld	a,(tag_val)		; <b> <i> <rev>: 1 2 3
	ld	e,a
	ld	d,0
	ld	hl,in_b-1
	add	hl,de
	ld	(hl),1
.lok:
	pop	hl
	ld	hl,(tok_end)
	inc	hl
	jp	.adv
.lnone:
	pop	hl
	ld	a,'<'
	jp	.emit

.star:					; emphasis, by the flanking rules
	inc	hl
	ld	a,(hl)
	dec	hl
	cp	'*'
	ld	a,1
	jr	nz,.s1
	inc	a
.s1:
	ld	(st_w),a
	ld	e,a
	ld	d,0
	push	hl
	add	hl,de
	ld	a,(hl)			; the character after the stars
	pop	hl
	ld	(st_nxt),a
	ld	a,(st_w)
	dec	a
	ld	de,in_em
	jr	z,.s2
	ld	de,in_strong
.s2:
	ld	a,(de)
	or	a
	jr	z,.sopen
	ld	a,(in_prev)		; open: closes after a non-space
	call	is_space
	jr	z,.slit
	call	in_reset
	jr	.sskip
.sopen:
	ld	a,(st_nxt)		; opens before a non-space
	call	is_space
	jr	z,.slit
	ld	a,1
	ld	(de),a
	ld	a,(st_w)		; and sets i (*) or b (**)
	cp	2
	ld	a,1
	jr	z,.sb
	ld	(in_i),a
	jr	.sskip
.sb:
	ld	(in_b),a
.sskip:
	ld	a,(st_w)
	ld	e,a
	ld	d,0
	add	hl,de
	jp	.adv
.slit:
	ld	a,'*'
	jp	.emit

.bracket:				; [text](url): text up to 80, url up to 255
	ld	a,(in_outer)
	or	a
	ld	a,'['
	jp	z,.emit			; no links inside a link's text
	push	hl
	ld	b,0
.bf:
	inc	hl
	inc	b
	ld	a,b
	cp	82
	jp	z,.bnone
	ld	a,(hl)
	or	a
	jp	z,.bnone
	cp	']'
	jr	nz,.bf
	inc	hl
	ld	a,(hl)
	cp	'('
	jp	nz,.bnone
	ld	a,b
	dec	a
	ld	(lk_llen),a
	inc	hl
	ld	(lk_url),hl
	ld	bc,0
.uf:
	ld	a,(hl)
	or	a
	jp	z,.bnone
	cp	')'
	jr	z,.ufound
	inc	hl
	inc	bc
	ld	a,b
	or	a
	jr	z,.uf
	jp	.bnone			; 256 characters without a ')'
.ufound:
	ld	(tok_end),hl
	; the url, without white space at either end, into url_buf
	ld	hl,(lk_url)
.ul:
	ld	a,c
	or	a
	jr	z,.ucopy
	ld	a,(hl)
	call	is_space
	jr	nz,.ur
	inc	hl
	dec	c
	jr	.ul
.ur:
	push	hl
	ld	e,c
	ld	d,0
	add	hl,de
	dec	hl
.ur2:
	ld	a,(hl)
	call	is_space
	jr	nz,.ur3
	dec	hl
	dec	c
	jr	.ur2
.ur3:
	pop	hl
.ucopy:
	ld	de,url_buf
	ld	b,0
	ld	a,c
	or	a
	jr	z,.u0
	ldir
.u0:
	xor	a
	ld	(de),a
	; a link: its number, and the program's look at it (find, list)
	ld	hl,(st_links)
	ld	(lk_cur),hl
	inc	hl
	ld	(st_links),hl
	ld	a,(wr_mute)		; only counting a label: nobody looks
	dec	a
	jr	z,.nohook
	ld	a,(mode)
	cp	MODE_FIND
	call	nc,link_hook
.nohook:
	; the label: the text, or the url if there is none
	pop	hl
	inc	hl
	ld	a,(lk_llen)
	or	a
	ld	de,url_buf
	jr	z,.lab
	ld	c,a
	ld	b,0
	ld	de,label_buf
	push	de
	ldir
	xor	a
	ld	(de),a
	pop	de
.lab:
	; run the label with a fresh state; the outer state waits on the stack
	ld	hl,(tok_end)
	inc	hl
	push	hl
	ld	hl,(in_em)		; in_em .. in_color: 6 bytes
	push	hl
	ld	hl,(in_em+2)
	push	hl
	ld	hl,(in_em+4)
	push	hl
	ex	de,hl
	ld	(in_p),hl
	xor	a
	ld	(in_outer),a
	call	in_reset
	ld	a,1
	ld	(in_link),a
	ld	a,' '
	ld	(in_prev),a
	call	inline_run
	pop	hl
	ld	(in_em+4),hl
	pop	hl
	ld	(in_em+2),hl
	pop	hl
	ld	(in_em),hl
	xor	a
	ld	(in_link),a
	pop	hl
	ld	(in_p),hl
	ld	a,1
	ld	(in_outer),a
	ld	a,')'
	ld	(in_prev),a
	jp	.step
.bnone:
	pop	hl
	ld	a,'['
	jp	.emit

; in_reset: a closing tag or emphasis ends all inline state.
in_reset:
	xor	a
	ld	(in_em),a
	ld	(in_strong),a
	ld	(in_b),a
	ld	(in_i),a
	ld	(in_rev),a
	dec	a
	ld	(in_color),a		; 0xFF: none
	ret

; is_space: Z if A is a space, a line break or the end (0).
is_space:
	or	a
	ret	z
	cp	' '
	ret	z
	cp	BRK
	ret

; is_punct: carry if A is ASCII punctuation (what a backslash escapes).
is_punct:
	cp	33
	jr	c,.no
	cp	48
	ret	c
	cp	58
	jr	c,.no
	cp	65
	ret	c
	cp	91
	jr	c,.no
	cp	97
	ret	c
	cp	123
	jr	c,.no
	cp	127
	ret
.no:
	or	a
	ret

; entity_value: the C characters at HL are an entity's name. Carry and
; A = its character if it is one: lt gt amp quot nbsp (any case), or
; #digits (32-126, else '?').
entity_value:
	ld	a,c
	or	a
	ret	z			; no carry
	ld	a,(hl)
	cp	'#'
	jr	z,.num
	ld	de,entities
.e:
	ld	a,(de)
	or	a
	ret	z			; not one of them (no carry)
	push	hl
	push	bc
	push	de
	call	word_is
	pop	de
	pop	bc
	pop	hl
	push	af
.skip:					; DE past the name's 0
	ld	a,(de)
	inc	de
	or	a
	jr	nz,.skip
	pop	af
	jr	z,.found
	inc	de			; past the character
	jr	.e
.found:
	ld	a,(de)
	scf
	ret
.num:
	dec	c
	ret	z			; "&#;"
	inc	hl
	ld	b,c
	ld	c,0
.d:
	ld	a,(hl)
	sub	'0'
	jr	c,.nonum
	cp	10
	jr	nc,.nonum
	ld	e,a
	ld	a,c
	cp	26
	ld	a,255
	jr	nc,.sat
	ld	a,c
	add	a,a
	add	a,a
	add	a,c
	add	a,a
	add	a,e
	jr	nc,.sat
	ld	a,255
.sat:
	ld	c,a
	inc	hl
	djnz	.d
	ld	a,c
	cp	32
	jr	c,.q
	cp	127
	jr	c,.ok
.q:
	ld	a,'?'
.ok:
	scf
	ret
.nonum:
	or	a
	ret

; tag_kind: the C characters at HL are what is between < and >.
; A = 0 not a tag (printed), 1 a tag with no effect (<center>), 2 a
; closing tag that resets the inline state, 3 <br>, 4 a colour, 5 b/i/rev
; (tag_val: the colour, or 1 b, 2 i, 3 rev).
tag_kind:
	ld	de,tagbuf		; lower case copy, 0-terminated
	ld	b,c
	ld	a,c
	or	a
	jr	z,.copied
.cp:
	ld	a,(hl)
	call	to_lower
	ld	(de),a
	inc	hl
	inc	de
	djnz	.cp
.copied:
	xor	a
	ld	(de),a
	ld	hl,tagbuf
	ld	a,(hl)
	cp	'/'
	jr	nz,.open
	inc	hl			; closing
	dec	c
	ld	a,2
	ret	z			; </>
	call	tag_name_kind		; 1 colour, 2 flag, 3 center, 4 br, 0 other
	cp	3
	jr	z,.one			; </center>: no effect
	cp	4
	jr	z,.zero			; </br> is printed
	or	a
	ret	z
	ld	a,2			; </colour>, </b>, </i>, </rev>
	ret
.open:
	ld	a,c
	or	a
	ret	z			; <>
	call	tag_name_kind
	or	a
	ret	z
	cp	3
	jr	z,.one
	cp	4
	jr	z,.br
	add	a,3			; colour 4, flag 5
	ret
.one:
	ld	a,1
	ret
.br:
	ld	a,3
	ret
.zero:
	xor	a
	ret

; tag_name_kind: the C characters at HL (lower case): A = 1 a colour name,
; 2 b/i/rev, 3 center, 4 br, 0 anything else; tag_val = its value.
tag_name_kind:
	push	hl
	push	bc
	ld	de,tag_names
.n:
	ld	a,(de)
	or	a
	jr	z,.none
	push	hl
	push	bc
	push	de
	inc	de
	inc	de
	call	word_is
	pop	de
	pop	bc
	pop	hl
	jr	z,.found
	inc	de			; DE: kind -> the next kind
.skip:
	inc	de
	ld	a,(de)
	or	a
	jr	nz,.skip
	inc	de
	jr	.n
.found:
	inc	de
	ld	a,(de)
	ld	(tag_val),a
	dec	de
	ld	a,(de)			; the kind
	pop	bc
	pop	hl
	ret
.none:
	pop	bc
	pop	hl
	xor	a
	ret

; =============================================================================
; Word wrap (reference render.wrap() and text_block()). Cells are
; [character][attribute][link id], CELL bytes.

; cell_style: B = the character's italic bit, C = the attribute (bit 7
; bold), E = the link id, for the inline state now (reference
; render.cells()): the role's colour (or the link's), em's then strong's
; colour for i and b, then an inline colour; reversed by the role or <rev>.
cell_style:
	ld	a,(in_box)		; a field's box: field / field-sel, its
	or	a			; colour and reverse only, no case
	jr	z,.nobox
	ld	hl,(fld_id)
	ld	de,(sel_link)
	or	a
	sbc	hl,de
	ld	a,S_FIELD
	jr	nz,.fs
	ld	a,S_FIELDSEL
.fs:
	call	role_style
	ld	a,e
	and	1
	ld	c,a
	ld	a,d
	call	mk_attr
	ld	c,a
	ld	b,0
	ld	d,0
	ld	a,(fld_id)
	or	0x80
	ld	e,a
	ret
.nobox:
	ld	a,(in_link)
	or	a
	jr	z,.blk
	ld	hl,(lk_cur)		; a link: link-sel when it is the focused one
	ld	de,(sel_link)
	or	a
	sbc	hl,de
	ld	a,S_LINK
	jr	nz,.lk
	ld	a,S_LINKSEL
.lk:
	call	role_style
	jr	.role
.blk:
	ld	a,(bk_col)
	ld	d,a
	ld	a,(bk_flags)
	ld	e,a
.role:
	ld	a,d
	ld	(cs_col),a
	ld	a,e
	ld	(cs_flags),a
	ld	a,(in_i)		; i: em on top, b: strong on top
	or	a
	ld	a,S_EM
	call	nz,.over
	ld	a,(in_b)
	or	a
	ld	a,S_STRONG
	call	nz,.over
	ld	a,(in_color)		; an inline colour
	cp	NO_COLOUR
	jr	z,.nc
	ld	(cs_col),a
.nc:
	ld	a,(in_rev)		; inline rev
	or	a
	jr	z,.nr
	ld	hl,cs_flags
	set	0,(hl)
.nr:
	ld	a,(cs_flags)
	ld	c,a
	ld	a,(cs_col)
	call	mk_attr
	ld	c,a
	ld	a,(in_b)
	or	a
	jr	z,.nob
	set	7,c			; bold rides in the FLASH bit
.nob:
	ld	a,(cs_flags)		; upper case: the role's word, or the page's
	and	SF_UPPER
	ld	d,a
	ld	a,(upper)
	or	d
	ld	d,a
	ld	a,(in_i)
	rrca
	and	0x80
	ld	b,a
	ld	e,0
	ld	a,(in_link)
	or	a
	ret	z
	ld	a,(lk_cur)		; the link's id: its number's low 7 bits + 128
	or	0x80
	ld	e,a
	ret
.over:					; em/strong: its colour if it has one;
	add	a,a			; reverse and upper add
	ld	l,a
	ld	h,0
	ld	de,sty
	add	hl,de
	ld	a,(hl)
	cp	NO_COLOUR
	jr	z,.keep
	ld	(cs_col),a
.keep:
	inc	hl
	ld	a,(hl)
	and	SF_REV|SF_UPPER
	ld	e,a
	ld	a,(cs_flags)
	or	e
	ld	(cs_flags),a
	ret

; wr_char: one character of the block's text. Keeps HL.
wr_char:
	push	hl
	ld	l,a
	ld	a,(wr_mute)
	or	a
	ld	a,l
	jr	nz,.mute
	cp	BRK
	jr	z,.brk
	cp	' '
	jr	z,.space
	push	af
	ld	a,(word_len)
	call	cells_at
	ld	de,word_cells
	add	hl,de
	push	hl
	call	cell_style		; (uses HL)
	pop	hl
	pop	af
	inc	d			; this cell's case
	dec	d
	jr	z,.case
	cp	'a'
	jr	c,.case
	cp	'z'+1
	jr	nc,.case
	sub	32
.case:
	or	b
	ld	(hl),a
	inc	hl
	ld	(hl),c
	inc	hl
	ld	(hl),e
	ld	a,(word_len)
	inc	a
	ld	(word_len),a
	ld	b,a
	ld	a,(wr_width)
	cp	b
	call	c,wr_overflow		; longer than a line: it can never fit
.done:
	pop	hl
	ret
.space:
	call	place_word
	ld	hl,(pend_cnt)
	inc	hl
	ld	(pend_cnt),hl
	ld	de,WIDTH+1
	or	a
	sbc	hl,de
	jr	nc,.done		; only the first 32 are ever shown
	ld	a,(pend_cnt)
	dec	a
	call	cells_at
	ld	de,pend_cells
	add	hl,de
	push	hl
	call	cell_style		; (uses HL)
	pop	hl
	ld	(hl),' '
	inc	hl
	ld	(hl),c
	inc	hl
	ld	(hl),e
	jr	.done
.brk:
	call	place_word
	call	wr_flush		; the line, with what fits of the spaces
	jr	.done
.mute:					; counting a label (forms.asm): its length,
	push	af			; and its first CAP_MAX characters in case
	ld	hl,(mt_len)
	inc	hl
	ld	(mt_len),hl
	ld	a,h
	or	a
	jr	nz,.mend
	ld	a,l
	cp	CAP_MAX+1
	jr	nc,.mend
	push	hl
	call	cell_style		; D = upper case
	pop	hl
	pop	af
	push	af
	inc	d
	dec	d
	jr	z,.mc
	cp	'a'
	jr	c,.mc
	cp	'z'+1
	jr	nc,.mc
	sub	32
.mc:
	cp	BRK
	jr	nz,.mk
	ld	a,' '
.mk:
	ld	de,cap_buf-1
	add	hl,de
	ld	(hl),a
.mend:
	pop	af
	pop	hl
	ret

; cells_at: HL = A * CELL.
cells_at:
	ld	l,a
	ld	h,0
	ld	d,h
	ld	e,l
	add	hl,hl
	add	hl,de
	ret

; wr_end: the end of the block.
wr_end:
	call	place_word
	ld	a,(cur_len)
	ld	hl,(pend_cnt)
	or	h
	or	l
	call	nz,wr_flush
	ld	hl,(lines_out)
	ld	a,h
	or	l
	ret	nz
	xor	a			; an empty block is one empty row
	ld	hl,cur_cells
	jp	out_line

; wr_flush: cur + as many pending spaces as fit -> a line; then empty.
wr_flush:
	ld	a,(cur_len)
	ld	b,a
	ld	a,(wr_width)
	sub	b			; room left
	ld	hl,(pend_cnt)
	ld	c,a
	ld	a,h
	or	a
	jr	nz,.room		; lots of spaces: the room is the limit
	ld	a,l
	cp	c
	jr	c,.n
.room:
	ld	a,c
.n:
	ld	hl,pend_cells
	call	cur_append
	ld	hl,cur_cells
	ld	a,(cur_len)
	call	out_line
	xor	a
	ld	(cur_len),a
	ld	hl,0
	ld	(pend_cnt),hl
	ret

; wr_overflow: the word is one longer than a line: the line so far goes,
; then the word's first wr_width characters; one character stays.
wr_overflow:
	ld	a,(cur_len)
	ld	hl,(pend_cnt)
	or	h
	or	l
	jr	z,.nocur
	ld	hl,cur_cells
	ld	a,(cur_len)
	call	out_line
	xor	a
	ld	(cur_len),a
	ld	hl,0
	ld	(pend_cnt),hl
.nocur:
	ld	hl,word_cells
	ld	a,(wr_width)
	call	out_line
	ld	a,(wr_width)
	call	cells_at
	ld	de,word_cells
	add	hl,de
	ld	bc,CELL
	ldir
	ld	a,1
	ld	(word_len),a
	ret

; place_word: the word goes on the line if it fits with the spaces before
; it; otherwise the line goes out and the word starts the next one.
place_word:
	ld	a,(word_len)
	or	a
	ret	z
	ld	hl,(pend_cnt)
	ld	e,a
	ld	d,0
	add	hl,de
	ld	a,(cur_len)
	ld	e,a
	add	hl,de			; cur + pending + word
	ex	de,hl
	ld	a,(wr_width)
	ld	l,a
	ld	h,0
	or	a
	sbc	hl,de
	jr	c,.nofit
	ld	a,(pend_cnt)		; fits: then the spaces are at most 32
	ld	hl,pend_cells
	call	cur_append
	jr	.word
.nofit:
	ld	a,(cur_len)
	ld	hl,(pend_cnt)
	or	h
	or	l
	jr	z,.empty
	ld	hl,cur_cells
	ld	a,(cur_len)
	call	out_line
.empty:
	xor	a
	ld	(cur_len),a
.word:
	ld	hl,word_cells
	ld	a,(word_len)
	call	cur_append
	xor	a
	ld	(word_len),a
	ld	hl,0
	ld	(pend_cnt),hl
	ret

; cur_append: A cells from HL onto the end of cur.
cur_append:
	or	a
	ret	z
	push	af
	push	hl
	call	cells_at		; HL = the bytes to copy
	push	hl
	ld	a,(cur_len)
	call	cells_at
	ld	de,cur_cells
	add	hl,de
	ex	de,hl
	pop	bc
	pop	hl
	ldir
	pop	af
	ld	b,a
	ld	a,(cur_len)
	add	a,b
	ld	(cur_len),a
	ret

; out_line: a wrapped line of A cells at HL becomes a row: the list
; marker or the indent, the centring, then the line.
out_line:
	ld	(ol_src),hl
	ld	(ol_len),a
	ld	de,rowbuf
	xor	a
	ld	(ol_cells),a
	ld	a,(bk_indent)
	or	a
	jr	z,.centre
	ld	b,a
	ld	hl,(lines_out)
	ld	a,h
	or	l
	jr	nz,.indent		; not the first line
	ld	a,(bk_mlen)
	or	a
	jr	z,.indent		; a quote: no marker
	ld	b,a
	ld	hl,bk_marker
.mk:
	ld	a,(hl)
	inc	hl
	call	put_plain
	djnz	.mk
	ld	b,1			; and a space
.indent:
	ld	a,' '
	call	put_plain
	djnz	.indent
.centre:
	ld	a,(bk_center)
	or	a
	jr	z,.body
	ld	a,(ol_len)
	ld	b,a
	ld	a,(wr_width)
	sub	b
	srl	a
	jr	z,.body
	ld	b,a
.cs:
	ld	a,' '
	call	put_plain
	djnz	.cs
.body:
	ld	a,(ol_len)
	or	a
	jr	z,.emit
	push	de
	call	cells_at
	ld	b,h
	ld	c,l
	pop	de
	ld	hl,(ol_src)
	ldir
	ld	hl,ol_cells
	ld	a,(ol_len)
	add	a,(hl)
	ld	(hl),a
.emit:
	ld	hl,(lines_out)
	inc	hl
	ld	(lines_out),hl
	ld	a,(ol_cells)
	jp	row_emit

; put_plain: a cell with character A in the text colour, no link, at DE.
; Keeps HL and B.
put_plain:
	push	hl
	ld	(de),a
	inc	de
	ld	a,(att_plain)
	ld	(de),a
	inc	de
	xor	a
	ld	(de),a
	inc	de
	ld	hl,ol_cells
	inc	(hl)
	pop	hl
	ret

; =============================================================================
; Characters

; to_case: the page's case (upper unless "case: mixed").
to_case:
	push	af
	ld	a,(upper)
	or	a
	jr	z,.keep
	pop	af
	cp	'a'
	ret	c
	cp	'z'+1
	ret	nc
	sub	32
	ret
.keep:
	pop	af
	ret

; to_lower: A in lower case (letters only).
to_lower:
	cp	'A'
	ret	c
	cp	'Z'+1
	ret	nc
	add	a,32
	ret

	include	"style.asm"
	include	"forms.asm"

; =============================================================================
; Words and tables

s_dashes:	db	"---"
s_pre:		db	"```"
s_fence:	db	":::"
w_8tml:		db	"8tml",0
w_title:	db	"title",0
w_case:		db	"case",0
w_style:	db	"style",0
w_mixed:	db	"mixed",0
w_form:		db	"form",0
w_center:	db	"<center>",0

; [name 0][character], then a 0
entities:
		db	"lt",0,'<', "gt",0,'>', "amp",0,'&', "quot",0,'"', "nbsp",0,NBSP
		db	0

; [kind][value]["name" 0]: kind 1 colour (value: ZX ink + BRIGHT, the
; hand-tuned table of CLAUDE.md 6.6), 2 b/i/rev (1/2/3), 3 center, 4 br
tag_names:
		db	1,0x00,"black",0, 1,0x47,"white",0, 1,0x02,"red",0
		db	1,0x05,"cyan",0, 1,0x03,"purple",0, 1,0x04,"green",0
		db	1,0x01,"blue",0, 1,0x46,"yellow",0, 1,0x06,"orange",0
		db	1,0x02,"brown",0, 1,0x42,"pink",0, 1,0x07,"darkgrey",0
		db	1,0x07,"grey",0, 1,0x44,"lightgreen",0, 1,0x45,"lightblue",0
		db	1,0x07,"lightgrey",0
		db	1,0x03,"magenta",0, 1,0x42,"lightred",0, 1,0x07,"gray",0
		db	1,0x07,"darkgray",0, 1,0x07,"lightgray",0
		db	2,1,"b",0, 2,2,"i",0, 2,3,"rev",0
		db	3,0,"center",0
		db	4,0,"br",0
		db	0

; =============================================================================
; Variables (the big buffers are the program's, after its loaded code)

is_page:	db	0
upper:		db	1
newer:		db	0
has_form:	db	0
body_ptr:	dw	0
hd_first:	db	0
hd_s:		dw	0
hd_k:		dw	0
hd_klen:	db	0
hd_v:		dw	0
hd_vlen:	db	0
hd_style	equ	input			; the header's style: value, 0-terminated
hd_stylelen:	db	0

src_ptr:	dw	0
line_start:	dw	0
line_len:	db	0
st_len:		db	0
k_kind:		db	0
k_ls:		dw	0
k_text:		dw	0
k_level:	db	0
k_num:		dw	0
k_numlen:	db	0
k_indent2:	db	0

st_flags:	db	0			; the parser's state at a block:
st_num:		ds	NUM_MAX+1		;   flags, last list number,
st_links:	dw	0			;   links so far (STATE_SIZE)
bs_src:		dw	0			; ... saved at the block's start
bs_flags:	db	0
bs_num:		ds	NUM_MAX+1
bs_links:	dw	0
num_prev:	ds	NUM_MAX+1
blk_rows:	dw	0

mode:		db	0
lk_total:	dw	0			; links on the page
lk_cur:		dw	0			; the link being read
found:		db	0
base_links:	dw	0			; links before the drawn screen's first block
run_n:		db	0			; link runs on the screen
run_last:	dw	0
re_col:		db	0
re_prev:	db	0
re_id:		db	0
re_ptr:		dw	0
pc_attr:	db	0
pc_ital:	db	0
ol_cells:	db	0
tag_val:	db	0
too_long:	db	0
screens:	dw	0
scr_rowcnt:	db	0
skip:		dw	0
dr_row:		db	0
render_sp:	dw	0
row_len:	db	0
pl_left:	db	0
pl_n:		db	0
pl_p:		dw	0

bk_col:		db	0			; the role's colour and words
bk_flags:	db	0
cs_col:		db	0			; cell_style's working colour and words
cs_flags:	db	0
sel_link:	dw	0xFFFF			; the focused link, drawn link-sel
bk_indent:	db	0
bk_center:	db	0
bk_mlen:	db	0
bk_marker:	ds	NUM_MAX+2

pr_ptr:		dw	0
pr_end:		dw	0
pr_hard:	db	0
pr_eof:		db	0
pr_head:	db	0
pr_kind:	db	0
stop_ptr:	dw	0
hist:		ds	4

in_p:		dw	0
win_end:	dw	0
in_outer:	db	0
in_em:		db	0			; inline state (6 bytes, in order)
in_strong:	db	0
in_b:		db	0			; b i rev: tag values 1 2 3
in_i:		db	0
in_rev:		db	0
in_color:	db	0xFF			; 0xFF: none
in_link:	db	0
in_prev:	db	0
tok_end:	dw	0
st_w:		db	0
st_nxt:		db	0
lk_llen:	db	0
lk_url:		dw	0

wr_width:	db	0
cur_len:	db	0
word_len:	db	0
pend_cnt:	dw	0
lines_out:	dw	0
ol_src:		dw	0
ol_len:		db	0
