// Checks the built prototype and its texts. Fails (exit 1) on:
//   1. a network resource — anything loaded from http(s), in the HTML or the CSS;
//   2. a key that one language has and the other does not (copy/source/{ru,en});
//   3. a link to a page or an anchor that does not exist;
//   4. a number in the visible text that is not in copy/facts.mjs (the rule: every number on the
//      site is true from the repository, or it is not there). Not counted: values the owner decides
//      (yellow, .tbd), example data in mock-ups ([data-sample]), code, and technical identifiers
//      (.mono, HTTP/2, SHA-256, SOCKS5…);
//   5. a word the site must not use (bypassing identity checks, verification or anti-fraud);
//   6. a page that scrolls sideways on a phone (wider than 390 px).
//
//   node design/site/tools/check.mjs
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { SITE } from './lib/kit.mjs';
import { PAGES, LANGS } from './build.mjs';
import { FACTS } from '../copy/facts.mjs';

const { chromium } = createRequire(import.meta.url)('playwright');
const problems = [];
const fail = (kind, msg) => problems.push(`${kind}: ${msg}`);

// 1. Network resources
const proto = path.join(SITE, 'prototype');
const files = [];
(function walk(d) { for (const f of fs.readdirSync(d)) { const p = path.join(d, f); if (fs.statSync(p).isDirectory()) walk(p); else files.push(p); } })(proto);
for (const f of files.filter((x) => /\.(html|css|js)$/.test(x))) {
  const s = fs.readFileSync(f, 'utf8');
  const rel = path.relative(SITE, f);
  for (const m of s.matchAll(/(?:src|href)\s*=\s*"(https?:)?\/\/[^"]+"/g)) if (!/rel="alternate"/.test(m[0])) fail('network', `${rel}: ${m[0].slice(0, 80)}`);
  for (const m of s.matchAll(/url\(\s*['"]?https?:/g)) fail('network', `${rel}: ${m[0]}`);
  for (const m of s.matchAll(/@import\s/g)) fail('network', `${rel}: @import`);
  for (const m of s.matchAll(/<link[^>]+rel="stylesheet"[^>]+href="(?!\.\.\/assets\/|assets\/)[^"]*"/g)) fail('network', `${rel}: ${m[0]}`);
}

// 2. ru/en parity of the texts
function shape(v, p = '') {
  if (Array.isArray(v)) return v.flatMap((x, i) => shape(x, `${p}[${i}]`));
  if (v && typeof v === 'object') return Object.entries(v).flatMap(([k, x]) => shape(x, p ? `${p}.${k}` : k));
  return [p];
}
for (const f of fs.readdirSync(path.join(SITE, 'copy', 'source', 'ru'))) {
  const ru = (await import(pathToFileURL(path.join(SITE, 'copy', 'source', 'ru', f)).href)).default;
  const enFile = path.join(SITE, 'copy', 'source', 'en', f);
  if (!fs.existsSync(enFile)) { fail('parity', `en/${f} is missing`); continue; }
  const en = (await import(pathToFileURL(enFile).href)).default;
  const a = new Set(shape(ru)), b = new Set(shape(en));
  for (const k of a) if (!b.has(k)) fail('parity', `${f}: en lacks ${k}`);
  for (const k of b) if (!a.has(k)) fail('parity', `${f}: ru lacks ${k}`);
}

// 3–5 in the rendered pages
const allowed = new Set(FACTS.flatMap((f) => [].concat(f.value)).map(norm));
function norm(x) { return String(x).replace(/[\s  ]/g, '').replace(/,/g, '.'); }
const FORBIDDEN = [
  /антидетект/i, /anti-?detect/i, /undetect/i, /верификац/i, /антифрод/i, /anti-?fraud/i, /\bKYC\b/i,
  /обход\S*\s+(провер|верифик|антифрод|защит)/i, /\bbypass\S*\s+(check|verif|anti)/i, /\bevad/i, /не\s+обнаруж/i,
];
const browser = await chromium.launch();
const ctx = await browser.newContext();
await ctx.route((u) => !u.href.startsWith('file:'), (r) => { fail('network', `request ${r.request().url()}`); return r.abort(); });
const numbersSeen = new Map();
// 6. No page scrolls sideways on a phone (390 px).
const phone = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
await phone.route((u) => !u.href.startsWith('file:'), (r) => r.abort());
for (const lang of LANGS) {
  for (const page of PAGES) {
    const file = path.join(proto, lang, `${page.slug}.html`);
    if (!fs.existsSync(file)) continue;
    const p = await phone.newPage();
    await p.goto(pathToFileURL(file).href + '?shot=1');
    const wide = await p.evaluate(() => document.documentElement.scrollWidth);
    if (wide > 390) fail('phone', `${lang}/${page.slug}: the page is ${wide} px wide at 390`);
    await p.close();
  }
}
await phone.close();
for (const lang of LANGS) {
  for (const page of PAGES) {
    const file = path.join(proto, lang, `${page.slug}.html`);
    if (!fs.existsSync(file)) { fail('build', `${lang}/${page.slug}.html is missing`); continue; }
    const p = await ctx.newPage();
    await p.goto(pathToFileURL(file).href + '?shot=1');
    const data = await p.evaluate(() => {
      const ids = new Set(Array.from(document.querySelectorAll('[id]')).map((e) => e.id));
      const links = Array.from(document.querySelectorAll('a[href]')).map((a) => a.getAttribute('href'));
      const root = document.body.cloneNode(true);
      root.querySelectorAll('script, style, svg, .tbd, [data-sample], .mono, code, pre, kbd, [data-proto], input, textarea, select').forEach((e) => e.remove());
      const tw = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      let text = '';
      while (tw.nextNode()) text += tw.currentNode.data + ' ';
      return { ids: Array.from(ids), links, text: text.replace(/[ \t]+/g, ' '), title: document.title };
    });
    // Links
    for (const href of data.links) {
      if (/^(mailto:|https?:)/.test(href)) continue;
      const [target, anchor] = href.split('#');
      const targetFile = target ? path.resolve(path.dirname(file), target) : file;
      if (!fs.existsSync(targetFile)) { fail('link', `${lang}/${page.slug}: ${href}`); continue; }
      if (anchor) {
        if (target) {
          const html = fs.readFileSync(targetFile, 'utf8');
          if (!html.includes(`id="${anchor}"`)) fail('anchor', `${lang}/${page.slug}: ${href}`);
        } else if (!data.ids.includes(anchor)) fail('anchor', `${lang}/${page.slug}: ${href}`);
      }
    }
    // Numbers
    const text = `${data.title}\n${data.text}`;
    const re = /(?<![\p{L}\d/._\-#@:])\d[\d   ]*(?:[.,:]\d+)*(?:\s?[–-]\s?\d+)?(?![\p{L}\d/_\-@])/gu;
    for (const m of text.matchAll(re)) {
      const raw = m[0].trim();
      const parts = raw.split(/\s?[–-]\s?/).map(norm).filter(Boolean);
      for (const part of [norm(raw), ...parts]) {
        if (!numbersSeen.has(part)) numbersSeen.set(part, new Set());
        numbersSeen.get(part).add(`${lang}/${page.slug}`);
      }
      if (allowed.has(norm(raw)) || parts.every((x) => allowed.has(x))) continue;
      const at = text.slice(Math.max(0, m.index - 40), m.index + raw.length + 30).replace(/\s+/g, ' ');
      fail('number', `${lang}/${page.slug}: «${raw}» in “…${at}…”`);
    }
    // Words
    for (const rx of FORBIDDEN) {
      const m = text.match(rx);
      if (m) fail('wording', `${lang}/${page.slug}: «${m[0]}»`);
    }
    await p.close();
  }
}
await browser.close();

if (process.argv.includes('--numbers')) {
  for (const [n, where] of [...numbersSeen].sort((a, b) => a[0].localeCompare(b[0], 'en', { numeric: true }))) console.log(`${n}\t${[...where].slice(0, 6).join(', ')}`);
}
if (problems.length) {
  console.log(problems.join('\n'));
  console.log(`CHECK FAILED: ${problems.length} problem(s)`);
  process.exitCode = 1;
} else {
  console.log(`CHECK PASSED: ${PAGES.length * LANGS.length} pages — no network resources, ru/en texts match key for key, every link resolves, every number is in copy/facts.mjs, no forbidden wording, nothing wider than a phone`);
}
