// A page with one home scene, for working on that scene alone: the header, the scene, room to scroll past
// it, the footer → prototype/_preview/<scene>-<lang>.html (not part of the site; delete before committing).
//
//   node design/site/tools/preview-scene.mjs encryption        # ru and en
//   node design/site/tools/preview-scene.mjs encryption en
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { SITE } from './lib/kit.mjs';
import { setProduct } from './lib/html.mjs';
import { document } from './templates/layout.mjs';
import { PRODUCT, loadCopy } from './build.mjs';
import { scene } from './templates/pages/home.mjs';

const [name, only] = process.argv.slice(2);
if (!name) { console.error('usage: preview-scene.mjs <scene> [ru|en]'); process.exit(2); }
setProduct(PRODUCT);
for (const lang of only ? [only] : ['ru', 'en']) {
  const common = await loadCopy(lang, 'common');
  const ctx = { lang, c: common, slug: 'index', other: 'index.html', page: { slug: 'index' }, sub: '', copy: (n) => loadCopy(lang, n) };
  const s = await scene(name, ctx);
  const spacer = '<section style="height:70vh;display:grid;place-items:center;color:var(--text-tertiary);font:var(--t-caption)">— end of scene —</section>';
  const html = document(ctx, { title: `preview: ${name}`, description: name, body: `${s.html}\n${spacer}`, bodyClass: 'page-home', styles: s.styles, scripts: s.scripts })
    .replace(/href="(index|features|download|pricing|login|how-it-works|verification|docs|blog)\.html"/g, 'href="../ru/$1.html"');
  const out = path.join(SITE, 'prototype', '_preview', `${name}-${lang}.html`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, html);
  console.log(`WROTE ${path.relative(SITE, out)}`);
}
