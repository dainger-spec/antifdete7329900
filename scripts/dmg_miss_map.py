#!/usr/bin/env python3
"""Measurement (never merged): where the points dmg_background_check.py finds not the picture's lie,
and what they are. Lays the picture where the check lays it, then prints, for the backdrop and for
the features, the misses by band of 8 points of the window's height (counting from the window's
frame top) and the colours seen at them; for the features, how many lie on an edge of the 1x
picture (a neighbour 1 point away differs by more than the tolerance) and how many inside.

    python3 scripts/dmg_miss_map.py --shot X.png --geometry X.json --picture picture.png [--picture2x page2.png]
"""
import argparse, json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dmg_background_check as c


def lay(shot, plain, features, scale, frame_x, frame_y, ww, wh):
    best = (-1.0, frame_x, frame_y)
    for dy in range(frame_y, frame_y + 81):
        for dx in range(frame_x, frame_x + 9):
            fit = min(c.share(c.score(shot, plain[::3], scale, dx, dy, ww, wh)),
                      c.share(c.score(shot, features[::4], scale, dx, dy, ww, wh)))
            if fit > best[0]:
                best = (fit, dx, dy)
    return best[1], best[2]


def misses(shot, sample, scale, dx, dy, ww, wh):
    out = []
    for x, y, wanted in sample:
        if dy + y > wh - 4 or dx + x > ww - 4:
            continue
        sx, sy = int((dx + x) * scale), int((dy + y) * scale)
        if sx >= shot[0] or sy >= shot[1]:
            continue
        seen = shot[2][sy][sx]
        if max(abs(seen[i] - wanted[i]) for i in range(3)) > c.TOLERANCE:
            out.append((x, y, wanted, seen))
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--shot", required=True); p.add_argument("--geometry", required=True)
    p.add_argument("--picture", required=True); p.add_argument("--picture2x")
    a = p.parse_args()
    shot = c.read_png(a.shot)
    g = json.load(open(a.geometry))
    left, top, right, bottom = g["bounds"]; cx, cy, cw, _ = g["capture"]
    scale = shot[0] / cw
    picture = c.read_png(a.picture)
    if picture[0] >= 2 * (right - left) - 2:
        picture = (picture[0] // 2, picture[1] // 2, [row[::2] for row in picture[2][::2]])
    fx, fy, ww, wh = left - cx, top - cy, right - cx, bottom - cy
    backdrop, plain, features = c.points(picture)
    dx, dy = lay(shot, plain, features, scale, fx, fy, ww, wh)
    print(f"miss map: capture {shot[0]}x{shot[1]} at {scale:g}x, window {right - left}x{bottom - top} pt, picture laid {dx - fx}, {dy - fy} into the frame")
    rows = picture[2]
    def edge(x, y):
        here = rows[y][x]
        return any(max(abs(rows[y + j][x + i][k] - here[k]) for k in range(3)) > c.TOLERANCE
                   for i, j in ((1, 0), (-1, 0), (0, 1), (0, -1)))
    for name, sample in (("backdrop", plain), ("features", features)):
        found = misses(shot, sample, scale, dx, dy, ww, wh)
        compared = c.score(shot, sample, scale, dx, dy, ww, wh)[1]
        print(f"miss map: {name}: {len(found)} of {compared} points not the picture's")
        bands = {}
        for x, y, wanted, seen in found:
            band = (dy - fy + y) // 8 * 8
            bands.setdefault(band, []).append((x, seen))
        for band in sorted(bands):
            entries = bands[band]
            colours = {}
            for _, seen in entries:
                colours[seen] = colours.get(seen, 0) + 1
            top3 = sorted(colours.items(), key=lambda e: -e[1])[:3]
            xs = [x for x, _ in entries]
            print(f"miss map:   {name} window y {band:3}-{band + 7:3} pt: {len(entries):4} misses, x {min(xs)}..{max(xs)}, seen {top3}")
        if name == "features":
            on_edge = sum(1 for x, y, _, _ in found if edge(x, y))
            print(f"miss map: features: {on_edge} of the {len(found)} misses lie on an edge of the 1x picture, {len(found) - on_edge} inside")
    if a.picture2x:
        p2 = c.read_png(a.picture2x)
        ok = n = 0
        for x, y, _ in features:
            if dy + y > wh - 4 or dx + x > ww - 4:
                continue
            sx, sy = int((dx + x) * scale), int((dy + y) * scale)
            if sx >= shot[0] or sy >= shot[1]:
                continue
            want = p2[2][int(y * scale)][int(x * scale)]
            seen = shot[2][sy][sx]
            n += 1
            ok += max(abs(seen[i] - want[i]) for i in range(3)) <= c.TOLERANCE
        print(f"miss map: features against the picture's {scale:g}x page: {ok} of {n}")


if __name__ == "__main__":
    main()
