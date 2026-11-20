; basic.asm - the modem for BASIC programs (USR entry points, docs/link-protocol.md 7.3).
;
;   LET U$="http://..."        the address to fetch
;   LET n=USR basic_fetch      fetch it; n = bytes received into BASIC_BUF
;   RANDOMIZE USR basic_print  print them (LF = new line, CR dropped)
;   PEEK basic_status          0 OK, 1 modem error (message in BASIC_BUF),
;                              2 SPACE pressed, 3 no reply, 4 no usable U$
;   PEEK basic_http + 256*PEEK (basic_http+1)   HTTP status
;
; The program that includes this puts a jump table at a fixed address (the
; menu: 32771 fetch, 32774 print, 32777 status, 32778 HTTP status, 32780
; length), and defines basic_status, basic_http and basic_len there.
; IY and the alternate HL are left alone, as BASIC needs.

VARS		equ	23627		; system variable: start of the variables
CHAN_OPEN	equ	0x1601		; ROM: open channel for stream A
BASIC_BUF	equ	0xC000		; reply buffer, up to the UDGs at 0xFF58
BASIC_BUF_MAX	equ	16000

BASIC_OK	equ	0
BASIC_ERR_MODEM	equ	1
BASIC_ERR_BREAK	equ	2
BASIC_ERR_LINK	equ	3
BASIC_ERR_NO_U	equ	4

; basic_fetch: GET the address in U$ through the modem's basic service
; (0x03 'F' [max:2] url). Returns BC = bytes in BASIC_BUF.
basic_fetch:
	ld	hl,0
	ld	(basic_len),hl
	ld	(basic_http),hl
	call	find_u_string		; HL = text, DE = length
	ld	a,BASIC_ERR_NO_U
	jr	nc,.done
	ld	a,d			; 1-255 characters
	or	a
	ld	a,BASIC_ERR_NO_U
	jr	nz,.done
	ld	a,e
	or	a
	ld	a,BASIC_ERR_NO_U
	jr	z,.done
	push	hl
	ld	hl,basic_req		; request: 03 'F' max url
	ld	(hl),0x03
	inc	hl
	ld	(hl),'F'
	inc	hl
	ld	(hl),low BASIC_BUF_MAX
	inc	hl
	ld	(hl),high BASIC_BUF_MAX
	ld	b,d			; BC = length
	ld	c,e
	pop	hl			; HL = text
	push	bc
	ld	de,basic_req+4
	ldir
	pop	hl
	ld	bc,4
	add	hl,bc
	ld	b,h
	ld	c,l
	ld	hl,basic_req
	call	link_request
	ld	ix,BASIC_BUF
	ld	de,BASIC_BUF_MAX
	call	link_receive
	jr	nc,.link_error
	ld	(basic_len),bc
	ld	hl,(link_header+8)
	ld	(basic_http),hl
	or	a			; type 0: the body
	ld	a,BASIC_OK
	jr	z,.done
	ld	a,(link_header)
	cp	1			; error: the message is in the buffer
	ld	a,BASIC_ERR_MODEM
	jr	z,.done
	ld	a,BASIC_ERR_LINK
	jr	.done
.link_error:
	cp	LINK_ERR_BREAK
	ld	a,BASIC_ERR_BREAK
	jr	z,.done
	ld	a,BASIC_ERR_LINK
.done:
	ld	(basic_status),a
	ld	bc,(basic_len)
	ret

; find_u_string: find U$ in the BASIC variables. Carry set: HL = its text,
; DE = its length.
find_u_string:
	ld	hl,(VARS)
.next:
	ld	a,(hl)
	cp	0x80			; end of the variables
	jr	z,.none
	ld	c,a
	and	0xE0
	cp	0x40			; 010xxxxx: string
	jr	z,.string
	cp	0x60			; 011xxxxx: number, one-letter name
	ld	de,6
	jr	z,.skip
	cp	0xE0			; 111xxxxx: FOR control variable
	ld	de,19
	jr	z,.skip
	cp	0xA0			; 101xxxxx: number, longer name
	jr	z,.long
	inc	hl			; arrays: name, length, contents
	ld	e,(hl)
	inc	hl
	ld	d,(hl)
	inc	hl
.skip:
	add	hl,de
	jr	.next
.long:
	inc	hl			; the name ends with bit 7 set
.letter:
	ld	a,(hl)
	inc	hl
	bit	7,a
	jr	z,.letter
	ld	de,5
	jr	.skip
.string:
	inc	hl
	ld	e,(hl)
	inc	hl
	ld	d,(hl)
	inc	hl
	ld	a,c
	cp	0x40+('u'&0x1F)		; U$
	jr	nz,.skip
	scf
	ret
.none:
	or	a
	ret

; basic_print: print the bytes from the last fetch on the upper screen.
basic_print:
	ld	a,2
	call	CHAN_OPEN
	ld	hl,BASIC_BUF
	ld	bc,(basic_len)
	ld	e,13			; last character printed
.loop:
	ld	a,b
	or	c
	jr	z,.end
	ld	a,(hl)
	inc	hl
	dec	bc
	cp	13			; CR: dropped (CR LF = one new line)
	jr	z,.loop
	cp	10
	jr	nz,.tab
	ld	a,13			; LF -> ENTER
	jr	.out
.tab:
	cp	9
	jr	nz,.text
	ld	a,' '
.text:
	cp	32			; other controls: skipped
	jr	c,.loop
	cp	128
	jr	c,.out
	ld	a,'?'
.out:
	ld	e,a
	push	hl
	push	bc
	push	de
	rst	16
	pop	de
	pop	bc
	pop	hl
	jr	.loop
.end:
	ld	a,e			; end on a new line
	cp	13
	ret	z
	ld	a,13
	rst	16
	ret
