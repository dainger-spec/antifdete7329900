// Builds the clickable prototype: every page in Russian and English from the page templates
// (tools/templates/pages) and the texts (copy/source/{ru,en}), into prototype/{ru,en}/*.html.
//
//   node design/site/tools/build.mjs
//
// The pages are static HTML: they read without JavaScript, load nothing from a network, and link
// to each other relatively, so the prototype opens from disk (double-click prototype/index.html).
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { SITE } from './lib/kit.mjs';
import { setProduct } from './lib/html.mjs';
import { document } from './templates/layout.mjs';
import { hub } from './templates/hub.mjs';

export const LANGS = ['ru', 'en'];

// The working name and a reserved placeholder domain (RFC 2606): both are the owner's decision (q1).
export const PRODUCT = { name: 'Lumen', domain: 'lumen.example' };

// slug: the file name; template: tools/templates/pages/<template>.mjs; copy: copy/source/<lang>/<copy>.mjs
export const PAGES = [
  { slug: 'index', template: 'home', copy: 'home', group: 'Маркетинг' },
  { slug: 'features', template: 'features', copy: 'features', group: 'Маркетинг' },
  { slug: 'how-it-works', template: 'how-it-works', copy: 'how-it-works', group: 'Маркетинг' },
  { slug: 'verification', template: 'verification', copy: 'verification', group: 'Маркетинг' },
  { slug: 'pricing', template: 'pricing', copy: 'pricing', group: 'Маркетинг' },
  { slug: 'download', template: 'download', copy: 'download', group: 'Маркетинг' },
  { slug: 'docs', template: 'docs', copy: 'docs', group: 'Документация и обновления' },
  { slug: 'docs-import-cookies', template: 'docs-article', copy: 'docs', group: 'Документация и обновления' },
  { slug: 'blog', template: 'blog', copy: 'blog', group: 'Документация и обновления' },
  { slug: 'blog-no-noise', template: 'blog-post', copy: 'blog', group: 'Документация и обновления' },
  { slug: 'login', template: 'auth', copy: 'auth', state: 'email', group: 'Вход и кабинет' },
  { slug: 'login-code', template: 'auth', copy: 'auth', state: 'code', group: 'Вход и кабинет' },
  { slug: 'login-key', template: 'auth', copy: 'auth', state: 'key', group: 'Вход и кабинет' },
  { slug: 'signup', template: 'auth', copy: 'auth', state: 'signup', group: 'Вход и кабинет' },
  { slug: 'account', template: 'account', copy: 'account', state: 'subscription', group: 'Вход и кабинет' },
  { slug: 'account-devices', template: 'account', copy: 'account', state: 'devices', group: 'Вход и кабинет' },
  { slug: 'account-sync', template: 'account', copy: 'account', state: 'sync', group: 'Вход и кабинет' },
  { slug: 'account-invoices', template: 'account', copy: 'account', state: 'invoices', group: 'Вход и кабинет' },
  { slug: 'account-settings', template: 'account', copy: 'account', state: 'settings', group: 'Вход и кабинет' },
  { slug: 'privacy', template: 'legal', copy: 'legal', state: 'privacy', group: 'Правовое и поддержка' },
  { slug: 'terms', template: 'legal', copy: 'legal', state: 'terms', group: 'Правовое и поддержка' },
  { slug: 'refunds', template: 'legal', copy: 'legal', state: 'refunds', group: 'Правовое и поддержка' },
  { slug: 'support', template: 'support', copy: 'support', group: 'Правовое и поддержка' },
  { slug: '404', template: 'notfound', copy: 'notfound', group: 'Правовое и поддержка' },
];

const exists = (p) => fs.existsSync(p);
const tplPath = (name) => path.join(SITE, 'tools', 'templates', 'pages', `${name}.mjs`);
const copyPath = (lang, name) => path.join(SITE, 'copy', 'source', lang, `${name}.mjs`);

export async function loadCopy(lang, name) {
  return (await import(pathToFileURL(copyPath(lang, name)).href + `?t=${Date.now()}`)).default;
}

export async function build({ only } = {}) {
  setProduct(PRODUCT);
  const built = [];
  for (const lang of LANGS) {
    const common = await loadCopy(lang, 'common');
    for (const page of PAGES) {
      if (only && !page.slug.includes(only)) continue;
      if (!exists(tplPath(page.template)) || !exists(copyPath(lang, page.copy))) {
        console.warn(`SKIP ${lang}/${page.slug}.html (template or copy not written yet)`);
        continue;
      }
      const render = (await import(pathToFileURL(tplPath(page.template)).href + `?t=${Date.now()}`)).default;
      const c = await loadCopy(lang, page.copy);
      // The header's subtitle (phones): the page's own name, or on the home page its first scene's.
      const sub = typeof c.title === 'string' ? c.title : (c.intro && c.intro.section) || '';
      const ctx = { lang, c: common, slug: page.slug, other: `${page.slug}.html`, state: page.state, page, sub, copy: (name) => loadCopy(lang, name) };
      const out = await render(c, ctx);
      const html = document(ctx, {
        title: out.title === undefined ? (c.title ?? null) : out.title,
        description: out.description || c.description,
        body: out.body,
        bodyClass: out.bodyClass,
        hideFooter: out.hideFooter,
        scripts: out.scripts,
      });
      const file = path.join(SITE, 'prototype', lang, `${page.slug}.html`);
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, html);
      built.push(`${lang}/${page.slug}.html`);
    }
  }
  if (!only) {
    // Where each owner decision shows (yellow marks), counted in the Russian pages, for the review page.
    const tbdIndex = {};
    for (const page of PAGES) {
      const file = path.join(SITE, 'prototype', 'ru', `${page.slug}.html`);
      if (!exists(file)) continue;
      for (const m of fs.readFileSync(file, 'utf8').matchAll(/class="tbd" data-q="(q\d+)"/g)) {
        tbdIndex[m[1]] = tbdIndex[m[1]] || {};
        tbdIndex[m[1]][page.slug] = (tbdIndex[m[1]][page.slug] || 0) + 1;
      }
    }
    fs.writeFileSync(path.join(SITE, 'prototype', 'index.html'), hub({ pages: PAGES, tbdIndex }));
    built.push('index.html');
  }
  console.log(`BUILT ${built.length} pages`);
  return built;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  await build({ only: process.argv[2] });
}
