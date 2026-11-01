#!/usr/bin/env node
// The rules for Lumen's mail templates, checked on every build (email/src/build.mjs runs this):
// what mail programs break on, and what the owner ruled out.
//
//   node design/site/email/src/check.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'templates');
const NAMES = ['signup_code', 'signup_existing', 'password_reset_code', 'password_changed', 'invite', 'seat_revoked', 'reminder', 'payment_received', 'deletion_scheduled', 'deletion_cancelled'];
const CODE = new Set(['signup_code', 'password_reset_code']);
const errors = [];
const fail = (file, why) => errors.push(`${file}: ${why}`);

for (const name of NAMES) {
  for (const lang of ['ru', 'en']) {
    const base = `${name}.${lang}`;
    const hp = path.join(DIR, `${base}.html`), tp = path.join(DIR, `${base}.txt`);
    if (!fs.existsSync(hp)) { fail(base, 'no HTML version'); continue; }
    if (!fs.existsSync(tp)) { fail(base, 'no text version beside the HTML one'); continue; }
    const h = fs.readFileSync(hp, 'utf8'), t = fs.readFileSync(tp, 'utf8');
    const f = `${base}.html`;

    // Inline styles only: no <style>, no stylesheet, no classes, no media queries; no scripts.
    if (/<style/i.test(h)) fail(f, '<style> — Gmail strips it; styles go inline');
    if (/<link\b/i.test(h)) fail(f, 'an external stylesheet');
    if (/\sclass=/i.test(h)) fail(f, 'a class attribute — there is no stylesheet for it');
    if (/@media/i.test(h)) fail(f, 'a media query');
    if (/<script/i.test(h)) fail(f, 'a script');
    if (/<!--/.test(h)) fail(f, 'an HTML comment — html/template drops comments');
    // Tables, not flexbox or grid; hex colours (Outlook knows no rgba); no gradients or picture backgrounds.
    if (/display\s*:\s*(flex|grid|inline-flex|inline-grid)|\bflex\s*:|grid-template/i.test(h)) fail(f, 'flexbox or grid');
    if (/<(div|section|article|header|footer|main|nav)\b/i.test(h.replace(/<div style="display:none;[^"]*">/, ''))) fail(f, 'a block other than tables (the hidden preview line aside)');
    if (/rgba?\(|hsla?\(/i.test(h)) fail(f, 'rgb()/rgba() — hex colours only');
    if (/gradient\(/i.test(h)) fail(f, 'a gradient');
    if (/background(-image)?\s*:\s*url|background=/i.test(h)) fail(f, 'a picture as a background');
    for (const m of h.matchAll(/<table\b[^>]*>/gi)) if (!/role="presentation"/.test(m[0])) fail(f, 'a layout table without role="presentation"');
    // One column, at most 600 px.
    for (const m of h.matchAll(/\swidth="(\d+)(%?)"/g)) if (!m[2] && +m[1] > 600) fail(f, `width="${m[1]}" — wider than 600`);
    for (const m of h.matchAll(/(?:^|[;"\s])width:\s*(\d+)px/g)) if (+m[1] > 600) fail(f, `width:${m[1]}px — wider than 600`);
    // cells of each row, nested tables counted as their own rows: two side by side only where a row is
    // a label and its value, or a button and its link
    const rows = [], open = [];
    for (const m of h.matchAll(/<(\/?)(tr|td)\b/gi)) {
      if (m[2].toLowerCase() === 'tr') { if (m[1]) rows.push(open.pop()); else open.push(0); }
      else if (!m[1] && open.length) open[open.length - 1] += 1;
    }
    if (rows.some((c) => c > 2)) fail(f, 'more than two cells in a row — one column');
    // The logo is the one picture (docs/SITE_API.md §11): the server's {{.LogoURL}} (cid: — inside the letter),
    // with alt «Lumen» and a size, and the word «Lumen» in its place when there is none; nothing that could be a pixel.
    const imgs = [...h.matchAll(/<img\b[^>]*>/gi)].map((m) => m[0]);
    if (imgs.length !== 1) fail(f, `${imgs.length} pictures — only the logo`);
    if (!/\{\{if \.LogoURL\}\}<img [^>]*>\{\{else\}\}<span [^>]*color:#[0-9A-F]{6}[^>]*>Lumen<\/span>\{\{end\}\}/i.test(h)) fail(f, 'the logo without its word «Lumen» for a letter with no picture');
    for (const img of imgs) {
      if (!/src="\{\{\.LogoURL\}\}"/.test(img)) fail(f, 'a picture other than the logo');
      if (!/alt="Lumen"/.test(img)) fail(f, 'the logo without alt «Lumen»');
      const w = +(img.match(/width="(\d+)"/) || [])[1], hh = +(img.match(/height="(\d+)"/) || [])[1];
      if (!w || !hh) fail(f, 'the logo without width and height');
      if (w < 16 || hh < 16) fail(f, 'a picture this small reads as a tracking pixel');
    }
    if (/data:image|cid:|src="https?:/i.test(h)) fail(f, 'a picture written into the template — the server passes the logo as LogoURL');
    // Colours set everywhere: the page's background at every level, and a colour on every piece of text.
    if (!/<body bgcolor="#[0-9A-F]{6}" style="[^"]*background-color:#[0-9A-F]{6}/i.test(h)) fail(f, 'the body without an explicit background');
    for (const m of h.matchAll(/style="([^"]*font-size[^"]*)"/g)) if (!/(^|;)color:#[0-9A-F]{6}/i.test(m[1])) fail(f, `text without a colour: ${m[1].slice(0, 60)}…`);
    for (const m of h.matchAll(/<a\b[^>]*>/g)) if (!/style="[^"]*color:#[0-9A-F]{6}/i.test(m[0])) fail(f, 'a link without a colour');
    // No tracking: no pixels (above), no redirect links — links go to the site itself or the invitation.
    for (const m of h.matchAll(/href="([^"]*)"/g)) if (!/^\{\{\.(SiteURL|AcceptURL)\}\}/.test(m[1])) fail(f, `a link that is not the site's: ${m[1]}`);
    // The code large and monospaced.
    if (CODE.has(name)) {
      const td = (h.match(/<td[^>]*style="([^"]*)"[^>]*>\{\{\.Code\}\}<\/td>/) || [])[1] || '';
      if (!/monospace/.test(td) || !(+(td.match(/font-size:(\d+)px/) || [])[1] >= 28)) fail(f, 'the code is not large and monospaced');
    }
    // Gmail clips a letter over 102 KB; these stay far below.
    if (Buffer.byteLength(h) > 60 * 1024) fail(f, `${Math.round(Buffer.byteLength(h) / 1024)} KB — too heavy`);
    if (!new RegExp(`<html lang="${lang}"`).test(h)) fail(f, 'the language is not set');

    // The text version: a subject on the first line, the letter, the signature.
    if (!/^\{\{define "subject"\}\}[^\n]+\{\{end\}\}/.test(t)) fail(`${base}.txt`, 'no one-line {{define "subject"}} first');
    if (!/— Lumen/.test(t)) fail(`${base}.txt`, 'no signature');
    if (/<[a-z][^>]*>/i.test(t)) fail(`${base}.txt`, 'markup in the text version');
  }
}
// The logo lies beside the templates: PNG, 144×144, at most 10 KB (docs/SITE_API.md §11).
const logo = path.join(DIR, 'lumen-mark-1.png');
if (!fs.existsSync(logo)) errors.push('lumen-mark-1.png: missing beside the templates');
else {
  const b = fs.readFileSync(logo);
  if (b.readUInt32BE(16) !== 144 || b.readUInt32BE(20) !== 144) errors.push('lumen-mark-1.png: not 144×144');
  if (b.length > 10 * 1024) errors.push(`lumen-mark-1.png: ${b.length} bytes — over 10 KB`);
}
const extra = fs.readdirSync(DIR).filter((x) => x !== 'lumen-mark-1.png' && !NAMES.some((n) => x.startsWith(`${n}.`)));
if (extra.length) errors.push(`unknown files: ${extra.join(', ')}`);

if (errors.length) {
  console.error(`MAIL CHECK FAILED:\n  ${errors.join('\n  ')}`);
  process.exit(1);
}
console.log(`MAIL CHECK PASSED: ${NAMES.length} letters × ru/en × HTML and text, and the logo — tables and inline styles only, one column ≤ 600 px, hex colours set on every text and background, the logo from LogoURL with alt «Lumen» and the word in its place, nothing loaded from outside, no outside links, the code large and monospaced`);
