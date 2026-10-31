"""Lay the owner's licensed track under the film (spec v2 §3, "What we do once he commits a WAV"). numpy only.

    python3 -I tools/film/mix.py TRACK.wav [options]
      → video/.cache/mix.wav          the film's soundtrack: 30.0 s, 48 kHz, 24-bit, −14 LUFS, ≤ −1 dBTP
        video/.cache/music-edit.wav   the music edit alone (before the foley and the loudness gain), for listening
        video/.cache/retime.csv       where each hard cut would move to land on the track's beat (≤ ±0.12 s)
        video/.cache/mix-report.txt   what was measured and decided, with the QA numbers
    then: sh tools/film/encode.sh ru --audio video/.cache/mix.wav

1. Measure. Onset envelope (spectral flux over 40 log bands, 2048/256 STFT). Tempo by autocorrelation of the
   envelope (a gentle prior around 120 bpm), refined by a comb over 8 multiples; beats by dynamic programming
   (Ellis 2007). Downbeat phase: of the four beat phases, the one whose beats carry the most low-band (< 150 Hz)
   onset energy (plus harmonic change). Sections: novelty of a beat-synchronous self-similarity matrix (Foote's
   checkerboard kernel). 4/4 is assumed.
2. Edit. The film is cut by the spec's must-hit points: a track bar line on 8.5 («Сразу.»), the last strong
   downbeat or chord on 27.0 (cues.seat). Part A (film 0–18.5) is anchored at 8.5: every bar line of the track is
   tried, scored for an empty name (0–1.5), a pulse under the burst (5.5–7.0), a strong downbeat on 8.5 and a
   thinner texture under the comparison (11.5–13.5); one splice is allowed if it scores clearly better. Part B
   (19.0–29.5) is anchored at 27.0 on the track's final strong chord and starts on the bar line nearest 19.0.
   Splices are on bar lines with equal-power crossfades that end on the bar line (the downbeat stays intact).
   The music is silent before 1.5 and is gated hard at 18.5 (closed by 18.5, an 8 ms ramp, so within 10 ms),
   opens again at 19.0 (or B's first bar line, if later), and ends with the picture at 29.5 (0.1 s fade).
3. Retime. For each hard cut, the nearest track beat in film time; a proposal when it is within ±0.12 s. The stage
   re-captures; renderer sequences (R1, R2, R3) are re-rendered only when their duration changes > 2 frames.
4. Mix. Music high-passed at 30 Hz (4th-order Butterworth). The foley stem (foley.py) laid 20–25 dB under the music
   (default 22.5): the loudness of its events, room tone excluded, against the music's. Normalised to −14 LUFS
   integrated (BS.1770-4) and limited to −1 dBTP by a look-ahead limiter on the 4×-oversampled peak (no clipper),
   iterated until both hold. The film's digital zero (18.5–19.0) stays exact.

Overrides, when the measurement is wrong (a person who has listened decides): --bpm, --downbeat SEC (any bar line,
track time), --anchor SEC (the bar line to put on 8.5), --final SEC (the chord to put on 27.0), --edit
"FILM@TRACK,…" (segments by hand: each starts at film time FILM playing the track from TRACK), --under DB.
"""
import argparse
import csv
import importlib.util
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.abspath(os.path.join(HERE, '..', '..'))
CACHE = os.path.join(SITE, 'video', '.cache')


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


L = _load('soundlib')
Q = _load('soundqa')
SR = L.SR
HOP = 256
NFFT = 2048
FPS = SR / HOP                 # analysis frames a second (187.5)
T0 = NFFT / 2 / SR             # a frame's time is its window's centre
FINE = 48                      # the fine onset envelope: 1 ms steps


def t2f(t):
    return np.round((np.asarray(t, dtype=np.float64) - T0) * FPS).astype(int)

DEFAULT_CUES = {'lid': [1.8, 2.9], 'settle': 2.9, 'click': 16.5, 'zero': [18.5, 19.0], 'seat': 27.0, 'end': 29.5}
MUST = {'open': 1.5, 'pulse': [5.5, 7.0], 'downbeat': 8.5, 'thin': [11.5, 13.5], 'reentry': [19.0, 20.5]}


def read_timeline():
    try:
        tl = json.load(open(os.path.join(HERE, 'timeline.json')))
    except (OSError, ValueError):
        tl = {}
    cues = dict(DEFAULT_CUES)
    cues.update({k: v for k, v in (tl.get('cues') or {}).items() if k in DEFAULT_CUES})
    return tl, cues, float(tl.get('duration', 30.0))


def load_track(path):
    """→ stereo float64 at 48 kHz. WAV is read in numpy; anything else is decoded by ffmpeg to float WAV first."""
    if path.lower().endswith(('.wav', '.wave')):
        x, sr = L.read_wav(path)
    else:
        raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 'f32le', '-acodec', 'pcm_f32le', '-ac', '2', '-'],
                             check=True, capture_output=True).stdout
        probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_entries', 'stream=sample_rate',
                                '-of', 'default=nw=1:nk=1', path], check=True, capture_output=True, text=True).stdout
        sr = int(probe.strip())
        x = np.frombuffer(raw, dtype='<f4').astype(np.float64).reshape(-1, 2).T
    if x.shape[0] == 1:
        x = np.vstack([x, x])
    x = x[:2]
    if sr != SR:
        x = L.resample(x, sr, SR)
    return x, sr


# ---------------------------------------------------------------------------------------------------- analysis

def features(mono):
    """Per STFT frame: log band energies (40), low-band (< 150 Hz) energy, chroma (12), power. Chunked."""
    n = len(mono)
    nfr = 1 + max(0, (n - NFFT) // HOP)
    f = np.fft.rfftfreq(NFFT, 1 / SR)
    edges = np.geomspace(30, 16000, 41)
    band = np.digitize(f, edges) - 1                     # −1 below 30 Hz, 40 above 16 kHz
    low = (f >= 30) & (f < 150)
    cmask = (f >= 65) & (f < 4000)
    pc = np.zeros(len(f), dtype=int)
    pc[cmask] = np.round(12 * np.log2(f[cmask] / 440.0)).astype(int) % 12
    win = np.hanning(NFFT)
    B = np.zeros((nfr, 40), dtype=np.float32)
    LOW = np.zeros(nfr, dtype=np.float32)
    C = np.zeros((nfr, 12), dtype=np.float32)
    P = np.zeros(nfr, dtype=np.float64)
    step = 1024
    for s in range(0, nfr, step):
        idx = np.arange(s, min(nfr, s + step))
        fr = np.stack([mono[i * HOP:i * HOP + NFFT] for i in idx]) * win
        S = np.abs(np.fft.rfft(fr, axis=1)) ** 2
        P[idx] = S.sum(axis=1) / (NFFT * np.sum(win ** 2) / 2)
        for b in range(40):
            B[idx, b] = S[:, band == b].sum(axis=1)
        LOW[idx] = S[:, low].sum(axis=1)
        mag = np.sqrt(S[:, cmask])
        for k in range(12):
            C[idx, k] = mag[:, pc[cmask] == k].sum(axis=1)
    return B, LOW, C, P


def onset_env(E, lag=1):
    """Spectral flux of log energies (half-wave rectified), local mean removed. E: frames × bands (or frames)."""
    Ld = 10 * np.log10(np.atleast_2d(E.T).T + 1e-10)
    if Ld.ndim == 1:
        Ld = Ld[:, None]
    fl = np.zeros(Ld.shape[0])
    fl[lag:] = np.maximum(Ld[lag:] - Ld[:-lag], 0).sum(axis=1)
    k = int(0.4 * FPS)
    mean = np.convolve(fl, np.ones(2 * k + 1) / (2 * k + 1), mode='same')
    o = np.maximum(fl - mean, 0)
    return o / (o.std() + 1e-9)


def tempo(o, hint=None):
    """Tempo by autocorrelation of the onset envelope, a log-Gaussian prior (1 octave) around 120 bpm (or the
    hint), refined by a comb of 8 multiples. → (bpm, period in frames, confidence)."""
    n = len(o)
    m = L.fast_len(2 * n)
    F = np.fft.rfft(o - o.mean(), m)
    ac = np.fft.irfft(np.abs(F) ** 2, m)[:n]
    ac /= ac[0] + 1e-12
    lags = np.arange(1, n)
    bpm = 60 * FPS / lags
    sel = (bpm >= 60) & (bpm <= 200)
    centre = hint or 120.0
    prior = np.exp(-0.5 * (np.log2(bpm[sel] / centre) / 1.0) ** 2)
    score = ac[1:][sel] * prior
    lag0 = lags[sel][np.argmax(score)]
    if hint:
        lag0 = 60 * FPS / hint
    grid = np.linspace(lag0 * 0.97, lag0 * 1.03, 241)
    comb = [sum(np.interp(k * g, np.arange(n), ac) / k ** 0.5 for k in range(1, 9)) for g in grid]
    P = float(grid[int(np.argmax(comb))]) if not hint else float(lag0)
    conf = float(np.interp(P, np.arange(n), ac))
    return 60 * FPS / P, P, conf


def beat_track(o, P, tight=100.0):
    """Dynamic-programming beat tracker (Ellis 2007): maximise onset strength minus tightness·log²(interval/P)."""
    n = len(o)
    score = o.astype(np.float64).copy()
    back = -np.ones(n, dtype=int)
    lo, hi = int(round(P / 2)), int(round(2 * P))
    offs = np.arange(lo, hi + 1)
    pen = -tight * np.log(offs / P) ** 2
    for t in range(hi, n):
        cand = score[t - offs] + pen
        k = int(np.argmax(cand))
        if cand[k] > 0:
            score[t] = o[t] + cand[k]
            back[t] = t - offs[k]
    # end on the best score in the last period
    tail = np.arange(max(0, n - int(P) - 1), n)
    t = int(tail[np.argmax(score[tail])])
    beats = [t]
    while back[t] >= 0:
        t = back[t]
        beats.append(t)
    beats = np.array(beats[::-1], dtype=float)
    # extend at the start with the period where the DP chain begins late (a quiet intro)
    while beats[0] - P >= 0:
        beats = np.concatenate([[beats[0] - P], beats])
    # sub-frame: parabolic peak of o within ±2 frames when there is one
    out = []
    for b in beats:
        i = int(round(b))
        j0, j1 = max(1, i - 2), min(n - 2, i + 2)
        if j1 <= j0:
            out.append(b)
            continue
        k = j0 + int(np.argmax(o[j0:j1 + 1]))
        y0, y1, y2 = o[k - 1], o[k], o[k + 1]
        d = (y0 - y2) / (2 * (y0 - 2 * y1 + y2)) if (y0 - 2 * y1 + y2) < 0 else 0.0
        out.append(k + float(np.clip(d, -0.5, 0.5)) if y1 > 0.5 else b)
    return np.array(out) / FPS + T0


def fine_flux(mono):
    """A 1 ms onset envelope: log energy over 2 ms in four bands (< 200, 200–2k, 2k–8k, > 8 kHz), its rise over
    2 ms, summed. Sharp enough to put a beat on its attack within a millisecond or two."""
    w = 2 * FINE
    bands = [L.butter('lp', 200, 4), L.butter('hp', 200, 4) + L.butter('lp', 2000, 4),
             L.butter('hp', 2000, 4) + L.butter('lp', 8000, 4), L.butter('hp', 8000, 4)]
    idx = np.arange(w, len(mono), FINE)
    out = np.zeros(len(idx))
    for sos in bands:
        y = L.sosfilt(mono, sos, pad=SR // 4)
        cs = np.concatenate([[0], np.cumsum(y * y)])
        e = (cs[idx] - cs[idx - w]) / w
        ld = 10 * np.log10(e + 1e-11)
        d = np.zeros(len(ld))
        d[2:] = np.maximum(ld[2:] - ld[:-2], 0)
        out += d
    return out, (idx - FINE) / SR          # time ≈ where the attack is when its rise is steepest


def refine_beats(beats, ff, ft, period, win=0.05):
    """Move each beat to the steepest attack within ±win on the fine envelope, when there is a clear one; then,
    if the track is steady (≥ 70 % of beats within 15 ms of one straight line, < 8 ms RMS), replace the beats by
    that grid across the whole track. → (beats, steady, grid bpm, residual ms)."""
    med = np.median(ff)
    mad = np.median(np.abs(ff - med)) + 1e-9
    thr = med + 6 * mad
    rb, sharp = [], []
    for b in beats:
        i0, i1 = np.searchsorted(ft, b - win), np.searchsorted(ft, b + win)
        k = i0 + int(np.argmax(ff[i0:i1])) if i1 - i0 >= 3 else None
        ok = k is not None and ff[k] > thr
        rb.append(float(ft[k]) if ok else b)
        sharp.append(ok)
    rb, sharp = np.array(rb), np.array(sharp)
    # judge steadiness on the beats with a clear attack only: in a soft intro the tracked beats wander
    k = np.round((rb - rb[0]) / period).astype(float)
    use = sharp if sharp.sum() >= 8 else np.ones(len(rb), bool)
    fit = np.polyfit(k[use], rb[use], 1)
    inl = use.copy()
    for _ in range(4):
        r = rb - np.polyval(fit, k)
        inl = use & (np.abs(r) < 0.015)
        if inl.sum() < 4:
            break
        fit = np.polyfit(k[inl], rb[inl], 1)
    r = rb - np.polyval(fit, k)
    rms = float(np.sqrt(np.mean(r[inl] ** 2))) * 1000 if inl.any() else 1e9
    steady = inl.sum() >= 0.7 * use.sum() and use.sum() >= 0.3 * len(rb) and rms < 8
    if steady:
        p, b0 = fit[0], fit[1]
        k0 = -int(np.floor(b0 / p))
        kk = np.arange(k0, int((ft[-1] - b0) / p) + 1)
        grid = b0 + kk * p
        return grid[(grid >= 0) & (grid <= ft[-1])], True, 60 / p, rms
    return rb, False, 60 / fit[0], rms


def downbeat_phase(beats, o_low, chroma):
    """Which of the 4 beat phases is beat 1: low-band onset energy at the beat (weight 1) and harmonic change
    into the beat (weight 0.5), z-scored. → (phase, scores, confidence)."""
    fi = np.clip(t2f(beats), 0, len(o_low) - 1)
    low = np.array([o_low[max(0, i - 2):i + 3].max() for i in fi])
    cn = chroma / (np.linalg.norm(chroma, axis=1, keepdims=True) + 1e-9)
    ch = []
    for k, i in enumerate(fi):
        prev = fi[k - 1] if k > 0 else max(0, i - 40)
        nxt = fi[k + 1] if k + 1 < len(fi) else min(len(cn), i + 40)
        a = cn[prev:i].mean(axis=0) if i > prev else cn[i]
        b = cn[i:nxt].mean(axis=0) if nxt > i else cn[i]
        ch.append(1 - float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9)))
    ch = np.array(ch)
    z = lambda v: (v - v.mean()) / (v.std() + 1e-9)
    s = z(low) + 0.5 * z(ch)
    scores = np.array([s[p::4].mean() if len(s[p::4]) else -9 for p in range(4)])
    order = np.argsort(scores)[::-1]
    conf = float(scores[order[0]] - scores[order[1]])
    return int(order[0]), scores, conf, low


def novelty(beats, B, C, kernel=16):
    """Foote novelty on beat-synchronous features (40 log bands + chroma), checkerboard kernel of `kernel` beats."""
    fi = np.clip(t2f(beats), 0, len(B) - 1)
    feats = []
    for k in range(len(fi)):
        a, b = fi[k], fi[k + 1] if k + 1 < len(fi) else min(len(B), fi[k] + 40)
        b = max(b, a + 1)
        lb = np.log10(B[a:b].mean(axis=0) + 1e-10)
        cc = C[a:b].mean(axis=0)
        cc = cc / (np.linalg.norm(cc) + 1e-9)
        feats.append(np.concatenate([lb, 2 * cc]))
    F = np.array(feats)
    F = (F - F.mean(axis=0)) / (F.std(axis=0) + 1e-9)
    F /= np.linalg.norm(F, axis=1, keepdims=True) + 1e-9
    S = F @ F.T
    h = kernel // 2
    g = np.exp(-0.5 * ((np.arange(-h, h) + 0.5) / (h / 2)) ** 2)
    sign = np.sign(np.arange(-h, h) + 0.5)
    K = np.outer(g * sign, g * sign)
    nov = np.zeros(len(F))
    Sp = np.pad(S, h, mode='edge')
    for i in range(len(F)):
        nov[i] = np.sum(K * Sp[i:i + 2 * h, i:i + 2 * h])
    nov = np.maximum(nov, 0)
    return nov / (nov.max() + 1e-9), F


def analyse(x, bpm_hint=None, downbeat_at=None):
    mono = x.mean(axis=0)
    B, LOW, C, P = features(mono)
    o = onset_env(B)
    o_low = onset_env(LOW)
    bpm, per, conf = tempo(o, bpm_hint)
    beats = beat_track(o, per)
    ff, ft = fine_flux(mono)
    beats, steady, grid_bpm, resid = refine_beats(beats, ff, ft, per / FPS)
    if downbeat_at is not None:
        phase = int(np.argmin(np.abs(beats - downbeat_at))) % 4
        dscores, dconf, low = None, None, None
    else:
        phase, dscores, dconf, low = downbeat_phase(beats, o_low, C)
    bars = beats[phase::4]
    nov, F = novelty(beats, B, C)
    # section boundaries: novelty peaks ≥ 8 beats apart, above mean + 1σ, snapped to the nearest bar line
    pk = [i for i in range(1, len(nov) - 1) if nov[i] >= nov[i - 1] and nov[i] > nov[i + 1] and nov[i] > nov.mean() + nov.std()]
    sel = []
    for i in sorted(pk, key=lambda i: -nov[i]):
        if all(abs(i - j) >= 8 for j in sel):
            sel.append(i)
    sections = sorted({float(bars[np.argmin(np.abs(bars - beats[i]))]) for i in sel})
    ib = np.diff(beats)
    pdb = 10 * np.log10(P + 1e-12)
    return {'bpm': bpm, 'bpm_grid': grid_bpm, 'beat_jitter_ms': resid, 'steady': steady,
            'tempo_conf': conf, 'beats': beats, 'bars': bars, 'phase': phase, 'downbeat_scores': dscores,
            'downbeat_conf': dconf, 'sections': sections, 'novelty': nov, 'o': o, 'o_low': o_low,
            'power_db': pdb, 'power': P, 'F_beats': F, 'len': x.shape[1] / SR, 'ib_ms': float(np.median(ib) * 1000)}


# ---------------------------------------------------------------------------------------------------- the edit

class Track:
    """Per-frame arrays with cumulative sums, read through an edit (segments of film time → track time)."""

    def __init__(self, A):
        self.A = A
        self.n = len(A['o'])
        self.cs_pow = np.concatenate([[0], np.cumsum(A['power'])])
        self.cs_o = np.concatenate([[0], np.cumsum(A['o'])])
        live = A['power_db'] > np.percentile(A['power_db'], 95) - 40
        self.loud = float(10 * np.log10(np.percentile(A['power'], 95) + 1e-12))
        self.o_med = float(np.median(A['o'][live])) + 1e-3 if live.any() else 1.0
        self.o_mean = float(np.mean(A['o'][live])) + 1e-3 if live.any() else 1.0

    def _sum(self, cs, a, b):
        """Sum over track seconds [a, b), zero outside the track."""
        ia = int(np.clip(round((a - T0) * FPS), 0, self.n))
        ib = int(np.clip(round((b - T0) * FPS), 0, self.n))
        return cs[ib] - cs[ia] if ib > ia else 0.0

    def mean(self, segs, fa, fb, what='pow'):
        cs = self.cs_pow if what == 'pow' else self.cs_o
        tot = 0.0
        for (s0, s1, tr) in segs:
            a, b = max(fa, s0), min(fb, s1)
            if b > a:
                tot += self._sum(cs, tr + (a - s0), tr + (b - s0))
        return tot / max(1.0, (fb - fa) * FPS)

    def db(self, segs, fa, fb):
        return 10 * np.log10(self.mean(segs, fa, fb) + 1e-12) - self.loud


def bar_strength(A):
    fi = np.clip(t2f(A['bars']), 0, len(A['o_low']) - 1)
    s = np.array([A['o_low'][max(0, i - 2):i + 3].max() + 0.5 * A['o'][max(0, i - 2):i + 3].max() for i in fi])
    return (s - s.mean()) / (s.std() + 1e-9)


def find_final(A, T):
    """The track's last strong downbeat or chord: a strong bar line followed by a decaying, sparse tail."""
    bars, z = A['bars'], bar_strength(A)
    best, bi = -1e9, None
    for j, d in enumerate(bars):
        if d < 0.35 * A['len'] or d + 1.0 > A['len']:
            continue
        here = T.db([(0, 99, d)], 0.0, 0.5)
        if z[j] <= -1.0 or here < -20:                 # a final chord is a loud bar line, not a weak one
            continue
        after_o = T.mean([(0, 99, d)], 0.25, 2.5, 'o') / T.o_mean
        decay = float(np.clip((here - T.db([(0, 99, d)], 2.0, 2.5)) / 10, -1, 2))   # rings down, but a cliff into
        s = z[j] - 1.5 * after_o + decay + 0.5 * d / A['len']                   # silence earns no more than 20 dB
        if s > best:
            best, bi = s, j
    return bi


def score_A(T, A, segs, cues, z_at):
    """Score a part-A edit for the must-hit points. Higher is better. → (score, parts)."""
    q = T.db(segs, 0, MUST['open'])
    s_q = -max(0.0, q + 24) / 8
    chop = T.db(segs, MUST['open'] - 0.5, MUST['open'])          # a sustained sound cut open by the gate at 1.5
    s_q -= max(0.0, chop + 30) / 15
    pulse = T.mean(segs, *MUST['pulse'], what='o') / T.o_mean
    s_p = 0.5 * float(np.clip(np.log2(pulse + 1e-3), -2, 2))
    s_d = 0.4 * float(np.clip(z_at, -2, 2))
    thin = T.db(segs, *MUST['thin']) - T.db(segs, MUST['pulse'][0], MUST['downbeat'])
    s_t = -max(0.0, thin + 1.0) / 4
    have = T.mean(segs, MUST['open'], cues['zero'][0])
    s_c = -2.0 if have < 10 ** ((T.loud - 50) / 10) else 0.0
    return s_q + s_p + s_d + s_t + s_c, {'quiet_0_1.5_db': round(float(q), 1), 'chopped_at_1.5_db': round(float(chop), 1),
                                          'pulse_ratio': round(float(pulse), 2), 'downbeat_z': round(float(z_at), 2),
                                          'thin_minus_pulse_db': round(float(thin), 1)}


def plan_edit(A, cues, anchor=None, final=None):
    """→ dict(segments [(film_from, film_to, track_from)], B info, scores, notes)."""
    T = Track(A)
    bars = A['bars']
    tbar = float(np.median(np.diff(bars))) if len(bars) > 1 else 4 * 60 / A['bpm']
    z = bar_strength(A)
    z0, z1 = cues['zero']
    seat, end = cues['seat'], cues['end']
    notes = []
    # part B: the final chord on 27.0
    if final is not None:
        jE = int(np.argmin(np.abs(bars - final)))
        E = float(final)
    else:
        jE = find_final(A, T)
        E = float(bars[jE]) if jE is not None else None
    if E is None:
        notes.append('no final chord found: part B is the last bars of the track')
        E = max(0.0, A['len'] - (end - seat))
        jE = int(np.argmin(np.abs(bars - E)))
    # B starts on a bar line at or after 19.0 (inside the spec's sparse re-entry, 19.0–20.5), never before the gate
    nB = max(1, int(np.floor((seat - z1) / tbar + 0.01)))
    while E - nB * tbar < 0 and nB > 1:
        nB -= 1
    b_track = float(bars[max(0, jE - nB)]) if jE - nB >= 0 else E - nB * tbar
    b_film = seat - (E - b_track)
    if b_film < z1:                       # a slightly long bar: enter at 19.0, mid-bar, keeping the chord on 27.0
        b_track += z1 - b_film
        b_film = z1
    segB = (b_film, end, b_track)
    reentry = T.db([segB], *MUST['reentry'])
    # part A: every bar line on 8.5, then one splice if it is clearly better
    db_ = MUST['downbeat']
    cands = []
    for j, d in enumerate(bars):
        if anchor is not None and abs(d - anchor) > tbar / 2:
            continue
        if d + (z0 - db_) > A['len']:
            continue
        segs = [(0.0, z0, d - db_)]
        s, parts = score_A(T, A, segs, cues, z[j])
        over = max(0.0, min(d + (z0 - db_), segB[2] + (end - segB[0])) - max(d - db_, segB[2]))
        if over > 2.0:
            s -= 0.5
        cands.append((s, segs, parts, f'contiguous, bar {j} on {db_}'))
    if not cands:
        raise SystemExit('mix: the track is too short for part A (it needs ~10 s after a bar line)')
    cands.sort(key=lambda c: -c[0])
    best = cands[0]
    # one splice before 8.5 (an intro bar, then the anchored music) or after it (drop bars to thin 11.5–13.5)
    if anchor is None:
        nbars = len(bars)
        Fb = A['F_beats']
        bar_feat = np.array([Fb[min(len(Fb) - 1, 4 * k + A['phase']):min(len(Fb), 4 * k + A['phase'] + 4)].mean(axis=0)
                             if 4 * k + A['phase'] < len(Fb) else Fb[-1] for k in range(nbars)])
        nov_bar = np.array([A['novelty'][min(len(A['novelty']) - 1, 4 * k + A['phase'])] for k in range(nbars)])
        top = [c for c in cands[:12]]
        for s0, segs0, _, _ in top:
            d = segs0[0][2] + db_
            j = int(np.argmin(np.abs(bars - d)))
            for k in (1, 2, 3, 4):
                gs = db_ + k * tbar
                if gs >= z0 - tbar:
                    break
                jl = j + k                                   # the bar that would play at gs without a splice
                for v in range(1, nbars):
                    if v == jl or bars[v] + (z0 - gs) > A['len']:
                        continue
                    segs = [(0.0, gs, d - db_), (gs, z0, float(bars[v]))]
                    s, parts = score_A(T, A, segs, cues, z[j])
                    cost = 0.4 + 0.6 * float(1 - np.dot(bar_feat[min(jl - 1, nbars - 1)], bar_feat[v - 1])) / 2 - 0.2 * nov_bar[v]
                    s -= cost
                    if s > best[0] + 0.5:
                        best = (s, segs, parts, f'bar {j} on {db_}, splice at film {gs:.2f} to bar {v}')
            for k in (1, 2, 3):
                gs = db_ - k * tbar
                if gs <= MUST['open']:
                    break
                jr = j - k                                   # the bar that plays at gs in the anchored music
                for u in range(1, nbars):
                    if u == jr:
                        continue
                    segs = [(0.0, gs, float(bars[u]) - gs), (gs, z0, d - (db_ - gs))]
                    s, parts = score_A(T, A, segs, cues, z[j])
                    cost = 0.4 + 0.6 * float(1 - np.dot(bar_feat[max(0, u - 1)], bar_feat[max(0, jr - 1)])) / 2 - 0.2 * nov_bar[max(0, jr)]
                    s -= cost
                    if s > best[0] + 0.5:
                        best = (s, segs, parts, f'the bars before bar {u} up to film {gs:.2f}, spliced into bar {jr} '
                                                f'(bar {j} on {db_})')
    segs = best[1] + [segB]
    return {'segments': segs, 'tbar': tbar, 'final': E, 'B': segB, 'reentry_db': round(reentry, 1),
            'score': round(best[0], 3), 'parts': best[2], 'how': best[3], 'notes': notes,
            'runner_up': [(round(c[0], 3), c[3]) for c in cands[1:4]]}


def parse_edit(s, cues):
    pts = []
    for part in s.split(','):
        f, t = part.split('@')
        pts.append((float(f), float(t)))
    pts.sort()
    segs = []
    for i, (f, t) in enumerate(pts):
        nxt = pts[i + 1][0] if i + 1 < len(pts) else cues['end']
        segs.append((f, nxt, t))
    return segs


def render_edit(x, segs, cues, dur, xf=0.03, open_at=MUST['open']):
    """Play the segments into a film-length buffer with equal-power crossfades that end on each join, then gate."""
    N = int(round(dur * SR))
    y = np.zeros((2, N))
    nx = int(round(xf * SR))
    z0, z1 = cues['zero']
    end = cues['end']
    joins = []
    for i, (f0, f1, tr) in enumerate(segs):
        a = int(round(f0 * SR))
        b = int(round(f1 * SR))
        # the incoming fade starts xf before the join (unless the join is inside the gate or at the start)
        join_in = i > 0 and abs(segs[i - 1][1] - f0) < 1e-6 and not (z0 - 1e-6 <= f0 <= z1 + 1e-6)
        join_out = i + 1 < len(segs) and abs(segs[i + 1][0] - f1) < 1e-6 and not (z0 - 1e-6 <= f1 <= z1 + 1e-6)
        a2 = a - nx if join_in else a
        b2 = b
        idx = np.arange(a2, b2)
        src = np.round(tr * SR).astype(int) + (idx - a)
        ok = (src >= 0) & (src < x.shape[1]) & (idx >= 0) & (idx < N)
        seg = np.zeros((2, len(idx)))
        seg[:, ok] = x[:, src[ok]]
        w = np.ones(len(idx))
        if join_in:
            u = (np.arange(nx) + 0.5) / nx
            w[:nx] = np.sin(0.5 * np.pi * u)
            joins.append(f0)
        if join_out:
            u = (np.arange(nx) + 0.5) / nx
            w[-nx:] = np.cos(0.5 * np.pi * u)
        keep = (idx >= 0) & (idx < N)
        y[:, idx[keep]] += seg[:, keep] * w[keep]
    y = L.sosfilt(y, L.butter('hp', 30.0, 4), pad=SR // 2)
    g = np.ones(N)
    o = int(round(open_at * SR))
    r = int(0.005 * SR)
    g[:max(0, o - r)] = 0
    g[max(0, o - r):o] = L.ramp(r, start_at_one=False)[:o - max(0, o - r)]
    c = int(round(z0 * SR))
    rc = int(0.008 * SR)
    g[c - rc:c] = L.ramp(rc)[::-1] * g[c - rc:c]
    # the gate reopens at z1 when a segment plays through it, else on the first segment that starts after it
    # (a hand --edit may splice again after the gate: the last segment's start is not the re-entry)
    cover = [s for s in segs if s[0] <= z1 + 1e-6 and s[1] > z1 + 1e-6]
    reopen = z1 if cover else max(z1, min([s[0] for s in segs if s[0] > z1], default=z1))
    ro = int(round(reopen * SR))
    g[c:ro] = 0
    g[ro:ro + r] *= L.ramp(r)
    e = int(round(end * SR))
    tf = int(0.1 * SR)
    g[e - tf:e] *= L.ramp(tf)[::-1]
    g[e:] = 0
    return y * g[None, :], joins, reopen


# ---------------------------------------------------------------------------------------------------- the limiter

def limiter(x, ceiling_db=-1.0, margin_db=0.1, look=128, release=0.05):
    """Look-ahead peak limiter on the 4×-oversampled peak (ideal band-limited interpolation, the stricter of the two
    meters in soundlib). Gain ≤ ceiling/peak at every sample by construction:
    a trailing minimum over `look` samples smoothed by a forward box of the same length; release exponential in
    dB (time constant `release` s). No clipper. → (y, max gain reduction dB)."""
    n = x.shape[1]
    os4 = np.abs(L.oversample_fft(x, 4)).max(axis=0).reshape(n, 4).max(axis=1)
    p = np.maximum(os4, np.concatenate([[0], os4[:-1]]))
    c = 10 ** ((ceiling_db - margin_db) / 20)
    r = np.minimum(1.0, c / np.maximum(p, 1e-12))
    m = r.copy()
    w = 1
    while w < look:
        m[w:] = np.minimum(m[w:], m[:-w].copy())
        w *= 2
    W = w
    cs = np.concatenate([[0], np.cumsum(np.concatenate([m, np.ones(W)]))])
    g1 = (cs[W:W + n] - cs[:n]) / W
    gr1 = -20 * np.log10(np.maximum(g1, 1e-9))
    la = -1.0 / (release * SR)
    k = np.arange(n)
    with np.errstate(divide='ignore'):
        lg = np.log(np.maximum(gr1, 0))
    acc = np.maximum.accumulate(lg - k * la)
    gr = np.exp(acc + k * la)
    gr = np.maximum(gr, gr1)
    g = 10 ** (-gr / 20)
    return x * g[None, :], float(gr.max())


def master(y, target=-14.0, ceiling=-1.0):
    """Gain to the target loudness, limit, re-measure, repeat until both hold."""
    gain = target - L.loudness(y)['integrated']
    margin = 0.1
    prev = None
    for it in range(8):
        out, gr = limiter(y * L.undb(gain), ceiling, margin)
        lo = L.loudness(out)['integrated']
        tp = max(L.true_peak(out), L.true_peak_fft(out))
        if tp <= ceiling and abs(lo - target) <= 0.05:
            break
        if tp > ceiling:
            margin += tp - ceiling + 0.05
        if abs(lo - target) > 0.05:
            # secant on loudness vs gain: under heavy limiting 1 dB more gain buys less than 1 LU
            slope = 1.0
            if prev is not None and abs(gain - prev[0]) > 1e-3:
                slope = float(np.clip((lo - prev[1]) / (gain - prev[0]), 0.2, 1.0))
            prev = (gain, lo)
            gain += (target - lo) / slope
    return out, {'gain_db': gain, 'limiter_max_gr_db': gr, 'lufs': lo, 'tp': tp, 'iterations': it + 1, 'margin_db': margin}


# ---------------------------------------------------------------------------------------------------- retime

def retime(A, segs, tl, cues, fps=60):
    """Each hard cut against the nearest track beat in film time. → rows."""
    beats_film = []
    for f0, f1, tr in segs:
        bt = A['beats'][(A['beats'] >= tr) & (A['beats'] < tr + (f1 - f0))]
        beats_film += list(f0 + (bt - tr))
    beats_film = np.array(sorted(b for b in beats_film if 0 <= b <= cues['end']))
    # 1.5 is fixed too: render_edit keeps the music gated until MUST['open'], so a beat before it is inaudible and
    # moving the S02 cut onto it would only change R1's length (a re-render) for nothing
    fixed = {0.0, MUST['open'], cues['zero'][0], cues['zero'][1], cues['end'], 30.0}
    halves = (beats_film[:-1] + beats_film[1:]) / 2 if len(beats_film) > 1 else beats_film
    film_beat = 60.0 / float(tl.get('bpm', 120))
    rows = []
    for e in tl.get('events', []):
        if e.get('sync') != 'hard':
            continue
        t = float(e['t'])
        if len(beats_film) == 0:
            break
        # a cut on the film's eighth (the S04 burst, the S10 footer) goes to the track's eighth, the rest to its beat
        eighth = abs((t / film_beat) % 1 - 0.5) < 1e-6
        grid = halves if eighth else beats_film
        b = float(grid[np.argmin(np.abs(grid - t))])
        d = b - t
        inside = {'S02': 'R1', 'S05': 'R2', 'S19': 'R3'}.get(e['shot']) if e['event'] != 'cut' else None
        if any(abs(t - f) < 1e-6 for f in fixed):
            prop, note = t, 'fixed (the film start, the music opening at 1.5, the gate or the end)'
        elif inside:
            prop, note = t, f'inside render {inside}: not moved (it would need a re-render; {d:+.3f} s to the beat)'
        elif abs(d) * fps < 0.5:
            prop, note = t, 'on the beat'
        elif abs(d) <= 0.12:
            prop, note = round(b * fps) / fps, 'move'
        elif abs(d) > 0.5 * film_beat * 1.6:
            prop, note = t, 'no music here (before the track starts, or in the gap after the gate); leave'
        else:
            prop, note = t, f'no beat within 0.12 s ({d:+.3f}); leave'
        rows.append({'t': t, 'frame': round(t * fps), 'shot': e['shot'], 'event': e['event'], 'beat_film': round(b, 4),
                     'delta_s': round(d, 4), 'proposed_t': round(prop, 4), 'proposed_frame': round(prop * fps), 'note': note})
    # renderer sequences: their duration changes when their cut points move
    rend = []
    shots = {s['id']: s for s in tl.get('shots', [])}
    moves = {(r['shot'], r['event']): r['proposed_t'] for r in rows}
    for sid, name in (('S02', 'R1'), ('S05', 'R2'), ('S19', 'R3')):
        if sid not in shots:
            continue
        s = shots[sid]
        a = moves.get((sid, 'cut'), s['from'])
        nxt = [k for k in shots if shots[k]['from'] == s['to']]
        b = moves.get((nxt[0], 'cut'), s['to']) if nxt else s['to']
        dfr = round((b - a) * fps) - round((s['to'] - s['from']) * fps)
        rend.append((name, sid, a, b, dfr, 're-render' if abs(dfr) > 2 else 'time-remap only'))
    return rows, rend


# ---------------------------------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description='Lay a licensed track under the film (spec v2 §3)')
    ap.add_argument('track')
    ap.add_argument('--foley', default=os.path.join(CACHE, 'foley.wav'), help="foley stem, or 'none'")
    ap.add_argument('--out', default=os.path.join(CACHE, 'mix.wav'))
    ap.add_argument('--report', default=os.path.join(CACHE, 'mix-report.txt'))
    ap.add_argument('--retime', default=os.path.join(CACHE, 'retime.csv'))
    ap.add_argument('--under', type=float, default=22.5, help='foley events under the music, dB (20–25)')
    ap.add_argument('--lufs', type=float, default=-14.0)
    ap.add_argument('--ceiling', type=float, default=-1.0)
    ap.add_argument('--bpm', type=float)
    ap.add_argument('--downbeat', type=float, help='any bar line of the track, seconds')
    ap.add_argument('--anchor', type=float, help='track bar line to put on film 8.5, seconds')
    ap.add_argument('--final', type=float, help='track chord to put on film 27.0, seconds')
    ap.add_argument('--edit', help='segments by hand: "FILM@TRACK,FILM@TRACK,…" (seconds)')
    ap.add_argument('--xfade', type=float, default=0.03)
    o = ap.parse_args()
    under = float(np.clip(o.under, 20, 25))
    tl, cues, dur = read_timeline()
    x, sr0 = load_track(o.track)
    rep = [f'Mix report — {os.path.basename(o.track)} ({sr0} Hz → 48 kHz, {x.shape[1] / SR:.2f} s). '
           f'Measured by numpy; nobody has listened to the result.', '']
    A = analyse(x, o.bpm, o.downbeat)
    rep.append(f'tempo {A["bpm"]:.2f} bpm by autocorrelation (confidence {A["tempo_conf"]:.2f}); beats refined on a 1 ms '
               f'attack envelope fit {A["bpm_grid"]:.3f} bpm with {A["beat_jitter_ms"]:.1f} ms RMS deviation → '
               + ('a steady grid is used' if A['steady'] else 'NOT steady: the tracked beats are used as they are')
               + f' ({len(A["beats"])} beats)')
    if A['downbeat_scores'] is not None:
        rep.append(f'downbeat phase {A["phase"]} of 4 (scores {np.round(A["downbeat_scores"], 2).tolist()}, margin '
                   f'{A["downbeat_conf"]:.2f}); first bar line at {A["bars"][0]:.3f} s; {len(A["bars"])} bars')
    else:
        rep.append(f'downbeat given: phase {A["phase"]}, first bar line at {A["bars"][0]:.3f} s')
    rep.append('section boundaries (novelty, on bar lines): ' + ', '.join(f'{s:.2f}' for s in A['sections']))
    if A['bpm'] < 110 or A['bpm'] > 125:
        rep.append(f'NOTE: {A["bpm"]:.1f} bpm is outside the brief (110–125); the cuts will drift from the beat more')
    if o.edit:
        segs = parse_edit(o.edit, cues)
        plan = {'segments': segs, 'how': 'by hand (--edit)', 'notes': [], 'score': None, 'parts': {}, 'runner_up': [],
                'reentry_db': None, 'final': None, 'tbar': float(np.median(np.diff(A['bars'])))}
    else:
        plan = plan_edit(A, cues, o.anchor, o.final)
    rep.append('')
    rep.append(f'edit: {plan["how"]} (score {plan["score"]}); {plan["parts"]}')
    for f0, f1, tr in plan['segments']:
        rep.append(f'  film {f0:6.3f}–{f1:6.3f} s ← track {tr:7.3f}–{tr + f1 - f0:7.3f} s')
    if plan.get('final') is not None:
        rep.append(f'  final chord: track {plan["final"]:.3f} s on film {cues["seat"]}; part B starts on its bar line at '
                   f'film {plan["segments"][-1][0]:.3f}; re-entry 19.0–20.5 at {plan["reentry_db"]} dB re the track\'s loud level')
    if not o.edit and not (MUST['reentry'][0] - 1e-3 <= plan['segments'][-1][0] <= MUST['reentry'][1]):
        rep.append(f'  NOTE: part B enters at film {plan["segments"][-1][0]:.3f}, outside the spec\'s 19.0–20.5 (the track\'s bars '
                   f'are {plan["tbar"]:.3f} s); room tone alone until then. --edit can enter at 19.0 mid-bar instead.')
    for s, how in plan.get('runner_up', []):
        rep.append(f'  runner-up: {how} (score {s})')
    rep += [f'  {n}' for n in plan['notes']]
    music, joins, reopen = render_edit(x, plan['segments'], cues, dur, o.xfade)
    rep.append(f'  splices with equal-power crossfades ({o.xfade * 1000:.0f} ms, ending on the bar line): '
               + (', '.join(f'{j:.3f}' for j in joins) or 'none (the A→B join is inside the gate)'))
    L.write_wav(os.path.join(os.path.dirname(os.path.abspath(o.out)), 'music-edit.wav'), music)

    # foley under it
    lm = L.loudness(music)['integrated']
    total = music.copy()
    fg = None
    if o.foley != 'none' and os.path.exists(o.foley):
        fx, fsr = L.read_wav(o.foley)
        fx = fx[:, :total.shape[1]] if fx.shape[1] >= total.shape[1] else np.pad(fx, ((0, 0), (0, total.shape[1] - fx.shape[1])))
        ev = os.path.join(os.path.dirname(o.foley), 'foley-stems', 'events.wav')
        if os.path.exists(ev):
            le = L.loudness(L.read_wav(ev)[0])['integrated']
            basis = 'its events stem (room tone excluded)'
        else:
            le = L.loudness(fx)['integrated']
            basis = 'the whole stem (no events stem found)'
        fg = (lm - under) - le
        total = total + fx * L.undb(fg)
        rep.append('')
        rep.append(f'foley: {os.path.relpath(o.foley, SITE)} at {fg:+.2f} dB, so {basis} sits {under:.1f} dB under the '
                   f'music ({le:.2f} → {le + fg:.2f} LUFS against {lm:.2f})')
    else:
        rep.append('')
        rep.append('foley: none')
    out, mi = master(total, o.lufs, o.ceiling)
    L.write_wav(o.out, out)

    # QA
    y, _ = L.read_wav(o.out)
    rep.append('')
    lines, num = Q.master_report(y, f'master {os.path.relpath(os.path.abspath(o.out), SITE)}')
    rep += lines
    rep.append(f'  normalised {mi["gain_db"]:+.2f} dB in {mi["iterations"]} pass(es); limiter at most {mi["limiter_max_gr_db"]:.2f} dB '
               f'of gain reduction (detection margin {mi["margin_db"]:.2f} dB)')
    ok_l = abs(num['lufs'] - o.lufs) <= 0.1
    ok_t = num['tp'] <= o.ceiling and num['tp_fft'] <= o.ceiling
    z0, z1 = cues['zero']
    runs = L.zero_runs(y, int(0.001 * SR))
    zr = [r for r in runs if r[0] < int(round(cues['end'] * SR))]
    mz = L.zero_runs(music, 1)
    mrun = [r for r in mz if r[0] <= int(round(z0 * SR)) <= r[1]]
    pre = music[:, int(round((z0 - 0.010) * SR)):int(round(z0 * SR))]
    ok_g = bool(mrun) and mrun[0][0] >= int(round((z0 - 0.010) * SR))
    rep.append(f'  [{"PASS" if ok_l else "FAIL"}] integrated {num["lufs"]:.2f} LUFS (target {o.lufs})')
    rep.append(f'  [{"PASS" if ok_t else "FAIL"}] true peak {num["tp"]:.2f} / {num["tp_fft"]:.2f} dBTP (ceiling {o.ceiling})')
    rep.append(f'  [{"PASS" if ok_g else "FAIL"}] music gated to digital zero from {mrun[0][0] / SR if mrun else float("nan"):.4f} s '
               f'(the 10 ms before {z0}: peak {L.peak_db(pre):.1f} dBFS, closing ramp 8 ms) until {reopen:.4f} s; master zero runs: '
               + ', '.join(f'{a / SR:.4f}–{b / SR:.4f}' for a, b in zr))
    if fg is not None:
        lmix_m = L.loudness(music * L.undb(mi['gain_db']))['integrated']
        rep.append(f'  foley under the music: {under:.1f} dB by the events\' loudness; room tone now at about '
                   f'{-58 + fg + mi["gain_db"]:.1f} dBFS RMS (music at {lmix_m:.1f} LUFS before the limiter)')
    rows, rend = retime(A, plan['segments'], tl, cues)
    os.makedirs(os.path.dirname(os.path.abspath(o.retime)), exist_ok=True)
    with open(o.retime, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ['t'])
        w.writeheader()
        w.writerows(rows)
    mv = [r for r in rows if r['note'] == 'move']
    far = [r for r in rows if r['note'].startswith('no beat')]
    none = [r for r in rows if r['note'].startswith('no music')]
    rep.append('')
    rep.append(f'retime → {os.path.relpath(os.path.abspath(o.retime), SITE)}: {len(rows)} hard events; {len(mv)} would move '
               f'(largest {max([abs(r["delta_s"]) for r in mv] or [0]):.3f} s), {len(far)} have no beat within 0.12 s, '
               f'{len(none)} have no music under them')
    for name, sid, a, b, dfr, what in rend:
        rep.append(f'  {name} ({sid}) {a:.3f}–{b:.3f} s, {dfr:+d} frames → {what}')
    rep.append('')
    rep.append('Listen before anything is published: the edit points, the gate at 18.5 and the foley balance were chosen by '
               'measurement only.')
    text = '\n'.join(rep) + '\n'
    with open(o.report, 'w') as f:
        f.write(text)
    print(text, end='')
    return 0 if (ok_l and ok_t and ok_g) else 1


if __name__ == '__main__':
    sys.exit(main())
