#!/usr/bin/env python3
"""Screen flip: assert the flipped render is an EXACT 180 rotation.

The SPI cabinet's flip switch (SW1:1) is read by the game, which sets reg_1a
bit 0; the video hardware mirrors on that bit. MAME captures the bit and drops
it, so there is no reference image to check a flipped frame against -- see
PLAN.md.

This checks the implementation against ITSELF instead, which is stronger for
the mirror arithmetic than any reference would be: render the SAME frozen
capture twice, once with flip off and once with flip on, and require

    flipped[x, y] == plain[W-1-x, H-1-y]

for every pixel. Both sides are the same RTL over identical state, so there is
no tolerance to argue about -- 320 and 240 are even and both are multiples of 8
and 16, so no centre pixel and no character cell straddles the mirror. Any
mismatch is a bug.

Usage:  check_flip.py <plain.bin> <flipped.bin>   (raw ARGB32, 320x240)
"""
import struct
import sys

W, H = 320, 240


def load(path):
    data = open(path, "rb").read()
    want = W * H * 4
    if len(data) != want:
        sys.exit("%s: %d bytes, expected %d (raw ARGB32 %dx%d)"
                 % (path, len(data), want, W, H))
    return struct.unpack("<%dI" % (W * H), data)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    plain, flipped = load(sys.argv[1]), load(sys.argv[2])

    bad = [(x, y) for y in range(H) for x in range(W)
           if flipped[y * W + x] != plain[(H - 1 - y) * W + (W - 1 - x)]]

    # A frame with no structure cannot fail this test, so it must not be
    # allowed to pass it either: a uniform image is a 180 rotation of itself.
    # Two captures of a flat background were what made an earlier round of this
    # look green while the mirror was doing nothing.
    distinct = len(set(plain))
    if distinct < 8:
        sys.exit("FAIL: reference frame has only %d distinct colours -- too "
                 "uniform to prove anything. Capture a scene with detail."
                 % distinct)

    if bad:
        print("FAIL: %d/%d pixels are not the 180 rotation (%.3f%%)"
              % (len(bad), W * H, 100.0 * len(bad) / (W * H)))
        for x, y in bad[:8]:
            print("   x=%3d y=%3d  expected %06X  got %06X"
                  % (x, y, plain[(H - 1 - y) * W + (W - 1 - x)] & 0xFFFFFF,
                     flipped[y * W + x] & 0xFFFFFF))
        # A uniform (dx, dy) offset means the mirror CENTRES are wrong rather
        # than the mirror itself -- a different and much easier fix, so say so.
        best = None
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                m = sum(1 for y in range(H) for x in range(W)
                        if 0 <= W - 1 - x + dx < W and 0 <= H - 1 - y + dy < H
                        and flipped[y * W + x] ==
                            plain[(H - 1 - y + dy) * W + (W - 1 - x + dx)])
                if best is None or m > best[0]:
                    best = (m, dx, dy)
        if best[1] or best[2]:
            print("   best fit is dx=%d dy=%d (%.1f%%) -- that is a CENTRE "
                  "error, not a broken mirror" % (best[1], best[2],
                                                  100.0 * best[0] / (W * H)))
        return 1

    print("PASS: flipped frame is an exact 180 rotation, all %d pixels "
          "(%d distinct colours in the reference)" % (W * H, distinct))
    return 0


if __name__ == "__main__":
    sys.exit(main())
