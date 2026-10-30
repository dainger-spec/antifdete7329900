// Render the mock Swedish pages: desktop layout at 1200 css px (x4/3 = 1600 px), phone layout at 390 (x2 = 780).
import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const { chromium } = createRequire(new URL('../../render.mjs', import.meta.url))('playwright');
const base = path.resolve(process.argv[2]);
const out = path.resolve(process.argv[3]);
const only = process.argv[4] ? process.argv[4].split(',') : ['google', 'afton', 'svt', 'dn'];
const sizes = [['d', 1200, 800, 4 / 3], ['m', 390, 844, 2]];
const browser = await chromium.launch();
for (const [tag, w, h, dpr] of sizes) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: dpr });
  const p = await ctx.newPage();
  for (const s of only) {
    await p.goto(pathToFileURL(path.join(base, `${s}.html`)).href);
    await p.waitForTimeout(150);
    await p.screenshot({ path: path.join(out, `${s}-${tag}.png`), fullPage: true });
    console.log(s, tag);
  }
  await ctx.close();
}
await browser.close();
