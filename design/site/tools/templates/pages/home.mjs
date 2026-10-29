import { inline, esc } from '../../lib/html.mjs';
import { icon, flag, glyph } from '../../lib/kit.mjs';
import { btn, linkArrow, avatar, ring } from '../components.mjs';

// Sites of the Swedish warm-up preset (WarmUpPreset.swift, id "se"), in its order.
const SE_SITES = ['google.se', 'aftonbladet.se', 'svt.se', 'dn.se', 'expressen.se', 'blocket.se'];

/// The two halves of the mark, drawn whole (no gap, no slide) so CSS can slide them apart along the seam to
/// the mark's own proportions (LumenMarkGeometry.large: radius 19, gap 3, slide 6). Each half is filled
/// with its own binary (a pattern of monospace text, like the first screen), and a line of light lies in
/// the seam.
function splitDisc(size = 200, radius = 78) {
  const L = globalThis.Lumen;
  const path = L.geometry.glyphPath({ grid: size, cx: size / 2, cy: size / 2, radius, gap: 0, slide: 0 }, 0, 0, size);
  const k = path.indexOf('M', 1);
  const [a, b] = [path.slice(0, k), path.slice(k)];
  const len = Math.hypot(1, 3), d = [1 / len, -3 / len], n = [-d[1], d[0]];
  const gap = (radius * 3) / 19, slide = (radius * 6) / 19;
  const off = (side) => [side * (gap / 2 * n[0] + slide / 2 * d[0]), side * (gap / 2 * n[1] + slide / 2 * d[1])].map((v) => v.toFixed(2));
  const [ax, ay] = off(1), [bx, by] = off(-1);
  // Binary rows from a fixed seed, so every build draws the same pattern.
  let seed = 7;
  const bit = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >> 16) & 1; };
  const rows = (tint) => Array.from({ length: 12 }, (_, r) => `<text x="0" y="${(r * 8 + 6.4).toFixed(1)}" fill="${tint}">${Array.from({ length: 24 }, bit).join('')}</text>`).join('');
  const r = radius * 1.02, c = size / 2;
  return `<svg class="disc" viewBox="0 0 ${size} ${size}" aria-hidden="true">
    <defs>
      <pattern id="bin-a" width="105.6" height="96" patternUnits="userSpaceOnUse"><g font-family="ui-monospace, SF Mono, Menlo, DejaVu Sans Mono, monospace" font-size="7.3">${rows('#C4D3FF')}</g></pattern>
      <pattern id="bin-b" width="105.6" height="96" patternUnits="userSpaceOnUse" patternTransform="translate(37 21)"><g font-family="ui-monospace, SF Mono, Menlo, DejaVu Sans Mono, monospace" font-size="7.3">${rows('#E2E7F0')}</g></pattern>
    </defs>
    <line class="seam" x1="${(c - d[0] * r).toFixed(2)}" y1="${(c - d[1] * r).toFixed(2)}" x2="${(c + d[0] * r).toFixed(2)}" y2="${(c + d[1] * r).toFixed(2)}"/>
    <path class="half a" d="${a}" fill="url(#bin-a)" style="--tx:${ax}px;--ty:${ay}px"/>
    <path class="half b" d="${b}" fill="url(#bin-b)" style="--tx:${bx}px;--ty:${by}px"/>
  </svg>`;
}

export default function home(c, { lang }) {
  const h = c.hero;
  // The mark drawn in code (site.js, "Code art"): a canvas behind the whole first screen; the figure sits
  // in .art. Without JavaScript the plain mark stands in. The chips are glass over the code.
  const hero = `<section class="hero4">
  <canvas class="codefield" data-codeart="field" aria-hidden="true"></canvas>
  <div class="container hero4-inner">
    <div class="hero4-text">
      <p class="pill-eyebrow glass">${glyph(14)}<span>${inline(h.eyebrow, lang)}</span></p>
      <h1 class="mega">${inline(h.title, lang)}</h1>
      <p class="lead">${inline(h.lead, lang)}</p>
      <div class="btn-row">${btn('download.html', h.primary, 'primary', { size: 'lg', iconName: 'download', lang })}${btn('features.html', h.secondary, 'secondary', { size: 'lg', lang })}</div>
      <p class="hero-dots">${h.meta.map((m) => `<span>${icon('check', 13)}${inline(m, lang)}</span>`).join('')}</p>
    </div>
    <div class="art" data-art>
      <div class="art-fallback" aria-hidden="true">${glyph(380, '#2A2F3A')}</div>
      ${c.art.chips.map((p, i) => `<span class="achip glass ${i ? 'r' : 'l'}" style="--i:${i}">${avatar(p.name, [2, 3][i], 22)}<span class="an"><b>${esc(p.name)}</b><code>${esc(p.id)}</code></span>${flag(p.code, 16)}</span>`).join('')}
      <p class="visually-hidden">${esc(c.art.label)}</p>
    </div>
  </div>
</section>`;

  const t = c.tiles;
  const safari = `<article class="tile w7" data-tile="safari">
    <div class="ttext"><h3>${inline(t.safari.title, lang)}</h3><p>${inline(t.safari.text, lang)}</p></div>
    <div class="viz scan">
      <span class="scanbar" aria-hidden="true"></span>
      ${t.safari.rows.map((r) => `<div class="srow ok"><span>${inline(r, lang)}</span><span class="sok">${icon('check', 13)}${inline(t.safari.ok, lang)}</span></div>`).join('')}
      <div class="sfoot">${glyph(14)}<span>${inline(t.safari.foot, lang)}</span></div>
    </div>
  </article>`;

  const p = t.proxy;
  const proxy = `<article class="tile w5" data-tile="proxy">
    <div class="ttext"><h3>${inline(p.title, lang)}</h3><p>${inline(p.text, lang)}</p></div>
    <div class="viz route down">
      <div class="rline">
        <span class="rnode me">${avatar(p.profile, 3, 22)}<b>${esc(p.profile)}</b>${flag('US', 13)}</span>
        <span class="rseg s1"><i class="pk"></i></span>
        <span class="rnode px"><span class="pxic">${icon('network', 15)}</span><b>${esc(p.proxy)}</b><em>${icon('xmark', 11)}${esc(p.down)}</em></span>
        <span class="rseg s2"><i class="pk"></i></span>
        <span class="rnode site">${icon('globe', 15)}<b>${esc(p.site)}</b></span>
      </div>
      <div class="rdirect"><span class="dline"></span><span class="dlabel">${icon('lock', 11)}${esc(p.direct)} — ${esc(p.closed)}</span></div>
      <span class="rhidden">${icon('shieldCheck', 14)}${esc(p.hidden)}</span>
    </div>
  </article>`;

  const s = t.isolation;
  const isolation = `<article class="tile" data-tile="isolation">
    <div class="ttext"><h3>${inline(s.title, lang)}</h3><p>${inline(s.text, lang)}</p></div>
    <div class="viz split on">
      ${splitDisc()}
      <div class="side l"><span class="ichip">${avatar(s.left.name, 2, 18)}${esc(s.left.name)}${flag(s.left.code, 13)}</span><span class="itag">${s.tags.map(esc).join(' · ')}</span></div>
      <div class="side r"><span class="itag">${s.tags.map(esc).join(' · ')}</span><span class="ichip">${avatar(s.right.name, 3, 18)}${esc(s.right.name)}${flag(s.right.code, 13)}</span></div>
    </div>
  </article>`;

  const w = t.warmup;
  const warmup = `<article class="tile" data-tile="warmup">
    <div class="ttext"><h3>${inline(w.title, lang)}</h3><p>${inline(w.text, lang)}</p></div>
    <div class="viz warm2">
      <div class="wbig"><span class="n" data-count-to="84">84</span><span class="u">${esc(w.unit)}</span></div>
      <div class="wp">${ring(4 / 12, 14)}<span>${esc(w.page)}</span>${flag('SE', 13)}</div>
      <div class="wbar"><i style="width:33.3%"></i></div>
      <div class="wsites">${SE_SITES.map((x, i) => `<span class="${i < 4 ? 'done' : 'todo'}">${icon(i < 4 ? 'check' : 'minus', 10)}${x}</span>`).join('')}</div>
    </div>
  </article>`;

  const e = t.encryption;
  const encryption = `<article class="tile" data-tile="encryption">
    <div class="ttext"><h3>${inline(e.title, lang)}</h3><p>${inline(e.text, lang)}</p></div>
    <div class="viz cipher">
      ${e.items.map((x) => `<div class="crow"><span>${esc(x)}</span><code class="cbits" data-cipher>••••••••••••</code><span class="clock">${icon('lockFill', 12)}</span></div>`).join('')}
      <span class="tag accent ctag">${icon('key', 12)}${esc(e.tag)}</span>
    </div>
  </article>`;

  const bento = `<section class="bento-sec"><div class="container">
    <h2 class="h2 big">${inline(c.bentoTitle, lang)}</h2>
    <div class="bento">${safari}${proxy}${isolation}${warmup}${encryption}</div>
  </div></section>`;

  const pr = c.proof;
  const proof = `<section class="proof3"><div class="container">
    <div class="bignums">${pr.stats.map((x) => `<div><div class="bn"><span data-count-to="${esc(x.n)}">${esc(x.n)}</span>${x.of ? `<small>/${esc(x.of)}</small>` : ''}</div><div class="bt">${inline(x.t, lang)}</div></div>`).join('')}</div>
    <p class="center-text" style="margin-top:28px">${linkArrow('verification.html', pr.link, lang)}</p>
  </div></section>`;

  const ct = c.cta;
  const cta = `<section class="final"><div class="container center-text">
    <div class="final-art"><canvas data-codeart="mark" aria-hidden="true"></canvas><div class="art-fallback">${glyph(96, '#2A2F3A')}</div></div>
    <h2 class="mega" style="margin-top:28px;font-size:56px;line-height:60px">${inline(ct.title, lang)}</h2>
    <p class="lead" style="margin:16px auto 0;max-width:560px">${inline(ct.lead, lang)}</p>
    <div class="btn-row center" style="margin-top:32px">${btn('download.html', ct.primary, 'primary', { size: 'lg', iconName: 'download', lang })}${btn('pricing.html', ct.secondary, 'secondary', { size: 'lg', lang })}</div>
  </div></section>`;

  return { body: [hero, bento, proof, cta].join('\n'), bodyClass: 'page-home' };
}
