; ============================================================================
;  prodos_hd_rom.s -- slot 7 firmware: ProDOS block driver and SmartPort
;
;  Assembled by scripts/hdrom.py (py65, plain 6502 opcodes only, so it runs
;  on an unenhanced //e) into src/prodos_hd_rom.vh, which src/prodos_hd.v
;  includes.  Edit this file, then run `python scripts/hdrom.py`;
;  sim/run.ps1 fails if the .vh is stale (`--check`).
;
;  The card follows the Apple IIc Technical Reference, chapter 6 (SmartPort)
;  and the ProDOS 8 Technical Reference, 6.3 (disk drivers):
;    $C701=$20 $C703=$00 $C705=$03   a disk device (Autostart, ProDOS)
;    $C707=$00                       ...with a SmartPort
;    $C7FB=$00                       SmartPort ID type: not RAM, not SCSI
;    $C7FC-$C7FD=$0000               block count: ask STATUS
;    $C7FE=$9F                       removable, 2 volumes, format/write/read/status
;    $C7FF=$29                       ProDOS entry $C729; SmartPort entry $C72C
;  ProDOS 8 only counts SmartPort units on a card in slot 5 (Technical Note
;  #20), so in slot 7 it uses the block entry and $C7FE's two volumes, as
;  before.  The SmartPort is for software that asks for it (MECC's Computer
;  Inspector, disk utilities).  It lives in the $C800 expansion ROM, which
;  the card claims whenever its $C7xx page is touched: the entry does
;  BIT $CFFF first, which releases any other card's (and the 80-column
;  firmware's) $C800, and the next fetch from $C7xx claims it for slot 7.
;
;  Hardware ($C0F0-$C0FF, src/prodos_hd.v):
;    $C0F0 data   $C0F1/2 block lo/hi   $C0F3 1 = read, 0 = write
;    $C0F4 status: bit 7 busy, bit 1 volume present, bit 0 last read failed
;    $C0F5 drive (0/1)   $C0F6/7 the drive's size in blocks (lo/hi)
;  Zero page: $42-$47, the ProDOS driver parameters, which the SmartPort
;  also uses as scratch (the IIc Reference: no data passes through zero page).
; ============================================================================

DATA    = $C0F0
BLKLO   = $C0F1
BLKHI   = $C0F2
XFER    = $C0F3
STAT    = $C0F4
DRIVE   = $C0F5
SIZELO  = $C0F6
SIZEHI  = $C0F7
CMD     = $42
UNIT    = $43
BUF     = $44
BUFH    = $45
BLK     = $46
BLKH    = $47

        .org $C700
; ---- boot: read block 0 of drive 1 to $0800 and run it ----
; The first four instructions are the signature bytes $20 $00 $03 $00.
BOOT:   LDX #$20
        LDY #$00
        LDX #$03
        LDX #$00
        LDA #$01
        STA CMD
        LDA #$70
        STA UNIT
        LDA #$00
        STA BUF
        STA BLK
        STA BLKH
        LDA #$08
        STA BUFH
        JSR PRODOS
        BCS NOBOOT
        LDX #$70
        JMP $0801
NOBOOT: JMP $FABA               ; no volume: the Autostart scan's next slot

        .org $C729
PRODOS: JMP BLKDRV              ; $C7FF points here
SPORT:  BIT $CFFF               ; SmartPort entry, ProDOS entry + 3
        JMP SPDISP

; ---- ProDOS block driver: $42 command, $43 unit, $44 buffer, $46 block ----
BLKDRV: LDA UNIT
        ASL
        LDA #$00
        ROL
        STA DRIVE
        LDA STAT
        AND #$02
        BEQ NODEV
        LDA BLK
        STA BLKLO
        LDA BLKH
        STA BLKHI
        LDY #$00
        LDA CMD
        BEQ STATUS
        CMP #$01
        BEQ READ
        CMP #$02
        BEQ WRITE
        CMP #$03
        BEQ OK                  ; FORMAT: nothing to lay down on this medium
        LDA #$01
        SEC
        RTS
NODEV:  LDA #$28
        SEC
        RTS
STATUS: LDX SIZELO
        LDY SIZEHI
OK:     LDA #$00
        CLC
        RTS
READ:   LDA #$01
        STA XFER
RW:     LDA STAT
        BMI RW
        LSR
        BCS IOERR
R1:     LDA DATA                ; ~15 cycles a byte: the card fetches the next
        STA (BUF),Y             ; byte from the DDR3 in between
        INY
        BNE R1
        INC BUFH
R2:     LDA DATA
        STA (BUF),Y
        INY
        BNE R2
        DEC BUFH
        JMP OK
WRITE:  LDA #$00
        STA XFER
W1:     LDA (BUF),Y
        STA DATA
        INY
        BNE W1
        INC BUFH
W2:     LDA (BUF),Y
        STA DATA
        INY
        BNE W2
        DEC BUFH
W3:     LDA STAT                ; until the card has the block
        BMI W3
        JMP OK
IOERR:  LDA #$27
        SEC
        RTS

        .org $C7FB
        .byte $00               ; SmartPort ID type
        .byte $00, $00          ; blocks: ask STATUS
        .byte $9F               ; status byte
        .byte <PRODOS           ; entry

; ============================================================================
;  SmartPort, in the $C800 expansion ROM
;
;  JSR dispatch / .byte command / .word parameter list.  Returns past the
;  three inline bytes, C clear and A = 0, or C set and A = the error;
;  STATUS returns its byte count in X (low) and Y (high).
;  Units: 0 the SmartPort itself, 1 and 2 the drives.
; ============================================================================
        .org $C800
SPDISP: CLD
        TSX                     ; the return address points at the JSR's
        LDA $0101,X             ; last byte: the inline bytes follow it
        STA BLK
        CLC
        ADC #$03
        STA $0101,X
        LDA $0102,X
        STA BLKH
        ADC #$00
        STA $0102,X
        LDY #$01
        LDA (BLK),Y
        STA CMD
        INY
        LDA (BLK),Y
        STA BUF                 ; (BUF) = the parameter list
        INY
        LDA (BLK),Y
        STA BUFH
        LDY #$01
        LDA (BUF),Y
        STA UNIT
        LDA CMD
        CMP #$06                ; OPEN, CLOSE, READ, WRITE: character devices
        JCS BADCMD              ; only, as the UniDisk 3.5 answers
        TAX
        LDY #$00
        LDA (BUF),Y
        CMP PCOUNT,X
        JNE BADPCNT
        LDA UNIT
        JEQ UNIT0
        CMP #$03
        JCS NODRIVE
        LSR                     ; unit 1, 2 -> drive 0, 1
        STA DRIVE
        LDA CMD
        BEQ DSTAT
        CMP #$04
        JEQ DCTL
        CMP #$05
        JEQ SPOK                ; INIT
        LDA STAT                ; READ, WRITE, FORMAT need the medium
        AND #$02
        JEQ OFFLINE
        LDA CMD
        CMP #$03
        BEQ SPOK                ; FORMAT
; ---- READ BLOCK / WRITE BLOCK: buffer at +2, block at +4 (3 bytes) ----
        LDY #$06
        LDA (BUF),Y
        JNE BADBLK
        DEY
        LDA (BUF),Y
        CMP SIZEHI
        BCC INSIDE
        JNE BADBLK
        DEY
        LDA (BUF),Y
        CMP SIZELO
        JCS BADBLK
INSIDE: LDY #$05
        LDA (BUF),Y
        STA BLKH
        DEY
        LDA (BUF),Y
        STA BLK
        DEY
        LDA (BUF),Y
        TAX
        DEY
        LDA (BUF),Y
        STA BUF
        STX BUFH
        LDA UNIT                ; the block driver's unit: drive in bit 7,
        LSR                     ; slot 7 in bits 6-4
        LDA #$70
        BCS UNIT1
        LDA #$F0
UNIT1:  STA UNIT
        JMP BLKDRV              ; returns to the caller for us

; ---- STATUS of a drive: code 0 general status, 3 the DIB ----
DSTAT:  LDY #$04
        LDA (BUF),Y
        BEQ DST0
        CMP #$03
        BNE BADCTL
        JSR STHEAD
        LDY #$04
DIBL:   LDA DIBTL-4,Y
        STA (BLK),Y
        INY
        CPY #$19
        BNE DIBL
        LDA UNIT                ; the drive digit of the name
        ORA #$30
        LDY #$10
        STA (BLK),Y
        LDX #$19
        BNE SPOKN
DST0:   JSR STHEAD
        LDX #$04
SPOKN:  LDY #$00
SPOK:   LDA #$00
        CLC
        RTS

; ---- CONTROL: reset (code 0) is all a drive takes ----
DCTL:   LDY #$04
        LDA (BUF),Y
        BEQ SPOK
        BNE BADCTL

; ---- unit 0, the SmartPort itself ----
UNIT0:  LDA CMD
        BEQ U0STAT
        CMP #$04
        BEQ U0CTL
        CMP #$05
        BEQ SPOK                ; INIT
        BNE BADUNIT             ; READ, WRITE, FORMAT
U0STAT: LDY #$04
        LDA (BUF),Y
        BNE BADCTL
        JSR GETLST
        LDY #$07
U0L:    LDA U0TAB,Y
        STA (BLK),Y
        DEY
        BPL U0L
        LDX #$08
        BNE SPOKN
U0CTL:  LDY #$04                ; 0, 1: interrupts on, off (there are none)
        LDA (BUF),Y
        CMP #$02
        BCC SPOK
        BCS BADCTL

BADCMD: LDA #$01
        SEC
        RTS
BADPCNT: LDA #$04
        SEC
        RTS
BADUNIT: LDA #$11
        SEC
        RTS
BADCTL: LDA #$21
        SEC
        RTS
NODRIVE: LDA #$28
        SEC
        RTS
BADBLK: LDA #$2D
        SEC
        RTS
OFFLINE: LDA #$2F
        SEC
        RTS

; (BLK) = the status list (parameter list +2)
GETLST: LDY #$02
        LDA (BUF),Y
        STA BLK
        INY
        LDA (BUF),Y
        STA BLKH
        RTS
; the general status byte and the size, list bytes 0-3
STHEAD: JSR GETLST
        LDX #$E8                ; block, write, read, format; not on line
        LDA STAT
        AND #$02
        BEQ STH1
        LDX #$F8                ; ...on line
STH1:   TXA
        LDY #$00
        STA (BLK),Y
        INY
        LDA SIZELO
        STA (BLK),Y
        INY
        LDA SIZEHI
        STA (BLK),Y
        INY
        LDA #$00
        STA (BLK),Y
        RTS

PCOUNT: .byte 3, 3, 3, 1, 3, 1  ; STATUS READ WRITE FORMAT CONTROL INIT
U0TAB:  .byte 2, $40, 0, 0, 0, 0, 0, 0   ; 2 devices, no interrupt
DIBTL:  .byte 12                ; the DIB from byte 4: name length,
        .asc "TF CARD S7D1    "  ; 16 bytes, uppercase, space padded,
        .byte $02, $00          ; ProFile-type hard disk, subtype 0,
        .word $0100             ; firmware version 1.0
