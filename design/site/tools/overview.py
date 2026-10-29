# Contact sheets of every page (the top of each full-page shot), for a first look:
#   python3 design/site/tools/overview.py  →  shots/overview-{ru,en}-1440.png, shots/overview-{ru,en}-390.png
import os, sys
from PIL import Image, ImageDraw, ImageFont

SITE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGES = ['index', 'features', 'how-it-works', 'verification', 'pricing', 'download',
         'docs', 'docs-import-cookies', 'blog', 'blog-no-noise', 'login', 'login-code',
         'login-key', 'signup', 'account', 'account-devices', 'account-sync', 'account-invoices',
         'account-settings', 'privacy', 'terms', 'refunds', 'support', '404']

def font(size):
    for f in ['/usr/share/fonts/opentype/inter/Inter-Medium.otf', '/System/Library/Fonts/SFNS.ttf']:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()

def sheet(lang, width, crop_h, scale, cols):
    tiles = []
    for p in PAGES:
        im = Image.open(os.path.join(SITE, 'shots', lang, f'{p}-{width}.png')).convert('RGB')
        im = im.crop((0, 0, im.size[0], min(im.size[1], crop_h * 2)))
        tiles.append((p, im.resize((int(im.size[0] * scale), int(im.size[1] * scale)), Image.LANCZOS)))
    tw = max(t.size[0] for _, t in tiles); th = max(t.size[1] for _, t in tiles)
    gap, label = 16, 28
    rows = (len(tiles) + cols - 1) // cols
    out = Image.new('RGB', (cols * tw + (cols + 1) * gap, rows * (th + label) + (rows + 1) * gap), (5, 6, 8))
    d = ImageDraw.Draw(out); f = font(15)
    for k, (name, t) in enumerate(tiles):
        x = gap + (k % cols) * (tw + gap); y = gap + (k // cols) * (th + label + gap)
        d.text((x, y + 4), f'{name}.html', fill=(162, 169, 182), font=f)
        out.paste(t, (x, y + label))
    path = os.path.join(SITE, 'shots', f'overview-{lang}-{width}.png')
    out.save(path, optimize=True)
    print('WROTE', os.path.relpath(path, SITE), out.size)

for lang in ('ru', 'en'):
    sheet(lang, 1440, 1000, 0.2, 6)
    sheet(lang, 390, 844, 0.32, 12)
