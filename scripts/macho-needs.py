#!/usr/bin/env python3
"""What a Mach-O binary asks the loader for, and which of those this prefix has.

ONE ERROR AT A TIME IS THE SLOW WAY. A bundle that links forty frameworks fails on the first one
missing, gets that one added, and fails on the next; each round is a build and a run. The load
commands list every dependency up front, so the whole gap can be seen at once and the work ordered
by what actually matters.

Handles FAT binaries by walking every architecture and reporting the x86_64 slice, which is the one
this port runs. Follows nothing: a dependency of a dependency is a separate question, and asking it
here would hide which of them the application itself named.

    scripts/macho-needs.py <binary> [prefix] [runtime]
"""
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
CPU_TYPE_X86_64 = 0x01000007


def slices(data):
    """(offset, cputype) for each architecture in the file, thin or fat."""
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (FAT_MAGIC, FAT_CIGAM):
        count = struct.unpack(">I", data[4:8])[0]
        out = []
        for i in range(count):
            base = 8 + i * 20
            cputype, _sub, offset, _size, _align = struct.unpack(">iiIII", data[base:base + 20])
            out.append((offset, cputype))
        return out
    return [(0, CPU_TYPE_X86_64)]


def dylibs(data, offset):
    magic = struct.unpack("<I", data[offset:offset + 4])[0]
    if magic not in (MH_MAGIC_64, MH_CIGAM_64):
        return []
    ncmds = struct.unpack("<I", data[offset + 16:offset + 20])[0]
    pos = offset + 32
    out = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[pos:pos + 8])
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB):
            name_off = struct.unpack("<I", data[pos + 8:pos + 12])[0]
            raw = data[pos + name_off:pos + cmdsize]
            name = raw.split(b"\0", 1)[0].decode("utf-8", "replace")
            out.append((name, cmd == LC_LOAD_WEAK_DYLIB))
        pos += cmdsize
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    prefix = sys.argv[2] if len(sys.argv) > 2 else "/tmp/cider-appkit-1000/prefix"
    runtime = sys.argv[3] if len(sys.argv) > 3 else "/tmp/cider-appkit-1000/rt/libexec/cider"

    with open(path, "rb") as handle:
        data = handle.read()

    wanted = []
    for offset, cputype in slices(data):
        if cputype != CPU_TYPE_X86_64:
            continue
        wanted = dylibs(data, offset)
        break

    import os

    # @rpath AND @executable_path ARE NOT PATHS, and treating them as if they were turns every
    # framework an application ships INSIDE ITS OWN BUNDLE into a missing one. iTerm2 has ten of
    # those, and a report that names them alongside SwiftUI is worse than no report: it buries the
    # four that matter under six that are already there.
    exe_dir = os.path.dirname(os.path.abspath(path))
    bundle_roots = [exe_dir, os.path.join(exe_dir, "..", "Frameworks")]

    def resolve(name):
        if name.startswith("@executable_path/"):
            return [os.path.normpath(os.path.join(exe_dir, name[len("@executable_path/"):]))]
        if name.startswith("@loader_path/"):
            return [os.path.normpath(os.path.join(exe_dir, name[len("@loader_path/"):]))]
        if name.startswith("@rpath/"):
            tail = name[len("@rpath/"):]
            return [os.path.normpath(os.path.join(root, tail)) for root in bundle_roots]
        # The guest sees a union of the prefix over the runtime tree, so either one counts.
        return [root + name for root in (prefix, runtime)]

    def is_macho(candidate):
        """EXISTING IS NOT THE SAME AS LOADABLE.

        The swift dylibs in this tree are 131 byte git-lfs POINTER FILES locally and real Mach-O
        only in the nix pin, so a check that asks whether the path exists reports a runtime that is
        entirely there and dyld disagrees. Read the magic."""
        try:
            with open(candidate, "rb") as handle:
                head = handle.read(4)
        except OSError:
            return False
        return head in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
                        b"\xbe\xba\xfe\xca")

    missing, weak_missing, present, bundled, notmacho = [], [], [], [], []
    for name, weak in wanted:
        candidates = resolve(name)
        found = any(os.path.exists(candidate) for candidate in candidates)
        loadable = any(is_macho(candidate) for candidate in candidates)
        if found and not loadable:
            notmacho.append(name)
        elif loadable:
            (bundled if name.startswith("@") else present).append(name)
        elif weak:
            weak_missing.append(name)
        else:
            missing.append(name)

    print(f"needs={len(wanted)} present={len(present)} in-bundle={len(bundled)} "
          f"missing={len(missing)} not-macho={len(notmacho)} weak-missing={len(weak_missing)}")
    for name in notmacho:
        print(f"NOTMACHO {name}")
    for name in missing:
        print(f"MISSING  {name}")
    for name in weak_missing:
        print(f"weak     {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
