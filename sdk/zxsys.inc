; zxsys.inc - 48K ROM entry points and system variables used by our programs.

LAST_K		equ	23560		; last key pressed (ROM keyboard scan)
FLAGS		equ	23611		; bit 5: a new key is in LAST_K
FLAGS2		equ	23658		; bit 3: caps lock
FRAMES		equ	23672		; 50 Hz counter (low byte used)
ROM_CLS		equ	0x0D6B

; Key codes the ROM puts in LAST_K
K_TRUE_VIDEO	equ	4		; CAPS+3
K_INV_VIDEO	equ	5		; CAPS+4
K_CAPS_LOCK	equ	6		; CAPS+2
K_EDIT		equ	7		; CAPS+1
K_LEFT		equ	8		; CAPS+5
K_DOWN		equ	10		; CAPS+6
K_UP		equ	11		; CAPS+7
K_DELETE	equ	12		; CAPS+0
K_ENTER		equ	13
