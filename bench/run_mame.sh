#!/bin/sh
#
# Run the SPI 386 benchmark ROM in MAME, in a window, so you can watch the table
# fill in and page it with the joystick.
#
#   ./bench/run_mame.sh                          # window, default rompath
#   ./bench/run_mame.sh -r ~/Downloads/roms      # window, explicit rompath
#   ./bench/run_mame.sh -t                       # headless, print the table
#   ./bench/run_mame.sh -s 60                    # stop after 60 emulated seconds
#
# The image is written straight into MAME's ":maincpu" region and the machine is
# soft reset, so there is no doctored zip and no rebuilt driver -- the real
# rfjet.zip is all you need. See bench/mame_bench.lua.
#
# All 37 tests fit on one screen; the whole suite takes about 90 emulated
# seconds and the bottom line reads COMPLETE when it is done.
#
# Leave MAME's rotation alone. rfjet is ROT270 and the benchmark lays its text
# out to be read through that rotation, exactly as the game's own text is, so
# MAME's default 240x320 view is the upright one. -n / -norotate shows the raw
# framebuffer, where the table runs sideways.
#
set -eu

here=$(cd "$(dirname "$0")" && pwd)
rompath="${ROMS:-$HOME/Downloads}"
mame="${MAMEBIN:-mame}"
rom="$here/out/bench_patched.bin"
secs=""
headless=0
norotate=""

usage() {
    sed -n '2,20p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--rompath) rompath=$2; shift 2 ;;
        -m|--mame)    mame=$2; shift 2 ;;
        -i|--image)   rom=$2; shift 2 ;;
        -s|--seconds) secs=$2; shift 2 ;;
        -t|--table)   headless=1; shift ;;
        -n|--norotate) norotate="-norotate"; shift ;;   # raw framebuffer, sideways
        -h|--help)    usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

if [ ! -f "$rom" ]; then
    echo "no $rom -- run 'make -C bench' first" >&2
    exit 1
fi
if [ ! -f "$rompath/rfjet.zip" ]; then
    echo "no rfjet.zip in $rompath -- pass -r <dir> or set ROMS" >&2
    exit 1
fi

out=${BENCH_OUT:-/tmp/spi_bench/mame.txt}
mkdir -p "$(dirname "$out")"

set -- rfjet -rompath "$rompath" -autoboot_script "$here/mame_bench.lua" \
       -noplugins -skip_gameinfo

if [ "$headless" = 1 ]; then
    set -- "$@" -video none -sound none -nothrottle -seconds_to_run "${secs:-180}"
else
    set -- "$@" -window -nomaximize -sound none $norotate
    [ -n "$secs" ] && set -- "$@" -seconds_to_run "$secs"
fi

echo "image:   $rom"
echo "rompath: $rompath"
echo "results: $out"
echo

BENCH_ROM="$rom" BENCH_OUT="$out" "$mame" "$@"

if [ -s "$out" ]; then
    echo
    grep '^BENCHINFO' "$out" || true
    echo
    python3 "$here/analyze.py" "mame=$out"
fi
