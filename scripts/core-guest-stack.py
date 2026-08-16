#!/usr/bin/env python3
"""Resolve a guest crash stack from a core dump, which nothing else here can do.

A guest process is `mldr` with Mach-O images mapped into it, so systemd-coredump and gdb both
print `n/a` for every frame: they look for ELF modules and there are none at those addresses.
The mapping information IS in the core, in the NT_FILE note that the kernel writes for every
file-backed mapping, and mldr maps its images from files. This reads that note, turns each stack
address into a file plus an offset, and asks llvm-symbolizer for a name.

THE PATHS IN THE NOTE ARE GUEST PATHS. mldr opens its images through the container's view, so
the note records /Applications/... and /usr/lib/..., which do not exist on the host. Pass one
--root per tree to search: the prefix and the runtime libexec directory between them cover
everything a guest maps.

Usage:
    scripts/core-guest-stack.py [--root DIR]... [--threads] <core> [<address> ...]

--threads lists EVERY thread and where it stopped, which is the question systemd-coredump cannot
answer: it prints one thread, and a crash in any other is invisible.

With no addresses it reads them from stdin, one per line, which is what pasting a
`coredumpctl info` stack does.

WHY THE OFFSET IS NOT ADDRESS MINUS START. NT_FILE records the file offset of each mapping, so
the offset within the file is `addr - start + file_ofs`. Getting that wrong yields plausible
symbol names from the wrong part of the binary, which is worse than none.
"""
import struct
import subprocess
import sys

NT_FILE = 0x46494C45
NT_PRSTATUS = 1

# elf_prstatus on x86-64: the register block starts at 112, and rip is register 16 of the 27 in
# user_regs_struct. Spelled out because an off-by-one here yields a plausible wrong address.
PRSTATUS_REG_OFFSET = 112
RIP_INDEX = 16
RSP_INDEX = 19


_CORE_CACHE = {}


def _core_bytes(path):
    """The core, read once. These are hundreds of megabytes and both note walks want them."""
    if path not in _CORE_CACHE:
        with open(path, "rb") as f:
            _CORE_CACHE[path] = f.read()
    return _CORE_CACHE[path]


def read_nt_file(path):
    """[(start, end, file_offset, filename)] from the core's NT_FILE note."""
    data = _core_bytes(path)
    if data[:4] != b"\x7fELF" or data[4] != 2:
        raise SystemExit(f"{path}: not a 64-bit ELF core")

    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)

    notes = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from("<I", data, off)
        if p_type != 4:  # PT_NOTE
            continue
        p_offset, = struct.unpack_from("<Q", data, off + 0x08)
        p_filesz, = struct.unpack_from("<Q", data, off + 0x20)
        notes.append((p_offset, p_filesz))

    for note_off, note_size in notes:
        pos = note_off
        end = note_off + note_size
        while pos + 12 <= end:
            n_namesz, n_descsz, n_type = struct.unpack_from("<III", data, pos)
            pos += 12
            name_end = pos + ((n_namesz + 3) & ~3)
            desc = data[name_end:name_end + n_descsz]
            pos = name_end + ((n_descsz + 3) & ~3)
            if n_type != NT_FILE:
                continue
            count, page_size = struct.unpack_from("<QQ", desc, 0)
            entries = []
            for j in range(count):
                start, stop, file_ofs = struct.unpack_from("<QQQ", desc, 16 + j * 24)
                entries.append([start, stop, file_ofs * page_size, None])
            # The filenames follow the triples, NUL terminated, in the same order.
            names = desc[16 + count * 24:].split(b"\x00")
            for j in range(count):
                if j < len(names):
                    entries[j][3] = names[j].decode("utf-8", "replace")
            return [tuple(e) for e in entries]
    return []


def read_thread_pcs(path):
    """[(pid, rip, rsp)] from every NT_PRSTATUS note, which is one per thread.

    THIS IS THE PART NOTHING ELSE GIVES YOU. systemd-coredump prints one thread and gdb needs
    symbols it cannot find, so a crash in any thread but the one they picked is invisible.
    """
    data = _core_bytes(path)
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)
    out = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from("<I", data, off)
        if p_type != 4:
            continue
        p_offset, = struct.unpack_from("<Q", data, off + 0x08)
        p_filesz, = struct.unpack_from("<Q", data, off + 0x20)
        pos, end = p_offset, p_offset + p_filesz
        while pos + 12 <= end:
            n_namesz, n_descsz, n_type = struct.unpack_from("<III", data, pos)
            pos += 12
            name_end = pos + ((n_namesz + 3) & ~3)
            desc = data[name_end:name_end + n_descsz]
            pos = name_end + ((n_descsz + 3) & ~3)
            if n_type != NT_PRSTATUS or len(desc) < PRSTATUS_REG_OFFSET + 27 * 8:
                continue
            pid, = struct.unpack_from("<i", desc, 32)
            rip, = struct.unpack_from("<Q", desc, PRSTATUS_REG_OFFSET + RIP_INDEX * 8)
            rsp, = struct.unpack_from("<Q", desc, PRSTATUS_REG_OFFSET + RSP_INDEX * 8)
            out.append((pid, rip, rsp))
    return out


# One nm pass per FILE, not per address. libmergedlo.dylib has 441,307 symbols and a thread list
# asks about the same handful of files repeatedly; without this the tool takes longer than the
# crash did.
_SYMBOL_CACHE = {}


def _symbol_table(path):
    if path in _SYMBOL_CACHE:
        return _SYMBOL_CACHE[path]
    syms = []
    print(f"  reading symbols from {path.rsplit('/', 1)[-1]}", file=sys.stderr)
    try:
        r = subprocess.run(["llvm-nm", "--defined-only", "--numeric-sort", path],
                           capture_output=True, text=True, timeout=180)
        for line in r.stdout.splitlines():
            parts = line.split()
            if len(parts) != 3:
                continue
            try:
                syms.append((int(parts[0], 16), parts[2]))
            except ValueError:
                pass
    except Exception:
        pass
    syms.sort()
    # The addresses are kept as their own list because bisect needs a sequence of keys, and
    # rebuilding it per lookup is what made a thread list slower than the crash.
    _SYMBOL_CACHE[path] = (syms, [s[0] for s in syms])
    return _SYMBOL_CACHE[path]


def symbolize(path, offset):
    """A symbol name for one file offset, or None. Falls back to the nearest defined symbol,
    because a Mach-O built without debug info still has a symbol table."""
    try:
        r = subprocess.run(
            ["llvm-symbolizer", f"--obj={path}", "--functions=short", "--demangle", hex(offset)],
            capture_output=True, text=True, timeout=60,
        )
        first = r.stdout.strip().splitlines()
        if first and first[0] not in ("??", ""):
            return first[0]
    except Exception:
        pass
    syms, keys = _symbol_table(path)
    if not syms:
        return None
    import bisect
    i = bisect.bisect_right(keys, offset) - 1
    if i < 0:
        return None
    addr, name = syms[i]
    return f"{name} (+{offset - addr})"


def resolve_host_path(name, roots):
    """The host file for a guest path, or None. Tried in the order the roots were given."""
    import os
    if os.path.exists(name):
        return name
    for root in roots:
        candidate = os.path.join(root, name.lstrip("/"))
        if os.path.exists(candidate):
            return candidate
    return None


def main():
    args = sys.argv[1:]
    roots = []
    while args and args[0] == "--root":
        if len(args) < 2:
            raise SystemExit("--root needs a directory")
        roots.append(args[1])
        args = args[2:]
    if not args:
        raise SystemExit(__doc__)
    threads_only = False
    if args and args[0] == "--threads":
        threads_only = True
        args = args[1:]
    core = args[0] if args else None
    if core is None:
        raise SystemExit(__doc__)
    addrs = args[1:]
    if not addrs:
        addrs = [w for line in sys.stdin for w in line.split() if w.startswith("0x")]

    maps = read_nt_file(core)
    if threads_only:
        threads = read_thread_pcs(core)
        print(f"{len(threads)} threads", file=sys.stderr)
        for pid, rip, rsp in threads:
            hit = next((m for m in maps if m[0] <= rip < m[1]), None)
            if not hit:
                print(f"tid {pid}  {hex(rip)}  <not in any file-backed mapping>  rsp={hex(rsp)}")
                continue
            start, _stop, file_ofs, name = hit
            offset = rip - start + file_ofs
            host = resolve_host_path(name, roots)
            sym = symbolize(host, offset) if host else None
            print(f"tid {pid}  {name.rsplit('/', 1)[-1]}+{hex(offset)}  {sym or '??'}")
        return
    if not maps:
        raise SystemExit("no NT_FILE note in the core, so nothing can be resolved")
    print(f"{len(maps)} file-backed mappings in the core", file=sys.stderr)

    for a in addrs:
        addr = int(a, 16)
        hit = next((m for m in maps if m[0] <= addr < m[1]), None)
        if not hit:
            print(f"{a}  <not in any file-backed mapping>")
            continue
        start, _stop, file_ofs, name = hit
        offset = addr - start + file_ofs
        host = resolve_host_path(name, roots)
        sym = symbolize(host, offset) if host else None
        short = name.rsplit("/", 1)[-1]
        note = "" if host else "  <no host file: pass --root>"
        print(f"{a}  {short}+{hex(offset)}  {sym or '??'}{note}")


if __name__ == "__main__":
    main()
