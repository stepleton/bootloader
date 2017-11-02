*-----------------------------------------------------------
* Title      : Test stand-in for the Lisa Boot ROM
* Written by : Tom Stepleton
* Date       : 21 October 2016
* Description:
*   Contains faked replacements for various externally-
*   callable routines found in the Apple Lisa's boot ROM.
*   Produces textual output in the EASy68K simulator's I/O
*   window.
*
*   This code is not really all that "nice", but it should
*   be fairly simple.
*-----------------------------------------------------------

* Equates

    ; Data addresses
kBootDvce  EQU  $01B3               ; ROM-computed boot device byte
kRomRam    EQU  $0480               ; Scratchpad memory area for ROM routines

    ; ROM routine addresses
kInitMon   EQU  $00FE0084           ; Boot ROM monitor
kConvRtd5  EQU  $00FE0088           ; Display a string on the screen
kTwgRead   EQU  $00FE0094           ; Read floppy disk sector
kVfyChkSm  EQU  $00FE00BC           ; Verify checksum

    ; Miscellaneous constants
kNumSects  EQU  40                  ; "Last out!" tag every _ TWGREAD calls


* Pragmas

    MEMORY  Read $FE0000,$FEFFFF    ; The ROM is mapped to a read-only page


* Fake Lisa Boot ROM externally-callable routines

    ; Various constants from the ROM, as well as system parameters that the
    ; ROM saves in its reserved memory area. Some arithmetic may be necessary
    ; to get around alignment requirements.
    ORG     kBootDvce-1             ; Q: What device did we boot from?
    DC.W    $0001                   ; A: the lower floppy drive


    ; Data that the ROM is allowed to mutate.
    ORG     kRomRam                 ; These live in the ROM's scratchpad area
sTrSectors:                         ; Reset sectors-left counter
    DC.L    kNumSects
sTrBusyTag:                         ; 'Base' tag string for all but last sector
    DC.B    '..  oo  **  '          ; Will be mutated by the loader for variety


    ; Replicates the ROM's jump table for all of its external-facing routines.
    ORG     kConvRtd5
    BRA     FAKE_CONVRTD5
    ORG     kInitMon
    BRA     FAKE_INITMON
    ORG     kTwgRead
    BRA     FAKE_TWGREAD
    ORG     kVfyChkSm
    BRA     FAKE_VFYCHKSM

    ; Macros and helpers for our fake routines.
    ; NOTE: The printing macros can take data or addresses from just about
    ; anywhere as arguments, but DON'T use the stack pointer A7, it won't work.
mRegSave    MACRO                   ; Save registers onto the stack
    MOVEM.L D0-D7/A0-A6,-(A7)
            ENDM
mRegLoad    MACRO                   ; Reload registers from the stack
    MOVEM.L (A7)+,D0-D7/A0-A6
            ENDM
mPrnt       MACRO                   ; Print string at \1.L
    MOVEM.L D0/A1,-(A7)             ; Save D0 and A1 onto the stack
    MOVE.B  #14,D0                  ; We will want to print a string
    MOVEA.L \1,A1                   ; Here is the string to print
    TRAP    #15                     ; Call the EASy68K I/O trap
    MOVEM.L (A7)+,D0/A1             ; Restore D0 and A1
            ENDM
mPrntLn     MACRO                   ; Print string at \1.L, followed by CRLF
    MOVEM.L D0/A1,-(A7)             ; Save D0 and A1 onto the stack
    MOVE.B  #13,D0                  ; We will want to print a string
    MOVEA.L \1,A1                   ; Here is the string to print
    TRAP    #15                     ; Call the EASy68K I/O trap
    MOVEM.L (A7)+,D0/A1             ; Restore D0 and A1
            ENDM
mPrntHx     MACRO                   ; Print an unsigned hex value at \1.L
    MOVEM.L D0-D2,-(A7)             ; Save D0 to D2 onto the stack
    MOVE.L  \1,-(A7)                ; Save value to print on stack
    MOVE.B  #15,D0                  ; We will want to print a number
    MOVE.L  (A7)+,D1                ; We will want to print this number
    MOVE.B  #16,D2                  ; We will want to print it in base 16
    TRAP    #15                     ; Call the EASy68K I/O trap
    MOVEM.L (A7)+,D0-D2             ; Restore D0 to D2
            ENDM
mNewLn      MACRO                   ; Print a newline
    MOVEM.L D0-D1,-(A7)             ; Save D0 and D1 onto the stack
    MOVE.B  #0,D0                   ; We will want to print a substring of (A1)
    CLR.W   D1                      ; of length 0, so who cares where A1 points
    TRAP    #15                     ; Call the EASy68K I/O trap
    MOVEM.L (A7)+,D0-D1             ; Restore D0 and D1
            ENDM
mShow       MACRO                   ; Print hex value \2 with prefix string \1
    mPrnt   \1                      ; Print prefix string
    mPrntHx \2                      ; Print value as hex
    mNewLn                          ; Print newline
            ENDM

    ; Our stand-in for the CONVRTD5 routine
FAKE_CONVRTD5:
    mPrntLn #sConvRtd5              ; Print CONVRTD5 banner
    BSR     SHOW_D4
    BSR     SHOW_D5
    BSR     SHOW_D6
    BSR     SHOW_A3
    mPrnt   #sCrStrPrefix           ; Print "here's the argument" prefix
    mPrntLn A3                      ; Print argument string
    mNewLn                          ; An empty line of space
    RTS                             ; Back to the caller

    ; Our stand-in for the INITMON routine
FAKE_INITMON:
    mPrntLn #sInitMon               ; Print INITMON banner
    BSR     SHOW_D0
    BSR     SHOW_A2
    BSR     SHOW_A3
    MOVE.B  #9,D0                   ; We will want to halt the simulator soon
    MOVE.L  A3,D1                   ; Copy A3 to D1; is it empty?
    BEQ.S   _f0                     ; No; skip ahead; say "no error message"
    mPrnt   #sImErrPrefix           ; Print "here's the argument" prefix
    mPrntLn A3                      ; Print the error message string
    TRAP    #15                     ; Call the EASy68K I/O trap (halts!)
_f0 mPrntLn #sImNoErr               ; Print "no error message" string
    TRAP    #15                     ; Call the EASy68K I/O trap (halts!)

    ; Our stand-in for the TWGREAD routine
    ; Note that the checksum for the final sector assumes that the bootloader
    ; has been trying to read a SONY 3.5" disk.
FAKE_TWGREAD:
    mPrntLn #sTwgRead               ; Print TWGREAD banner
    BSR     SHOW_D0
    BSR     SHOW_D1
    BSR     SHOW_D2
    BSR     SHOW_A0
    BSR     SHOW_A1
    BSR     SHOW_A2
    BSR     SHOW_A3
    mNewLn                          ; An empty line of space
    ; Make fake sector data: the sector ID rotated byte-by-byte.
    MOVE.W  #$7F,D0                 ; Longs to "load", minus one
_f1 MOVE.L  D1,(A2)+                ;   Copy a (rotated) sector ID
    ROR.L   #8,D1                   ;   Rotate sector ID by a byte
    DBRA    D0,_f1                  ;   Loop to copy 128 longs; D1 restored
    SUBA.L  #$200,A2                ; Rewind A2
    ; See if we're done loading sectors.
    SUBQ.L  #1,sTrSectors           ; Decrement sectors to load
    BEQ.S   _f2                     ; No more; skip to copy the final tag
    ; We're not. Use the "busy" tag. Mutate it for visual interest.
    LEA     sTrBusyTag,A0           ; Point to busy tag
    MOVE.L  (A0),D0                 ; Rotate bytes 1..4 by one byte
    ROR.L   #8,D0
    MOVE.L  D0,(A0)+
    MOVE.L  (A0),D0                 ; Rotate bytes 5..8 by one byte
    ROR.L   #8,D0
    MOVE.L  D0,(A0)+
    MOVE.L  (A0),D0                 ; Rotate bytes 9..12 by one byte
    ROR.L   #8,D0
    MOVE.L  D0,(A0)+
    SUBA.L  #$C,A0                  ; Rewind A0
    BRA.S   _f3                     ; Skip ahead to tag copy
    ; Done loading sectors. Use the final tag and reset sector countdown
_f2 LEA     sTrLastOut,A0           ; Prepare to copy the final tag
    MOVE.L  #kNumSects,sTrSectors   ; Reset sector countdown
    ; Copy the tag.
_f3 MOVE.W  #$B,D0                  ; Prepare to copy 12 bytes
_f4 MOVE.B  (A0)+,(A1)+             ;   Copy a byte
    DBRA    D0,_f4                  ;   Loop to copy 12 bytes
    SUBA.L  #$C,A1                  ; Rewind A1
    ; Return to caller with 0 errors.
    CLR.L   D0                      ; No error code
    ANDI.B  #$0,CCR                 ; No error bit or anything
    RTS                             ; Back to caller

    ; Our stand-in for the VFYCHKSM routine; actually computes checksum.
FAKE_VFYCHKSM:
    mPrntLn #sVfyChkSm              ; Print VFYCHKSM banner
    BSR     SHOW_D0
    BSR     SHOW_D1
    BSR     SHOW_A0
    MOVE.L  D4,-(A7)                ; Save D4 on stack
    CLR.L   D2                      ; Holds last word added to checksum
    CLR.L   D3                      ; Accumulates checksum
    CLR.L   D4                      ; Checksum up to all but the last word
_fA MOVE.W  D3,D4                   ;   Save old checksum
    MOVE.W  (A0)+,D2                ;   Next word to add to checksum
    ADD.W   D2,D3                   ;   Add it to the checksum
    ROL.W   #1,D3                   ;   Rotate checksum left one bit
    DBRA    D0,_fA                  ;   Decrement loop counter and loop
    mShow   #sVcWordOnDisk,D2       ; Print what the checksum on disk was
    NEG.W   D4                      ; Compute what it should have been
    ANDI.L  #$FFFF,D4               ; (We only care about the word part)
    mShow   #sVcWordComputed,D4     ; Print what checksum should have been
    mNewLn                          ; An empty line of space
    TST.W   D3                      ; See if D3 is 0
    BEQ.S   _fB                     ; It is; checksum was a match
    ORI.B   #$1,CCR                 ; It isn't; mark the error
_fB MOVEM.L (A7)+,D4                ; Restore D4; MOVEM won't alter CCR
    RTS                             ; Back to caller

    ; Register-printing subroutines
SHOW_D0:
    mShow   #sD0,D0
    RTS                             ; Return to caller
SHOW_D1:
    mShow   #sD1,D1
    RTS                             ; Return to caller
SHOW_D2:
    mShow   #sD2,D2
    RTS                             ; Return to caller
SHOW_D3:
    mShow   #sD3,D3
    RTS                             ; Return to caller
SHOW_D4:
    mShow   #sD4,D4
    RTS                             ; Return to caller
SHOW_D5:
    mShow   #sD5,D5
    RTS                             ; Return to caller
SHOW_D6:
    mShow   #sD6,D6
    RTS                             ; Return to caller
SHOW_D7:
    mShow   #sD7,D6
    RTS                             ; Return to caller
SHOW_A0:
    mShow   #sA0,A0
    RTS                             ; Return to caller
SHOW_A1:
    mShow   #sA1,A1
    RTS                             ; Return to caller
SHOW_A2:
    mShow   #sA2,A2
    RTS                             ; Return to caller
SHOW_A3:
    mShow   #sA3,A3
    RTS                             ; Return to caller
SHOW_A4:
    mShow   #sA4,A4
    RTS                             ; Return to caller
SHOW_A5:
    mShow   #sA5,A5
    RTS                             ; Return to caller
SHOW_A6:
    mShow   #sA6,A6
    RTS                             ; Return to caller


* String constants

    ; String constants for our fake ROM routines.
sConvRtd5:
    DC.B    'CONVRTD5 called:',0
sCrStrPrefix:
    DC.B    'Display string: ',0
sInitMon:
    DC.B    'INITMON called, ending simulation, bye!',0
sImNoErr:
    DC.B    'No error string supplied.',0
sImErrPrefix:
    DC.B    'Error string: ',0
sTwgRead:
    DC.B    'TWGREAD called:',0
sTrLastOut:
    DC.B    'Last out!',0,$A3,$6C
sVfyChkSm:
    DC.B    'VFYCHKSM called:',0
sVcWordOnDisk:
    DC.B    'Checksum stored was: ',0
sVcWordComputed:
    DC.B    '  Checksum computed: ',0
sD0:
    DC.B    '  D0: ',0
sD1:
    DC.B    '  D1: ',0
sD2:
    DC.B    '  D2: ',0
sD3:
    DC.B    '  D3: ',0
sD4:
    DC.B    '  D4: ',0
sD5:
    DC.B    '  D5: ',0
sD6:
    DC.B    '  D6: ',0
sD7:
    DC.B    '  D7: ',0
sA0:
    DC.B    '  A0: ',0
sA1:
    DC.B    '  A1: ',0
sA2:
    DC.B    '  A2: ',0
sA3:
    DC.B    '  A3: ',0
sA4:
    DC.B    '  A4: ',0
sA5:
    DC.B    '  A5: ',0
sA6:
    DC.B    '  A6: ',0


* End of the fake ROM routines

*~Font name~Courier New~
*~Font size~10~
*~Tab type~1~
*~Tab size~4~
