#!/usr/bin/env python3
"""Pairs for the design's review: each mockup of the handoff beside the app's own screenshot of the
same state (DesignShotTests, sorted by ci.sh into design/<lang>-<theme>/<name>.png).

    python3 ios/scripts/design_pairs.py <handoff screens dir> <CI design dir> <out dir>

<handoff screens dir> holds ru-dark/, en-dark/, ru-light/ … with <name>.png (1170 x 2532); the CI's
design dir the same names (1320 x 2868, the 6.9-inch iPhone). Each pair is written as
<out>/<lang>-<theme>/<name>.png, both at one height under a line naming them; a state the app was not
photographed in is listed, not drawn. Prints the list of pairs, and the states missing on either side.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HEIGHT = 1100
GAP = 40
TOP = 70


def font(size):
    for path in ("/usr/share/fonts/opentype/inter/Inter-SemiBold.otf",
                 "/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def scaled(path):
    image = Image.open(path).convert("RGB")
    width = round(image.width * HEIGHT / image.height)
    return image.resize((width, HEIGHT), Image.LANCZOS)


def pair(mockup, app, title, out):
    left, right = scaled(mockup), scaled(app)
    canvas = Image.new("RGB", (left.width + right.width + GAP * 3, HEIGHT + TOP + GAP), (246, 246, 248))
    draw = ImageDraw.Draw(canvas)
    small = font(26)
    draw.text((GAP, 18), f"{title} — макет", font=small, fill=(40, 40, 46))
    draw.text((left.width + GAP * 2, 18), "приложение", font=small, fill=(40, 40, 46))
    canvas.paste(left, (GAP, TOP))
    canvas.paste(right, (left.width + GAP * 2, TOP))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    canvas.save(out, optimize=True)


def main(mockups, shots, out):
    made, no_app, no_mockup = [], [], []
    for variant in sorted(os.listdir(mockups)):
        folder = os.path.join(mockups, variant)
        if not os.path.isdir(folder):
            continue
        for name in sorted(n[:-4] for n in os.listdir(folder) if n.endswith(".png")):
            app = os.path.join(shots, variant, name + ".png")
            if os.path.exists(app):
                pair(os.path.join(folder, name + ".png"), app, f"{variant} · {name}", os.path.join(out, variant, name + ".png"))
                made.append(f"{variant}/{name}")
            else:
                no_app.append(f"{variant}/{name}")
    if os.path.isdir(shots):
        for variant in sorted(os.listdir(shots)):
            for name in sorted(os.listdir(os.path.join(shots, variant))):
                if not os.path.exists(os.path.join(mockups, variant, name)):
                    no_mockup.append(f"{variant}/{name[:-4]}")
    print(f"pairs: {len(made)}")
    print("no screenshot of the app:", ", ".join(no_app) or "none")
    print("no mockup (states the app has beyond the handoff):", ", ".join(no_mockup) or "none")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
