"""Shared numpy DSP for the film's sound (spec v2 §3): foley.py, mix.py and soundqa.py load it by path.

No scipy: every filter here is a causal IIR applied through its exact frequency response on a zero-padded FFT
(the padding is long enough that the impulse response has died before it could wrap), so it behaves like the
recursive filter without a per-sample Python loop.

    WAV       read_wav() (PCM 16/24/32, float 32/64, WAVE_FORMAT_EXTENSIBLE), write_wav() (24- or 16-bit, TPDF
              dither, exact digital zero kept where the signal is exactly zero, written atomically)
    filters   biquad() (RBJ), butter() (Butterworth as biquad sections), sosfilt(), fftconv()
    meters    loudness() (ITU-R BS.1770-4 K-weighted, gated), true_peak() (4× oversampled, windowed sinc),
              true_peak_fft() (ideal band-limited 4×), zero_runs()

As a module (the scripts run with python3 -I, which leaves their folder off sys.path):
    spec = importlib.util.spec_from_file_location('soundlib', path); L = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(L)
"""
import os
import struct
import wave

import numpy as np

SR = 48000


# ---------------------------------------------------------------------------------------------------- levels

def db(x):
    return 20.0 * np.log10(np.maximum(np.abs(x), 1e-12))


def undb(d):
    return 10.0 ** (np.asarray(d, dtype=np.float64) / 20.0)


def peak_db(x):
    return float(db(np.max(np.abs(x)))) if np.size(x) else -240.0


def rms_db(x):
    return float(10 * np.log10(max(float(np.mean(np.square(x, dtype=np.float64))), 1e-24)))


def fast_len(n):
    """The smallest 2^a·3^b·5^c ≥ n (FFT-friendly)."""
    best = 1 << int(np.ceil(np.log2(max(n, 1))))
    p5 = 1
    while p5 < best:
        p35 = p5
        while p35 < best:
            m = p35
            while m < n:
                m *= 2
            best = min(best, m)
            p35 *= 3
        p5 *= 5
    return best


# ---------------------------------------------------------------------------------------------------- WAV

def read_wav(path):
    """→ (x float64 [channels, n] in −1…1, sample rate). PCM 8/16/24/32, IEEE float 32/64, extensible."""
    with open(path, 'rb') as f:
        data = f.read()
    if data[:4] not in (b'RIFF', b'RF64') or data[8:12] != b'WAVE':
        raise ValueError(f'{path}: not a RIFF/WAVE file')
    pos, fmt, raw = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack('<I', data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b'fmt ':
            tag, ch, sr, _, _, bits = struct.unpack('<HHIIHH', body[:16])
            if tag == 0xFFFE and len(body) >= 26:
                tag = struct.unpack('<H', body[24:26])[0]
            fmt = (tag, ch, sr, bits)
        elif cid == b'data':
            raw = body
            if size == 0xFFFFFFFF or pos + 8 + size > len(data):   # streaming writers leave the size open
                raw = data[pos + 8:]
            break
        pos += 8 + size + (size & 1)
    if fmt is None or raw is None:
        raise ValueError(f'{path}: no fmt or data chunk')
    tag, ch, sr, bits = fmt
    w = bits // 8
    raw = raw[:len(raw) // (w * ch) * (w * ch)]
    if tag == 3:
        x = np.frombuffer(raw, dtype='<f4' if bits == 32 else '<f8').astype(np.float64)
    elif tag == 1:
        if bits == 8:
            x = (np.frombuffer(raw, dtype=np.uint8).astype(np.float64) - 128) / 128
        elif bits == 16:
            x = np.frombuffer(raw, dtype='<i2').astype(np.float64) / 32768
        elif bits == 24:
            b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
            v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
            v = np.where(v >= 1 << 23, v - (1 << 24), v)
            x = v.astype(np.float64) / (1 << 23)
        elif bits == 32:
            x = np.frombuffer(raw, dtype='<i4').astype(np.float64) / 2147483648.0
        else:
            raise ValueError(f'{path}: {bits}-bit PCM is not supported')
    else:
        raise ValueError(f'{path}: WAV format tag {tag} is not PCM or float')
    return x.reshape(-1, ch).T.copy(), sr


def write_wav(path, x, bits=24, seed=0, dither=True):
    """Write x [channels, n] (float, ±1 full scale) as PCM WAV, atomically.

    TPDF dither of ±1 LSB is added before rounding, except on samples that are exactly 0.0 in every channel:
    those stay digital zero (the film's one designed silence and its tail must survive quantisation)."""
    x = np.atleast_2d(np.asarray(x, dtype=np.float64))
    ch, n = x.shape
    full = float(1 << (bits - 1))
    y = x * full
    if dither:
        rng = np.random.default_rng(seed)
        y = y + rng.random((ch, n)) - rng.random((ch, n))
    q = np.clip(np.round(y), -full, full - 1).astype(np.int64)
    q[:, np.all(x == 0.0, axis=0)] = 0
    inter = q.T.reshape(-1)
    if bits == 24:
        b = inter.astype('<i4').view(np.uint8).reshape(-1, 4)[:, :3].tobytes()
    elif bits == 16:
        b = inter.astype('<i2').tobytes()
    else:
        raise ValueError('bits must be 16 or 24')
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, f'.{os.path.basename(path)}.{os.getpid()}.tmp')
    with wave.open(tmp, 'wb') as w:
        w.setnchannels(ch)
        w.setsampwidth(bits // 8)
        w.setframerate(SR)
        w.writeframes(b)
    os.replace(tmp, path)
    return q


# ---------------------------------------------------------------------------------------------------- filters

def biquad(kind, f0, q=0.7071067811865476, sr=SR, gain_db=0.0):
    """RBJ cookbook biquad → ((b0, b1, b2), (1, a1, a2)). kind: lp, hp, bp (0 dB peak), peak, lowshelf, highshelf."""
    w0 = 2 * np.pi * f0 / sr
    cw, sw = np.cos(w0), np.sin(w0)
    al = sw / (2 * q)
    A = 10 ** (gain_db / 40)
    if kind == 'lp':
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
        a = [1 + al, -2 * cw, 1 - al]
    elif kind == 'hp':
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
        a = [1 + al, -2 * cw, 1 - al]
    elif kind == 'bp':
        b = [al, 0.0, -al]
        a = [1 + al, -2 * cw, 1 - al]
    elif kind == 'peak':
        b = [1 + al * A, -2 * cw, 1 - al * A]
        a = [1 + al / A, -2 * cw, 1 - al / A]
    elif kind in ('lowshelf', 'highshelf'):
        s = 1 if kind == 'lowshelf' else -1
        sq = 2 * np.sqrt(A) * al
        b = [A * ((A + 1) - s * (A - 1) * cw + sq), s * 2 * A * ((A - 1) - s * (A + 1) * cw),
             A * ((A + 1) - s * (A - 1) * cw - sq)]
        a = [(A + 1) + s * (A - 1) * cw + sq, -s * 2 * ((A - 1) + s * (A + 1) * cw), (A + 1) + s * (A - 1) * cw - sq]
    else:
        raise ValueError(kind)
    return (tuple(v / a[0] for v in b), (1.0, a[1] / a[0], a[2] / a[0]))


def butter(kind, f0, order=2, sr=SR):
    """Butterworth low- or high-pass of even order as biquad sections (all at the same warped f0)."""
    if order % 2:
        raise ValueError('even orders only')
    return [biquad(kind, f0, 1 / (2 * np.sin((2 * k + 1) * np.pi / (2 * order))), sr) for k in range(order // 2)]


def sos_response(sos, freqs, sr=SR):
    z1 = np.exp(-1j * 2 * np.pi * np.asarray(freqs) / sr)
    z2 = z1 * z1
    h = np.ones_like(z1)
    for b, a in sos:
        h = h * (b[0] + b[1] * z1 + b[2] * z2) / (a[0] + a[1] * z1 + a[2] * z2)
    return h


def sosfilt(x, sos, pad=SR, sr=SR):
    """Causal IIR filtering along the last axis through the filter's exact response on a padded FFT."""
    x = np.asarray(x, dtype=np.float64)
    n = x.shape[-1]
    nfft = fast_len(n + pad)
    X = np.fft.rfft(x, nfft, axis=-1)
    X *= sos_response(sos, np.fft.rfftfreq(nfft, 1 / sr), sr)
    return np.fft.irfft(X, nfft, axis=-1)[..., :n]


def fftconv(x, h):
    """Full linear convolution along the last axis (x [..., n], h [..., m] or [m]) → [..., n + m − 1]."""
    x = np.asarray(x, dtype=np.float64)
    h = np.asarray(h, dtype=np.float64)
    m = x.shape[-1] + h.shape[-1] - 1
    nfft = fast_len(m)
    return np.fft.irfft(np.fft.rfft(x, nfft, axis=-1) * np.fft.rfft(h, nfft, axis=-1), nfft, axis=-1)[..., :m]


def resample(x, sr_from, sr_to=SR):
    """Band-limited resampling by FFT (zero-padded both ends so nothing wraps)."""
    if sr_from == sr_to:
        return np.asarray(x, dtype=np.float64)
    x = np.atleast_2d(x)
    pad = int(sr_from * 0.5)
    xp = np.pad(x, ((0, 0), (pad, pad)))
    n = xp.shape[-1]
    m = int(round(n * sr_to / sr_from))
    X = np.fft.rfft(xp, axis=-1)
    k = m // 2 + 1
    Y = np.zeros((x.shape[0], k), dtype=complex)
    c = min(k, X.shape[-1])
    Y[:, :c] = X[:, :c]
    y = np.fft.irfft(Y, m, axis=-1) * (m / n)
    p2 = int(round(pad * sr_to / sr_from))
    return y[:, p2:p2 + int(round(x.shape[-1] * sr_to / sr_from))]


# ---------------------------------------------------------------------------------------------------- envelopes

def ramp(n, start_at_one=True):
    """Raised-cosine 0→1 of n samples. With start_at_one the first sample is already above 0 (k + 1), so a
    fade-in that starts on a digital-zero boundary does not add one more zero sample to it."""
    k = np.arange(n) + (1 if start_at_one else 0)
    return np.sin(0.5 * np.pi * np.clip(k / n, 0, 1)) ** 2


# ---------------------------------------------------------------------------------------------------- loudness

# ITU-R BS.1770-4, K-weighting at 48 kHz: the head shelf, then the RLB high-pass (coefficients from the standard)
K_SOS = [((1.53512485958697, -2.69169618940638, 1.19839281085285), (1.0, -1.69065929318241, 0.73248077421585)),
         ((1.0, -2.0, 1.0), (1.0, -1.99004745483398, 0.99007225036621))]


def loudness(x, sr=SR):
    """BS.1770-4 loudness of x [channels, n] at 48 kHz (L and R weighted 1).
    → dict(integrated LUFS, momentary_max, short_term_max, blocks (400 ms, 100 ms step))."""
    if sr != SR:
        raise ValueError('loudness() expects 48 kHz')
    x = np.atleast_2d(x)
    y = sosfilt(x, K_SOS)
    sq = np.concatenate([np.zeros((y.shape[0], 1)), np.cumsum(y * y, axis=1)], axis=1)

    def blocks(win, step):
        starts = np.arange(0, y.shape[1] - win + 1, step)
        if len(starts) == 0:
            return np.zeros(0)
        z = (sq[:, starts + win] - sq[:, starts]) / win
        return z.sum(axis=0)

    m = blocks(int(0.4 * sr), int(0.1 * sr))
    s = blocks(int(3.0 * sr), int(0.1 * sr))
    lk = lambda e: -0.691 + 10 * np.log10(np.maximum(e, 1e-30))
    lm = lk(m)
    g = m[lm > -70]
    if len(g) == 0:
        integ = -np.inf
    else:
        rel = lk(np.mean(g)) - 10
        g2 = m[(lm > -70) & (lm > rel)]
        integ = float(lk(np.mean(g2))) if len(g2) else -np.inf
    return {'integrated': integ, 'momentary_max': float(lm.max()) if len(lm) else -np.inf,
            'short_term_max': float(lk(s).max()) if len(s) else -np.inf, 'blocks': lm}


# ---------------------------------------------------------------------------------------------------- true peak

def _os_kernel(factor=4, taps_per_phase=32, beta=9.0):
    n = factor * taps_per_phase + 1
    t = (np.arange(n) - (n - 1) / 2) / factor
    return np.sinc(t) * np.kaiser(n, beta)


def oversample(x, factor=4):
    """Band-limited ×factor interpolation (zero-stuffing + Kaiser-windowed sinc, 32 taps per phase).
    → [channels, n·factor], aligned so that y[:, k·factor] == x[:, k]."""
    x = np.atleast_2d(np.asarray(x, dtype=np.float64))
    h = _os_kernel(factor)
    up = np.zeros((x.shape[0], x.shape[1] * factor))
    up[:, ::factor] = x
    y = fftconv(up, h)
    d = (len(h) - 1) // 2
    return y[:, d:d + up.shape[1]]


def true_peak(x, factor=4):
    """dBTP: the peak of the 4× oversampled signal (windowed-sinc interpolator, as BS.1770-4 Annex 2 asks)."""
    return peak_db(oversample(x, factor))


def oversample_fft(x, factor=4):
    """Ideal band-limited ×factor interpolation by FFT of the zero-padded signal → [channels, n·factor], aligned so
    that y[:, k·factor] == x[:, k]. Full bandwidth up to Nyquist, so it reads inter-sample peaks of bright material
    (hats, noise) that a windowed-sinc FIR, rolling off near Nyquist, under-reads by a few tenths of a dB."""
    x = np.atleast_2d(np.asarray(x, dtype=np.float64))
    pad = 4096
    n0 = x.shape[1]
    n = fast_len(n0 + 2 * pad)
    if n % 2:
        n += 1
    xp = np.zeros((x.shape[0], n))
    xp[:, pad:pad + n0] = x
    X = np.fft.rfft(xp, axis=1)
    m = n * factor
    Y = np.zeros((x.shape[0], m // 2 + 1), dtype=complex)
    Y[:, :X.shape[1]] = X
    Y[:, n // 2] *= 0.5              # split the Nyquist bin between ±fs/2
    y = np.fft.irfft(Y, m, axis=1) * factor
    return y[:, pad * factor:(pad + n0) * factor]


def true_peak_fft(x, factor=4):
    """dBTP by ideal band-limited (FFT) 4× interpolation: a stricter second opinion."""
    return peak_db(oversample_fft(x, factor))


# ---------------------------------------------------------------------------------------------------- checks

def zero_runs(x, min_len):
    """Runs where every channel is exactly 0 for at least min_len samples → [(start, end_exclusive)]."""
    z = np.all(np.atleast_2d(x) == 0, axis=0).astype(np.int8)
    d = np.diff(np.concatenate([[0], z, [0]]))
    s, e = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
    return [(int(a), int(b)) for a, b in zip(s, e) if b - a >= min_len]


def band_energy_db(x, lo, hi, sr=SR):
    """Energy of x between lo and hi Hz relative to its total energy (dB), and absolute (dBFS, as RMS)."""
    x = np.atleast_2d(x)
    X = np.fft.rfft(x, axis=1)
    f = np.fft.rfftfreq(x.shape[1], 1 / sr)
    p = np.abs(X) ** 2
    tot = p.sum()
    sel = p[:, (f >= lo) & (f < hi)].sum()
    rel = 10 * np.log10(max(sel, 1e-30) / max(tot, 1e-30))
    # Parseval: mean square = Σ|X|² · 2 / n² (one-sided), per channel → average over channels
    ms = sel * 2 / (x.shape[1] ** 2) / x.shape[0]
    return float(rel), float(10 * np.log10(max(ms, 1e-30)))
