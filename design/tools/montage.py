"""Puts PNGs side by side (or in a grid) for a quick look: python3 design/tools/montage.py out.png cols a.png b.png ..."""
import sys
from PIL import Image
out, cols, files = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
ims = [Image.open(f).convert('RGB') for f in files]
scale = 0.5
ims = [im.resize((int(im.width * scale), int(im.height * scale)), Image.LANCZOS) for im in ims]
cw = max(im.width for im in ims); ch = max(im.height for im in ims)
rows = (len(ims) + cols - 1) // cols
sheet = Image.new('RGB', (cols * cw + (cols - 1) * 16, rows * ch + (rows - 1) * 16), (40, 40, 40))
for i, im in enumerate(ims):
    sheet.paste(im, ((i % cols) * (cw + 16), (i // cols) * (ch + 16)))
sheet.save(out)
print(sheet.size)
