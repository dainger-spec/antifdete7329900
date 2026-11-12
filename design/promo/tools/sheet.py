"""A contact sheet of stills: python3 sheet.py out.jpg a.png b.png … (five across, each 384 wide, its time under it)."""
import os
import re
import sys

from PIL import Image, ImageDraw

out, files = sys.argv[1], sys.argv[2:]
cols, w = 5, 384
thumbs = []
for f in files:
    im = Image.open(f).convert('RGB')
    h = round(im.height * w / im.width)
    thumbs.append((im.resize((w, h), Image.LANCZOS), os.path.basename(f)))
h = thumbs[0][0].height
rows = (len(thumbs) + cols - 1) // cols
sheet = Image.new('RGB', (cols * w + (cols + 1) * 6, rows * (h + 22) + 6), (48, 48, 52))
d = ImageDraw.Draw(sheet)
for i, (im, name) in enumerate(thumbs):
    x = 6 + (i % cols) * (w + 6)
    y = 6 + (i // cols) * (h + 22)
    sheet.paste(im, (x, y))
    m = re.search(r't0*([\d.]+)\.png', name)
    d.text((x + 4, y + h + 4), f"t = {m.group(1) if m else name}", fill=(255, 220, 90))
sheet.save(out, quality=88)
print(out, sheet.size)
