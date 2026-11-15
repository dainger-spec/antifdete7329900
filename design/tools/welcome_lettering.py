#!/usr/bin/env python3
"""Lumen's welcome lettering: the greetings of the launch screen, as a pen writes them.

    python3 design/tools/welcome_lettering.py            # writes both outputs below
    python3 design/tools/welcome_lettering.py --sheet out.svg   # every glyph and word, with knots

The letters are Lumen's own: a monoline upright cursive drawn here as the centreline the pen
follows, not taken from any font. Each glyph is a few knots — points the pen passes through, some
with the direction it moves in, some a cusp where it turns back — and the curves between them are
cubic Béziers whose handles make circular arcs where they can (round letters stay round). A word
is its glyphs joined: the pen leaves one letter in the direction it was going and arrives at the
next one's entry, so the joins are curves of the same family. Dots, crossbars and accents are
written after their word, as a hand writes them.

The pen's pace is modelled too: faster on long, nearly straight strokes (the joins), slower in
tight turns, easing into and out of cusps and stroke ends, with short pauses where the pen lifts and
a longer one between words. Each greeting takes 1.6–2.2 s, longer for longer words.

Two outputs, from this one source:

* design/prototypes/welcome-lettering.js — for the HTML prototype (design/prototypes/welcome.html)
  and the preview recordings (design/tools/record_welcome.mjs);
* Sources/PrivacyBrowser/UI/WelcomeLettering.swift — the same paths and timing for the app
  (WelcomeSplash.swift draws them).

Units: the x-height is 1, y points down (as SwiftUI and SVG draw), x = 0 is the greeting's centre
and y = 0 the baseline of its last line.
"""
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
JS_OUT = os.path.join(ROOT, "design", "prototypes", "welcome-lettering.js")
SWIFT_OUT = os.path.join(ROOT, "Sources", "PrivacyBrowser", "UI", "WelcomeLettering.swift")

XH = 100.0           # x-height in design units (glyphs are drawn in these, y up)
SLANT = math.radians(10)  # the hand's slant, applied to the upright design
WIDEN = 1.22         # the letters' width, applied to the upright design (round, as in the owner's mock)
LINE_GAP = 236.0     # baseline to baseline, design units
WORD_GAP = 46.0      # between words on one line
JOIN_GAP = 16.0      # the least run of a join between letters
JOIN_SLOPE = 0.3     # and how much more for each unit it rises or falls
CLEARANCE = 12.0     # a letter's body stays this far right of the exit before it
LIFT_GAP = 14.0      # after a letter the pen leaves the paper at


# MARK: - Glyphs
#
# A knot is (x, y), (x, y, dir), (x, y, 'c') or (x, y, dir_in, dir_out):
#   dir      the direction the pen moves in there, in degrees (0 right, 90 up, 180 left, 270 down);
#   'c'      a cusp — the pen turns back; the directions either side come from the neighbours;
#   in, out  a cusp with its directions given (either may be None).
# `main` is the stroke the letter is written in; its first knot is where the pen arrives from the
# letter before (the join comes in with that knot's direction), its last where it leaves for the
# next. `lead` is put before the first knot when the letter begins a word. `lift_after`: the pen
# leaves the paper after this letter (the next one starts a stroke of its own, after `body`, the
# right of the letter's body — a flourish may stand over the next letter). `strokes`: further
# strokes written right after `main`, each a stroke of its own. `marks`: written after the word.

def bowl(*rest):
    """The round letters' bowl (o, a, d, g, д, б): from its top right — where the join from the letter
    before arrives and turns back over the top — anticlockwise round to its right side."""
    return [(52, 94, None, 165), (33, 100, 180), (2, 52, 270), (32, 0, 0)] + list(rest)


LOOP = [(4, 32, 38), (34, 108, 72), (40, 156, 95), (28, 172, 180), (16, 152, 262)]   # l, b, h, k
STEM_IN = (12, 97, 74, 268)
OVER = [(20, 98, 8)]          # a join into a bowl comes over its top, left to right, before turning back   # the up-stroke's cusp at the top of a stem (i, n, m, u, …)
EXIT = [(70, 0, 0), (84, 22, 50)]

GLYPHS = {
    "o": dict(main=bowl((63, 46, 90), (52, 95, 125, 2), (72, 94, 356)), approach=OVER),
    "a": dict(main=bowl((58, 28, 60), (63, 99, 85, 270), (63, 18, 270), (74, 0, 0), (87, 24, 55)), approach=OVER),
    "d": dict(main=bowl((58, 28, 60), (66, 168, 84, 270), (64, 18, 270), (75, 0, 0), (88, 24, 55)), approach=OVER),
    "g": dict(main=bowl((58, 28, 60), (63, 99, 85, 270), (62, -40, 270), (47, -84, 180), (35, -62, 70),
                        (73, 6, 40), (85, 20, 45)), approach=OVER),
    "c": dict(main=[(50, 92, None, 165), (33, 100, 180), (3, 52, 270), (32, 0, 0), (60, 22, 45)], approach=OVER),
    "e": dict(main=[(2, 34, 25), (44, 64, 72), (30, 100, 180), (4, 56, 266), (28, 0, 0), (56, 22, 45)]),
    "l": dict(main=LOOP + [(14, 22, 274), (28, 0, 0), (50, 22, 48)]),
    "i": dict(main=[STEM_IN, (14, 18, 270), (26, 0, 0), (42, 22, 50)],
              lead=[(-4, 44)], marks=[[(15, 140), (17, 143)]]),
    "j": dict(main=[STEM_IN, (15, -40, 270), (2, -84, 180), (-8, -62, 72), (28, 8, 42), (44, 22, 45)],
              lead=[(-4, 44)], marks=[[(15, 140), (17, 143)]]),
    "t": dict(main=[(18, 150, 78, 268), (17, 18, 270), (29, 0, 0), (45, 22, 50)],
              lead=[(-2, 60)], marks=[[(-2, 100), (40, 103)]]),
    "n": dict(main=[STEM_IN, (12, 2, 270, 84), (14, 56, 82), (34, 99, 0), (55, 70, 280), (56, 18, 270),
                    (68, 0, 0), (82, 22, 50)], lead=[(-4, 46)]),
    "m": dict(main=[STEM_IN, (12, 2, 270, 84), (14, 56, 82), (30, 99, 0), (46, 72, 278), (47, 2, 270, 84),
                    (49, 56, 82), (65, 99, 0), (82, 70, 280), (83, 18, 270), (95, 0, 0), (109, 22, 50)],
              lead=[(-4, 46)]),
    "u": dict(main=[(10, 97, 70, 270), (12, 28, 274), (30, 0, 0), (52, 40, 76), (56, 98, 86, 270),
                    (56, 18, 270), (68, 0, 0), (82, 22, 50)], lead=[(-6, 46)]),
    "v": dict(main=[(10, 97, 70, 270), (13, 30, 280), (30, 0, 0), (52, 32, 66), (59, 92, 96, 4), (78, 93, 0)],
              lead=[(-6, 46)]),
    "w": dict(main=[(10, 97, 70, 270), (12, 28, 275), (26, 0, 0), (42, 34, 80), (44, 90, 88, 268),
                    (46, 28, 275), (60, 0, 0), (76, 32, 66), (83, 92, 96, 4), (102, 93, 0)], lead=[(-6, 46)]),
    "b": dict(main=LOOP + [(14, 22, 274), (32, 0, 0), (56, 36, 90), (38, 68, 170, 8), (62, 72, 0)]),
    "h": dict(main=LOOP + [(14, 2, 272, 82), (16, 56, 82), (36, 99, 0), (57, 70, 280), (58, 18, 270),
                           (70, 0, 0), (84, 22, 50)]),
    "k": dict(main=LOOP + [(14, 2, 272, 80), (18, 52, 72), (40, 96, 20), (50, 80, 280), (26, 50, 215, 318),
                           (46, 10, 300), (60, 0, 0), (76, 22, 50)]),
    "s": dict(main=[(26, 100, None, 298), (44, 52, 274), (38, 10, 235), (22, 0, 180), (6, 14, 125, 340),
                    (32, 6, 8), (56, 22, 45)], lead=[(4, 46)]),
    "z": dict(main=[(4, 86, 40), (26, 99, 0), (46, 94, 345, 226), (10, 4, 226, 0), (44, 0, 0), (62, 22, 50)]),
    "-": dict(main=[(4, 52), (40, 54)], alone=True),
    # Cyrillic of their own (а о р с и п т are drawn as a o p c u n m).
    "д": dict(main=bowl((58, 28, 60), (66, 110, 86), (60, 158, 115), (42, 170, 185), (28, 158, 240)),
              lift_after=True, approach=OVER, body=68),
    "б": dict(main=bowl((62, 46, 88), (68, 108, 70), (86, 146, 42), (110, 160, 8), (128, 156, 340)), lift_after=True,
              approach=OVER, body=66),
    "р": dict(main=[STEM_IN, (12, -70, 270, 90), (13, 52, 86), (36, 99, 0), (58, 52, 270), (38, 2, 185),
                    (16, 16, 120, 350), (42, 10, 15), (60, 22, 45)], lead=[(-4, 46)]),
    "в": dict(main=[(4, 32, 38), (32, 100, 72), (38, 142, 95), (26, 158, 180), (15, 140, 262), (14, 22, 274),
                    (32, 0, 0), (56, 36, 90), (38, 68, 170, 8), (62, 72, 0)]),
    "ж": dict(main=[(0, 90, None, 340), (24, 70, 300), (32, 50, 270), (24, 26, 240), (2, 6, 210)],
              strokes=[[(48, 100, 270), (48, 2, 270)],
                       [(96, 92, 200), (70, 72, 240), (62, 50, 270), (70, 24, 300), (92, 4, 340), (104, 18, 50)]]),
    "л": dict(main=[(0, 6, None, 62), (20, 42, 64), (36, 99, 78, 274), (40, 18, 272), (52, 0, 0), (66, 22, 50)],
              lead=[(-12, 16)]),
    "м": dict(main=[(0, 6, None, 62), (18, 42, 64), (32, 99, 78, 274), (34, 2, 270, 66), (46, 48, 60),
                    (60, 99, 74, 274), (63, 18, 272), (75, 0, 0), (89, 22, 50)], lead=[(-12, 16)]),
    "к": dict(main=[STEM_IN, (12, 2, 270, 82), (15, 50, 72), (40, 96, 30), (50, 82, 280), (26, 50, 215, 320),
                    (46, 10, 300), (60, 0, 0), (76, 22, 50)], lead=[(-6, 46)]),
    "ь": dict(main=[STEM_IN, (12, 12, 270), (30, 0, 0), (56, 26, 90), (36, 52, 180), (16, 42, 240)],
              lead=[(-4, 46)]),
}
ALIASES = {"а": "a", "о": "o", "с": "c", "и": "u", "п": "n", "т": "m", "е": "e"}
# Letters with marks: the base letter and the marks added (written after the word).
MARKED = {
    "ş": ("s", [[(30, -8), (34, -22, 260), (22, -32, 180)]]),
    "ä": ("a", [[(18, 140), (20, 143)], [(46, 140), (48, 143)]]),
}

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


# MARK: - Geometry

def unit(dx, dy):
    length = math.hypot(dx, dy)
    return (dx / length, dy / length) if length > 1e-9 else (1.0, 0.0)


def direction(degrees):
    return (math.cos(math.radians(degrees)), math.sin(math.radians(degrees)))


def shear(point):
    x, y = point
    return (x * WIDEN + y * math.tan(SLANT), y)


def shear_dir(vector):
    if vector is None:
        return None
    return unit(vector[0] * WIDEN + vector[1] * math.tan(SLANT), vector[1])


class Knot:
    def __init__(self, spec, dx=0.0):
        x, y = spec[0] + dx, spec[1]
        self.p = shear((x, y))
        self.tin = self.tout = None
        self.corner = False
        if len(spec) == 3 and spec[2] == "c":
            self.corner = True
        elif len(spec) == 3:
            self.tin = self.tout = shear_dir(direction(spec[2]))
        elif len(spec) == 4:
            self.corner = True
            self.tin = shear_dir(direction(spec[2])) if spec[2] is not None else None
            self.tout = shear_dir(direction(spec[3])) if spec[3] is not None else None


def circle_tangent(a, b, c):
    """The tangent at b of the circle through a, b, c, pointing from a's side to c's."""
    ax, ay = a[0] - b[0], a[1] - b[1]
    cx, cy = c[0] - b[0], c[1] - b[1]
    la, lc = ax * ax + ay * ay, cx * cx + cy * cy
    tx, ty = cx * la - ax * lc, cy * la - ay * lc
    if math.hypot(tx, ty) < 1e-9:
        return unit(c[0] - a[0], c[1] - a[1])
    return unit(tx, ty)


def end_tangent(a, b, c):
    """The tangent at a of the circle through a, b, c, pointing toward b."""
    bx, by = b[0] - a[0], b[1] - a[1]
    cx, cy = c[0] - a[0], c[1] - a[1]
    lb, lc = bx * bx + by * by, cx * cx + cy * cy
    tx, ty = bx * lc - cx * lb, by * lc - cy * lb
    if math.hypot(tx, ty) < 1e-9:
        return unit(bx, by)
    t = unit(tx, ty)
    return t if t[0] * bx + t[1] * by > 0 else (-t[0], -t[1])


def tangents(knots):
    points = [k.p for k in knots]
    n = len(points)
    result = []
    for i, k in enumerate(knots):
        def forward():
            if i + 2 < n:
                return end_tangent(points[i], points[i + 1], points[i + 2])
            return unit(points[i + 1][0] - points[i][0], points[i + 1][1] - points[i][1])

        def backward():
            if i >= 2:
                t = end_tangent(points[i], points[i - 1], points[i - 2])
            else:
                t = unit(points[i - 1][0] - points[i][0], points[i - 1][1] - points[i][1])
            return (-t[0], -t[1])

        if i == 0:
            tin = tout = k.tout or forward()
        elif i == n - 1:
            tin = tout = k.tin or backward()
        elif k.corner:
            tin = k.tin or backward()
            tout = k.tout or forward()
        else:
            tin = tout = k.tin or circle_tangent(points[i - 1], points[i], points[i + 1])
        result.append((tin, tout))
    return result


def handle(chord, tangent, length):
    cos = max(-1.0, min(1.0, (chord[0] * tangent[0] + chord[1] * tangent[1])))
    alpha = math.acos(cos)
    if alpha < 1e-3:
        k = 1 / 3
    else:
        alpha = min(alpha, math.radians(110))
        k = (2 / 3) * math.tan(alpha / 2) / math.sin(alpha)
    return length * min(k, 0.95)


def beziers(knots):
    """The stroke's cubic segments: [(p0, c1, c2, p1)]."""
    ts = tangents(knots)
    segments = []
    for i in range(len(knots) - 1):
        p0, p1 = knots[i].p, knots[i + 1].p
        t0, t1 = ts[i][1], ts[i + 1][0]
        length = math.hypot(p1[0] - p0[0], p1[1] - p0[1])
        chord = unit(p1[0] - p0[0], p1[1] - p0[1])
        h0, h1 = handle(chord, t0, length), handle(chord, t1, length)
        c1 = (p0[0] + t0[0] * h0, p0[1] + t0[1] * h0)
        c2 = (p1[0] - t1[0] * h1, p1[1] - t1[1] * h1)
        segments.append((p0, c1, c2, p1))
    return segments


def point_at(seg, t):
    p0, c1, c2, p1 = seg
    u = 1 - t
    return (u * u * u * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * p1[0],
            u * u * u * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * p1[1])


def derivative(seg, t):
    p0, c1, c2, p1 = seg
    u = 1 - t
    d1 = [3 * u * u * (c1[k] - p0[k]) + 6 * u * t * (c2[k] - c1[k]) + 3 * t * t * (p1[k] - c2[k]) for k in (0, 1)]
    d2 = [6 * u * (c2[k] - 2 * c1[k] + p0[k]) + 6 * t * (p1[k] - 2 * c2[k] + c1[k]) for k in (0, 1)]
    return d1, d2


# MARK: - Words

class Stroke:
    def __init__(self, knots, kind):
        self.knots = knots      # [Knot]
        self.kind = kind        # "main" or "mark"
        self.segments = []
        self.word = 0
        self.lift_before = 0.0  # seconds the pen is off the paper before this stroke


def glyph_for(letter):
    if letter in MARKED:
        base, marks = MARKED[letter]
        glyph = dict(GLYPHS[ALIASES.get(base, base)])
        glyph["marks"] = list(glyph.get("marks", [])) + marks
        return glyph
    return GLYPHS[ALIASES.get(letter, letter)]


def join_offset(previous_exit, glyph):
    """Where a glyph goes after a letter that left at `previous_exit` (design units): its entry far
    enough on for the join to rise or fall at the hand's slope, and its body clear of the exit."""
    entry = glyph["main"][0]
    left = min(k[0] for k in glyph["main"] + glyph.get("approach", []))
    if "approach" in glyph:
        entry = glyph["approach"][0]
    rise = abs(entry[1] - previous_exit[1])
    by_entry = previous_exit[0] + JOIN_GAP + JOIN_SLOPE * rise - entry[0]
    by_body = previous_exit[0] + CLEARANCE - left
    return max(by_entry, by_body)


def layout_word(word, x0, y0):
    """The word's strokes (main strokes in writing order, then its marks) and its right edge."""
    strokes, marks = [], []
    current = None
    x = x0
    right = x0
    previous_exit = None
    for index, letter in enumerate(word):
        glyph = glyph_for(letter)
        alone = glyph.get("alone", False)
        if previous_exit is not None:
            x = join_offset(previous_exit, glyph)
        main = [Knot((kx, ky + y0) + tuple(rest), dx=x) for (kx, ky, *rest) in glyph["main"]]
        if current is not None and not alone and "approach" in glyph:
            main = [Knot((kx, ky + y0) + tuple(rest), dx=x) for (kx, ky, *rest) in glyph["approach"]] + main
        if current is None and "lead" in glyph:
            main = [Knot((lx, ly + y0), dx=x) for (lx, ly) in glyph["lead"]] + main
        if current is None and glyph.get("first_out") is not None:
            main[0].tout = shear_dir(direction(glyph["first_out"]))
        if alone or current is None:
            current = Stroke(main, "main")
            strokes.append(current)
        else:
            current.knots.extend(main)
        for extra in glyph.get("strokes", []):
            current = Stroke([Knot((kx, ky + y0) + tuple(rest), dx=x) for (kx, ky, *rest) in extra], "main")
            strokes.append(current)
        for mark in glyph.get("marks", []):
            marks.append(Stroke([Knot((kx, ky + y0) + tuple(rest), dx=x) for (kx, ky, *rest) in mark], "mark"))
        last = (glyph.get("strokes") or [glyph["main"]])[-1][-1]
        previous_exit = (last[0] + x, last[1])
        right = max(right, x + max(k[0] for k in glyph["main"]), previous_exit[0])
        if alone or glyph.get("lift_after"):
            current = None
            widest = glyph.get("body", max(k[0] for k in glyph["main"] + [k for extra in glyph.get("strokes", []) for k in extra]))
            previous_exit = (x + widest + LIFT_GAP, 40)
    return strokes + marks, right


def layout(lines):
    """Every stroke of a greeting: lines stacked, each centred on x = 0 by what it draws, the last
    line's baseline at y = 0 (design units, y up)."""
    all_strokes = []
    word_index = 0
    count = len(lines)
    for line_number, words in enumerate(lines):
        y0 = (count - 1 - line_number) * LINE_GAP
        line = []
        x = 0.0
        for word in words:
            strokes, right = layout_word(word, x, y0)
            for stroke in strokes:
                stroke.word = word_index
                stroke.segments = beziers(stroke.knots)
            line.extend(strokes)
            word_index += 1
            x = right + WORD_GAP
        xs = [point_at(seg, t / 8)[0] for stroke in line for seg in stroke.segments for t in range(9)]
        shift = -(min(xs) + max(xs)) / 2
        for stroke in line:
            for knot in stroke.knots:
                knot.p = (knot.p[0] + shift, knot.p[1])
            stroke.segments = beziers(stroke.knots)
        all_strokes.extend(line)
    return all_strokes


# MARK: - The pen's pace

SAMPLES = 48          # per segment, for length and curvature
PAUSE_LIFT = 0.07     # the pen off the paper inside a word
PAUSE_WORD = 0.16     # between words
PAUSE_MARK = 0.06     # before each dot, crossbar or accent
CUSP_EASE = 0.22      # x-heights over which the pen slows into a cusp or a stroke's end
MIN_SPEED = 0.22      # of the top speed


def pace(strokes, letters):
    """Times each stroke: returns [(t0, t1, [p at each 1/120 s])] and the total duration, where p
    is segment index + parameter along the segment."""
    # Arc length and the speed allowed at each sample.
    profiles = []
    for stroke in strokes:
        rows = []   # (cumulative length, segment, t, speed factor)
        cusps = [0.0]
        total = 0.0
        for index, seg in enumerate(stroke.segments):
            previous = point_at(seg, 0)
            if index > 0:
                k = stroke.knots[index]
                if k.corner:
                    cusps.append(total)
            for step in range(SAMPLES + 1):
                t = step / SAMPLES
                point = point_at(seg, t)
                if step > 0:
                    total += math.hypot(point[0] - previous[0], point[1] - previous[1])
                previous = point
                d1, d2 = derivative(seg, t)
                speed = math.hypot(*d1)
                curvature = abs(d1[0] * d2[1] - d1[1] * d2[0]) / max(speed ** 3, 1e-9)
                radius = 1 / max(curvature, 1e-6) / XH
                factor = math.sqrt(radius / (radius + 0.32))
                rows.append([total, index, t, factor])
        cusps.append(total)
        for row in rows:
            nearest = min(abs(row[0] - c) for c in cusps) / XH
            ease = math.sqrt(min(1.0, nearest / CUSP_EASE))
            row[3] = max(MIN_SPEED, row[3] * (0.35 + 0.65 * ease))
        profiles.append((rows, total))

    # Time at unit top speed (design units per second = 1), then scaled to the duration wanted.
    raw = []
    for rows, _ in profiles:
        times = [0.0]
        for a, b in zip(rows, rows[1:]):
            ds = b[0] - a[0]
            times.append(times[-1] + ds / ((a[3] + b[3]) / 2))
        raw.append(times)
    ink = sum(times[-1] for times in raw)
    pauses = []
    previous = None
    for stroke in strokes:
        if previous is None:
            pause = 0.0
        elif stroke.kind == "mark":
            pause = PAUSE_MARK + (0.05 if previous.kind == "main" else 0.0)
        elif stroke.word != previous.word:
            pause = PAUSE_WORD
        else:
            pause = PAUSE_LIFT
        pauses.append(pause)
        previous = stroke
    duration = min(2.2, max(1.6, 1.2 + 0.065 * letters))
    scale = (duration - sum(pauses)) / ink

    timed = []
    clock = 0.0
    fps = 120.0
    for stroke, (rows, _), times, pause in zip(strokes, profiles, raw, pauses):
        clock += pause
        t0 = clock
        t1 = clock + times[-1] * scale
        samples = []
        steps = max(1, int(math.ceil((t1 - t0) * fps)))
        j = 0
        for step in range(steps + 1):
            local = min(times[-1], (step / steps) * times[-1])
            while j + 1 < len(times) - 1 and times[j + 1] < local:
                j += 1
            a, b = rows[j], rows[min(j + 1, len(rows) - 1)]
            ta, tb = times[j], times[min(j + 1, len(times) - 1)]
            f = 0.0 if tb <= ta else (local - ta) / (tb - ta)
            pa = a[1] + a[2]
            pb = b[1] + b[2]
            samples.append(pa + (pb - pa) * f)
        samples[-1] = float(len(stroke.segments))
        timed.append((t0, t1, samples))
        clock = t1
    return timed, clock


# MARK: - Output

def to_screen(point):
    """Design units (y up) to the output's: x-height 1, y down."""
    return (point[0] / XH, -point[1] / XH)


def greeting_data(code, text, lines):
    strokes = layout(lines)
    letters = sum(len(word) for line in lines for word in line)
    timed, duration = pace(strokes, letters)
    out = []
    xs, ys = [], []
    for stroke, (t0, t1, samples) in zip(strokes, timed):
        parts = []
        first = to_screen(stroke.segments[0][0])
        parts.append("M %.4f %.4f" % first)
        for seg in stroke.segments:
            c1, c2, p1 = (to_screen(p) for p in seg[1:])
            parts.append("C %.4f %.4f %.4f %.4f %.4f %.4f" % (c1 + c2 + p1))
            for t in (0.25, 0.5, 0.75, 1.0):
                x, y = to_screen(point_at(seg, t))
                xs.append(x)
                ys.append(y)
        out.append(dict(kind=stroke.kind, t0=round(t0, 4), t1=round(t1, 4), d=" ".join(parts),
                        p=" ".join("%.3f" % s for s in samples)))
    return dict(code=code, text=text, lines=[" ".join(line) for line in lines], duration=round(duration, 4),
                bounds=[round(min(xs), 4), round(min(ys), 4), round(max(xs), 4), round(max(ys), 4)],
                lineCount=len(lines), lineGap=LINE_GAP / XH, strokes=out)


def write_js(data):
    with open(JS_OUT, "w", encoding="utf-8") as handle:
        handle.write("// Generated by design/tools/welcome_lettering.py — do not edit.\n")
        handle.write("window.WELCOME_LETTERING = ")
        json.dump(data, handle, ensure_ascii=False, indent=1)
        handle.write(";\n")


def swift_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_swift(data):
    lines = [
        "// Generated by design/tools/welcome_lettering.py — do not edit; change a glyph there and run it again.",
        "//",
        "// Lumen's own lettering, no font's: each greeting as the centreline a pen follows, in cubic",
        "// Béziers (\"M x y C x1 y1 x2 y2 x y …\"), and where the pen is along it every 1/120 s of its",
        "// stroke (a segment's index plus how far along that segment). Units: the x-height is 1, y points",
        "// down, x = 0 is the greeting's centre and y = 0 the baseline of its last line. The same data",
        "// draws design/prototypes/welcome.html.",
        "",
        "import CoreGraphics",
        "",
        "extension WelcomeLettering {",
        "    /// Every greeting, in the order later launches go through them (WelcomeSplashPolicy.nextGreeting).",
        "    /// Each is the greeting itself in its own language: never translated.",
        "    static let all: [WelcomeLettering] = [",
    ]
    for greeting in data:
        lines.append("        WelcomeLettering(")
        lines.append("            code: %s, text: %s, // l10n: not text" % (swift_string(greeting["code"]),
                                                                       swift_string(greeting["text"])))
        lines.append("            duration: %s, lineCount: %d," % (repr(greeting["duration"]), greeting["lineCount"]))
        b = greeting["bounds"]
        lines.append("            bounds: CGRect(x: %.4f, y: %.4f, width: %.4f, height: %.4f)," %
                     (b[0], b[1], b[2] - b[0], b[3] - b[1]))
        lines.append("            strokes: [")
        for stroke in greeting["strokes"]:
            lines.append("                .init(mark: %s, start: %s, end: %s," % (
                "true" if stroke["kind"] == "mark" else "false", repr(stroke["t0"]), repr(stroke["t1"])))
            lines.append("                      path: %s," % swift_string(stroke["d"]))
            lines.append("                      pen: %s)," % swift_string(stroke["p"]))
        lines.append("            ]),")
    lines.append("    ]")
    lines.append("}")
    with open(SWIFT_OUT, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


# MARK: - The contact sheet (for drawing the glyphs)

def sheet(path):
    rows = []
    x, y = 40, 60
    glyph_names = list(GLYPHS) + list(MARKED)
    scale = 0.9
    items = []
    for name in glyph_names:
        items.append(([[name]], name))
    for code, text, lines in GREETINGS:
        items.append((lines, code))
    width = 1800
    svg_parts = []
    row_h = 0
    for lines, label in items:
        strokes = layout(lines)
        xs = [p[0] for s in strokes for k in s.knots for p in [k.p]]
        ys = [p[1] for s in strokes for k in s.knots for p in [k.p]]
        w = (max(xs) - min(xs)) * scale + 60
        h = (max(ys) - min(ys) + 120) * scale + 40
        if x + w > width:
            x = 40
            y += row_h + 20
            row_h = 0
        ox = x - min(xs) * scale + 20
        oy = y + max(ys) * scale + 30
        def tr(p):
            return (ox + p[0] * scale, oy - p[1] * scale)
        g = []
        g.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#333" stroke-width="1"/>' % (
            x, oy, x + w, oy))
        g.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#262626" stroke-width="1"/>' % (
            x, oy - XH * scale, x + w, oy - XH * scale))
        for s in strokes:
            d = []
            for i, seg in enumerate(s.segments):
                p0, c1, c2, p1 = (tr(p) for p in seg)
                if i == 0:
                    d.append("M %.1f %.1f" % p0)
                d.append("C %.1f %.1f %.1f %.1f %.1f %.1f" % (c1 + c2 + p1))
            color = "#cfd3da" if s.kind == "main" else "#9fd0ff"
            g.append('<path d="%s" fill="none" stroke="%s" stroke-width="%.1f" stroke-linecap="round" '
                     'stroke-linejoin="round" opacity="0.85"/>' % (" ".join(d), color, 15 * scale))
            g.append('<path d="%s" fill="none" stroke="#e5484d" stroke-width="1"/>' % " ".join(d))
            for k in s.knots:
                px, py = tr(k.p)
                g.append('<circle cx="%.1f" cy="%.1f" r="2.2" fill="%s"/>' % (px, py, "#ffb224" if k.corner else "#3dd68c"))
        g.append('<text x="%.1f" y="%.1f" fill="#888" font-size="12" font-family="Inter">%s</text>' % (x, y + 10, label))
        svg_parts.append("\n".join(g))
        x += w + 20
        row_h = max(row_h, h)
    height = y + row_h + 40
    with open(path, "w", encoding="utf-8") as handle:
        handle.write('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">' % (width, height))
        handle.write('<rect width="100%" height="100%" fill="#0b0c0f"/>')
        handle.write("\n".join(svg_parts))
        handle.write("</svg>\n")


def main(argv):
    if len(argv) > 2 and argv[1] == "--sheet":
        sheet(argv[2])
        return 0
    data = [greeting_data(code, text, lines) for code, text, lines in GREETINGS]
    write_js(data)
    write_swift(data)
    for greeting in data:
        print("%s: %d strokes, %.2f s" % (greeting["code"], len(greeting["strokes"]), greeting["duration"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
