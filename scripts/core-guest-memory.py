#!/usr/bin/env python3
"""Read guest memory out of a core file, at an address the fault registers named.

core-guest-stack.py answers "where did it stop"; this answers "what was actually IN the object".
A garbage pointer is ambiguous on its own: a C++ object whose first word points into a loaded
image is alive and merely holds a bad field, while one whose first word is a float or a small
integer was never that kind of object at all.

    scripts/core-guest-memory.py [--words N] <core> <address> [<address> ...]

Each word is printed as hex, as a signed integer, as an IEEE double, and, when it falls inside a
mapped region the core describes, with the name of the file mapped there. That last column is the
one that decides "real object" versus "not an object".
"""

import struct
import sys

PT_LOAD = 1
PT_NOTE = 4
NT_FILE = 0x46494C45


def _phdrs(blob):
    if blob[:4] != b"\x7fELF" or blob[4] != 2:
        raise SystemExit("not a 64-bit ELF core")
    e_phoff, = struct.unpack_from("<Q", blob, 32)
    e_phentsize, e_phnum = struct.unpack_from("<HH", blob, 54)
    out = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from("<I", blob, off)
        p_offset, p_vaddr, _p_paddr, p_filesz, p_memsz = struct.unpack_from("<5Q", blob, off + 8)
        out.append((p_type, p_offset, p_vaddr, p_filesz, p_memsz))
    return out


def _mapped_files(blob, phdrs):
    """NT_FILE names every file-backed mapping: (start, end, path)."""
    for p_type, p_offset, _vaddr, p_filesz, _memsz in phdrs:
        if p_type != PT_NOTE:
            continue
        pos, end = p_offset, p_offset + p_filesz
        while pos + 12 <= end:
            n_namesz, n_descsz, n_type = struct.unpack_from("<3I", blob, pos)
            desc = pos + 12 + ((n_namesz + 3) & ~3)
            if n_type == NT_FILE:
                count, _psize = struct.unpack_from("<2Q", blob, desc)
                triples = desc + 16
                names = triples + count * 24
                out, at = [], names
                for i in range(count):
                    start, stop, _pgoff = struct.unpack_from("<3Q", blob, triples + i * 24)
                    z = blob.index(b"\0", at)
                    out.append((start, stop, blob[at:z].decode("utf-8", "replace")))
                    at = z + 1
                return out
            pos = desc + ((n_descsz + 3) & ~3)
    return []


def _read(blob, phdrs, addr, length):
    for p_type, p_offset, p_vaddr, p_filesz, _memsz in phdrs:
        if p_type == PT_LOAD and p_vaddr <= addr < p_vaddr + p_filesz:
            off = p_offset + (addr - p_vaddr)
            avail = min(length, p_filesz - (addr - p_vaddr))
            return blob[off:off + avail]
    return b""


def _owner(files, addr):
    for start, stop, path in files:
        if start <= addr < stop:
            return path.rsplit("/", 1)[-1]
    return ""


def main():
    args = sys.argv[1:]
    words = 16
    if args and args[0] == "--words":
        words = int(args[1])
        args = args[2:]
    if len(args) < 2:
        raise SystemExit(__doc__)

    blob = open(args[0], "rb").read()
    phdrs = _phdrs(blob)
    files = _mapped_files(blob, phdrs)

    for spec in args[1:]:
        addr = int(spec, 16 if spec.lower().startswith("0x") else 10)
        owner = _owner(files, addr)
        print(f"{addr:#018x}  {owner or 'anonymous or absent from NT_FILE'}")
        data = _read(blob, phdrs, addr, words * 8)
        if not data:
            print("  NOT IN THE CORE: unmapped, or a region the dump skipped")
            continue
        for i in range(0, len(data) - 7, 8):
            w, = struct.unpack_from("<Q", data, i)
            d, = struct.unpack_from("<d", data, i)
            s = w - (1 << 64) if w >> 63 else w
            points = _owner(files, w)
            note = f"  -> {points}" if points else ""
            print(f"  +{i:#05x}  {w:#018x}  {s:>20}  {d:>24.6g}{note}")
        print()


if __name__ == "__main__":
    main()
