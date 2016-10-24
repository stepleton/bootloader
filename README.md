Floppy disk bootloader for Lisa
===============================

This program is a floppy disk bootloader for Apple Lisa computers.

When you tell a Lisa to boot from a floppy disk, the Lisa's boot ROM loads the
floppy's first sector into RAM and attempts to execute it. It's up to the
loaded code (no more than 512 bytes!) to figure out what happens next.

If the loaded code is a bootloader like this one, what happens next is that
more sectors of the floppy are loaded into RAM, then executed.

This bootloader is capable of loading the contents of entire floppy disks (not
counting the first sector) into memory. It can also display short messages to
the user whilst loading.

A Python program is provided for preparing Disk Copy 4.2 disk images with the
bootloader in the first sector and arbitrary program data in remaining sectors.


Unlicense
---------

The floppy disk bootloader and any supporting programs, software libraries, and
documentation distributed alongside it are released into the public domain
without any warranty. See the UNLICENSE file for details.


Operational description
-----------------------

**Background:** When the Lisa boots, the 68000's 24-bit address space can be
divided as follows (assuming a Lisa with 1 MB of RAM):

- $000000 - $0007FF: System configuration and status information in RAM, and
  RAM space reserved for use by the boot ROM.
- $000800 - $0F7FFF: *Free RAM.*
- $0F8000 - $0FFFFF: Video memory, which occupies the highest 32K in RAM.
- $FC0000 - $FCFFFF: Memory-mapped I/O.
- $FE0000 - $FEFFFF: "Special I/O space".

(Address ranges not shown are unmapped/not in use.)

**Operational summary:** The bootloader loads disk sectors starting from the
second sector on the disk (side 0, track 0, sector 1) into a contiguous memory
region starting at $000800. Sectors are loaded consecutively within a track,
and tracks are accessed consecutively from track 0 on, first on one side of the
disk (side 0) and then the other (side 1) (if a double-sided disk like a Twiggy
or an 800k 3.5" floppy is present). Sector loading continues until a specially
formatted sector tag is encountered; the bootloader then computes a checksum of
the loaded sectors to verify data integrity and finally executes the loaded
data with a JMP to $000800.

**Details and features:**

- All Lisa floppy disks store 524 bytes per sector: 512 "data" bytes and 12
  "tag" bytes. Sector tags are usually used by other Lisa software to store
  filesystem and data recovery metadata. Tags are **not** loaded into the
  contiguous memory region starting at $000800.

- The bootloader will continue loading sector data into memory until it loads a
  a sector whose tag starting with the ASCII string "`Last out!\0`". ('`\0`'
  means the byte $00.)

- The last two bytes of the "`Last out!\0`" sector tag are a 16-bit checksum of
  all the sector data that the bootloader should have loaded from the disk into
  the contiguous memory region starting at $000800. The bootloader will compute
  its own checksum of the loaded data by iterating the following algorithm:

    - Add the next 16 bits of the loaded data to the checksum (which starts
      with the value $0000), using big-endian byte ordering.
    - Rotate the 16-bit checksum left by one bit.

  The bootloader will cause the ROM to display an error message if the computed
  checksum does not match the last two bytes of the sector tag. A decimal
  representation of the computed checksum is shown.

- All other tags are displayed to user on the screen, appearing in the "dialog
  box" displayed by the boot ROM as it begins booting from a disk. The tags
  appear to the right of the dialog box's hourglass icon and overwrite each
  other as each new sector is loaded. Disks that use the bootloader can use
  this facility to display loading progress messages to the user---bearing in
  mind that only the boot ROM can only show the ASCII characters A-Z, 0-9, and
  -./? (along with a blank, which corresponds to ASCII $20, or "space"). All
  other characters render as a white question mark on a black box.

  If no progress message is desired for a particular sector, a tag starting
  with '\0' will cause no new text to be displayed. Any text from a previous
  sector tag is preserved. (More generally, tags behave like null-terminated
  strings: the display of new characters stops as soon as '\0' is encountered.)
  To clear an old tag without showing new text, a tag containing all spaces
  (i.e. twelve $20 bytes) is recommended.

  A tag starting with "`Last out!\0`" is never shown to the user.

- The bootloader leaves ROM-reserved memory locations $000000-$0007FF untouched
  and does not alter the MMU setup, allowing the loaded program to make use of
  externally-callable routines and other resources in the Lisa's boot ROM.


Internals
---------

The bootloader comprises two stages: stage one, which moves the code for stage
two into the upper reaches of the Lisa's free memory; and stage two, which
loads, checks, and executes program data from the floppy disk.

The relocation performed by stage one is necessary because the Lisa boot ROM
copies the first sector of the floppy disk to memory addresses $020000-$0201FF.
Lisa systems with only a single 512K RAM board would not be able to store all
799 of the remaining sectors of a 400K disk in a contiguous memory region if
this first sector remained in that location. Instead, stage two code executes
from the highest possible address in the Lisa's free memory (i.e. just before
the video memory), providing sufficient unfragmented space for the entire
remainder of the disk.

Stage two iterates these four operations (all but the third are subroutines of
the bootloader):

1. `LOADSECTOR`: Load the sector referred to by the 32-bit sector identifier.
2. `MAYBEBOOT`: Does the sector tag mark the loaded sector as it the last
   sector? If so, check and run the loaded program code.
3. Increment the 32-bit sector identifier.
4. `VALIDATE`: Repeat 3 unless the 32-bit sector identifier is a valid
   identifier (that is, the side, track, and sector values in the identifier
   actually refer to real sides, tracks, and sectors that exist for that
   medium.)

The 32-bit sector identifier uses one byte to represent each of disk drive,
side, sector, and track as follows:

     MSB-> DdZzTtSs <-LSB

     Dd: Floppy drive; either $00 (upper drive) or $80 (lower drive).
     Zz: Disk side; either $00 or $01.
     Tt: Track, counting upwards from $00.
     Ss: Sector, counting upwards from $00.

(*Note:* This format is slightly different from the sector identifier format
used by the boot ROM's externally-callable floppy sector reading routine, which
uses the ordering DdZzSsTt, swapping the last two bytes.)

The `VALIDATE` subroutine's only required task is to indicate whether the side,
track, and sector values in the 32-bit sector identifier are within reasonable
ranges. For this reason, `VALIDATE` is media-specific: a `VALIDATE` designed
for Twiggy systems will not work on 3.5" systems and vice-versa, unless a more
intelligent (and space-consuming) "super-`VALIDATE`" compatible with both media
is made. (So far, only a 3.5"-compatible `VALIDATE` exists.)

The bootloader would function correctly if `VALIDATE` limited itself to
accepting or rejecting 32-bit sector identifiers; however, to save time that
would be wasted on iterating through contiguous integers that correspond to no
sector, `VALIDATE` is also permitted to advance any invalid argument up to (but
not beyond) the very last *invalid* 32-bit sector identifier just before the
(numerically) very next *valid* 32-bit sector identifier. This behaviour is
optional and may be added to or omitted from `VALIDATE` as dictated by code
space and execution time requirements.

It's fine for `VALIDATE` to allow the ROM to do error-handling for certain
accesses that ought to be unrecoverable; for example, attempting to read the
second side of a single-sided disk. (This allows the bootloader to handle 400K
and 800K 3.5" disks with the same `VALIDATE` implementation.)


Building the bootloader
-----------------------

The bootloader is written entirely in the dialect of 68000 macro assembly
supported by the open-source [EASy68K](http://www.easy68k.com/) development
environment and simulator. EASy68K is a Windows program which is well-behaved
on MacOS X, Linux, and similar systems with the use of the Wine compatibility
layer. Converting the bootloader's source code to be compatible with other
popular assemblers should not be too difficult. The bootloader itself uses no
macros.

EASy68K compiles the bootloader source code (`Bootloader.X68`) to a Motorola
S-record file (`Bootloader.S68` by default) with no changes required. A few
configuration options are present and documented in the source code.
Eventually, an option to configure whether the bootloader is built for Twiggy
or 3.5" systems may be available; for now, the bootloader only works for 3.5"
disks.

Once created, the S-record file may be converted into raw binary code with the
`EASyBIN.exe` program distributed with EASy68K, or with the `srec_cat` program
distributed with the [SRecord](http://srecord.sourceforge.net/) package for
UNIX systems, among many other options. An example invocation of `srec_cat` is:

    srec_cat Bootloader.S68 -offset -0x20000 -o Bootloader.bin -binary

The resulting binary file may be copied directly to the beginning of side 0,
track 0, sector 0 of your floppy disk or disk image.


Utility and test code
---------------------

The following programs and libraries are distributed with the bootloader:

### `dc42_build_bootable_disk.py` ###

This Python program assembles bootable Disk Copy 4.2 disk images for 400K,
800K, and Twiggy disks given a binary bootloader file, a binary program data
file, and (optionally) a text file containing strings to use as tags.

### `booted_test_gen.py` ###

This Python program builds EASy68K assembler program files for simple test
programs that can span multiple sectors of a floppy disk. The `-n` argument
allows you to specify how many sectors to use. Generated programs compile
out-of-the-box with EASy68K and can be converted to binary files with
`EASyBIN.exe` or the following `srec_cat` command:

    srec_cat program.S68 -offset -0x800 -o program.bin -binary

Generated programs contain small segments of code at 512-byte intervals, each
one printing a message to the string indicating which disk sector it was loaded
from.

### `FakeBootRom.X68` ###

This library is an incomplete collection of subroutines that mimic the
externally-callable Lisa boot ROM subroutines used by the bootloader.  These
subroutines are meant to be used in tandem with the `kEASy68K` flag in
`Bootloader.X68`. When this flag is nonzero, minimal conditional changes are
enabled that allow the bootloader to run in the EASy68K simulator (for example,
stage one's code relocation is skipped in lieu of placing stage two at $010000
to begin with), and the `FakeBootRom.X68` subroutines are used instead of the
corresponding Lisa boot ROM code.

The `FakeBootRom.X68` subroutines print information to the EASy68K I/O window
and construct artificial sector and tag data for reads from the floppy disk.

A bootloader compiled with the `kEASy68K` flag set to a nonzero value is not
usable as an actual bootloader for Lisa floppy disks.


Resources
---------

The following resources were used to develop this bootloader:

- [EASy68K](http://www.easy68k.com/): 68000 macro assembler, IDE, and simulator.
- [lisaem](http://lisaem.sunder.net/): Apple Lisa emulation for development and
  testing, as well as information (gleaned from the source code) about valid
  ranges for side/sector/track values.
- [Disk Copy 4.2 Format Specification](https://wiki.68kmla.org/index.php?title=DiskCopy_4.2_format_specification): DC42 format information.
- [Basic Lisa Utility manual](http://sigmasevensystems.com/blumanual.html):
  DC42 format information (esp. w.r.t. Twiggy and 800k 3.5" disk images).
- [Lisa Boot ROM Manual v1.3](http://bitsavers.informatik.uni-stuttgart.de/pdf/apple/lisa/Lisa_Boot_ROM_Manual_V1.3_Feb84.pdf):
  Lisa boot ROM documentation (nb: some information appears not to be current;
  refer to ROM source listing for more reliable information).
- [Lisa_Boot_ROM_Asm_Listing.TEXT](http://bitsavers.informatik.uni-stuttgart.de/pdf/apple/lisa/firmware/Lisa_Boot_ROM_Asm_Listing.TEXT):
  Authoritative information for boot ROM version H.
- [Apple Lisa Computer: Hardware Manual -- 1983 (with Errata)](http://lisa.sunder.net/LisaHardwareManual1983.pdf):
  Extensive details on Apple Lisa internals.


Revision history
----------------

20 October 2016: Initial release. Twiggy support is still absent.
(Tom Stepleton, stepleton@gmail.com, London)
