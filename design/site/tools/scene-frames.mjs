// Screenshots of a page at points of a scene's progress, for reviewing scroll-driven scenes.
//
//   node design/site/tools/scene-frames.mjs <page.html> <outdir> --scene proxy --at 0,0.25,0.5,0.75,1
//        [--sizes 1440x900,390x844] [--static] [--hold 250]
//
// For each size it writes <outdir>/<scene>-<w>-<p>.png at each progress point p (0 = the scene's top at the
// top of the window, 1 = its bottom at the bottom), and with --static also <scene>-<w>-static.png: the page
// with Reduce Motion and ?shot=1 (no scenes; what the shots and no-JS readers get), cropped to the scene.
// A phone size (width < 600) is emulated as a touch device. Every network request fails the run.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const { chromium } = createRequire(import.meta.url)('playwright');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d; };
const [page, outdir] = args;
const name = opt('scene');
const at = opt('at', '0,0.25,0.5,0.75,1').split(',').map(Number);
const sizes = opt('sizes', '1440x900,390x844').split(',').map((s) => s.split('x').map(Number));
const hold = +opt('hold', '250');
if (!page || !outdir || !name) { console.error('usage: scene-frames.mjs <page.html> <outdir> --scene <name> [--at …] [--sizes …] [--static]'); process.exit(2); }
fs.mkdirSync(outdir, { recursive: true });
const url = pathToFileURL(path.resolve(page)).href;
const browser = await chromium.launch();
for (const [w, h] of sizes) {
  for (const still of args.includes('--static') ? [false, true] : [false]) {
    const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 1, isMobile: w < 600, hasTouch: w < 600, reducedMotion: still ? 'reduce' : 'no-preference' });
    await ctx.route((u) => !u.href.startsWith('file:'), (r) => { console.error(`BLOCKED ${r.request().url()}`); process.exitCode = 1; return r.abort(); });
    const p = await ctx.newPage();
    p.on('pageerror', (e) => console.error(`pageerror: ${e.message}`));
    p.on('console', (m) => { if (m.type() === 'error') console.error(`console: ${m.text()}`); });
    await p.goto(`${url}?${still ? 'shot' : 'rec'}=1`);
    await p.evaluate(() => document.fonts.ready);
    await p.waitForTimeout(900);
    if (still) {
      const box = await p.evaluate((n) => { const el = document.querySelector(`[data-scene="${n}"]`); const r = el.getBoundingClientRect(); return { y: r.top + scrollY, h: r.height }; }, name);
      const out = path.join(outdir, `${name}-${w}-static.png`);
      await p.screenshot({ path: out, fullPage: true, clip: { x: 0, y: box.y, width: w, height: Math.max(1, box.h) } });
      console.log(`WROTE ${out}`);
    } else {
      for (const pr of at) {
        const y = await p.evaluate(([n, q]) => { const el = document.querySelector(`[data-scene="${n}"]`); const top = el.getBoundingClientRect().top + scrollY; return Math.round(top + Math.max(0, el.offsetHeight - innerHeight) * q); }, [name, pr]);
        await p.evaluate((yy) => window.scrollTo(0, yy), y);
        await p.waitForTimeout(hold);
        const out = path.join(outdir, `${name}-${w}-${pr}.png`);
        await p.screenshot({ path: out });
        console.log(`WROTE ${out}`);
      }
    }
    await ctx.close();
  }
}
await browser.close();
