#!/usr/bin/env python3
"""Read a compiled NIBArchive and print its objects, keys and values.

WHY THIS EXISTS: a nib is the arbiter for what an application actually asked for. Reasoning about
our decoder cannot settle a question the archive answers directly, and one round of that cost a
whole boolean polarity: NSNIBArchiveUnarchiver had value type 4 as true and 5 as false, the format
has them the other way round, and every boolean in every nib in this system decoded inverted.

ONE KEY CANNOT SETTLE A POLARITY, THE WHOLE ARCHIVE CAN. Dump every boolean and ask which reading
describes a nib a person would author: 21 controls enabled and 23 not refusing first responder, or
every control in the window disabled.

    python3 scripts/nibdump.py <path/to/keyedobjects-NNNNNN.nib> [class name substring]

Format: the magic "NIBArchive", ten little-endian uint32 counts and offsets, then four tables.
VARINTS ARE BACKWARDS from every other format in this tree: seven bits per byte, low bits first,
and the byte with its high bit SET is the LAST one rather than a continuation.
"""
import struct, sys

class R:
    def __init__(s, d, o=0): s.d, s.o = d, o
    def u32(s):
        v = struct.unpack_from("<I", s.d, s.o)[0]; s.o += 4; return v
    def var(s):
        v = 0; sh = 0
        while True:
            b = s.d[s.o]; s.o += 1
            v |= (b & 0x7F) << sh; sh += 7
            if b & 0x80: return v
    def raw(s, n):
        v = s.d[s.o:s.o+n]; s.o += n; return v

def parse(path):
    d = open(path, 'rb').read()
    assert d[:10] == b'NIBArchive'
    h = struct.unpack_from("<10I", d, 10)
    _, _, objc, objo, keyc, keyo, valc, valo, clsc, clso = h
    r = R(d, keyo); keys = [r.raw(r.var()).decode('utf8', 'replace') for _ in range(keyc)]
    r = R(d, clso); clss = []
    for _ in range(clsc):
        n = r.var(); extra = r.var(); r.raw(extra * 4)
        clss.append(r.raw(n).decode('utf8', 'replace').rstrip('\0'))
    r = R(d, valo); vals = []
    for _ in range(valc):
        k = r.var(); t = d[r.o]; r.o += 1
        if t == 0: v = struct.unpack_from("<b", d, r.o)[0]; r.o += 1
        elif t == 1: v = struct.unpack_from("<h", d, r.o)[0]; r.o += 2
        elif t == 2: v = struct.unpack_from("<i", d, r.o)[0]; r.o += 4
        elif t == 3: v = struct.unpack_from("<q", d, r.o)[0]; r.o += 8
        elif t == 4: v = False
        elif t == 5: v = True
        elif t == 6: v = struct.unpack_from("<f", d, r.o)[0]; r.o += 4
        elif t == 7: v = struct.unpack_from("<d", d, r.o)[0]; r.o += 8
        elif t == 8: v = r.raw(r.var())
        elif t == 9: v = None
        elif t == 10: v = ("@obj", r.u32())
        else: raise SystemExit("value type %d at %d" % (t, r.o))
        vals.append((keys[k], v))
    r = R(d, objo); objs = []
    for _ in range(objc):
        c = r.var(); vi = r.var(); vc = r.var()
        objs.append((clss[c], vals[vi:vi+vc]))
    return objs

objs = parse(sys.argv[1])
want = sys.argv[2] if len(sys.argv) > 2 else None
for i, (c, kv) in enumerate(objs):
    if want and want not in c: continue
    print("#%d %s" % (i, c))
    for k, v in kv:
        print("     %-28s %r" % (k, v))
