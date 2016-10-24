*-----------------------------------------------------------
* Title      : Floppy disk bootloader for Lisa
* Written by : Tom Stepleton
* Date       : 20 October 2016
* Description:
*   A bootloader for executable code on Apple Lisa floppies.
*   Lives in the 512-byte first sector of your floppy; all
*   remaining sectors are your program.
*
*   Data is loaded contguously from the second sector onward
*   until a sector whose tag starts with the ASCII string
*   'Last out!\0' is encountered. The final two bytes of the
*   tag are a 16-bit checksum for all loaded sectors.
*
*   Tags for preceding sectors are presented to the user in
*   the "hourglass" dialog box displayed by the boot ROM
*   during booting. (This behaviour can be disabled.)
*
*   Loaded data will occupy a contiguous block of RAM from
*   address $800 onward. This leaves the boot ROM-reserved
*   memory areas untouched (including the stack).
*
*   After loading, the bootloader verifies the checksum and
*   JMPs to $800.
*-----------------------------------------------------------

* Equates

    ; Data addresses
kBootDvce  EQU  $01B3               ; ROM-computed boot device byte
kScreen    EQU  $0110               ; ROM-set pointer to bottom of video memory

kDataStart EQU  $0800               ; Start of loaded data

    ; Device addresses
kDiskMem   EQU  $00FCC001           ; Shared disk controller memory
kVia1Base  EQU  $00FCDD81           ; VIA handling floppy interrupts

    ; ROM routine addresses
kConvRtd5  EQU  $00FE0088           ; Display a string on the screen
kInitMon   EQU  $00FE0084           ; Boot ROM monitor
kTwgRead   EQU  $00FE0094           ; Read floppy disk sector

    ; Constants
kFdirTime  EQU  $C0000              ; Disk fdir timeout (two minutes)
kSectrSize EQU  $200                ; Sectors are 512 bytes

    ; Set the following EQU nonzero to have the bootloader show the sector tags
    ; of all but the last window whilst loading.
kShowTag   EQU  1

    ; Set the following EQU nonzero to enable additional test and debugging
    ; code for use with the EASy68K 68000 simulator. Code compiled with this
    ; flag enabled is not usable as a bootloader.
kEASy68K   EQU  0


* Bootloader code

    ORG    $20000                   ; Where the boot ROM loads this sector.

START:


*****************
*** STAGE ONE ***
*****************
    ; This stage copies the rest of the bootloader's code (aka "stage two") to
    ; the very last usable region in RAM: the portion just before the region
    ; that the ROM allocates for the video memory (which is the last 30k or so
    ; of the flat entire-physical-memory-spanning address space that the boot
    ; ROM programs into the MMU just after power-up or reboot).
    ;
    ; When the copy is complete, the program flow jumps to the copied code.
STAGEONE:

  IFNE kEASy68K
    LEA     $100000,A5              ; Testing? Point A5 at stage 2 directly...
    JMP     (A5)                    ; ...and jump there
  ENDC
    MOVEA.L kScreen,A5              ; Start of the screen bitmap buffer
    LEA     THEEND,A0               ; End of our code to copy
    MOVE.W  #(THEEND-STAGETWO-1),D0 ; Bytes to copy - 1
_1_ MOVE.B  -(A0),-(A5)             ;   Copy bytes in reverse order
    DBRA    D0,_1_                  ;   Decrement loop counter; break if -1
    JMP     (A5)                    ; Jump to copied code


*****************
*** STAGE TWO ***
*****************
    ; This stage does the rest of the bootloading. It loads data sector by
    ; sector until the magic 'Last out!' tag is found, verifies the checksum
    ; of the loaded data, then jumps to the loaded data. It requires that A5
    ; point to the byte just before the first byte of the Stage Two code.
  IFNE kEASy68K
    ORG     $100000                 ; Debugging? Stage 2 lives at 1 MB
  ENDC
STAGETWO:

    ; Prepare "initial" arguments for the disk reading routine LOAD. We store
    ; a "\0\0" "null terminator" just before the stage 2 code (two bytes for
    ; alignment when we copy the checksum after "Last out!\0"), and before that,
    ; the 12 bytes of the disk sector tag. Can you guess what we'll do with it?
    CLR.W   -(A5)                   ; "Null terminator" for tag data
    SUBQ.L  #6,A5                   ; Tag address, 12 bytes earlier...
    SUBQ.L  #6,A5                   ; ...note that two SUBQs takes less space
    MOVEA.L #kDataStart,A6          ; Data address (starts at $800)
    ; Last but not least, we put the next sector to load in D7. "Native" Lisa
    ; sector addresses go DdZzSsTt (Dd=drive, Zz=side, Ss=sector, Tt=track),
    ; but we actually use DdZzTtSs instead. To continue loading the drive we're
    ; already booting from, we load the boot device byte into Dd, which is
    ; either 00 (upper) or 01 (lower). Dd needs to be 00 or 80 respectively,
    ; so we simply rotate the LSB to the MSB.
    CLR.L   D7                      ; Clear D7
    MOVE.B  kBootDvce,D7            ; Load the boot device byte
    ROR.L   #1,D7                   ; Rotate LSB to MSB
    ; Then we set the LSB to indicate we want sector 1, track 0, side 0, the
    ; very next sector after the one that this bootloader loaded from.
    ADDQ.B  #1,D7                   ; Set LSB to 1

    ; Sector load loop. Owns D4-D7/A5-A6. (D4-D6 are not used if kShowTag==0).
_2_ BSR.S   LOADSECTOR              ; Load the next sector
    ADDA.L  #kSectrSize,A6          ; Advance data load address
    BSR.S   MAYBEBOOT               ; Boot if that sector was the last one
  IFNE kShowTag
    MOVEA.L A5,A3                   ; We wish to print the tag
    MOVE.W  #24,D6                  ; Start at column 24
    MOVE.W  #13,D5                  ; Print on row 13
    JSR     kConvRtd5               ; Call ROM string print routine
  ENDC
_2a ADDQ.L  #1,D7                   ; Increment sector identifier
    BSR.S   VALIDATE                ; See if this sector DdZzTtSs is valid
    BHI.S   _2a                     ; It isn't, so increment sector again
    BRA.S   _2_                     ; It is, so load the sector


LOADSECTOR:
    ; Load floppy disk sector. Arguments are:
    ;   A5: load sector tag here
    ;   A6: load data here
    ;   D7: sector to load: DdZzTtSs (Dd=drive, Zz=side, Tt=track, Ss=sector)
    ; Trashes registers: A0, A1, A2, A3, D0, D1, D2, D3

    MOVEA.L #kDiskMem,A0            ; Shared disk controller memory
    MOVEA.L A5,A1                   ; Tag address
    MOVEA.L A6,A2                   ; Data address
    MOVEA.L #kVia1Base,A3           ; VIA handling floppy interrupts
    CLR.L   D0                      ; Drive speed (go with the default)
    MOVE.L  D7,D1                   ; DdZzTtSs sector to read
    ROR.W   #8,D1                   ; Convert to DdZzSsTt for ROM routine
    MOVE.L  #kFdirTime,D2           ; Read timeout time (go with the default)
    JSR     kTwgRead                ; Call ROM floppy sector read routine
    BCS.S   _3_                     ; Error? Jump to the fail routine
    RTS                             ; No error, so back to caller

    ; Sector read fail routine (error code is already in D0)
_3_ SUBA.L  A2,A2                   ; No icon to show the user
    LEA     sFailure(PC),A3         ; Floppy failure error message
    JMP     kInitMon                ; Bail to the monitor


MAYBEBOOT:
    ; Check whether the last sector loaded was the last sector to load. If it
    ; was, check the checksum of all loaded data; if it matches, boot. If not,
    ; return to the caller. Arguments are:
    ;   A5: location of last-loaded sector tag
    ;   A6: just past the end of all the loaded data.
    ; Assumes that all data has been loaded in the memory region starting at
    ; kDataStart and ending just before (A6).
    ; Trashes registers: A0 A1 D0

    ; Compare first ten bytes of the last-loaded sector's tag to sLastOut.
    ; If not a match, return to the caller.
    LEA     sLastOut(PC),A0         ; A0 walks along sLastOut
    MOVEA.L A5,A1                   ; A1 walks along the loaded sector tag
_4_ MOVE.B  (A0)+,D0                ; Next sLastOut char into D0
    CMP.B   (A1)+,D0                ; Compare against next tag char
    BEQ.S   _5_                     ; Were they the same?
    RTS                             ; If not, back to caller
_5_ TST.B   D0                      ; If so, was this the last sLastOut byte?
    BNE.S   _4_                     ; If it wasn't, do the next byte

    ; If a match, verify loaded data checksum.
    CLR.W   D0                      ; Clear checksum accumulator
    MOVEA.L #kDataStart,A0          ; Beginning of data to checksum
_6_ ADD.W   (A0)+,D0                ; Add next word to checksum accumulator
    ROL.W   #1,D0                   ; Rotate one bit left
    CMPA.L  A0,A6                   ; Done with the data?
    BHI.S   _6_                     ; Not yet, keep looping
    CMP.W   (A1),D0                 ; Yes, compare computed checksum w/expected

    ; If the checksum matched, then boot; if not, fail to the monitor. The
    ; computed checksum in D0 will be the error code.
    BNE.S   _7_                     ; Checksum mismatch?
    ADDQ.L  #4,SP                   ; If not, pop the stack...
  IFEQ kEASy68K                     ; ...and if not debugging in the sim...
    JMP     kDataStart              ; ...jump to loaded code! All done!
  ENDC
  IFNE kEASy68K                     ; But if we're in the sim...
    LEA     sSuccess,A3             ; "Success!" error message;
    JMP     kInitMon                ; Bail to the monitor; nevermind D0, A2
  ENDC
_7_ SUBA.L  A2,A2                   ; No icon to show the user
    LEA     sChecksum(PC),A3        ; Bad checksum error message
    JMP     kInitMon                ; Bail to the monitor


VALIDATE:
    ; ** For SONY 3.5" drives, single-sided (400k) and double-sided (800k). **
    ;
    ; Check whether a DdZzTtSs (Dd=drive, Zz=side, Tt=track, Ss=sector) sector
    ; identifier lists a valid side, track, and sector. If not, optionally and
    ; only if practicable, advance the sector identifier upward through some
    ; of its numerically contiguous neighboring 32-bit numbers that are also 
    ; invalid---but stop before arriving at a valid sector identifier.
    ;
    ; Diagrammatically, the set of valid side, track, and sector identifiers
    ; is discontiguous over the 24-bit integers (* means "valid identifier"):
    ;
    ;   _____*****_____*****_______________*****_____*****_______________
    ;                   H    I            J                      increasing-->
    ;
    ; If VALIDATE is called with the sector identifier H, it must indicate that
    ; the identifier is valid; if it's called with the sector identifier I, it
    ; must indicate the identifier is invalid, and it can additionally mutate
    ; the sector identifier up to (but no further than) J.
    ;
    ; After executing VALIDATE, then:
    ;  - to branch on a *valid* identifier, BLS
    ;  - to branch on an *invalid* identifier, BHI
    ;
    ; Arguments to this routine:
    ;   D7: sector to load: DdZzTtSs (Dd=drive, Zz=side, Tt=track, Ss=sector)
    ; Trashes registers: D0 D1

    ; The sector identifier can't be larger than $14F08, since Zz can either
    ; be 00 (side 1) or 01 (side 2).
    MOVE.L  D7,D0                   ; We'll dissect the identifier in D0
    LSL.L   #8,D0                   ; Get rid of Dd by shifting left 8 bits...
    LSR.L   #8,D0                   ; ...and then shifting back 8 bits right
    CMPI.L  #$14F08,D0              ; ZzTtSs > the largest possible ID?
    BHI.S   _9a                     ; Yes, return indirectly to the caller

    ; TtSs can't be larger than $4F08; otherwise, advance toward disk side 2.
    ; ($4F is the largest track on Sony).
    CMPI.W  #$4F08,D0               ; TtSs > $4F08?
    BLS.S   _8_                     ; No, skip ahead to keep testing
    MOVE.W  #$FFFF,D7               ; Yes, advance D7 to just before disk side 2
    BRA.S   _9_                     ; Jump to fail routine

    ; Ss can only be certain values depending on the Tt value. Valid values:
    ;   Tracks 00..0F: sectors 0..B
    ;          10..1F: sectors 0..A
    ;          20..2F: sectors 0..9
    ;          30..3F: sectors 0..8
    ;          40..4F: sectors 0..7
_8_ MOVE.B  D0,D1                   ; Copy Ss to D1
    LSR.W   #8,D0                   ; In D0, TtSs => 00Tt
    LSR.B   #4,D0                   ; In D0, 00Tt => 000T
    NEG.B   D0                      ; Negate that byte, and...
    ADDI.B  #$0B,D0                 ; ...add $B, giving our largest track value
    CMP.B   D0,D1                   ; Is the track value larger than that?
    BLS.S   _9a                     ; No, return indirectly to the caller
    MOVE.B  #$FF,D7                 ; Yes, advance D7 to just before next track

_9_ ANDI.B  #$1A,CCR                ; Clear C and Z so caller's BHI will jump
_9a RTS                             ; Back to caller

    ; TODO: implement for twiggies.
    ; TWIGGY:
    ; tracks 0..3: sectors 0..15.
    ;        4..A: sectors 0..14.
    ;       B..10: sectors 0..13.
    ;      11..16: sectors 0..12.
    ;      17..1C: sectors 0..11.
    ;      1D..22: sectors 0..10.
    ;      23..29: sectors 0..F.
    ;      2A..2D: sectors 0..E.
    ;
 

* String constants

    ; **NOTE**: These constants must collectively use an EVEN number of chars,
    ; or else the instructions in Stage 2 will not be word-aligned.

sChecksum:
    DC.B    'BAD CHECKSUM',0        ; Checksum mismatch error message
sFailure:
    DC.B    'FLOPPY FAIL',0         ; Floppy read failure error message
sLastOut:
    DC.B    'Last out!',0           ; Tag prefix marking last sector to load
sPadding:
    DC.B    $FF                     ; Padding byte (see NOTE above!)
  IFNE kEASy68K
sSuccess:
    DC.B    'Success! We actually jump to $800 here. Ending simulation, bye!',0
  ENDC


* End of the bootloader

THEEND:

    ; Include the ROM stand-in code if we are testing in EASy68K.
  IFNE kEASy68K
    INCLUDE FakeBootRom.X68
  ENDC


* End of source

    ; Designates START as the beginning of the program.
    END    START

*~Font name~Courier New~
*~Font size~10~
*~Tab type~1~
*~Tab size~4~
