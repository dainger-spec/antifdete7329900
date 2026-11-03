#!/usr/bin/env python3
"""Does the disk image's window, as captured, show its picture? (the owner, 3 November: 0.1.1's
window had its icons and its size and no picture, and nothing said so.)

    python3 scripts/dmg_background_check.py --shot dmg-window-light.png --geometry dmg-window-light.json \\
        --picture background.png

`--shot` is the capture of the window (scripts/dmg_window_shot.sh), `--geometry` what that script
wrote beside it: Finder's bounds of the window and the rectangle captured, in points. `--picture` is
the window's picture at 1x, as a PNG — what `Lumen --render-dmg-background` draws, or the image's own
.background/background.tiff converted with sips.

The picture is laid from the top left of the window's content, under the title bar, whose height
differs between macOS versions: the check finds where the picture sits by trying each offset, then
compares the capture with the picture point by point — leaving out the icons and the names Finder
writes — in two sets: its backdrop, every 8 points, and its features, every 2 points where the
picture stands out from its backdrop (the plates under the names, the mark and the name). It
passes when at least 90 % of the backdrop's points and 80 % of the features' are the picture's own
colour (each channel within 12 of it). Without the picture the window's own background is white,
or (30, 30, 30) in the dark appearance (CI run 668); and a window of any one colour, even one as
dark as the picture's near black (11, 12, 15), shows none of its features. Exit 0 when the window shows the picture, 1 when it does not, 2 when the
files cannot be read. Standard library only.
"""
import argparse
import json
import struct
import sys
import zlib

TOLERANCE = 12
PASS_SHARE = 0.90
FEATURE_SHARE = 0.80
STEP = 8
# A point of the picture is one of its features — the plates under the names, the mark and the
# name at the top — when it is this far from the picture's own backdrop: a window of one colour,
# however close to the backdrop, never shows those.
FEATURE_CONTRAST = 40
# DiskImageBackground.swift: the icons' size and centres, and where Finder writes their names.
ICON_HALF = 72
CENTRES = ((170, 210), (490, 210))
LABEL_BELOW, LABEL_HALF_WIDTH, LABEL_HALF_HEIGHT = 84, 46, 12


def read_png(path):
    """(width, height, rows of RGB tuples) of an 8-bit RGB or RGBA, non-interlaced PNG."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")
    position, chunks, width, height, channels = 8, [], None, None, None
    while position < len(data):
        (length,) = struct.unpack(">I", data[position:position + 4])
        kind, body = data[position + 4:position + 8], data[position + 8:position + 8 + length]
        position += 12 + length
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or interlace != 0 or colour not in (2, 6):
                raise ValueError(f"{path}: a PNG of depth {depth}, colour type {colour}, interlace {interlace} is not read here")
            channels = 4 if colour == 6 else 3
        elif kind == b"IDAT":
            chunks.append(body)
        elif kind == b"IEND":
            break
    raw = zlib.decompress(b"".join(chunks))
    stride, rows, previous, index = width * channels, [], bytearray(width * channels), 0
    for _ in range(height):
        kind, line = raw[index], bytearray(raw[index + 1:index + 1 + stride])
        index += 1 + stride
        for x in range(stride):
            left = line[x - channels] if x >= channels else 0
            up = previous[x]
            corner = previous[x - channels] if x >= channels else 0
            if kind == 1:
                line[x] = (line[x] + left) & 255
            elif kind == 2:
                line[x] = (line[x] + up) & 255
            elif kind == 3:
                line[x] = (line[x] + ((left + up) >> 1)) & 255
            elif kind == 4:
                guess = left + up - corner
                a, b, c = abs(guess - left), abs(guess - up), abs(guess - corner)
                line[x] = (line[x] + (left if a <= b and a <= c else up if b <= c else corner)) & 255
        rows.append([tuple(line[x:x + 3]) for x in range(0, stride, channels)])
        previous = line
    return width, height, rows


def covered(x, y):
    """Points of the picture Finder draws over: the icons, and the names it writes under them."""
    for cx, cy in CENTRES:
        if abs(x - cx) <= ICON_HALF and abs(y - cy) <= ICON_HALF:
            return True
        if abs(x - cx) <= LABEL_HALF_WIDTH and abs(y - (cy + LABEL_BELOW)) <= LABEL_HALF_HEIGHT:
            return True
    return False


def points(picture):
    """The picture's points to compare: (backdrop points, feature points), each (x, y, colour)."""
    width, height, rows = picture
    backdrop = rows[min(340, height - 1)][min(30, width - 1)]
    plain, features = [], []
    for y in range(4, height - 4, STEP):
        for x in range(4, width - 4, STEP):
            if not covered(x, y):
                plain.append((x, y, rows[y][x]))
    for y in range(4, height - 4, 2):
        for x in range(4, width - 4, 2):
            colour = rows[y][x]
            if not covered(x, y) and max(abs(colour[i] - backdrop[i]) for i in range(3)) > FEATURE_CONTRAST:
                features.append((x, y, colour))
    plain = [point for point in plain if max(abs(point[2][i] - backdrop[i]) for i in range(3)) <= FEATURE_CONTRAST]
    return backdrop, plain, features


def score(shot, sample, scale, dx, dy, window_width, window_height):
    """(matching, compared) of the sample's points, the picture laid at (dx, dy) points into the capture."""
    shot_width, shot_height, shot_rows = shot
    matching = compared = 0
    for x, y, wanted in sample:
        if dy + y > window_height - 4 or dx + x > window_width - 4:
            continue
        sx, sy = int((dx + x) * scale), int((dy + y) * scale)
        if sx >= shot_width or sy >= shot_height:
            continue
        seen = shot_rows[sy][sx]
        compared += 1
        if max(abs(seen[i] - wanted[i]) for i in range(3)) <= TOLERANCE:
            matching += 1
    return matching, compared


def share(result):
    matching, compared = result
    return matching / compared if compared else 0.0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shot", required=True)
    parser.add_argument("--geometry", required=True)
    parser.add_argument("--picture", required=True)
    arguments = parser.parse_args()
    try:
        shot = read_png(arguments.shot)
        picture = read_png(arguments.picture)
        with open(arguments.geometry) as handle:
            geometry = json.load(handle)
        left, top, right, bottom = geometry["bounds"]
        capture_x, capture_y, capture_width, _ = geometry["capture"]
    except (OSError, ValueError, KeyError, zlib.error) as error:
        print(f"window picture: cannot be checked: {error}")
        return 2
    scale = shot[0] / capture_width
    # The picture in points: its first page is 1x, but a 2x page given is read at every second pixel.
    if picture[0] >= 2 * (right - left) - 2:
        picture = (picture[0] // 2, picture[1] // 2, [row[::2] for row in picture[2][::2]])
    # The window in the capture, in points: its frame from (left, top) to (right, bottom).
    frame_x, frame_y = left - capture_x, top - capture_y
    window_width, window_height = right - capture_x, bottom - capture_y
    backdrop, plain, features = points(picture)
    if len(features) < 50:
        print(f"window picture: cannot be checked: the picture has only {len(features)} points that stand out from its backdrop")
        return 2
    # Where the picture sits: under a title bar of a height this macOS gives it.
    coarse_plain, coarse_features = plain[::3], features[::4]
    best = (-1.0, frame_x, frame_y)
    for dy in range(frame_y, frame_y + 81):
        for dx in range(frame_x, frame_x + 9):
            fit = min(share(score(shot, coarse_plain, scale, dx, dy, window_width, window_height)),
                      share(score(shot, coarse_features, scale, dx, dy, window_width, window_height)))
            if fit > best[0]:
                best = (fit, dx, dy)
    _, dx, dy = best
    plain_result = score(shot, plain, scale, dx, dy, window_width, window_height)
    feature_result = score(shot, features, scale, dx, dy, window_width, window_height)
    appearance = geometry.get("appearance", "?")
    where = f"laid {dx - frame_x}, {dy - frame_y} points into the window's frame, capture at {scale:g}x"
    said = (f"{plain_result[0]} of {plain_result[1]} points of its backdrop ({share(plain_result):.1%}) and "
            f"{feature_result[0]} of {feature_result[1]} points of its plates, mark and name ({share(feature_result):.1%})")
    if plain_result[1] < 300 or feature_result[1] < 50:
        print(f"window picture ({appearance}): cannot be checked: too little of the picture is in the capture ({said})")
        return 2
    if share(plain_result) >= PASS_SHARE and share(feature_result) >= FEATURE_SHARE:
        print(f"window picture ({appearance}): SHOWN — {said} are the picture's ({where})")
        return 0
    print(f"window picture ({appearance}): NOT SHOWN — at its best place only {said} are the picture's "
          f"({PASS_SHARE:.0%} and {FEATURE_SHARE:.0%} are needed; {where})")
    shot_rows = shot[2]
    seen = shot_rows[min(int((dy + 340) * scale), shot[1] - 1)][min(int((dx + 30) * scale), shot[0] - 1)]
    print(f"window picture ({appearance}): where the picture's backdrop {backdrop} should be, the window shows {seen}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
