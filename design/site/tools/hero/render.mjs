// The hero's image sequence: a MacBook Pro in Space Black whose display shows the Lumen mark in code; as you
// scroll, the camera comes closer and round to the Mac's right, and the mark's left half lifts out of the
// glass towards you, turning to face you, while the right half stays on the display with its seam of light.
// Rendered offline with our own WebGL2 renderer (renderer.js + codeart.js, opened in headless Chromium),
// then encoded to WebP with Pillow (encode.py).
//
// Regenerate (from design/site; about 45 min on 4 CPU cores with SwiftShader: desktop ~30, phone ~15):
//   node tools/hero/render.mjs                       # both framings → prototype/assets/scenes/hero/
//   node tools/hero/render.mjs --only d              # desktop only (d) or phone only (m)
// Look at a few moments quickly, small and noisy, into a scratch folder (not the site):
//   node tools/hero/render.mjs --preview /tmp/hero --at 0,0.4,1 --scale 0.3 --passes 2
//
// Output: hero/d/00.webp … (landscape 2560×1600, 16:10, for screens wider than tall: sharp on Retina) and
// hero/m/00.webp … (portrait 1080×1920, phones and tablets upright), hero/{d,m}-final.jpg (the last frame, for
// the still page: no JavaScript, Reduce Motion, screenshots), hero/{d,m}-poster.jpg (the first frame, small,
// drawn while the frames load), and tools/hero/layout.json (where the Mac and the half land in every frame;
// tools/templates/pages/home/hero.mjs reads it to keep the picture clear of the words). After a render,
// rebuild the site (node tools/build.mjs). Needs Playwright's Chromium and python3 with Pillow (WebP).
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SITE = path.resolve(here, '../..');
const { chromium } = createRequire(path.join(SITE, 'tools/render.mjs'))('playwright');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d; };

// MARK: The story, as keyframes over t (0 → 1 across the sequence)
const clamp01 = (x) => Math.max(0, Math.min(1, x));
const ease = (x) => { x = clamp01(x); return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
const smooth = (x) => { x = clamp01(x); return x * x * (3 - 2 * x); };
const lerp = (a, b, t) => a + (b - a) * t;
/// A monotone cubic through keyframes {t, ...numbers or arrays} (Fritsch–Carlson tangents): smooth through
/// the keys, never overshooting, at rest on the first key (so a held key really holds), still moving on the last.
function track(keys, t) {
  t = clamp01(t);
  let i = 0; while (i < keys.length - 2 && t > keys[i + 1].t) i++;
  const k1 = keys[i], k2 = keys[i + 1], h = k2.t - k1.t, u = clamp01((t - k1.t) / h);
  const slope = (a, b, f) => (f(b) - f(a)) / (b.t - a.t);
  const tangent = (k, f) => {
    if (k === 0) return 0;
    const dl = slope(keys[k - 1], keys[k], f);
    if (k === keys.length - 1) return dl * 0.5;
    const dr = slope(keys[k], keys[k + 1], f);
    return dl * dr <= 0 ? 0 : 2 / (1 / dl + 1 / dr);
  };
  const herm = (f) => {
    const p0 = f(k1), p1 = f(k2), m0 = tangent(i, f) * h, m1 = tangent(i + 1, f) * h;
    const u2 = u * u, u3 = u2 * u;
    return (2 * u3 - 3 * u2 + 1) * p0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * p1 + (u3 - u2) * m1;
  };
  const out = {};
  for (const key of Object.keys(k1)) {
    if (key === 't') continue;
    const v = k1[key];
    out[key] = Array.isArray(v) ? v.map((_, j) => herm((k) => k[key][j])) : herm((k) => k[key]);
  }
  return out;
}

// The words leave the first screen over t ≈ 0–0.2 (hero.js maps the scene's progress onto t, the film ends at
// p 0.9). The camera starts moving at t 0.06 and has done half its move by t 0.3; the half lifts out of the
// glass from t 0.24 and settles by t 0.85; between t 0.85 and 1 everything still drifts a little, so the end
// of the scroll is never a frozen picture.
const HALF0 = { t: 0, lift: 0, dx: 0, dy: 0, yaw: 0, pitch: 0, dome: 0 };
const FRAMINGS = {
  // Landscape: the whole Mac under the words, seen from a classic three-quarter-high front view (about 16°
  // above the deck, so the keyboard reads); then closer and round to its right while the half comes out
  // to the left, into the space the words have left, turned to face us.
  d: {
    w: 2560, h: 1600, frames: 72, quality: 72,
    cam: [
      { t: 0, eye: [80, 680, 1900], target: [0, 98, 0], fov: 18.5, shift: [0, 0.49] },
      { t: 0.06, eye: [80, 680, 1900], target: [0, 98, 0], fov: 18.5, shift: [0, 0.49] },
      { t: 0.3, eye: [300, 460, 1330], target: [-30, 108, 0], fov: 18.5, shift: [0.03, 0.2] },
      { t: 0.62, eye: [560, 400, 1150], target: [-95, 118, 0], fov: 21.5, shift: [0.12, 0.12] },
      { t: 0.85, eye: [640, 380, 1090], target: [-110, 118, 0], fov: 23, shift: [0.14, 0.07] },
      { t: 1, eye: [690, 372, 1060], target: [-115, 118, 0], fov: 23, shift: [0.15, 0.08] },
    ],
    half: [
      HALF0, { ...HALF0, t: 0.24 },
      { t: 0.55, lift: 190, dx: -50, dy: -10, yaw: 22, pitch: 2, dome: 0.03 },
      { t: 0.85, lift: 310, dx: -78, dy: -14, yaw: 40, pitch: 0, dome: 0.04 },
      { t: 1, lift: 335, dx: -84, dy: -16, yaw: 43, pitch: 0, dome: 0.04 },
    ],
  },
  // Portrait: the Mac across the bottom of the first screen, under the words, with the same lens as on
  // desktop; as the words go it comes closer (wider than the phone, bleeding off both sides) and up to the
  // middle, and the half rises into the tall space above it.
  m: {
    w: 1080, h: 1920, frames: 60, quality: 72,
    cam: [
      { t: 0, eye: [240, 600, 2100], target: [-5, 100, 0], fov: 21, shift: [0.02, 0.57] },
      { t: 0.06, eye: [240, 600, 2100], target: [-5, 100, 0], fov: 21, shift: [0.02, 0.57] },
      { t: 0.3, eye: [330, 540, 1900], target: [-12, 110, 0], fov: 21, shift: [0.03, 0.18] },
      { t: 0.62, eye: [430, 490, 1830], target: [-20, 130, 0], fov: 21.5, shift: [0.05, 0.13] },
      { t: 0.85, eye: [470, 470, 1800], target: [-24, 136, 0], fov: 21.5, shift: [0.05, 0.1] },
      { t: 1, eye: [490, 462, 1780], target: [-26, 138, 0], fov: 21.5, shift: [0.05, 0.09] },
    ],
    half: [
      HALF0, { ...HALF0, t: 0.24 },
      { t: 0.55, lift: 200, dx: 0, dy: 90, yaw: 8, pitch: 8, dome: 0.03 },
      { t: 0.85, lift: 320, dx: 10, dy: 135, yaw: 15, pitch: 10, dome: 0.04 },
      { t: 1, lift: 340, dx: 12, dy: 142, yaw: 17, pitch: 10, dome: 0.04 },
    ],
  },
};

/// Everything the renderer needs at moment t of a framing.
function params(F, t, q) {
  const c = track(F.cam, t);
  const h = track(F.half, t);
  const lift = clamp01(h.lift / F.half[F.half.length - 2].lift);
  const out = h.lift > 0.05;
  return {
    eye: c.eye, target: c.target, fov: c.fov, shift: c.shift, lid: 108,
    // the display: a deep blue field, the mark; the half that stays reads as clearly as the one that left
    screen: { on: 1, r: 0.33, rows: 13, ghost: 0, bg: 1, rightGain: lerp(1.15, 1.45, smooth(lift)), flat: lerp(0.25, 0.5, smooth(lift)) },
    half: out ? { ...h, gain: 1, glowK: 0.2, glowS: 2 } : null,
    halfGain: lerp(1.5, 1.6, lift), halfLight: lerp(0.5, 2.4, lift),
    pool: 0.6, poolR: 210, bloom: [0.2, 0.07],                       // a small pool of light under the Mac that ends well inside the frame; a tight glow
    passes: q.passes, spp: q.spp, exposure: 1, seed: 7,   // the same samples in every frame: grain stays put instead of boiling as you scroll
  };
}

// MARK: Run
const preview = opt('preview', null);
const only = opt('only', null);
const scale = +opt('scale', preview ? 0.5 : 1);
const quality = { passes: +opt('passes', preview ? 4 : 10), spp: +opt('spp', 1) };
const outRoot = preview ? path.resolve(preview) : path.join(SITE, 'prototype/assets/scenes/hero');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'hero-'));
const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const meta = {};
for (const [name, F] of Object.entries(FRAMINGS)) {
  if (only && only !== name) continue;
  const W = Math.round(F.w * scale), H = Math.round(F.h * scale);
  const page = await browser.newPage();
  page.on('pageerror', (e) => console.error('pageerror:', e.message.slice(0, 3000)));
  await page.goto(pathToFileURL(path.join(here, 'render.html')).href);
  await page.evaluate(() => document.fonts.load('20px "DejaVu Sans Mono"'));
  await page.evaluate(([w, h]) => window.HERO.init(w, h), [W, H]);
  const ts = preview ? opt('at', '0,0.5,1').split(',').map(Number) : Array.from({ length: F.frames }, (_, i) => i / (F.frames - 1));
  const dir = preview ? outRoot : path.join(tmp, name);
  fs.mkdirSync(dir, { recursive: true });
  const t0 = Date.now();
  meta[name] = [];
  for (const [i, t] of ts.entries()) {
    const r = await page.evaluate((o) => window.HERO.frame(o), params(F, t, quality));
    const url = await page.evaluate(() => window.HERO.image());
    const file = preview ? path.join(dir, `${name}-${t}.png`) : path.join(dir, `${String(i).padStart(2, '0')}.png`);
    fs.writeFileSync(file, Buffer.from(url.split(',')[1], 'base64'));
    meta[name].push({ t: +t.toFixed(4), box: r.box, half: r.hbox });
    console.log(`${name} ${i + 1}/${ts.length} t=${t.toFixed(3)} ${r.ms} ms box=${r.box} half=${r.hbox}`);
  }
  console.log(`${name}: ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  await page.close();
  if (!preview) {
    const dest = path.join(outRoot, name);
    fs.rmSync(dest, { recursive: true, force: true });
    fs.mkdirSync(dest, { recursive: true });
    execFileSync('python3', [path.join(here, 'encode.py'), dir, dest, String(F.quality), path.join(outRoot, `${name}-final.jpg`)], { stdio: 'inherit' });
  }
}
await browser.close();
fs.rmSync(tmp, { recursive: true, force: true });
// where the Mac and the half land in each frame (px of the frame): for laying out the page (hero.mjs FRAMES)
if (!preview) {
  const file = path.join(here, 'layout.json');
  const old = only && fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
  fs.writeFileSync(file, JSON.stringify({ ...old, ...meta }));
}
else fs.writeFileSync(path.join(outRoot, 'layout.json'), JSON.stringify(meta));
