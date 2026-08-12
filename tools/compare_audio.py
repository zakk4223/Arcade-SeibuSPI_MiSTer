#!/usr/bin/env python3
"""Compare a hardware audio capture against a MAME reference recording.

    tools/compare_audio.py hw.wav mame_ref.wav

This is the measurement PLAN.md section 10d describes for rdft2, written down
so the next set does not have to reinvent it. The telemetry cannot do this job:
it reports a healthy engine playing the wrong thing, which is exactly how
rfjet's missing music survived a hardware run (the bank 4-7 bug).

What it reports, and what each one is evidence of:

  envelope r      20 ms RMS, correlated after alignment. This says the sound
                  PROGRAM is right -- the same notes start and stop at the same
                  times. It is the figure that catches wrong sequence data.
  spectrum r      long-term average spectrum, normalised. Says the SYNTHESIS is
                  right -- the same partials at the same relative strengths.
  per-window r    median and the fraction above 0.8, so one bad passage cannot
                  hide inside a good average.
  silence         windows where one side plays and the other does not. A core
                  that drops voices shows up here and nowhere else.

Alignment is searched, not assumed: the hardware is captured mid-attract and
MAME starts from boot, so the two are offset by an arbitrary amount. The search
maximises envelope correlation over every offset that leaves full overlap, and
the reference should be comfortably longer than the capture.

Level is deliberately NOT compared. 10d measured MAME's rdft2 output at 2.58x
the hardware's and never explained it; it is a level difference, not a shape
difference, and every figure here is normalised.
"""

import sys
import wave

import numpy as np

WIN_MS = 20


def read_wav(path):
    with wave.open(path) as w:
        n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
        a = np.frombuffer(w.readframes(n), dtype="<i2").reshape(-1, ch)
    return a.astype(np.float64), sr, ch


def envelope(mono, sr):
    """RMS in WIN_MS windows -- the shape of the music over time."""
    w = int(sr * WIN_MS / 1000)
    n = len(mono) // w
    return np.sqrt((mono[: n * w].reshape(n, w) ** 2).mean(axis=1))


def norm(x):
    x = x - x.mean()
    s = x.std()
    return x / s if s else x


def align(hw_env, ref_env):
    """Offset into ref_env that best matches hw_env, by correlation.

    Coarse then fine: a full search at every window is O(n*m) and slow enough
    to discourage running this, which is worse than it being approximate.
    """
    n = len(hw_env)
    hwn = norm(hw_env)
    best, best_off = -2.0, 0
    for step, lo, hi in ((25, 0, len(ref_env) - n), (1, None, None)):
        if lo is None:
            lo, hi = max(0, best_off - 25), min(len(ref_env) - n, best_off + 25)
        for off in range(lo, hi + 1, step):
            r = float(np.dot(hwn, norm(ref_env[off : off + n]))) / n
            if r > best:
                best, best_off = r, off
    return best_off, best


def spectrum(mono, sr):
    w = 4096
    n = len(mono) // w
    if not n:
        return np.zeros(w // 2)
    frames = mono[: n * w].reshape(n, w) * np.hanning(w)
    mag = np.abs(np.fft.rfft(frames, axis=1))[:, : w // 2]
    avg = mag.mean(axis=0)
    return avg / (np.linalg.norm(avg) or 1)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    hw_path, ref_path = sys.argv[1], sys.argv[2]

    hw, hw_sr, hw_ch = read_wav(hw_path)
    ref, ref_sr, ref_ch = read_wav(ref_path)
    if hw_sr != ref_sr:
        sys.exit(f"sample rates differ: {hw_sr} vs {ref_sr}")

    hw_m, ref_m = hw.mean(axis=1), ref.mean(axis=1)
    print(f"hardware  {len(hw_m)/hw_sr:7.1f} s  rms {np.sqrt((hw_m**2).mean()):8.1f}"
          f"  peak {int(abs(hw_m).max()):6d}")
    print(f"reference {len(ref_m)/ref_sr:7.1f} s  rms {np.sqrt((ref_m**2).mean()):8.1f}"
          f"  peak {int(abs(ref_m).max()):6d}")

    # Stereo separation, which is a real divergence for the cartridge sets
    # (PLAN.md T-K): the SPI board is stereo and this core is mono.
    for name, a, ch in (("hardware", hw, hw_ch), ("reference", ref, ref_ch)):
        if ch < 2:
            continue
        mid = (a[:, 0] + a[:, 1]) / 2
        side = (a[:, 0] - a[:, 1]) / 2
        rm, rs = np.sqrt((mid**2).mean()), np.sqrt((side**2).mean())
        db = 20 * np.log10(rs / rm) if rm and rs else -np.inf
        print(f"  {name:9s} side/mid {db:7.1f} dB"
              f"   ({'MONO' if db < -60 else 'stereo'})")

    hw_env, ref_env = envelope(hw_m, hw_sr), envelope(ref_m, ref_sr)
    if len(ref_env) <= len(hw_env):
        sys.exit("reference must be longer than the capture, to align within")

    off, r_env = align(hw_env, ref_env)
    n = len(hw_env)
    ref_env_a = ref_env[off : off + n]
    print(f"\naligned at {off * WIN_MS / 1000:.2f} s into the reference")
    print(f"envelope r          {r_env:.4f}   (the sound PROGRAM: same notes, same times)")

    # Same alignment applied to the samples, for the spectral figures.
    o = off * int(hw_sr * WIN_MS / 1000)
    ref_a = ref_m[o : o + len(hw_m)]
    m = min(len(ref_a), len(hw_m))
    hw_s, ref_s = hw_m[:m], ref_a[:m]

    sh, sr_ = spectrum(hw_s, hw_sr), spectrum(ref_s, ref_sr)
    print(f"spectrum r          {float(np.dot(sh, sr_)):.4f}   (the SYNTHESIS: same partials)")

    # Per-window spectral correlation, so a bad passage cannot average away.
    win = hw_sr  # one second
    rs_list = []
    for i in range(m // win):
        a, b = hw_s[i * win : (i + 1) * win], ref_s[i * win : (i + 1) * win]
        if np.sqrt((a**2).mean()) < 20 and np.sqrt((b**2).mean()) < 20:
            continue
        sa, sb = spectrum(a, hw_sr), spectrum(b, ref_sr)
        rs_list.append(float(np.dot(sa, sb)))
    if rs_list:
        rs_arr = np.array(rs_list)
        print(f"per-second r        median {np.median(rs_arr):.4f}, "
              f"{100*np.mean(rs_arr > 0.8):.0f}% above 0.8   ({len(rs_arr)} windows)")

    # Silence agreement. Windows where the hardware is quiet and MAME is not are
    # dropped voices; the reverse is the core playing something it should not.
    q = 40
    hw_q, ref_q = hw_env < q, ref_env_a < q
    print(f"silence agreement   {100*np.mean(hw_q == ref_q):.1f}%")
    print(f"  hardware silent while MAME plays  {int(np.sum(hw_q & ~ref_q)):5d} windows"
          f"  ({100*np.mean(hw_q & ~ref_q):.2f}%)")
    print(f"  MAME silent while hardware plays  {int(np.sum(~hw_q & ref_q)):5d} windows"
          f"  ({100*np.mean(~hw_q & ref_q):.2f}%)")


if __name__ == "__main__":
    main()
