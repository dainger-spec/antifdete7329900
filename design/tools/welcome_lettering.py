#!/usr/bin/env python3
"""Lumen's welcome lettering: the launch screen's greetings in Pacifico, written as a pen writes them.

    python3 design/tools/welcome_lettering.py                  # writes both outputs below
    python3 design/tools/welcome_lettering.py --sheet out.svg  # every greeting: outline, centrelines, order

Needs fontTools, uharfbuzz, freetype-py, numpy, scipy, scikit-image and skan (pip install …). Run it
again after changing the font, a greeting or a constant here; the outputs are checked in.

The letters are the font's own: Pacifico (design/fonts/Pacifico, SIL Open Font License 1.1, its
licence beside it), shaped with HarfBuzz so its joins are the ones its designers drew, in Cyrillic
and Latin alike. What the screen shows is the font's outline exactly. What moves is a pen along the
letters' centrelines, revealing the outline under a round-capped stroke a little wider than the
font's: the centrelines come from the outline itself — rendered at 420 px a x-height, skeletonized,
traced into a graph (spurs dropped, a crossing's twin junctions merged), walked from the left with
the straightest continuation at each junction (a branch left behind is taken up from where it
starts, the leftmost first), smoothed, and fitted with Catmull-Rom cubics. Dots and accents are
written after their word.

The pen's pace: slow to start, faster along long strokes, slower in tight turns, gentle at the end
of each word; short pauses where it lifts, longer between words; 1.8–2.4 s a greeting.

Two outputs, from this one source:

* design/prototypes/welcome-lettering.js — for the prototype (design/prototypes/welcome.html) and
  the preview recordings (design/tools/record_welcome.mjs);
* Sources/PrivacyBrowser/UI/WelcomeLettering.swift — the same outlines, paths and timing for the app.

Units: the x-height is 1, y points down, x = 0 is the greeting's centre and y = 0 the baseline of
its last line.
"""
import json
import math
import os
import sys

import numpy as np
import uharfbuzz as hb
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.freetypePen import FreeTypePen
from fontTools.pens.basePen import BasePen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from scipy import ndimage
from skan import Skeleton
from skimage.morphology import skeletonize

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONT = os.path.join(ROOT, "design", "fonts", "Pacifico", "Pacifico-Regular.ttf")
JS_OUT = os.path.join(ROOT, "design", "prototypes", "welcome-lettering.js")
SWIFT_OUT = os.path.join(ROOT, "Sources", "PrivacyBrowser", "UI", "WelcomeLettering.swift")

RES = 420.0          # raster pixels per x-height, for the skeleton
LINE_GAP = 2.45      # baseline to baseline, x-heights
REVEAL = 1.22        # the reveal's width over the font's widest stroke

# The greetings, line by line, in the rotation's order. Each is the greeting itself in its language,
# never translated: it is what the screen draws.
GREETINGS = [
    ("ru", "добро пожаловать", [["добро"], ["пожаловать"]]),
    ("en", "welcome", [["welcome"]]),
    ("de", "willkommen", [["willkommen"]]),
    ("fr", "bienvenue", [["bienvenue"]]),
    ("es", "bienvenido", [["bienvenido"]]),
    ("it", "benvenuto", [["benvenuto"]]),
    ("pt", "bem-vindo", [["bem-vindo"]]),
    ("uk", "ласкаво просимо", [["ласкаво"], ["просимо"]]),
    ("pl", "witaj", [["witaj"]]),
    ("tr", "hoş geldiniz", [["hoş", "geldiniz"]]),
    ("nl", "welkom", [["welkom"]]),
    ("sv", "välkommen", [["välkommen"]]),
]


# MARK: - The font

class Font:
    def __init__(self, path):
        self.tt = TTFont(path)
        self.glyphs = self.tt.getGlyphSet()
        self.order = self.tt.getGlyphOrder()
        self.xh = float(self.tt["OS/2"].sxHeight)
        self.hb = hb.Font(hb.Face(hb.Blob.from_file_path(path)))

    def shape(self, text):
        """[(glyph name, x, y)] in font units, and the advance."""
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(self.hb, buf, {"kern": True, "liga": True, "calt": True})
        x = 0
        placed = []
        for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
            placed.append((self.order[info.codepoint], x + pos.x_offset, pos.y_offset))
            x += pos.x_advance
        return placed, x

    def draw(self, placed, pen):
        for name, x, y in placed:
            self.glyphs[name].draw(TransformPen(pen, (1, 0, 0, 1, x, y)))

    def bounds(self, placed):
        pen = BoundsPen(self.glyphs)
        self.draw(placed, pen)
        return pen.bounds


# MARK: - Centrelines

def raster(font, placed):
    """The word's outline as a mask at RES pixels a x-height (rows down), and the map from a pixel
    (row, col) back to font units."""
    x0, y0, x1, y1 = font.bounds(placed)
    scale = RES / font.xh
    margin = 12
    width = int(math.ceil((x1 - x0) * scale)) + 2 * margin
    height = int(math.ceil((y1 - y0) * scale)) + 2 * margin
    pen = FreeTypePen(font.glyphs)
    font.draw(placed, pen)
    dx, dy = -x0 * scale + margin, -y0 * scale + margin
    image = pen.array(width=width, height=height, transform=(scale, 0, 0, scale, dx, dy))

    def to_font(row, col):
        return ((col - dx) / scale, (height - row - dy) / scale)
    return image > 0.5, to_font


def chain_length(points):
    return float(np.sum(np.hypot(*np.diff(points, axis=0).T))) if len(points) > 1 else 0.0


class Graph:
    """The skeleton as nodes (endpoints, junctions) and edges (pixel chains between them)."""

    def __init__(self, mask, stroke):
        skeleton = Skeleton(skeletonize(mask))
        coords = skeleton.coordinates
        chains = [coords[path].astype(float) for path in skeleton.paths_list() if len(path) >= 2]
        # Node pixels: the ends of every chain, merged when within a third of a stroke (a junction is
        # several pixels; a crossing often two junctions a few pixels apart).
        parent = {}

        def find(a):
            while parent.setdefault(a, a) != a:
                parent[a] = parent[parent[a]]
                a = parent[a]
            return a

        tips = []
        for index, points in enumerate(chains):
            tips += [(index, 0, tuple(points[0])), (index, 1, tuple(points[-1]))]
        for i in range(len(tips)):
            for j in range(i + 1, len(tips)):
                a, b = tips[i][2], tips[j][2]
                if abs(a[0] - b[0]) + abs(a[1] - b[1]) <= stroke * 0.34:
                    ra, rb = find(a), find(b)
                    if ra != rb:
                        parent[ra] = rb
        node_of, members = {}, {}
        for index, end, point in tips:
            root = find(point)
            node_of[(index, end)] = root
            members.setdefault(root, []).append(point)
        self.nodes = {root: np.mean(points, axis=0) for root, points in members.items()}
        self.edges = []   # [node a, node b, points from a to b]
        for index, points in enumerate(chains):
            a, b = node_of[(index, 0)], node_of[(index, 1)]
            if a == b and chain_length(points) < stroke * 0.6:
                continue
            inner = points[1:-1] if len(points) > 2 else np.zeros((0, 2))
            self.edges.append([a, b, np.vstack([self.nodes[a], inner, self.nodes[b]])])
        self.stroke = stroke

    def degree(self, node):
        return sum((e[0] == node) + (e[1] == node) for e in self.edges)

    def prune(self, spur):
        """Drops spurs shorter than `spur` pixels (a stroke end's rounding, a corner's notch) and joins
        the chains that meet at a node left with two."""
        changed = True
        while changed:
            changed = False
            for edge in list(self.edges):
                a, b, points = edge
                if chain_length(points) >= spur:
                    continue
                da, db = self.degree(a), self.degree(b)
                if (da == 1 and db >= 3) or (db == 1 and da >= 3):
                    self.edges.remove(edge)
                    changed = True
            for node in list(self.nodes):
                touching = [e for e in self.edges if e[0] == node or e[1] == node]
                if len(touching) != 2 or touching[0][0] == touching[0][1] or touching[1][0] == touching[1][1]:
                    continue
                e1, e2 = touching
                p1, a = (e1[2], e1[0]) if e1[1] == node else (e1[2][::-1], e1[1])
                p2, b = (e2[2], e2[1]) if e2[0] == node else (e2[2][::-1], e2[0])
                self.edges.remove(e1)
                self.edges.remove(e2)
                self.edges.append([a, b, np.vstack([p1, p2[1:]])])
                del self.nodes[node]
                changed = True


def heading(points, at_start, reach):
    """The direction a chain leaves its start (or, `at_start` false, its end), over `reach` pixels."""
    if not at_start:
        points = points[::-1]
    lengths = np.cumsum(np.hypot(*np.diff(points, axis=0).T))
    k = min(max(int(np.searchsorted(lengths, reach)) + 1, 1), len(points) - 1)
    v = points[k] - points[0]
    n = float(np.hypot(*v))
    return v / n if n > 0 else np.array([0.0, 1.0])


def walk(graph):
    """The chains in writing order: [(points (row, col), continues)] — `continues` when the stroke
    starts where the pen already was (a branch left behind), so no lift shows.

    A part of the word starts at its leftmost point (an end there if there is one, a bowl's side
    otherwise, going down — anticlockwise round a bowl). At each junction the pen takes the
    straightest way on, but closes a loop first (a branch back to where it has been). When it can
    go no further it takes up the branch left behind at the junction it passed last."""
    unused = list(range(len(graph.edges)))
    visited = []          # nodes in the order the pen reached them
    strokes = []
    reach = graph.stroke * 0.9
    live = [k for k in graph.nodes if graph.degree(k) > 0]

    def edges_at(node):
        for i in unused:
            ea, eb, epoints = graph.edges[i]
            if ea == node:
                yield i, True, eb, epoints
            if eb == node:
                yield i, False, ea, epoints

    while unused:
        resumed = None
        for node in reversed(visited):
            options = list(edges_at(node))
            if options:
                resumed = node
                break
        if resumed is not None:
            # A branch left behind: the one going on most smoothly from the pen's last way there.
            options = list(edges_at(resumed))
            _, edge, forward = max((float(np.dot(heading(p, f, reach), [1.0, 0.4])), i, f) for i, f, _, p in options)
            continues = True
        else:
            # A new part: its leftmost node (an end, if one is near it).
            pending = {n for i in unused for n in graph.edges[i][:2]}
            nodes = [k for k in live if k in pending]
            left = min(graph.nodes[k][1] for k in nodes)
            near = [k for k in nodes if graph.nodes[k][1] - left < RES * 0.35]
            ends = [k for k in near if graph.degree(k) == 1]
            start = min(ends or near, key=lambda k: graph.nodes[k][1])
            # Down first, a little to the right: a bowl anticlockwise, a lead-in onward.
            _, edge, forward = max((float(np.dot(heading(p, f, reach), [1.0, 0.3])), i, f)
                                   for i, f, _, p in edges_at(start))
            continues = False
        path = []
        while edge is not None:
            a, b, points = graph.edges[edge]
            points = points if forward else points[::-1]
            start, end = (a, b) if forward else (b, a)
            for node in (start, end):
                if node in visited:
                    visited.remove(node)
                visited.append(node)
            unused.remove(edge)
            path.append(points if not path else points[1:])
            going = -heading(points, False, reach)
            best = None
            for i, f, other, epoints in edges_at(end):
                straight = float(np.dot(going, heading(epoints, f, reach)))
                if straight < -0.45:
                    continue
                closes = 0.6 if other in visited and other != end else 0.0
                score = straight + closes
                if best is None or score > best[0]:
                    best = (score, i, f)
            edge, forward = (best[1], best[2]) if best else (None, None)
        strokes.append((np.vstack(path), continues))
    return strokes


def smooth(points, sigma, spacing):
    """A chain smoothed (its ends kept) and resampled every `spacing` pixels."""
    if len(points) > 3:
        pad = 8
        padded = np.vstack([np.repeat(points[:1], pad, axis=0), points, np.repeat(points[-1:], pad, axis=0)])
        smoothed = ndimage.gaussian_filter1d(padded, sigma, axis=0, mode="nearest")[pad:-pad]
        smoothed[0], smoothed[-1] = points[0], points[-1]
    else:
        smoothed = points
    lengths = np.concatenate([[0], np.cumsum(np.hypot(*np.diff(smoothed, axis=0).T))])
    count = max(2, int(round(lengths[-1] / spacing)) + 1)
    at = np.linspace(0, lengths[-1], count)
    return np.stack([np.interp(at, lengths, smoothed[:, 0]), np.interp(at, lengths, smoothed[:, 1])], axis=1)


def catmull_rom(points):
    """Cubic segments through `points`, the ends' tangents their chords."""
    segments = []
    n = len(points)
    for i in range(n - 1):
        p0 = points[i - 1] if i > 0 else points[i]
        p1, p2 = points[i], points[i + 1]
        p3 = points[i + 2] if i + 2 < n else points[i + 1]
        segments.append((p1, p1 + (p2 - p0) / 6.0, p2 - (p3 - p1) / 6.0, p2))
    return segments


# MARK: - A greeting

class Stroke:
    def __init__(self, segments, kind, word, continues):
        self.segments = segments    # [(p0, c1, c2, p1)] in x-heights, y down
        self.kind = kind            # "main" or "mark"
        self.word = word
        self.continues = continues


def word_strokes(font, placed, baseline, word_index):
    """A word's strokes in writing order (its marks last), in x-heights, and its widest stroke."""
    mask, to_font = raster(font, placed)
    distance = ndimage.distance_transform_edt(mask)
    stroke = 2 * float(np.percentile(distance[skeletonize(mask)], 90))
    graph = Graph(mask, stroke)
    graph.prune(stroke * 0.75)
    labels, _ = ndimage.label(mask)
    main, marks = [], []
    for points, continues in walk(graph):
        label = labels[int(round(points[0][0])), int(round(points[0][1]))]
        rows, cols = np.nonzero(labels == label)
        # A mark: a part of the outline of its own, small (a dot, an accent).
        small = bool(label) and max(np.ptp(rows), np.ptp(cols)) < RES * 0.5
        resampled = smooth(points, sigma=RES * 0.03, spacing=RES * 0.05)
        font_points = np.array([to_font(r, c) for r, c in resampled])
        xy = np.stack([font_points[:, 0] / font.xh, baseline - font_points[:, 1] / font.xh], axis=1)
        (marks if small else main).append(Stroke(catmull_rom(xy), "mark" if small else "main", word_index,
                                                 continues and not small))
    return main + marks, stroke / RES


class PathDataPen(BasePen):
    """SVG path data with absolute M, L, Q, C and Z only (what the app's parser reads)."""

    def __init__(self, glyphs):
        super().__init__(glyphs)
        self.parts = []

    def _moveTo(self, p):
        self.parts.append("M %s %s" % (fmt(p[0]), fmt(p[1])))

    def _lineTo(self, p):
        self.parts.append("L %s %s" % (fmt(p[0]), fmt(p[1])))

    def _qCurveToOne(self, p1, p2):
        self.parts.append("Q %s %s %s %s" % (fmt(p1[0]), fmt(p1[1]), fmt(p2[0]), fmt(p2[1])))

    def _curveToOne(self, p1, p2, p3):
        self.parts.append("C " + " ".join(fmt(v) for p in (p1, p2, p3) for v in p))

    def _closePath(self):
        self.parts.append("Z")


def outline_path(font, placed, baseline):
    """The word's outline as path data, in x-heights, y down."""
    pen = PathDataPen(font.glyphs)
    s = 1.0 / font.xh
    font.draw(placed, TransformPen(pen, (s, 0, 0, -s, 0, baseline)))
    return " ".join(pen.parts)


def layout(font, lines):
    """A greeting's strokes and outline: lines stacked, each centred on x = 0, the last line's
    baseline at y = 0."""
    strokes, outlines = [], []
    space = font.shape(" ")[1]
    word_index = 0
    reveal = 0.0
    for line_number, words in enumerate(lines):
        baseline = -(len(lines) - 1 - line_number) * LINE_GAP
        shaped = [font.shape(word) for word in words]
        starts, x, whole = [], 0, []
        for placed, advance in shaped:
            starts.append(x)
            whole += [(n, gx + x, gy) for n, gx, gy in placed]
            x += advance + space
        x0, _, x1, _ = font.bounds(whole)
        shift = -(x0 + x1) / 2
        for (placed, _), start in zip(shaped, starts):
            moved = [(n, gx + start + shift, gy) for n, gx, gy in placed]
            word, stroke = word_strokes(font, moved, baseline, word_index)
            reveal = max(reveal, stroke)
            strokes += word
            outlines.append(outline_path(font, moved, baseline))
            word_index += 1
    return strokes, " ".join(outlines), reveal


# MARK: - The pen's pace

SAMPLES = 24
PAUSE_LIFT = 0.07     # the pen off the paper inside a word
PAUSE_ON = 0.015      # a branch taken up where the pen already was
PAUSE_WORD = 0.16     # between words
PAUSE_MARK = 0.05     # before each dot or accent
MIN_SPEED = 0.25


def point_at(seg, t):
    p0, c1, c2, p1 = seg
    u = 1 - t
    return u * u * u * p0 + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * p1


def derivative(seg, t):
    p0, c1, c2, p1 = seg
    u = 1 - t
    d1 = 3 * u * u * (c1 - p0) + 6 * u * t * (c2 - c1) + 3 * t * t * (p1 - c2)
    d2 = 6 * u * (c2 - 2 * c1 + p0) + 6 * t * (p1 - 2 * c2 + c1)
    return d1, d2


def pace(strokes, letters):
    """Times each stroke: [(t0, t1, [pen position every 1/120 s])] and the total duration. The pen
    position is a segment's index plus how far along it."""
    profiles = []
    for stroke in strokes:
        rows, total = [], 0.0
        for index, seg in enumerate(stroke.segments):
            previous = point_at(seg, 0)
            for step in range(SAMPLES + 1):
                t = step / SAMPLES
                point = point_at(seg, t)
                if step:
                    total += float(np.hypot(*(point - previous)))
                previous = point
                d1, d2 = derivative(seg, t)
                speed = float(np.hypot(*d1))
                curvature = abs(d1[0] * d2[1] - d1[1] * d2[0]) / max(speed ** 3, 1e-9)
                radius = 1 / max(curvature, 1e-6)
                rows.append([total, index, t, math.sqrt(radius / (radius + 0.3))])
        profiles.append((rows, total))
    # The word's envelope: slow to start, gentle at its end; a stroke's own ends ease too.
    word_ink = {}
    for stroke, (_, total) in zip(strokes, profiles):
        if stroke.kind == "main":
            word_ink[stroke.word] = word_ink.get(stroke.word, 0.0) + total
    done = {}
    for stroke, (rows, total) in zip(strokes, profiles):
        before = done.get(stroke.word, 0.0)
        whole = max(word_ink.get(stroke.word, total), 1e-6)
        for row in rows:
            u = (before + row[0]) / whole if stroke.kind == "main" else 0.5
            start = 0.4 + 0.6 * min(1.0, u / 0.14)
            end = 0.55 + 0.45 * min(1.0, (1 - u) / 0.12)
            near = min(row[0], total - row[0])
            ease = 1.0 if stroke.continues and row[0] < total / 2 else 0.45 + 0.55 * min(1.0, near / 0.25)
            row[3] = max(MIN_SPEED, row[3] * start * end * ease)
        if stroke.kind == "main":
            done[stroke.word] = before + total
    raw = []
    for rows, _ in profiles:
        times = [0.0]
        for a, b in zip(rows, rows[1:]):
            times.append(times[-1] + (b[0] - a[0]) / ((a[3] + b[3]) / 2))
        raw.append(times)
    ink = sum(times[-1] for times in raw)
    pauses, previous = [], None
    for stroke in strokes:
        if previous is None:
            pause = 0.0
        elif stroke.kind == "mark":
            pause = PAUSE_MARK + (0.05 if previous.kind == "main" else 0.0)
        elif stroke.word != previous.word:
            pause = PAUSE_WORD
        else:
            pause = PAUSE_ON if stroke.continues else PAUSE_LIFT
        pauses.append(pause)
        previous = stroke
    duration = min(2.4, max(1.8, 1.45 + 0.06 * letters))
    scale = (duration - sum(pauses)) / ink
    timed, clock = [], 0.0
    for stroke, (rows, _), times, pause in zip(strokes, profiles, raw, pauses):
        clock += pause
        t0, t1 = clock, clock + times[-1] * scale
        steps = max(1, int(math.ceil((t1 - t0) * 120)))
        samples, j = [], 0
        for step in range(steps + 1):
            local = (step / steps) * times[-1]
            while j + 1 < len(times) - 1 and times[j + 1] < local:
                j += 1
            a, b = rows[j], rows[min(j + 1, len(rows) - 1)]
            ta, tb = times[j], times[min(j + 1, len(times) - 1)]
            f = 0.0 if tb <= ta else (local - ta) / (tb - ta)
            samples.append((a[1] + a[2]) + ((b[1] + b[2]) - (a[1] + a[2])) * f)
        samples[-1] = float(len(stroke.segments))
        timed.append((t0, t1, samples))
        clock = t1
    return timed, clock


# MARK: - Output

def fmt(v):
    text = ("%.4f" % v).rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text


def greeting_data(font, code, text, lines):
    strokes, outline, reveal = layout(font, lines)
    letters = sum(len(word) for line in lines for word in line)
    timed, duration = pace(strokes, letters)
    out = []
    for stroke, (t0, t1, samples) in zip(strokes, timed):
        parts = ["M %s %s" % (fmt(stroke.segments[0][0][0]), fmt(stroke.segments[0][0][1]))]
        for seg in stroke.segments:
            parts.append("C " + " ".join(fmt(v) for p in seg[1:] for v in p))
        out.append(dict(kind=stroke.kind, t0=round(t0, 4), t1=round(t1, 4), d=" ".join(parts),
                        p=" ".join("%.3f" % s for s in samples)))
    numbers = [float(v) for v in outline.split() if v not in ("M", "L", "Q", "C", "Z")]
    xs, ys = numbers[0::2], numbers[1::2]
    return dict(code=code, text=text, lines=[" ".join(line) for line in lines], duration=round(duration, 4),
                bounds=[round(min(xs), 4), round(min(ys), 4), round(max(xs), 4), round(max(ys), 4)],
                lineCount=len(lines), reveal=round(reveal * REVEAL, 4), outline=outline, strokes=out)


FONT_NOTICE = ("Pacifico, Copyright 2018 The Pacifico Project Authors (https://github.com/googlefonts/Pacifico), "
               "licensed under the SIL Open Font License 1.1 (design/fonts/Pacifico/OFL.txt)")


def write_js(data):
    with open(JS_OUT, "w", encoding="utf-8") as handle:
        handle.write("// Generated by design/tools/welcome_lettering.py — do not edit.\n")
        handle.write("// The lettering: %s.\n" % FONT_NOTICE)
        handle.write("window.WELCOME_LETTERING = ")
        json.dump(data, handle, ensure_ascii=False, indent=1)
        handle.write(";\n")


def swift_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_swift(data):
    lines = [
        "// Generated by design/tools/welcome_lettering.py — do not edit; change the script and run it again.",
        "//",
        "// The launch screen's greetings in Pacifico, Copyright 2018 The Pacifico Project Authors",
        "// (https://github.com/googlefonts/Pacifico), licensed under the SIL Open Font License 1.1: its text",
        "// is design/fonts/Pacifico/OFL.txt. The outlines are the font's glyphs as HarfBuzz shapes them;",
        "// the strokes are the pen's way along them (centrelines from the outline's skeleton, in cubic",
        "// Béziers: \"M x y C x1 y1 x2 y2 x y …\") with where the pen is every 1/120 s of a stroke. Units:",
        "// the x-height is 1, y points down, x = 0 is the greeting's centre and y = 0 its last baseline.",
        "",
        "import CoreGraphics",
        "",
        "extension WelcomeLettering {",
        "    /// Every greeting, of which the app writes the English one (WelcomeSplashPolicy.greetingLanguage).",
        "    /// Each is the greeting itself in its own language: never translated.",
        "    static let all: [WelcomeLettering] = [",
    ]
    for greeting in data:
        b = greeting["bounds"]
        lines += [
            "        WelcomeLettering(",
            "            code: %s, text: %s, // l10n: not text" % (swift_string(greeting["code"]), swift_string(greeting["text"])),
            "            duration: %s, lineCount: %d, reveal: %s," % (repr(greeting["duration"]), greeting["lineCount"],
                                                                 repr(greeting["reveal"])),
            "            bounds: CGRect(x: %.4f, y: %.4f, width: %.4f, height: %.4f)," % (b[0], b[1], b[2] - b[0], b[3] - b[1]),
            "            outline: %s," % swift_string(greeting["outline"]),
            "            strokes: [",
        ]
        for stroke in greeting["strokes"]:
            lines.append("                .init(mark: %s, start: %s, end: %s," % (
                "true" if stroke["kind"] == "mark" else "false", repr(stroke["t0"]), repr(stroke["t1"])))
            lines.append("                      path: %s," % swift_string(stroke["d"]))
            lines.append("                      pen: %s)," % swift_string(stroke["p"]))
        lines.append("            ]),")
    lines += ["    ]", "}"]
    with open(SWIFT_OUT, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


# MARK: - The sheet

def sheet(font, path):
    """Every greeting: the outline, its centrelines coloured by writing order (a dot where each
    starts), and the reveal's width."""
    parts, y, width = [], 40, 1800
    palette = ["#ff6b6b", "#ffa94d", "#ffd43b", "#69db7c", "#38d9a9", "#4dabf7", "#9775fa", "#f783ac"]
    for code, text, lines in GREETINGS:
        data = greeting_data(font, code, text, lines)
        b = data["bounds"]
        scale = min(110.0, (width - 80) / (b[2] - b[0]))
        h = (b[3] - b[1]) * scale + 60
        g = ['<g transform="translate(%.1f %.1f) scale(%.3f)">' % (width / 2, y + 30 - b[1] * scale, scale)]
        g.append('<path d="%s" fill="#3a3f4a"/>' % data["outline"])
        for i, s in enumerate(data["strokes"]):
            color = palette[i % len(palette)]
            g.append('<path d="%s" fill="none" stroke="%s" stroke-width="%.4f" stroke-linecap="round" opacity="0.9"/>'
                     % (s["d"], color, 3 / scale))
            first = s["d"].split()[1:3]
            g.append('<circle cx="%s" cy="%s" r="%.4f" fill="%s"/>' % (first[0], first[1], 5 / scale, color))
        g.append("</g>")
        g.append('<text x="20" y="%.1f" fill="#888" font-size="13" font-family="Inter">%s · %d strokes · %.2f s</text>'
                 % (y + 14, code, len(data["strokes"]), data["duration"]))
        parts.append("\n".join(g))
        y += h + 20
    with open(path, "w", encoding="utf-8") as handle:
        handle.write('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">' % (width, y + 20))
        handle.write('<rect width="100%" height="100%" fill="#0b0c0f"/>')
        handle.write("\n".join(parts))
        handle.write("</svg>\n")


def main(argv):
    font = Font(FONT)
    if len(argv) > 2 and argv[1] == "--sheet":
        sheet(font, argv[2])
        return 0
    data = [greeting_data(font, code, text, lines) for code, text, lines in GREETINGS]
    write_js(data)
    write_swift(data)
    for greeting in data:
        print("%s: %d strokes, %.2f s, reveal %.3f" % (greeting["code"], len(greeting["strokes"]), greeting["duration"],
                                                     greeting["reveal"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
