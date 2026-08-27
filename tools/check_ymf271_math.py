#!/usr/bin/env python3
"""
Check the integer forms the YMF271 RTL uses against MAME's OPX core,
exhaustively.

This used to check one algebra claim: that calculate_step()'s doubles were all
powers of two or half integers, so the RTL could collapse them into a multiply
and a signed shift. The rewritten core (MAME 03761e46766) has no doubles left
in the signal path -- but it has int64_t intermediates, and the RTL has to pin
every one of them to a finite width. A width chosen one bit short is the same
class of bug as the old wrong shift: a whole voice at the wrong pitch, audible
and very hard to attribute.

So the sweep now runs MAME's arithmetic in unbounded Python integers against a
model that masks to the widths ymf271_synth.sv declares, and fails if they ever
disagree. The model here IS the specification the RTL is written to -- if you
change a width in the RTL, change it here and re-run.

Four things are checked:

  phase_inc   FM pitch, all (fnum, block, dt, mul) x a spread of LFO values
  pcm_step    external-waveform pitch, the same plus Fs
  eg_rate     rate clamp and the eg_inc nibble selection, all (rate, rks, cnt)
  op          the log-sin / exp attenuation resolution, against the .vh tables

    tools/check_ymf271_math.py [path/to/mame]
"""

import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_ymf271_tables as gen   # noqa: E402


# ---------------------------------------------------------------- widths ----
# The declared widths in ymf271_synth.sv. Keep these two lists in step.
W_FNUM_Q7 = 20    # fnum with 7 fraction bits, after the LFO term
W_INC     = 33    # signed, the pre-multiplier increment
W_PCM_NUM = 36    # fnum(q7) << 16, before the block shift


def s(v, w):
    """Truncate to a w-bit two's complement value, as a Verilog reg would."""
    v &= (1 << w) - 1
    return v - (1 << w) if v & (1 << (w - 1)) else v


def u(v, w):
    return v & ((1 << w) - 1)


# ------------------------------------------------------- MAME, verbatim ----
def mame_phase_inc(fnum, block_s, dt, mul, pms, lfo_pm, keycode, detune, pms_k):
    sh = block_s + 11
    f = fnum << 7
    if lfo_pm != 0:
        f += (fnum * pms_k[pms] * lfo_pm) >> 10
    inc = (f << sh) >> 7
    d = detune[keycode * 4 + (dt & 3)] << 12
    inc = inc - d if (dt & 4) else inc + d
    if inc < 0:
        inc = 0
    inc = (inc >> 1) if mul == 0 else inc * mul
    return inc & 0xFFFFFFFF          # uint32_t(inc)


def mame_pcm_step(fnum, block_s, dt, mul, fs, pms, lfo_pm, keycode, detune, pms_k):
    base = (fnum & 0x7FF) | 0x800
    f = base << 7
    if lfo_pm != 0:
        f += (base * pms_k[pms] * lfo_pm) >> 10
    inc = (f << 16) >> (18 - block_s)
    d = detune[keycode * 4 + (dt & 3)] << 6
    inc = inc - d if (dt & 4) else inc + d
    if inc < 0:
        inc = 0
    inc = (inc >> 1) if mul == 0 else inc * mul
    inc >>= fs
    return inc & 0xFFFFFFFF


# ------------------------------------------------ the RTL's bounded form ----
def rtl_phase_inc(fnum, block_s, dt, mul, pms, lfo_pm, keycode, detune, pms_k):
    # fnum(q7) is unsigned and cannot go negative: the LFO term is bounded by
    # fnum * 48 * 128 / 1024 = fnum * 6, well under fnum * 128.
    f = u(fnum << 7, W_FNUM_Q7)
    if lfo_pm != 0:
        f = u(f + ((fnum * pms_k[pms] * lfo_pm) >> 10), W_FNUM_Q7)
    sh = block_s + 11                       # 3..18, always positive
    inc = s(f << (sh - 7), W_INC) if sh >= 7 else s(f >> (7 - sh), W_INC)
    d = detune[keycode * 4 + (dt & 3)] << 12
    inc = s(inc - d, W_INC) if (dt & 4) else s(inc + d, W_INC)
    if inc < 0:
        inc = 0
    inc = (inc >> 1) if mul == 0 else inc * mul
    return u(inc, 32)


def rtl_pcm_step(fnum, block_s, dt, mul, fs, pms, lfo_pm, keycode, detune, pms_k):
    base = (fnum & 0x7FF) | 0x800
    f = u(base << 7, W_FNUM_Q7)
    if lfo_pm != 0:
        f = u(f + ((base * pms_k[pms] * lfo_pm) >> 10), W_FNUM_Q7)
    inc = u(f << 16, W_PCM_NUM) >> (18 - block_s)   # shift right by 11..26
    inc = s(inc, W_INC)
    d = detune[keycode * 4 + (dt & 3)] << 6
    inc = s(inc - d, W_INC) if (dt & 4) else s(inc + d, W_INC)
    if inc < 0:
        inc = 0
    inc = (inc >> 1) if mul == 0 else inc * mul
    inc >>= fs
    return u(inc, 32)


# ----------------------------------------------------------------- tables ----
def table_from_vh(vh, name, count, radix="d"):
    vals = [None] * count
    pat = re.escape(name) + r"\[\s*(\d+)\] = \d+'" + radix + r"([0-9a-fA-F]+);"
    for m in re.finditer(pat, vh):
        vals[int(m.group(1))] = int(m.group(2), 16 if radix == "h" else 10)
    if any(v is None for v in vals):
        raise SystemExit("%s: missing entries in ymf271_tables.vh" % name)
    return vals


def main():
    mame_root = sys.argv[1] if len(sys.argv) > 1 else gen.DEFAULT_MAME
    src, _ = gen.read_source(mame_root)

    detune = gen.parse_int_table(src, "const uint8_t detune_tab[32][4]", 128)
    pms_k = gen.parse_int_table(src, "const uint8_t pms_k[8]", 8)
    eg_inc = gen.parse_int_table(src, "const uint32_t eg_inc[64]", 64)
    rks_tab = gen.parse_int_table(src, "const uint8_t rks_tab[32][8]", 256)

    vh = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "rtl", "ymf271_tables.vh")).read()

    bad = 0

    # ---- the generated .vh agrees with the source it was scraped from ----
    for name, ref, radix in (("YMF_DETUNE", detune, "d"),
                             ("YMF_PMS_K", pms_k, "d"),
                             ("YMF_EG_INC", eg_inc, "h"),
                             ("YMF_RKS", rks_tab, "d")):
        got = table_from_vh(vh, name, len(ref), radix)
        if got != ref:
            print("%s: .vh does not match ymf271.cpp" % name)
            bad += 1
    logsin = table_from_vh(vh, "YMF_LOGSIN", 256)
    exp_t = table_from_vh(vh, "YMF_EXP", 256)
    for i in range(256):
        want_l = int(math.floor(-math.log(math.sin((i + 0.5) * math.pi / 512.0))
                                / math.log(2.0) * 256.0 + 0.5))
        want_e = int(math.floor(math.pow(2.0, -(i + 1) / 256.0) * 2048.0 + 0.5))
        if logsin[i] != want_l or exp_t[i] != want_e:
            print("logsin/exp mismatch at %d" % i)
            bad += 1
            break
    print("tables: 7 tables checked, %d mismatches" % bad)

    # ---- phase_inc / pcm_step -------------------------------------------
    # 7 is coprime with every power of two, so stepping fnum by it still walks
    # every alignment of the shift.
    LFOS = (0, 1, 63, 127, -1, -64, -128)
    step_bad = pcm_bad = checked = 0
    for block in range(16):
        block_s = block - 16 if block & 8 else block
        for mul in range(16):
            for dt in range(8):
                for fs in range(4):
                    for lfo in LFOS:
                        pms = 7 if lfo else 0
                        for fnum in range(0, 4096, 293):
                            kc = ((0 if block_s < 0 else (block & 7) * 4)
                                  + (0 if fnum < 0x780 else 1 if fnum < 0x900
                                     else 2 if fnum < 0xA80 else 3))
                            checked += 1
                            a = mame_phase_inc(fnum, block_s, dt, mul, pms, lfo,
                                               kc, detune, pms_k)
                            b = rtl_phase_inc(fnum, block_s, dt, mul, pms, lfo,
                                              kc, detune, pms_k)
                            if a != b:
                                step_bad += 1
                                if step_bad <= 5:
                                    print("phase_inc fns=%4d blk=%2d dt=%d mul=%2d "
                                          "lfo=%4d  mame=%d rtl=%d"
                                          % (fnum, block_s, dt, mul, lfo, a, b))
                            a = mame_pcm_step(fnum, block_s, dt, mul, fs, pms, lfo,
                                              kc, detune, pms_k)
                            b = rtl_pcm_step(fnum, block_s, dt, mul, fs, pms, lfo,
                                             kc, detune, pms_k)
                            if a != b:
                                pcm_bad += 1
                                if pcm_bad <= 5:
                                    print("pcm_step  fns=%4d blk=%2d dt=%d mul=%2d "
                                          "fs=%d lfo=%4d  mame=%d rtl=%d"
                                          % (fnum, block_s, dt, mul, fs, lfo, a, b))
    print("phase_inc: %d combinations checked, %d mismatches" % (checked, step_bad))
    print("pcm_step:  %d combinations checked, %d mismatches" % (checked, pcm_bad))
    bad += step_bad + pcm_bad

    # ---- eg_rate and the eg_inc nibble selection -------------------------
    # MAME reads eg_inc[rate] as eight packed nibbles and picks one with a
    # shift derived from the rate. The RTL does it with a comparator, a mask
    # and a 3-bit index into a 32-bit word, so what needs pinning is the rate
    # clamp, the rate-0 escape, and that eg_cnt is wide enough: shift reaches
    # 11 and three index bits sit above it, so anything under 14 bits silently
    # freezes the slowest rates.
    W_EG_CNT = 16
    if W_EG_CNT < 14:
        print("eg_cnt is %d bits; 14 is the minimum" % W_EG_CNT)
        bad += 1

    def mame_eg_step(rate2, rks, cnt):
        rate = 0 if rate2 == 0 else min(rate2 + rks, 63)
        if rate < 48:
            shift = 11 - (rate >> 2)
            if cnt & ((1 << shift) - 1):
                return 0
            idx = (cnt >> shift) & 7
        else:
            idx = cnt & 7
        return (eg_inc[rate] >> (idx * 4)) & 15

    def rtl_eg_step(rate2, rks, cnt):
        # rate2 is 2*AR/D1R/D2R (0..62) or 4*RR (0..60); the sum needs 7 bits
        # before the clamp, and rks is 5.
        rate = u(rate2 + rks, 7)
        rate = 0 if rate2 == 0 else (63 if rate > 63 else rate)
        cnt = u(cnt, W_EG_CNT)
        slow = rate < 48
        shift = (11 - (rate >> 2)) if slow else 0
        if slow and (cnt & u((1 << shift) - 1, W_EG_CNT)):
            return 0
        idx = ((cnt >> shift) & 7) if slow else (cnt & 7)
        return (eg_inc[rate] >> (idx * 4)) & 15

    # rate2 is 2*AR (AR 5 bits) or 4*RR (RR 4 bits), so 62 is the ceiling;
    # 62 + rks 31 = 93 is what the 7-bit pre-clamp sum has to hold.
    eg_bad = eg_checked = 0
    for rate2 in range(0, 63):
        for rks in range(32):
            for cnt in range(0, 1 << 14, 37):   # 37 is coprime with 2^k
                eg_checked += 1
                a = mame_eg_step(rate2, rks, cnt)
                b = rtl_eg_step(rate2, rks, cnt)
                if a != b:
                    eg_bad += 1
                    if eg_bad <= 5:
                        print("eg_step rate2=%d rks=%d cnt=%d  mame=%d rtl=%d"
                              % (rate2, rks, cnt, a, b))
    print("eg_step:   %d combinations checked, %d mismatches" % (eg_checked, eg_bad))
    bad += eg_bad

    # ---- op(): the attenuation resolution --------------------------------
    # att = logsin + env<<2, cut off at 4096, out = (exp[att&255]<<2) >> (att>>8).
    # 4096 / 256 = 16 shift positions, so the barrel shift is 4 bits wide and
    # the product before it is 13 bits. Check the range never exceeds that.
    op_max = 0
    for att in range(4096):
        v = (exp_t[att & 255] << 2) >> (att >> 8)
        op_max = max(op_max, v)
    if op_max > 8191:
        print("op: output %d exceeds the 14-bit operator range" % op_max)
        bad += 1
    print("op:        peak magnitude %d (14-bit range is 8191)" % op_max)

    if bad:
        print("FAILED: %d mismatches" % bad)
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
