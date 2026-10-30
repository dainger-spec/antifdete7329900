// Scene "numbers": strength in numbers — a column of facts over a texture of code tinted like a display's
// subpixels; a light follows the scroll down it. Numbers only from copy/facts.mjs.
import { inline, esc } from '../../../lib/html.mjs';
import { linkArrow } from '../../components.mjs';

export const assets = { styles: ['scenes/numbers.css'], scripts: ['scenes/numbers.js'] };

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

export default function numbers(N, { lang }) {
  return `<section class="nums" data-scene="numbers" data-title="${esc(N.title)}">
  <div class="nm-bg" aria-hidden="true" style="--tile:url(&quot;${pixelTile()}&quot;)"><i class="nm-lit"></i></div>
  <div class="container nm-list">
    <h2 class="h-xl center-text reveal">${inline(N.head, lang)}</h2>
    ${N.items.map((x) => `<div class="nm-item reveal">${x.code ? `<span class="nm-n nm-code"><code>${esc(x.code)}</code></span>` : `<span class="nm-n"><span data-count="${esc(x.n)}">${esc(x.n)}</span>${x.of ? `<small> / ${esc(x.of)}</small>` : ''}</span>`}<span class="nm-t">${inline(x.t, lang)}</span></div>`).join('')}
    <p class="center-text reveal nm-link">${linkArrow('verification.html', N.link, lang)}</p>
  </div>
</section>`;
}
