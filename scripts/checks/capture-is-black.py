#!/usr/bin/env python3
"""Say whether a capture is uniformly black, so a gate cannot pass one silently.

WHY THIS EXISTS. roster-sweep.sh and roster-input.sh print a byte count and ask a human to LOOK.
A byte count does not separate a rendered window from a black one: task #256 saw four of seven
captures come back black while the applications were demonstrably alive and doing the work, and
the only reason it did not read as a regression is that every case was re-run by hand. A gate that
cannot tell those apart is a gate that lies.

Exit 0 if the image has visible content, 1 if it is uniformly black, 2 if it cannot be read. The
last case matters: a decoder that fails must not be mistaken for a pass.

Prints one line either way, because a check that is silent on success cannot be distinguished from
a check that never ran.
"""
import struct
import sys
import zlib


def read_png(path):
    """Return (width, height, channels, pixel bytes) for a non-interlaced 8-bit PNG."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")

    pos = 8
    width = height = depth = colour = interlace = None
    idat = bytearray()
    while pos + 8 <= len(data):
        length, kind = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break

    if width is None:
        raise ValueError("no IHDR")
    if depth != 8:
        raise ValueError("bit depth %d is not supported" % depth)
    if interlace:
        raise ValueError("interlaced PNG is not supported")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    if channels is None:
        raise ValueError("colour type %d is not supported" % colour)

    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(height * stride)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        filt = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        # The five PNG filters, undone in place. Each needs the reconstructed line, not the raw one.
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            x = line[i]
            if filt == 1:
                x += a
            elif filt == 2:
                x += b
            elif filt == 3:
                x += (a + b) >> 1
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                x += a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = x & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return width, height, channels, out


def main():
    if len(sys.argv) < 2:
        print("usage: capture-is-black.py <capture.png>")
        return 2
    path = sys.argv[1]
    try:
        width, height, channels, pixels = read_png(path)
    except Exception as exc:
        print("UNREADABLE %s: %s" % (path, exc))
        return 2

    # Alpha is ignored on purpose: a fully transparent capture still reads as black on screen.
    colour_channels = 1 if channels in (1, 2) else 3
    step = channels
    brightest = 0
    lit = 0
    for i in range(0, len(pixels), step):
        v = max(pixels[i:i + colour_channels])
        if v > brightest:
            brightest = v
        if v > 16:
            lit += 1

    total = width * height
    share = (lit * 100.0) / total if total else 0.0
    if lit == 0:
        print("BLACK %s %dx%d brightest=%d lit=0" % (path, width, height, brightest))
        return 1
    print("CONTENT %s %dx%d brightest=%d lit=%d of %d (%.1f percent)"
          % (path, width, height, brightest, lit, total, share))
    return 0


sys.exit(main())
