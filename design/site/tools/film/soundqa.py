"""Sound QA by measurement only (spec v2 §3 "Sound QA"). Nobody on the team can listen, so these numbers are all
we have; they say whether the file is what the spec describes, not whether it sounds good.

    python3 -I tools/film/soundqa.py                      # the foley stem: video/.cache/foley.wav + foley.json + stems
    python3 -I tools/film/soundqa.py FILE.wav --master    # any master (e.g. mix.py's): loudness, peaks, gate, phone

Foley checks (each PASS/FAIL, with the measured number):
    designed onsets ≤ 6 in 30 s (event-level detector; a finer spectral-flux count is printed for information);
    exactly one run of digital zero before the end, 18.5000–19.0000 s (0.5000 s), and the file silent after 29.5;
    room tone −58 ±2 dBFS RMS per channel in the windows where nothing else sounds (and its L/R correlation);
    each event's peak within ±1 dB of spec; true peak ≤ −6 dBTP;
    no energy below 30 Hz (≤ −40 dB of the total);
    phone check: after a 300 Hz high-pass, the click's and the hinge's peaks within 3 dB of their full-band peaks;
    the room send's impulse response ≤ 0.35 s (reverb tails over 0.5 s are banned);
    integrated loudness (BS.1770-4) and true peak reported. The stem is not normalised, so loudness is a report.
"""
import argparse
import importlib.util
import json
import os
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.abspath(os.path.join(HERE, '..', '..'))
CACHE = os.path.join(SITE, 'video', '.cache')
_spec = importlib.util.spec_from_file_location('soundlib', os.path.join(HERE, 'soundlib.py'))
L = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(L)
SR = L.SR


# ---------------------------------------------------------------------------------------------------- detectors

def envelope_db(x, win=0.020, hop=0.005):
    """RMS over `win` every `hop`, the louder channel, in dBFS. → (times of window starts, dB)."""
    x = np.atleast_2d(x)
    w, h = int(win * SR), int(hop * SR)
    sq = np.concatenate([np.zeros((x.shape[0], 1)), np.cumsum(x * x, axis=1)], axis=1)
    st = np.arange(0, x.shape[1] - w + 1, h)
    ms = ((sq[:, st + w] - sq[:, st]) / w).max(axis=0)
    return st / SR, 10 * np.log10(np.maximum(ms, 1e-30))


def event_onsets(x, rise_db=10.0, fall_db=4.0, rearm=0.050):
    """Designed onsets: the 20 ms envelope rising `rise_db` over the room's floor after it has stayed within
    `fall_db` of the floor for `rearm` seconds. → (floor dB, [(t, peak dBFS within 0.3 s)])."""
    t, e = envelope_db(x)
    live = e > -200
    floor = float(np.median(e[live]))
    on, off = floor + rise_db, floor + fall_db
    out, armed, quiet = [], True, 0.0
    hop = t[1] - t[0]
    for i in range(len(e)):
        if armed and e[i] >= on:
            j0, j1 = int(t[i] * SR), int(min(t[i] + 0.3, x.shape[1] / SR) * SR)
            seg = np.abs(x[:, j0:j0 + int(0.025 * SR)]).max(axis=0)
            k = int(np.argmax(seg >= 0.5 * seg.max()))            # the attack: first sample at half the local peak
            out.append(((j0 + k) / SR, L.peak_db(x[:, j0:j1])))
            armed, quiet = False, 0.0
        elif not armed:
            quiet = quiet + hop if e[i] < off else 0.0
            if quiet >= rearm:
                armed = True
    return floor, out


def flux_onsets(x, gap=0.05):
    """Spectral-flux onsets (log magnitude, 1024/256 STFT, adaptive median threshold, ≥ gap apart): a fine count
    that also sees the hinge's individual friction grains. For information."""
    m = np.atleast_2d(x).mean(axis=0)
    n, h = 1024, 256
    win = np.hanning(n)
    st = np.arange(0, len(m) - n, h)
    S = np.abs(np.fft.rfft(np.stack([m[s:s + n] * win for s in st]), axis=1))
    S = np.log1p(1e4 * S)
    fl = np.maximum(np.diff(S, axis=0), 0).sum(axis=1)
    fl = np.concatenate([[0], fl])
    k = int(0.5 * SR / h)
    pad = np.pad(fl, k, mode='edge')
    med = np.array([np.median(pad[i:i + 2 * k + 1]) for i in range(len(fl))])
    mad = np.median(np.abs(fl - np.median(fl))) + 1e-9
    th = med + 6 * mad
    peaks = [i for i in range(1, len(fl) - 1) if fl[i] > th[i] and fl[i] >= fl[i - 1] and fl[i] > fl[i + 1]]
    out, last = [], -1e9
    for i in peaks:
        tt = (st[i] + n / 2) / SR
        if tt - last >= gap:
            out.append(tt)
            last = tt
    return out


def phone(x, order=2):
    return L.sosfilt(x, L.butter('hp', 300.0, order), pad=SR // 4)


def window(x, a, b):
    return x[:, max(0, int(round(a * SR))):max(0, int(round(b * SR)))]


def master_report(x, label):
    """Loudness, peaks and the phone check of any master → (lines, numbers)."""
    lo = L.loudness(x)
    tp, tpf = L.true_peak(x), L.true_peak_fft(x)
    rel30, abs30 = L.band_energy_db(x, 0, 30)
    xp = phone(x)
    lp = L.loudness(xp)
    rms_full, rms_ph = L.rms_db(x), L.rms_db(xp)
    crest = L.peak_db(xp) - rms_ph
    mid, _ = L.band_energy_db(xp, 300, 4000)
    lines = [f'{label}',
             f'  integrated loudness   {lo["integrated"]:7.2f} LUFS (BS.1770-4, gated)',
             f'  momentary max         {lo["momentary_max"]:7.2f} LUFS   short-term max {lo["short_term_max"]:7.2f} LUFS',
             f'  sample peak           {L.peak_db(x):7.2f} dBFS',
             f'  true peak             {tp:7.2f} dBTP (4× windowed sinc)   {tpf:7.2f} dBTP (ideal 4× FFT)',
             f'  energy below 30 Hz    {rel30:7.2f} dB of total   ({abs30:.1f} dBFS as RMS)',
             f'  phone (HP 300 Hz, 12 dB/oct): loudness {lp["integrated"]:7.2f} LUFS ({lp["integrated"] - lo["integrated"]:+.2f} LU), '
             f'RMS {rms_ph - rms_full:+.2f} dB, crest {crest:.2f} dB, share 300 Hz–4 kHz {100 * 10 ** (mid / 10):.1f} %']
    return lines, {'lufs': lo['integrated'], 'tp': tp, 'tp_fft': tpf, 'below30_rel': rel30, 'phone_lufs': lp['integrated']}


# ---------------------------------------------------------------------------------------------------- foley QA

def qa_foley(wav_path, json_path, stems_dir):
    x, sr = L.read_wav(wav_path)
    with wave.open(wav_path) as w:
        bits = w.getsampwidth() * 8
    meta = json.load(open(json_path))
    stems = {}
    for k in ('room', 'hinge', 'settle', 'click', 'seat', 'events'):
        p = os.path.join(stems_dir, k + '.wav')
        if os.path.exists(p):
            stems[k] = L.read_wav(p)[0]
    cues = meta['cues']
    z0, z1 = cues['zero']
    end = cues['end']
    ok = True
    out = []

    def check(name, passed, detail):
        nonlocal ok
        ok &= bool(passed)
        out.append(f'[{"PASS" if passed else "FAIL"}] {name}: {detail}')

    out.append(f'Foley stem QA, by measurement only. Nobody has listened to this file.')
    out.append(f'file {os.path.relpath(wav_path, SITE)}: {sr} Hz, {x.shape[0]} ch, {bits}-bit, {x.shape[1] / sr:.4f} s, '
               f'seed {meta.get("seed")}, cues from timeline.json v{meta.get("timeline_version")}')
    out.append('')
    check('format', sr == 48000 and x.shape[0] == 2 and bits == 24 and abs(x.shape[1] / sr - meta['duration']) < 1e-9,
          f'{sr} Hz, {x.shape[0]} channels, {bits}-bit, {x.shape[1]} samples')

    # 1. onsets
    floor, ons = event_onsets(x)
    names = []
    for t, p in ons:
        hits = [e['name'] for e in meta['events']
                if e['t'] - 0.03 <= t <= e['t'] + (e['span'][1] - e['span'][0] if 'span' in e else 0.1)]
        names.append(f'{t:.3f} s ({p:.1f} dBFS, {"+".join(hits)})' if hits else f'{t:.3f} s ({p:.1f} dBFS, NOT A DESIGNED EVENT)')
    stray = [n for n in names if 'NOT A DESIGNED' in n]
    check('designed onsets ≤ 6', len(ons) <= 6 and not stray,
          f'{len(ons)} onsets (20 ms envelope ≥ floor + 10 dB, re-armed after 50 ms within floor + 4 dB; floor '
          f'{floor:.1f} dB): ' + '; '.join(names))
    fl = flux_onsets(x)
    out.append(f'       for information, a fine spectral-flux detector (≥ 50 ms apart) finds {len(fl)}: the hinge\'s '
               f'friction grains count one by one there ({sum(1 for t in fl if cues["lid"][0] - 0.05 <= t < cues["settle"] - 0.03)} of them '
               f'in {cues["lid"][0]}–{cues["settle"]} s) and a broadband flux barely sees the low thumps; the rest at '
               + ', '.join(f'{t:.3f}' + (' (the room returning after the zero)' if abs(t - z1) < 0.02 else '')
                           for t in fl if not (cues['lid'][0] - 0.05 <= t < cues['settle'] - 0.03)) + ' s')

    # 2. digital zero
    runs = L.zero_runs(x, int(0.001 * SR))
    before = [r for r in runs if r[0] < int(round(end * SR))]
    after = [r for r in runs if r[0] >= int(round(end * SR))]
    want = (int(round(z0 * SR)), int(round(z1 * SR)))
    desc = ', '.join(f'{a / SR:.5f}–{b / SR:.5f} s ({(b - a) / SR:.4f} s)' for a, b in runs)
    check(f'digital zero exactly {z0}–{z1} s and nowhere else before {end}', before == [want],
          f'runs of ≥ 1 ms where both channels are exactly 0: {desc}')
    tail_ok = len(after) == 1 and after[0] == (int(round(end * SR)), x.shape[1])
    last = np.flatnonzero(np.any(x != 0, axis=0))
    check(f'audio ends at {end} s', tail_ok, f'last non-zero sample at {last[-1] / SR:.5f} s; zero from {end} s to the end: {tail_ok}')
    short = L.zero_runs(x, 8)
    out.append(f'       shorter both-channel zero runs (8–47 samples) anywhere: {len(short) - len(runs)}')

    # 3. room tone
    ev_end = {e['name']: e['t'] + 0.05 for e in meta['events']}
    windows = [(0.5, cues['lid'][0] - 0.1), (cues['settle'] + 0.6, cues['click'] - 0.1), (cues['click'] + 0.5, z0 - 0.05),
               (z1 + cues['roomReturnFade'] + 0.1, cues['seat'] - 0.1), (cues['seat'] + 0.9, end - 0.05)]
    rows, allrms = [], []
    for a, b in windows:
        seg = window(x, a, b)
        ev = window(stems['events'], a, b) if 'events' in stems else None
        r = [L.rms_db(seg[c]) for c in range(2)]
        allrms += r
        quiet = '' if ev is None else f', events stem there {L.peak_db(ev):.0f} dBFS peak'
        rows.append(f'{a:.2f}–{b:.2f} s L {r[0]:.2f} R {r[1]:.2f}{quiet}')
    lo_r, hi_r = min(allrms), max(allrms)
    check('room tone −58 ±2 dBFS RMS', -60 <= lo_r and hi_r <= -56, f'{lo_r:.2f} to {hi_r:.2f} dBFS; ' + '; '.join(rows))
    if 'room' in stems:
        rm = stems['room']
        live = np.all(rm != 0, axis=0)
        cc = np.corrcoef(rm[0, live], rm[1, live])[0, 1]
        out.append(f'       room stem over all its live samples: L {L.rms_db(rm[0, live]):.2f}, R {L.rms_db(rm[1, live]):.2f} dBFS RMS, '
                   f'L/R correlation {cc:.3f} (spec 0.4)')

    # 4. event peaks
    stem_of = {'hinge': 'hinge', 'settle': 'settle', 'click': 'click', 'release': 'click', 'seat': 'seat'}
    evs = sorted(meta['events'], key=lambda e: e['t'])
    peak_rows, peak_ok = [], True
    phone_rows, phone_ok = [], True
    for i, e in enumerate(evs):
        a = e['t'] - 0.002
        b = e['t'] + e['length_s']
        if i + 1 < len(evs):
            b = min(b, evs[i + 1]['t'] - 0.002)
        st = stems.get(stem_of[e['name']])
        ps = L.peak_db(window(st, a, b)) if st is not None else float('nan')
        pm = L.peak_db(window(x, a, b))
        d = ps - e['spec_peak_dbfs']
        good = abs(d) <= 1.0
        peak_ok &= good
        peak_rows.append(f'{e["name"]} at {e["t"]:.4f} s: stem {ps:.2f}, in the mix {pm:.2f} dBFS, spec {e["spec_peak_dbfs"]:.1f} '
                         f'({d:+.2f} dB{"" if good else " OUT"})')
        if st is not None:
            ph2, ph4 = L.peak_db(window(phone(st, 2), a, b)), L.peak_db(window(phone(st, 4), a, b))
            loss2, loss4 = ph2 - ps, ph4 - ps
            gated = e['name'] in ('click', 'release', 'hinge')
            if gated:
                phone_ok &= loss2 >= -3.0
            phone_rows.append(f'{e["name"]} {loss2:+.2f} dB (24 dB/oct: {loss4:+.2f}){"" if gated else " [not gated: a felt low sound]"}')
    check('event peaks within ±1 dB of spec', peak_ok, '; '.join(peak_rows))

    # the hinge follows the lid: its envelope against |dθ/dt| of θ = 108°·easeInOutCubic((t − a)/(b − a))
    hg = next((e for e in meta['events'] if e['name'] == 'hinge'), None)
    if hg is not None and 'hinge' in stems:
        a, b = hg['span']
        t, e = envelope_db(stems['hinge'], win=0.05, hop=0.01)
        tc = t + 0.025
        sel = (tc >= a) & (tc <= b)
        x01 = np.clip((tc[sel] - a) / (b - a), 0, 1)
        v = np.where(x01 < 0.5, 4 * x01 * x01, (2 - 2 * x01) ** 2)
        amp = 10 ** (e[sel] / 20)
        r = float(np.corrcoef(amp, v)[0, 1])
        rate = hg.get('grains', 0) / (b - a)
        check('hinge follows the lid\'s angular velocity', r >= 0.8,
              f'correlation of its 50 ms RMS envelope with |dθ/dt| r = {r:.3f}; {hg.get("grains")} stick-slip grains in '
              f'{b - a:.2f} s ({rate:.1f} a second overall, 18–30 while it moves)')

    # 5. peaks and loudness
    lines, num = master_report(x, 'foley stem')
    check('true peak ≤ −6 dBTP', num['tp'] <= -6 and num['tp_fft'] <= -6, f'{num["tp"]:.2f} dBTP (FFT {num["tp_fft"]:.2f})')
    check('no energy below 30 Hz', num['below30_rel'] <= -40, f'{num["below30_rel"]:.2f} dB of the total energy lies below 30 Hz')
    check('phone check (HP 300 Hz): click and hinge within 3 dB of full band', phone_ok, '; '.join(phone_rows))
    ir = meta.get('ir', {})
    check('room send ≤ 0.35 s (nothing over 0.5 s)', ir.get('length_s', 9) <= 0.35 and max(meta['sends'].values()) <= 0.10,
          f'IR {ir.get("length_s")} s from {ir.get("images")} image sources, first reflection {ir.get("first_reflection_ms")} ms, '
          f'RT60 (T20) by band {ir.get("rt60_t20_s")}; sends {meta["sends"]}')
    out.append('')
    out += lines
    lo = num['lufs']
    out.append(f'  (not loudness-normalised, by design. The spec guessed "about −36 LUFS"; its own levels — a room at −58 dBFS '
               f'and four short events — integrate to {lo:.1f} LUFS here. Nothing was raised to meet the guess.)')
    for k in ('room', 'events', 'hinge', 'settle', 'click', 'seat'):
        if k in stems:
            lk = L.loudness(stems[k])['integrated']
            out.append(f'  stem {k:7s} integrated {lk:7.2f} LUFS, sample peak {L.peak_db(stems[k]):7.2f} dBFS, '
                       f'true peak {L.true_peak(stems[k]):7.2f} dBTP')
    out.append('')
    out.append('Placed (from foley.json): ' + '; '.join(f'{e["name"]} {e["t"]:.4f} s ({e["jitter_ms"]:+.2f} ms, '
                                                        f'{e["level_offset_db"]:+.2f} dB)' for e in evs))
    out.append('Overall: ' + ('all checks pass.' if ok else 'SOME CHECKS FAIL.') +
               ' These are measurements; nobody has heard the stem. It must be listened to before anything is published.')
    return ok, '\n'.join(out) + '\n'


def main():
    ap = argparse.ArgumentParser(description='Sound QA by measurement')
    ap.add_argument('wav', nargs='?', default=os.path.join(CACHE, 'foley.wav'))
    ap.add_argument('--json')
    ap.add_argument('--stems')
    ap.add_argument('--master', action='store_true', help='loudness/peaks/phone report for any file')
    ap.add_argument('--out')
    o = ap.parse_args()
    if o.master:
        x, sr = L.read_wav(o.wav)
        if sr != SR:
            x = L.resample(x, sr)
        lines, _ = master_report(x, os.path.relpath(os.path.abspath(o.wav), SITE))
        runs = L.zero_runs(x, int(0.001 * SR))
        lines.append('  digital zero runs ≥ 1 ms: ' + (', '.join(f'{a / SR:.4f}–{b / SR:.4f} s' for a, b in runs) or 'none'))
        text = '\n'.join(lines) + '\n'
        ok = True
    else:
        base = os.path.splitext(o.wav)[0]
        ok, text = qa_foley(o.wav, o.json or base + '.json', o.stems or os.path.join(os.path.dirname(o.wav), 'foley-stems'))
    print(text, end='')
    if o.out:
        with open(o.out, 'w') as f:
            f.write(text)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
