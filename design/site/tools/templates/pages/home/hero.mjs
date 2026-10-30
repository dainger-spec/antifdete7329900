// Scene "hero": the first screen. A MacBook Pro in Space Black, rendered offline (tools/hero/render.mjs) as a
// sequence of frames the page scrubs with the scroll on a <canvas>, after Apple's product pages: its display
// shows the Lumen mark in code; the camera comes closer and round, and the mark's left half lifts out of the
// glass towards us, the right half stays on the screen. Above it the headline, a lead, the button and a text
// link; as the scene ends, the closing line comes in (at the top on desktop, at the bottom on phones).
// Without scenes (no JavaScript, Reduce Motion, shots) the section shows the words and the last frame, still.
import fs from 'node:fs';
import { inline, esc } from '../../../lib/html.mjs';
import { icon } from '../../../lib/kit.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/hero.css'], scripts: ['scenes/hero.js'] };

// Frame sets (tools/hero/render.mjs FRAMINGS): landscape 16:10 and portrait 9:16. tools/hero/layout.json
// (written by the render) says where the Mac and the floating half land in every frame; the page needs the
// first frame's Mac (lid top, base bottom) and the last frame's whole picture (top of the half or the lid,
// base bottom), as fractions of the frame's height, to keep them clear of the words.
const LAYOUT = JSON.parse(fs.readFileSync(new URL('../../../hero/layout.json', import.meta.url), 'utf8'));
const SIZE = { d: { w: 2560, h: 1600 }, m: { w: 1080, h: 1920 } };
const DIR = '../assets/scenes/hero';
function frames(k) {
  const L = LAYOUT[k], { w, h } = SIZE[k], f0 = L[0], f1 = L[L.length - 1];
  // the half's box is its padded texture quad (2.5 radii square): the characters reach about 0.8 of it
  const half = f1.half ? (f1.half[1] + f1.half[3]) / 2 - 0.82 * ((f1.half[3] - f1.half[1]) / 2) : Infinity;
  const r = (v) => (v / h).toFixed(4);
  return { n: L.length, w, h, a: `${r(f0.box[1])},${r(f0.box[3])}`, z: `${r(Math.min(half, f1.box[1]))},${r(f1.box[3])}` };
}

export default function scene(c, { lang }) {
  const F = { d: frames('d'), m: frames('m') };
  const sets = Object.entries(F).map(([k, f]) => `data-${k}="${DIR}/${k}/|${f.n}|${f.w}|${f.h}|${f.a}|${f.z}|${DIR}/${k}-poster.jpg"`).join(' ');
  return `<section class="scene sc-hero" data-scene="hero" data-title="${esc(c.section)}" style="--len:260vh">
  <div class="scene-pin">
    <div class="hr-stage" aria-hidden="true" ${sets}>
      <picture class="hr-still">
        <source media="(max-width: 599px)" srcset="${DIR}/m-final.jpg" width="${F.m.w}" height="${F.m.h}">
        <img src="${DIR}/d-final.jpg" width="${F.d.w}" height="${F.d.h}" alt="" decoding="async" loading="lazy">
      </picture>
      <canvas class="hr-film"></canvas>
    </div>
    <div class="hr-copy" data-r="0.012 0.17">
      <h1 class="hr-title">${twoTone(c.title, lang)}</h1>
      <p class="hr-lead">${inline(c.lead, lang)}</p>
      <p class="hr-cta">
        <a class="btn primary lg" href="download.html">${inline(c.primary, lang)}</a>
        <a class="hr-more" href="features.html">${inline(c.secondary, lang)}${icon('chevronRight', 14)}</a>
      </p>
    </div>
    <p class="hr-caption" data-r="0.7 0.84">${twoTone(c.caption, lang)}</p>
    <p class="visually-hidden">${inline(c.label, lang)}</p>
  </div>
</section>`;
}
