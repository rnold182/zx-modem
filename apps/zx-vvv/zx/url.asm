; url.asm - zx-vvv's address rules: resolve a link against the page address.
;
; The Z80 twin of apps/zx-vvv/host/url.c (the readable model, with the rules
; spelled out); both are checked against host/url_cases.txt. The Spectrum
; resolves every link itself and sends the modem only absolute addresses.
;
; url_resolve: HL = base (the page's address; "" = the reader typed ref),
;              DE = ref, both 0-terminated, each up to 255 characters.
; Out: A = URL_OK (url_out holds the address), URL_SAME, URL_NOFOLLOW or
;      URL_LONG. IX, IY kept. The program defines url_tmp and url_out (below).

URL_OK		equ	0		; url_out = the absolute address
URL_SAME	equ	1		; fragment only: the current page
URL_NOFOLLOW	equ	2		; not http/https
URL_LONG	equ	3		; over URL_MAX
URL_MAX		equ	255

url_resolve:
	ld	(u_base),hl
	ld	(u_ref),de
	ld	a,(hl)
	or	a
	jr	nz,.based
	; 1. typed: "http://" in front unless it has a scheme
	ld	de,url_tmp
	ld	hl,(u_ref)
	call	has_scheme_sep
	jr	z,.typed
	ld	hl,s_http
	call	u_strcpy
.typed:
	ld	hl,(u_ref)
	call	u_strcpy
	ld	hl,url_tmp
	ld	(u_base),hl
	ld	(u_ref),hl
.based:
	; 2. the fragment: rl = length up to '#'
	ld	hl,(u_ref)
	ld	bc,0
.rl:
	ld	a,(hl)
	or	a
	jr	z,.rl_end
	cp	'#'
	jr	z,.rl_end
	inc	hl
	inc	bc
	jr	.rl
.rl_end:
	ld	(u_rl),bc
	ld	a,b
	or	c
	ld	a,URL_SAME
	ret	z
	; 3. resolve into url_out
	ld	de,url_out
	ld	hl,(u_ref)
	call	scheme_len
	or	a
	jp	nz,.copy_ref		; absolute
	ld	a,(hl)
	cp	'/'
	jr	nz,.not_slash
	inc	hl
	ld	a,(hl)
	cp	'/'
	jr	nz,.abs_path
	; network path: the base's scheme, then ref
	ld	hl,(u_base)
	call	scheme_len
	ld	c,a
	ld	b,0
	jr	.base_bc
.abs_path:					; the base up to its path, then ref
	ld	hl,(u_base)
	call	auth_end
	jr	.base_to_hl
.not_slash:
	cp	'?'
	jr	nz,.merge
	ld	hl,(u_base)			; the base up to its query, then ref
.q:
	ld	a,(hl)
	or	a
	jr	z,.base_to_hl
	cp	'?'
	jr	z,.base_to_hl
	cp	'#'
	jr	z,.base_to_hl
	inc	hl
	jr	.q
.merge:						; the base's directory, then ref
	ld	hl,(u_base)
	call	auth_end
	ld	(u_auth),hl
	ld	(u_dir),hl
.m:
	ld	a,(hl)
	or	a
	jr	z,.m_end
	cp	'?'
	jr	z,.m_end
	cp	'#'
	jr	z,.m_end
	inc	hl
	cp	'/'
	jr	nz,.m
	ld	(u_dir),hl			; just after the last '/'
	jr	.m
.m_end:
	ld	hl,(u_dir)
	ld	de,(u_auth)
	or	a
	sbc	hl,de
	ld	de,url_out
	jr	nz,.dir				; the base has a path
	ld	hl,(u_auth)			; no path: the root
	call	.base_to_hl_de
	ld	a,'/'
	ld	(de),a
	inc	de
	jr	.copy_ref
.dir:
	ld	hl,(u_dir)
.base_to_hl:
	ld	de,url_out
	call	.base_to_hl_de
	jr	.copy_ref
.base_bc:					; BC bytes of the base
	ld	de,url_out
	ld	hl,(u_base)
	call	u_copy_bc
.copy_ref:					; rl bytes of ref, then 0
	ld	hl,(u_ref)
	ld	bc,(u_rl)
	call	u_copy_bc
	xor	a
	ld	(de),a
	; the path starts with '/' ("http://h" -> "http://h/")
	ld	hl,url_out
	call	auth_end
	ld	a,(hl)
	cp	'/'
	jr	z,.dots
	push	hl
	ld	bc,1
	call	make_room
	pop	hl
	ld	(hl),'/'
.dots:
	push	hl
	call	remove_dots
	; 4. only http and https
	ld	hl,url_out
	ld	de,s_http
	call	prefix_nocase
	jr	z,.ok_scheme
	ld	hl,url_out
	ld	de,s_https
	call	prefix_nocase
	jr	z,.ok_scheme
	pop	hl
	ld	a,URL_NOFOLLOW
	ret
.ok_scheme:
	; 5. an empty path or one ending in '/' -> index.8tml
	pop	hl				; the path
.p:
	ld	a,(hl)
	or	a
	jr	z,.p_end
	cp	'?'
	jr	z,.p_end
	inc	hl
	jr	.p
.p_end:
	dec	hl
	ld	a,(hl)
	inc	hl
	cp	'/'
	jr	nz,.len
	push	hl
	ld	bc,10
	call	make_room
	pop	de
	ld	hl,s_index
	ld	bc,10
	ldir
.len:
	ld	hl,url_out
	call	u_strlen
	ld	hl,URL_MAX
	or	a
	sbc	hl,bc
	ld	a,URL_LONG
	ret	c
	xor	a				; URL_OK
	ret

; The base from its start up to HL (exclusive) to DE.
.base_to_hl_de:
	ld	bc,(u_base)
	or	a
	sbc	hl,bc
	ld	b,h
	ld	c,l
	ld	hl,(u_base)
	; fall through

; u_copy_bc: BC bytes from HL to DE (none if BC = 0).
u_copy_bc:
	ld	a,b
	or	c
	ret	z
	ldir
	ret

; u_strcpy: the string at HL to DE, with its 0; DE ends on the 0.
u_strcpy:
	ld	a,(hl)
	ld	(de),a
	or	a
	ret	z
	inc	hl
	inc	de
	jr	u_strcpy

; u_strlen: BC = length of the string at HL; HL ends on the 0.
u_strlen:
	ld	bc,0
.l:
	ld	a,(hl)
	or	a
	ret	z
	inc	hl
	inc	bc
	jr	.l

; scheme_len: A = length of the scheme at HL with its ':', or 0. Keeps HL.
; A letter, then letters, digits, '+', '-', '.', then ':'.
scheme_len:
	push	hl
	ld	a,(hl)
	call	is_alpha
	jr	nc,.none
	ld	b,0
.l:
	ld	a,(hl)
	cp	':'
	jr	z,.colon
	call	is_alpha
	jr	c,.next
	cp	'0'
	jr	c,.sym
	cp	'9'+1
	jr	c,.next
.sym:
	cp	'+'
	jr	z,.next
	cp	'-'
	jr	z,.next
	cp	'.'
	jr	nz,.none
.next:
	inc	hl
	inc	b
	jr	nz,.l
.none:
	pop	hl
	xor	a
	ret
.colon:
	pop	hl
	ld	a,b
	inc	a
	ret

; is_alpha: carry set if A is a letter. Keeps A.
is_alpha:
	push	af
	or	0x20
	cp	'a'
	jr	c,.no
	cp	'z'+1
	jr	nc,.no
	pop	af
	scf
	ret
.no:
	pop	af
	or	a
	ret

; auth_end: HL = string -> HL = the end of its authority: after
; "scheme://", the first '/', '?' or 0. Without "//", just after the scheme.
auth_end:
	call	scheme_len
	ld	e,a
	ld	d,0
	add	hl,de
	ld	a,(hl)
	cp	'/'
	ret	nz
	inc	hl
	ld	a,(hl)
	dec	hl
	cp	'/'
	ret	nz
	inc	hl
.l:
	inc	hl
	ld	a,(hl)
	or	a
	ret	z
	cp	'/'
	ret	z
	cp	'?'
	ret	z
	jr	.l

; has_scheme_sep: Z if the string at HL contains "://".
has_scheme_sep:
	ld	a,(hl)
	or	a
	jr	z,.no
	inc	hl
	cp	':'
	jr	nz,has_scheme_sep
	ld	a,(hl)
	cp	'/'
	jr	nz,has_scheme_sep
	inc	hl
	ld	a,(hl)
	dec	hl
	cp	'/'
	jr	nz,has_scheme_sep
	ret				; Z
.no:
	inc	a			; NZ
	ret

; prefix_nocase: Z if the string at HL starts with the lower-case text at DE
; (letters compared without case; the other characters here are unaffected
; by OR 0x20: ':' and '/').
prefix_nocase:
	ld	a,(de)
	or	a
	ret	z
	ld	a,(hl)
	or	0x20
	ex	de,hl
	cp	(hl)
	ex	de,hl
	ret	nz
	inc	hl
	inc	de
	jr	prefix_nocase

; make_room: move the string from HL (to its 0) up by BC bytes.
make_room:
	push	bc
	push	hl
	call	u_strlen		; HL on the 0, BC = bytes before it
	inc	bc			; and the 0
	pop	de
	pop	de			; DE = the gap
	push	bc
	ld	b,h			; HL = the last byte to move
	ld	c,l
	ex	de,hl
	add	hl,bc
	ex	de,hl			; DE = HL + gap
	pop	bc
	lddr
	ret

; remove_dots: RFC 3986 5.2.4 on the path at HL (starts with '/', ends at
; '?' or 0), in place; the query moves down after it. The output (DE) never
; passes the input (HL), so copying forward in place is safe.
remove_dots:
	ld	(rd_start),hl
	ld	d,h
	ld	e,l
	xor	a
	ld	(rd_trail),a
.seg:
	ld	a,(hl)
	cp	'/'
	jr	nz,.end
	inc	hl			; the segment
	push	hl
	ld	bc,0
.m:
	ld	a,(hl)
	or	a
	jr	z,.m_end
	cp	'/'
	jr	z,.m_end
	cp	'?'
	jr	z,.m_end
	inc	hl
	inc	bc
	jr	.m
.m_end:
	pop	hl
	ld	a,b
	or	a
	jr	nz,.normal
	ld	a,(hl)
	cp	'.'
	jr	nz,.normal
	ld	a,c
	dec	a
	jr	z,.dot			; "."
	dec	a
	jr	nz,.normal
	inc	hl
	ld	a,(hl)
	dec	hl
	cp	'.'
	jr	nz,.normal
	inc	hl			; "..": drop the last output segment
	inc	hl
	push	hl
	ex	de,hl			; HL = output end
.back:
	ld	de,(rd_start)
	or	a
	sbc	hl,de
	add	hl,de
	jr	z,.back_done
	dec	hl
	ld	a,(hl)
	cp	'/'
	jr	nz,.back
.back_done:
	ex	de,hl
	pop	hl
	jr	.trail
.dot:
	inc	hl
.trail:
	ld	a,1
	ld	(rd_trail),a
	jr	.seg
.normal:
	ld	a,'/'
	ld	(de),a
	inc	de
	call	u_copy_bc
	xor	a
	ld	(rd_trail),a
	jr	.seg
.end:
	ld	a,(rd_trail)
	or	a
	jr	nz,.slash
	push	hl
	ld	hl,(rd_start)
	or	a
	sbc	hl,de
	pop	hl
	jr	nz,.query
.slash:
	ld	a,'/'
	ld	(de),a
	inc	de
.query:
	jp	u_strcpy

s_http:		db	"http://",0
s_https:	db	"https://",0
s_index:	db	"index.8tml"

u_base:		dw	0
u_ref:		dw	0
u_rl:		dw	0
u_auth:		dw	0
u_dir:		dw	0
rd_start:	dw	0
rd_trail:	db	0

; The program provides the buffers (they needn't be loaded from tape):
;   url_tmp: ds URL_TMP_SIZE   a typed address with "http://"
;   url_out: ds URL_OUT_SIZE   the result (checked against URL_MAX at the end)
URL_TMP_SIZE	equ	8+URL_MAX+1
URL_OUT_SIZE	equ	2*URL_MAX+16
