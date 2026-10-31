// The mark and the app icon, current and refined: SVG files, PNGs at the sizes they are shown at, and
// the review sheets (sizes, pixel zoom, macOS 26 layers, menu-bar template, Dock / Finder / ⌘-Tab).
//
//   node design/tools/logo.mjs
//
// Geometry comes from design/prototypes/kit/geometry.js, which ports LumenMark.swift; the current icon
// replays AppIcon.image(pixels:) step by step. Chromium (Skia) rasterises here, the app uses Core Graphics:
// edges at 16–20 px can differ by a shade, not by shape.
import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const here = dirname(fileURLToPath(import.meta.url));
const design = join(here, '..');
const Lumen = require('./kit-node.cjs');
const G = Lumen.geometry;

const TILE = '#16181D', GLYPH = '#F4F5F7';
const out = (...p) => { const f = join(design, ...p); mkdirSync(dirname(f), { recursive: true }); return f; };
const f = (n) => (Math.round(n * 1000) / 1000).toString();

// MARK: The app icon (AppIcon.image(pixels:)): tile 824/1024 centred, shadow 0/−10/22 at 32 %, the
// light ring inside the edge (824/96 wide), the split disc in the cut for the tile's width in pixels.

let uid = 0;
function iconSVG(pixels, { refined = false, tile = TILE, glyph = GLYPH, ring = 'rgba(255,255,255,0.12)', shadow = true } = {}) {
  const u = pixels / 1024;
  const x = 100 * u, w = 824 * u, r = w * 0.2235;
  const cut = refined ? G.refinedTileCut(w) : G.cutForTileSize(w);
  const id = `i${++uid}`;
  const tilePath = G.squirclePath(x, x, w, w, r);
  const ringW = 2 * Math.max(w / 96, 1);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${pixels}" height="${pixels}" viewBox="0 0 ${pixels} ${pixels}">` +
    `<defs><clipPath id="${id}c"><path d="${tilePath}"/></clipPath>` +
    (shadow ? `<filter id="${id}s" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="${f(10 * u)}" stdDeviation="${f(11 * u)}" flood-color="#000" flood-opacity="0.32"/></filter>` : '') +
    `</defs><path d="${tilePath}" fill="${tile}" ${shadow ? `filter="url(#${id}s)"` : ''}/>` +
    `<g clip-path="url(#${id}c)"><path d="${tilePath}" fill="none" stroke="${ring}" stroke-width="${f(ringW)}"/></g>` +
    `<path d="${G.glyphPath(cut, x, x, w)}" fill="${glyph}"/></svg>`;
}

/// LumenMark at `size` points on a screen of `scale`: current (cut by points) or refined (by pixels).
function markSVG(size, scale, refined, opts = {}) {
  const cut = refined ? G.refinedTileCut(size * scale) : G.cutForTileSize(size);
  return G.markSVG(size, { cut, ...opts });
}
function glyphSVG(size, scale, refined, color = GLYPH) {
  const cut = refined ? G.refinedBareCut(size * scale) : G.cutForBareSize(size);
  return G.glyphSVG(size, color, cut);
}

// MARK: macOS 26 layers: the system masks the full-bleed square to its own shape and renders glass;
// the artwork stays flat — one background, each half its own layer so they can sit apart in depth.
function layerFiles() {
  const s = 1024;
  const cut = G.REFINED.tile64;
  // Icon Composer's canvas is the whole 1024 square (the system masks it), so the disc is laid out on
  // the full canvas: 38/64 of it, the share it has of today's 824 tile. glyphPath draws both halves;
  // they are split at "Z" into one file each.
  const both = G.glyphPath(cut, 0, 0, s).split('Z').filter(Boolean).map((p) => p + 'Z');
  const files = {
    'background.svg': `<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 ${s} ${s}"><rect width="${s}" height="${s}" fill="${TILE}"/></svg>`,
    'half-right.svg': `<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 ${s} ${s}"><path d="${both[0]}" fill="${GLYPH}"/></svg>`,
    'half-left.svg': `<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 ${s} ${s}"><path d="${both[1]}" fill="${GLYPH}"/></svg>`,
  };
  return { files, halves: both };
}

// MARK: Pages to screenshot

const page = (body, bg = '#0B0C0F') => `<!doctype html><html><head><meta charset="utf-8"><style>
  body{margin:0;background:${bg};font:500 11px/14px Inter, -apple-system, sans-serif;color:#8A93A3;-webkit-font-smoothing:antialiased}
  .cap{font:500 11px/14px Inter, sans-serif;color:#8A93A3} .h{font:600 13px/18px Inter, sans-serif;color:#ECEEF2}
  .row{display:flex;align-items:flex-end;gap:24px} .cell{display:flex;flex-direction:column;align-items:center;gap:8px}
  svg{display:block}
</style></head><body>${body}</body></html>`;

async function shoot(browser, html, w, h, file, scale = 2) {
  const p = await browser.newPage({ deviceScaleFactor: scale });
  await p.setViewportSize({ width: w, height: h });
  await p.setContent(html);
  const buffer = await p.screenshot({ path: file || undefined, clip: { x: 0, y: 0, width: w, height: h }, omitBackground: true });
  await p.close();
  if (file) console.log('WROTE', file.replace(design + '/', 'design/'));
  return buffer;
}

/// 16/18/20 pt as the screen gets them (Retina and 1×), enlarged ×8 without smoothing.
async function zoomSheet(browser, lang) {
  const shots = {};
  for (const refined of [false, true]) {
    for (const scale of [2, 1]) {
      const buf = await shoot(browser, zoomSource(refined, scale), 74, 28, null, scale);
      shots[`${refined}-${scale}`] = 'data:image/png;base64,' + buf.toString('base64');
    }
  }
  const img = (key, scale) => `<img src="${shots[key]}" style="width:${74 * 8}px;height:${28 * 8}px;image-rendering:pixelated;display:block;border-radius:6px">`;
  const block = (refined) => `<div style="display:flex;flex-direction:column;gap:8px"><div class="h">${refined ? T(lang, 'Предлагаю', 'Proposed') : T(lang, 'Сейчас', 'Now')}</div>
    <div class="cap">Retina: 16 / 18 / 20 pt = 32 / 36 / 40 px</div>${img(`${refined}-2`)}
    <div class="cap" style="margin-top:6px">${T(lang, 'Внешний монитор 1×: 16 / 18 / 20 px', 'External 1× display: 16 / 18 / 20 px')}</div>${img(`${refined}-1`)}</div>`;
  return page(`<div style="padding:24px;display:flex;flex-direction:column;gap:14px">
    <div class="h" style="font-size:15px">${T(lang, 'Мелкие размеры под лупой (×8, без сглаживания)', 'Small sizes under a loupe (×8, no smoothing)')}</div>
    <div class="cap" style="max-width:1100px">${T(lang, 'На Retina у текущего знака шов в 2 раза толще пропорции большого знака, а сдвиг половин почти не виден. 32-сеточный срез держит пропорции большого знака. На 1× оба варианта используют 16-сетку: там разница — только чуть больший сдвиг (2 → 2.5), чтобы половины читались сдвинутыми, а не просто разрезанными.', 'On Retina the current seam is twice as thick as the large mark’s proportion and the slide is barely visible. The 32-grid cut keeps the large mark’s proportions. At 1× both use the 16 grid; the only change there is a little more slide (2 → 2.5), so the halves read as slid, not just cut.')}</div>
    <div style="display:flex;gap:28px">${block(false)}${block(true)}</div></div>`, '#161920');
}

const T = (lang, ru, en) => (lang === 'en' ? en : ru);

// The CI "app-icon" sheet (UISnapshots.AppIconSheet, 900 × 640), redrawn with the refined icon.
function appIconSheet(refined) {
  const sizes = [256, 128, 64, 32, 16];
  const row = (bg) => `<div style="height:320px;background:${bg};display:flex;align-items:center;padding:0 32px"><div class="row" style="gap:28px">` +
    sizes.map((s) => `<div style="width:${s}px;height:${s}px">${iconSVG(s * 2, { refined }).replace(/width="\d+" height="\d+"/, `width="${s}" height="${s}"`)}</div>`).join('') + '</div></div>';
  return page(row('#0B0C0F') + row('#ECECEC'));
}

// The CI "brand" sheet (UISnapshots.BrandSheet, 900 × 560), redrawn with the refined cuts.
function brandSheet(refined) {
  const marks = [128, 64, 32, 24, 20, 16, 14].map((s) => `<div class="cell">${markSVG(s, 2, refined)}<div class="cap">${s}</div></div>`).join('');
  const lockup = (mark, word, gap, color = '#ECEEF2') => `<span style="display:inline-flex;align-items:center;gap:${gap}px">${markSVG(mark, 2, refined)}${G.wordmarkSVG(word, color)}</span>`;
  return page(`<div style="padding:32px;display:flex;flex-direction:column;gap:28px">
    <div class="row">${marks}</div>
    <div class="row" style="align-items:center;gap:28px">${lockup(36, 22, 14)}${lockup(20, 11.2, 8)}${[40, 24, 16].map((s) => glyphSVG(s, 2, refined)).join('')}</div>
    <div style="display:flex;flex-direction:column;gap:12px">${G.wordmarkSVG(40)}${G.wordmarkSVG(22)}${G.wordmarkSVG(11.2)}</div>
    <div class="row" style="gap:24px;align-items:center"><div style="padding:16px;background:#F2F3F6;border-radius:8px">${lockup(36, 22, 14, '#121419')}</div>
      <div style="padding:16px;background:#F2F3F6;border-radius:8px">${markSVG(48, 2, refined)}</div></div></div>`);
}

// Real sizes, current vs refined, on dark and light, plus the template glyph.
function sizesSheet(lang) {
  const sizes = [16, 18, 20, 32, 64, 128];
  const strip = (refined, bg, labelColor) => `<div style="display:flex;align-items:flex-end;gap:20px;padding:18px 24px;background:${bg}">` +
    sizes.map((s) => `<div class="cell">${markSVG(s, 2, refined)}<div class="cap" style="color:${labelColor}">${s}</div></div>`).join('') + '</div>';
  const tmpl = (refined, bg, color) => `<div style="display:flex;align-items:center;gap:18px;padding:12px 24px;background:${bg}">` +
    [16, 18, 20].map((s) => glyphSVG(s, 2, refined, color)).join('') + `</div>`;
  const col = (refined) => `<div style="flex:1;display:flex;flex-direction:column;gap:0;border-radius:10px;overflow:hidden;border:1px solid rgba(255,255,255,.08)">
    <div class="h" style="padding:12px 24px;background:#161920">${refined ? T(lang, 'Предлагаю: срез по пикселям (16 / 32 / 64)', 'Proposed: cut by pixels (16 / 32 / 64)') : T(lang, 'Сейчас: срез по пунктам (16 / 64)', 'Now: cut by points (16 / 64)')}</div>
    ${strip(refined, '#0B0C0F', '#8A93A3')}${strip(refined, '#ECECEC', '#555D6C')}
    <div class="cap" style="padding:10px 24px 0;background:#161920">${T(lang, 'Знак без плитки (пустые состояния, шаблон для строки меню): 16, 18, 20 pt', 'Bare glyph (empty states, menu-bar template): 16, 18, 20 pt')}</div>
    <div style="display:flex;background:#161920">${tmpl(refined, '#161920', '#F4F5F7')}${tmpl(refined, '#ECECEC', '#000000')}</div></div>`;
  return page(`<div style="padding:24px;display:flex;flex-direction:column;gap:16px">
    <div><div class="h" style="font-size:15px">${T(lang, 'Знак в реальных размерах, Retina (×2)', 'The mark at real sizes, Retina (×2)')}</div>
    <div class="cap" style="margin-top:3px">${T(lang, 'Слева LumenMark как сейчас: ниже 28 pt — 16-сеточный срез, на Retina он рисуется вдвое: шов 4 px = 12.5 % плитки, знак читается как «Ø». Справа — 32-сеточный срез для 24–47 px: шов ≈ 6 %, сдвиг = 2 × шов, как у большого знака. Скачка на 28 pt больше нет.', 'Left: LumenMark today — below 28 pt the 16-grid cut, drawn twice as large on Retina: a 4 px seam, 12.5 % of the tile, reads as “Ø”. Right: a 32-grid cut for 24–47 px: seam ≈ 6 %, slide = 2 × seam, as in the large mark. No jump at 28 pt.')}</div></div>
    <div style="display:flex;gap:16px">${col(false)}${col(true)}</div></div>`, '#0B0C0F');
}

// Pixel inspection: 16/18/20 pt on Retina and 1×, ×8 nearest-neighbour (done in a second pass).
function zoomSource(refined, scale) {
  return page(`<div style="display:flex;gap:6px;padding:4px;background:#0B0C0F">${[16, 18, 20].map((s) => markSVG(s, scale, refined)).join('')}</div>`);
}

function tahoeSheet(lang) {
  const { halves } = layerFiles();
  const s = 220;
  const sq = G.squirclePath(0, 0, s, s, s * 0.2235);
  // Layers over a light checkerboard (transparency), so the dark background layer shows as a square.
  const layer = (content, label) => `<div class="cell"><svg width="${s * 0.55}" height="${s * 0.55}" viewBox="0 0 1024 1024" style="background:repeating-conic-gradient(#C9CDD4 0 25%, #E4E6EA 0 50%) 0 0/48px 48px;border-radius:10px">${content}</svg><div class="cap">${label}</div></div>`;
  const icon = (tile, glyphA, glyphB, label, note = '') => `<div class="cell"><svg width="${s}" height="${s}" viewBox="0 0 ${s} ${s}"><path d="${sq}" fill="${tile}"/>
      <g transform="scale(${s / 1024}) translate(0 0)"><path d="${halves[1]}" fill="${glyphA}"/><path d="${halves[0]}" fill="${glyphB}"/></g></svg>
      <div class="h" style="font-size:12px">${label}</div><div class="cap" style="max-width:220px;text-align:center;color:#D5D9E0">${note}</div></div>`;
  return page(`<div style="padding:28px;display:flex;flex-direction:column;gap:22px">
    <div><div class="h" style="font-size:15px">${T(lang, 'Иконка для macOS 26+: слои вместо картинки', 'Icon for macOS 26+: layers instead of a picture')}</div>
    <div class="cap" style="margin-top:3px;max-width:1060px">${T(lang, 'Сейчас приложение рисует .icns само (плитка 824/1024 с тенью — сетка Big Sur). С macOS 26 иконку собирает система из слоёв Icon Composer: сама маскирует форму, добавляет стекло, блики и режимы «Тёмный / Прозрачный / Тонированный». Наши слои остаются плоскими (правило бренда не нарушается), а половины диска — разные слои, поэтому система может развести их по глубине. Справа — приближения: настоящий рендер даёт только Icon Composer на Mac.', 'Today the app draws its .icns itself (an 824/1024 tile with a shadow — the Big Sur grid). From macOS 26 the system builds icons from Icon Composer layers: it masks the shape and adds the glass, highlights and the Dark / Clear / Tinted looks. Our layers stay flat (the brand rule holds) and each half is its own layer, so the system can set them apart in depth. Right: approximations — only Icon Composer on a Mac renders the real thing.')}</div></div>
    <div style="display:flex;gap:40px;align-items:flex-start">
      <div><div class="cap" style="margin-bottom:10px">${T(lang, 'Слои (design/logo/macos26-layers/)', 'Layers (design/logo/macos26-layers/)')}</div>
        <div class="row" style="gap:16px">${layer(`<rect width="1024" height="1024" fill="${TILE}"/>`, 'background.svg')}${layer(`<path d="${halves[1]}" fill="${GLYPH}"/>`, 'half-left.svg')}${layer(`<path d="${halves[0]}" fill="${GLYPH}"/>`, 'half-right.svg')}</div></div>
    </div>
    <div class="row" style="gap:36px;align-items:flex-start;padding:22px 26px;border-radius:12px;background:#4A5260">
      ${icon(TILE, GLYPH, GLYPH, T(lang, 'По умолчанию', 'Default'), T(lang, 'наши цвета; система добавит стекло', 'our colours; the system adds the glass'))}
      ${icon('#1C1C1E', '#6F8FEA', '#6F8FEA', T(lang, 'Тонированная', 'Tinted'), T(lang, 'система красит по яркости слоёв в выбранный цвет', 'the system tints by the layers’ luminance'))}
      ${icon('#2C2C2E', '#E6E8ED', '#E6E8ED', T(lang, 'Тёмная', 'Dark'), T(lang, 'можно не рисовать: наша и так тёмная', 'can be skipped: ours is dark already'))}
      ${icon('#F2F3F6', '#16181D', '#16181D', T(lang, 'Светлая (не предлагаю)', 'Light (not proposed)'), T(lang, 'для сравнения: бренд — тёмная плитка', 'for comparison: the brand is the dark tile'))}
    </div></div>`, '#161920');
}

// Template glyph in a menu bar, light and dark (a template image is drawn by the system in the bar's colour).
function menubarSheet(lang) {
  const bar = (bg, fg, label) => `<div style="height:24px;background:${bg};display:flex;align-items:center;justify-content:flex-end;gap:16px;padding:0 14px;font:500 13px/16px Inter, sans-serif;color:${fg}">
    <span style="opacity:.9">${label}</span>${glyphSVG(16, 2, true, fg)}<span style="opacity:.85">⌃</span><span>${T(lang, 'Ср 29 окт. 15:42', 'Wed Oct 29 3:42 PM')}</span></div>`;
  return page(`<div style="padding:24px;display:flex;flex-direction:column;gap:14px;width:840px">
    <div class="h" style="font-size:15px">${T(lang, 'Монохром для строки меню (шаблонное изображение)', 'Monochrome for the menu bar (template image)')}</div>
    <div class="cap" style="max-width:780px">${T(lang, 'Знак без плитки, 16 pt, чёрный с альфой: система сама красит его под светлую и тёмную строку. У приложения сейчас нет значка в строке меню — это заготовка, если он понадобится (например, «сколько профилей запущено»).', 'The bare glyph, 16 pt, black with alpha: the system colours it for light and dark bars. The app has no menu-bar item today — this is ready if it gets one (e.g. how many profiles run).')}</div>
    ${bar('#E9E9EB', '#1D1D1F', 'Lumen')}${bar('#1E1E20', '#F2F2F4', 'Lumen')}
    <div class="row" style="gap:20px;margin-top:6px">${[16, 18, 22].map((s) => `<div class="cell"><div style="padding:8px;background:#ECECEC;border-radius:6px">${glyphSVG(s, 2, true, '#000')}</div><div class="cap">${s} pt</div></div>`).join('')}</div></div>`, '#161920');
}

// Where the icon lives: Dock (dark, light), Finder list and icon view, ⌘-Tab — with neutral stand-ins
// for other apps (no real app's icon is drawn).
function contextSheet(lang, refined) {
  const others = ['#3A7BD5', '#E2574C', '#F5A623', '#7ED321', '#9B59B6', '#50E3C2'];
  const glyphs = ['M30 70 L50 30 L70 70Z', 'M30 30h40v40H30z', 'M50 28a22 22 0 1 0 .1 0z', 'M28 50h44M50 28v44', 'M30 35h40M30 50h40M30 65h25', 'M30 70 Q50 20 70 70'];
  const other = (i, size) => `<svg width="${size}" height="${size}" viewBox="0 0 100 100"><path d="${G.squirclePath(9, 9, 82, 82, 18.3)}" fill="${others[i % 6]}"/><path d="${glyphs[i % 6]}" fill="none" stroke="#fff" stroke-width="6" stroke-linecap="round" stroke-linejoin="round" opacity=".9"/></svg>`;
  const ours = (size) => iconSVG(size * 2, { refined }).replace(/width="\d+" height="\d+"/, `width="${size}" height="${size}"`);
  const dock = (bg, shelf, border) => `<div style="background:${bg};padding:22px 0 14px;display:flex;justify-content:center;border-radius:10px">
    <div style="display:flex;gap:6px;padding:6px 8px;border-radius:22px;background:${shelf};box-shadow:inset 0 0 0 1px ${border}">${[0, 1, 2].map((i) => other(i, 64)).join('')}${ours(64)}${[3, 4, 5].map((i) => other(i, 64)).join('')}</div></div>`;
  const finderList = `<div style="background:#1E1E20;border-radius:10px;overflow:hidden;font:400 13px/16px Inter, sans-serif;color:#E6E6E6">
    ${[['Notes', 0], ['PrivacyBrowser', -1], ['Preview', 2], ['Reader', 3]].map(([n, i], k) => `<div style="display:flex;align-items:center;gap:8px;height:24px;padding:0 12px;${n === 'PrivacyBrowser' ? 'background:#2A5BC9;color:#fff' : k % 2 ? 'background:#232326' : ''}">${i < 0 ? ours(16) : other(i, 16)}<span>${n}.app</span></div>`).join('')}</div>`;
  const finderIcons = `<div style="background:#ECECEC;border-radius:10px;padding:18px;display:flex;gap:26px;font:400 12px/15px Inter, sans-serif;color:#1D1D1F">${[0, -1, 2].map((i) => `<div class="cell" style="gap:6px">${i < 0 ? ours(64) : other(i, 64)}<span>${i < 0 ? 'PrivacyBrowser' : ['Notes', '', 'Preview'][i]}</span></div>`).join('')}</div>`;
  const cmdTab = `<div style="background:#0B0C0F;padding:18px;border-radius:10px;display:flex;justify-content:center"><div style="display:flex;gap:10px;padding:14px;border-radius:24px;background:#2A2A2D">${[1, -1, 4].map((i) => `<div style="padding:8px;border-radius:16px;${i < 0 ? 'background:rgba(255,255,255,.14)' : ''}">${i < 0 ? ours(96) : other(i, 96)}</div>`).join('')}</div></div>`;
  return page(`<div style="padding:24px;display:flex;flex-direction:column;gap:16px">
    <div class="h" style="font-size:15px">${refined ? T(lang, 'Предлагаемая иконка в системе', 'The proposed icon in place') : T(lang, 'Текущая иконка в системе', 'The current icon in place')}</div>
    <div class="cap">${T(lang, 'Dock в тёмном и светлом режиме (64 pt), Finder списком (16 pt) и значками (64 pt), ⌘-Tab (96 pt). Остальные иконки — нейтральные заглушки.', 'Dock in dark and light mode (64 pt), Finder list (16 pt) and icons (64 pt), ⌘-Tab (96 pt). The other icons are neutral stand-ins.')}</div>
    ${dock('#0E1013', 'rgba(60,60,64,.55)', 'rgba(255,255,255,.12)')}${dock('#C9D3DE', 'rgba(255,255,255,.55)', 'rgba(0,0,0,.08)')}
    <div style="display:grid;grid-template-columns:260px 1fr 1fr;gap:16px;align-items:start">${finderList}${finderIcons}${cmdTab}</div></div>`, '#161920');
}

// MARK: Run

const browser = await chromium.launch();

// SVG deliverables
writeFileSync(out('logo', 'mark-current.svg'), G.markSVG(512, { cut: G.CUTS.large }));
writeFileSync(out('logo', 'mark-refined-64grid.svg'), G.markSVG(512, { cut: G.REFINED.tile64 }));
writeFileSync(out('logo', 'mark-refined-32grid.svg'), G.markSVG(32, { cut: G.REFINED.tile32 }));
writeFileSync(out('logo', 'mark-refined-16grid.svg'), G.markSVG(16, { cut: G.REFINED.tile16 }));
writeFileSync(out('logo', 'glyph-refined-32grid.svg'), G.glyphSVG(32, '#F4F5F7', G.REFINED.bare32));
writeFileSync(out('logo', 'menubar-template-16pt.svg'), G.glyphSVG(16, '#000000', G.REFINED.bare32));
writeFileSync(out('logo', 'menubar-template-18pt.svg'), G.glyphSVG(18, '#000000', G.REFINED.bare32));
writeFileSync(out('logo', 'appicon-current-1024.svg'), iconSVG(1024));
writeFileSync(out('logo', 'appicon-refined-1024.svg'), iconSVG(1024, { refined: true }));
for (const [name, content] of Object.entries(layerFiles().files)) writeFileSync(out('logo', 'macos26-layers', name), content);
console.log('WROTE design/logo/*.svg');

// PNGs at the sizes they are shown at (Retina): the mark and the app icon, current and refined, dark and light.
for (const refined of [false, true]) {
  const kind = refined ? 'refined' : 'current';
  for (const size of [16, 18, 20, 32, 64, 128, 512]) {
    for (const [bgName, bg] of [['dark', '#0B0C0F'], ['light', '#ECECEC']]) {
      await shoot(browser, page(`<div style="padding:${Math.max(4, size / 8)}px;background:${bg};display:inline-block">${markSVG(size, 2, refined)}</div>`, bg),
        size + 2 * Math.max(4, size / 8), size + 2 * Math.max(4, size / 8), out('logo', 'png', kind, `mark-${size}pt@2x-${bgName}.png`));
    }
    await shoot(browser, page(`<div style="padding:4px;display:inline-block">${glyphSVG(size, 2, refined, '#000')}</div>`, 'transparent'),
      size + 8, size + 8, out('logo', 'png', kind, `mono-${size}pt@2x.png`));
  }
  for (const px of [16, 32, 64, 128, 256, 512, 1024]) {
    await shoot(browser, page(iconSVG(px, { refined }), 'transparent'), px, px, out('logo', 'png', kind, `appicon-${px}px.png`), 1);
  }
}

// The two CI sheets, redrawn with the refined mark (they have no text: one file serves both languages).
for (const lang of ['ru', 'en']) {
  await shoot(browser, appIconSheet(true), 900, 640, out('shots', 'after', lang, 'app-icon.png'));
  await shoot(browser, brandSheet(true), 900, 560, out('shots', 'after', lang, 'brand.png'));
}
for (const lang of ['ru', 'en']) {
  await shoot(browser, sizesSheet(lang), 1180, 640, out('shots', 'after', lang, 'new-logo-sizes.png'));
  await shoot(browser, tahoeSheet(lang), 1180, 680, out('shots', 'after', lang, 'new-logo-macos26.png'));
  await shoot(browser, menubarSheet(lang), 888, 300, out('shots', 'after', lang, 'new-logo-menubar.png'));
  await shoot(browser, contextSheet(lang, false), 1180, 640, out('shots', 'after', lang, 'new-logo-context-current.png'));
  await shoot(browser, contextSheet(lang, true), 1180, 640, out('shots', 'after', lang, 'new-logo-context.png'));
}
for (const lang of ['ru', 'en']) {
  await shoot(browser, await zoomSheet(browser, lang), 1260, 700, out('shots', 'after', lang, 'new-logo-zoom.png'));
}
await browser.close();
