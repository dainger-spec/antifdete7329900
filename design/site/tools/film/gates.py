# The promo film v2's pixel gates (spec v2 §2 Palette, §6). tools/film/gates.mjs runs them all; each can also be
# run by hand. Exit 1 on a failure.
#
#   python3 -I tools/film/gates.py palette FRAMES… [--dom DIR]   # output frames (1920 × 1080, 8-bit)
#       A connected region > 64 px with OKLab chroma > 0.025, outside the chips' and traffic lights' masks (from
#       the frame's record in DIR), whose core is not the exact #2F6BEF (ΔE_OK < 0.02) → fail; more than one
#       blue region in a frame → fail. Frame numbers come from NNNN.png, or <lang>-<seconds>.png for stills.
#   python3 -I tools/film/gates.py plates [ID…]                 # rendered plates: |R−G|, |G−B| ≤ 1 off the display
#   python3 -I tools/film/gates.py flash DIR [--from F --to F]  # WCAG 2.3.1: ≤ 3 general flashes in any 1 s
#   python3 -I tools/film/gates.py glyphs DIR                   # glyph gap ≥ 0.04 em (gates.mjs renders the lines)
#   python3 -I tools/film/gates.py s08 L.png R.png Y            # the two halves identical below the toolbar band
import json
import os
import re
import struct
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.abspath(os.path.join(HERE, '..', '..'))
CACHE = os.path.join(SITE, 'video', '.cache')
BLUE = (0x2F, 0x6B, 0xEF)


def lin(x):
    x = np.asarray(x, np.float32)
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def oklab(rgb8):
    c = lin(np.asarray(rgb8, np.float32) / 255.0)
    r, g, b = c[..., 0], c[..., 1], c[..., 2]
    l = np.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    m = np.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    s = np.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return np.stack([0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s], axis=-1)


def label(mask):
    """8-connected components of a boolean mask (run-length union-find; no scipy). Returns (labels, sizes)."""
    h, w = mask.shape
    parent = [0]
    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    runs_prev = []
    lab = np.zeros((h, w), np.int32)
    for y in range(h):
        row = mask[y]
        if not row.any():
            runs_prev = []
            continue
        d = np.diff(np.concatenate([[0], row.view(np.int8), [0]]))
        starts, ends = np.nonzero(d == 1)[0], np.nonzero(d == -1)[0]
        runs = []
        j = 0
        for s, e in zip(starts, ends):
            ids = []
            while j < len(runs_prev) and runs_prev[j][1] < s - 1:
                j += 1
            k = j
            while k < len(runs_prev) and runs_prev[k][0] <= e:
                ids.append(runs_prev[k][2])
                k += 1
            if ids:
                root = find(ids[0])
                for o in ids[1:]:
                    ro = find(o)
                    if ro != root:
                        parent[ro] = root
                lid = root
            else:
                lid = len(parent)
                parent.append(lid)
            lab[y, s:e] = lid
            runs.append((s, e, lid))
        runs_prev = runs
    roots = np.array([find(i) for i in range(len(parent))], np.int32)
    lab = roots[lab]
    sizes = np.bincount(lab.ravel(), minlength=len(parent))
    return lab, sizes


def frame_of(path):
    b = os.path.basename(path)
    m = re.match(r'^(\d{4})\.png$', b)
    if m:
        return int(m.group(1))
    m = re.match(r'^[a-z]{2}-(\d+(?:\.\d+)?)\.png$', b)
    return round(float(m.group(1)) * 60) if m else None


def palette(files, dom):
    ok = True
    blue_lab = oklab(np.array(BLUE, np.uint8))
    hue_b = np.arctan2(blue_lab[2], blue_lab[1])
    for f in files:
        img = np.asarray(Image.open(f).convert('RGB'))
        lab = oklab(img)
        chroma = np.hypot(lab[..., 1], lab[..., 2])
        mask = chroma > 0.025
        n = frame_of(f)
        rec = None
        if n is not None and dom and os.path.exists(os.path.join(dom, f'{n:04d}.json')):
            rec = json.load(open(os.path.join(dom, f'{n:04d}.json')))
        allow = np.zeros(mask.shape, bool)
        k = img.shape[1] / 1920
        for x, y, w, h in (rec or {}).get('masks', []):
            x0, y0 = max(0, int((x - 3) * k)), max(0, int((y - 3) * k))
            allow[y0:int((y + h + 3) * k) + 1, x0:int((x + w + 3) * k) + 1] = True
        # one element is one region: glyphs of a line of text, a hairline's broken pixels — group parts within 8 px
        grp = mask.copy()
        for _ in range(8):
            g2 = grp.copy()
            g2[1:] |= grp[:-1]; g2[:-1] |= grp[1:]; g2[:, 1:] |= grp[:, :-1]; g2[:, :-1] |= grp[:, 1:]
            grp = g2
        lab_ids, _ = label(grp)
        lab_ids = np.where(mask, lab_ids, 0)
        sizes = np.bincount(lab_ids.ravel(), minlength=int(lab_ids.max()) + 1)
        bad, blues = [], 0
        for lid in np.nonzero(sizes > 64)[0]:
            if lid == 0:
                continue
            sel = lab_ids == lid
            if (sel & allow).any() and (sel & ~allow).sum() <= 64:
                continue
            de = np.sqrt(((lab[sel] - blue_lab) ** 2).sum(-1))
            ys, xs = np.nonzero(sel)
            thin = min(np.ptp(ys), np.ptp(xs)) <= 4 or sel.sum() / ((np.ptp(ys) + 1) * (np.ptp(xs) + 1)) < 0.08
            hue = np.arctan2(lab[sel][:, 2], lab[sel][:, 1])
            hue_ok = np.abs(np.angle(np.exp(1j * (hue - hue_b)))) < np.radians(8)
            core = de.min() < 0.02 or (thin and (hue_ok & (de < 0.10)).any())
            if core:
                blues += 1
            else:
                bad.append((int(sizes[lid]), int(xs.mean()), int(ys.mean()), float(chroma[sel].max())))
        shot = (rec or {}).get('shot', '?')
        if bad or blues > 1:
            ok = False
            print(f'PALETTE FAIL {os.path.basename(f)} ({shot}): {len(bad)} coloured region(s) off the masks {bad[:4]}, {blues} blue region(s)')
        else:
            print(f'palette ok   {os.path.basename(f)} ({shot}): {blues} blue region(s)')
    return ok


def read16(path):
    w, h = struct.unpack('>II', open(path, 'rb').read(24)[16:24])
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', 'rgb48le', '-'], check=True, capture_output=True).stdout
    return np.frombuffer(raw, '<u2').reshape(h, w, 3).astype(np.float32) / 65535 * 255


def plates(ids):
    ok = True
    pdir = os.path.join(CACHE, 'plates')
    if not os.path.isdir(pdir):
        print('plates: none rendered yet (post.py uses the graphite placeholder, which is neutral by construction)')
        return True
    ids = ids or sorted(x[:-5] for x in os.listdir(pdir) if x.endswith('.json') and '.' not in x[:-5])
    blue_lab = oklab(np.array(BLUE, np.uint8))
    hue_b = np.arctan2(blue_lab[2], blue_lab[1])
    for pid in ids:
        meta = json.load(open(os.path.join(pdir, f'{pid}.json')))
        d = os.path.join(pdir, pid)
        files = sorted(x for x in os.listdir(d) if re.match(r'^\d{4}\.png$', x)) if os.path.isdir(d) else []
        for x in files[:: max(1, len(files) // 6)]:
            a = read16(os.path.join(d, x))
            fr = meta['frames'][min(int(x[:4]), len(meta['frames']) - 1)] if meta.get('frames') else {}
            off = np.ones(a.shape[:2], bool)
            if fr.get('display'):
                q = np.array(fr['display'])
                x0, y0 = q.min(0) - 0.03 * a.shape[1]
                x1, y1 = q.max(0) + 0.03 * a.shape[1]
                off[max(0, int(y0)):int(y1) + 1, max(0, int(x0)):int(x1) + 1] = False
            a8 = np.rint(a)
            dev = np.maximum(np.abs(a8[..., 0] - a8[..., 1]), np.abs(a8[..., 1] - a8[..., 2]))
            lab = oklab(np.clip(a8, 0, 255).astype(np.uint8))
            hue = np.arctan2(lab[..., 2], lab[..., 1])
            # the mark's blue seam (and its anti-aliased edge) may be off neutral; a faint blue cast may not, so
            # only pixels saturated like the seam are let off (a cast of a few levels is under 0.025 chroma)
            seam = (np.abs(np.angle(np.exp(1j * (hue - hue_b)))) < np.radians(25)) & (np.hypot(lab[..., 1], lab[..., 2]) > 0.025)
            badm = (dev > 1) & off & ~seam
            if badm.any():
                ok = False
                print(f'PLATE FAIL {pid}/{x}: {int(badm.sum())} px off neutral (max |R−G|,|G−B| {int(dev[badm].max())})')
            else:
                print(f'plate ok   {pid}/{x}: neutral off the display (max deviation {int(dev[off & ~seam].max()) if (off & ~seam).any() else 0})')
    return ok


def flash(d, a=None, b=None):
    """WCAG 2.3.1 general flash, on the frames in d (finished frames, or RGBA DOM captures over the graphite).
    Luminance is averaged over the area WCAG counts (25% of a 10° field: 21 824 px at 1024 × 768, about 240 × 240
    px at 1080p), on blocks overlapping by half; a flash is a pair of opposing changes of ≥ 0.1 relative
    luminance with the darker side under 0.8. More than three in any second (7+ changes) fails."""
    files = sorted(x for x in os.listdir(d) if re.match(r'^\d{4}\.png$', x))
    if a is not None:
        files = [x for x in files if a <= int(x[:4]) <= b]
    if len(files) < 2:
        print('flash: fewer than two frames')
        return True
    L = []
    for x in files:
        im = Image.open(os.path.join(d, x)).convert('RGBA').resize((240, 135), Image.BOX)
        p = np.asarray(im, np.float32) / 255
        c = lin(p[..., :3]) * p[..., 3:4] + 0.008 * (1 - p[..., 3:4])     # over the graphite (≈ sRGB 24)
        y = c @ np.array([0.2126, 0.7152, 0.0722], np.float32)
        cs = np.pad(y.cumsum(0).cumsum(1), ((1, 0), (1, 0)))
        B, S = 30, 15                                                    # 240 px blocks at 1080p, stride 120
        ys, xs = np.arange(0, 135 - B + 1, S), np.arange(0, 240 - B + 1, S)
        blk = (cs[ys[:, None] + B, xs[None, :] + B] - cs[ys[:, None], xs[None, :] + B] - cs[ys[:, None] + B, xs[None, :]] + cs[ys[:, None], xs[None, :]]) / (B * B)
        L.append(blk)
    L = np.stack(L)
    n = L.shape[0]
    trans = np.zeros(L.shape, bool)
    hi, lo = L[0].copy(), L[0].copy()
    dirn = np.zeros(L.shape[1:], np.int8)
    for i in range(1, n):
        x = L[i]
        up = (x - lo >= 0.1) & (np.minimum(lo, x) < 0.8) & (dirn != 1)
        dn = (hi - x >= 0.1) & (np.minimum(hi, x) < 0.8) & (dirn != -1) & ~up
        t = up | dn
        trans[i] = t
        dirn = np.where(up, 1, np.where(dn, -1, dirn)).astype(np.int8)
        hi = np.where(t, x, np.maximum(hi, x))
        lo = np.where(t, x, np.minimum(lo, x))
    cs = np.cumsum(trans, axis=0)
    most, at = 0, 0
    for i in range(n):
        j = min(n - 1, i + 59)
        m = int((cs[j] - (cs[i - 1] if i else 0)).max())
        if m > most:
            most, at = m, i
    ok = most < 7
    print(f'{"flash ok" if ok else "FLASH FAIL"}: frames {files[0][:4]}–{files[-1][:4]}: at most {most} opposing changes ({most // 2} flashes) '
          f'in a 1-s window of any 240-px area (from frame {int(files[at][:4])}); the limit is 3 flashes')
    return ok


def glyphs(d, fix=None):
    """Each pair of neighbouring glyphs of each display-size line, rendered alone (red, green on black): their
    ink at least 0.04 em apart. With fix: the pairs that are closer get the space they lack in kern.json."""
    ok = True
    meta = json.load(open(os.path.join(d, 'glyphs.json')))
    need = {}
    worst = {}
    for m in meta:
        a = np.asarray(Image.open(os.path.join(d, m['file'])).convert('RGB'), np.float32) / 255
        red = (a[..., 0] > 0.5) & (a[..., 1] < 0.5)
        grn = (a[..., 1] > 0.5) & (a[..., 0] < 0.5)
        def edge(mk):
            e = mk.copy()
            e[1:-1, 1:-1] &= ~(mk[:-2, 1:-1] & mk[2:, 1:-1] & mk[1:-1, :-2] & mk[1:-1, 2:])
            return np.argwhere(e).astype(np.float32)
        r, g = edge(red), edge(grn)
        if not len(r) or not len(g):
            continue
        best = np.inf
        for i in range(0, len(r), 3000):
            best = min(best, float(((r[i:i + 3000, None, :] - g[None, :, :]) ** 2).sum(-1).min()))
        gap = max(0.0, np.sqrt(best) - 1) / m['px']
        key = (m['shot'], m['text'])
        if key not in worst or gap < worst[key][0]:
            worst[key] = (gap, m['pair'])
        if gap < 0.04:
            ok = False
            print(f'GLYPH GAP FAIL {m["shot"]} «{m["text"]}»: «{m["pair"]}» {gap:.3f} em < 0.04 em')
            sz = need.setdefault(m['size'], {})
            sz[m['pair']] = max(sz.get(m['pair'], 0), round(0.045 - gap, 3))
    for (shot, text), (gap, pair) in worst.items():
        if gap >= 0.04:
            print(f'glyph gap ok {shot} «{text}»: closest «{pair}» {gap:.3f} em')
    if fix and need:
        cur = json.load(open(fix)) if os.path.exists(fix) else {}
        for sz, pairs in need.items():
            for p, v in pairs.items():
                cur.setdefault(sz, {})[p] = round(cur.get(sz, {}).get(p, 0) + v, 3)
        with open(fix, 'w') as fh:
            json.dump(cur, fh, ensure_ascii=False, indent=1)
        print(f'glyphs: wrote {sum(len(v) for v in need.values())} pair correction(s) to {fix} — rebuild the stage and run the gate again')
    return ok


def s08(lp, rp, y):
    a = np.asarray(Image.open(lp).convert('RGBA'), np.int16)
    b = np.asarray(Image.open(rp).convert('RGBA'), np.int16)
    k = a.shape[1] / 1920
    y0 = int(np.ceil(float(y) * k))
    d = np.abs(a[y0:] - b[y0:])
    ok = int(d.max()) == 0
    print(f'{"s08 ok" if ok else "S08 FAIL"}: the two pages below y = {y} differ by max {int(d.max())} ({int((d.max(-1) > 0).sum())} px)')
    return ok


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__ if __doc__ else 'see the head of this file')
        return 2
    cmd, rest = a[0], a[1:]
    def opt(k, dflt=None):
        if k in rest:
            i = rest.index(k)
            v = rest[i + 1]
            del rest[i:i + 2]
            return v
        return dflt
    if cmd == 'palette':
        dom = opt('--dom')
        ok = palette(rest, dom)
    elif cmd == 'plates':
        ok = plates(rest)
    elif cmd == 'flash':
        f0, f1 = opt('--from'), opt('--to')
        ok = flash(rest[0], int(f0) if f0 else None, int(f1) if f1 else None)
    elif cmd == 'glyphs':
        fx = opt('--fix')
        ok = glyphs(rest[0], fx)
    elif cmd == 's08':
        ok = s08(*rest[:3])
    else:
        print(f'gates: unknown gate {cmd}')
        return 2
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
