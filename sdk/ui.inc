; ui.inc - colours and glyphs shared by the menu and its overlays.

; Attributes: FLASH BRIGHT PAPER(3) INK(3)
A_BODY		equ	0x07		; white on black
A_TITLE		equ	0x47		; bright white on black
A_ITEM		equ	0x47
A_SEL		equ	0x68		; black on bright cyan
A_HINT		equ	0x05		; cyan on black
A_MSG		equ	0x46		; bright yellow on black
A_ERR		equ	0x42		; bright red on black
A_OK		equ	0x44		; bright green on black
A_FIELD		equ	0x4F		; bright white on blue (text entry)
A_STATUS	equ	0x4F		; bright white on blue
A_BAR_OFF	equ	0x48		; black on bright blue (status line)

; Custom glyphs (scr_glyphs in the menu)
G_DIAG		equ	1		; title stripes
G_BAR1		equ	2		; signal bars, rising height: G_BAR1 + 0..3
G_LOCK		equ	6		; padlock
G_CHECK		equ	7		; tick: connected
G_DOT		equ	8		; dot: saved

