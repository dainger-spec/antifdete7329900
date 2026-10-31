// Renders every page of the prototype to PNG: full page, at 1440 and 390 CSS pixels wide, Retina
// scale (deviceScaleFactor 2), in Russian and English → shots/{ru,en}/<page>-{1440,390}.png.
//
//   node design/site/tools/render.mjs                 # everything
//   node design/site/tools/render.mjs pricing         # pages whose slug contains "pricing"
//   node design/site/tools/render.mjs --preview home  # quick look at scale 1 into $PREVIEW_DIR
//
// Pages are loaded from disk (file://); any other request fails the render. The shots are taken
// with prefers-reduced-motion and ?shot=1, so every element is at rest (the mark drawn in code
// finished) and the prototype's strip is hidden. Decision marks are off, as on the real site:
// the review page lists where they are, and ?tbd=1 shows them.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { SITE } from './lib/kit.mjs';
import { PAGES, LANGS } from './build.mjs';

const { chromium } = createRequire(import.meta.url)('playwright');
const WIDTHS = [1440, 390];

export async function render({ filter, preview = false, widths = WIDTHS, langs = LANGS, outDir } = {}) {
  const browser = await chromium.launch();
  const written = [];
  for (const width of widths) {
    const context = await browser.newContext({
      viewport: { width, height: width === 390 ? 844 : 900 },
      deviceScaleFactor: preview ? 1 : 2,
      reducedMotion: 'reduce',
      isMobile: width === 390,
      hasTouch: width === 390,
    });
    await context.route((url) => !url.href.startsWith('file:'), (route) => {
      console.error(`BLOCKED network request ${route.request().url()}`);
      process.exitCode = 1;
      return route.abort();
    });
    for (const lang of langs) {
      for (const page of PAGES) {
        if (filter && !page.slug.includes(filter)) continue;
        const file = path.join(SITE, 'prototype', lang, `${page.slug}.html`);
        if (!fs.existsSync(file)) continue;
        const p = await context.newPage();
        await p.goto(`${pathToFileURL(file).href}?shot=1`);
        await p.evaluate(() => document.fonts.ready);
        const out = path.join(outDir || path.join(SITE, 'shots'), lang, `${page.slug}-${width}.png`);
        fs.mkdirSync(path.dirname(out), { recursive: true });
        await p.screenshot({ path: out, fullPage: true });
        written.push(out);
        console.log(`WROTE ${path.relative(SITE, out)}`);
        await p.close();
      }
    }
    await context.close();
  }
  await browser.close();
  return written;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  const preview = args.includes('--preview');
  const filter = args.find((a) => !a.startsWith('--'));
  await render({ filter, preview, outDir: preview ? (process.env.PREVIEW_DIR || path.join(SITE, '.preview')) : undefined });
}
