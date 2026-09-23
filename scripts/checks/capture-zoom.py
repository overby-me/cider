#!/usr/bin/env python3
"""Crop a region of a capture, magnify it, and print its ink as characters.

WHY THIS EXISTS. The standing instruction is to LOOK at every capture, and at 11 points that is not
possible: CMake drew every descender three rows too low for weeks and the capture was passed as
CONTENT every time, because at 1:1 the words merely look slightly odd. Worse, looking harder makes
it worse rather than better. The first write up of that defect said the letters were SUBSTITUTED, p
by D and g by q and y by v, which is what an eye does with a shape it cannot resolve. Magnified 14
times and printed as ink, the glyphs turned out to be the right size and in the wrong place, which
is a different defect with a different cause.

So this is not a convenience. It is the difference between reading a capture and guessing at it.

    scripts/checks/capture-zoom.py shot.png --at 232,450 --size 58x22            ink map
    scripts/checks/capture-zoom.py shot.png --at 200,448 --size 260x20 --out z.png --scale 6

The ink map is the exact answer: one character per pixel, # for dark, + for mid, . for light, with
the row number down the side, so the vertical extent of a letter is a number rather than an
impression. The PNG is for when the shape matters more than the rows.

There is no PIL here on purpose; this reads PNGs the same way capture-is-black.py does.
"""
import argparse
import struct
import sys
import zlib


def read_png(path):
    """Return (width, height, channels, pixel bytes) for a non-interlaced 8-bit PNG."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat = 8, bytearray()
    width = height = depth = colour = interlace = None
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
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if filt == 1:
                line[i] = (line[i] + a) & 255
            elif filt == 2:
                line[i] = (line[i] + b) & 255
            elif filt == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif filt == 4:
                pred = a + b - c
                pa, pb, pc = abs(pred - a), abs(pred - b), abs(pred - c)
                best = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + best) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return width, height, channels, out


def grey(px, channels, index):
    if channels >= 3:
        return (px[index] + px[index + 1] + px[index + 2]) // 3
    return px[index]


def write_png(path, rows, width, height):
    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body
                + struct.pack(">I", zlib.crc32(kind + body)))

    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    data = b"\x89PNG\r\n\x1a\n"
    data += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(raw, 9))
    data += chunk(b"IEND", b"")
    open(path, "wb").write(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("capture")
    ap.add_argument("--at", required=True, help="top left of the crop as x,y")
    ap.add_argument("--size", required=True, help="crop size as WxH")
    ap.add_argument("--scale", type=int, default=8, help="magnification for --out")
    ap.add_argument("--out", help="write a magnified PNG here instead of an ink map")
    ap.add_argument("--dark", type=int, default=100, help="grey level below which ink is #")
    ap.add_argument("--mid", type=int, default=190, help="grey level below which ink is +")
    args = ap.parse_args()

    x0, y0 = (int(v) for v in args.at.split(","))
    w, h = (int(v) for v in args.size.lower().split("x"))
    W, H, C, px = read_png(args.capture)
    if x0 < 0 or y0 < 0 or x0 + w > W or y0 + h > H:
        print("crop %d,%d %dx%d is outside the %dx%d capture" % (x0, y0, w, h, W, H))
        return 2

    if args.out:
        ow, oh = w * args.scale, h * args.scale
        rows = []
        for y in range(oh):
            sy = y0 + y // args.scale
            row = bytearray()
            for x in range(ow):
                sx = x0 + x // args.scale
                i = (sy * W + sx) * C
                row += bytes(px[i:i + 3]) if C >= 3 else bytes([px[i]] * 3)
            rows.append(row)
        write_png(args.out, rows, ow, oh)
        print("wrote %s %dx%d from %s %dx%d" % (args.out, ow, oh, args.capture, W, H))
        return 0

    print("%s rows y=%d..%d cols x=%d..%d" % (args.capture, y0, y0 + h - 1, x0, x0 + w - 1))
    for y in range(y0, y0 + h):
        line = ""
        for x in range(x0, x0 + w):
            v = grey(px, C, (y * W + x) * C)
            line += "#" if v < args.dark else ("+" if v < args.mid else ".")
        print("%4d %s" % (y, line))
    return 0


if __name__ == "__main__":
    sys.exit(main())
