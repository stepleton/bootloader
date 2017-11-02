#!/usr/bin/python

from __future__ import absolute_import
from __future__ import division
from __future__ import print_function

import argparse
import re
import struct
import sys
import warnings


def _define_flags():
  """Defines an `ArgumentParser` for command-line flags used by this program."""
  flags = argparse.ArgumentParser(
      description='Build a bootable Apple Lisa .dc42 disk image')

  flags.add_argument('program',
                     help='68000 program to load+run (starting address $800)',
                     type=argparse.FileType('rb'))

  flags.add_argument('-o', '--output',
                     help='Where to write the resulting disk image',
                     type=argparse.FileType('wb'),
                     default='-')

  flags.add_argument('-b', '--bootloader',
                     help='"Stepleton" bootloader for loading --program',
                     type=argparse.FileType('rb'),
                     default='Bootloader.bin')

  flags.add_argument('-t', '--tags_file',
                     help='Text file listing loading display tags',
                     type=argparse.FileType('r'))

  flags.add_argument('-f', '--floppy',
                     help='Target variety of floppy media',
                     choices=['sony_400k', 'sony_800k', 'twiggy'],
                     default='sony_400k')

  return flags


# Constants obtained from:
# http://sigmasevensystems.com/blumanual.html
# https://wiki.68kmla.org/index.php?title=DiskCopy_4.2_format_specification

_DATA_SIZE = {'sony_400k': 0x64000,
              'sony_800k': 0xc8000,
              'twiggy': 0xd4c00}

_TAG_SIZE = {'sony_400k': 0x2580,
             'sony_800k': 0x4b00,
             'twiggy': 0x4fc8}

_DISK_TYPE = {'sony_400k': '\x00',  # 400k GCR "CLV" SS-DD disk.
              'sony_800k': '\x01',  # 800k GCR "CLV" DS-DD disk.
              'twiggy': '\x54'}     # BLU's disk code for Twiggy.

_FORMAT_BYTE = {'sony_400k': '\x02',  # Single-sided; "Mac 400k" interleaving.
                'sony_800k': '\x22',  # Double-sided; "Mac 400k" interleaving.
                'twiggy': '\x01'}     # BLU's format code for Twiggy.

_DC42_MAGIC = '\x01\x00'  # BLU "magic number" string.

# For the loose compatibility checks in _check_bootloader_compatibility: A
# "Stepleton" bootloader is determined to be built for a certain floppy media
# if it contains all of the binary strings paired with a corresponding
# _BOOTLOADER_SIGNATURES key. Meanwhile, _BOOTLOADER_COMPATIBILITIES[k] is the
# set of bootloader build types that are notionally suitable for use with
# floppy media type k.

_BOOTLOADER_SIGNATURES = {
    'sony_400k': ('\x4f\x07', '\x7f\xff\x00\x00', '\x0f\x1f\x2f\x3f\xff'),
    'sony_800k': ('\x4f\x07', '\x7f\xfe\x00\x00', '\x0f\x1f\x2f\x3f\xff'),
    'twiggy': (
        '\x2d\x0e', '\x7f\xfe\x00\x00', '\x03\x0a\x10\x16\x1c\x22\x29\xff'),
}

_BOOTLOADER_COMPATIBILITIES = {'sony_400k': {'sony_400k', 'sony_800k'},
                               'sony_800k': {'sony_800k'},
                               'twiggy': {'twiggy'}}


def main(FLAGS):
  # No tags_file listed? We supply a boring stand-in.
  if FLAGS.tags_file is None: FLAGS.tags_file = DefaultTags()

  # Load bootloader. If less than 512 bytes, pad out with zeros.
  bootloader_data, _ = _read_binary_data(FLAGS.bootloader, 0x200, 'bootloader')

  # Warn user if bootloader and floppy type may not be compatible.
  _check_bootloader_compatibility(bootloader_data, FLAGS.floppy)

  # Load program data; if smaller than the disk data capacity minus 512 (for the
  # sector already used by the bootloader), pad it out with zeros.
  program_data, program_size = _read_binary_data(
      FLAGS.program, _DATA_SIZE[FLAGS.floppy] - 0x200, 'program')

  # Compute the checksum that the bootloader uses to verify program integrity.
  program_checksum = _compute_program_checksum(program_data, program_size)

  # Final assembly of sector data: concatenate bootloader and program data.
  data = bootloader_data + program_data

  # Load and assemble tag data; note calculation of the program data's checksum.
  tags = _assemble_tags(
      FLAGS.tags_file, program_checksum, program_size, _TAG_SIZE[FLAGS.floppy])

  # Permute data and tag ordering for Sony 800k DS-DD disks.
  if FLAGS.floppy == 'sony_800k':
    data, tags = _permute_data_and_tags_for_sony_800k(data, tags)

  # Construct all parts of the .dc42 file:
  dc42_parts = []

  ## Disk image name ##
  # Like all Lisa images, this disk is named "-not a Macintosh disk-".
  # 64-byte Pascal string; we use NUL padding.
  dc42_parts.append(struct.pack('64p', '-not a Macintosh disk-'))

  ## Data size ##
  dc42_parts.append(struct.pack('>I', _DATA_SIZE[FLAGS.floppy]))

  ## Tag size ##
  dc42_parts.append(struct.pack('>I', _TAG_SIZE[FLAGS.floppy]))

  ## Data checksum ##
  dc42_parts.append(_compute_dc42_checksum(data))

  ## Tag checksum ##
  # Tag checksum calculation skips the first twelve bytes of tag data.
  dc42_parts.append(_compute_dc42_checksum(tags[12:]))

  ## Disk type ##
  dc42_parts.append(_DISK_TYPE[FLAGS.floppy])

  ## Format byte ##
  dc42_parts.append(_FORMAT_BYTE[FLAGS.floppy])

  ## DC42 "magic number" ##
  dc42_parts.append(_DC42_MAGIC)

  ## Disk image data ##
  dc42_parts.append(data)

  ## Disk image tag data ##
  dc42_parts.append(tags)

  # Write .dc42 disk image.
  FLAGS.output.write(''.join(dc42_parts))


def _read_binary_data(fp, size, name):
  """Read zero-padded binary data from a file.

  Attempts to read `size+1` bytes from filehandle `fp`. If 0 or more than `size`
  bytes are read, raises an IOError. Data of any other size is returned to the
  caller, followed by enough zero padding to yield `size` bytes exactly.

  Args:
    fp: file object to read from.
    size: number of bytes to read from `fp`.
    name: name for data being loaded (used for exception messages).

  Returns: a 2-tuple whose members are the data loaded from `fp` (zero-padded)
      and the original size of the data in bytes prior to zero-padding.

  Raises:
    IOError: if the file is empty or contains more than size bytes.
  """
  # Read data.
  data = fp.read(size + 1)
  if len(data) == 0:
    raise IOError('failed to read any {} data'.format(name))
  if len(data) > size:
    raise IOError('{} data file was larger than {} bytes'.format(name, size))

  # Zero-pad and return with original size.
  return data + ('\x00' * (size - len(data))), len(data)


def _assemble_tags(fp, checksum, program_size, tagdata_size):
  """Assemble sector tags required by a "Stepleton" bootloader.

  Constructs tags for all sectors of the disk image. All but the last of the
  sectors allocated to program data have tags loaded from `fp` via
  `_read_next_tag`; the final tag is composed of a special marker string plus
  a two-byte checksum that a "Stepleton" bootloader uses to verify program
  integrity.

  Args:
    fp: file object to read tags from.
    checksum: two-byte program checksum mentioned above. Computed in this
        program by `_compute_program_checksum`.
    program_size: size of the program the bootloader should load, in bytes.
    tagdata_size: total size of all sector tags; or, number of sectors * 12.

  Returns: all sector tags as one contiguous `tagdata_size` chunk.
  """
  # Tag data begins with a tag for the bootloader's sector. The only important
  # part is the $AAAA at offset 4, which marks this sector as bootable.
  tags = ['Booo\xaa\xaaoooot!']

  # All sectors but the last one used to hold the program data get a tag loaded
  # from the tag file.
  while program_size > 0x200:
    program_size -= 0x200
    tags.append(_read_next_tag(fp))

  # The final sector holding the program data has the special end-marking tag,
  # comprising the string "Last out!", a NUL byte, and the two-byte checksum.
  tags.append('Last out!\x00' + checksum)

  # The tags for the remaining sectors are all 0s, obtained by padding.
  tagdata = ''.join(tags)
  return tagdata + ('\x00' * (tagdata_size - len(tagdata)))


def _read_next_tag(fp):
  """Read the next tag from the tag file.

  Attempts to read the next line from the text file opened as `fp` (using the
  `readline` file object method---quack quack!) for use as a sector tag. A
  "Stepleton" bootloader prints all but the last sector's tag to the screen,
  making the tags useful progress indicators. Tags can be up to twelve bytes
  long and may only contain the characters A..Z, 0..9, and "./-?" (quotes not
  included), which are all that's defined in the ROM. Any tag with fewer than
  twelve characters will be padded with spaces.

  Args:
    fp: file object to read tags from.

  Returns: 12-byte tag data string for use as a sector tag.

  Raises:
    IOError: if end of file is encountered.
    RuntimeError: if a tag uses characters not found in the Lisa Boot ROM.
  """
  # Read "raw" line and clip away CR/CRLF/LF.
  tag = fp.readline()
  if tag == '':
    raise IOError('ran out of tags in the tag file.')
  tag = tag.rstrip('\r\n')

  # Scan line for chars not in the ROM.
  if not re.match('[0-9A-Z ./-?]*$', tag):
    raise RuntimeError('tag {} has chars not found in the ROM'.format(tag))

  # Warn if the tag is too long and truncate to 12 bytes.
  if len(tag) > 12:
    warnings.warn('tag {} will be clipped to 12 bytes'.format(tag), UserWarning)
    tag = tag[:12]

  # Space-pad and return.
  return tag + (' ' * (12 - len(tag)))


def _compute_dc42_checksum(data):
  """Compute checksum DC42 uses to verify sector and tag data integrity.

  Args:
    data: data to compute a checksum for.

  Returns: a 32-bit (big endian) checksum as a 2-byte string.
  """

  def addl_rorl(uint, csum):
    """Add `uint` to `csum`; 32-bit truncate; 32-bit rotate right one bit."""
    csum += uint        # add uint
    csum &= 0xffffffff  # truncate
    rbit = csum & 0x1   # rotate part 1 (save low-order bit)
    csum >>= 1          # rotate part 2 (shift right)
    csum += rbit << 31  # rotate part 3 (prepend old low-order bit)
    return csum

  # Loop over all two-byte words in the data and include them in the checksum.
  checksum = 0
  for word_bytes in [data[i:i+2] for i in range(0, len(data), 2)]:
    word = struct.unpack('>H', word_bytes)[0]  # big endian word bytes to native
    checksum = addl_rorl(word, checksum)       # add to checksum

  # return result as a big-endian 32-bit word.
  return struct.pack('>I', checksum)


def _compute_program_checksum(data, program_size):
  """Compute checksum a "Stepleton" bootloader uses to verify program integrity.

  This disk image creation tool directs the bootloader to load only as many
  sectors as are required to fit the program. The bootloader will then compute
  a checksum for just these sectors. This function computes what the correct
  checksum should be.

  Args:
    data: data whose first `program_size` bytes are the program being loaded
        by the bootloader.
    program_size: size of the program being loaded by the bootloader in bytes.

  Returns: a 16-bit (big endian) checksum as a 2-byte string.
  """

  def addw_rolw(word, csum):
    """Add `word` to `csum`; truncate to 16 bits; 16-bit rotate left one bit."""
    csum += word        # add word
    csum &= 0xffff      # truncate
    csum <<= 1          # rotate part 1 (shift left)
    csum += csum >> 16  # rotate part 2 (add old higher-order bit)
    csum &= 0xffff      # rotate part 3 (mask to 16 bits)
    return csum

  # The checksum is only for sectors containing program data. To figure out how
  # many bytes that is, we round program_size up to the nearest 512.
  num_bytes = (program_size & ~0x1ff) + (0x200 if program_size & 0x1ff else 0)

  # Loop over all two-byte words in the data and include them in the checksum.
  checksum = 0
  for word_bytes in [data[i:i+2] for i in range(0, num_bytes, 2)]:
    word = struct.unpack('>H', word_bytes)[0]  # big endian word bytes to native
    checksum = addw_rolw(word, checksum)       # add to checksum

  # Return result as a big-endian 16-bit word.
  return struct.pack('>H', checksum)


def _permute_data_and_tags_for_sony_800k(data, tags):
  """Put sector and tag data in the correct order for Sony 800k .dc42 images.

  In Sony 800k .dc42 disk image files, the data from both sides of the disk
  are interleaved on a track-by-track basis. (That is, the disk image contains
  the sectors from side 1 track 0, followed by those from side 2 track 0,
  followed by side 1 track 1, then side 2 track 1, then side 1 track 2, side 2
  track 2, and so on. The tag data are arranged similarly.)

  In contrast, when this program marshals sector and track data, it assumes that
  the data and tags are arranged in track order for side 1, followed by track
  order for side 2. (This is correct for BLU Twiggy image files, and trivially
  correct for single-sided Sony 400k images.)

  This function permutes the contiguous sector and tag data in the arguments
  to obtain the side-interleaved sector and tag data required for a Sony 800k
  .dc42 disk image file.

  Args:
    data: 800k of side-contiguous sector data.
    tags: 19.2k of side-contiguous tag data.

  Returns: a 2-tuple whose elements are the sector and tag data permuted into
      the correct .dc42 disk image ordering.
  """

  # The number of sectors in track t on a 400k disk (or on one side of an 800k
  # disk) can be referenced in this table as track_sizes[t]:
  track_sizes = 0x10*[0xC] + 0x10*[0xB] + 0x10*[0xA] + 0x10*[0x9] + 0x10*[0x8]

  # This is a pretty silly (O(N^2)) way to compute the cumulative sum of a
  # list, but it's adequate for our needs, and best of all, very short.
  cumsum = lambda l: [sum(l[:n+1]) for n in range(len(l))]

  # Derived from track_sizes: bounds for the sector and tag data in `data` and
  # `tags` associated with track t on the first/only side of an 800k/400k disk.
  track_data_bounds = cumsum([0] + [0x200 * s for s in track_sizes])
  track_data_begins = track_data_bounds[:-1]
  track_data_ends   = track_data_bounds[1:]

  track_tags_bounds = cumsum([0] + [0xc * s for s in track_sizes])
  track_tags_begins = track_tags_bounds[:-1]
  track_tags_ends   = track_tags_bounds[1:]

  # Riffle tracks from the first and second half of `data` to obtain the sector
  # data as it should appear in the dc42 file for a double-sided disk.
  permuted_data = []
  for s1_track_begin, s1_track_end in zip(track_data_begins, track_data_ends):
    s2_track_begin = s1_track_begin + 0x64000
    s2_track_end   = s1_track_end   + 0x64000
    permuted_data.append(data[s1_track_begin:s1_track_end])
    permuted_data.append(data[s2_track_begin:s2_track_end])

  # Likewise for tag data.
  permuted_tags = []
  for s1_track_begin, s1_track_end in zip(track_tags_begins, track_tags_ends):
    s2_track_begin = s1_track_begin + 0x2580
    s2_track_end   = s1_track_end   + 0x2580
    permuted_tags.append(tags[s1_track_begin:s1_track_end])
    permuted_tags.append(tags[s2_track_begin:s2_track_end])

  # Merge and return all permuted tags.
  data = ''.join(permuted_data)
  tags = ''.join(permuted_tags)
  return data, tags


def _check_bootloader_compatibility(bootloader_data, floppy):
  """Perform loose checks on bootloader and floppy media compatibility.

  Attempts to determine the type of media `bootloader_data` was compiled for,
  and issues warnings if `floppy` appears not to be compatible with that
  kind of media. See also notes above the definitions of
  _BOOTLOADER_SIGNATURES and _BOOTLOADER_COMPATIBILITIES.

  Args:
    bootloader_data: binary bootloader data.
    floppy: string identifier for target floppy media.
  """
  # First, try to detect the kind of floppy media the bootloader was built for.
  # Warn and give up if we can't identify one unique kind of media.
  all_bootloader_media = []
  for bootloader_media, signatures in _BOOTLOADER_SIGNATURES.items():
    if all(signature in bootloader_data for signature in signatures):
      all_bootloader_media.append(bootloader_media)

  if len(all_bootloader_media) != 1:
    warnings.warn('bootloader appears to be of an unknown type', UserWarning)
    return

  bootloader_media = all_bootloader_media[0]

  # Warn if the bootloader media type isn't ideal for the floppy media type.
  if bootloader_media not in _BOOTLOADER_COMPATIBILITIES.get(floppy, set()):
    warnings.warn('a bootloader built for {} media may not be suitable for '
                  '{} media; proceed with caution'.format(
                      bootloader_media, floppy), UserWarning)


class DefaultTags(object):
  """Boring "tags file" stand-in object.

  Tags "read" from this file object stand-in will display boring messages to
  the user during loading, e.g.
     READ 0.5K
     READ 1.0K
     READ 1.5K
  and so on.
  """

  def __init__(self):
    self._sectors_read = 0

  def readline(self):
    self._sectors_read += 1
    return 'READ {}K\n'.format(0.5 * self._sectors_read)


if __name__ == '__main__':
  flags = _define_flags()
  FLAGS = flags.parse_args()
  main(FLAGS)
