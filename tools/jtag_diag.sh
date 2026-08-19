#!/bin/sh
# One-shot SDRAM diagnosis over JTAG against a running SeibuSPI.
#
#   tools/jtag_diag.sh <reference sdram.bin>
#
# Reports what spi_romcheck computed versus what it should have, then reads the
# real SDRAM at the start of each ROM region plus the 386 reset vector and
# diffs it against the reference image.
set -e
REF="${1:?usage: jtag_diag.sh <reference sdram.bin>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/slop_jtag"
mkdir -p "$OUT"

echo "=== what the on-board checker computed ==="
quartus_stp -t "$ROOT/tools/jtag_peek.tcl" sums 2>&1 | sed -n '/^ok bits/,/^sum SPRITES/p'
cat <<'EXPECT'

  expected:
    sum PRG     = 741393AF
    sum CHARS   = 79A0EB60
    sum TILES   = D3E9E887
    sum SPRITES = DCD037DA
EXPECT

: > "$OUT/dump.txt"
for spec in "0x0 6:PRG" "0x1FFFF0 2:reset vector" "0x240000 4:CHARS" "0x480000 4:TILES" "0xA80000 4:SPRITES"; do
    range="${spec%%:*}"; name="${spec#*:}"
    addr="${range%% *}"; count="${range##* }"
    echo "=== reading $name at $addr ==="
    quartus_stp -t "$ROOT/tools/jtag_peek.tcl" dump "$addr" "$count" 2>&1 \
        | grep -E '^[0-9A-F]{7} [0-9A-F]{16}$' | tee -a "$OUT/dump.txt"
done

echo
echo "=== compared against the reference image ==="
python3 "$ROOT/tools/jtag_compare.py" "$REF" "$OUT/dump.txt"
