// Scene "numbers": the product in numbers, after Apple's display pages. The first figure stands alone,
// huge, over a macro shot of a display showing the product's own code — every pixel three subpixel
// stripes, in the brand's blues, with a shallow depth of field (assets/scenes/numbers/display.webp, a
// still picture made once). The other figures follow in a row of columns, then the cipher, wide.
// With scenes the camera drifts along the line of code as the section passes and each figure comes up
// with the scroll (numbers.js; scroll-tied, nothing moves on its own; no counting, so no figure ever
// shows a value that is not a fact). Without scenes: the finished picture. Numbers only from
// copy/facts.mjs.
import { inline, esc } from '../../../lib/html.mjs';
import { linkArrow } from '../../components.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/numbers.css'], scripts: ['scenes/numbers.js'] };

const value = (x) => x.code
  ? `<span class="nm-n nm-code"><code>${esc(x.code)}</code></span>`
  : `<span class="nm-n">${esc(x.n)}${x.of ? `<span class="nm-of">/${esc(x.of)}</span>` : ''}</span>`;

export default function numbers(N, { lang }) {
  const [first, ...rest] = N.items;
  const wide = rest.filter((x) => x.code), cols = rest.filter((x) => !x.code);
  return `<section class="sc-numbers" data-scene="numbers" data-title="${esc(N.title)}">
  <div class="container nm-top">
    <h2 class="h-xl nm-head">${twoTone(N.head, lang)}</h2>
  </div>
  <div class="nm-hero">
    <div class="nm-macro" aria-hidden="true"><img src="../assets/scenes/numbers/display.webp" width="2880" height="1600" alt="" decoding="async"></div>
    <div class="nm-fig nm-first">${value(first)}<p class="nm-t">${inline(first.t, lang)}</p></div>
  </div>
  <div class="container nm-body">
    <div class="nm-cols">${cols.map((x, i) => `<div class="nm-col nm-fig" style="--c:${i}">${value(x)}<p class="nm-t">${inline(x.t, lang)}</p></div>`).join('')}</div>
    ${wide.map((x) => `<div class="nm-wide nm-fig">${value(x)}<p class="nm-t">${inline(x.t, lang)}</p></div>`).join('')}
    <p class="nm-link">${linkArrow('verification.html', N.link, lang)}</p>
  </div>
</section>`;
}
