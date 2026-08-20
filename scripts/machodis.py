#!/usr/bin/env python3
"""Disassemble a Mach-O binary at a virtual address, including inside a FAT file.

WHY THIS EXISTS: a crash inside a shipping application is reported as base + offset, and the only
arbiter for what the code there actually does is the code itself. llvm-objdump reads Mach-O but
ignores --start-address on these files, and it will not select a slice of a universal binary for
disassembly either, so every attempt dumps the tail of __TEXT instead of the address asked for.

This does the address arithmetic by hand and hands the bytes to llvm-mc, which disassembles whatever
it is given:

    python3 scripts/machodis.py <binary> <vmaddr> [count]

Prints one instruction per line with its virtual address, so an address from a crash line can be
found in it directly.
"""
import struct
import subprocess
import sys

FAT_MAGIC = 0xCAFEBABE
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_X86_64 = 0x01000007
LC_SEGMENT_64 = 0x19


def slice_for_x86_64(data):
    """Return (offset, size) of the x86_64 slice, or (0, len) for a thin file."""
    magic = struct.unpack_from(">I", data, 0)[0]

    if magic not in (FAT_MAGIC,):
        return 0, len(data)

    count = struct.unpack_from(">I", data, 4)[0]
    for i in range(count):
        cputype, _sub, offset, size, _align = struct.unpack_from(">iiIII", data, 8 + i * 20)
        if cputype == CPU_TYPE_X86_64:
            return offset, size
    raise SystemExit("no x86_64 slice in this universal binary")


def text_mapping(data, base):
    """Every (vmaddr, vmsize, fileoff) of the slice's segments, so any address can be located."""
    magic, _cpu, _sub, _ft, ncmds, _size, _flags, _res = struct.unpack_from("<IiiIIIII", data, base)
    if magic != MH_MAGIC_64:
        raise SystemExit("not a 64-bit Mach-O at offset %d (magic %#x)" % (base, magic))

    segments = []
    offset = base + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == LC_SEGMENT_64:
            name = data[offset + 8:offset + 24].rstrip(b"\0").decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, offset + 24)
            segments.append((name, vmaddr, vmsize, fileoff, filesize))
        offset += cmdsize
    return segments


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)

    path = sys.argv[1]
    vmaddr = int(sys.argv[2], 0)
    count = int(sys.argv[3], 0) if len(sys.argv) > 3 else 96

    data = open(path, "rb").read()
    base, _size = slice_for_x86_64(data)

    for name, segvm, segsize, fileoff, filesize in text_mapping(data, base):
        if segvm <= vmaddr < segvm + segsize:
            offset = base + fileoff + (vmaddr - segvm)
            if offset + count > base + fileoff + filesize:
                count = base + fileoff + filesize - offset
            chunk = data[offset:offset + count]

            # objdump ON A RAW BINARY, not llvm-mc on hex. llvm-mc prints an unresolved rel32 as
            # "A" rather than a byte, so counting encoding bytes to advance the address undercounts
            # every call and every instruction after one lands at the wrong address. objdump does
            # the arithmetic itself and --adjust-vma puts the real addresses back.
            import tempfile

            with tempfile.NamedTemporaryFile(suffix=".bin") as raw:
                raw.write(chunk)
                raw.flush()
                out = subprocess.run(
                    ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64",
                     "--adjust-vma=%#x" % vmaddr, raw.name],
                    capture_output=True, text=True)

            for line in out.stdout.splitlines():
                if ":\t" in line and not line.startswith("Disassembly"):
                    print(line)
            if out.returncode != 0 and out.stderr.strip():
                print(out.stderr.strip(), file=sys.stderr)
            return
    raise SystemExit("%#x is not inside any segment of %s" % (vmaddr, path))


main()
