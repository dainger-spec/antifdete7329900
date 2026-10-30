# Encode the hero's rendered frames (PNG) to WebP for the page, the last one to JPEG for the still page, and
# a small poster of the first one (JPEG) that the page draws while the frames load.
#   python3 tools/hero/encode.py <png dir> <out dir> <webp quality> <final.jpg>
# Called by tools/hero/render.mjs. Prints each framing's total size.
import os
import sys
from PIL import Image

src, dst, q, final = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
names = sorted(f for f in os.listdir(src) if f.endswith('.png'))
total = 0
for n in names:
    im = Image.open(os.path.join(src, n)).convert('RGB')
    out = os.path.join(dst, n.replace('.png', '.webp'))
    im.save(out, 'WEBP', quality=q, method=6)
    total += os.path.getsize(out)
last = Image.open(os.path.join(src, names[-1])).convert('RGB')
last.save(final, 'JPEG', quality=86, optimize=True, progressive=True, subsampling=0)
first = Image.open(os.path.join(src, names[0])).convert('RGB')
poster = final.replace('-final.jpg', '-poster.jpg')
first.resize((first.width // 4, first.height // 4), Image.LANCZOS).save(poster, 'JPEG', quality=62, optimize=True, progressive=True)
print(f'{dst}: {len(names)} frames, {total / 1e6:.2f} MB; {final}: {os.path.getsize(final) / 1e3:.0f} KB; {poster}: {os.path.getsize(poster) / 1e3:.0f} KB')
