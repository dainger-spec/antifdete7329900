// The film's opening shot: the same MacBook Pro as the site's hero (tools/hero/renderer.js), rendered as a shot
// of its own — 16:9, 60 frames a second. The closed Mac in the dark; light comes up along its edges; the lid
// opens; the display wakes with the Lumen mark in code; the camera comes round to the front and closer, and the
// mark's left half lifts out of the glass towards us, while the right half stays on the display.
//
//   node tools/film3/hero.mjs                                  # every frame → video/.cache/hero/000.png … (resumes)
//   node tools/film3/hero.mjs --reverse                        # the same from the last frame: run beside the first to halve the wait
//   node tools/film3/hero.mjs --preview DIR --at 0,1.5,3 --scale 0.3 --passes 2    # a few moments, small (seconds)
//
// About 10 s a frame at 1920 × 1080 on 4 CPU cores (SwiftShader). Frames already on disk are kept, so a stopped
// render picks up where it was; delete the folder to render afresh.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SITE = path.resolve(here, '../..');
const { chromium } = createRequire(path.join(SITE, 'tools/render.mjs'))('playwright');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d; };

export const FPS = 60;
export const DURATION = 4.4;                 // seconds; the film uses 0 … 4.4 of it (with room for the cut)
export const W = 1920, H = 1080;

const clamp01 = (x) => Math.max(0, Math.min(1, x));
const smooth = (x) => { x = clamp01(x); return x * x * (3 - 2 * x); };
const lerp = (a, b, t) => a + (b - a) * t;
/// A monotone cubic through keyframes {t, ...numbers or arrays} (as tools/hero/render.mjs): smooth through the
/// keys, never overshooting, at rest on the first key, still moving on the last.
function track(keys, t) {
  t = Math.max(keys[0].t, Math.min(keys[keys.length - 1].t, t));
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

// MARK: The shot, in seconds
// 0–0.9 the light comes up on the closed Mac, seen low from the front left · 0.7–2.0 the lid opens ·
// 1.55–2.15 the display wakes, the mark comes up · 1.0–3.0 the camera rises and comes round to the front ·
// 2.3–4.4 closer and round to the right while the left half lifts out to the left, turning to face us.
const CAM = [
  { t: 0, eye: [-430, 180, 1000], target: [20, 30, 0], fov: 16, shift: [0, 0.04] },
  { t: 0.9, eye: [-400, 220, 1080], target: [15, 42, 0], fov: 16, shift: [0, 0.06] },
  { t: 2.0, eye: [-150, 420, 1500], target: [0, 90, 0], fov: 15, shift: [0, 0.22] },
  { t: 2.9, eye: [100, 470, 1500], target: [-20, 104, 0], fov: 15.5, shift: [0.01, 0.26] },
  { t: 3.8, eye: [380, 420, 1330], target: [-80, 116, 0], fov: 17.5, shift: [0.06, 0.24] },
  { t: 4.4, eye: [500, 400, 1250], target: [-100, 118, 0], fov: 18.5, shift: [0.09, 0.22] },
];
const HALF0 = { t: 0, lift: 0, dx: 0, dy: 0, yaw: 0, pitch: 0, dome: 0 };
const HALF = [
  HALF0, { ...HALF0, t: 2.45 },
  { t: 3.3, lift: 175, dx: -46, dy: -8, yaw: 20, pitch: 2, dome: 0.03 },
  { t: 4.0, lift: 280, dx: -70, dy: -13, yaw: 35, pitch: 0, dome: 0.04 },
  { t: 4.4, lift: 310, dx: -78, dy: -14, yaw: 40, pitch: 0, dome: 0.04 },
];

/// Everything the renderer needs at second s of the shot.
export function params(s, q) {
  const c = track(CAM, s);
  const h = track(HALF, s);
  const lift = clamp01(h.lift / 280);
  const lid = 108 * smooth((s - 0.7) / 1.3);
  const on = smooth((s - 1.55) / 0.6);
  return {
    eye: c.eye, target: c.target, fov: c.fov, shift: c.shift, lid,
    screen: { on, r: 0.33, rows: 13, ghost: 0, bg: 1, rightGain: lerp(1.15, 1.45, smooth(lift)), flat: lerp(0.25, 0.5, smooth(lift)) },
    half: h.lift > 0.05 ? { ...h, gain: 1, glowK: 0.2, glowS: 2 } : null,
    halfGain: lerp(1.5, 1.6, lift), halfLight: lerp(0.5, 2.4, lift),
    pool: 0.6, poolR: 210, bloom: [0.2, 0.07],
    exposure: Math.pow(smooth(s / 0.9), 1.6),
    passes: q.passes, spp: q.spp, seed: 7,
  };
}

// MARK: Run
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const preview = opt('preview', null);
  const scale = +opt('scale', preview ? 0.5 : 1);
  const quality = { passes: +opt('passes', preview ? 4 : 10), spp: +opt('spp', 1) };
  const dir = preview ? path.resolve(preview) : path.join(SITE, 'video/.cache/hero');
  fs.mkdirSync(dir, { recursive: true });
  const frames = Math.round(DURATION * FPS) + 1;
  const list = preview ? opt('at', '0,1.5,3').split(',').map(Number) : Array.from({ length: frames }, (_, i) => i / FPS);
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  const page = await browser.newPage();
  page.on('pageerror', (e) => console.error('pageerror:', e.message.slice(0, 3000)));
  await page.goto(pathToFileURL(path.join(SITE, 'tools/hero/render.html')).href);
  await page.evaluate(() => document.fonts.load('20px "DejaVu Sans Mono"'));
  await page.evaluate(([w, h]) => window.HERO.init(w, h), [Math.round(W * scale), Math.round(H * scale)]);
  const t0 = Date.now();
  let done = 0;
  const order = [...list.entries()];
  if (args.includes('--reverse')) order.reverse();
  for (const [i, s] of order) {
    const file = preview ? path.join(dir, `hero-${s}.png`) : path.join(dir, `${String(i).padStart(3, '0')}.png`);
    if (!preview && fs.existsSync(file)) continue;
    const r = await page.evaluate((o) => window.HERO.frame(o), params(s, quality));
    const url = await page.evaluate(() => window.HERO.image());
    fs.writeFileSync(file + '.part', Buffer.from(url.split(',')[1], 'base64'));
    fs.renameSync(file + '.part', file);
    done++;
    console.log(`hero ${i + 1}/${list.length} s=${s.toFixed(3)} ${r.ms} ms`);
  }
  console.log(`hero: ${done} frames in ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  await browser.close();
}
