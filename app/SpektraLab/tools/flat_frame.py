#!/usr/bin/env python3
"""flat_frame.py OUT.png [WIDTH HEIGHT CODE] -- a flat grey sRGB picture (default 3000 x 2000, code 118), with no
content for a centroid or an edge to be weighted by: `--masks-check`'s flat geometry case (MacMaskFlatCheck.swift).
Written with the standard library only (zlib), so no package is needed."""
import struct
import sys
import zlib


def main() -> int:
    out = sys.argv[1]
    w, h, code = (int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])) if len(sys.argv) > 4 else (3000, 2000, 118)
    row = b"\x00" + bytes([code]) * (3 * w)
    raw = row * h

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"sRGB", b"\x00") + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    with open(out, "wb") as f:
        f.write(png)
    return 0


if __name__ == "__main__":
    sys.exit(main())
