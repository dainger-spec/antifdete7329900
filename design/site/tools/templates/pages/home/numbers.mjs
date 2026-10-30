// Scene "numbers": strength in numbers, after Apple's display pages — big figures over a field of code
// seen close up, like a display's subpixels; the code is tinted in the brand's blues only. A soft light
// follows the scroll down the field (CSS, --p of the scene). Each figure climbs to its value as it
// comes up the screen (numbers.js, with scenes only). Numbers only from copy/facts.mjs.
//
// Layout: the first figure alone and large; then the figures in pairs; a figure given as `code` (the
// cipher) closes the column, wide.
import { inline, esc } from '../../../lib/html.mjs';
import { linkArrow } from '../../components.mjs';

export const assets = { styles: ['scenes/numbers.css'], scripts: ['scenes/numbers.js'] };

// The field: the product's own code, as the first screen's field draws it (site.js "Code art"), set
// in a fixed grid so the tile repeats without a seam whatever monospace font draws it.
const CODE = [
  'profile.store { exit: "DE"; lang: "de-DE"; tz: "Europe/Berlin"; proxy: socks5 }',
  'profile.ads { exit: "US"; lang: "en-US"; tz: "America/New_York"; proxy: https }',
  'cookies(profile) -> own; passwords(profile) -> own; history(profile) -> own',
  'webkit.process(per: profile); window = safari',
  'route(profile) = proxy; direct = closed; udp = closed; webrtc = closed',
  'tls.handshake == safari; headers.order == safari; http2 == safari',
  'vault.seal(aes-256-gcm, key: argon2id(master))',
  'warmup(profile, sites: country(proxy)) -> cookies',
];
const COLS = 90, ROWS = 32, CW = 7.2, LH = 16;

/// One tile of the field as an SVG data: URL. `tones`: a fill per column in turn (a subpixel triad).
/// Every character is placed on the grid by its own x, so no font can drift it off the tile's edge.
function tile(tones, size = 11) {
  const ch = (i, j) => { const line = CODE[j % CODE.length] + '    '; return line[(i + j * 23) % line.length]; };
  const xml = (c) => (c === '&' ? '&amp;' : c === '<' ? '&lt;' : c === '>' ? '&gt;' : c);
  const rows = [];
  for (let j = 0; j < ROWS; j++) {
    for (let k = 0; k < tones.length; k++) {
      const xs = [], cs = [];
      for (let i = k; i < COLS; i += tones.length) { const c = ch(i, j); if (c !== ' ') { xs.push(+(i * CW).toFixed(1)); cs.push(xml(c)); } }
      if (cs.length) rows.push(`<text y="${(j * LH + LH * 0.72).toFixed(1)}" x="${xs.join(' ')}" fill="${tones[k]}">${cs.join('')}</text>`);
    }
  }
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${(COLS * CW).toFixed(1)}" height="${ROWS * LH}" font-family="SF Mono,ui-monospace,Menlo,DejaVu Sans Mono,monospace" font-size="${size}">${rows.join('')}</svg>`;
  return `url("data:image/svg+xml,${encodeURIComponent(svg).replace(/'/g, '%27').replace(/"/g, '%22')}")`;
}

const figure = (x, cls, lang) => `<div class="nm-item ${cls} reveal">${x.code
  ? `<span class="nm-n nm-code"><code>${esc(x.code)}</code></span>`
  : `<span class="nm-n"><span class="nm-v" data-count="${esc(x.n)}">${esc(x.n)}</span>${x.of ? `<span class="nm-of">/${esc(x.of)}</span>` : ''}</span>`}<p class="nm-t">${inline(x.t, lang)}</p></div>`;

export default function numbers(N, { lang }) {
  const [first, ...rest] = N.items;
  const wide = rest.filter((x) => x.code), pairs = rest.filter((x) => !x.code);
  const base = tile(['#AFC3EE']), lit = tile(['#7FA2F5', '#A9C2FF', '#DCE6FF']);
  return `<section class="sc-numbers" data-scene="numbers" data-title="${esc(N.title)}" style="--tile-base:${esc(base)};--tile-lit:${esc(lit)}">
  <div class="nm-field" aria-hidden="true"><i class="nm-base"></i><i class="nm-lit"></i></div>
  <div class="container nm-wrap">
    <h2 class="h-xl nm-head reveal">${inline(N.head, lang)}</h2>
    ${figure(first, 'nm-hero', lang)}
    <div class="nm-pairs">${pairs.map((x) => figure(x, 'nm-pair', lang)).join('')}</div>
    ${wide.map((x) => figure(x, 'nm-wide', lang)).join('')}
    <p class="nm-link reveal">${linkArrow('verification.html', N.link, lang)}</p>
  </div>
</section>`;
}
