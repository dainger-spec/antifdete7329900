import { inline, esc, plain } from '../../lib/html.mjs';
import { icon, flag, glyph } from '../../lib/kit.mjs';
import { btn, linkArrow, avatar } from '../components.mjs';

// The keyboard of a MacBook Pro, row by row (relative key widths): the function row, numbers, three letter
// rows, the bottom row with the space bar.
const KEY_ROWS = [
  Array(14).fill(1),
  [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.6],
  [1.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.1],
  [1.8, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.8],
  [2.3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2.3],
  [1, 1, 1, 1.3, 5.2, 1.3, 1, 1, 1, 1],
];

/// A MacBook Pro in Space Black, drawn in CSS 3D (no images): the lid with the display, the keyboard deck,
/// the front lip and the near side. On its display, one half of the mark drawn in code; the other half
/// (a canvas of its own, in the lid's plane until it comes out) floats in front of the screen, out here.
function macbook(c) {
  const [out, onScreen] = c.art.chips;
  const keys = KEY_ROWS.map((r) => `<span class="kr" style="grid-template-columns:${r.map((x) => `${x}fr`).join(' ')}">${'<i></i>'.repeat(r.length)}</span>`).join('');
  return `<div class="mbp" data-mbp aria-hidden="true">
      <div class="mbp-glow"></div>
      <div class="mbp-rig">
        <div class="mbp-deck"><span class="mbp-grille l"></span><span class="mbp-grille r"></span><span class="mbp-keys">${keys}</span><span class="mbp-pad"></span></div>
        <div class="mbp-front"></div>
        <div class="mbp-side"></div>
        <div class="mbp-lid">
          <div class="mbp-hinge"></div>
          <div class="mbp-lidedge"></div>
          <div class="mbp-face">
            <div class="mbp-display">
              <div class="mbp-wall"></div>
              <canvas class="cglow" data-glow-of="screen"></canvas>
              <canvas data-codeart="screen"></canvas>
              <div class="art-fallback">${glyph(150, '#C4D3FF')}</div>
              <div class="mbp-glare"></div>
              <div class="mbp-notch"></div>
              <span class="mbp-note">${avatar(onScreen.name, 3, 20)}<span><b>${esc(onScreen.name)}</b><code>${esc(onScreen.id)}</code></span>${flag(onScreen.code, 12)}</span>
            </div>
          </div>
          <div class="mbp-pop"><canvas class="cglow" data-glow-of="pop"></canvas><canvas data-codeart="pop"></canvas></div>
        </div>
      </div>
    </div>`;
}

// Short words that should not end a line (they stay with the next word).
const STICKY = { ru: new Set('в во без до из к ко на над не ни о об от по под при про с со у и а но да за для что как или же ли бы то мы вы это все всё нет так уже чем где кто ещё свой своя свои'.split(' ')), en: new Set('a an the of to in on at by or and is it as if no so we you its for not per'.split(' ')) };

/// A paragraph whose words light up one by one as the scene scrolls (CSS: --p of the scene, --i of the
/// word, --n words). *Starred* phrases are set in the accent gradient.
function manifest(text, lang) {
  let accent = false;
  const words = plain(text).split(/\s+/).map((w) => {
    const open = w.startsWith('*'), close = w.endsWith('*') || w.endsWith('*.') || w.endsWith('*,');
    if (open) accent = true;
    const word = w.replace(/\*/g, '');
    const out = { word, accent };
    if (close) accent = false;
    return out;
  });
  const sticky = STICKY[lang] || STICKY.en;
  return `<p class="manifest" style="--n:${words.length}">${words.map((x, i) =>
    `<span class="w${x.accent ? ' acc' : ''}" style="--i:${i}">${esc(x.word)}</span>${i < words.length - 1 ? (sticky.has(x.word.toLowerCase()) ? ' ' : ' ') : ''}`).join('')}</p>`;
}

// The shop on the profiles' screens, in the language each profile sends (an invented shop: the words are
// the site's, not ours).
const STORE = {
  de: { nav: ['Neu', 'Damen', 'Herren'], kicker: 'Kollektion', h: 'Neue Kollektion', sub: 'Leicht, warm, für jeden Tag.', cta: 'Jetzt entdecken', cards: ['Jacken', 'Schuhe', 'Taschen'] },
  en: { nav: ['New', 'Women', 'Men'], kicker: 'Collection', h: 'The new collection', sub: 'Light, warm, for every day.', cta: 'Shop now', cards: ['Jackets', 'Shoes', 'Bags'] },
  ja: { nav: ['新着', 'レディース', 'メンズ'], kicker: 'コレクション', h: '新しいコレクション', sub: '軽くて暖かい、毎日のために。', cta: '今すぐ見る', cards: ['ジャケット', 'シューズ', 'バッグ'] },
};
function storefront(t, p) {
  return `<div class="sf" style="--c1:${p.c1};--c2:${p.c2}">
    <div class="sf-nav"><span class="sf-logo"></span><b>shop</b><span class="sf-links">${t.nav.map((x) => `<i>${x}</i>`).join('')}</span><span class="sf-cart"></span></div>
    <div class="sf-hero"><div class="sf-copy"><p class="sf-kicker">${t.kicker}</p><h3>${t.h}</h3><p class="sf-sub">${t.sub}</p><span class="sf-btn">${t.cta}</span></div><div class="sf-art"><i class="o1"></i><i class="o2"></i><i class="o3"></i></div></div>
    <div class="sf-row">${t.cards.map((x, i) => `<span class="sf-card" style="--k:${i}"><i class="img"></i><b>${x}</b></span>`).join('')}</div>
  </div>`;
}

/// A tile of code whose columns are tinted red, green and blue in turn, like a display's subpixels seen
/// close up (an SVG for a CSS background; its text is not page text).
function pixelTile() {
  const cols = 30, rows = 16, cw = 7.2, lh = 11;
  let seed = 11;
  const bit = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >> 16) & 1; };
  const grid = Array.from({ length: rows }, () => Array.from({ length: cols }, bit));
  const tints = ['#FF5A5A', '#4CFF8A', '#5A7CFF'];
  const lines = grid.map((row, r) => tints.map((c, k) => `<text x="0" y="${(r * lh + 9).toFixed(1)}" fill="${c}" xml:space="preserve">${row.map((b, i) => (i % 3 === k ? b : ' ')).join('')}</text>`).join('')).join('');
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${(cols * cw).toFixed(1)}" height="${rows * lh}" font-family="ui-monospace,SF Mono,Menlo,DejaVu Sans Mono,monospace" font-size="10">${lines}</svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

export default function home(c, { lang }) {
  const I = c.intro;
  const [out, onScreen] = c.art.chips;
  const chip = (p, cls, n) => `<span class="achip glass ${cls}">${avatar(p.name, n, 22)}<span class="an"><b>${esc(p.name)}</b><code>${esc(p.id)}</code></span>${flag(p.code, 16)}</span>`;

  // 1. The opening: the promise, and under it a MacBook. As the page scrolls, the Mac rises, its lid opens,
  // the code comes up on its display and one half of the mark comes out of the screen (site.js, "Scenes").
  const intro = `<section class="scene intro" data-scene="intro" data-title="${esc(I.section)}" style="--len:300vh">
  <div class="scene-pin">
    <canvas class="codefield" data-codeart="field" aria-hidden="true"></canvas>
    <div class="intro-text" data-r="0.02 0.13">
      <p class="pill-eyebrow glass">${glyph(14)}<span>${inline(I.eyebrow, lang)}</span></p>
      <h1 class="intro-title">${I.title.map((l, i) => `<span class="ln"><span style="--i:${i}">${inline(l, lang).replace(/ (—|–)$/, '\u00A0$1')}</span></span>`).join('')}</h1>
      <p class="intro-lead">${inline(I.lead, lang)}</p>
      <div class="btn-row center">${btn('download.html', I.primary, 'primary', { size: 'lg', iconName: 'download', lang })}${btn('features.html', I.secondary, 'secondary', { size: 'lg', lang })}</div>
      <p class="hero-dots center">${I.meta.map((m) => `<span>${icon('check', 13)}${inline(m, lang)}</span>`).join('')}</p>
    </div>
    <div class="intro-stage" data-r="0.03 0.32">
      <div class="art" data-art>
        ${macbook(c)}
        ${chip(out, 'l', 2)}${chip(onScreen, 'r', 3)}
        <p class="visually-hidden">${esc(c.art.label)}</p>
      </div>
    </div>
    <p class="intro-caption" data-r="0.8 0.93">${I.caption.map((l, i) => `<span${i ? ' class="dim"' : ''}>${inline(l, lang)}</span>`).join(' ')}</p>
    <span class="scroll-hint" data-r="0 0.05" aria-hidden="true">${esc(I.scroll)}${icon('chevronDown', 14)}</span>
  </div>
</section>`;

  // 2. The idea in one paragraph; its words light up as you scroll (the one place for this device).
  const statement = `<section class="scene statement" data-scene="statement" data-title="${esc(c.statementTitle)}" style="--len:220vh">
  <div class="scene-pin"><div class="container">${manifest(c.statement, lang)}</div></div>
</section>`;

  // 3. The real thing: a page drawn as an outline "renders" into colour, then the camera pulls back and it
  // sits on a MacBook's display, in a profile's Safari window; the profiles change, and with them the
  // site's country and language (site.js, "zoom").
  const Z = c.zoom;
  const zp = Z.profiles;
  const sites = zp.map((p, i) => storefront(STORE[['de', 'en', 'ja'][i]], p, i));
  const zoom = `<section class="scene zoom" data-scene="zoom" data-title="${esc(Z.title)}" style="--len:440vh">
  <div class="scene-pin">
    <h2 class="zm-head h-xl">${Z.head.map((l, i) => `<span${i ? ' class="dim"' : ''}>${inline(l, lang)}</span>`).join(' ')}</h2>
    <div class="zm-mac" aria-hidden="true"><div class="zm-lid"><div class="zm-screen" data-zm-screen>
    <div class="zm-page" data-zm-page>
      <div class="zm-bar"><span class="tl"><i></i><i></i><i></i></span><span class="zm-url">${icon('lock', 10)}<span>${esc(zp[0].site)}</span></span>${zp.map((p, i) => `<span class="zm-chip" data-zm-k="${i}">${avatar(p.name, [2, 3, 4][i], 18)}<b>${esc(p.name)}</b>${flag(p.code, 14)}</span>`).join('')}</div>
      <div class="zm-content">
        <div class="zm-site zm-wire">${sites[0]}</div>
        ${sites.map((html, i) => `<div class="zm-site zm-real" data-zm-k="${i}">${html}</div>`).join('')}
        <span class="zm-scan"></span>
      </div>
    </div>
    <span class="zm-notch"></span></div></div><div class="zm-base"></div></div>
    <p class="zm-overlay glass">${Z.overlay.map((l, i) => `<span data-zm-line="${i}">${inline(l, lang)}</span>`).join('')}</p>
    <p class="zm-cap">${zp.map((p, i) => `<span data-zm-k="${i}">${esc(Z.sees)}: ${flag(p.code, 14)} ${esc(p.country)} · <code>${esc(p.lang)}</code></span>`).join('')}</p>
  </div>
</section>`;

  // 4. Isolation, as an exploded view: five layers of one profile part as you scroll.
  const LY = c.layers;
  const layerFace = [
    `<span class="lyf-bar"><i></i><i></i><i></i><em></em></span><span class="lyf-page"><i></i><i></i><i class="s"></i></span>`,
    `<span class="lyf-chip">${icon('cpu', 14)}WebKit</span><span class="lyf-chip">${icon('folder', 14)}~/profile</span>`,
    `<span class="lyf-row">${icon('cookie', 13)}<i></i>${icon('lockFill', 11)}</span><span class="lyf-row">${icon('key', 13)}<i></i>${icon('lockFill', 11)}</span><span class="lyf-row">${icon('clock', 13)}<i></i>${icon('lockFill', 11)}</span>`,
    `<span class="lyf-net"><i class="dot"></i><i class="ln"></i>${icon('network', 14)}<i class="ln"></i>${icon('globe', 14)}</span><span class="lyf-net off"><i class="dot"></i><i class="ln dash"></i>${icon('xmark', 12)}</span>`,
    `<span class="lyf-key">${icon('key', 18)}<code>AES-256-GCM</code></span>`,
  ];
  const layers = `<section class="scene layers" data-scene="layers" data-title="${esc(LY.title)}" style="--len:300vh">
  <div class="scene-pin"><div class="container ly-grid">
    <div class="ly-text">
      <h2 class="h-xl">${LY.head.map((l, i) => `<span${i ? ' class="dim"' : ''}>${inline(l, lang)}</span>`).join(' ')}</h2>
      <p class="lead">${inline(LY.lead, lang)}</p>
      <ol class="ly-labels">${LY.items.map((x, i) => `<li data-r="${(0.12 + i * 0.1).toFixed(2)} ${(0.24 + i * 0.1).toFixed(2)}"><span class="ly-ic">${icon(x.icon, 16)}</span><span><b>${inline(x.t, lang)}</b><span>${inline(x.d, lang)}</span></span></li>`).join('')}</ol>
    </div>
    <div class="ly-stage" data-r="0.04 0.62" aria-hidden="true">
      <div class="ly-stack">${LY.items.map((x, i) => `<div class="ly" style="--k:${LY.items.length - 1 - i};--i:${i}"><div class="ly-face">${layerFace[i]}</div><span class="ly-name">${inline(x.t, lang)}</span></div>`).join('')}</div>
    </div>
  </div></div>
</section>`;

  // 5. The proxy: light runs from the profile through the proxy to the site; the proxy goes down and the
  // light stops at it.
  const BM = c.beam;
  const beam = `<section class="scene beam" data-scene="beam" data-title="${esc(BM.title)}" style="--len:260vh">
  <div class="scene-pin">
    <div class="container bm-text">
      <h2 class="h-xxl" data-r="0.36 0.52">${BM.head.map((l, i) => `<span${i ? ' class="dim"' : ''}>${inline(l, lang)}</span>`).join(' ')}</h2>
      <p class="lead" data-r="0.5 0.66">${inline(BM.sub, lang)}</p>
    </div>
    <div class="bm-route" aria-hidden="true">
      <span class="bm-node me">${avatar(BM.profile, 3, 30)}<b>${esc(BM.profile)}</b>${flag('US', 16)}</span>
      <span class="bm-line l1"><i class="pk"></i><i class="pk"></i><i class="pk"></i></span>
      <span class="bm-ring"><span class="bm-ic">${icon('network', 26)}</span><b>${esc(BM.proxy)}</b><em>${icon('xmark', 11)}${esc(BM.down)}</em></span>
      <span class="bm-line l2"><i class="pk"></i><i class="pk"></i></span>
      <span class="bm-node site"><span class="bm-ic">${icon('globe', 24)}</span><b>${esc(BM.site)}</b></span>
    </div>
  </div>
</section>`;

  // 6. Strength in numbers: a column of facts over a texture of code tinted like a display's subpixels;
  // a light follows the scroll down it.
  const N = c.nums;
  const nums = `<section class="nums" data-scene="nums" data-title="${esc(N.title)}">
  <div class="nm-bg" aria-hidden="true" style="--tile:url(&quot;${pixelTile()}&quot;)"><i class="nm-lit"></i></div>
  <div class="container nm-list">
    <h2 class="h-xl center-text reveal">${inline(N.head, lang)}</h2>
    ${N.items.map((x) => `<div class="nm-item reveal">${x.code ? `<span class="nm-n nm-code"><code>${esc(x.code)}</code></span>` : `<span class="nm-n"><span data-count="${esc(x.n)}">${esc(x.n)}</span>${x.of ? `<small> / ${esc(x.of)}</small>` : ''}</span>`}<span class="nm-t">${inline(x.t, lang)}</span></div>`).join('')}
    <p class="center-text reveal nm-link">${linkArrow('verification.html', N.link, lang)}</p>
  </div>
</section>`;

  // 7. Everything else, as a bento grid of small pictures.
  const BE = c.bento;
  const tile = (cls, t, d, art) => `<article class="bx ${cls} reveal"><div class="bx-art" aria-hidden="true">${art}</div><h3>${inline(t, lang)}</h3><p>${inline(d, lang)}</p></article>`;
  const bento = `<section class="bentox" data-title="${esc(BE.title)}"><div class="container">
    <h2 class="h-xl center-text reveal">${BE.head.map((l, i) => `<span${i ? ' class="dim"' : ''}>${inline(l, lang)}</span>`).join(' ')}</h2>
    <div class="bx-grid">
      ${tile('w2 pw', BE.passwords.t, BE.passwords.d, `<span class="pw-card glass"><span class="pw-site">${icon('lockFill', 11)}${esc(BE.passwords.site)}</span><span class="pw-field">${icon('key', 13)}<i>••••••••••</i></span><span class="pw-btn">${esc(BE.passwords.save)}</span></span>`)}
      ${tile('hs', BE.history.t, BE.history.d, `<span class="hs-list">${BE.history.rows.map((r, i) => `<span><i style="--h:${[18, 220, 150][i]}"></i>${esc(r)}</span>`).join('')}</span>`)}
      ${tile('ck', BE.cookies.t, BE.cookies.d, `<span class="ck-flow"><span class="ck-file">${icon('doc', 16)}<code>${esc(BE.cookies.file)}</code></span>${icon('arrowRight', 16)}${avatar(c.zoom.profiles[0].name, 2, 34)}</span>`)}
      ${tile('w2 sy', BE.sync.t, BE.sync.d, `<span class="sy-flow">${icon('laptop', 40)}<i class="sy-ln"></i><span class="sy-pk">${icon('lockFill', 13)}</span><i class="sy-ln"></i>${icon('laptop', 40)}</span>`)}
      ${tile('w2 ex', BE.export.t, BE.export.d, `<span class="ex-file">${icon('doc', 44)}<span class="ex-lk">${icon('lockFill', 13)}</span></span>`)}
      ${tile('ep', BE.ephemeral.t, BE.ephemeral.d, `<span class="ep-art">${icon('hourglass', 40)}<i></i><i></i><i></i></span>`)}
    </div>
    <p class="center-text reveal" style="margin-top:40px">${linkArrow('features.html', BE.link, lang)}</p>
  </div></section>`;

  const ct = c.cta;
  const cta = `<section class="final"><div class="container center-text">
    <div class="final-art"><canvas data-codeart="mark" aria-hidden="true"></canvas><div class="art-fallback">${glyph(96, '#2A2F3A')}</div></div>
    <h2 class="h-xxl" style="margin-top:28px">${inline(ct.title, lang)}</h2>
    <p class="lead" style="margin:18px auto 0;max-width:560px">${inline(ct.lead, lang)}</p>
    <div class="btn-row center" style="margin-top:34px">${btn('download.html', ct.primary, 'primary', { size: 'lg', iconName: 'download', lang })}${btn('pricing.html', ct.secondary, 'secondary', { size: 'lg', lang })}</div>
  </div></section>`;

  return { body: [intro, statement, zoom, layers, beam, nums, bento, cta].join('\n'), bodyClass: 'page-home' };
}
