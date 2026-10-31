# The studio every shot of the film v3 stands in: v2's graphite cyc (PL-CARD, rendered by tools/film/plates.mjs
# with tools/hero/renderer.js), out of focus, a stop brighter and a touch cool, so the windows stand on a lit
# graphite backdrop and their shadows show — rather than v1's empty black. 8-bit, with a triangular dither of
# about a level so the long dark gradient doesn't band.
#
#   python3 -I tools/film3/studio.py [--ev 1.0]     # → video/.cache/studio/studio.png (3840 × 2160)
#
# It reads video/.cache/plates/PL-CARD.defocus48.npy (linear light, float16), or makes it from PL-CARD/0000.png.
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

SITE = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
ev = float(sys.argv[sys.argv.index('--ev') + 1]) if '--ev' in sys.argv else 1.0
plates = os.path.join(SITE, 'video', '.cache', 'plates')
cache = os.path.join(plates, 'PL-CARD.defocus48.npy')


def lin(x):
    return np.where(x <= 0.04045, x / 12.92, np.power((x + 0.055) / 1.055, 2.4))


def enc(x):
    x = np.clip(x, 0, 1)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - 0.055)


if os.path.exists(cache):
    a = np.load(cache).astype(np.float32)
else:
    im = Image.open(os.path.join(plates, 'PL-CARD', '0000.png')).convert('RGB')
    im = im.filter(ImageFilter.GaussianBlur(48))
    a = lin(np.asarray(im, dtype=np.float32) / 255)
a = a * (2 ** ev) * np.array([0.97, 1.0, 1.06], dtype=np.float32)
s = enc(a) * 255
rng = np.random.default_rng(7)
s += rng.triangular(-1, 0, 1, size=s.shape).astype(np.float32)
out = os.path.join(SITE, 'video', '.cache', 'studio')
os.makedirs(out, exist_ok=True)
Image.fromarray(np.clip(np.rint(s), 0, 255).astype(np.uint8), 'RGB').save(os.path.join(out, 'studio.png'), compress_level=6)
print(f'WROTE video/.cache/studio/studio.png ({s.shape[1]} × {s.shape[0]}, levels {s.min():.0f}–{s.max():.0f}, mean {s.mean():.1f})')
