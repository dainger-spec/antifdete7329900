"""Measures what a translucent sidebar does to text contrast: samples the rendered sidebar's empty band
(no text there) and reports, for each text colour, the contrast against its lightest and darkest pixel.

  python3 design/tools/sample_sidebar.py out.json render1.png render2.png ...   (renders at ×2, window inset 28 pt)
"""
import json, sys
from PIL import Image

def lin(c):
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def lum(rgb):
    r, g, b = (lin(c) for c in rgb[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def ratio(a, b):
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)

TEXT = {'textPrimary': (0xEC, 0xEE, 0xF2), 'textSecondary': (0xA2, 0xA9, 0xB6), 'textTertiary': (0x8A, 0x93, 0xA3)}
out = {}
for path in sys.argv[2:]:
    im = Image.open(path).convert('RGB')
    s = 2  # renders are at Retina scale
    # sidebar band with no text: x 28+20 … 28+190, y 28+470 … 28+630 (points)
    box = ((28 + 20) * s, (28 + 470) * s, (28 + 190) * s, (28 + 630) * s)
    pixels = list(im.crop(box).get_flattened_data()) if hasattr(Image.Image, 'get_flattened_data') else list(im.crop(box).getdata())
    lums = sorted(lum(p) for p in pixels)
    lightest, darkest = lums[int(len(lums) * 0.995)], lums[int(len(lums) * 0.005)]
    out[path.rsplit('/', 1)[-1]] = {
        name: {'worst': round(ratio(lum(c), lightest), 2), 'best': round(ratio(lum(c), darkest), 2)} for name, c in TEXT.items()
    }
json.dump(out, open(sys.argv[1], 'w'), indent=1)
print(json.dumps(out, indent=1))
