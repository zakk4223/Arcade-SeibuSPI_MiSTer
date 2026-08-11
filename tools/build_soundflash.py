#!/usr/bin/env python3
"""Build an SPI cartridge game's sample-flash image offline, the way the game's own
386 updater builds it at first boot.

The SXX2C mainboard has no sample ROM: the YMF271 reads two E28F008SA flash chips
that the game programs itself during the several-minute "techno music" ritual at
first boot. There is no dumped pre-flashed image, so a pre-flashed MRA needs the
image derived from the cartridge ROMs. This does that, bit-for-bit against the
image MAME's flash devices end up holding.

Every SXX2C title drives the same table-driven updater, but in three generations
(PLAN.md "the updater comes in three generations"):

  gen A  senkyu / batlball / ejanhs / viprp1   decode-only, byte 8 is an address
                                               STRIDE, no verbatim mode exists
  gen B0 rdft                                  copy-only, byte 8 is a lane-mode
                                               enum, no decoder exists
  gen B1 rdft2 / rfjet                         both; byte 9 picks per job

The codec, where there is one, is byte pair encoding (Philip Gage's BPE, Dr.
Dobb's 1994) layered over DPCM, and it is bit-identical across generations: BPE
expands each input byte through a per-block 256-entry pair table, and every leaf
byte is a delta added to a running 8-bit accumulator.

Nothing here is a magic number: the copy lengths, source addresses and fetch
modes are read out of the job table in the game's own program image, and the
table address is the one the updater is handed in its argument struct.

Usage:
    tools/build_soundflash.py <set>.zip out.bin [--set NAME] [--verify]
                              [--decoded-out FILE]

--set picks a clone inside a merged parent zip (e.g. --set batlball senkyu.zip).
--decoded-out writes just the decoded jobs' output, which is what the RTL decoder
in rtl/spi_rom_decode.sv is checked against (sim/tb_rom_decode.cpp).
"""

import sys
import zipfile

# The 386's view. The program ROMs are mapped at PRG_BASE and the sound01 window
# at S01_BASE, so a job's source address decodes to one or the other.
PRG_BASE = 0x00200000
PRG_SIZE = 0x00200000
S01_BASE = 0x00A00000
S01_SIZE = 0x00A00000

FLASH_SIZE = 0x200000  # two E28F008SA, 1 MB each, addressed as one linear space
FLASH_START = 4        # the updater opens the session at 4; 0..3 is the stamp

# Per game, all read out of the program image rather than guessed:
#   prg        the four byte-wide program ROMs, and where MAME loads them
#   job_table  the updater's 12-byte job records, from the argument struct
#   stamp      386 address of the region stamp, written to flash[0..3] LAST
#   sound01    which ROM sits at which region base, and how many of every four
#              byte lanes it occupies
#   gen        which updater generation drives the job records (see above)
GAMES = {
    "senkyu": {
        "prg": (["fb_1.211", "fb_2.212", "fb_3.210", "fb_4.29"], 0x100000),
        "job_table": 0x00302324, "stamp": 0x003FFFFC, "gen": "A",
        "sound01": [("fb_pcm-1.215", 0x000000, 1), ("fb_7.216", 0x800000, 1)],
        "sha256": "dd081ebad5534f72d97d815ba9ab3e9a2281c70cd017efada262a04659edd528",
    },
    "batlball": {
        "prg": (["1.211", "2.212", "3.210", "4.029"], 0x100000),
        # same jobs as senkyu to the byte; only the region stamp and the table's
        # own address differ, which is what a region clone looks like here
        "job_table": 0x00302290, "stamp": 0x003FFFFC, "gen": "A",
        "sound01": [("fb_pcm-1.215", 0x000000, 1), ("fb_7.216", 0x800000, 1)],
        "sha256": "09c4b1ec253324f80d2c5763f6e037e2136c8c8f4a1fc55701edbaa80e0d3181",
    },
    "ejanhs": {
        "prg": (["ejan3_1.211", "ejan3_2.212", "ejan3_3.210", "ejan3_4.29"], 0x100000),
        "job_table": 0x003026AC, "stamp": 0x003FFFFC, "gen": "A",
        "sound01": [("ej3_pcm1.215", 0x000000, 1), ("ejan3_7.216", 0x800000, 1)],
        "sha256": "7693933a13108ffc0b283a64d8f3347f76dd28b0771d71f380e140496936341f",
    },
    "viprp1": {
        "prg": (["seibu1.211", "seibu2.212", "seibu3.210", "seibu4.29"], 0x000000),
        "job_table": 0x00200760, "stamp": 0x003FFFFC, "gen": "A",
        # the only game whose second job reads the PROGRAM ROM: viprp1 has no
        # second sound ROM, so its compressed tail is embedded in the 386 image
        "sound01": [("v_pcm.215", 0x000000, 1)],
        "sha256": "274495438f7acc2593c57441d7eb02d1371eb0e275e7ef3ca55e7774fa71a44e",
    },
    "rdft": {
        "prg": (["raiden-fi_prg0_121196.u0211", "raiden-fi_prg1_121196.u0212",
                 "raiden-fi_prg2_121196.u0210", "raiden-fi_prg3_121196.u029"], 0x000000),
        "job_table": 0x0020174D, "stamp": 0x003FFFFC, "gen": "B0",
        "sound01": [("gun_dogs_pcm.u0217", 0x000000, 2), ("seibu_8.u0216", 0x800000, 1)],
        "sha256": "659df8c6a964c109465cc6d927f1565c57beae5d9d86b88b09e5976b57befee1",
    },
    "rdft2": {
        "prg": (["prg0.tun", "prg1.bin", "prg2.bin", "prg3.bin"], 0x000000),
        "job_table": 0x00201B55, "stamp": 0x003FFFFC, "gen": "B1",
        "sound01": [("pcm.u0217", 0x000000, 2), ("sound1.u0222", 0x800000, 1)],
        "sha256": "c0da4614a8d07a7bce24b7712b756435f2c5fd1ef74dc44333657afdecc6c67c",
    },
    "rfjet": {
        "prg": (["prg0.u0211", "prg1.u0212", "prg2.u0221", "prg3.u0220"], 0x000000),
        "job_table": 0x00203597, "stamp": 0x003FFFFC, "gen": "B1",
        "sound01": [("pcm-d.u0227", 0x000000, 2), ("sound1.u0222", 0x800000, 1)],
        "sha256": "fb02c059e7ee1b0a26c97ccb5d6eb60eaaa1c48a7e65c76c2d2628475cb4e621",
    },
}


def zread(zf, setname, name):
    """Merged zips keep a clone's own ROMs under <set>/; parent ROMs sit at the top."""
    for cand in ("%s/%s" % (setname, name), name):
        try:
            return zf.read(cand)
        except KeyError:
            pass
    raise KeyError("%s: neither %s/%s nor %s in the zip" % (setname, setname, name, name))


def load_prg(zf, setname, spec):
    """Interleave the four byte-wide program ROMs into the 386's 32-bit image."""
    names, base = spec
    out = bytearray(PRG_SIZE)
    for lane, n in enumerate(names):
        p = zread(zf, setname, n)
        out[base + lane:base + lane + len(p) * 4:4] = p
    return bytes(out)


def bank(raw):
    """A ROM spans the region in 2 MB banks that sit 4 MB apart.

    MAME writes that as ROM_CONTINUE(base + 0x400000) after 2 MB, and the 386's
    fetcher walks it with the same skip (`cmp esi,0x400000 / test esi,0x1fffff /
    add esi,0x200000`), so both sides agree without special-casing either.
    """
    return raw + (raw // 0x200000) * 0x200000


def load_sound01(zf, setname, layout):
    """Assemble the sound01 window: ROMs scattered across the 32-bit region."""
    region = bytearray(S01_SIZE)
    for name, base, lanes in layout:
        data = zread(zf, setname, name)
        for i, b in enumerate(data):
            group, lane = divmod(i, lanes)
            region[base + bank(group * 4 + lane)] = b
    return bytes(region)


class Fetcher:
    """The 386's source-byte fetcher, in its two forms.

    gen A (senkyu 0x33C4B5) is three instructions: take the byte, add a literal
    STRIDE to the address. A ROM occupying one byte in four is read with stride 4,
    and viprp1's program-ROM job with stride 1.

    gen B (rdft2 0x2A1C34) caches a dword and hands out only some of its lanes --
    mode 0 takes 1 byte per dword, mode 1 takes 2, anything else takes all 4. Same
    effect, different encoding, and the reason the compressed tail could not be
    found by searching the ROMs: the source is not contiguous in the region.

    Both then apply the 2 MB bank skip, and both address the 386's map rather than
    a region offset, so a job may name the program ROM instead of sound01.
    """

    def __init__(self, prg, region, addr, mode, gen):
        self.prg, self.region, self.esi = prg, region, addr
        self.mode, self.gen, self.cache = mode, gen, 0
        # Every hand-out is one byte of one ROM file, whatever the lane mode, so
        # this counts SOURCE FILE bytes. That is the number an MRA has to slice
        # with and the number rom_loader carries as the part size, and for a
        # decoded job it is the only way to know it -- the job record's `len` is
        # the OUTPUT length. Reading one byte too many shifts every later part.
        self.n = 0

    def _read32(self, addr):
        src, o = ((self.prg, addr - PRG_BASE) if addr < S01_BASE
                  else (self.region, addr - S01_BASE))
        return int.from_bytes(src[o:o + 4], "little")

    def __call__(self):
        if self.gen == "A":
            al = self._read32(self.esi & ~3) >> (8 * (self.esi & 3)) & 0xFF
            self.esi += self.mode
        else:
            if self.esi % 4 == 0:
                self.cache = self._read32(self.esi)
            al = self.cache & 0xFF
            self.cache >>= 8
            self.esi += 1
            if self.mode == 0:
                self.esi += 3
            elif self.mode == 1 and self.esi % 2 == 0:
                self.esi += 2
        if self.esi >= 0x400000 and self.esi % 0x200000 == 0:
            self.esi += 0x200000
        self.n += 1
        return al


def expand(fetch, out):
    """The decompressor (rdft2 0x2A1D20, senkyu 0x33C560): BPE over DPCM.

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


def build(zf, setname, decoded_out=None, quiet=False):
    g = GAMES[setname]
    decoded = bytearray()
    prg = load_prg(zf, setname, g["prg"])
    region = load_sound01(zf, setname, g["sound01"])

    def prg_dword(addr):
        o = addr - PRG_BASE
        return int.from_bytes(prg[o:o + 4], "little")

    def say(msg):
        if not quiet:
            print(msg, file=sys.stderr)

    img = bytearray(b"\xFF" * FLASH_SIZE)
    o = g["stamp"] - PRG_BASE
    img[0:4] = prg[o:o + 4]  # region stamp; the updater writes it last
    pos = FLASH_START

    job = g["job_table"]
    while prg_dword(job) != 0xFFFFFFFF:
        src = prg_dword(job)
        length = prg_dword(job + 4)
        mode = prg[job - PRG_BASE + 8]
        # gen A has no verbatim mode and gen B0 has no decoder; only B1 chooses
        # per job, and it does so with byte 9. In A and B0 that byte is padding.
        verbatim = {"A": False, "B0": True}.get(
            g["gen"], bool(prg[job - PRG_BASE + 9]))
        fetch = Fetcher(prg, region, src, mode, "A" if g["gen"] == "A" else "B")
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
                print("  warning: job declared %d bytes, decoded %d"
                      % (length, len(out)), file=sys.stderr)
        say("  %-6s src=%#09x mode=%d -> flash[%#x..%#x] (%d in, %d out)"
            % ("copy" if verbatim else "decode", src, mode, start, pos - 1,
               fetch.n, pos - start))
        job += 0xC

    say("  payload ends at %#x, rest is erased 0xFF" % (pos - 1))
    if decoded_out:
        with open(decoded_out, "wb") as f:
            f.write(decoded)
        say("  decoded output -> %s (%d bytes)" % (decoded_out, len(decoded)))
    return bytes(img)


def detect(zf):
    """Pick the set from the zip: a clone's ROMs live under its own directory."""
    names = set(zf.namelist())
    for s, v in GAMES.items():
        if all("%s/%s" % (s, n) in names or n in names for n in v["prg"][0]):
            return s
    return None


def main():
    argv = sys.argv[1:]
    decoded_out = setname = None
    for flag in ("--decoded-out", "--set"):
        if flag in argv:
            k = argv.index(flag)
            val = argv[k + 1]
            del argv[k:k + 2]
            if flag == "--set":
                setname = val
            else:
                decoded_out = val
    args = [a for a in argv if not a.startswith("--")]
    verify = "--verify" in argv
    if len(args) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src, dst = args

    with zipfile.ZipFile(src) as zf:
        if setname is None:
            setname = detect(zf)
        if setname not in GAMES:
            print("%s: no supported game (have: %s)" % (src, sorted(GAMES)),
                  file=sys.stderr)
            return 1
        print("%s (gen %s):" % (setname, GAMES[setname]["gen"]), file=sys.stderr)
        img = build(zf, setname, decoded_out)

    if verify:
        import hashlib
        got = hashlib.sha256(img).hexdigest()
        want = GAMES[setname]["sha256"]
        print("  sha256 %s %s" % (got, "OK" if got == want
                                  else "MISMATCH, want " + want), file=sys.stderr)
        if got != want:
            return 1

    with open(dst, "wb") as f:
        f.write(img)
    return 0


if __name__ == "__main__":
    sys.exit(main())
