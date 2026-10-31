// Films the v3 stage (video/stage3/<lang>.html) frame by frame: for each frame, FILM.seek(t), a screenshot at twice
// the size (3840 × 2160), and where things move fast several moments of a 180° shutter averaged into one
// (FILM.blurAt) — real motion blur. frames.py brings each frame down to 1920 × 1080 (Lanczos, with a little
// dither so the dark gradients don't band) into video/.cache/frames3/<lang>/; encode.sh makes the film.
//
//   node tools/film3/capture.mjs ru                        # every frame (3 browsers in parallel; resumes)
//   node tools/film3/capture.mjs ru --from 12 --to 16      # part of the film
//   node tools/film3/capture.mjs ru --at 1.5,4,7.2 --out DIR   # a few stills at 1920 × 1080, to look at
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
const lang = args[0] && !args[0].startsWith('--') ? args[0] : 'ru';
const TL = JSON.parse(fs.readFileSync(path.join(here, 'timeline.json'), 'utf8'));
const FPS = TL.fps;
const url = pathToFileURL(path.join(SITE, 'video', 'stage3', `${lang}.html`)).href;

async function open(scale) {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: scale, reducedMotion: 'no-preference' });
  // the stage loads only files next to it; anything else fails the run
  await ctx.route((u) => !u.href.startsWith('file:'), (r) => { console.error(`BLOCKED ${r.request().url()}`); process.exitCode = 1; return r.abort(); });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => console.error(`pageerror: ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error') console.error(`console: ${m.text()}`); });
  await page.goto(url);
  await page.evaluate(() => window.FILM.ready);
  const cdp = await ctx.newCDPSession(page);
  return { browser, page, cdp };
}
const shoot = async (cdp) => Buffer.from((await cdp.send('Page.captureScreenshot', { format: 'png', optimizeForSpeed: true })).data, 'base64');

// MARK: Stills, to look at
const at = opt('at', null);
if (at) {
  const out = path.resolve(opt('out', path.join(SITE, 'video', '.cache', 'stills3', lang)));
  fs.mkdirSync(out, { recursive: true });
  const { browser, page, cdp } = await open(+opt('scale', '1'));
  for (const t of at.split(',').map(Number)) {
    await page.evaluate((x) => window.FILM.seek(x), t);
    const file = path.join(out, `${lang}-${t.toFixed(2)}.png`);
    fs.writeFileSync(file, await shoot(cdp));
    console.log(`WROTE ${file}`);
  }
  await browser.close();
  process.exit();
}

// MARK: The film
const from = +opt('from', 0), to = +opt('to', TL.duration);
const workers = +opt('workers', 3), scale = +opt('scale', 2);
const dir = path.join(SITE, 'video', '.cache', 'frames3', lang);
fs.mkdirSync(dir, { recursive: true });
const all = [];
for (let f = Math.round(from * FPS); f < Math.round(to * FPS); f++) if (!fs.existsSync(path.join(dir, `${String(f).padStart(4, '0')}.png`))) all.push(f);
console.log(`${lang}: ${all.length} frames to film, ${workers} browsers`);
const t0 = Date.now();
let done = 0;
async function work(w) {
  const mine = all.filter((_, i) => i % workers === w);
  if (!mine.length) return;
  const { browser, page, cdp } = await open(scale);
  // frames.py: reads "<file> <n>\n" then n PNGs (each "<bytes>\n<data>"), writes the averaged, scaled frame
  const py = spawn('python3', ['-I', path.join(here, 'frames.py'), '1920', '1080'], { stdio: ['pipe', 'inherit', 'inherit'] });
  const send = (b) => new Promise((r) => (py.stdin.write(b) ? r() : py.stdin.once('drain', r)));
  for (const f of mine) {
    const t = f / FPS;
    const n = await page.evaluate((x) => window.FILM.blurAt(x), t);
    const file = path.join(dir, `${String(f).padStart(4, '0')}.png`);
    await send(`${file} ${n}\n`);
    for (let i = 0; i < n; i++) {
      const ts = n === 1 ? t : t + ((i + 0.5) / n - 0.5) * (0.5 / FPS);
      await page.evaluate((x) => window.FILM.seek(x), ts);
      const png = await shoot(cdp);
      await send(`${png.length}\n`);
      await send(png);
    }
    done++;
    if (done % 30 === 0) {
      const s = (Date.now() - t0) / 1000;
      console.log(`${done}/${all.length} frames, ${s.toFixed(0)} s, ~${((all.length - done) * s / done / 60).toFixed(1)} min left`);
    }
  }
  py.stdin.end();
  await new Promise((r) => py.on('close', r));
  await browser.close();
}
await Promise.all(Array.from({ length: workers }, (_, w) => work(w)));
console.log(`${lang}: filmed ${done} frames in ${((Date.now() - t0) / 60000).toFixed(1)} min → ${path.relative(SITE, dir)}`);
