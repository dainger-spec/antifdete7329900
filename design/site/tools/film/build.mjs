// The promo film v2 («Графит»): the stage. One page, 1920 × 1080 CSS px, that holds the DOM layer of every shot
// S01–S21 (spec v2 §4) and nothing else: no plates, no backgrounds, no light. The studio plates are composited
// under it by post.py (the stage is filmed on a transparent background), so a frame here is type, UI and the
// screen content that goes on the rendered display, each on the exact frame of its beat.
//
// What the stage reuses from the home page: the six profile windows (templates/pages/home/mission.mjs), the
// Meridian news site in its three editions (sites.mjs), the Safari window with the Kontor sign-in and Safari's
// error (proxy.mjs), the encryption rows and their ciphertext (encryption.mjs), the bento pictures (bento.mjs),
// each with its scene's CSS, restyled for the film in film.css (pages greyscale, no glows, no blue but the one).
//
//   node tools/film/build.mjs          # → video/stage/ru.html, video/stage/en.html
//
// Open a stage in a browser to look at it: ?t=12.3 shows that moment (on a checker ground), ← → step a frame.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setProduct, esc } from '../lib/html.mjs';
import { flag, glyph, wordmark } from '../lib/kit.mjs';
import { avatar } from '../templates/components.mjs';
import { PRODUCT, loadCopy } from '../build.mjs';
import { SITES as WINDOWS, bar as winBar } from '../templates/pages/home/mission.mjs';
import { safari as meridian, SITE as EDITIONS } from '../templates/pages/home/sites.mjs';
import { safari as kontor } from '../templates/pages/home/proxy.mjs';
import { cipher } from '../templates/pages/home/encryption.mjs';
import * as bento from '../templates/pages/home/bento.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const SITE = path.resolve(here, '../..');
const OUT = path.join(SITE, 'video', 'stage');
const PLATES = path.join(SITE, 'video', '.cache', 'plates');
const TL = JSON.parse(fs.readFileSync(path.join(here, 'timeline.json'), 'utf8'));
const SH = TL.shot;

// MARK: Typography (spec §2 Type)

/// No-break spaces: after one- and two-letter words and «для» (ru), after a few short words (en), before a dash.
function nbRaw(s, lang) {
  let x = String(s);
  if (lang === 'ru') x = x.replace(/(?<=^|[\s(«])([А-Яа-яЁё]{1,2}|[Дд]ля) /g, '$1\u00A0');
  else x = x.replace(/(?<=^|[\s(“])(a|an|the|of|to|in|on|at|by|or|no|is|it|we|and) /gi, '$1\u00A0');
  return x.replace(/ (—|–)/g, '\u00A0$1');
}
const nb = (s, lang) => esc(nbRaw(s, lang));
/// Pair corrections at display size (tools/film/kern.json, written by gates.mjs --fix): where two glyphs of a
/// line come closer than 0.04 em at the film's tracking (Cyrillic «д» and its feet), the first gets that space.
const KERN = fs.existsSync(path.join(here, 'kern.json')) ? JSON.parse(fs.readFileSync(path.join(here, 'kern.json'), 'utf8')) : {};
function kern(s, lang, size) {
  const ks = KERN[size] || {}, ch = [...nbRaw(s, lang)];
  return ch.map((c, i) => (ks[c + (ch[i + 1] || '')] ? `<span class="kp" style="margin-right:${ks[c + ch[i + 1]]}em">${esc(c)}</span>` : esc(c))).join('');
}
/// A trailing «.» or «—» hangs: wrapped so film.js can give it a negative right margin equal to its advance.
const hang = (html) => html.replace(/(\u00A0?[.—])$/, '<span class="hang">$1</span>');
/// Tabular figures on the numbers only (Inter's tnum also spaces out hyphens and dots).
const tn = (html) => html.replace(/\d+/g, '<span class="tn">$&</span>');
/// One line of type. cls: size (xl l m s) and colour (w g b); at: {base, x?, right?, on?}. Centred unless x/right.
function line(text, cls, { base, x, right, on, html = false, lang = 'ru', id = '' } = {}) {
  const size = cls.split(' ').find((c) => ['xl', 'l', 'm'].includes(c));
  const body = html ? text : hang(size ? kern(text, lang, size) : nb(text, lang));
  const pos = right != null ? `right:${1920 - right}px;text-align:right` : x != null ? `left:${x}px` : 'left:0;width:1920px;text-align:center';
  return `<div class="tx ${cls}"${id ? ` id="${id}"` : ''} data-base="${base}"${on != null ? ` data-on="${on}"` : ''} style="${pos}"><i class="bl"></i>${body}</div>`;
}

/// The lockup: glyph() + wordmark() side by side, `width` px wide by their ink, centred on (cx, cy). The glyph's
/// ink is 63.6% of its SVG box tall and 60.3% wide (kit geometry), so it is sized by its ink: LUMEN is 0.91 of
/// the glyph's ink height (a circle reads smaller than caps of the same height) and the gap takes the rest. At
/// 640 px the glyph's ink is 127 px tall, and the clear space under the lockup on the end card (to the
/// tagline's cap height) is at least that.
function lockup(width, cx, cy) {
  const WM = 406 / 102, INK_H = 0.6356, INK_W = 0.603, INK_X = 0.199;
  const gi = width / (INK_W / INK_H + 0.4545 + 0.91 * WM);   // the glyph's ink height
  const box = gi / INK_H, wh = 0.91 * gi, ww = wh * WM, inkW = INK_W * box;
  const left = cx - width / 2, gap = width - inkW - ww;
  const r = (v) => Math.round(v * 100) / 100;
  return `<div class="lockup" style="left:${r(left)}px;top:${r(cy - box / 2)}px;width:${r(width)}px;height:${r(box)}px">` +
    `<span style="position:absolute;left:${r(-INK_X * box)}px;top:0">${glyph(r(box), '#F5F5F7')}</span>` +
    `<span style="position:absolute;left:${r(inkW + gap)}px;top:${r((box - wh) / 2)}px">${wordmark(r(wh), '#F5F5F7')}</span></div>`;
}

// MARK: Pieces of the home page, restyled

/// A profile window (mission.mjs): Safari bar with the profile chip and the site, at its own size.
function profileWindow(i, profiles, { focus = true, w, h, cls = '', style = '' } = {}) {
  const s = WINDOWS[i];
  const W = w || s.w, H = h || s.h;
  return `<div class="mi-win${s.dark ? ' dark' : ''}${focus ? ' focus' : ''} ${cls}" data-i="${i}" style="--w:${W};--h:${H};${style}">
      <div class="mi-frame">${winBar(profiles[i], s.url)}<div class="mi-page">${s.site()}</div></div></div>`;
}

/// The desktop on the Mac's display for S05 (and video/.cache/screens/desktop6.png): 1920 × 1247, #1C1C1E,
/// six windows at 576 × 372 with 32 px gutters, centred in rows 83.5–1163.5. «Магазин» has the focus.
function desktop6(profiles) {
  const W = 576, H = 372, G = 32, x0 = (1920 - (3 * W + 2 * G)) / 2, y0 = 83.5 + (1080 - (2 * H + G)) / 2;
  const at = [[0, 0], [1, 0], [2, 0], [0, 1], [1, 1], [2, 1]];
  // profile order on the desktop: Магазин, Реклама, Поддержка / Тесты, Продажи, Блог
  return `<div class="desk sc-mission">${[0, 1, 2, 3, 4, 5].map((i) => {
    const [c, r] = at[i];
    const lw = WINDOWS[i].w, lh = Math.round(lw * H / W), k = W / lw;
    return profileWindow(i, profiles, { focus: i === 0, w: lw, h: lh, cls: 'dw', style: `left:${x0 + c * (W + G)}px;top:${y0 + r * (H + G)}px;transform:scale(${k.toFixed(5)})` });
  }).join('\n')}</div>`;
}

/// The Store profile's Safari window with the Kontor sign-in and Safari's own error (proxy.mjs), and Safari's
/// generic arrow pointer (drawn here: not Apple's asset).
const POINTER = '<svg class="ptr" width="20" height="28" viewBox="0 0 20 28" aria-hidden="true"><path d="M1.5 1.5v21.2l5.3-5.1 3.6 8.4 3.6-1.6-3.6-8.2h7.4z" fill="#000" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg>';

/// The display content for S13 (and screens/signin.png, screens/error.png): the desktop with the Store
/// window large on it; film.js switches the page (white sign-in / Safari's dark error).
const screenKontor = (px) => `<div class="desk scr-kontor sc-proxy"><div class="kw">${kontor(px)}</div></div>`;

/// The encryption window for S15 (rows and ciphertext from encryption.mjs; no beam, lock, glow or blue).
function encWindow(c, lang) {
  const rows = c.rows.map((r, i) => {
    const k = 977 * (i + 1);
    const ct = (seed, s) => esc(cipher(seed, [...s].length));
    return `<li class="er" data-i="${i}"><span class="er-tile">${esc(r.tile)}</span>
      <span class="er-txt"><span class="er-t"><b class="pl">${esc(r.t)}</b><b class="ct">${ct(k + 2, r.t)}</b></span>
      <span class="er-s"><span class="pl">${esc(r.s)}</span><span class="ct">${ct(k + 3, r.s)}</span></span></span>
      <span class="er-kind">${esc(r.kind)}</span></li>`;
  }).join('');
  return `<div class="ew"><div class="ew-bar"><span class="lights"><i></i><i></i><i></i></span>${avatar(c.profile.name, 0, 24)}<span class="ew-name">${esc(c.profile.name)}</span>
    <span class="ew-meta">${flag('DE', 14)}<span>${esc(c.profile.lang)} · ${esc(c.profile.zone)}</span></span></div><ul class="ew-rows">${rows}</ul></div>`;
}

/// Six German Meridian pages for the warm-up (S17), from the DE edition: each a section front.
function meridianPages() {
  const de = EDITIONS[0];
  const sections = ['Startseite', 'Reisen', 'Kultur', 'Wirtschaft', 'Wissen', 'Sport'];
  const heads = [de.title.replace('\n', ' '), de.items[0], de.more[0][1], de.more[2][1], de.items[1], 'Pokal: Ein Abend, zwei Tore, eine Stadt'];
  const deks = [de.dek, 'Von Berlin nach Wien, Stockholm und Zürich: die Verbindungen des Winters und was sie kosten.', 'Das neue Programm, die alten Säle und ein Publikum, das jünger wird.', 'Die Preise an der Börse steigen, der Kaffee im Laden folgt mit Abstand.', de.dekS, 'Was das Spiel am Mittwoch über die Saison verrät.'];
  return sections.map((s, i) => `<div class="mpg" data-i="${i}">
      <div class="mpg-top"><span>${esc(de.edition)}</span><b>Meridian</b><span>${esc(de.date)}</span></div>
      <nav class="mpg-nav">${de.nav.concat(['Sport']).slice(0, 6).map((n) => `<span${n === s ? ' class="on"' : ''}>${esc(n)}</span>`).join('')}</nav>
      <div class="mpg-body mpg-v${i % 3}">
        <div class="mpg-lead"><i class="mpg-img"></i><span class="mpg-kick">${esc(s)}</span><b>${esc(heads[i])}</b><p>${esc(deks[i])}</p></div>
        <div class="mpg-side">${de.items.map((x, k) => `<div><i class="mpg-th"></i><span>${esc(x)}</span></div>`).join('')}</div>
      </div>
      <div class="mpg-more">${de.more.map(([k, t]) => `<div><i class="mpg-img2"></i><em>${esc(k)}</em><span>${esc(t)}</span></div>`).join('')}</div>
      <div class="mpg-more">${de.more.slice().reverse().map(([k, t]) => `<div><i class="mpg-img2"></i><em>${esc(k)}</em><span>${esc(t)}</span></div>`).join('')}</div>
    </div>`).join('');
}

// MARK: The stage

setProduct(PRODUCT);
fs.mkdirSync(OUT, { recursive: true });
const plates = {};
if (fs.existsSync(PLATES)) for (const f of fs.readdirSync(PLATES).filter((x) => x.endsWith('.json'))) {
  try { const j = JSON.parse(fs.readFileSync(path.join(PLATES, f), 'utf8')); plates[j.id || f.replace(/\.json$/, '')] = j; } catch (e) { console.warn(`plates: ${f}: ${e.message}`); }
}

for (const lang of ['ru', 'en']) {
  const f = await loadCopy(lang, 'film');
  const mission = await loadCopy(lang, 'home-mission');
  const sites = await loadCopy(lang, 'home-sites');
  const px = await loadCopy(lang, 'home-proxy');
  const enc = await loadCopy(lang, 'home-encryption');
  const be = await loadCopy(lang, 'home-bento');
  const T = (text, cls, at) => line(text, cls, { lang, ...at });
  const shot = (id, body, cls = '') => `<section class="shot ${cls}" data-shot="${id}"><div class="cam">${body}</div></section>`;

  // S04: the six windows, each in its own cut, in the measured order (darkest first)
  const burst = SH.S04.order.map((i, k) => `<div class="cut sc-mission" data-k="${k}">${profileWindow(i, mission.profiles, { cls: 'bw' })}</div>`).join('\n');

  // S07: the column: label, country, clock (digits that roll), locale
  const clock = (time) => time.padStart(5, ' ');
  const times = f.countries.map(([, , t]) => clock(t));
  const digits = [0, 1, 2, 3, 4].map((p) => (p === 2 ? '<span class="dc">:</span>'
    : `<span class="dg" data-p="${p}"><span class="dg-in">${times.map((t) => `<span>${t[p]}</span>`).join('')}</span></span>`)).join('');
  const s07col = [
    T(f.sites, 's g', { base: 330, x: 1000 }),
    ...f.countries.map(([, name], i) => T(name, 'm w swap', { base: 450, x: 1000 }).replace('class="tx m w swap"', `class="tx m w swap" data-c="${i}"`)),
    line(digits, 'xl w lt tnum clock', { base: 720, x: 1000, html: true }),
    ...f.countries.map(([, , , loc], i) => line(tn(esc(loc).replace(' · ', ' · ')), 's g swap', { base: 800, x: 1000, html: true }).replace('class="tx s g swap"', `class="tx s g swap" data-c="${i}"`)),
  ].join('\n');

  // S08: two instances of one Meridian window (U.S. Edition), clipped to the sides of the seam
  const vsWin = (side) => `<div class="half half-${side}"><div class="sc-sites vw vw-${side}">${meridian(sites.profiles)}</div></div>`;

  // S10: the ruled table
  const cols = f.rows.map(([a, b, label], i) => {
    const x = 120 + i * 568;
    return `<div class="col" data-on="${SH.S10.columns[i]}"><i class="rule" style="left:${x}px;top:300px;width:544px"></i>
      ${line(`${tn(esc(a))}<span class="g">/${tn(esc(b))}</span>`, 'l w lt', { base: 470, x, html: true })}
      ${T(label, 's w', { base: 548, x })}</div>`;
  }).join('\n');

  // S17: the hidden window
  const pageAt = (n) => tn(nb(f.page.replace('{n}', String(n)).replace('{total}', String(SH.S17.total)), lang));
  const strip = SH.S17.pages.map((_, i) => `<span class="wst-l" data-p="${i}">${esc(f.hidden)} · meridian.example · ${pageAt(SH.S17.first + i)}</span>`).join('') +
    SH.S17.cookies.map((n, i) => `<span class="wst-r" data-c="${i}">${tn(String(n))} ${esc(f.unit)}</span>`).join('');

  // S18: the four tiles on the one CSS 3D plane
  const tileArt = [bento.passwords(be.passwords), bento.cookies(be.cookies), bento.sync(be.sync), bento.ephemeral(be.ephemeral)];
  const tileCls = ['bx-pw', 'bx-ck', 'bx-sy', 'bx-ep'];
  const tiles = f.tiles.map(([t, d], i) => `<article class="tile ${tileCls[i]}" data-i="${i}"><div class="tile-copy"><h3>${nb(t, lang)}</h3><p>${nb(d, lang)}</p></div>
      <div class="bx-art tile-art">${tileArt[i]}</div><i class="tile-edge"></i></article>`).join('\n');

  const html = `<!doctype html>
<!-- The promo film v2 stage (tools/film/build.mjs). Not part of the site. Filmed on a transparent ground: post.py puts the studio under it. -->
<html lang="${lang}" class="film">
<head>
<meta charset="utf-8">
<title>Lumen — film v2 stage (${lang})</title>
<meta name="color-scheme" content="dark">
<link rel="stylesheet" href="../../prototype/assets/site.css">
<link rel="stylesheet" href="../../prototype/assets/scenes/mission.css">
<link rel="stylesheet" href="../../prototype/assets/scenes/sites.css">
<link rel="stylesheet" href="../../prototype/assets/scenes/proxy.css">
<link rel="stylesheet" href="../../prototype/assets/scenes/bento.css">
<link rel="stylesheet" href="../../tools/film/film.css">
</head>
<body class="film">
<main class="reel">
${shot('S01', lockup(640, 960, 532))}
${shot('S02', '')}
${shot('S03', T(f.claim[0], 'l w', { base: 480 }) + T(f.claim[1], 'l g', { base: 636, on: SH.S03.line2 }))}
${shot('S04', burst)}
${shot('S05', `<div class="dclip"><div class="dnotch"><div class="screen" data-scr="desk">${desktop6(mission.profiles)}</div></div></div>`)}
${shot('S06', T(f.atOnce[0], 'xl w', { base: 600 }) + T(f.atOnce[1], 'm g', { base: 740, on: SH.S06.line2 }))}
${shot('S07', `<div class="s07-win sc-sites">${meridian(sites.profiles)}</div>\n${s07col}`)}
${shot('S08', `${vsWin('l')}${vsWin('r')}<svg class="seam" width="1920" height="1080" viewBox="0 0 1920 1080"><line x1="1100" y1="120" x2="780" y2="1080" stroke="#2F6BEF" stroke-width="1.5"/></svg>
${T(f.vs[0], 's g', { base: 80, x: 120 })}${T(f.vs[1], 's g', { base: 80, right: 1800 })}`)}
${shot('S09', T(f.safari[0], 'l w', { base: 480 }) + T(f.safari[1], 'l g', { base: 636 }))}
${shot('S10', `${cols}<div class="col" data-on="${SH.S10.footer}"><i class="rule" style="left:120px;top:820px;width:1680px"></i>
${line(`<span class="w b6">${tn(esc(f.probe[0]))}</span> ${nb(f.probe[1], lang)}`, 's g', { base: 900, x: 120, html: true })}</div>`)}
${shot('S11', `<div class="kwin sc-proxy">${kontor(px)}${POINTER}</div>`)}
${shot('S13', `<div class="dclip"><div class="dnotch"><div class="screen" data-scr="kontor">${screenKontor(px)}</div></div></div>`)}
${shot('S14', T(f.proxy[0], 'l w', { base: 480 }) + T(f.proxy[1], 'l g', { base: 636, on: SH.S14.line2 }) + T(f.proxyProof, 's g', { base: 968, on: SH.S14.foot }))}
${shot('S15', `<div class="encw">${encWindow(enc, lang)}</div>`)}
${shot('S16', T(f.encryption[0], 'l w', { base: 480 }) + T(f.encryption[1], 'l g', { base: 636 }) + line(tn(esc(f.cipher).replace(' · ', ' · ')), 's g', { base: 968, on: SH.S16.spec, html: true }))}
${shot('S17', `<div class="hw sc-mission"><div class="hw-frame">
  <div class="hw-bar"><span class="mi-lights"><i></i><i></i><i></i></span><span class="hw-title">${esc(f.hidden)}</span>
    <span class="mi-cap mi-prof">${flag('DE', 16)}<span>${esc(mission.profiles[0].name)}</span></span>
    <span class="mi-cap mi-addr"><span class="mi-url">meridian.example</span></span></div>
  <div class="hw-view"><div class="hw-pages">${meridianPages()}</div></div>
  <div class="hw-strip">${strip}</div></div></div>
${T(f.warmup, 'm w', { base: 968, x: 120 })}`)}
${shot('S18', `<div class="plane-wrap"><div class="plane sc-bento">${tiles}</div></div>`)}
${shot('S19', '')}
${shot('S20', lockup(640, 960, 470) + T(f.platform, 's g', { base: 690, on: SH.S20.lines }) + T(f.cta, 's b', { base: 754, on: SH.S20.lines }))}
${shot('S21', '')}
</main>
<script>window.FILM_TIMELINE = ${JSON.stringify(TL)}; window.FILM_PLATES = ${JSON.stringify(plates)}; window.FILM_LANG = ${JSON.stringify(lang)};</script>
<script src="../../tools/film/film.js"></script>
</body>
</html>
`.replace(/(src|href|srcset)="\.\.\/assets\//g, '$1="../../prototype/assets/').replace(/url\(\.\.\/assets\//g, 'url(../../prototype/assets/')
    // the film shows no domain other than *.example (spec v2 §2 BANNED); the home page's Tokyo checkout has one
    .replace(/hanako@example\.jp/g, 'hanako@mail.example');
  const file = path.join(OUT, `${lang}.html`);
  fs.writeFileSync(file, html);
  console.log(`WROTE ${path.relative(SITE, file)} (plates: ${Object.keys(plates).join(', ') || 'none yet — post.py uses the graphite placeholder'})`);
}
