"""The promo film v2's foley stem (spec v2 §3, "What we deliver (1)"). It takes over sound.py's role: no music.

Nobody on the team can listen, so everything made here is short, physical, quiet and sparse. A room, and only
the sounds the real objects make:

    room tone   0.0–18.5 and 19.0–29.5. Pink noise, high-pass 40 Hz and low-pass 6 kHz at 12 dB/oct, two channels
                correlated 0.4, −58 dBFS RMS, ±1 dB slow random drift (a knot about every 4 s), 0.25 s fade-in at 0.
                Dry. It stops at 18.5 within 4 ms and comes back at 19.0 over 0.3 s.
    hinge       the lid opening (cues.lid, 1.8–2.9). Stick-slip friction grains (4–9 ms, 18–30 a second, ±30 %
                amplitude) band-limited to 300 Hz–2.5 kHz, through resonators at 190/420/1350 Hz (Q 6/8/10). The
                grain rate and level follow the lid's angular velocity: the derivative of the S02 curve
                lid = 108°·easeInOutCubic((t − 1.8)/1.1). Peak −30 dBFS.
    settle      the lid reaching its stop (cues.settle, 2.9). Modes 115/240/610 Hz decaying in 70/45/20 ms (T60),
                driven by a short felt pulse, plus felt noise low-passed at 2 kHz. Peak −28 dBFS.
    click       the trackpad on «Weiter» (cues.click 16.5, +6 ms). A 1.5 ms noise transient high-passed at 1.5 kHz
                and modes at 2.1/3.4/4.7/7.2 kHz (T60 12/8/5/3 ms). Peak −20 dBFS. The release 70 ms later, 8 dB
                quieter, its modes detuned a little (a real release never repeats the press exactly).
    zero        18.5–19.0 (cues.zero): digital zero, room tone included. The only silence in the film.
    seat        the halves of the mark meeting (cues.seat, 27.0). An unpitched felt thump: resonators at
                72/118/164 Hz (inharmonic, so no note), T60 220/140/90 ms, an 8 ms low-passed noise attack.
                Peak −26 dBFS.
    space       hinge, settle, click and seat send at most 10 % to a 0.35 s small-room impulse response:
                an image-source shoebox 4.2 × 5.6 × 2.9 m (randomised image positions, so no flutter), absorption
                per octave band 125 Hz–8 kHz, air absorption, two omni capsules 17 cm apart.
    humanising  every event's time jitters ±6 ms; every part inside an event (each mode, grain group, the release)
                varies ±1.5 dB, and each event as a whole ±0.75 dB, so it stays inside the QA's ±1 dB of spec.
    end         audio ends with the picture at 29.5 (cues.end); 29.5–30.0 is digital zero.
    level       deliberately quiet, NOT loudness-normalised (normalising would turn the room into hiss).
    low end     every layer is high-passed at 40 Hz (8th-order Butterworth), so nothing sits below 30 Hz.

"Decays" in the spec are read as T60 (the time to fall 60 dB), the usual meaning in modal synthesis: a felt thump
and a click have to die in tens of milliseconds, which the time-constant reading would not give.

Cue times come from tools/film/timeline.json "cues" (seconds, film time), with the contract's defaults for
anything missing: lid [1.8, 2.9], settle 2.9, click 16.5, zero [18.5, 19.0], seat 27.0, end 29.5.

    python3 -I tools/film/foley.py [--out video/.cache/foley.wav] [--seed 7] [--bits 24] [--no-qa]
      → video/.cache/foley.wav (48 kHz stereo, 24-bit, TPDF-dithered except on digital zero),
        video/.cache/foley-stems/{room,hinge,settle,click,seat,events}.wav (the same samples, one layer each),
        video/.cache/foley.json (what was placed where, the targets, the room), and then the sound QA
        (tools/film/soundqa.py) → video/.cache/foley-qa.txt. Exit 1 if a QA check fails.
"""
import argparse
import importlib.util
import json
import os
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
SR = L.SR

DEFAULT_CUES = {'lid': [1.8, 2.9], 'settle': 2.9, 'click': 16.5, 'zero': [18.5, 19.0], 'seat': 27.0, 'end': 29.5,
                'roomFadeIn': 0.25, 'roomReturnFade': 0.3}
# spec §3 levels (dBFS): room tone as RMS per channel, events as sample peak of the event (dry + its room send)
SPEC = {'room': -58.0, 'hinge': -30.0, 'settle': -28.0, 'click': -20.0, 'release': -28.0, 'seat': -26.0}
SEND = {'hinge': 0.10, 'settle': 0.08, 'click': 0.06, 'seat': 0.08}     # ≤ 10 % to the room
JITTER_T = 0.006       # ±6 ms
JITTER_PART_DB = 1.5   # ±1.5 dB on each part of an event
JITTER_EVENT_DB = 0.75  # ±0.75 dB on the event as a whole (QA allows ±1 dB of spec)
STOP = 0.004           # the room tone's de-click at 18.5 and 29.5: 4 ms, ending exactly on the boundary
EDGE = 0.02           # …and its fades meet the zero windows at −34 dB re the room (≈ −92 dBFS), never at 0, so the
                      # digital zero starts and ends on the exact sample even after dithered 24-bit rounding
HP_STEM = L.butter('hp', 40.0, 8)   # every layer: nothing below 30 Hz (−20 dB at 30, −33 at 25); the room is HP 40


def read_cues(path=os.path.join(HERE, 'timeline.json')):
    tl = {}
    try:
        with open(path) as f:
            tl = json.load(f)
    except (OSError, ValueError):
        pass
    c = dict(DEFAULT_CUES)
    c.update({k: v for k, v in (tl.get('cues') or {}).items() if k in DEFAULT_CUES})
    return c, float(tl.get('duration', 30.0)), tl.get('version')


def s2n(t):
    return int(round(t * SR))


# ---------------------------------------------------------------------------------------------------- building blocks

def resonator_ir(f, q, n):
    """Two-pole resonator (constant 0 dB peak gain) as an impulse response: 2α·e^(−αt)·sin(2πft), α = πf/Q."""
    t = np.arange(n) / SR
    a = np.pi * f / q
    return 2 * a / SR * np.exp(-a * t) * np.sin(2 * np.pi * f * t)


def modes_ir(freqs, t60s, amps, n, phases=None):
    """Σ a·e^(−6.91 t / T60)·sin(2πft + φ): a struck structure's modal response."""
    t = np.arange(n) / SR
    y = np.zeros(n)
    for i, (f, t60, a) in enumerate(zip(freqs, t60s, amps)):
        ph = 0.0 if phases is None else phases[i]
        y += a * np.exp(-6.907755 * t / t60) * np.sin(2 * np.pi * f * t + ph)
    return y


def hann_pulse(ms):
    n = max(3, int(round(ms * 1e-3 * SR)))
    return np.hanning(n + 2)[1:-1]


def place(bus, x, at):
    """Add x [2, m] into bus [2, N] starting at sample `at`."""
    j0, j1 = max(0, at), min(bus.shape[1], at + x.shape[1])
    if j1 > j0:
        bus[:, j0:j1] += x[:, j0 - at:j1 - at]


def jit_db(rng, span):
    return float(rng.uniform(-span, span))


# ---------------------------------------------------------------------------------------------------- the room

BANDS = np.array([125, 250, 500, 1000, 2000, 4000, 8000], dtype=float)
# absorption coefficients per octave band: a furnished small room with plasterboard walls and ceiling (membrane
# absorbers, so the low end is damped too), shelves, curtains, a sofa and a rug. Sabine RT ≈ 0.34 s at 125 Hz,
# 0.29 s at 1 kHz, 0.25 s at 4 kHz, so the response has decayed by the 0.35 s it is cut at.
ALPHA = {
    'x0': [0.34, 0.33, 0.35, 0.38, 0.40, 0.42, 0.44],   # side wall with shelves
    'x1': [0.30, 0.32, 0.36, 0.40, 0.42, 0.44, 0.45],   # side wall, curtains over a window
    'y0': [0.30, 0.22, 0.20, 0.22, 0.24, 0.26, 0.28],   # back wall, plasterboard and a door
    'y1': [0.32, 0.36, 0.40, 0.42, 0.43, 0.44, 0.45],   # front wall with a sofa
    'z0': [0.28, 0.30, 0.38, 0.48, 0.55, 0.60, 0.62],   # floor: wood with a rug
    'z1': [0.32, 0.26, 0.24, 0.24, 0.26, 0.28, 0.30],   # ceiling, plasterboard
}
AIR_DB_PER_M = np.array([0.0004, 0.0011, 0.0022, 0.0042, 0.0090, 0.025, 0.080])   # 20 °C, ~50 % RH


def room_ir(rng, dims=(4.2, 5.6, 2.9), src=(1.73, 3.62, 0.86), mics=((2.13, 2.48, 1.14), (2.30, 2.48, 1.14)),
            length=0.35, c=343.0, jitter=0.08):
    """Image-source shoebox IR, reflections only (the direct sound is the dry signal), stereo, unit energy.
    Randomised image positions (±jitter m) break the shoebox's periodic flutter. → (ir [2, n], info)."""
    n = int(round(length * SR))
    R = c * length
    beta = {k: np.sqrt(1 - np.asarray(v)) for k, v in ALPHA.items()}
    axes = []
    for a, (Lr, s) in enumerate(zip(dims, src)):
        N = int(np.ceil(R / (2 * Lr))) + 1
        nn = np.arange(-N, N + 1)
        coord, c0, c1 = [], [], []
        for u in (0, 1):
            coord.append((1 - 2 * u) * s + 2 * nn * Lr)
            c0.append(np.abs(nn - u))
            c1.append(np.abs(nn))
        axes.append((np.concatenate(coord), np.concatenate(c0), np.concatenate(c1)))
    (X, X0, X1), (Y, Y0, Y1), (Z, Z0, Z1) = axes
    gx, gy, gz = np.meshgrid(np.arange(len(X)), np.arange(len(Y)), np.arange(len(Z)), indexing='ij')
    gx, gy, gz = gx.ravel(), gy.ravel(), gz.ravel()
    order = X0[gx] + X1[gx] + Y0[gy] + Y1[gy] + Z0[gz] + Z1[gz]
    keep = order > 0                                    # no direct path
    ix, iy, iz = gx[keep], gy[keep], gz[keep]
    P = np.stack([X[ix], Y[iy], Z[iz]], axis=1)
    P = P + rng.uniform(-jitter, jitter, P.shape)
    # per-band reflection loss in the log domain
    lb = np.zeros((len(ix), len(BANDS)))
    for key, cnt in (('x0', X0[ix]), ('x1', X1[ix]), ('y0', Y0[iy]), ('y1', Y1[iy]), ('z0', Z0[iz]), ('z1', Z1[iz])):
        lb += cnt[:, None] * np.log(beta[key])[None, :]
    nfft = L.fast_len(2 * n)
    f = np.fft.rfftfreq(nfft, 1 / SR)
    # complementary octave masks (cos² crossovers one octave wide around the geometric band edges), summing to 1
    lf = np.log2(np.maximum(f, 1.0))
    edges = np.log2(np.sqrt(BANDS[:-1] * BANDS[1:]))
    masks = []
    lo = np.ones_like(f)
    for e in edges:
        w = np.clip((lf - (e - 0.5)), 0, 1)
        up = np.sin(0.5 * np.pi * w) ** 2
        masks.append(lo * (1 - up))
        lo = lo * up
    masks.append(lo)
    masks = np.array(masks)
    ir = np.zeros((2, n))
    for m, mic in enumerate(mics):
        d = np.linalg.norm(P - np.asarray(mic)[None, :], axis=1)
        sel = d < R
        dd = d[sel]
        amp = np.exp(lb[sel]) / np.maximum(dd, 0.3)[:, None] * 10 ** (-AIR_DB_PER_M[None, :] * dd[:, None] / 20)
        pos = dd / c * SR
        i0 = np.floor(pos).astype(int)
        fr = pos - i0
        spec = np.zeros(len(f), dtype=complex)
        for b in range(len(BANDS)):
            tr = np.bincount(i0, amp[:, b] * (1 - fr), minlength=nfft + 1)[:nfft] + \
                np.bincount(np.minimum(i0 + 1, nfft - 1), amp[:, b] * fr, minlength=nfft + 1)[:nfft]
            spec += np.fft.rfft(tr, nfft) * masks[b]
        y = np.fft.irfft(spec, nfft)[:n]
        ir[m] = y
    # the tail ends inside 0.35 s: a 20 ms cosine fade, then nothing
    fade = int(0.02 * SR)
    ir[:, -fade:] *= np.cos(0.5 * np.pi * np.arange(1, fade + 1) / fade) ** 2
    ir = L.sosfilt(ir, L.butter('hp', 60.0, 2), pad=SR // 4)   # a room send carries no rumble
    ir /= np.sqrt(np.mean(np.sum(ir * ir, axis=1)))
    # measured decay per band (Schroeder backward integration, T20 extrapolated to 60 dB)
    rt = []
    for b in range(len(BANDS)):
        yb = np.fft.irfft(np.fft.rfft(ir[0], nfft) * masks[b], nfft)[:n]
        e = np.cumsum((yb ** 2)[::-1])[::-1]
        edb = 10 * np.log10(np.maximum(e / e[0], 1e-30))
        i5, i25 = np.argmax(edb <= -5), np.argmax(edb <= -25)
        rt.append(round(3 * (i25 - i5) / SR, 3) if i25 > i5 else None)
    first = int(np.argmax(np.abs(ir[0]) > 1e-3 * np.abs(ir[0]).max()))
    return ir, {'dims_m': list(dims), 'source_m': list(src), 'mics_m': [list(m) for m in mics], 'length_s': length,
                'images': int(len(ix)), 'first_reflection_ms': round(first / SR * 1000, 2),
                'rt60_t20_s': dict(zip([int(b) for b in BANDS], rt))}


# ---------------------------------------------------------------------------------------------------- the sounds

def room_tone(rng, n, rms_db, corr=0.4):
    """Two channels of pink noise, HP 40 / LP 6k at 12 dB/oct, correlation `corr`, each at rms_db."""
    pad = SR
    m = L.fast_len(n + pad)
    f = np.fft.rfftfreq(m, 1 / SR)
    shape = np.zeros_like(f)
    shape[1:] = 1 / np.sqrt(f[1:])
    shape *= (f / 40) ** 2 / np.sqrt(1 + (f / 40) ** 4)        # |2nd-order Butterworth HP|
    shape *= 1 / np.sqrt(1 + (f / 6000) ** 4)                   # |2nd-order Butterworth LP|
    def pink():
        y = np.fft.irfft(np.fft.rfft(rng.standard_normal(m)) * shape, m)[pad // 2:pad // 2 + n]
        return y / np.sqrt(np.mean(y * y))
    common, a, b = pink(), pink(), pink()
    l = np.sqrt(corr) * common + np.sqrt(1 - corr) * a
    r = np.sqrt(corr) * common + np.sqrt(1 - corr) * b
    x = np.vstack([l / np.sqrt(np.mean(l * l)), r / np.sqrt(np.mean(r * r))])
    return x * L.undb(rms_db)


def drift(rng, n, span_db=1.0, every=4.0):
    """A slow random gain: knots about every 4 s (±25 %), uniform in ±span dB, cosine-interpolated."""
    T = n / SR
    knots = [0.0]
    while knots[-1] < T:
        knots.append(knots[-1] + every * rng.uniform(0.75, 1.25))
    vals = rng.uniform(-span_db, span_db, len(knots))
    t = np.arange(n) / SR
    k = np.searchsorted(knots, t, side='right') - 1
    k = np.clip(k, 0, len(knots) - 2)
    t0, t1 = np.asarray(knots)[k], np.asarray(knots)[k + 1]
    u = (t - t0) / (t1 - t0)
    w = 0.5 - 0.5 * np.cos(np.pi * u)
    return L.undb(vals[k] * (1 - w) + vals[k + 1] * w)


def lid_velocity(t, a, b):
    """|dθ/dt| of θ = 108°·easeInOutCubic((t − a)/(b − a)), normalised to 1 at its peak (t = (a + b)/2)."""
    x = np.clip((t - a) / (b - a), 0, 1)
    v = np.where(x < 0.5, 4 * x * x, (2 - 2 * x) ** 2)
    return np.where((t < a) | (t > b), 0.0, v)


def hinge(rng, a, b, parts):
    """Stick-slip friction through the hinge's resonators, following the lid's angular velocity. Mono."""
    dur = b - a
    n = int((dur + 0.25) * SR)
    src = np.zeros(n)
    tt = 0.0
    grains = 0
    while tt < dur:
        v = float(lid_velocity(np.array([a + tt]), a, b)[0])
        if v < 0.015:
            tt += 0.004
            continue
        rate = 18 + 12 * v                                       # 18–30 slips a second, faster when it moves faster
        g_ms = rng.uniform(4, 9)
        gn = int(g_ms * 1e-3 * SR)
        k = np.arange(gn) / SR
        env = (1 - np.exp(-k / 0.0004)) * np.exp(-k / (g_ms * 1e-3 / 3.2))   # the slip snaps, then dies
        env[-16:] *= np.linspace(1, 0, 16)
        amp = v * rng.uniform(0.7, 1.3)                          # ±30 % per grain
        i = int(tt * SR)
        src[i:i + gn] += amp * env * rng.standard_normal(gn)
        grains += 1
        tt += rng.uniform(0.75, 1.25) / rate                     # stick-slip is quasi-periodic, not Poisson
    # a continuous rub under the slips, 18 dB down, also following the velocity
    t = a + np.arange(n) / SR
    src += 0.125 * lid_velocity(t, a, b) * rng.standard_normal(n)
    src = L.sosfilt(src, L.butter('hp', 300, 2) + L.butter('lp', 2500, 2), pad=SR // 4)
    m = int(0.12 * SR)
    res = [(190, 6, 0.45), (420, 8, 1.0), (1350, 10, 0.7)]
    y = 0.5 * parts() * src
    for f, q, w in res:
        f = f * rng.uniform(0.99, 1.01)
        y += w * parts() * L.fftconv(src, resonator_ir(f, q, m))[:n]
    return y, {'grains': grains, 'resonators': res}


def settle(rng, parts):
    """The lid meeting its stop: a felt-damped modal thunk."""
    n = int(0.25 * SR)
    freqs = [f * rng.uniform(0.99, 1.01) for f in (115, 240, 610)]
    amps = [w * parts() for w in (1.0, 0.55, 0.3)]
    body = L.fftconv(hann_pulse(2.5), modes_ir(freqs, (0.070, 0.045, 0.020), amps, n))[:n]
    body /= np.max(np.abs(body))
    felt = rng.standard_normal(n) * np.concatenate([hann_pulse(4.0), np.zeros(n - len(hann_pulse(4.0)))])
    felt = L.sosfilt(felt, L.butter('lp', 2000, 2), pad=SR // 8)
    felt /= np.max(np.abs(felt))
    return body + 0.22 * parts() * felt


def click(rng, parts, detune=1.0):
    """The trackpad's click: a crisp noise transient and four short high modes."""
    n = int(0.04 * SR)
    tr = np.zeros(n)
    p = hann_pulse(1.5)
    tr[:len(p)] = p * rng.standard_normal(len(p))
    tr = L.sosfilt(tr, L.butter('hp', 1500, 4), pad=SR // 8)
    tr /= np.max(np.abs(tr))
    freqs = [f * detune * rng.uniform(0.99, 1.01) for f in (2100, 3400, 4700, 7200)]
    amps = [w * parts() for w in (1.0, 0.7, 0.5, 0.32)]
    body = modes_ir(freqs, (0.012, 0.008, 0.005, 0.003), amps, n, phases=rng.uniform(0, 0.4, 4))
    body /= np.max(np.abs(body))
    return body + 0.6 * parts() * tr


def seat(rng, parts):
    """The halves meeting: an unpitched felt thump (inharmonic low modes, so it is not a note)."""
    n = int(0.6 * SR)
    freqs = [f * rng.uniform(0.99, 1.01) for f in (72, 118, 164)]
    amps = [w * parts() for w in (1.0, 0.62, 0.38)]
    pulse = hann_pulse(8.0)
    body = L.fftconv(pulse, modes_ir(freqs, (0.220, 0.140, 0.090), amps, n))[:n]
    body /= np.max(np.abs(body))
    att = np.zeros(n)
    att[:len(pulse)] = pulse * rng.standard_normal(len(pulse))
    att = L.sosfilt(att, L.butter('lp', 1200, 2), pad=SR // 8)
    att /= np.max(np.abs(att))
    return body + 0.18 * parts() * att


# ---------------------------------------------------------------------------------------------------- the stem

def build(seed=7):
    cues, duration, version = read_cues()
    rng = np.random.default_rng(seed)
    N = s2n(duration)
    parts = lambda: L.undb(jit_db(rng, JITTER_PART_DB))
    ir, room_info = room_ir(np.random.default_rng(seed + 1000))

    z0, z1 = cues['zero']
    end = cues['end']
    log = []
    stems = {}

    def event(name, mono, t_nominal, target_db, send, jitter=True):
        """Place a mono event at t_nominal (± jitter), add its room send, set its peak (dry + wet) to the target."""
        dt = rng.uniform(-JITTER_T, JITTER_T) if jitter else 0.0
        ev_db = jit_db(rng, JITTER_EVENT_DB)
        dry = np.vstack([mono, mono])
        wet = send * L.fftconv(mono[None, :], ir)
        x = np.zeros((2, wet.shape[1] + int(0.3 * SR)))   # room for the stem high-pass's own tail
        x[:, :dry.shape[1]] += dry
        x[:, :wet.shape[1]] += wet
        x = L.sosfilt(x, HP_STEM, pad=SR // 2)
        x *= L.undb(target_db + ev_db) / np.max(np.abs(x))
        at = s2n(t_nominal + dt)
        bus = np.zeros((2, N))
        place(bus, x, at)
        log.append({'name': name, 't_nominal': round(t_nominal, 4), 't': round(at / SR, 5), 'jitter_ms': round(dt * 1000, 2),
                    'spec_peak_dbfs': target_db, 'level_offset_db': round(ev_db, 2), 'send': send,
                    'length_s': round(x.shape[1] / SR, 3)})
        return bus

    # hinge: the lid's own clock, its grains are the jitter; the whole sound may still slip ±6 ms
    a, b = cues['lid']
    hm, hinfo = hinge(rng, a, b, parts)
    stems['hinge'] = event('hinge', hm, a, SPEC['hinge'], SEND['hinge'])
    log[-1].update({'span': [a, b], **hinfo})
    stems['settle'] = event('settle', settle(rng, parts), cues['settle'], SPEC['settle'], SEND['settle'])
    t_click = cues['click'] + 0.006
    cl = event('click', click(rng, parts), t_click, SPEC['click'], SEND['click'])
    rel_db = SPEC['click'] - 8.0
    rl = event('release', click(rng, parts, detune=rng.uniform(1.03, 1.06)), t_click + 0.070, rel_db, SEND['click'])
    stems['click'] = cl + rl
    stems['seat'] = event('seat', seat(rng, parts), cues['seat'], SPEC['seat'], SEND['seat'])

    # room tone, with its gates
    room = room_tone(rng, N, SPEC['room'])
    room *= drift(rng, N)[None, :]
    g = np.zeros(N)
    fi = s2n(cues['roomFadeIn'])
    i_z0, i_z1, i_end = s2n(z0), s2n(z1), s2n(end)
    stop = s2n(STOP)
    g[:i_z0] = 1.0
    edge = lambda r: EDGE + (1 - EDGE) * r
    g[:fi] = edge(L.ramp(fi))
    g[i_z0 - stop:i_z0] = edge(L.ramp(stop)[::-1])
    rf = s2n(cues['roomReturnFade'])
    g[i_z1:i_end] = 1.0
    g[i_z1:i_z1 + rf] = edge(L.ramp(rf))
    g[i_end - stop:i_end] = edge(L.ramp(stop)[::-1])
    room = L.sosfilt(room, HP_STEM, pad=SR // 2) * g[None, :]
    stems['room'] = room

    # every layer is gated to exact zero in the zero window and after the end (an event's tail never crosses them)
    gate = np.ones(N)
    gate[i_z0:i_z1] = 0.0
    gate[i_end:] = 0.0
    for k in stems:
        stems[k] = stems[k] * gate[None, :]
    events = stems['hinge'] + stems['settle'] + stems['click'] + stems['seat']
    stems['events'] = events
    mix = events + stems['room']
    meta = {'sr': SR, 'duration': duration, 'seed': seed, 'timeline_version': version, 'cues': cues,
            'spec_dbfs': SPEC, 'sends': SEND, 'events': log,
            'room': {'rms_dbfs': SPEC['room'], 'correlation': 0.4, 'hp_hz': 40, 'lp_hz': 6000, 'slope_db_oct': 12,
                     'drift_db': 1.0, 'fade_in_s': cues['roomFadeIn'], 'return_fade_s': cues['roomReturnFade'],
                     'stop_ms': STOP * 1000},
            'ir': room_info, 'stem_highpass': '8th-order Butterworth at 40 Hz on every layer (the room is also HP 40 Hz at 12 dB/oct before it)',
            'humanise': {'timing_ms': JITTER_T * 1000, 'part_db': JITTER_PART_DB, 'event_db': JITTER_EVENT_DB}}
    return mix, stems, meta


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--out', default=os.path.join(CACHE, 'foley.wav'))
    ap.add_argument('--seed', type=int, default=7)
    ap.add_argument('--bits', type=int, default=24, choices=(16, 24))
    ap.add_argument('--no-qa', action='store_true')
    o = ap.parse_args()
    mix, stems, meta = build(o.seed)
    out = os.path.abspath(o.out)
    sdir = os.path.join(os.path.dirname(out), 'foley-stems')
    L.write_wav(out, mix, bits=o.bits, seed=o.seed)
    for k, x in stems.items():
        L.write_wav(os.path.join(sdir, k + '.wav'), x, bits=o.bits, seed=o.seed + 1 + len(k))
    meta.update({'file': os.path.relpath(out, SITE), 'bits': o.bits, 'stems': os.path.relpath(sdir, SITE)})
    jpath = os.path.splitext(out)[0] + '.json'
    with open(jpath + '.tmp', 'w') as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
    os.replace(jpath + '.tmp', jpath)
    print(f'foley: {os.path.relpath(out, SITE)} ({meta["duration"]:.1f} s, 48 kHz, {o.bits}-bit), stems in '
          f'{os.path.relpath(sdir, SITE)}/, {os.path.relpath(jpath, SITE)}')
    for e in meta['events']:
        print(f'  {e["name"]:8s} {e["t"]:8.4f} s  ({e["jitter_ms"]:+5.2f} ms)  spec {e["spec_peak_dbfs"]:6.1f} dBFS '
              f'{e["level_offset_db"]:+.2f} dB  send {e["send"]:.2f}')
    if o.no_qa:
        return 0
    Q = _load('soundqa')
    ok, text = Q.qa_foley(out, jpath, sdir)
    qpath = os.path.join(os.path.dirname(out), 'foley-qa.txt')
    with open(qpath + '.tmp', 'w') as f:
        f.write(text)
    os.replace(qpath + '.tmp', qpath)
    print(text)
    print(f'foley: QA → {os.path.relpath(qpath, SITE)}: {"all checks pass" if ok else "SOME CHECKS FAIL"}')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
