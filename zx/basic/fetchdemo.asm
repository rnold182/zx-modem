; fetchdemo - M2c: a BASIC program that fetches a web page through the modem.
;
; Build: sjasmplus zx/basic/fetchdemo.asm -> fetchdemo.tap (auto-runs)
; Needs the ZX MODEM menu in memory: load it, choose 5 BASIC, then load
; this or type it in:
;
;   10 IF PEEK 32771<>195 THEN PRINT "Load the ZX MODEM menu first": STOP
;   20 LET U$="http://wttr.in/Budapest?format=%l:+%C+%t"
;   30 PRINT "Fetching ";U$
;   40 LET N=USR 32771
;   50 IF PEEK 32777<>0 THEN PRINT "Error ";PEEK 32777;": ";
;   60 RANDOMIZE USR 32774
;   70 PRINT "HTTP ";PEEK 32778+256*PEEK 32779;", ";N;" bytes"
;
; (Line 10 checks for the JP at 32771, i.e. that the menu's entry table is
; there.) Change U$ to fetch something else.

	DEVICE ZXSPECTRUM48

T_STOP		equ	0xE2
T_LET		equ	0xF1
T_PRINT		equ	0xF5
T_IF		equ	0xFA
T_THEN		equ	0xCB
T_PEEK		equ	0xBE
T_USR		equ	0xC0
T_RANDOMIZE	equ	0xF9
T_NE		equ	0xC9		; <>

; A number literal: its digits, then 0x0E and the 5-byte integer form.
	MACRO	NUM digits, value
	db	digits,0x0E,0,0
	dw	value
	db	0
	ENDM

; Each line: number (big-endian), length of the rest (little-endian), body, ENTER.

	org	0xC000
prog:

l10:	db	0,10
	dw	.e - .b
.b:	db	T_IF,T_PEEK
	NUM	"32771",32771
	db	T_NE
	NUM	"195",195
	db	T_THEN,T_PRINT,'"Load the ZX MODEM menu first"',':',T_STOP,0x0D
.e:

l20:	db	0,20
	dw	.e - .b
.b:	db	T_LET,"U$=",'"http://wttr.in/Budapest?format=%l:+%C+%t"',0x0D
.e:

l30:	db	0,30
	dw	.e - .b
.b:	db	T_PRINT,'"Fetching "',';',"U$",0x0D
.e:

l40:	db	0,40
	dw	.e - .b
.b:	db	T_LET,"N=",T_USR
	NUM	"32771",32771
	db	0x0D
.e:

l50:	db	0,50
	dw	.e - .b
.b:	db	T_IF,T_PEEK
	NUM	"32777",32777
	db	T_NE
	NUM	"0",0
	db	T_THEN,T_PRINT,'"Error "',';',T_PEEK
	NUM	"32777",32777
	db	';','": "',';',0x0D
.e:

l60:	db	0,60
	dw	.e - .b
.b:	db	T_RANDOMIZE,T_USR
	NUM	"32774",32774
	db	0x0D
.e:

l70:	db	0,70
	dw	.e - .b
.b:	db	T_PRINT,'"HTTP "',';',T_PEEK
	NUM	"32778",32778
	db	'+'
	NUM	"256",256
	db	'*',T_PEEK
	NUM	"32779",32779
	db	';','", "',';',"N",';','" bytes"',0x0D
.e:

prog_end:

	EMPTYTAP "fetchdemo.tap"
	SAVETAP  "fetchdemo.tap", BASIC, "fetchdemo", prog, prog_end - prog, 10
