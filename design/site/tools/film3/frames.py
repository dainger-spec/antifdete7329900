# The film's frames, from capture.mjs's screenshots: the moments of one frame's shutter averaged (motion blur),
# the 2x screenshot brought down to the film's size with Lanczos, and a little dither (about ±0.6 of a level,
# different in every frame) before it is rounded to 8 bits, so the long dark gradients don't band in the video.
#
#   reads stdin: "<file> <n>\n", then n times "<bytes>\n<png>"; writes <file> (PNG, written whole or not at all)
import io
import os
import sys

import numpy as np
from PIL import Image

W, H = int(sys.argv[1]), int(sys.argv[2])
inp = sys.stdin.buffer
while True:
    head = inp.readline()
    if not head:
        break
    file, n = head.decode().split()
    n = int(n)
    acc = None
    for _ in range(n):
        size = int(inp.readline())
        im = Image.open(io.BytesIO(inp.read(size))).convert('RGB')
        a = np.asarray(im, dtype=np.float32)
        acc = a if acc is None else acc + a
    acc /= n
    if acc.shape[1] != W or acc.shape[0] != H:
        chans = [np.asarray(Image.fromarray(acc[:, :, c], 'F').resize((W, H), Image.LANCZOS)) for c in range(3)]
        acc = np.stack(chans, axis=2)
    seed = int(''.join(ch for ch in os.path.basename(file) if ch.isdigit()) or 0)
    rng = np.random.default_rng(seed)
    acc += rng.triangular(-0.6, 0, 0.6, size=acc.shape).astype(np.float32)
    out = np.clip(np.rint(acc), 0, 255).astype(np.uint8)
    Image.fromarray(out, 'RGB').save(file + '.part.png', compress_level=1)
    os.replace(file + '.part.png', file)
