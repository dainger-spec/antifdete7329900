// Scene "hero": the first screen. A MacBook Pro in Space Black, rendered offline (tools/hero/render.mjs) as a
// sequence of frames the page scrubs with the scroll on a <canvas>, after Apple's product pages: its display
// shows the Lumen mark in code; the camera comes round and the mark's left half lifts out of the glass towards
// us, the right half stays on the screen. Above it the headline, a lead, the button and a text link; as the
// scene ends, the closing line takes the headline's place. Without scenes (no JavaScript, Reduce Motion,
// shots) the section shows the words and the last frame, still.
import { inline, esc } from '../../../lib/html.mjs';
import { icon } from '../../../lib/kit.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/hero.css'], scripts: ['scenes/hero.js'] };

// Frame sets (tools/hero/render.mjs FRAMINGS): landscape 16:10 and portrait 9:16; top = where the Mac's lid
// begins in the first frame (a fraction of the frame's height), so the page can keep it clear of the words.
const FRAMES = { d: { n: 72, w: 1920, h: 1200, top: 0.492 }, m: { n: 60, w: 1080, h: 1920, top: 0.539 } };
const DIR = '../assets/scenes/hero';

export default function scene(c, { lang }) {
  const sets = Object.entries(FRAMES).map(([k, f]) => `data-${k}="${DIR}/${k}/|${f.n}|${f.w}|${f.h}|${f.top}"`).join(' ');
  return `<section class="scene sc-hero" data-scene="hero" data-title="${esc(c.section)}" style="--len:320vh">
  <div class="scene-pin">
    <div class="hr-stage" aria-hidden="true" ${sets}>
      <picture class="hr-still">
        <source media="(max-width: 599px)" srcset="${DIR}/m-final.jpg" width="${FRAMES.m.w}" height="${FRAMES.m.h}">
        <img src="${DIR}/d-final.jpg" width="${FRAMES.d.w}" height="${FRAMES.d.h}" alt="" decoding="async" loading="lazy">
      </picture>
      <canvas class="hr-film"></canvas>
    </div>
    <div class="hr-copy" data-r="0.015 0.2">
      <h1 class="hr-title">${twoTone(c.title, lang)}</h1>
      <p class="hr-lead">${inline(c.lead, lang)}</p>
      <p class="hr-cta">
        <a class="btn primary lg" href="download.html">${inline(c.primary, lang)}</a>
        <a class="hr-more" href="features.html">${inline(c.secondary, lang)}${icon('chevronRight', 14)}</a>
      </p>
    </div>
    <p class="hr-caption" data-r="0.66 0.8">${twoTone(c.caption, lang)}</p>
    <p class="visually-hidden">${inline(c.label, lang)}</p>
  </div>
</section>`;
}
