// Stills of the film at given moments, for checking: node design/promo/tools/frames.mjs 1.5,3,7.2 [--out dir] [--scale 1]
// Also a contact sheet: --sheet 0:77:1 (from:to:step) writes one image of many moments.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
// Playwright as installed for the machine (global), or the project's own if there is one.
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const stage = path.resolve(here, '..', 'stage', 'index.html');
const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const out = path.resolve(opt('--out', path.join(here, '..', '.cache', 'stills')));
const scale = parseFloat(opt('--scale', '1'));
fs.mkdirSync(out, { recursive: true });

let times = [];
const sheet = opt('--sheet', null);
if (sheet) {
  const [a, b, s] = sheet.split(':').map(Number);
  for (let t = a; t <= b + 1e-9; t += s) times.push(Math.round(t * 1000) / 1000);
} else times = (args[0] || '0').split(',').map(Number);

const browser = await chromium.launch({ args: ['--font-render-hinting=none', '--disable-lcd-text'] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: scale });
page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') console.log('[page]', m.text()); });
page.on('pageerror', (e) => console.log('[pageerror]', e.message));
await page.route('**/*', (route) => (route.request().url().startsWith('file://') ? route.continue() : route.abort()));
await page.goto(pathToFileURL(stage).href + '?capture=1&t=0');
await page.waitForFunction(() => window.__ready === true);
const files = [];
for (const t of times) {
  const t0 = Date.now();
  await page.evaluate((t) => window.Film.render(t), t);
  const file = path.join(out, `t${t.toFixed(2).padStart(6, '0')}.png`);
  await page.screenshot({ path: file, type: 'png' });
  files.push(file);
  console.log(`t=${t} ${Date.now() - t0} ms → ${file}`);
}
await browser.close();
if (sheet) {
  const { execFileSync } = await import('node:child_process');
  execFileSync('python3', ['-I', path.join(here, 'sheet.py'), path.join(out, 'sheet.jpg'), ...files], { stdio: 'inherit' });
}
