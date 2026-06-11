#!/usr/bin/env python3
"""Compare two Intel HEX files as decoded byte images (record layout ignored)."""
import sys


def decode(path):
    mem = {}
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line or not line.startswith(":"):
                continue
            data = bytes.fromhex(line[1:])
            count, addr, rtype = data[0], (data[1] << 8) | data[2], data[3]
            if sum(data) & 0xFF != 0:
                sys.exit(f"{path}:{lineno}: bad checksum")
            if rtype == 1:
                break
            if rtype != 0:
                sys.exit(f"{path}:{lineno}: unsupported record type {rtype}")
            for i, b in enumerate(data[4 : 4 + count]):
                mem[addr + i] = b
    return mem


a, b = decode(sys.argv[1]), decode(sys.argv[2])
keys = sorted(set(a) | set(b))
diffs = 0
for k in keys:
    va, vb = a.get(k), b.get(k)
    if va != vb:
        diffs += 1
        if diffs <= 20:
            fa = f"{va:02X}" if va is not None else "--"
            fb = f"{vb:02X}" if vb is not None else "--"
            print(f"  {k:04X}: {sys.argv[1]}={fa} {sys.argv[2]}={fb}")
if diffs:
    print(f"{diffs} differing byte(s) of {len(keys)}")
    sys.exit(1)
print(f"identical: {len(keys)} bytes")
