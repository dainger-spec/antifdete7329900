// Short recordings of the prototype's motion → shots/motion/<scene>.mp4 (H.264), for the review page.
//
//   node design/site/tools/record.mjs            # every scene
//   node design/site/tools/record.mjs hero       # scenes whose name contains "hero"
//
// The prototype is served from a static server on 127.0.0.1 (cross-document view transitions need an
// origin; file:// has none). Every other request fails the recording. Playwright records at about 25
// frames a second: enough to see a 200 ms transition, not to judge its curve — for that, open the
// prototype itself.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { SITE } from './lib/kit.mjs';

const { chromium } = createRequire(import.meta.url)('playwright');
const OUT = path.join(SITE, 'shots', 'motion');
const TMP = path.join(process.env.TMPDIR || '/tmp', `lumen-site-rec-${process.pid}`);
const TYPES = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png', '.mp4': 'video/mp4' };

function serve() {
  const root = path.join(SITE, 'prototype');
  const server = http.createServer((req, res) => {
    const url = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    let file = path.join(root, url);
    if (!file.startsWith(root)) { res.writeHead(403); res.end(); return; }
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

const pause = (page, ms) => page.waitForTimeout(ms);
async function smoothScroll(page, to, ms = 900) {
  await page.evaluate(([y, d]) => new Promise((done) => {
    const y0 = scrollY, t0 = performance.now();
    const step = (t) => { const p = Math.min(1, (t - t0) / d); const e = p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2; scrollTo(0, y0 + (y - y0) * e); if (p < 1) requestAnimationFrame(step); else done(); };
    requestAnimationFrame(step);
  }), [to, ms]);
}
async function clickAt(page, locator) {
  const b = await locator.boundingBox();
  await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2, { steps: 12 });
  await pause(page, 150);
  await page.mouse.down(); await page.mouse.up();
}

const SCENES = {
  'home-1440': { w: 1440, h: 900, async run(page, base) {
    // The presentation, top to bottom: each scene plays with the scroll.
    await page.goto(`${base}/ru/index.html?rec=1`);
    await pause(page, 1800);
    const H = await page.evaluate(() => document.documentElement.scrollHeight - innerHeight);
    const stops = await page.evaluate(() => Array.from(document.querySelectorAll('[data-scene], .morex, .final')).map((el) => el.getBoundingClientRect().top + scrollY));
    let y = 0;
    for (const s of stops.slice(1).concat([H])) {
      const to = Math.min(H, s), d = to - y;
      if (d <= 0) continue;
      await smoothScroll(page, to, Math.max(1600, Math.min(5200, d * 1.6)));
      await pause(page, 700);
      y = to;
    }
    await pause(page, 1200);
  } },
  'home-390': { w: 390, h: 844, mobile: true, async run(page, base) {
    await page.goto(`${base}/ru/index.html?rec=1`);
    await pause(page, 1600);
    const H = await page.evaluate(() => document.documentElement.scrollHeight - innerHeight);
    const stops = await page.evaluate(() => Array.from(document.querySelectorAll('[data-scene], .morex, .final')).map((el) => el.getBoundingClientRect().top + scrollY));
    let y = 0;
    for (const s of stops.slice(1).concat([H])) {
      const to = Math.min(H, s), d = to - y;
      if (d <= 0) continue;
      await smoothScroll(page, to, Math.max(1500, Math.min(4800, d * 1.5)));
      await pause(page, 600);
      y = to;
    }
    await pause(page, 1000);
  } },
  'home-1440': { w: 1440, h: 900, async run(page, base) {
    // The presentation, top to bottom: each scene plays with the scroll.
    await page.goto(`${base}/ru/index.html?rec=1`);
    await pause(page, 1800);
    const H = await page.evaluate(() => document.documentElement.scrollHeight - innerHeight);
    const stops = await page.evaluate(() => Array.from(document.querySelectorAll('[data-scene], .morex, .final')).map((el) => el.getBoundingClientRect().top + scrollY + Math.max(0, el.offsetHeight - innerHeight)));
    let y = 0;
    for (const s of stops.concat([H])) {
      const to = Math.min(H, s), d = to - y;
      if (d <= 20) continue;
      await smoothScroll(page, to, Math.max(1400, Math.min(5600, d * 1.9)));
      await pause(page, 500);
      y = to;
    }
    await pause(page, 1200);
  } },
  'home-390': { w: 390, h: 844, mobile: true, async run(page, base) {
    await page.goto(`${base}/ru/index.html?rec=1`);
    await pause(page, 1600);
    const H = await page.evaluate(() => document.documentElement.scrollHeight - innerHeight);
    const stops = await page.evaluate(() => Array.from(document.querySelectorAll('[data-scene], .morex, .final')).map((el) => el.getBoundingClientRect().top + scrollY + Math.max(0, el.offsetHeight - innerHeight)));
    let y = 0;
    for (const s of stops.concat([H])) {
      const to = Math.min(H, s), d = to - y;
      if (d <= 20) continue;
      await smoothScroll(page, to, Math.max(1400, Math.min(5200, d * 1.8)));
      await pause(page, 450);
      y = to;
    }
    await pause(page, 1000);
  } },
  'hero-1440': { w: 1440, h: 900, async run(page, base) {
    // The opening alone: the words rise, then the scroll opens the Mac and brings the half out of its screen.
    await page.goto(`${base}/ru/index.html?rec=1`);
    await pause(page, 2000);
    const end = await page.evaluate(() => { const el = document.querySelector('[data-scene="intro"]'); return el.offsetHeight - innerHeight; });
    await smoothScroll(page, end, 7000);
    await pause(page, 600);
    await page.mouse.move(380, 700, { steps: 1 });
    await page.mouse.move(470, 430, { steps: 40 });
    await page.mouse.move(560, 380, { steps: 30 });
    await pause(page, 1400);
  } },
  'hero-reduced-1440': { w: 1440, h: 900, reduced: true, async run(page, base) {
    // Reduce Motion: no scenes; every section shows its finished picture and the page simply scrolls.
    await page.goto(`${base}/ru/index.html?rec=1`);
    await pause(page, 1200);
    await smoothScroll(page, 1400, 2400);
    await pause(page, 1000);
  } },
  'reveal-1440': { w: 1440, h: 900, async run(page, base) {
    await page.goto(`${base}/ru/features.html?rec=1`);
    await pause(page, 600);
    for (let i = 1; i <= 6; i++) { await smoothScroll(page, i * 620, 700); await pause(page, 450); }
  } },
  'sections-1440': { w: 1440, h: 900, async run(page, base) {
    await page.goto(`${base}/ru/features.html?rec=1`);
    await pause(page, 500);
    await smoothScroll(page, 360, 600);
    await pause(page, 500);
    for (const id of ['encryption', 'warmup', 'proxy', 'data']) {
      await clickAt(page, page.locator(`.local-nav a[href="#${id}"]`));
      await pause(page, 1500);
    }
  } },
  'pages-1440': { w: 1440, h: 900, async run(page, base) {
    await page.goto(`${base}/ru/index.html?rec=1`);
    await pause(page, 1200);
    for (const href of ['features.html', 'how-it-works.html', 'verification.html', 'pricing.html']) {
      await clickAt(page, page.locator(`.site-header .nav a[href="${href}"]`));
      await page.waitForLoadState('load');
      await pause(page, 1100);
    }
  } },
  'pricing-1440': { w: 1440, h: 900, async run(page, base) {
    await page.goto(`${base}/ru/pricing.html?rec=1`);
    await pause(page, 500);
    await smoothScroll(page, 300, 500);
    await pause(page, 500);
    for (const which of ['year', 'month', 'year']) { await clickAt(page, page.locator(`label[data-bill="${which}"]`)); await pause(page, 1100); }
  } },
  'menu-390': { w: 390, h: 844, mobile: true, async run(page, base) {
    await page.goto(`${base}/ru/index.html?rec=1`);
    await pause(page, 900);
    await clickAt(page, page.locator('.menu > summary'));
    await pause(page, 1300);
    await clickAt(page, page.locator('.menu > summary'));
    await pause(page, 900);
  } },
};

async function record(name, spec, base) {
  const dir = path.join(TMP, name);
  fs.mkdirSync(dir, { recursive: true });
  const browser = await chromium.launch();
  const context = await browser.newContext({
    viewport: { width: spec.w, height: spec.h }, isMobile: !!spec.mobile, hasTouch: !!spec.mobile,
    reducedMotion: spec.reduced ? 'reduce' : 'no-preference',
    recordVideo: { dir, size: { width: spec.w, height: spec.h } },
  });
  await context.route((u) => !u.href.startsWith(base), (r) => { console.error(`BLOCKED ${r.request().url()}`); process.exitCode = 1; return r.abort(); });
  // The prototype's own strip stays out of the recordings, on every page a scene opens.
  await context.addInitScript(() => {
    const add = () => document.documentElement && document.documentElement.classList.add('rec');
    add(); document.addEventListener('DOMContentLoaded', add);
  });
  const page = await context.newPage();
  await spec.run(page, base);
  const video = page.video();
  await context.close();
  await browser.close();
  const webm = await video.path();
  fs.mkdirSync(OUT, { recursive: true });
  const mp4 = path.join(OUT, `${name}.mp4`);
  // Trim the blank start, H.264 for every player.
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-ss', '0.25', '-i', webm, '-c:v', 'libx264', '-preset', 'slow', '-crf', '24', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an', mp4]);
  console.log(`WROTE shots/motion/${name}.mp4 (${(fs.statSync(mp4).size / 1024).toFixed(0)} KB)`);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const filter = process.argv[2];
  const server = await serve();
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    for (const [name, spec] of Object.entries(SCENES)) if (!filter || name.includes(filter)) await record(name, spec, base);
  } finally {
    server.close();
    fs.rmSync(TMP, { recursive: true, force: true });
  }
}
