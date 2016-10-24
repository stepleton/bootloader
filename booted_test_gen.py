#!/usr/bin/python

from __future__ import absolute_import
from __future__ import division
from __future__ import print_function

import argparse
import datetime
import os
import textwrap


def _define_flags():
  """Defines an `ArgumentParser` for command-line flags used by this program."""
  flags = argparse.ArgumentParser(
      description='Generate a test program that jumps to each loaded sector')

  flags.add_argument('-n', '--num_sectors',
                     help='How many sectors the program should occupy',
                     type=int,
                     default=799)

  flags.add_argument('-o', '--output',
                     help='Where to write the resulting assembly source',
                     type=argparse.FileType('wt'),
                     default='-')

  return flags


_HEADER = textwrap.dedent("""\
    *-----------------------------------------------------------
    * Title      : Bootloader-loaded test program
    * Written by : a python program run by {}@
    * Date       : {:%d %B %Y}
    * Description:
    *   Code should demonstrate correct loading of a program
    *   from a disk by jumping around between code snippets at
    *   the start of each of all sectors that don't contain the
    *   bootloader. Calls the ROM message display routine.
    *-----------------------------------------------------------
    
    * Equates
    
        ; ROM routine addresses
    kConvRtd5   EQU  $00FE0088           ; Display a string on the screen
    
        ; Screen display properties
    kRow1       EQU  14
    kRow2       EQU  15
    kRow3       EQU  16
    kCol        EQU  24
    
    
    * Program code
    
        ORG     $800                     ; Floppy data is loaded here
    
    START:
        LEA     sHooray,A3               ; Print the message at sHooray
        CLR.L   D4                       ; Irrelevant; no CRLF in string
        MOVE.L  #kRow1,D5                ; Row for printed string
        MOVE.L  #kCol,D6                 ; Column to start printing from
        JSR     kConvRtd5                ; Call ROM string display routine
        LEA     sUnstoppable,A3          ; Print the message at sUnstoppable
        MOVE.L  #kRow2,D5                ; Row for printed string
        MOVE.L  #kCol,D6                 ; Column to start printing from
        JSR     kConvRtd5                ; Call ROM string display routine
        JMP     LOOP                     ; Jump ahead to the looping display

    sHooray:                             ; Data of message to print
        DC.B    'HOORAY -- THE BOOTLOADER LOADED AND STARTED OUR PROGRAM.',0
    sUnstoppable:                        ; Data for another message
        DC.B    'YOU WILL HAVE TO PRESS THE RESET BUTTON TO STOP IT.',0

        DS.W    0                        ; Restore word alignment for code
    LOOP:
   """.format(os.environ['USER'], datetime.date.today()))

_FOOTER = textwrap.dedent("""\
    
        DS.W    0                        ; Restore word alignment for code
    LOOPBACK:
        ; Jump back to the beginning; loop forever.
        JMP     LOOP

    * End of program

        ; Designates START as the beginning of the program.
        END     START
    """)


def _sector_message_code(sector_num, num_sectors):
  org_addr = 0x600 + sector_num * 0x200
  nxt_addr = 0x800 + sector_num * 0x200

  org = ''
  if sector_num > 1:
    org = '    ORG     ${:<24x}; We are in the next sector\n'.format(org_addr)

  if sector_num < num_sectors:
    jmp = 'JMP     ${:<24x}; Skip to the next sector'.format(nxt_addr)
  else:
    jmp = 'JMP     LOOPBACK'

  return textwrap.dedent("""\
      
      {}    LEA     sSec{:03x},A3               ; Print the message just below
          CLR.L   D4                       ; Irrelevant; no CRLF in string
          MOVE.L  #kRow3,D5                ; Row for printed string
          MOVE.L  #kCol,D6                 ; Column to start printing from
          JSR     kConvRtd5                ; Call ROM string display routine
          {}
      sSec{:03x}:                             ; Data of message to print
          DC.B    'THIS STRING WAS LOADED FROM SECTOR {:03X}',0
      """).format(org, sector_num, jmp, sector_num, sector_num)


def main(FLAGS):
  FLAGS.output.write(_HEADER)
  for i in range(1, FLAGS.num_sectors + 1):
    FLAGS.output.write(_sector_message_code(i, FLAGS.num_sectors))
  FLAGS.output.write(_FOOTER)


if __name__ == '__main__':
  flags = _define_flags()
  FLAGS = flags.parse_args()
  main(FLAGS)
