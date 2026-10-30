# Two more procedural "photographs" for the mock pages, chosen for colour: a summer archipelago (blue sky,
# deep sea, a red cottage on granite) and northern lights over the fjäll. Only ever seen through the reeds.
import sys, numpy as np
from PIL import Image, ImageDraw, ImageFilter
OUT = sys.argv[1]
rng = np.random.default_rng(3)
W, H = 960, 600

def grad(stops):
    y = np.linspace(0, 1, H)[:, None]
    out = np.zeros((H, W, 3))
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        m = (y >= p0) & (y <= p1)
        t = np.clip((y - p0) / max(1e-6, p1 - p0), 0, 1)
        col = np.array(c0)[None, None, :] * (1 - t[..., None]) + np.array(c1)[None, None, :] * t[..., None]
        out = np.where(m[..., None], col, out)
    return out

def noise(scale, octaves=4):
    acc = np.zeros((H, W)); amp = 1; tot = 0
    for o in range(octaves):
        sh, sw = max(2, int(H / scale * 2 ** o)), max(2, int(W / scale * 2 ** o))
        n = rng.random((sh, sw))
        im = Image.fromarray((n * 255).astype(np.uint8)).resize((W, H), Image.BICUBIC)
        acc += np.asarray(im) / 255 * amp; tot += amp; amp *= 0.5
    return acc / tot

def summer():
    a = grad([(0, (58, 118, 196)), (0.5, (150, 196, 232)), (0.505, (30, 78, 128)), (1, (16, 50, 92))])
    # soft clouds
    c = noise(160, 5); al = np.clip((c - 0.52) * 3.2, 0, 0.75) * (np.arange(H)[:, None] < 300) * np.clip((300 - np.arange(H)[:, None]) / 60, 0, 1)
    a = a * (1 - al[..., None]) + np.array([244, 247, 251])[None, None, :] * al[..., None]
    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)); d = ImageDraw.Draw(im)
    # granite island, pine trees, a falu-red cottage with white trim, its reflection
    d.polygon([(250, 312), (330, 270), (520, 262), (700, 286), (760, 312)], fill=(122, 112, 104))
    for x in range(300, 690, 22):
        h = int(rng.integers(40, 90)); d.polygon([(x, 272 - h), (x - 14, 276), (x + 14, 276)], fill=(30, 66, 42))
    d.rectangle([430, 222, 540, 282], fill=(150, 36, 30)); d.polygon([(420, 224), (485, 186), (550, 224)], fill=(52, 40, 38))
    d.rectangle([450, 244, 470, 264], fill=(236, 236, 230)); d.rectangle([500, 244, 520, 264], fill=(236, 236, 230))
    d.rectangle([150, 306, 860, 316], fill=(60, 90, 120))
    a = np.asarray(im).astype(float)
    refl = a[::-1][H - 2 * 312:H - 312 + (H - 312) - (H - 312)] if False else None
    yy = np.arange(H)
    for y in range(312, min(H, 312 + 80)):
        src = 2 * 312 - y
        a[y] = a[y] * 0.62 + a[src] * 0.38 * 0.85
    a += (noise(18) - 0.5)[..., None] * 18 * (yy[:, None, None] > 312)
    Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).save(f'{OUT}/summer.png')

def aurora():
    a = grad([(0, (6, 12, 30)), (0.6, (14, 30, 52)), (0.7, (20, 34, 50)), (1, (10, 14, 22))])
    x = np.arange(W)[None, :]; y = np.arange(H)[:, None]
    # two ribbons: a curved band, brightest at its lower edge, with vertical rays
    for (cy, amp, ph, col, k) in [(200, 60, 0.0, (70, 210, 150), 1.0), (150, 40, 1.7, (60, 170, 170), 0.6)]:
        curve = cy + amp * np.sin(x / 210 + ph) + 20 * np.sin(x / 67 + ph * 2)
        rays = 0.55 + 0.45 * np.asarray(Image.fromarray((rng.random((1, W // 6)) * 255).astype(np.uint8)).resize((W, 1), Image.BICUBIC)) / 255
        dy = curve - y
        band = np.where(dy > 0, np.exp(-dy / 70.0), np.exp(dy / 9.0)) * (dy > -30)
        a += band[..., None] * rays[..., None] * np.array(col)[None, None, :] * 0.9 * k
    # fjäll silhouette and snow
    ridge = 400 + 40 * np.sin(np.arange(W) / 120) + 25 * np.sin(np.arange(W) / 41 + 1)
    m = y > ridge[None, :]
    a[m] = a[m] * 0.15 + np.array([10, 14, 22]) * 0.85
    snow = y > (470 + 10 * np.sin(np.arange(W) / 90))[None, :]
    a[snow] = np.array([52, 70, 88])
    a += (noise(30) - 0.5)[..., None] * 8
    Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).save(f'{OUT}/aurora.png')

summer(); aurora(); print('ok')
