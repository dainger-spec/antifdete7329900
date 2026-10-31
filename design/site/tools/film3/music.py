"""Lay a licensed recorded track under the film v3. numpy and ffmpeg only (the analysis is v2's tools/film/mix.py).

    python3 -I tools/film3/music.py TRACK --analyse                      # tempo, bar lines, energy per bar, endings
    python3 -I tools/film3/music.py TRACK --downbeat D [--final F] [--name NAME] [options]
      → video/.cache/music3/NAME.wav    30.0 s, 48 kHz, 24-bit, −14 LUFS integrated, ≤ −1 dBTP
    then mux it with the picture (encode.sh ru --audio …, or ffmpeg -c:v copy onto a picture-only encode).

The film is cut to 120 bpm (timeline.json: a beat is 0.5 s, a bar 2 s, every cut on a beat). So:
  1. the track is time-stretched to 120 bpm (ffmpeg rubberband, pitch kept, both channels together); only within
     ±10 % — further than that, pick another track;
  2. its bar line D (track seconds, as --analyse prints them) lands on film --at (default 2.0, v1's cue "music":
     the display wakes); the two seconds before it in the track play under the name, faded in from silence if they
     are the middle of the track;
  3. with --final F: the track's own ending — its last strong chord F — lands on film --hit (default 26.0, the bar
     line before the halves of the mark meet). The ending comes in --lead bars before it (default 1), on a bar line,
     with a 40 ms equal-power crossfade that ends on the bar line, so the downbeat stays whole;
  4. a fade out 28.8 → 30.0 (v1's cue "fade"); 30.0 s exactly;
  5. high-passed at 30 Hz, then to −14 LUFS integrated and ≤ −1 dBTP by v2's look-ahead limiter (no clipper).
The report says where each cut of the film falls against the music's beats (it should be on one).
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.abspath(os.path.join(HERE, '..', '..'))
_spec = importlib.util.spec_from_file_location('mix', os.path.join(SITE, 'tools', 'film', 'mix.py'))
M = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(M)
L = M.L
SR = M.SR
TL = json.load(open(os.path.join(HERE, 'timeline.json')))
BPM = TL['bpm']
DUR = float(TL['duration'])


def stretch(x, tempo):
    """x [2, n] → x played `tempo` times faster (pitch kept)."""
    if abs(tempo - 1) < 1e-4:
        return x
    raw = np.ascontiguousarray(x.T.astype('<f4')).tobytes()
    out = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'f32le', '-ar', str(SR), '-ac', '2', '-i', '-',
                          '-af', f'rubberband=tempo={tempo:.6f}:pitchq=quality:channels=together',
                          '-f', 'f32le', '-ar', str(SR), '-ac', '2', '-'], input=raw, capture_output=True, check=True).stdout
    return np.frombuffer(out, dtype='<f4').astype(np.float64).reshape(-1, 2).T.copy()


def take(y, t0, n):
    """n samples of y from (stretched) track second t0, silence outside the track."""
    i0 = int(round(t0 * SR))
    out = np.zeros((2, n))
    a, b = max(0, i0), min(y.shape[1], i0 + n)
    if b > a:
        out[:, a - i0:b - i0] = y[:, a:b]
    return out


def cosramp(n):
    return 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, n))


def analyse(path, bpm=None):
    x, _ = M.load_track(path)
    A = M.analyse(x, bpm_hint=bpm)
    T = M.Track(A)
    bars = A['bars']
    print(f'{os.path.basename(path)}: {A["len"]:.2f} s, {A["bpm"]:.2f} bpm (grid {A["bpm_grid"]:.2f}, confidence '
          f'{A["tempo_conf"]:.2f}, steady {A["steady"]}), {len(bars)} bar lines, downbeat confidence {A["downbeat_conf"]}')
    print(f'  integrated {L.loudness(x)["integrated"]:.1f} LUFS, true peak {L.true_peak(x):.1f} dBTP')
    print(f'  sections (bar lines): {", ".join(f"{s:.2f}" for s in A["sections"])}')
    z = M.bar_strength(A)
    print('  bar line   energy of the bar (dB under the loud part)   downbeat strength')
    for j, d in enumerate(bars):
        e = T.db([(0, 99, d)], 0.0, 2 * 60 / A['bpm'] * 2)
        print(f'  {d:8.2f}   {e:6.1f} {"#" * int(max(0, 40 + e) / 2):<20s}   {z[j]:+.2f}{"   ← section" if any(abs(d - s) < 0.05 for s in A["sections"]) else ""}')
    fi = M.find_final(A, T)
    print(f'  the ending (last strong chord): {bars[fi]:.2f} s' if fi is not None else '  no clear final chord found')
    return A


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('track')
    ap.add_argument('--analyse', action='store_true')
    ap.add_argument('--bpm', type=float, help='the track\'s tempo (else measured)')
    ap.add_argument('--downbeat', type=float, help='the bar line (track s) that lands on film --at')
    ap.add_argument('--at', type=float, default=2.0)
    ap.add_argument('--final', type=float, help='the ending\'s strong chord (track s) that lands on film --hit')
    ap.add_argument('--hit', type=float, default=26.0)
    ap.add_argument('--lead', type=int, default=1, help='bars of the ending before its chord')
    ap.add_argument('--fade', type=float, nargs=2, default=TL['cues']['fade'])
    ap.add_argument('--name', default=None)
    a = ap.parse_args()
    if a.analyse:
        analyse(a.track, a.bpm)
        return 0
    if a.downbeat is None:
        sys.exit('music: --downbeat is needed (see --analyse)')
    x, _ = M.load_track(a.track)
    bpm = a.bpm or M.analyse(x)['bpm_grid']
    tempo = BPM / bpm
    if abs(tempo - 1) > 0.10:
        sys.exit(f'music: the track is {bpm:.1f} bpm — more than 10 % from the film\'s {BPM}; pick another track')
    y = stretch(x, tempo)
    s = 1 / tempo                                          # track seconds → stretched seconds
    D, bar = a.downbeat * s, 2 * 60 / BPM
    N = int(round(DUR * SR))
    film = take(y, D - a.at, N)                            # film f plays track D + (f − at)
    pre = D - a.at
    nin = int((0.6 if pre > 0.5 else 0.005) * SR)
    film[:, :nin] *= cosramp(nin)[None, :]
    if a.final is not None:
        F = a.final * s
        S = a.hit - a.lead * bar                           # the splice: a bar line in film time
        if abs(((S - a.at) / bar) - round((S - a.at) / bar)) > 1e-6:
            sys.exit('music: --hit minus the lead is not on a bar line of the film (at + 2k s)')
        xf = int(0.04 * SR)
        i = int(round(S * SR))
        end = take(y, F - (a.hit - (S - 0.04)), N - (i - xf))     # from S − 40 ms on, the ending's own time
        g = np.sqrt(cosramp(xf))
        film[:, i - xf:i] = film[:, i - xf:i] * g[::-1][None, :] + end[:, :xf] * g[None, :]
        film[:, i:] = end[:, xf:]
    f0, f1 = (int(round(t * SR)) for t in a.fade)
    film[:, f0:f1] *= cosramp(f1 - f0)[::-1][None, :]
    film[:, f1:] = 0
    film = L.sosfilt(film, L.butter('hp', 30, 4))
    out, info = M.master(film, -14.0, -1.0)
    name = a.name or os.path.splitext(os.path.basename(a.track))[0]
    path = os.path.join(SITE, 'video', '.cache', 'music3', f'{name}.wav')
    L.write_wav(path, out, 24)
    # QA: where the cuts fall on the music's beats (re-measured on the result)
    B = M.analyse(out, bpm_hint=BPM)
    beats = B['beats']
    cuts = [sh['from'] for sh in TL['shots'][1:]]
    off = [float((beats - c)[np.argmin(np.abs(beats - c))]) * 1000 for c in cuts]
    print(f'WROTE {os.path.relpath(path, SITE)}: {bpm:.2f} → {BPM} bpm (×{tempo:.4f}), track {a.downbeat:.2f} s on film {a.at}'
          + (f', ending {a.final:.2f} s on film {a.hit} ({a.lead} bar lead)' if a.final is not None else '')
          + f'; {info["lufs"]:.2f} LUFS, {info["tp"]:.2f} dBTP, limiter ≤ {info["limiter_max_gr_db"]:.1f} dB')
    print('  cuts against the nearest beat (ms): ' + ', '.join(f'{c:g}: {o:+.0f}' for c, o in zip(cuts, off)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
