#!/usr/bin/env python3
"""Nearest preceding symbol for a file offset in a Mach-O.

The host nm cannot read Mach-O and reports zero symbols, which reads as a stripped binary; this
parses LC_SYMTAB directly. Offsets come from a core's NT_FILE mapping (address minus mapping
start), so they are FILE offsets and have to go through the segment table to become vmaddrs.
"""
import struct, sys, bisect

def load(path):
    d = open(path, 'rb').read()
    magic = struct.unpack_from('<I', d, 0)[0]
    assert magic in (0xfeedfacf,), f"not a 64-bit little-endian Mach-O: {magic:#x}"
    ncmds = struct.unpack_from('<I', d, 16)[0]
    off = 32
    segs, syms = [], []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', d, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            name = d[off+8:off+24].rstrip(b'\0').decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, off+24)
            segs.append((name, vmaddr, vmsize, fileoff, filesize))
        elif cmd == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', d, off+8)
            strs = d[stroff:stroff+strsize]
            for i in range(nsyms):
                o = symoff + i*16
                n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from('<IBBHQ', d, o)
                if n_value == 0 or (n_type & 0x0e) != 0x0e:  # N_SECT only
                    continue
                end = strs.find(b'\0', n_strx)
                syms.append((n_value, strs[n_strx:end].decode('utf-8', 'replace')))
        off += cmdsize
    syms.sort()
    return segs, syms

def file_off_to_vmaddr(segs, fo):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if fileoff <= fo < fileoff + filesize:
            return vmaddr + (fo - fileoff)
    return None

def main():
    path = sys.argv[1]
    segs, syms = load(path)
    addrs = [a for a, _ in syms]
    for arg in sys.argv[2:]:
        fo = int(arg, 16)
        va = file_off_to_vmaddr(segs, fo)
        if va is None:
            print(f"+0x{fo:x}  (offset outside every segment)")
            continue
        i = bisect.bisect_right(addrs, va) - 1
        if i < 0:
            print(f"+0x{fo:x}  (before the first symbol)")
        else:
            a, n = syms[i]
            print(f"+0x{fo:x}  {n} +0x{va-a:x}")

main()
