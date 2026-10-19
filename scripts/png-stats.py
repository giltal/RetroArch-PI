#!/usr/bin/env python3
"""png-stats.py SHOT.png [SHOT.png ...]

Per screenshot: mean luma, luma standard deviation, and the mean absolute
difference from the previous screenshot (on a 64x36 thumbnail), as one line
each:  mean <m> std <s> diff <d> <file>   (the file last: names have spaces)

Pure Python (zlib only), for the 8-bit RGB/RGBA non-interlaced PNGs RetroArch
writes, so game-test.sh needs nothing installed on the build host.
Used by scripts/game-test.sh to spot black screens (low mean and std) and
frozen pictures (diff ~0 between consecutive shots).
"""
import struct
import sys
import zlib


def read_png(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a PNG')
    p, idat, w = 8, b'', None
    while p < len(data):
        n, = struct.unpack('>I', data[p:p + 4])
        kind = data[p + 4:p + 8]
        body = data[p + 8:p + 8 + n]
        p += 12 + n
        if kind == b'IHDR':
            w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise ValueError('unsupported PNG (depth %d, type %d)' % (depth, ctype))
            bpp = 3 if ctype == 2 else 4
        elif kind == b'IDAT':
            idat += body
        elif kind == b'IEND':
            break
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    return w, h, bpp, rows


def thumb(path, tw=64, th=36):
    """Luma of a tw x th grid of sample points."""
    w, h, bpp, rows = read_png(path)
    out = []
    for ty in range(th):
        row = rows[min(h - 1, (ty * h + h // 2) // th)]
        for tx in range(tw):
            x = min(w - 1, (tx * w + w // 2) // tw) * bpp
            out.append((299 * row[x] + 587 * row[x + 1] + 114 * row[x + 2]) // 1000)
    return out


prev = None
for path in sys.argv[1:]:
    try:
        t = thumb(path)
    except Exception as e:  # report and go on: one bad file must not hide the rest
        print('error %s %s' % (e, path))
        prev = None
        continue
    mean = sum(t) / len(t)
    std = (sum((v - mean) ** 2 for v in t) / len(t)) ** 0.5
    diff = sum(abs(a - b) for a, b in zip(t, prev)) / len(t) if prev else -1
    print('mean %.1f std %.1f diff %.1f %s' % (mean, std, diff, path))
    prev = t
