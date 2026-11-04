# The promo film's sound: a short piece of music and the effects, written to the film's clock
# (tools/film/timeline.json) and synthesised here from sine waves and noise — no samples, nothing downloaded.
# 120 beats a minute, a chord a bar (2 s) in D major; the Mac wakes with a chime, the music comes in with the
# display, every cut lands on a beat, the proxy's failure cuts the sound with the light, and the last chord
# opens as the two halves of the mark meet.
#
#   python3 -I tools/film/sound.py [out.wav]        # 48 kHz stereo, 16-bit → video/.cache/sound.wav
import json
import os
import sys
import wave

import numpy as np

SR = 48000
HERE = os.path.dirname(os.path.abspath(__file__))
TL = json.load(open(os.path.join(HERE, 'timeline.json')))
CUE = TL['cues']
DUR = float(TL['duration'])
N = int(SR * DUR)
rng = np.random.default_rng(11)
TAU = 2 * np.pi


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def sm(x):
    x = np.clip(x, 0, 1)
    return x * x * (3 - 2 * x)


def span(tt, a, b):
    return np.clip((tt - a) / (b - a), 0, 1)


def pan(x, p):
    """Mono → stereo, equal power, p from -1 (left) to 1 (right)."""
    a = (p + 1) * np.pi / 4
    return np.vstack([x * np.cos(a), x * np.sin(a)])


def place(bus, x, at):
    """Add x (stereo 2×n or mono) into bus at time `at` (s)."""
    if x.ndim == 1:
        x = pan(x, 0)
    i = int(round(at * SR))
    j0, j1 = max(0, i), min(bus.shape[1], i + x.shape[1])
    if j1 > j0:
        bus[:, j0:j1] += x[:, j0 - i:j1 - i]


def fft_filter(x, gain):
    """Filter a mono signal by a gain function of frequency (Hz), whole signal at once."""
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1 / SR)
    return np.fft.irfft(X * gain(f), n)


def stft_filter(x, gain, frame=2048, hop=512):
    """A filter that changes over time: gain(times (s), freqs (Hz)) → frames × bins."""
    n = len(x)
    win = np.hanning(frame)
    pad = np.concatenate([np.zeros(frame), x, np.zeros(frame)])
    starts = np.arange(0, len(pad) - frame, hop)
    frames = np.stack([pad[s:s + frame] * win for s in starts])
    X = np.fft.rfft(frames, axis=1)
    times = (starts + frame / 2 - frame) / SR
    freqs = np.fft.rfftfreq(frame, 1 / SR)
    X *= gain(times[:, None], freqs[None, :])
    y = np.fft.irfft(X, frame, axis=1) * win
    out = np.zeros(len(pad))
    norm = np.zeros(len(pad))
    for k, s in enumerate(starts):
        out[s:s + frame] += y[k]
        norm[s:s + frame] += win * win
    out /= np.maximum(norm, 1e-6)
    return out[frame:frame + n]


def band(f, fc, q):
    """A soft band-pass bump around fc (Hz), width by q (in octaves)."""
    return np.exp(-0.5 * (np.log2(np.maximum(f, 1) / fc) / q) ** 2)


# MARK: Instruments

def pad_note(m, t0, dur, cutoff, amp=1.0, att=0.5, rel=1.1, voices=3, cents=8.0, spread=0.7):
    """A warm pad note: detuned saws, built from their harmonics so the low-pass can move with the film."""
    n = int((dur + rel) * SR)
    tt = np.arange(n) / SR
    env = sm(tt / att) * np.where(tt < dur, 1.0, np.cos(np.clip((tt - dur) / rel, 0, 1) * np.pi / 2) ** 2)
    fc = cutoff(t0 + tt)
    out = np.zeros((2, n))
    f0 = hz(m)
    for v in range(voices):
        c = (v - (voices - 1) / 2) * cents
        fv = f0 * 2 ** (c / 1200)
        ph = rng.random() * TAU
        sig = np.zeros(n)
        for h in range(1, int(min(36, 7000 // fv)) + 1):
            a = (1.0 / h) / np.sqrt(1 + (h * fv / fc) ** 4)
            sig += a * np.sin(TAU * h * fv * tt + ph * h)
        p = (v - (voices - 1) / 2) / max(1, (voices - 1) / 2) * spread
        out += pan(sig, p)
    lfo = 1 + 0.06 * np.sin(TAU * 0.23 * tt + rng.random() * TAU)
    return out * env * lfo * amp / voices


def bass_note(m, dur, amp=1.0):
    n = int((dur + 0.4) * SR)
    tt = np.arange(n) / SR
    f = hz(m)
    env = (1 - np.exp(-tt / 0.012)) * (0.75 + 0.25 * np.exp(-tt / 0.35)) * np.where(tt < dur, 1, np.exp(-(tt - dur) / 0.08))
    sig = np.sin(TAU * f * tt) + 0.22 * np.sin(TAU * 2 * f * tt) + 0.06 * np.sin(TAU * 3 * f * tt)
    return np.tanh(1.4 * sig) / np.tanh(1.4) * env * amp


def pluck(m, amp=1.0, decay=0.2):
    n = int(1.2 * SR)
    tt = np.arange(n) / SR
    f = hz(m)
    att = 1 - np.exp(-tt / 0.002)
    sig = (np.sin(TAU * f * tt) * np.exp(-tt / decay)
           + 0.4 * np.sin(TAU * 2 * f * tt) * np.exp(-tt / (decay * 0.4))
           + 0.15 * np.sin(TAU * 3.01 * f * tt) * np.exp(-tt / (decay * 0.25)))
    return sig * att * amp


def kick(amp=1.0):
    n = int(0.7 * SR)
    tt = np.arange(n) / SR
    f = 44 + 80 * np.exp(-tt / 0.03)
    ph = TAU * np.cumsum(f) / SR
    body = np.sin(ph) * np.exp(-tt / 0.3) * (1 - np.exp(-tt / 0.0015))
    click = fft_filter(rng.standard_normal(n), lambda fr: band(fr, 3500, 0.8)) * np.exp(-tt / 0.004) * 0.25
    return (body + click) * amp


def tick(amp=1.0, fc=4200, decay=0.012):
    n = int(0.12 * SR)
    tt = np.arange(n) / SR
    x = fft_filter(rng.standard_normal(n), lambda fr: band(fr, fc, 0.6))
    return x / (np.abs(x).max() + 1e-9) * np.exp(-tt / decay) * (1 - np.exp(-tt / 0.0006)) * amp


def bell(m, amp=1.0, dur=3.0, ratio=3.5, index=1.6, decay=1.3):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    f = hz(m)
    mod = index * np.exp(-tt / 0.35) * np.sin(TAU * f * ratio * tt)
    sig = np.sin(TAU * f * tt + mod) * np.exp(-tt / decay) + 0.25 * np.sin(TAU * 2 * f * tt) * np.exp(-tt / (decay * 0.4))
    return sig * (1 - np.exp(-tt / 0.003)) * amp


def impact(amp=1.0, f0=72, f1=31, decay=0.75, noise=0.35):
    n = int(2.2 * SR)
    tt = np.arange(n) / SR
    f = f1 + (f0 - f1) * np.exp(-tt / 0.18)
    sub = np.sin(TAU * np.cumsum(f) / SR) * np.exp(-tt / decay) * (1 - np.exp(-tt / 0.003))
    nz = fft_filter(rng.standard_normal(n), lambda fr: 1 / np.sqrt(1 + (fr / 900) ** 4)) * np.exp(-tt / 0.16)
    nz /= np.abs(nz).max() + 1e-9
    return (sub + noise * nz) * amp


def riser(dur, amp=1.0, f_lo=250, f_hi=7000, p0=-0.4, p1=0.4):
    """Noise rising through a band-pass into a hit at the end, panning across."""
    n = int(dur * SR)
    tt = np.arange(n) / SR
    x = rng.standard_normal(n)
    y = stft_filter(x, lambda T, F: band(F, f_lo * (f_hi / f_lo) ** np.clip(T / dur, 0, 1), 0.7))
    env = (tt / dur) ** 2.2
    y = y / (np.abs(y).max() + 1e-9) * env * amp
    p = np.linspace(p0, p1, n)
    return np.vstack([y * np.cos((p + 1) * np.pi / 4), y * np.sin((p + 1) * np.pi / 4)])


def whoosh(dur, amp=1.0, f_lo=300, f_hi=4000, p0=-0.8, p1=0.8, peak=0.55):
    """A pass: noise swelling up a band and down again, panning with what moves on screen."""
    n = int(dur * SR)
    tt = np.arange(n) / SR
    u = tt / dur
    x = rng.standard_normal(n)
    fcu = lambda T: f_lo * (f_hi / f_lo) ** np.sin(np.pi * np.clip(T / dur, 0, 1) * 0.5 / peak * (np.clip(T / dur, 0, 1) < peak) + np.pi / 2 * (np.clip(T / dur, 0, 1) >= peak))
    y = stft_filter(x, lambda T, F: band(F, fcu(T), 0.9))
    env = np.where(u < peak, (u / peak) ** 2, np.exp(-(u - peak) / (1 - peak) * 4))
    y = y / (np.abs(y).max() + 1e-9) * env * amp
    p = p0 + (p1 - p0) * sm(u)
    return np.vstack([y * np.cos((p + 1) * np.pi / 4), y * np.sin((p + 1) * np.pi / 4)])


def sparkle(t0, t1, rate0, rate1, amp=1.0, lo=2600, hi=7500):
    """Tiny bright grains, more and more of them: light, code taking shape."""
    out = np.zeros((2, int((t1 - t0 + 0.2) * SR)))
    t = 0.0
    while t < t1 - t0:
        r = rate0 + (rate1 - rate0) * (t / (t1 - t0))
        t += rng.exponential(1 / r)
        if t >= t1 - t0:
            break
        f = np.exp(rng.uniform(np.log(lo), np.log(hi)))
        n = int(0.05 * SR)
        tt = np.arange(n) / SR
        g = np.sin(TAU * f * tt) * np.exp(-tt / 0.012) * (1 - np.exp(-tt / 0.001)) * rng.uniform(0.4, 1)
        place(out, pan(g, rng.uniform(-0.8, 0.8)), t)
    return out * amp


# MARK: Reverb: a synthetic hall (decaying noise, darker as it decays), by FFT convolution

def make_ir(rt60=2.3, length=3.2, predelay=0.022):
    n = int(length * SR)
    tt = np.arange(n) / SR
    ir = np.zeros((2, n + int(predelay * SR)))
    for c in range(2):
        x = rng.standard_normal(n) * np.exp(-6.91 * tt / rt60)
        # darker as it decays: blend a low-passed copy in over time
        lp = fft_filter(x, lambda f: 1 / np.sqrt(1 + (f / 2500) ** 2))
        k = np.clip(tt / 0.8, 0, 1)
        x = x * (1 - k) + lp * k
        x = fft_filter(x, lambda f: (f / 180) ** 2 / (1 + (f / 180) ** 2))   # keep the low end dry
        ir[c, int(predelay * SR):] = x
    return ir / np.sqrt(np.sum(ir ** 2) / 2)


def convolve(x, ir):
    n = x.shape[1] + ir.shape[1]
    size = 1 << (n - 1).bit_length()
    out = np.zeros((2, x.shape[1]))
    for c in range(2):
        y = np.fft.irfft(np.fft.rfft(x[c], size) * np.fft.rfft(ir[c], size), size)
        out[c] = y[:x.shape[1]]
    return out


# MARK: The score
music = np.zeros((2, N))     # pad, bass, plucks, pulse — cut by the proxy's failure
fx = np.zeros((2, N))        # effects that follow the picture
wet_m = np.zeros((2, N))     # what goes to the hall
wet_f = np.zeros((2, N))

# chords from the display waking: (bass, pad notes). The proxy's bar is cut short by its failure; the music
# feels its way back after Safari's error, and the last chord opens as the halves of the mark meet.
G9 = (31, [59, 62, 66, 69])
D_F = (42, [57, 62, 64, 69])
Bm11 = (35, [57, 62, 64, 66])
Asus = (33, [57, 62, 64, 69])
Em9 = (40, [55, 59, 62, 66])
Dmaj9 = (38, [57, 61, 64, 66, 69])
A7s = (33, [55, 59, 62, 64])
DROP0, DROP1 = CUE['drop'], CUE['error'] + 0.25
BARS = {2: G9, 4: D_F, 6: Bm11, 8: Asus, 10: G9, 12: D_F, 14: Em9, 16: A7s, DROP1: Em9, 19: G9, 21: Bm11, 23: G9, 24.5: A7s, CUE['meet']: Dmaj9}
PROXY = 15.5                      # the proxy's shot: the pulse thins out, then stops with the load


def cutoff(tt):
    """The pad's low-pass over the film: opening with the display, closing in on the stalled load, wide at the end."""
    c = 700 + 1100 * span(tt, 1.8, 4.5)
    c = c + 500 * span(tt, 4.5, 15.0)
    c = c * (1 - 0.72 * span(tt, PROXY, DROP0))                      # the load stalls: the music narrows
    c = np.where(tt >= DROP1, 900 + 1500 * span(tt, DROP1, DROP1 + 2.0) + 400 * span(tt, 21, 25), c)
    c = np.where(tt >= CUE['meet'] - 0.05, 2600 + 1400 * span(tt, CUE['meet'], CUE['meet'] + 1.2), c)
    return np.maximum(c, 260)


starts = sorted(BARS)
for i, a in enumerate(starts):
    b = starts[i + 1] if i + 1 < len(starts) else DUR
    bass, notes = BARS[a]
    dur = b - a + 0.15
    last = a == CUE['meet']
    if last:
        dur = DUR - a + 0.5
    if a < DROP0 < b:
        dur = DROP0 - a
    amp = 0.9 if a >= 4 else 0.7
    for m in notes:
        place(music, pad_note(m, a, dur, cutoff, amp=amp * 0.16, att=0.6 if a == 2 else 0.3, rel=1.3), a)
    if a >= 4 and not (PROXY <= a < DROP1):
        place(music, pan(bass_note(bass + 12, min(dur, 2.0) - 0.05, amp=0.34), 0), a)
        if last:               # the last chord: the bass holds
            place(music, pan(bass_note(bass + 12, dur, amp=0.3), 0), a)
# the opening: a low drone under the dark, the light coming up
nd = int(2.6 * SR)
tt = np.arange(nd) / SR
drone = (np.sin(TAU * hz(38) * tt) + 0.3 * np.sin(TAU * hz(45) * tt)) * sm(tt / 1.2) * np.where(tt < 2.0, 1, np.cos(np.clip((tt - 2.0) / 0.6, 0, 1) * np.pi / 2))
place(music, pan(drone * 0.16, 0), 0.0)

# the pulse: soft kick on the whole seconds, eighth-note plucks over the chord, quiet ticks on the off-beats
ARP = {2: [74, 78, 81, 78], 4: [74, 76, 81, 76], 6: [74, 76, 78, 76], 8: [74, 76, 81, 76], 10: [74, 78, 81, 83],
       12: [74, 76, 81, 76], 14: [74, 78, 79, 78], 16: [74, 76, 79, 76], DROP1: [74, 78, 79, 78], 19: [74, 78, 81, 78],
       21: [74, 76, 78, 81], 23: [74, 78, 81, 83], 24.5: [74, 76, 79, 81]}
arp_keys = sorted(ARP)
for k in range(int(DUR / 0.25)):
    at = k * 0.25
    if at < CUE['dive'][1] or at >= 25.5 or CUE['stall'] - 0.01 <= at < DROP1 + 0.25:
        continue
    pat = ARP[max(a for a in arp_keys if a <= at)]
    m = pat[k % 4]
    acc = 1.0 if k % 8 == 0 else 0.7 if k % 2 == 0 else 0.55
    lvl = 0.07 * acc * (0.6 + 0.4 * min(1, (at - 4.5) / 4)) * (1 - 0.5 * float(np.clip((at - PROXY) / 0.8, 0, 1)) * (at < DROP1))
    p = 0.35 if k % 2 else -0.35
    place(music, pan(pluck(m, lvl), p), at)
    place(wet_m, pan(pluck(m, lvl * 1.4), -p), at)
    place(music, pan(pluck(m, lvl * 0.35, decay=0.14), -p), at + 0.375)      # an echo a dotted eighth later
    if k % 4 == 0 and at >= 5.0 and not (PROXY <= at < DROP1 + 0.5):
        place(music, pan(kick(0.42 if at % 2 == 0 else 0.3), 0), at)
    if k % 2 == 1 and 7.0 <= at < 25.0 and not (PROXY <= at < DROP1 + 0.5):
        place(music, pan(tick(0.025, fc=7500, decay=0.02), 0.5 if k % 4 == 1 else -0.5), at)

# MARK: Effects, on the picture
# the name: the seam of light crosses the dark and leaves the name behind it
b0, b1 = CUE['brand']
place(fx, whoosh(b1 - b0 + 0.25, amp=0.15, f_lo=600, f_hi=8000, p0=-0.9, p1=0.6, peak=0.6), b0 - 0.05)
place(wet_f, whoosh(b1 - b0 + 0.25, amp=0.1, f_lo=600, f_hi=8000, p0=-0.9, p1=0.6, peak=0.6), b0 - 0.05)
place(fx, pan(impact(0.4, f0=64, f1=33, decay=1.0, noise=0.12), 0), b1 - 0.1)
for m, d, a in ((74, 0.0, 0.09), (81, 0.06, 0.06), (86, 0.12, 0.035), (90, 0.2, 0.02)):
    place(fx, pan(bell(m, a, dur=3.0, index=0.9), 0.1), b1 - 0.1 + d)
    place(wet_f, pan(bell(m, a * 1.7, dur=3.0, index=0.9), -0.1), b1 - 0.1 + d)
place(wet_f, sparkle(b1 - 0.1, b1 + 1.0, 25, 3, amp=0.035, lo=3500, hi=9000), b1 - 0.1)
o0, o1 = CUE['brandOut']
place(fx, riser(o1 - o0 + 0.1, amp=0.08, f_lo=400, f_hi=6000, p0=0, p1=0), o0)
lid0, lid1 = CUE['lid']
place(fx, whoosh(lid1 - lid0 + 0.4, amp=0.04, f_lo=200, f_hi=1400, p0=-0.2, p1=0.2, peak=0.7), lid0)
for m, d, a in ((74, 0.0, 0.08), (81, 0.09, 0.06), (86, 0.18, 0.035)):       # the display wakes
    place(fx, pan(bell(m, a, dur=3.5), 0.1), CUE['wake'] + 0.25 + d)
    place(wet_f, pan(bell(m, a * 1.6, dur=3.5), -0.1), CUE['wake'] + 0.25 + d)
l0, l1 = CUE['lift']
place(fx, sparkle(l0, l1, 6, 30, amp=0.035), l0)
place(wet_f, sparkle(l0, l1, 6, 30, amp=0.05), l0)
# into the screen, and the windows
d0, d1 = CUE['dive']
place(fx, riser(d1 - d0 + 0.5, amp=0.16, p0=0.3, p1=0), d0 - 0.5)
place(fx, pan(impact(0.55), 0), d1)
place(wet_f, pan(impact(0.35, noise=0.6), 0), d1)
s0, s1 = CUE['spread']
place(fx, whoosh(0.9, amp=0.06, f_lo=300, f_hi=2500, p0=-0.5, p1=0.5, peak=0.4), s0)
t0_, t1_ = CUE['through']
place(fx, whoosh(t1_ - t0_ + 0.15, amp=0.11, f_lo=500, f_hi=5000, p0=0.1, p1=-0.4), t0_ - 0.06)
# the countries roll past
for i, at in enumerate(CUE['countries']):
    if i:
        for j in range(3):
            place(fx, pan(tick(0.05, fc=2600 + 500 * j, decay=0.01), 0.45), at - 0.12 + 0.05 * j)
    place(fx, pan(tick(0.1, fc=3200 + 600 * i, decay=0.03), 0.4), at + 0.04)
    place(fx, pan(bell(86 + [0, 2, 4][i], 0.025, dur=1.2, index=0.8), 0.4), at + 0.06)
place(wet_f, sparkle(CUE['chord'], CUE['chord'] + 0.4, 30, 5, amp=0.02), CUE['chord'])
# Safari and the profile: the book swings open; each row is read across both pages and confirmed
v0, v1 = CUE['vsIn']
place(fx, whoosh(v1 - v0 + 0.3, amp=0.1, f_lo=250, f_hi=3000, p0=0, p1=0, peak=0.35), v0 - 0.15)
place(fx, pan(impact(0.3, f0=58, f1=36, decay=0.5, noise=0.1), 0), v0)
for i, r in enumerate(CUE['rows']):
    place(fx, whoosh(0.36, amp=0.06, f_lo=2000, f_hi=9000, p0=-0.7, p1=0.7, peak=0.5), r)
    place(fx, pan(pluck([86, 90, 93][i], 0.07, decay=0.3), 0), r + 0.3)
    place(wet_f, pan(pluck([86, 90, 93][i], 0.08, decay=0.3), 0), r + 0.3)
f0_, f1_ = CUE['fly']
place(fx, riser(f1_ - f0_ + 0.25, amp=0.14, f_lo=500, f_hi=9000, p0=0, p1=0), f0_ - 0.25)
place(fx, pan(impact(0.62, f0=80, f1=33), 0), CUE['slam'])
place(wet_f, pan(impact(0.4, noise=0.7), 0), CUE['slam'])
for m, d, a in ((81, 0.02, 0.04), (88, 0.07, 0.025)):
    place(wet_f, pan(bell(m, a * 1.5, dur=2.5), 0), CUE['slam'] + d)
for a, b in (CUE['wipe1'], CUE['wipe2']):                                      # the seam crosses
    place(fx, whoosh(b - a + 0.25, amp=0.16, f_lo=700, f_hi=7000, p0=-0.9, p1=0.9, peak=0.5), a - 0.05)
    place(wet_f, whoosh(b - a + 0.25, amp=0.1, f_lo=700, f_hi=7000, p0=-0.9, p1=0.9, peak=0.5), a - 0.05)
# isolation: a note for each layer as it is named
for i, at in enumerate(CUE['words']):
    m = [74, 78, 81, 83, 86][i]
    place(fx, pan(pluck(m, 0.06, decay=0.22), 0.5), at)
    place(wet_f, pan(pluck(m, 0.06, decay=0.22), -0.3), at)
# the proxy: the click on "Weiter", the load ticking away, slowing, stopping; then the power goes
place(fx, pan(tick(0.16, fc=2500, decay=0.02), 0.1), CUE['press'])
tk, k = CUE['press'] + 0.12, 0
while tk < CUE['stall']:
    place(fx, pan(tick(0.05, fc=5200, decay=0.008), 0.25), tk)
    tk += 0.06 + 0.012 * k
    k += 1
nh = int((DROP0 - CUE['stall']) * SR)
tt = np.arange(nh) / SR
hold = np.sin(TAU * hz(86) * tt) * (0.5 + 0.5 * np.sin(TAU * 7 * tt)) * sm(tt / 0.25) * 0.018
place(fx, pan(hold, 0.2), CUE['stall'])
nd = int(0.18 * SR)
tt = np.arange(nd) / SR
down = np.sin(TAU * np.cumsum(420 * np.exp(-tt / 0.05) + 50) / SR) * np.exp(-tt / 0.06) * 0.12
place(fx, pan(down, 0), DROP0)
place(fx, pan(impact(0.42, f0=60, f1=34, decay=0.5, noise=0.15), 0), CUE['error'])
# the encryption: the light sweeps the data, the code closes into a lock, the lock is lit
s0, s1 = CUE['sweep']
place(fx, whoosh(s1 - s0 + 0.2, amp=0.11, f_lo=1500, f_hi=9000, p0=-0.7, p1=0.7, peak=0.6), s0)
place(fx, sparkle(s0, s1, 20, 50, amp=0.025, lo=4000, hi=9000), s0)
k0, k1 = CUE['lock']
tk = k0
while tk < k1:
    place(fx, pan(tick(rng.uniform(0.012, 0.03), fc=rng.uniform(3000, 8000), decay=0.006), rng.uniform(-0.6, 0.6)), tk)
    tk += rng.exponential(0.07 * (1 - 0.7 * (tk - k0) / (k1 - k0)))
for m, d, a in ((81, 0, 0.08), (88, 0.07, 0.04)):
    place(fx, pan(bell(m, a, dur=2.5), -0.1), k1 + d)
    place(wet_f, pan(bell(m, a * 1.5, dur=2.5), 0.1), k1 + d)
# the warm-up: a page turning for each site
for i, at in enumerate(CUE['pages']):
    place(fx, whoosh(0.32, amp=0.045, f_lo=900, f_hi=3500, p0=-0.3 + 0.2 * i, p1=0.2 + 0.2 * i, peak=0.3), at)
    place(fx, pan(tick(0.04, fc=6000, decay=0.01), 0.4), at + 0.15)
# the features: each tile on its eighth note, a little higher each time
for i, at in enumerate(CUE['tiles']):
    m = [74, 78, 81, 83, 86, 90][i]
    place(fx, pan(pluck(m, 0.06, decay=0.25), -0.5 + 0.2 * i), at)
    place(wet_f, pan(pluck(m, 0.06, decay=0.25), 0.5 - 0.2 * i), at)
# the end: a long rise into the meeting of the halves, the hit, the last chord with a shimmer over it
mt = CUE['meet']
place(fx, riser(mt - 25.6, amp=0.15, f_lo=200, f_hi=9000, p0=-0.3, p1=0.3), 25.6)
place(fx, pan(impact(0.62, f0=66, f1=30, decay=1.2, noise=0.25), 0), mt)
place(wet_f, pan(impact(0.4, noise=0.5), 0), mt)
for m, d, a in ((86, 0.0, 0.07), (93, 0.05, 0.04), (90, 0.11, 0.035), (98, 0.18, 0.02)):
    place(fx, pan(bell(m, a, dur=3.0, index=1.0), 0.15), mt + d)
    place(wet_f, pan(bell(m, a * 1.8, dur=3.0, index=1.0), -0.15), mt + d)
place(wet_f, sparkle(mt, mt + 1.6, 30, 4, amp=0.04, lo=3500, hi=9000), mt)
place(fx, pan(bell(81, 0.03, dur=2.0, index=0.6), 0), CUE['name'])

# MARK: Mix
ir = make_ir()
hall_m = convolve(wet_m + 0.32 * music, ir) * 0.32
hall_f = convolve(wet_f + 0.25 * fx, ir) * 0.36
tt = np.arange(N) / SR
# the proxy's failure: the music and its hall stop dead, and feel their way back after the error
gate = np.ones(N)
gate = np.where((tt >= DROP0) & (tt < DROP1), 0.0, gate)
gate *= 1 - span(tt, DROP0 - 0.012, DROP0) * (tt < DROP1)
gate = np.where(tt >= DROP1, sm((tt - DROP1) / 0.8), gate)
mix = (music + hall_m) * gate + fx + hall_f
# the ending: everything breathes out over the last seconds
f0, f1 = CUE['fade']
mix *= np.where(tt > f0, np.cos(np.clip((tt - f0) / (f1 - f0), 0, 1) * np.pi / 2) ** 1.5, 1.0)
mix[:, :int(0.004 * SR)] *= np.linspace(0, 1, int(0.004 * SR))
# the level: about -15 dBFS RMS over the film (web video sits near -14 LUFS), and a soft ceiling at -1 dBFS
# that only the hits reach
mix *= 10 ** (-15 / 20) / np.sqrt(np.mean(mix ** 2))
ceil = 10 ** (-1 / 20)
mix = np.where(np.abs(mix) < 0.5 * ceil, mix, np.sign(mix) * (0.5 * ceil + 0.5 * ceil * np.tanh((np.abs(mix) - 0.5 * ceil) / (0.5 * ceil))))
peak, rms = np.abs(mix).max(), np.sqrt(np.mean(mix ** 2))
print(f'sound: {DUR:.1f} s, peak {20 * np.log10(peak):.1f} dBFS, rms {20 * np.log10(rms):.1f} dBFS')

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..', '..', 'video', '.cache', 'sound.wav')
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
pcm = np.clip(np.rint(mix.T * 32767 + rng.triangular(-1, 0, 1, mix.T.shape)), -32768, 32767).astype('<i2')
with wave.open(out, 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(pcm.tobytes())
print(f'WROTE {os.path.relpath(out)}')
