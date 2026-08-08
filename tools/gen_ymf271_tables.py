#!/usr/bin/env python3
"""
Generate the YMF271 fixed-point lookup tables from MAME's ymf271.cpp.

MAME builds these at runtime from doubles (init_tables / calculate_clock_
correction). Everything here is the same arithmetic evaluated once, ahead of
time, in the fixed-point form the RTL uses:

  WAVE     [6][1024] the six real operator waveforms, signed 16 bit. Waveform 6
                    is the constant MAXOUT and waveform 7 is all zeros, so both
                    are handled in logic and left out of the ROM.
  LFO_STEP [256]    LFO phase increment per 44100 Hz sample
  PLFO_W   [4][256] the LFO pitch shape, quantised to q/128 in [-1, +1]
  PLFO     [7][257] 2^(cents[pms] * q/128 / 1200); pms 0 is exactly 1.0 and is
                    handled in logic, so only pms 1..7 are stored
  ALFO_K   [4]      LFO amplitude depth per ams setting
  MODLVL   [8]      phase modulation depth
  FBLVL    [8]      feedback depth
  RKS      [32][8]  keyscale rate adjustment, verbatim from RKS_Table
  AR_STEP  [64]     attack   envelope step for a full 0..255 sweep, <<16
  DC_STEP  [64]     decay2 / release step for a full 0..255 sweep, <<16
  DC_RECIP [64]     2^24 / decay-time-in-samples; decay1's step is this times
                    the sweep amount (decay1lvl * 16), which is the one
                    envelope step that is not a constant sweep
  ENV_VOL  [256]    envelope volume -> linear gain, 1.0 = 65536
  TL       [128]    total level -> linear gain
  ATTEN    [16]     channel attenuation -> linear gain

The sound chip runs at its documented 16.9344 MHz on SXX2E, so MAME's
clock_correction is exactly 1.0 and drops out.

Quartus rounds the odd-sized tables (WAVE 6144, PLFO 1799) up to a power of two
and zero-fills the tail, which it reports as Critical Warning 127005. That is
expected: nothing ever addresses past the real end.

Usage:
    tools/gen_ymf271_tables.py [path/to/mame] > rtl/ymf271_tables.vh
"""

import math
import os
import re
import sys

DEFAULT_MAME = os.path.expanduser("~/proj/mame")

SAMPLE_RATE = 44100.0
INF = -1.0


def read_source(mame_root):
    path = os.path.join(mame_root, "src/devices/sound/ymf271.cpp")
    with open(path) as f:
        return f.read(), path


def parse_double_table(src, decl, count):
    m = re.search(re.escape(decl) + r"\s*=\s*\{(.*?)\};", src, re.S)
    if not m:
        raise SystemExit("could not find %s" % decl)
    body = m.group(1)
    vals = []
    for tok in re.findall(r"(INF|[-+]?[0-9]*\.?[0-9]+)", body):
        vals.append(INF if tok == "INF" else float(tok))
    if len(vals) != count:
        raise SystemExit("%s has %d entries, expected %d" % (decl, len(vals), count))
    return vals


def parse_int_table(src, decl, count):
    m = re.search(re.escape(decl) + r"\s*=\s*\{(.*?)\};", src, re.S)
    if not m:
        raise SystemExit("could not find %s" % decl)
    vals = [int(v) for v in re.findall(r"-?\d+", m.group(1))]
    if len(vals) != count:
        raise SystemExit("%s has %d entries, expected %d" % (decl, len(vals), count))
    return vals


def parse_rks(src):
    m = re.search(r"static const int RKS_Table\[32\]\[8\]\s*=\s*\{(.*?)\n\};", src, re.S)
    if not m:
        raise SystemExit("could not find RKS_Table")
    rows = re.findall(r"\{([^{}]*?)\}", m.group(1))
    if len(rows) != 32:
        raise SystemExit("RKS_Table has %d rows, expected 32" % len(rows))
    out = []
    for r in rows:
        vals = [int(v) for v in re.findall(r"-?\d+", r)]
        if len(vals) != 8:
            raise SystemExit("RKS_Table row has %d entries, expected 8" % len(vals))
        out.append(vals)
    return out


def emit(name, width, values, per_line, fmt):
    print("\t/* verilator lint_off UNUSEDPARAM */")
    print("\treg [%d:0] %s [0:%d];" % (width - 1, name, len(values) - 1))
    print("\t/* verilator lint_on UNUSEDPARAM */")
    print("\tinitial begin")
    for i in range(0, len(values), per_line):
        chunk = values[i:i + per_line]
        cells = []
        for j, v in enumerate(chunk):
            cells.append("%s[%3d] = %d'%s;" % (name, i + j, width, fmt % v))
        print("\t\t" + "  ".join(cells))
    print("\tend")
    print()


def main():
    mame_root = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MAME
    src, path = read_source(mame_root)

    ar_time = parse_double_table(src, "static const double ARTime[64]", 64)
    dc_time = parse_double_table(src, "static const double DCTime[64]", 64)
    chan_att = parse_double_table(src, "static const double channel_attenuation_table[16]", 16)
    rks = parse_rks(src)

    # calculate_clock_correction(): rates expressed in samples, correction 1.0
    lut_ar = [t * SAMPLE_RATE / 1000.0 for t in ar_time]
    lut_dc = [t * SAMPLE_RATE / 1000.0 for t in dc_time]

    # init_envelope(): a rate below 4 means "instant", which MAME encodes as a
    # zero step. The INF entries are exactly those rates, so they never divide.
    VOL_MAX = 255 << 16

    def sweep_step(lut, rate):
        if rate < 4 or lut[rate] <= 0.0:
            return 0
        return min(int((255.0 / lut[rate]) * 65536.0), VOL_MAX)

    ar_step = [sweep_step(lut_ar, r) for r in range(64)]
    dc_step = [sweep_step(lut_dc, r) for r in range(64)]

    # decay1 sweeps only (255 - decay_level) = decay1lvl * 16, so the RTL scales
    # this reciprocal by the amount instead of holding 16 more tables.
    dc_recip = []
    for r in range(64):
        if r < 4 or lut_dc[r] <= 0.0:
            dc_recip.append(0)
        else:
            dc_recip.append(min(int(round((1 << 24) / lut_dc[r])), (1 << 20) - 1))

    env_vol = [min(int(65536.0 / math.pow(10.0, (i / (256.0 / 96.0)) / 20.0)), 65536)
               for i in range(256)]
    tl = [min(int(65536.0 / math.pow(10.0, (0.75 * i) / 20.0)), 65536) for i in range(128)]
    atten = [min(int(65536.0 / math.pow(10.0, db / 20.0)), 65536) for db in chan_att]

    print("//==========================================================================")
    print("//  SlopperPI - YMF271 fixed-point tables")
    print("//")
    print("//  GENERATED by tools/gen_ymf271_tables.py -- do not edit.")
    print("//  Source: %s" % path)
    print("//==========================================================================")
    print()

    flat_rks = [rks[k][s] for k in range(32) for s in range(8)]
    print("\t// RKS_Table[keycode][keyscale], flattened to {keycode[4:0], keyscale[2:0]}.")
    emit("YMF_RKS", 5, flat_rks, 8, "d%d")

    print("\t// Envelope steps for a full 255-unit sweep, already <<16.")
    emit("YMF_AR_STEP", 24, ar_step, 4, "d%d")
    emit("YMF_DC_STEP", 24, dc_step, 4, "d%d")

    print("\t// 2^24 / decay time in samples; decay1 multiplies this by its sweep.")
    emit("YMF_DC_RECIP", 20, dc_recip, 4, "d%d")

    print("\t// Linear gains, 65536 = unity.")
    emit("YMF_ENV_VOL", 17, env_vol, 8, "d%d")
    emit("YMF_TL", 17, tl, 8, "d%d")
    emit("YMF_ATTEN", 17, atten, 8, "d%d")

    # ---- operator waveforms (init_tables) ---------------------------------
    MAXOUT, MINOUT = 32767, -32768
    SIN_LEN = 1024
    waves = []
    for wf in range(6):
        for i in range(SIN_LEN):
            m1 = math.sin(((i * 2) + 1) * math.pi / SIN_LEN)
            m2 = math.sin(((i * 4) + 1) * math.pi / SIN_LEN)
            half = i < (SIN_LEN // 2)
            if wf == 0:   v = int(m1 * MAXOUT)
            elif wf == 1: v = int((m1 * m1) * (MAXOUT if half else MINOUT))
            elif wf == 2: v = int(m1 * MAXOUT) if half else int(-m1 * MAXOUT)
            elif wf == 3: v = int(m1 * MAXOUT) if half else 0
            elif wf == 4: v = int(m2 * MAXOUT) if half else 0
            else:         v = int(abs(m2) * MAXOUT) if half else 0
            waves.append(v & 0xFFFF)
    print("\t// Operator waveforms 0..5, {waveform[2:0], phase[9:0]}, two's complement.")
    print("\t// 6 is the constant %d and 7 is silence; both are done in logic." % MAXOUT)
    emit("YMF_WAVE", 16, waves, 6, "h%04X")

    # ---- LFO --------------------------------------------------------------
    lfo_freq = parse_double_table(src,
                                  "static const double LFO_frequency_table[256]", 256)
    lfo_step = [int(((256.0 * f) / SAMPLE_RATE) * 256.0) for f in lfo_freq]
    print("\t// init_lfo(): phase increment per sample, LFO_LENGTH 256 << 8.")
    emit("YMF_LFO_STEP", 10, lfo_step, 8, "d%d")

    # The pitch LFO shape, exactly as init_tables builds plfo[], quantised to
    # 128ths so the exponential below can be a table of 257 entries per depth
    # instead of 256 entries per (wave, depth) pair.
    LFO_LENGTH = 256
    qs = []
    for wave in range(4):
        for i in range(LFO_LENGTH):
            if wave == 0:
                x = 0.0
            elif wave == 1:
                fsaw = ((i % (LFO_LENGTH // 2)) * 1.0) / float((LFO_LENGTH // 2) - 1)
                x = fsaw if i < (LFO_LENGTH // 2) else fsaw - 1.0
            elif wave == 2:
                x = 1.0 if i < (LFO_LENGTH // 2) else -1.0
            else:
                ftri = ((i % (LFO_LENGTH // 4)) * 1.0) / float(LFO_LENGTH // 4)
                q = i // (LFO_LENGTH // 4)
                x = [ftri, 1.0 - ftri, -ftri, -(1.0 - ftri)][q]
            qs.append(int(round(x * 128.0)) & 0x1FF)
    print("\t// LFO pitch shape per {wave[1:0], phase[7:0]}, signed, unit = 1/128.")
    emit("YMF_PLFO_W", 9, qs, 8, "h%03X")

    # 2 ^ (cents * x / 1200), 65536 = unity, for pms 1..7 (pms 0 is unity).
    CENTS = [0.0, 3.378, 5.0646, 6.7495, 10.1143, 20.1699, 40.1076, 79.307]
    plfo = []
    for pms in range(1, 8):
        for q in range(-128, 129):
            plfo.append(int(round(65536.0 * math.pow(2.0, (CENTS[pms] * (q / 128.0)) / 1200.0))))
    print("\t// 2^(cents[pms] * q/128 / 1200) for pms 1..7, index {pms-1, q+128}.")
    emit("YMF_PLFO", 18, plfo, 6, "d%d")

    # calculate_slot_volume(): lfo_volume = 65536 - ((amplitude * K) >> 16)
    print("\t// Amplitude LFO depth per ams; 0 means no modulation.")
    emit("YMF_ALFO_K", 16, [0, 33124, 16742, 4277], 4, "d%d")

    # ---- operator modulation depths ---------------------------------------
    modlvl = parse_int_table(src, "static const int modulation_level[8]", 8)
    fblvl = parse_int_table(src, "static const int feedback_level[8]", 8)
    emit("YMF_MODLVL", 8, modlvl, 8, "d%d")
    emit("YMF_FBLVL", 7, fblvl, 8, "d%d")


if __name__ == "__main__":
    main()
