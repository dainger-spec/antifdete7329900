// Films the v2 stage (video/stage/<lang>.html) frame by frame: the DOM layer only, at 3840 × 2160, on a
// TRANSPARENT ground (CDP Emulation.setDefaultBackgroundColorOverride, alpha 0), so the studio plates never
// pass through the browser. For each frame:
//   video/.cache/dom/<lang>/NNNN.png   the DOM layer (RGBA; 8-bit straight from Chrome, or 16-bit when several
//                                      180° shutter subframes are averaged — post.py --shutter averages them in
//                                      premultiplied linear light as they arrive)
//   NNNN.behind.png / NNNN.front.png   the two layers of the shots filmed in two (S17: page / chrome)
//   NNNN.json                          the frame's record for post.py: the plate and its frame, the 2D push,
//                                      black ground, the glass reflection, the reeded glass, the depth-of-field
//                                      plane (S18 matrix), grain weight, and the chip / traffic-light masks
//                                      for the palette gate. Frames with no DOM (S02, S19, S21) get a record only.
//
//   node tools/film/capture.mjs ru                          # the whole film (3 browsers; resumes)
//   node tools/film/capture.mjs ru --from 12 --to 16        # part of it (seconds)
//   node tools/film/capture.mjs ru --at 0.5,9.2 [--out DIR] # the frames at these moments
//   node tools/film/capture.mjs ru --screens                # video/.cache/screens/{desktop6,signin,error}.png
//   node tools/film/capture.mjs ru --qa s08 --out DIR       # S08's two halves alone (the zero-diff gate)
//   options: --scale 2 (device pixels per CSS px), --workers 3
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SITE = path.resolve(here, '../..');
const { chromium } = createRequire(path.join(SITE, 'tools/render.mjs'))('playwright');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d; };
const has = (k) => args.includes(`--${k}`);
const lang = args[0] && !args[0].startsWith('--') ? args[0] : 'ru';
const TL = JSON.parse(fs.readFileSync(path.join(here, 'timeline.json'), 'utf8'));
const FPS = TL.fps;
const url = pathToFileURL(path.join(SITE, 'video', 'stage', `${lang}.html`)).href;
const pad = (f) => String(f).padStart(4, '0');

async function open(scale, { w = 1920, h = 1080, transparent = true } = {}) {
  VIEW = { w, h, scale };
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: scale, reducedMotion: 'no-preference' });
  // the stage loads only files next to it; anything else fails the run
  await ctx.route((u) => !u.href.startsWith('file:'), (r) => { console.error(`BLOCKED ${r.request().url()}`); process.exitCode = 1; return r.abort(); });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => { console.error(`pageerror: ${e.message}`); process.exitCode = 1; });
  page.on('console', (m) => { if (m.type() === 'error') console.error(`console: ${m.text()}`); });
  await page.goto(url);
  await page.evaluate(() => window.FILM.ready);
  const cdp = await ctx.newCDPSession(page);
  if (transparent) await cdp.send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
  return { browser, page, cdp };
}
// (a clip with the device scale: without one, CDP returns CSS-pixel-sized pictures whatever the device scale)
let VIEW = { w: 1920, h: 1080, scale: 2 };
const shoot = async (cdp) => Buffer.from((await cdp.send('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: VIEW.w, height: VIEW.h, scale: VIEW.scale } })).data, 'base64');
const write = (file, buf) => { fs.writeFileSync(`${file}.part`, buf); fs.renameSync(`${file}.part`, file); };

// MARK: The screens the renderer lights the Mac with (1920 × 1247, opaque, 1:1)
if (has('screens')) {
  const dir = path.join(SITE, 'video', '.cache', 'screens');
  fs.mkdirSync(dir, { recursive: true });
  const { browser, page, cdp } = await open(1, { w: 1920, h: 1247, transparent: false });
  for (const name of ['desktop6', 'signin', 'error']) {
    await page.evaluate((n) => window.FILM.screen(n), name);
    const file = path.join(dir, `${name}.png`);
    write(file, await shoot(cdp));
    console.log(`WROTE ${path.relative(SITE, file)}`);
  }
  await browser.close();
  process.exit();
}

// MARK: QA states for the gates
if (opt('qa', null) === 's08') {
  const out = path.resolve(opt('out', path.join(SITE, 'video', '.cache', 'gates', lang)));
  fs.mkdirSync(out, { recursive: true });
  const { browser, page, cdp } = await open(+opt('scale', '2'));
  for (const side of ['l', 'r']) {
    await page.evaluate((s) => window.FILM.qa('S08', s), side);
    const file = path.join(out, `s08-${side}.png`);
    write(file, await shoot(cdp));
    console.log(`WROTE ${file}`);
  }
  await browser.close();
  process.exit();
}

// MARK: Frames
const at = opt('at', null);
const scale = +opt('scale', '2');
const dir = path.resolve(opt('out', path.join(SITE, 'video', '.cache', 'dom', lang)));
fs.mkdirSync(dir, { recursive: true });
let frames;
if (at) frames = [...new Set(at.split(',').map((x) => Math.round(+x * FPS)))];
else {
  const from = +opt('from', 0), to = +opt('to', TL.duration);
  frames = [];
  for (let f = Math.round(from * FPS); f < Math.round(to * FPS); f++) frames.push(f);
}
// a frame is done when its record and every layer it names exist (the record is written as the subframes go to
// post.py --shutter, which writes the averaged PNG after it: a run stopped in between leaves the PNG missing)
const complete = (f) => {
  try {
    const r = JSON.parse(fs.readFileSync(path.join(dir, `${pad(f)}.json`), 'utf8'));
    return Object.values(r.files || {}).every((n) => fs.existsSync(path.join(dir, n)));
  } catch { return false; }
};
const todo = has('force') || at ? frames : frames.filter((f) => !complete(f));
const workers = Math.max(1, Math.min(+opt('workers', at ? '1' : '3'), todo.length || 1));
console.log(`${lang}: ${todo.length} frames to film at ${3840 * scale / 2}×${2160 * scale / 2}, ${workers} browser(s) → ${path.relative(SITE, dir) || dir}`);
const t0 = Date.now();
let done = 0;
async function work(w) {
  const mine = todo.filter((_, i) => i % workers === w);
  if (!mine.length) return;
  const { browser, page, cdp } = await open(scale);
  // post.py --shutter: reads "<file> <n>\n" then n PNGs ("<bytes>\n<data>"); writes the averaged 16-bit RGBA
  const py = spawn('python3', ['-I', path.join(here, 'post.py'), '--shutter'], { stdio: ['pipe', 'inherit', 'inherit'] });
  const send = (b) => new Promise((r) => (py.stdin.write(b) ? r() : py.stdin.once('drain', r)));
  for (const f of mine) {
    const { rec, times } = await page.evaluate((x) => window.FILM.plan(x), f);
    rec.files = {};
    rec.scale = scale;
    for (const layer of rec.layers) {
      const name = layer === 'dom' ? `${pad(f)}.png` : `${pad(f)}.${layer}.png`;
      const file = path.join(dir, name);
      rec.files[layer] = name;
      if (times.length === 1) {
        await page.evaluate(([x, F, L]) => window.FILM.seek(x, { f: F, layer: L }), [times[0], f, layer]);
        write(file, await shoot(cdp));
        continue;
      }
      await send(`${file} ${times.length}\n`);
      for (const ts of times) {
        await page.evaluate(([x, F, L]) => window.FILM.seek(x, { f: F, layer: L }), [ts, f, layer]);
        const png = await shoot(cdp);
        await send(`${png.length}\n`);
        await send(png);
      }
    }
    write(path.join(dir, `${pad(f)}.json`), Buffer.from(JSON.stringify(rec)));
    done++;
    if (at) console.log(`frame ${f} (${(f / FPS).toFixed(3)} s, ${rec.shot}, ${times.length} subframe${times.length > 1 ? 's' : ''}, layers ${rec.layers.join('+') || 'none'})`);
    else if (done % 30 === 0) {
      const s = (Date.now() - t0) / 1000;
      console.log(`${done}/${todo.length} frames, ${s.toFixed(0)} s, ~${((todo.length - done) * s / done / 60).toFixed(1)} min left`);
    }
  }
  py.stdin.end();
  await new Promise((r) => py.on('close', r));
  await browser.close();
}
await Promise.all(Array.from({ length: workers }, (_, w) => work(w)));
console.log(`${lang}: filmed ${done} frames in ${((Date.now() - t0) / 60000).toFixed(1)} min`);
