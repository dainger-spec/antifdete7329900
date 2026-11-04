// Renders the still (Reduce Motion) lock at 2x and saves the lockbox region (+ margin) as a PNG with alpha.
import { createRequire } from 'node:module';
import path from 'node:path';
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const require = createRequire(new URL('../../render.mjs', import.meta.url));
const { chromium } = require('playwright');
const [page, out] = process.argv.slice(2);
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, reducedMotion: 'reduce' });
await ctx.route(u => !u.href.startsWith('file:'), r => r.abort());
const p = await ctx.newPage();
// Text only: skip the glow (drawn at alpha 0.42) and the keyhole's light (a gradient fill) on the scene canvas.
await p.addInitScript(() => {
  const P = CanvasRenderingContext2D.prototype, di = P.drawImage, fr = P.fillRect;
  const mine = (c) => c.canvas.classList && c.canvas.classList.contains('enc-cv');
  P.drawImage = function (...a) { if (mine(this) && Math.abs(this.globalAlpha - 0.42) < 0.01) return; return di.apply(this, a); };
  P.fillRect = function (...a) { if (mine(this) && typeof this.fillStyle !== 'string') return; return fr.apply(this, a); };
});
await p.goto(pathToFileURL(path.resolve(page)).href + '?shot=1');
await p.evaluate(() => document.fonts.ready);
await p.waitForTimeout(800);
const data = await p.evaluate(() => {
  const cv = document.querySelector('.sc-encryption .enc-cv'), box = document.querySelector('.sc-encryption .enc-lockbox');
  const cr = cv.getBoundingClientRect(), br = box.getBoundingClientRect(), k = cv.width / cr.width, m = 24;
  const o = document.createElement('canvas'); o.width = Math.round((br.width + 2 * m) * k); o.height = Math.round((br.height + 2 * m) * k);
  o.getContext('2d').drawImage(cv, Math.round((br.left - cr.left - m) * k), Math.round((br.top - cr.top - m) * k), o.width, o.height, 0, 0, o.width, o.height);
  return o.toDataURL('image/png');
});
fs.writeFileSync(out, Buffer.from(data.split(',')[1], 'base64'));
console.log('WROTE', out);
await browser.close();
