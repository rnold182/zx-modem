; net.asm - Z80 side of the tape-port modem link (docs/link-protocol.md).
;
; A request is one tape block saved with flag 0x80; a response is one or more
; pairs of a 10-byte header block (0x90) and a data block (0x91), loaded with
; the ROM's own LD-BYTES. Knows nothing about what the bytes mean.
;
; The ROM routines are entered just after they push SA/LD-RET, the exit that
; turns SPACE into the BASIC error "D BREAK - CONT repeats". We push our own
; exit instead (link_tape_ret), so SPACE becomes an error code and the calling
; program keeps running. Addresses checked against the 48K ROM disassembly.

ROM_SA_BYTES_NORET	equ	0x04C6	; SA-BYTES after PUSH SA/LD-RET: A flag, IX, DE
ROM_LD_BYTES_NORET	equ	0x0562	; LD-BYTES after PUSH SA/LD-RET: set up as at 0556
LINK_BORDCR		equ	23624	; system variable: border colour * 8

LINK_ERR_HEADER		equ	1	; tape error in a header block
LINK_ERR_BREAK		equ	2	; SPACE pressed
LINK_ERR_TOO_LONG	equ	3	; response longer than the buffer
LINK_ERR_DATA		equ	4	; tape error in a data block

; The including program defines link_header: ds 10 (the last response
; header; the menu keeps it at a fixed address for apps).

link_rx_ptr:	dw	0
link_rx_left:	dw	0
link_rx_count:	dw	0

; link_request: save the request at HL, BC bytes long, as one block.
link_request:
	push	hl
	pop	ix
	ld	d,b
	ld	e,c
	ld	a,0x80
	ld	hl,link_tape_ret
	push	hl
	jp	ROM_SA_BYTES_NORET

; link_load_block: load DE bytes to IX, expecting flag A. Carry set = OK.
link_load_block:
	scf				; carry set = LOAD, not VERIFY
	inc	d			; the same set-up LD-BYTES does at 0556
	ex	af,af'
	dec	d
	di
	ld	a,0x0F			; border white, MIC off
	out	(0xFE),a
	ld	hl,link_tape_ret
	push	hl
	jp	ROM_LD_BYTES_NORET

; Shared exit of both ROM routines: what SA/LD-RET does, minus the BREAK error.
link_tape_ret:
	push	af			; keep the ROM's carry flag
	ld	a,(LINK_BORDCR)
	and	0x38
	rrca
	rrca
	rrca
	out	(0xFE),a
	pop	af
	ei
	ret

; link_receive: load a response into IX, at most DE bytes.
; Out: carry set, A = response type, BC = bytes received; or carry clear,
; A = LINK_ERR_*.
link_receive:
	ld	(link_rx_ptr),ix
	ld	(link_rx_left),de
	ld	hl,0
	ld	(link_rx_count),hl
.next:
	ld	ix,link_header
	ld	de,10
	ld	a,0x90
	call	link_load_block
	ld	b,LINK_ERR_HEADER
	jr	nc,.fail
	ld	de,(link_header+2)	; chunk_len
	ld	a,d
	or	e
	jr	z,.chunk_done
	ld	hl,(link_rx_left)
	or	a
	sbc	hl,de
	ld	b,LINK_ERR_TOO_LONG
	jr	c,.fail
	ld	(link_rx_left),hl
	ld	ix,(link_rx_ptr)
	push	de
	ld	a,0x91
	call	link_load_block
	pop	de
	ld	b,LINK_ERR_DATA
	jr	nc,.fail
	ld	hl,(link_rx_ptr)
	add	hl,de
	ld	(link_rx_ptr),hl
	ld	hl,(link_rx_count)
	add	hl,de
	ld	(link_rx_count),hl
.chunk_done:
	ld	a,(link_header+1)	; bit 0: final chunk
	rra
	jr	nc,.next
	ld	bc,(link_rx_count)
	ld	a,(link_header)
	scf
	ret
.fail:
	ld	a,0x7F			; SPACE still held? Then it was a BREAK.
	in	a,(0xFE)
	rra
	ld	a,b
	jr	c,.code
	ld	a,LINK_ERR_BREAK
.code:
	or	a			; carry clear = error
	ret
