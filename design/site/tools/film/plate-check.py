"""Measures rendered plates against the spec's studio targets (spec v2 §2, §5 gates): the graphite cyclorama's
wall 11–12, horizon band 24–28, floor 14–20 (sRGB code values), R = G = B ± 1.

    python3 -I tools/film/plate-check.py video/.cache/lookdev/PL-CARD-0000.png [more.png ...]

For each 16-bit plate (png16.write; a preview's <name>-cov.png next to it marks the studio's pixels, else every
pixel counts) it finds what each pixel sees by casting the camera's rays (the sidecar <ID>.json beside it, or
video/.cache/plates/<ID>.json) against the cyclorama's profile (floor y = 0 to z = −1500, cove radius 1200, wall
z = −2700), then reports per region (wall: the flat wall; horizon: the cove; floor: the flat floor) the mean
and the 5–95 % range in sRGB code values, a top-to-bottom profile of row means, and the largest |R−G|, |G−B|
on the studio's pixels. The verdict uses: top-of-frame rows (the top 4 %), the brightest band of the profile,
and the bottom rows (the bottom 8 %), all on studio pixels.
"""
import importlib.util
import json
import pathlib
import re
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('png16', HERE / 'png16.py')
png16 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(png16)

CYC = dict(zCove=-1500.0, r=1200.0, zWall=-2700.0)
TARGET = dict(top=(11, 12), band=(24, 28), bottom=(14, 20))


def rays(cam, w, h):
    """World-space ray directions for pixel centres, as the renderer projects (lookAt + lens shift)."""
    eye, tgt = np.array(cam['eye'], float), np.array(cam['target'], float)
    z = eye - tgt
    z /= np.linalg.norm(z)
    x = np.cross([0.0, 1.0, 0.0], z)
    x /= np.linalg.norm(x)
    y = np.cross(z, x)
    t = 1 / np.tan(np.radians(cam['fov']) / 2)
    asp = w / h
    sx, sy = cam.get('shift', [0, 0])
    px = (np.arange(w) + 0.5) / w * 2 - 1
    py = 1 - (np.arange(h) + 0.5) / h * 2
    a = (px[None, :] + sx) * asp / t
    b = (py[:, None] + sy) / t
    d = x[None, None, :] * a[..., None] + y[None, None, :] * b[..., None] - z[None, None, :]
    return eye, d / np.linalg.norm(d, axis=2, keepdims=True)


def regions(cam, w, h):
    """0 floor, 1 the cove's lower half (the horizon band), 2 wall (the flat wall and the cove above 60°), -1 nothing."""
    eye, d = rays(cam, w, h)
    reg = np.full((h, w), -1, np.int8)
    best = np.full((h, w), np.inf)
    # floor y = 0, z >= zCove
    with np.errstate(divide='ignore', invalid='ignore'):
        t = -eye[1] / d[..., 1]
        z = eye[2] + t * d[..., 2]
        ok = (t > 0) & (z >= CYC['zCove'])
        best = np.where(ok, t, best)
        reg[ok] = 0
        # wall z = zWall, y >= r
        t = (CYC['zWall'] - eye[2]) / d[..., 2]
        yy = eye[1] + t * d[..., 1]
        ok = (t > 0) & (yy >= CYC['r']) & (t < best)
        best = np.where(ok, t, best)
        reg[ok] = 2
        # cove: (y - r)^2 + (z - zCove)^2 = r^2, y <= r, z <= zCove (ray from inside: the far root)
        oy, oz = eye[1] - CYC['r'], eye[2] - CYC['zCove']
        A = d[..., 1] ** 2 + d[..., 2] ** 2
        B = 2 * (oy * d[..., 1] + oz * d[..., 2])
        C = oy * oy + oz * oz - CYC['r'] ** 2
        disc = B * B - 4 * A * C
        sq = np.sqrt(np.maximum(disc, 0))
        for tt in ((-B + sq) / (2 * A), (-B - sq) / (2 * A)):
            yy = eye[1] + tt * d[..., 1]
            zz = eye[2] + tt * d[..., 2]
            ok = (disc >= 0) & (tt > 0) & (yy <= CYC['r'] + 1e-6) & (zz <= CYC['zCove'] + 1e-6) & (tt < best)
            best = np.where(ok, tt, best)
            reg[ok] = np.where(yy[ok] > 0.5 * CYC['r'], 2, 1)        # the cove's upper half (steeper than 60°) reads as wall
    return reg


def sidecar(path):
    m = re.match(r'(.+?)-(\d{4})\.png$', path.name)
    if m:
        ident, i = m.group(1), int(m.group(2))
        cands = [path.with_name(f'{ident}.json'), HERE.parent.parent / 'video/.cache/plates' / f'{ident}.json']
    else:
        ident, i = path.parent.name, int(path.stem)
        cands = [path.parent.parent / f'{ident}.json']
    for c in cands:
        if c.exists():
            j = json.loads(c.read_text())
            fr = j['frames'][min(i, len(j['frames']) - 1)]
            return ident, i, fr['cam']
    return ident, i, None


def check(path):
    path = pathlib.Path(path)
    rgb16 = png16.read(path)
    h, w, _ = rgb16.shape
    v = rgb16.astype(np.float64) / 257.0                 # sRGB code values (0–255), not rounded
    cov_file = path.with_name(path.stem + '-cov.png')
    if cov_file.exists():
        from PIL import Image
        cov = np.asarray(Image.open(cov_file)).astype(np.float64) / 255 > 0.999
    else:
        cov = np.ones((h, w), bool)                     # no mask: every pixel counts (fine for the empty-studio plates;
                                                        # for plates with the Mac, check the --preview render, which has one)
    ident, i, cam = sidecar(path)
    lum = v.mean(axis=2)
    q = np.round(v)
    drift = max(np.abs(q[..., 0] - q[..., 1])[cov].max(initial=0), np.abs(q[..., 1] - q[..., 2])[cov].max(initial=0))
    out = {'file': str(path), 'id': ident, 'frame': i, 'size': [w, h], 'studio': round(float(cov.mean()), 3), 'mask': cov_file.exists(), 'rgbDrift': int(drift)}
    reg = None
    if cam is not None:
        reg = regions(cam, w, h)
        for k, name in ((2, 'wall'), (1, 'horizon'), (0, 'floor')):
            m = cov & (reg == k)
            if m.sum() > 50:
                vals = lum[m]
                out[name] = [round(float(vals.mean()), 2), round(float(np.percentile(vals, 5)), 2), round(float(np.percentile(vals, 95)), 2), round(float(m.mean()), 3)]
    # a profile of row means (studio pixels only, the middle 60 % of the width)
    c0, c1 = int(w * 0.2), int(w * 0.8)
    rows = []
    for r in range(h):
        m = cov[r, c0:c1]
        rows.append(float(lum[r, c0:c1][m].mean()) if m.sum() > (c1 - c0) * 0.3 else np.nan)
    rows = np.array(rows)
    bands = np.array_split(np.arange(h), 25)
    out['profile'] = [None if np.isnan(np.nanmean(rows[b]) if np.isfinite(rows[b]).any() else np.nan) else round(float(np.nanmean(rows[b])), 1) for b in bands]
    top = rows[: max(1, int(h * 0.04))]
    bot = rows[int(h * 0.92):]
    sm = np.convolve(np.nan_to_num(rows, nan=0), np.ones(max(1, h // 50)) / max(1, h // 50), mode='same')
    out['top'] = round(float(np.nanmean(top)), 2) if np.isfinite(top).any() else None
    out['band'] = round(float(np.nanmax(sm)), 2)
    out['bandRow'] = round(float(np.nanargmax(sm) / h), 3)
    out['bottom'] = round(float(np.nanmean(bot)), 2) if np.isfinite(bot).any() else None
    verdict = []
    topWall = cam is None or (reg[: max(1, int(h * 0.04))] == 2).mean() > 0.5
    for k, (lo, hi) in TARGET.items():
        val = out[k]
        if k == 'top' and not topWall:
            verdict.append(f'top {val} n/a (no wall at the top of this frame)')
            continue
        verdict.append(f'{k} {val} ' + ('ok' if val is not None and lo - 0.5 <= val <= hi + 0.5 else f'MISS ({lo}–{hi})'))
    verdict.append('rgb ' + ('ok' if drift <= 1 else f'MISS (drift {int(drift)})'))
    out['verdict'] = verdict
    return out


if __name__ == '__main__':
    for p in sys.argv[1:]:
        r = check(p)
        print(json.dumps(r))
