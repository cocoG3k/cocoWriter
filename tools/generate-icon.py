#!/usr/bin/env python3
"""Draw the neutral cocoWriter icon with Python's standard library."""
from pathlib import Path
import struct
import zlib

size = 1024
def rounded(x, y, left, top, right, bottom, radius):
    if not (left <= x < right and top <= y < bottom):
        return False
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2

rows = bytearray()
for y in range(size):
    rows.append(0)
    for x in range(size):
        color = (25, 42, 35)
        if rounded(x, y, 258, 176, 790, 846, 40):
            color = (153, 199, 178)
        if rounded(x, y, 210, 140, 746, 802, 40):
            color = (247, 248, 239)
        if rounded(x, y, 295, 275, 660, 303, 14):
            color = (48, 84, 64)
        if rounded(x, y, 295, 385, 610, 411, 13) or rounded(x, y, 295, 492, 660, 518, 13) or rounded(x, y, 295, 599, 548, 625, 13):
            color = (112, 156, 133)
        rows.extend(color)

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">2I5B", size, size, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")
output = Path(__file__).resolve().parent.parent / "ios/cocoWriter/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
output.write_bytes(png)
print("Created", output.relative_to(output.parents[4]))
