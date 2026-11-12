// Films the stage frame by frame: node design/promo/tools/capture.mjs [--scale 2] [--workers 4] [--fps 60]
//   [--from 0] [--to <end>] [--no-blur] [--out design/promo/.cache/frames]
// Each frame is drawn by time alone (stage/index.html, Film.render(t)) and captured as JPEG at `scale` × 1920×1080;
// where a move is fast (Film.samples(t) > 1) the frame is several moments inside a 180° shutter, kept as
// f<frame>_<sub>.jpg, which tools/compose.py averages. Frames already on disk are kept, so a run can be resumed.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const scale = parseFloat(opt('--scale', '2'));
const workers = parseInt(opt('--workers', '4'), 10);
const fps = parseInt(opt('--fps', '60'), 10);
const blur = !args.includes('--no-blur');
const out = path.resolve(opt('--out', path.join(here, '..', '.cache', `frames-${scale}x`)));
const stage = pathToFileURL(path.resolve(here, '..', 'stage', 'index.html')).href + '?capture=1';
fs.mkdirSync(out, { recursive: true });

async function open() {
  const browser = await chromium.launch({ args: ['--font-render-hinting=none', '--disable-lcd-text'] });
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: scale });
  page.on('pageerror', (e) => console.error('[pageerror]', e.message));
  await page.route('**/*', (route) => (route.request().url().startsWith('file://') ? route.continue() : route.abort()));
  await page.goto(stage);
  await page.waitForFunction(() => window.__ready === true);
  const cdp = await page.context().newCDPSession(page);
  return { browser, page, cdp };
}

const first = await open();
const duration = await first.page.evaluate(() => window.Film.duration());
const from = Math.round(parseFloat(opt('--from', '0')) * fps);
const to = Math.min(Math.round(parseFloat(opt('--to', String(duration))) * fps), Math.floor(duration * fps - 1e-6) + 1);
// how many moments each frame is made of
const plan = await first.page.evaluate(({ from, to, fps, blur }) => {
  const list = [];
  for (let n = from; n < to; n++) list.push(blur ? window.Film.samples(n / fps) : 1);
  return list;
}, { from, to, fps, blur });
fs.writeFileSync(path.join(out, 'plan.json'), JSON.stringify({ fps, scale, from, to, samples: plan }));
const total = plan.reduce((a, b) => a + b, 0);
console.log(`frames ${from}…${to - 1} (${((to - from) / fps).toFixed(2)} s), ${total} captures at ${1920 * scale}×${1080 * scale}, ${workers} workers → ${out}`);

let next = from, done = 0;
const started = Date.now();
async function worker(w) {
  const { browser, page, cdp } = w === 0 ? first : await open();
  for (;;) {
    const n = next++;
    if (n >= to) break;
    const S = plan[n - from];
    for (let s = 0; s < S; s++) {
      const file = path.join(out, `f${String(n).padStart(5, '0')}_${s}.jpg`);
      if (fs.existsSync(file)) continue;
      // the shutter is open for half the frame, centred on its time
      const t = S === 1 ? n / fps : (n + ((s + 0.5) / S - 0.5) * 0.5) / fps;
      await page.evaluate((t) => window.Film.render(t), t);
      const r = await cdp.send('Page.captureScreenshot', { format: 'jpeg', quality: 95, clip: { x: 0, y: 0, width: 1920, height: 1080, scale } });
      fs.writeFileSync(file + '.tmp', Buffer.from(r.data, 'base64'));
      fs.renameSync(file + '.tmp', file);
    }
    done++;
    if (done % 120 === 0) {
      const el = (Date.now() - started) / 1000;
      console.log(`${done}/${to - from} frames, ${el.toFixed(0)} s, about ${((el / done) * (to - from - done)).toFixed(0)} s left`);
    }
  }
  await browser.close();
}
await Promise.all(Array.from({ length: workers }, (_, i) => worker(i)));
console.log(`done in ${((Date.now() - started) / 1000).toFixed(0)} s`);
