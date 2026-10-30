// Scene "cta": the last call. The Lumen mark, drawn in characters of code (site.js "Code art"), large:
// its two halves — two profiles, each with its own values — come together from apart as the section
// rises up the screen, and the seam of light between them comes on when they meet (cta.js; scroll-tied,
// nothing moves on its own). Then the offer and the two buttons. Without scenes: the mark whole, lit.
// Without JavaScript: the plain mark (.art-fallback).
import { inline } from '../../../lib/html.mjs';
import { glyph } from '../../../lib/kit.mjs';
import { btn } from '../../components.mjs';

export const assets = { styles: ['scenes/cta.css'], scripts: ['scenes/cta.js'] };

export default function cta(ct, { lang }) {
  return `<section class="sc-cta" data-scene="cta">
  <div class="container ct-wrap">
    <div class="ct-art" aria-hidden="true">
      <i class="ct-glow"></i>
      <canvas class="ct-half ct-l"></canvas><canvas class="ct-half ct-r"></canvas><canvas class="ct-seam"></canvas>
      <div class="art-fallback">${glyph(150, '#4A5263')}</div>
    </div>
    <h2 class="h-xxl ct-title">${inline(ct.title, lang)}</h2>
    <p class="lead ct-lead">${inline(ct.lead, lang)}</p>
    <div class="btn-row center ct-btns">${btn('download.html', ct.primary, 'primary', { size: 'lg', iconName: 'download', lang })}${btn('pricing.html', ct.secondary, 'secondary', { size: 'lg', lang })}</div>
  </div>
</section>`;
}
