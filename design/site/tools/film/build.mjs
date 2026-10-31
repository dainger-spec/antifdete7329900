// The promo film's stage: one page, 1920 × 1080, that holds every shot of the film — the opening MacBook (a
// canvas for the frames of tools/film/hero.mjs) under the name, the home page's scenes (their own HTML, CSS and
// scripts, rearranged by the film in 3D), and the film's own shots: the comparison with Safari, the titles,
// the transitions, the end card (film.css, film.js). Nothing on it moves by itself: film.js puts the whole stage
// at any moment t of the film, and capture.mjs films it frame by frame.
//
//   node tools/film/build.mjs          # → video/stage/ru.html, video/stage/en.html
//
// Open a stage in a browser to look at it: ?t=12.3 shows that moment, the arrow keys step through the film.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setProduct, inline, esc } from '../lib/html.mjs';
import { flag, glyph, wordmark } from '../lib/kit.mjs';
import { PRODUCT, loadCopy } from '../build.mjs';
import { scene } from '../templates/pages/home.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const SITE = path.resolve(here, '../..');
const OUT = path.join(SITE, 'video', 'stage');
const TIMELINE = JSON.parse(fs.readFileSync(path.join(here, 'timeline.json'), 'utf8'));
// The home page's scenes the film uses; "hero", "safari" and "end" are the film's own.
const SCENES = ['mission', 'sites', 'layers', 'proxy', 'encryption', 'warmup', 'numbers', 'bento'];

/// A title: lines (white, then grey) set word by word; each line is a mask the words rise into.
function title(name, lines, lang, extra = '') {
  const words = (s) => inline(s, lang).split(/ (?![^<]*>)/).map((w) => `<span class="w">${w}</span>`).join(' ');
  return `<div class="ttl ttl-${name}" data-title="${name}">${lines.map((l, i) => `<div class="ln ln${i + 1}"><div class="lni">${words(l)}</div></div>`).join('')}${extra}</div>`;
}

/// A fingerprint drawn as a bar code: the same seed gives the same bars, so both sides of a row match.
function bars(seed, w = 420, h = 40) {
  let x = 0, s = seed * 9301 + 49297, out = '';
  const rnd = () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
  while (x < w) {
    const bw = 2 + Math.floor(rnd() * 5), gap = 2 + Math.floor(rnd() * 6), tall = 0.45 + rnd() * 0.55;
    if (x + bw > w) break;
    out += `<rect x="${x}" y="${((1 - tall) * h / 2).toFixed(1)}" width="${bw}" height="${(tall * h).toFixed(1)}" rx="1"/>`;
    x += bw + gap;
  }
  return `<svg class="vs-bars" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${out}</svg>`;
}

setProduct(PRODUCT);
fs.mkdirSync(OUT, { recursive: true });
for (const lang of ['ru', 'en']) {
  const common = await loadCopy(lang, 'common');
  const f = await loadCopy(lang, 'film');
  const ctx = { lang, c: common, slug: 'index', other: 'index.html', page: { slug: 'index' }, sub: '', copy: (n) => loadCopy(lang, n) };
  const parts = [];
  for (const name of SCENES) parts.push({ name, ...(await scene(name, ctx)) });
  const styles = [...new Set(parts.flatMap((p) => p.styles))];
  const scripts = [...new Set(parts.flatMap((p) => p.scripts))];
  // a shot: what its camera films, and what stays put over it (words that must not move with the camera)
  const shot = (name, body, over = '') => `<div class="shot shot-${name}" data-shot="${name}"><div class="cam">${body}</div>${over}</div>`;
  const sceneShot = (name, as = name, over = '') => shot(as, parts.find((p) => p.name === name).html, over);

  // The opening: the name over the dark, then the MacBook (its frames on the canvas)
  const brand = `<div class="brand"><div class="brand-in">${glyph(176)}<span class="brand-word">${wordmark(132, '#F5F6F8')}</span></div></div>`;
  // Each profile from its own country: the country, its time and locale, rolling as the window changes
  const countries = `<div class="cty"><div class="cty-k">${inline(f.sites, lang)}</div><div class="cty-roll">${f.countries.map(([code, name, time, loc], i) => `<div class="cty-i" data-i="${i}"><div class="cty-n">${flag(code, 76)}<span>${esc(name)}</span></div><div class="cty-t">${esc(time)}</div><div class="cty-l">${esc(loc)}</div></div>`).join('')}</div></div>`;
  // The comparison with Safari: two pages of an open book, the same fingerprint on both, row by row
  const page = (side, head) => `<div class="vs-page vs-${side}"><div class="vs-head">${side === 'r' ? glyph(34) : '<i class="vs-dot"></i>'}<span>${esc(head)}</span></div>${f.rows.map(([t], i) => `<div class="vs-row" data-i="${i}"><span class="vs-t">${esc(t)}</span><span class="vs-code">${bars(i + 3)}${bars(i + 3).replace('vs-bars', 'vs-bars vs-lit')}</span><i class="vs-scan"></i></div>`).join('')}</div>`;
  const vs = `<div class="vs"><div class="vs-book">${page('l', f.vs[0])}${page('r', f.vs[1])}</div><i class="vs-spine"></i><div class="vs-mid">${f.rows.map(([, a, b], i) => `<div class="vs-eq" data-i="${i}"><b>${esc(a)}</b><span>/${esc(b)}</span><svg width="30" height="30" viewBox="0 0 30 30"><circle cx="15" cy="15" r="14" fill="#2F6BEF"/><path d="m9 15.5 4 4 8-9" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg></div>`).join('')}</div></div>`;
  // Isolation: the layers named one by one as they part
  const words = `<ol class="lw">${f.layerWords.map((w, i) => `<li data-i="${i}">${esc(w)}</li>`).join('')}</ol>`;
  // The cipher's two names under the lock
  const cipher = `<div class="cn">${f.cipher.map((c) => `<span>${esc(c)}</span>`).join('<i></i>')}</div>`;
  const titles = [
    title('hero', f.hero, lang),
    title('mission', f.mission, lang),
    title('safari', f.safari, lang),
    title('probe', f.probe, lang),
    title('layers', f.layers, lang),
    title('proxy', f.proxy, lang, `<div class="ln ln3"><div class="lni"><span class="w">${inline(f.proxyProof, lang)}</span></div></div>`),
    title('encryption', f.encryption, lang),
    title('warmup', f.warmup, lang),
    title('features', f.features, lang),
  ].join('\n');
  const end = `<div class="end-mark"><i class="end-glow"></i><canvas class="end-l"></canvas><canvas class="end-r"></canvas><canvas class="end-seam"></canvas></div>
    <div class="end-name">${wordmark(104, '#F5F6F8')}</div>
    <div class="end-line">${inline(f.platform, lang)}</div>
    <div class="end-btn">${inline(f.cta, lang)}</div>`;
  const html = `<!doctype html>
<!-- The promo film's stage, built by tools/film/build.mjs from the home page's scenes. Not part of the site. -->
<html lang="${lang}" class="js film">
<head>
<meta charset="utf-8">
<title>Lumen — film stage (${lang})</title>
<meta name="color-scheme" content="dark">
<link rel="stylesheet" href="../../prototype/assets/site.css">
${styles.map((x) => `<link rel="stylesheet" href="../../prototype/assets/${x}">`).join('\n')}
<link rel="stylesheet" href="../../tools/film/film.css">
</head>
<body class="page-home film">
<main class="reel">
${shot('hero', `<canvas class="hero-cv" width="3840" height="2160"></canvas>${brand}`)}
${sceneShot('mission')}
${sceneShot('sites', 'sites', countries)}
${shot('safari', vs)}
${sceneShot('numbers')}
${sceneShot('layers', 'layers', words)}
${sceneShot('proxy')}
${sceneShot('encryption', 'encryption', cipher)}
${sceneShot('warmup')}
${sceneShot('bento', 'features')}
${shot('end', end)}
<div class="titles">
${titles}
</div>
<div class="fx"><i class="fx-vignette"></i><i class="fx-seam"></i><i class="fx-flash"></i><i class="fx-black"></i></div>
</main>
<script>window.FILM_TIMELINE = ${JSON.stringify(TIMELINE)}; window.FILM_LANG = ${JSON.stringify(lang)};</script>
${scripts.map((x) => `<script src="../../prototype/assets/${x}"></script>`).join('\n')}
<script src="../../prototype/assets/site.js"></script>
<script src="../../tools/film/film.js"></script>
</body>
</html>
`.replace(/(src|href)="\.\.\/assets\//g, '$1="../../prototype/assets/').replace(/url\(\.\.\/assets\//g, 'url(../../prototype/assets/');
  const file = path.join(OUT, `${lang}.html`);
  fs.writeFileSync(file, html);
  console.log(`WROTE ${path.relative(SITE, file)}`);
}
