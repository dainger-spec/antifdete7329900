// The hero's image sequence: a MacBook Pro in Space Black whose display shows the Lumen mark in code; as you
// scroll, the camera comes round and the mark's left half lifts out of the glass towards you as a hemisphere
// of characters, while the right half stays on the display. Rendered offline with our own WebGL2 renderer
// (renderer.js + codeart.js, opened in headless Chromium), then encoded to WebP with Pillow.
//
// Regenerate (from design/site; ~25–35 min on 4 CPU cores with SwiftShader):
//   node tools/hero/render.mjs                       # both framings → prototype/assets/scenes/hero/
//   node tools/hero/render.mjs --only d              # desktop only (d) or phone only (m)
// Look at a few moments quickly, small and noisy, into a scratch folder (not the site):
//   node tools/hero/render.mjs --preview /tmp/hero --at 0,0.4,1 --scale 0.5 --passes 4
//
// Output: hero/d/00.webp … (landscape 16:10, for screens wider than tall) and hero/m/00.webp … (portrait
// 9:16, phones), plus hero/d-final.jpg and hero/m-final.jpg (the last frame, for the still page: no
// JavaScript, Reduce Motion, screenshots). Needs Playwright's Chromium and python3 with Pillow (WebP).
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
/// Catmull-Rom through keyframes {t, ...numbers or arrays}: smooth, no stops at the keys.
function track(keys, t) {
  let i = 0; while (i < keys.length - 2 && t > keys[i + 1].t) i++;
  const k0 = keys[Math.max(0, i - 1)], k1 = keys[i], k2 = keys[i + 1], k3 = keys[Math.min(keys.length - 1, i + 2)];
  const u = clamp01((t - k1.t) / (k2.t - k1.t));
  const cr = (p0, p1, p2, p3) => 0.5 * ((2 * p1) + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u + (-p0 + 3 * p1 - 3 * p2 + p3) * u * u * u);
  const out = {};
  for (const key of Object.keys(k1)) {
    if (key === 't') continue;
    const v = k1[key];
    out[key] = Array.isArray(v) ? v.map((_, j) => cr(k0[key][j], v[j], k2[key][j], k3[key][j])) : cr(k0[key], v, k2[key], k3[key]);
  }
  return out;
}

const FRAMINGS = {
  // Landscape: the Mac low under the headline, nearly square-on; then closer and round to its right while
  // the half comes out to the left, into the space the words have left.
  d: {
    w: 1920, h: 1200, frames: 72, quality: 80,
    half: { lift: 250, dx: -80, dy: -18, yaw: 34, pitch: 14 },          // out of the glass, to the left, turned to us
    cam: [
      { t: 0, eye: [80, 250, 1500], target: [0, 104, 0], fov: 18.5, shift: [0, 0.45] },
      { t: 0.3, eye: [200, 280, 1320], target: [-10, 108, 0], fov: 18, shift: [0, 0.1] },
      { t: 0.62, eye: [540, 290, 1080], target: [-90, 118, 0], fov: 22, shift: [0.12, 0.16] },
      { t: 1, eye: [580, 280, 1040], target: [-100, 116, 0], fov: 22.5, shift: [0.14, 0.21] },
    ],
  },
  // Portrait: closer and from the right from the start, so the Mac fills the width under the words; the half
  // rises into the upper half of the screen as the words go.
  m: {
    w: 1080, h: 1920, frames: 60, quality: 74,
    half: { lift: 380, dx: 20, dy: 110, yaw: 25, pitch: 22 },            // out of the glass and up, into the tall space above
    cam: [
      { t: 0, eye: [380, 330, 1300], target: [-10, 100, 0], fov: 36, shift: [0.05, 0.37] },
      { t: 0.3, eye: [400, 320, 1290], target: [-15, 115, 0], fov: 36, shift: [0.05, 0.22] },
      { t: 0.62, eye: [415, 305, 1260], target: [-28, 145, 0], fov: 37.5, shift: [0.15, 0.09] },
      { t: 1, eye: [420, 300, 1250], target: [-30, 150, 0], fov: 37, shift: [0.16, 0.08] },
    ],
  },
};

/// Everything the renderer needs at moment t of a framing.
function params(F, t, q) {
  const c = track(F.cam, ease(t));
  const lift = ease((t - 0.3) / 0.5);          // the half comes out between t 0.3 and 0.8
  const out = lift > 0.0005;
  return {
    eye: c.eye, target: c.target, fov: c.fov, shift: c.shift, lid: 108,
    screen: { on: 1, r: 0.33, rows: 13, ghost: smooth((t - 0.32) / 0.4) },
    half: out ? { lift: lerp(0, F.half.lift, lift), dx: lerp(0, F.half.dx, lift), dy: lerp(0, F.half.dy, lift), yaw: lerp(0, F.half.yaw, lift), pitch: lerp(0, F.half.pitch, lift), dome: lerp(0, 0.42, smooth(lift * 1.4)), gain: 1, glowK: lerp(0.35, 0.6, lift) } : null,
    halfGain: lerp(1.6, 1.75, lift), halfLight: lerp(0.5, 3.0, lift),
    passes: q.passes, spp: q.spp, exposure: 1, pool: 0.9, seed: 7,   // the same samples in every frame: grain stays put instead of boiling as you scroll
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
    meta[name].push(r.box);
    console.log(`${name} ${i + 1}/${ts.length} t=${t.toFixed(3)} ${r.ms} ms box=${r.box}`);
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
