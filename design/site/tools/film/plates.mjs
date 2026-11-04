// The film's rendered plates (spec v2 §5): the MacBook Pro and the graphite studio from our own WebGL2 renderer
// (tools/hero/renderer.js + codeart.js in headless Chromium), written as 16-bit sRGB PNG for post.py. Replaces
// tools/film/hero.mjs. Every plate is a named shot below: camera keys, lid, the floating half, the rig, the
// picture on the display.
//
//   node tools/film/plates.mjs R1                      # every frame → video/.cache/plates/R1/0000.png … (resumes)
//   node tools/film/plates.mjs R1 --frames 160-169     # part of it (a-b inclusive, or a list: 0,90,162)
//   node tools/film/plates.mjs PL-CARD --preview video/.cache/lookdev --scale 0.5 --passes 4
//   node tools/film/plates.mjs --list                  # the shots
//
// Output: video/.cache/plates/<ID>/NNNN.png (16-bit RGB, sRGB-encoded, tonemapped; NNNN = frame index within
// the plate; written atomically, existing frames are skipped unless the quality asked for changed) and
// video/.cache/plates/<ID>.json:
//   { id, w, h, fps: 60, filmFrom, frames: [{ i, film, display, notch, radius, cam }] }
// display: the active area's corners (top-left, top-right, bottom-right, bottom-left) in plate px (origin at the
// plate's top-left corner, y down, pixel centres at +0.5); notch: its polygon; radius: the top corners' radius
// in px; cam: the camera and lid, so HERO.corners() (or cornersAt() below) gives subframe corners. display,
// notch and radius are null on plates without the Mac. With --preview the frames go to that folder instead, as
// <ID>-NNNN.png (16-bit) with an 8-bit -view.png to look at and a -cov.png (1 on the empty studio, 0 on the
// Mac), plus <ID>.json there.
//
// Options: --scale s (plate size × s), --passes n, --spp n, --screen file.png (the picture on the display, for
// tests), --drawn (draw the display's pixels: the checkerboard test), --at s,s (preview at render seconds),
// --force (render the frames asked for even if they are on disk at this quality).
//
// Sequences (R1, R2, R3) carry motion blur from the renderer's shutter: each pass sees the camera, lid and half at
// its own moment of a 180° shutter centred on the frame (paramsFor() gives o.a / o.b at i ∓ 0.25), as the stage's
// DOM subframes are. Every Mac plate has the detail on (key legends, Touch ID, the trackpad's bevel, the anodised
// micro-texture); R1 and R3 add the satin floor reflection (spec v2 §5.6–9).
// Measured at 1920 × 1080 and 12 passes on 4 shared CPU cores (SwiftShader): R1 about 31 s a frame without the
// floor reflection, 35–37 s with it; R2's end pose about 32 s; the first frame in a run adds ~6 s of shader compiling.
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SITE = path.resolve(here, '../..');
export const FPS = 60;
export const CACHE = path.join(SITE, 'video/.cache');

// MARK: Curves
const clamp01 = (x) => Math.max(0, Math.min(1, x));
const smooth = (x) => { x = clamp01(x); return x * x * (3 - 2 * x); };
const easeInOutCubic = (x) => { x = clamp01(x); return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
const sineInOut = (x) => 0.5 - 0.5 * Math.cos(Math.PI * clamp01(x));
const lerp = (a, b, t) => a + (b - a) * t;
const lerpv = (a, b, t) => a.map((v, i) => lerp(v, b[i], t));
/// A monotone cubic through keyframes {t, ...numbers or arrays} (Fritsch–Carlson tangents, as tools/hero): smooth
/// through the keys, never overshooting, at rest on the first key, still moving on the last.
export function track(keys, t) {
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

// MARK: The renderer's math in Node (corners without a browser)
let nodeHero = null;
/// tools/hero/renderer.js loaded in a vm with a stub document: HERO.corners() and HERO.display() are pure.
export function hero() {
  if (!nodeHero) {
    const stub = { getContext: () => null };
    const ctx = { document: { getElementById: () => null, createElement: () => ({ ...stub }) }, performance, console };
    ctx.window = ctx;
    vm.createContext(ctx);
    vm.runInContext(fs.readFileSync(path.join(SITE, 'tools/hero/renderer.js'), 'utf8'), ctx, { filename: 'renderer.js' });
    nodeHero = ctx.HERO;
  }
  return nodeHero;
}

// MARK: Rigs (spec §2 Light). Boxes: centre c, half width w, half height h, intensity k, aimed at `at` (the Mac
// by default). mac / cyc: how strongly a box lights the Mac and the cyclorama (1 by default): the reflection
// cards stand in for the lit studio itself, so they light the Mac only; the cyc multipliers on the Mac's boxes
// are the flags a gaffer would hang to keep their spill off the floor (tuned to the plate targets).
export const RIGS = {};
RIGS.graphite = [
  { name: 'overhead', c: [0, 1300, -250], w: 800, h: 300, k: 2.2, cyc: 0.05 },
  { name: 'rim', c: [0, 1250, -1600], w: 1300, h: 50, k: 11, cyc: 0.38 },
  { name: 'kickL', c: [-1300, 1300, -1000], w: 200, h: 600, k: 2.6, cyc: 0.05 },
  { name: 'kickR', c: [1300, 1250, -900], w: 200, h: 560, k: 2.0, cyc: 0.05 },
  { name: 'front', c: [0, 160, 1700], w: 1100, h: 60, k: 1.2, cyc: 0.05 },
  { name: 'key', c: [-1100, 900, 1100], w: 450, h: 450, k: 0.8, cyc: 0.05 },
  // the wall's glow. Spec: c [0, 2200, -600] at [0, 900, -2700] k 1.6; lowered and aimed at the cove so the
  // horizon band reads in the low R1/R2/R3 views too (fitted per light: PL-CARD wall 11.7, band 27, floor 19.6;
  // R1 band 24.4, floor 17–18; R2 band 25, floor 17.6)
  { name: 'backdrop', c: [0, 1800, -400], w: 1800, h: 300, at: [0, 150, -2200], k: 1.2, mac: 0 },
  // the reflection cards (spec: back k 0.30). The back card stands where the graphite wall is seen in frame; at
  // 0.30 it mirrors a wall ~30× brighter than the one on screen and the closed lid reads as flat grey (sRGB 134);
  // at 0.08 the lid keeps a broad graded sheen (about 90) and the open Mac is unchanged
  { name: 'cardBack', c: [0, 700, -2600], w: 3200, h: 1400, k: 0.08, cyc: 0 },
  { name: 'cardTop', c: [0, 2200, 600], w: 2400, h: 1200, k: 0.20, cyc: 0 },
];
// «Night» (S13): the display is the key light. Spec: every box × 0.2, the rim × 0.45; at a fixed exposure that
// leaves the keys at sRGB 18 under the rig alone, so the dark error page could not bring them to 8–12. Both
// scaled by 0.4 (× 0.08, rim × 0.18) with the display at gain 0.8: keys ≈ 50 under the white page, ≈ 10 after.
RIGS.night = RIGS.graphite.map((l) => ({ ...l, k: l.k * (l.name === 'rim' ? 0.18 : 0.08) }));

// Everything a plate shares: the cyclorama, float output, no edge fade or dither (post does grain and dither),
// constant exposure, bloom only inside the renderer (threshold 0.9 linear, weights 0.06 / 0.02).
const BASE = { cyc: true, float: true, strat: true, exposure: 1, bloomTh: 0.9, bloom: [0.06, 0.02], spp: 1, contact: [0.3, 60] };
// the Mac's detail (spec v2 §5.7–8): legends (#8E8E93 at 35%), Touch ID's ring, the trackpad's bevel, the anodising
const DETAIL = { legends: true, fine: true, micro: true };
// the shutter: 180° at 60 fps, centred on the frame (as the stage's DOM subframes: t ± 0.25 frame)
export const SHUTTER = 0.5;
const MOVING = ['eye', 'target', 'fov', 'shift', 'lid', 'half'];
const NEUTRAL_MARK = { look: 'neutral', r: 0.33, rows: 20 };
// the mark's display brightness. The inks' white (236) is 0.839 linear, so at 1.15 it is 0.964, over the 0.9 bloom
// threshold: the thin code characters still average under it in the bloom's 4 × 4 pre-filter (R1 162: bloom adds
// 0 levels), but the solid glyph S19 fills into does not (R3 59 at 1.15: a halo of +9.7 / +5.3 / +3.3 / +2.0 levels
// at 2–4 / 4–8 / 8–16 / 16–30 px of a 960 px frame). So R3 eases to SOLID_GAIN as it fills: 0.9 / 0.839 → 1.07,
// which measured +2.0 / +0.3 / +0.3 / 0 (the edge's own anti-aliasing), no halo.
const MARK_GAIN = 1.15, SOLID_GAIN = 1.07;

// MARK: Shots. params(s, i): renderer options at render second s (frame i). still: one frame.
const R1_CAM = [
  { t: 0, eye: [560, 300, 1150], target: [0, 30, 0], fov: 16, shift: [0.04, 0.06] },
  { t: 1.4, eye: [520, 420, 1220], target: [-30, 75, 0], fov: 16.3, shift: [0.0587, 0.1253] },
  { t: 3.0, eye: [470, 560, 1280], target: [-70, 105, 0], fov: 17, shift: [0.08, 0.2] },
];
const HALF_OUT = { lift: 280, dx: -70, dy: -13, yaw: 35, pitch: 0, dome: 0.04 };
const HALF_IN = { lift: 0, dx: 0, dy: 0, yaw: 0, pitch: 0, dome: 0 };
const R1_HALF = [{ t: 0, ...HALF_IN }, { t: 1.9, ...HALF_IN }, { t: 3.0, ...HALF_OUT }];
// S19: the half glides back and seats at s 0.5 (slow start, firm stop: the last key is reached still moving)
const R3_HALF = [{ t: 0, ...HALF_OUT }, { t: 0.5, ...HALF_IN }];
// S19's camera continues S02's: from R1's end pose, moving at s 0 (a virtual key before it), easing into the last
const R3_A = { eye: [470, 560, 1280], target: [-70, 105, 0], fov: 17, shift: [0.08, 0.2] };
const R3_B = { eye: [452, 540, 1236], target: [-60, 104, 0], fov: 17, shift: [0.08, 0.2] };
const R3_CAM = [{ t: -1, eye: lerpv(R3_A.eye, R3_B.eye, -1), target: lerpv(R3_A.target, R3_B.target, -1), fov: 17, shift: R3_A.shift }, { t: 0, ...R3_A }, { t: 1, ...R3_B }];

/// The mark on the display while the left half is out (or coming home): the half that stays reads as clearly
/// as the one that left.
function mark(on, lift, fill = 0) {
  return { ...NEUTRAL_MARK, on, fill, rightGain: lerp(1.0, 1.3, smooth(lift)), flat: lerp(0.2, 0.45, smooth(lift)) };
}
function halfOf(h) {
  return h.lift > 0.05 ? { ...h, gain: 1, glowK: 0 } : null;
}

/// S05's pull-out: from the display normal (the active area exactly (0, -83.5)–(1920, 1163.5) at 1920 × 1080)
/// to 3/4 front-left; azimuth, elevation, distance, target and fov eased together over s 0–1.3.
function r2Camera(s) {
  const fov = 18, asp = 16 / 9;
  const d = hero().display(108);
  const dist0 = (d.w / 2) / (Math.tan(fov / 2 * Math.PI / 180) * asp);
  const sph = (v) => { const r = Math.hypot(...v); return { az: Math.atan2(v[0], v[2]), el: Math.asin(v[1] / r), r }; };
  const a = { ...sph(d.normal), r: dist0, target: d.centre };
  const endEye = [-460, 415, 1230], endTarget = [0, 100, 0];
  const b = { ...sph(endEye.map((v, i) => v - endTarget[i])), target: endTarget };
  const u = sineInOut(s / 1.3);
  const az = lerp(a.az, b.az, u), el = lerp(a.el, b.el, u), r = lerp(a.r, b.r, u), target = lerpv(a.target, b.target, u);
  const eye = [target[0] + r * Math.cos(el) * Math.sin(az), target[1] + r * Math.sin(el), target[2] + r * Math.cos(el) * Math.cos(az)];
  return { eye, target, fov, shift: [0, 0] };
}

export const SHOTS = {
  // the empty studio for the type cards (defocused in post): S01, S03, S06–S10, S16, S17, S20
  'PL-CARD': { w: 3840, h: 2160, still: true, passes: 24, filmFrom: null, rig: 'graphite',
    params: () => ({ eye: [0, 300, 2200], target: [0, 260, -2400], fov: 22, lid: 108, mac: false }) },
  // the floor from about 58° above, under the S18 tile plane
  'PL-FLOOR': { w: 3840, h: 2160, still: true, passes: 24, filmFrom: 1470, rig: 'graphite',
    params: () => ({ eye: [0, 1270, 700], target: [0, 0, -100], fov: 30, lid: 108, mac: false }) },
  // S13: low and close from front-right, the white sign-in page (W) and Safari's dark error page (D) as the key light
  'PL-W': { w: 3840, h: 2160, still: true, passes: 32, filmFrom: 1080, rig: 'night', screen: 'signin',
    params: () => ({ eye: [320, 150, 640], target: [-20, 85, -40], fov: 24, lid: 108, screen: { image: true, on: 1, drawn: false }, screenGain: 0.8, cacheGrid: [8, 8], spp: 2 }) },
  'PL-D': { w: 3840, h: 2160, still: true, passes: 32, filmFrom: 1110, rig: 'night', screen: 'error',
    params: () => ({ eye: [320, 150, 640], target: [-20, 85, -40], fov: 24, lid: 108, screen: { image: true, on: 1, drawn: false }, screenGain: 0.8, cacheGrid: [8, 8], spp: 2 }) },
  // S02: the Mac opens, the display wakes with the mark, the left half lifts out (render s = film − 1.5)
  R1: { w: 1920, h: 1080, frames: 180, passes: 12, filmFrom: 90, rig: 'graphite',
    params: (s) => {
      const c = track(R1_CAM, s), h = track(R1_HALF, s);
      return { ...c, lid: 108 * easeInOutCubic((s - 0.3) / 1.1), screen: mark(smooth((s - 1.1) / 0.5), clamp01(h.lift / 280)), screenGain: MARK_GAIN, half: halfOf(h), halfGain: 1.3, halfLight: 0.6, reflect: true };
    } },
  // S05: the pull-out from the six windows (composited by the stage onto the exported corners)
  R2: { w: 1920, h: 1080, frames: 90, passes: 12, filmFrom: 420, rig: 'graphite', screen: 'desktop6',
    params: (s) => ({ ...r2Camera(s), lid: 108, screen: { image: true, on: 1, drawn: false }, screenGain: 1.2, cacheGrid: [6, 6], spp: 2 }) },
  // S19: the half comes home, seats at s 0.5 (film 27.0), the characters fill into the solid glyph over s 0.5–0.667
  R3: { w: 1920, h: 1080, frames: 60, passes: 12, filmFrom: 1590, rig: 'graphite',
    params: (s) => {
      const c = track(R3_CAM, s), h = track(R3_HALF, s), fill = smooth((s - 0.5) / (0.667 - 0.5));
      return { ...c, lid: 108, screen: mark(1, clamp01(h.lift / 280), fill), screenGain: lerp(MARK_GAIN, SOLID_GAIN, fill), half: halfOf(h), halfGain: 1.3, halfLight: 0.6, reflect: true };
    } },
};

/// Renderer options for frame i of a shot (s = i / 60; a fractional i gives subframe moments). Sequences get the
/// shutter's two ends as o.a / o.b (the moving parameters at i ∓ SHUTTER / 2); q.shutter: false leaves them out.
export function paramsFor(id, i, q = {}) {
  const S = SHOTS[id];
  if (!S) throw new Error(`no shot ${id}`);
  const s = (S.still ? 0 : i) / FPS;
  const p = S.params(s, i);
  const o = { ...BASE, ...(p.mac === false ? {} : DETAIL), lights: RIGS[S.rig], ...p, passes: q.passes ?? S.passes, spp: q.spp ?? p.spp ?? BASE.spp, seed: 7 + Math.floor(i) };
  if (!S.still && q.shutter !== false) {
    const end = (di) => { const e = S.params((i + di) / FPS, i + di); const m = {}; for (const k of MOVING) m[k] = e[k] ?? (k === 'shift' ? [0, 0] : null); m.half = e.half || o.half || null; return m; };
    o.a = end(-SHUTTER / 2); o.b = end(SHUTTER / 2);
  }
  return o;
}

/// The display's corners, notch and radius at frame i (fractional for subframes) of a shot, in px of a w × h plate.
export function cornersAt(id, i, w = SHOTS[id].w, h = SHOTS[id].h) {
  const p = paramsFor(id, i, { shutter: false });
  if (p.mac === false) return { display: null, notch: null, radius: null };
  return hero().corners({ ...p, w, h });
}

const round = (v) => (Array.isArray(v) ? v.map(round) : typeof v === 'number' ? +v.toFixed(4) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, round(x)])) : v);
/// The plate's sidecar: every frame's geometry (no rendering).
export function sidecar(id, w = SHOTS[id].w, h = SHOTS[id].h) {
  const S = SHOTS[id];
  const n = S.still ? 1 : S.frames;
  const frames = [];
  for (let i = 0; i < n; i++) {
    const p = paramsFor(id, i, { shutter: false });
    const c = cornersAt(id, i, w, h);
    frames.push({ i, film: S.filmFrom == null ? null : S.filmFrom + i, display: c.display, notch: c.notch, radius: c.radius, cam: round({ eye: p.eye, target: p.target, fov: p.fov, shift: p.shift || [0, 0], lid: p.lid }) });
  }
  return { id, w, h, fps: FPS, filmFrom: S.filmFrom, still: !!S.still, rig: S.rig, shutter: S.still ? 0 : SHUTTER, frames };
}

// MARK: Rendering
/// The picture on the display: video/.cache/screens/<name>.png as a data URL (no file:// canvas tainting), or
/// a flat #1C1C1E desktop when it is missing.
function screenURL(name, override) {
  const file = override || (name && path.join(CACHE, 'screens', `${name}.png`));
  if (file && fs.existsSync(file)) return { url: 'data:image/png;base64,' + fs.readFileSync(file).toString('base64'), file };
  return { url: null, file: null };
}

/// Renders frames of a shot. opts: { id, frames: [i...], scale, passes, spp, preview (dir), screen (file),
/// drawn, lights }. Resolves when every frame is on disk.
export async function render(opts) {
  const S = SHOTS[opts.id];
  const scale = opts.scale ?? 1;
  const W = Math.round(S.w * scale), H = Math.round(S.h * scale);
  const passes = opts.passes ?? S.passes, spp = opts.spp ?? paramsFor(opts.id, 0).spp;
  const preview = opts.preview ? path.resolve(opts.preview) : null;
  const dir = preview || path.join(CACHE, 'plates', opts.id);
  fs.mkdirSync(dir, { recursive: true });
  const quality = { passes, spp, w: W, h: H, renderer: fs.statSync(path.join(SITE, 'tools/hero/renderer.js')).mtimeMs };
  // the sidecar first (geometry needs no rendering)
  const side = sidecar(opts.id, W, H);
  const sideFile = preview ? path.join(dir, `${opts.id}.json`) : path.join(CACHE, 'plates', `${opts.id}.json`);
  fs.writeFileSync(sideFile + '.part', JSON.stringify(side));
  fs.renameSync(sideFile + '.part', sideFile);
  const name = (i) => (preview ? path.join(dir, `${opts.id}-${String(i).padStart(4, '0')}.png`) : path.join(dir, `${String(i).padStart(4, '0')}.png`));
  // resume: keep frames already rendered at this quality. quality.json records each frame's quality as that frame
  // is written (frames: { i: "12p 1spp 1920x1080" }), so a run that changes the quality and stops part-way, or
  // renders only some frames, never leaves frames of the old quality labelled as the new one
  const qFile = path.join(dir, preview ? `${opts.id}.quality.json` : 'quality.json');
  const qKey = (q) => `${q.passes}p ${q.spp}spp ${q.w}x${q.h}`;
  let oldQ = null;
  try { oldQ = JSON.parse(fs.readFileSync(qFile, 'utf8')); } catch { oldQ = null; }
  // (a quality.json from before the per-frame record covered every frame on disk)
  const legacy = oldQ && !oldQ.frames && oldQ.passes != null ? qKey(oldQ) : null;
  const all = Array.from({ length: S.still ? 1 : S.frames }, (_, i) => i);
  const qState = { ...quality, frames: {} };
  for (const i of all) { const q = oldQ && oldQ.frames ? oldQ.frames[i] : legacy; if (q && fs.existsSync(name(i))) qState.frames[i] = q; }
  const want = qKey(quality);
  // (merged with the file as it is now, so two runs on different frames of one plate keep each other's records)
  const mine = {};
  const saveQ = () => {
    let disk = null;
    try { disk = JSON.parse(fs.readFileSync(qFile, 'utf8')); } catch { disk = null; }
    const out = { ...qState, frames: { ...(disk && disk.frames ? disk.frames : qState.frames), ...mine } };
    const tmp = `${qFile}.${process.pid}.part`;
    fs.writeFileSync(tmp, JSON.stringify(out)); fs.renameSync(tmp, qFile);
  };
  const list = (opts.frames || all).filter((i) => preview || opts.force || qState.frames[i] !== want || !fs.existsSync(name(i)));
  const stale = list.filter((i) => !preview && fs.existsSync(name(i)) && qState.frames[i] && qState.frames[i] !== want);
  if (stale.length) console.log(`${opts.id}: ${stale.length} frame(s) on disk at another quality (${[...new Set(stale.map((i) => qState.frames[i]))].join(', ')}), re-rendering at ${want}`);
  saveQ();
  if (!list.length) { console.log(`${opts.id}: nothing to render`); return { dir, side: sideFile }; }

  const { chromium } = createRequire(path.join(SITE, 'tools/render.mjs'))('playwright');
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  const page = await browser.newPage();
  page.on('pageerror', (e) => console.error('pageerror:', e.message.slice(0, 3000)));
  await page.goto(pathToFileURL(path.join(SITE, 'tools/hero/render.html')).href);
  await page.evaluate(() => Promise.all([document.fonts.load('20px "DejaVu Sans Mono"'), document.fonts.load('500 40px Inter')]));
  await page.evaluate(([w, h]) => window.HERO.init(w, h), [W, H]);
  const scr = screenURL(S.screen, opts.screen);
  if (S.screen || opts.screen) {
    if (scr.url) await page.evaluate((u) => window.HERO.setScreen(u), scr.url);
    else {
      console.log(`${opts.id}: no ${S.screen}.png in video/.cache/screens, a flat #1C1C1E screen`);
      await page.evaluate(() => { const c = document.createElement('canvas'); c.width = 1920; c.height = 1247; const x = c.getContext('2d'); x.fillStyle = '#1C1C1E'; x.fillRect(0, 0, c.width, c.height); return window.HERO.setScreen(c.toDataURL()); });
    }
  }
  const writer = spawn('python3', ['-I', path.join(here, 'png16.py')], { stdio: ['pipe', 'pipe', 'inherit'] });
  let pending = null, outBuf = '';
  writer.stdout.on('data', (d) => { outBuf += d; let k; while ((k = outBuf.indexOf('\n')) >= 0) { const line = outBuf.slice(0, k); outBuf = outBuf.slice(k + 1); if (pending && line.startsWith('WROTE')) { const p = pending; pending = null; p(); } } });
  const send = (b) => new Promise((r) => (writer.stdin.write(b) ? r() : writer.stdin.once('drain', r)));
  const ch = preview ? 4 : 3;
  const t0 = Date.now();
  for (const i of list) {
    const p = { ...paramsFor(opts.id, i, { passes, spp: opts.spp }), ...(opts.lights ? { lights: opts.lights } : {}) };
    if (opts.drawn && p.screen) p.screen = { ...p.screen, drawn: true };
    if (opts.override) Object.assign(p, opts.override);
    const r = await page.evaluate((o) => window.HERO.frame(o), p);
    // the float frame → uint16 in the page, then across in chunks (base64)
    const bytes = await page.evaluate((ch) => {
      const f = window.HERO.raw(), n = f.length / 4, u = new Uint16Array(n * ch);
      for (let k = 0, j = 0; k < n; k++) for (let c = 0; c < ch; c++, j++) { const v = f[k * 4 + c]; u[j] = Math.round((v < 0 ? 0 : v > 1 ? 1 : v) * 65535); }
      window.__plate = new Uint8Array(u.buffer);
      return window.__plate.length;
    }, ch);
    const parts = [], CH = 6 << 20;
    for (let off = 0; off < bytes; off += CH) {
      const b64 = await page.evaluate(([a, b]) => { const s = window.__plate.subarray(a, b); let bin = ''; for (let k = 0; k < s.length; k += 0x8000) bin += String.fromCharCode.apply(null, s.subarray(k, k + 0x8000)); return btoa(bin); }, [off, Math.min(bytes, off + CH)]);
      parts.push(Buffer.from(b64, 'base64'));
    }
    await page.evaluate(() => { window.__plate = null; });
    const file = name(i);
    const extra = preview ? ` ${file.replace(/\.png$/, '-view.png')} ${file.replace(/\.png$/, '-cov.png')}` : '';
    const done = new Promise((res) => { pending = res; });
    await send(`${file} ${W} ${H} ${ch}${extra}\n`);
    for (const b of parts) await send(b);
    await done;
    qState.frames[i] = mine[i] = want; saveQ();
    console.log(`${opts.id} ${i} (film ${S.filmFrom == null ? '-' : S.filmFrom + i}) ${W}x${H} ${passes}p ${r.ms} ms → ${path.relative(SITE, file)}`);
  }
  writer.stdin.end();
  await new Promise((r) => writer.on('close', r));
  await browser.close();
  console.log(`${opts.id}: ${list.length} frame(s) in ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  return { dir, side: sideFile };
}

// MARK: CLI
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const opt = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d; };
  if (args.includes('--list') || !args[0] || args[0].startsWith('--')) {
    for (const [id, S] of Object.entries(SHOTS)) console.log(`${id.padEnd(9)} ${S.w}x${S.h} ${S.still ? 'still' : `${S.frames} frames`} ${S.passes} passes, film ${S.filmFrom ?? '-'}, rig ${S.rig}${S.screen ? `, screen ${S.screen}` : ''}`);
    process.exit(0);
  }
  const id = args[0];
  if (!SHOTS[id]) { console.error(`no shot ${id}; one of ${Object.keys(SHOTS).join(', ')}`); process.exit(1); }
  const S = SHOTS[id];
  let frames = null;
  const fr = opt('frames', null), at = opt('at', null);
  if (fr) frames = fr.includes('-') ? (() => { const [a, b] = fr.split('-').map(Number); return Array.from({ length: b - a + 1 }, (_, k) => a + k); })() : fr.split(',').map(Number);
  if (at) frames = at.split(',').map((s) => Math.round(+s * FPS));
  const n = S.still ? 1 : S.frames;
  if (frames && frames.some((i) => i < 0 || i >= n)) { console.error(`${id}: frames are 0–${n - 1}`); process.exit(1); }
  const preview = opt('preview', null);
  const scale = +opt('scale', 1);
  if (!preview && scale !== 1) console.warn(`${id}: a ${scale}× plate in video/.cache/plates is a test plate; render it again at 1 for the film`);
  await render({ id, frames, scale, preview, passes: opt('passes', null) ? +opt('passes') : undefined, spp: opt('spp', null) ? +opt('spp') : undefined, screen: opt('screen', null), drawn: args.includes('--drawn'), force: args.includes('--force') });
}
