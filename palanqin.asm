; Palanquin -- Cortex-M0 emulator for 8086
; Copyright (c) 2020 Robert Clausecker <fuz@fuz.su>

	cpu	8086		; restrict nasm to 8086 instructions

	section	.data
ident	db	"Copyright (c) 2020 Robert Clausecker <fuz@fuz.su>", 10, 13, 0

	section	.bss
	align	2
edata	equ	$		; must be the first thing in .bss

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Parameters                                                                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

stack	equ	0x100		; emulator stack size in bytes (multiple of 16)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Macros                                                                     ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	; load value into ARM register
%macro	ldrlo	2
	mov	[%1*2+reglo], %2
%endmacro

%macro	ldrhi	2
	mov	[%1*2+reghi], %2
%endmacro

	; store value of ARM register
%macro	strlo	2
	mov	%1, [%2*2+reglo]
%endmacro

%macro	strhi	2
	mov	%1, [%2*2+reghi]
%endmacro

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Startup and Initialisation                                                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	section	.text
	org	0x100

	; relocate the stack
start:	mov	sp, end+stack	; beginning of stack

	; print copyright notice
	mov	si, ident
	call	puts

	; initialise .bss
	xor	ax, ax
	mov	di, edata
	mov	cx, (end-edata)/2 ; .bss section length in words
	rep	stosw		; clear .bss

	; configure emulator base address
	mov	dx, sp		; an address just past the end of the memory
	mov	cl, 4
	shr	dx, cl		; convert to paragraph count
	mov	ax, cs
	add	ax, dx		; emulator image base address
	mov	[imgbase], ax

	; terminate argument vector
	mov	di, 0x80	; argument vector length pointer
	xor	bx, bx		; clear bx
	mov	bl, [di]	; load argument vector length
	inc	di		; beginning of arguments
	mov	[bx+di], bh	; NUL-terminate arguments

	mov	al, 0x20	; AL = ' '
	mov	cx, bx		; max length: argument vector length
	repe	scasb		; find first non-space
	dec	di		; go back to first non-space
	mov	[file], di	; remember file name for later

	cmp	byte [di], bh	; was there any argument at all?
	jne	.0

	; no argument was given: print usage and exit
	mov	si, usage
	call	puts		; print usage
.die:	mov	ax, 0x4c01	; error level 1 (failure)
	int	0x21		; 0x4c: TERMINATE PROGRAM

	; an argument was given: try to open it
.0:	mov	dx, di		; file name
	mov	ax, 0x3d00	; AL=00 (open file for reading)
	int	0x21		; 0x3d: OPEN EXISTING FILE
	mov	[handle], ax	; remember file handle for later
	jnc	.1		; did an error occur?

	; opening, reading, or closing the file failed
.err:	push	cs
	pop	ds		; set DS = CS
	mov	si, [file]	; load file name for error message
	call	perror		; print error message
	jmp	.die		; and die

	; opening the file was succesful: load program image
.1:	xchg	bx, ax		; file handle
	mov	ax, sp
	mov	dx, cs		; DX:AX = image base

	; read until EOF
	; TODO: reject image if it is too large
.2:	call	seglin
	call	linseg		; normalise address (to give us some space)
	mov	ds, dx
	xchg	dx, ax		; buffer address at DS:DX
	mov	cx, 0x8000	; number of bytes to read
	mov	ah, 0x3f
	int	0x21		; 0x3f: READ FROM FILE VIA HANDLE
	jc	.err		; IO error?
	test	ax, ax		; end of file reached?
	jz	.eof

	add	ax, dx		; compute new base address
	mov	dx, ds		; move buffer address to DX:AX
	jmp	.2		; and read some more data

	; close the image file
.eof:	mov	ah, 0x3e
	int	0x21		; 0x3e: CLOSE A FILE HANDLE
	jc	.err

	; restore DS = CS
	push	cs
	pop	ds

	; initial register set up: image base address (R0)
	mov	bx, [imgbase] 	; load image base
	mov	dx, bx
	xor	ax, ax		; DX:AX contains the image base
	call	seglin		; as a linear address
	ldrlo	0, ax		; write load address to R0
	ldrhi	0, dx

	; initial register set up: memory size (R1)
	mov	dx, [2]		; load first segment past program image from PSP
	sub	dx, bx		; compute number of paragraphs available
	xor	ax, ax		;  to the program
	call	seglin		; and convert to a linear address
	ldrlo	1, ax		; write memory size to R1
	ldrhi	1, dx

	; initial register set up: stack pointer and reset vector
	mov	ds, bx		; load DS with emulated address space
	xor	si, si		; vector table begin
	lodsw			; load initial SP, low half
	ldrlo	cs:13, ax
	lodsw			; load initial SP, high half
	ldrhi	cs:13, ax
	lodsw			; load initial PC (reset vector), low half
	ldrlo	cs:15, ax
	lodsw			; load initial PC (reset vector), high half
	ldrhi	cs:15, ax

	call	run		; emulate a Cortex M0

	strlo	al, cs:0	; load error level from R0
	mov	ah, 0x4c
	int	0x21		; 0x4c: TERMINATE PROGRAM

	section	.data
usage	db	"Usage: PALANQIN CORTEXM0.IMG", 0

	section	.bss
	align	2
file	resw	1		; image file name
handle	resw	1		; image file handle

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Emulator State                                                             ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	section	.bss
	alignb	4
state	equ	$
reglo	resw	16		; ARM registers, low  hwords
reghi	resw	16		; ARM registers, high hwords
pcaddr	resd	1		; location of the next instruction as a segment/
				; offset pair.  The PC register in the register
				; set is only updated as needed to increase
				; performance.
imgbase	resw	1		; emulator image base segment
flags	resw	1		; CPU flags in 8086 format
insn	resw	1		; the currently executed instruction

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Instruction Simulation                                                     ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	section	.text
	; run the emulation until we need to stop for some reason
run:	push	cs		; set up ds = cs
	pop	ds
	call	pcseg		; find the address of the next instruction
.step:	call	step		; simulate one instruction
	jmp	.step		; do it again and again

	; simulate one instruction.  Assumes DS=CS.
step:	les	si, [pcaddr]	; load the program counter into DS:SI
	es	lodsw		; load an instruction
	mov	[insn], ax	; remember a copy of the instruction in insn
	mov	cl, 4
	rol	ax, cl		; ax >> (15-4)
	and	ax, 0x1e	; mask out the top 4 bits of the instruction
	mov	bx, ax		; and use them to index a jump table
	jmp	[tXXXX+bx]

	section	.data
	align	2
	; first level jump table: decode the top 4 instruction bits
tXXXX:	dw	h000		; 000XX shift immediate
	dw	h000		; 00011 add/subtract register/immediate
	dw	h001		; 00100 add/subtract/compare/move immediate
	dw	h001
	dw	h0100		; 010100XXXX data-processing register
				; 010001XX special data processing
				; 01001 LDR  (literal pool)
	dw	h0101		; 0101 load/store register offset
	dw	h011 		; 011XX load/store word/byte immediate offset
	dw	h011
	dw	h1000		; 1000X load/store halfword immediate offset
	dw	h1001		; 1001X load from/store to stack
	dw	h1010		; 1010X add to SP or PC
	dw	h1011		; 1011XXXX miscellaneous instructions
	dw	h1100		; 1100X load/store multiple
	dw	h1101		; 1101XXXX conditional branch
				; 11011110 undefined instruction
				; 11011111 service call
	dw	h1110		; 11100 B (unconditional branch)
	dw	h1111		; 11110 branch and misc. control

	section	.text

	; instruction handlers that have not been implemented yet
h000:
h001:
h0100:
h0101:
h011:
h1000:
h1001:
h1010:
h1011:
h1100:
h1101:
h1110:
h1111:	int3

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Address Space Conversion                                                   ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	section	.text

	; convert DX:AX into a linear address in DX:AX
	; trashes CX
seglin:	mov	cl, 4
	rol	dx, cl		; dx = ds >> 12 | ds << 4
	mov	cx, dx
	and	dx, 0xf		; dx = ds >> 12
	and	cl, 0xf0	; cx = ds <<  4
	add	ax, cx		; ax = ax + (ds >> 12)
	adc	dx, 0		; apply carry
	ret

	; convert linear address in DX:AX into a segmented address in DX:AX
	; the offset is normalised to 0x0000--0x00ff
	; ignores the high 12 bit of DX, trashes CL
linseg:	and	dx, 0xf
	mov	dh, ah
	mov	cl, 4
	ror	dx, cl
	mov	ds, dx		; ds = dx << 12 | ax >> 4 & 0x0ff0
	xor	ah, ah		; ax = ax & 0x00ff
	ret

	; determine the segmented address of the current instruction from PC
	; and load it into pcaddr.  Trashes CX.  If PC cannot be represented as
	; an address, an exception is caused.
pcseg:	strlo	ax, cs:15	; load PC into DX:AX
	strhi	dx, cs:15
	mov	ch, dh		; keep a copy of the top 4 bit of PC
	call	linseg		; set up linear address in DX:AX
	and	ch, 0xf0	; isolate address space nibble
	test	ch, ch		; address space 0 (adjusted)?
	jnz	.not0
	add	dx, [cs:imgbase]; apply address space adjustment
	jmp	.wb
.not0:	cmp	ch, 2		; address space 2 (unadjusted)?
	jne	.wild		; if not, this address cannot be translated
.wb:	mov	[cs:pcaddr], ax	; set up translated PC with DX:AX
	mov	[cs:pcaddr+2], dx
	ret

.wild:	int3			; TODO: generate an exception or something
	jmp	.wild		; endless loop

	; determine the linear address of the current instruction from pcaddr
	; and load it into PC.  It is assumed that PC points into the right
	; address space already.  Trashes CX.  If 

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; IO Routines                                                                ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	section	.text

	; print string in ds:si to stdout
puts:	lodsb
	test	al, al		; end of string reached?
	jz	.end
	xchg	ax, dx		; DOS wants the character in dl
	mov	ah, 0x02
	int	0x21		; 0x02: WRITE CHARACTER TO STDOUT
	jmp	puts

.end:	ret

	; print ds:si and then a colon and a space
	; then print a message for the error in AX
perror:	push	ax		; remember error code
	call	puts		; print string

	push	cs
	pop	ds		; prepare ds
	mov	si, colsp	; ": "
	call	puts

	pop	si		; reload error code
	add	si, si
	mov	si, [errors+si]	; load error code
	call	puts		; print error message

	mov	si, crlf	; load "\r\n"
	call	puts

	ret

	; DOS error codes and messages
	section	.data
	align	2

errors	dw	.E00, .E01, .E02, .E03, .E04, .E05, .E06, .E07
	dw	.E08, .E09, .E0A, .E0B, .E0C, .E0D, .E0E, .E0F
	dw	.E10, .E11, .E12

.E00	db	"unknown error",0
.E01	db	"function number invalid",0
.E02	db	"file not found",0
.E03	db	"path not found",0
.E04	db	"too many open files",0
.E05	db	"access denied",0
.E06	db	"invalid handle",0
.E07	db	"memory control block destroyed",0
.E08	db	"insufficient memory",0
.E09	db	"memory block address invalid",0
.E0A	db	"environment invalid",0
.E0B	db	"format invalid",0
.E0C	db	"access code invalid",0
.E0D	db	"data invalid",0
.E0E	equ	.E00		; error code E is reserved
.E0F	db	"invalid drive",0
.E10	db	"attempt to remove current directory",0
.E11	db	"not same device",0
.E12	db	"no more files",0

colsp	db	": ",0
crlf	db	13,10,0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Colophon                                                                   ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	section	.bss
	alignb	16
end	equ	$		; end of program (on paragraph boundary)
