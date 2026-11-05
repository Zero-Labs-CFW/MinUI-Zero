#!/usr/bin/env python3
"""Structural check of an AArch64 ELF64 shared library: every PT_LOAD segment and the section header table lie inside
the file. A truncated copy (an interrupted cp) fails this even when its first bytes look right (Codex review
2026-11-05). Usage: elfcheck.py FILE [REQUIRED-STRING ...]; exit 0 if sound."""
import struct
import sys


def sound(data, required=()):
    if len(data) < 64 or data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        return False
    e_type, e_machine = struct.unpack_from('<HH', data, 16)
    e_phoff, e_shoff = struct.unpack_from('<QQ', data, 32)
    e_phentsize, e_phnum, e_shentsize, e_shnum = struct.unpack_from('<HHHH', data, 54)
    if e_type != 3 or e_machine != 183 or e_phentsize != 56 or not e_phnum:
        return False
    if e_phoff + e_phnum * e_phentsize > len(data) or (e_shnum and e_shoff + e_shnum * e_shentsize > len(data)):
        return False
    for i in range(e_phnum):
        p_type, _flags, p_offset, _va, _pa, p_filesz = struct.unpack_from('<IIQQQQ', data, e_phoff + i * e_phentsize)
        if p_type == 1 and p_offset + p_filesz > len(data):
            return False
    return all(r in data for r in required)


if __name__ == '__main__':
    sys.exit(0 if sound(open(sys.argv[1], 'rb').read(), [a.encode() for a in sys.argv[2:]]) else 1)
