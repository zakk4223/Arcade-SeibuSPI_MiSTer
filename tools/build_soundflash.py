#!/usr/bin/env python3
"""
Build an SPI cartridge game's sample-flash image offline, the way the game's own
386 updater builds it at first boot.

rdft's flash payload was a plain concatenation of two ROMs, so an MRA could
assemble it. rdft2's is not: 1.5 MB is a verbatim copy of pcm.u0217 and the
remaining half megabyte is DECOMPRESSED from sound1.u0222. This reproduces both,
bit-for-bit against the image MAME's flash devices end up holding.

The codec, read off the 386 at 0x2A1D20, is byte-pair encoding (Philip Gage's
BPE, Dr. Dobb's 1994) layered over DPCM: BPE expands each input byte through a
per-block 256-entry pair table, and every leaf byte is a signed delta added to a
running 8-bit accumulator. See PLAN.md "the rdft2 sound-flash codec".

Nothing here is a magic number: the copy lengths, source addresses and byte-lane
modes are read out of the job table in the game's own program image.

Usage:
    tools/build_soundflash.py rdft2.zip out.bin [--verify] [--decoded-out FILE]

--decoded-out writes just the decoded jobs' output, which is what the RTL
decoder in rtl/spi_rom_decode.sv is checked against (sim/tb_rom_decode.cpp).
"""

import sys
import zipfile

# The 386's view. The program ROMs are mapped at PRG_BASE and the sound01 window
# at S01_BASE, so a job's source address decodes to one or the other.
PRG_BASE = 0x00200000
S01_BASE = 0x00A00000

FLASH_SIZE = 0x200000  # two E28F008SA, 1 MB each, in lockstep

# Per game: the 12-byte job table the updater walks, and the region stamp it
# writes to flash[0..3]. Both are addresses in the 386 map; the table address
# comes from the struct the updater is called with (rdft2: at 0x00201B91).
GAMES = {
    "rdft2": {
        "prg": ["prg0.tun", "prg1.bin", "prg2.bin", "prg3.bin"],
        "job_table": 0x00201B55,
        "stamp": 0x003FFFFC,
        # sound01 assembly: each ROM is spread over the 32-bit region, `lanes`
        # bytes out of every 4, which is what the fetcher's lane mode undoes.
        "sound01": [("pcm.u0217", 0x000000, 2), ("sound1.u0222", 0x800000, 1)],
        "sha256": "c0da4614a8d07a7bce24b7712b756435f2c5fd1ef74dc44333657afdecc6c67c",
    },
}


def load_prg(zf, names):
    """Interleave the four byte-wide program ROMs into the 386's 32-bit image."""
    parts = [zf.read(n) for n in names]
    n = len(parts[0])
    out = bytearray(n * 4)
    for lane, p in enumerate(parts):
        out[lane::4] = p
    return bytes(out)


def load_sound01(zf, layout):
    """Assemble the sound01 window: ROMs scattered across the 32-bit region."""
    region = bytearray(0xA00000)
    for name, base, lanes in layout:
        data = zf.read(name)
        for i, b in enumerate(data):
            group, lane = divmod(i, lanes)
            region[base + group * 4 + lane] = b
    return bytes(region)


class Fetcher:
    """The 386's byte fetcher at 0x2A1C34.

    The sound01 region is 32 bits wide but a given ROM only occupies some of the
    byte lanes, so the fetcher reads a dword and hands out `lanes` bytes of it
    before stepping to the next one. The 0x400000 wrap is the bank skip.
    """

    def __init__(self, region, addr, lane_mode):
        self.region = region
        self.esi = addr - S01_BASE
        self.mode = lane_mode
        self.cache = 0

    def __call__(self):
        if self.esi % 4 == 0:
            o = self.esi
            self.cache = int.from_bytes(self.region[o:o + 4], "little")
        al = self.cache & 0xFF
        self.cache >>= 8
        self.esi += 1
        if self.mode == 0:
            self.esi += 3
        elif self.mode == 1 and self.esi % 2 == 0:
            self.esi += 2
        if self.esi >= 0x400000 and self.esi % 0x200000 == 0:
            self.esi += 0x200000
        return al


def expand(fetch, out):
    """The decompressor at 0x2A1D20: BPE over DPCM.

    Stream layout, all fields as the 386 reads them:

        u16 nblocks             little-endian
        per block:
          pair table            256 entries of (left, right); left[i] == i means
                                the entry is unused and carries no right byte.
                                A count byte >= 0x80 skips (count - 127) entries;
                                otherwise it introduces count + 1 entries.
          u16 size              BIG-endian, input bytes in this block
          size bytes            each expanded through the pair table

    Every leaf byte is a delta: out[n] = out[n-1] + leaf, 8-bit wrapping. The
    accumulator is zeroed once per call, not per block.
    """
    acc = 0
    nblocks = fetch() | (fetch() << 8)
    while nblocks:
        nblocks -= 1
        left = list(range(256))
        right = [0] * 256
        i = 0
        while i != 256:
            count = fetch()
            if count & 0x80:
                i += count - 127
                count = 0
            if i == 256:
                break
            for _ in range(count + 1):
                b = fetch()
                if left[i] != b:  # left[i] == i is the "unused" encoding
                    left[i] = b
                    right[i] = fetch()
                i += 1
        size = (fetch() << 8) | fetch()
        stack = []
        while stack or size:
            if stack:
                al = stack.pop()
            else:
                size -= 1
                al = fetch()
            while left[al] != al:
                stack.append(right[al])
                al = left[al]
            acc = (acc + al) & 0xFF
            out.append(acc)


def build(zf, game, decoded_out=None):
    g = GAMES[game]
    decoded = bytearray()
    prg = load_prg(zf, g["prg"])
    region = load_sound01(zf, g["sound01"])

    def prg_dword(addr):
        o = addr - PRG_BASE
        return int.from_bytes(prg[o:o + 4], "little")

    img = bytearray(b"\xFF" * FLASH_SIZE)
    o = g["stamp"] - PRG_BASE
    img[0:4] = prg[o:o + 4]  # region stamp; the updater writes it last
    pos = 4

    job = g["job_table"]
    while prg_dword(job) != 0xFFFFFFFF:
        src = prg_dword(job)
        length = prg_dword(job + 4)
        lane_mode = prg[job - PRG_BASE + 8]
        verbatim = prg[job - PRG_BASE + 9]
        fetch = Fetcher(region, src, lane_mode)
        kind = "copy" if verbatim else "decode"
        start = pos
        if verbatim:
            for _ in range(length):
                img[pos] = fetch()
                pos += 1
        else:
            out = bytearray()
            expand(fetch, out)
            decoded += out
            img[pos:pos + len(out)] = out
            pos += len(out)
            if len(out) != length:
                print(f"  warning: job declared {length} bytes, decoded {len(out)}",
                      file=sys.stderr)
        print(f"  {kind:6s} src={src:#09x} lane={lane_mode} "
              f"-> flash[{start:#x}..{pos - 1:#x}] ({pos - start} bytes)",
              file=sys.stderr)
        job += 0xC

    print(f"  payload ends at {pos - 1:#x}, rest is erased 0xFF", file=sys.stderr)
    if decoded_out:
        with open(decoded_out, "wb") as f:
            f.write(decoded)
        print(f"  decoded output -> {decoded_out} ({len(decoded)} bytes)", file=sys.stderr)
    return bytes(img)


def main():
    argv = sys.argv[1:]
    decoded_out = None
    if "--decoded-out" in argv:
        k = argv.index("--decoded-out")
        decoded_out = argv[k + 1]
        del argv[k:k + 2]
    args = [a for a in argv if not a.startswith("--")]
    verify = "--verify" in argv
    if len(args) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src, dst = args

    with zipfile.ZipFile(src) as zf:
        names = set(zf.namelist())
        game = next((g for g, v in GAMES.items()
                     if set(v["prg"]) <= names), None)
        if game is None:
            print(f"{src}: no supported game (have: {sorted(GAMES)})", file=sys.stderr)
            return 1
        print(f"{game}:", file=sys.stderr)
        img = build(zf, game, decoded_out)

    if verify:
        import hashlib
        got = hashlib.sha256(img).hexdigest()
        want = GAMES[game]["sha256"]
        print(f"  sha256 {got} {'OK' if got == want else 'MISMATCH, want ' + want}",
              file=sys.stderr)
        if got != want:
            return 1

    with open(dst, "wb") as f:
        f.write(img)
    return 0


if __name__ == "__main__":
    sys.exit(main())
