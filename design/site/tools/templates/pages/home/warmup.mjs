// Scene "warmup": warm-up runs while you work. One Safari window — the profile's hidden window, so it is
// out of focus (grey lights) and its page is seen through reeded glass — goes through the sites of
// Sweden's ready-made list one after another as the scene scrolls: google.se, aftonbladet.se, svt.se, dn.se.
// Each page loads (Safari's blue line in the address field), is read for a while (it scrolls under the
// glass), and the next one comes; on the glass, a large count of cookies climbs and a thin line says
// "Page 4 of 12". The last part of the scene lifts the picture to bring up three short facts.
//
// The window is sample data ([data-sample], aria-hidden): profile "Client" with a Swedish proxy, page 4 of
// 12, 84 cookies — the app's own sample (UISnapshots). The pages under the glass are pictures: mock Swedish
// sites (made-up papers; no real brand is drawn) rendered once, frosted and bent through vertical reeds
// (assets/scenes/warmup/<site>-d.webp: desktop layout, 60 reeds across; -m: phone layout, 18 reeds; the
// CSS draws the same number of reeds' light and shade over them), plus a tiny <site>-glow.webp each for
// the light the page throws around the window. The meaning is in the headline, the lead, a hidden sentence
// and the facts.
//
// Without scenes (no JavaScript, Reduce Motion, shots) it is the finished picture: dn.se, page 4 of 12,
// 84 cookies, the facts under the window.
import { inline, esc } from '../../../lib/html.mjs';
import { flag } from '../../../lib/kit.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/warmup.css'], scripts: ['scenes/warmup.js'] };

/// The visited part of the list. cookies: the running count after the site; read: how far down the page
/// the reader gets (a share of what is below the fold). The script reads both from data attributes.
const SITES = [
  { host: 'google.se', img: 'google', cookies: 7, read: 0 },
  { host: 'aftonbladet.se', img: 'afton', cookies: 39, read: 0.42 },
  { host: 'svt.se', img: 'svt', cookies: 58, read: 0.5 },
  { host: 'dn.se', img: 'dn', cookies: 84, read: 0.3 },
];
const TOTAL = 12;
const DIR = '../assets/scenes/warmup';

// SF Symbols-like toolbar glyphs, 16 px, 1.5 px strokes.
const svg = (body, w = 16) => `<svg width="${w}" height="16" viewBox="0 0 ${w} 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;
const G = {
  page: svg('<rect x="3.25" y="1.75" width="9.5" height="12.5" rx="1.8"/><path d="M5.75 5.5h4.5M5.75 8h4.5M5.75 10.5h2.5"/>'),
  share: svg('<path d="M8 1.75v8.5M5 4.5 8 1.6l3 2.9"/><path d="M5.2 6.6H4.4a1.6 1.6 0 0 0-1.6 1.6v4.6a1.6 1.6 0 0 0 1.6 1.6h7.2a1.6 1.6 0 0 0 1.6-1.6V8.2a1.6 1.6 0 0 0-1.6-1.6h-.8"/>'),
  plus: svg('<path d="M8 2.5v11M2.5 8h11"/>'),
  tabs: svg('<rect x="1.75" y="4.75" width="10" height="9.5" rx="1.8"/><path d="M4.75 2.25h7.5a2 2 0 0 1 2 2v7"/>', 17),
};

function win(c) {
  const last = SITES.length - 1;
  const page = (n) => esc(c.page).replace('{n}', `<span class="wu-pn">${n}</span>`).replace('{total}', String(TOTAL));
  return `<div class="wu-win" aria-hidden="true" data-sample data-total="${TOTAL}">
        <div class="wu-bar">
          <span class="wu-lights"><i></i><i></i><i></i></span>
          <span class="wu-cap wu-prof">${flag('SE', 14)}<span>${esc(c.profile)}</span></span>
          <span class="wu-addr"><span class="wu-pgi">${G.page}</span><span class="wu-hosts">${SITES.map((s, k) =>
            `<span class="wu-host${k === last ? ' on' : ''}">${esc(s.host)}</span>`).join('')}</span><i class="wu-load"></i></span>
          <span class="wu-cap wu-tools">${G.share}${G.plus}${G.tabs}</span>
        </div>
        <div class="wu-view">
          ${SITES.map((s, k) => `<picture class="wu-pg${k === last ? ' on' : ''}" data-cookies="${s.cookies}" data-read="${s.read}"><source media="(max-width: 599px)" srcset="${DIR}/${s.img}-m.webp"><img src="${DIR}/${s.img}-d.webp" alt="" decoding="async"></picture>`).join('\n          ')}
          <i class="wu-tint"></i>
          <span class="wu-cap-hidden">${esc(c.hidden)}</span>
          <div class="wu-read">
            <div class="wu-count"><span class="wu-n">${SITES[last].cookies}</span><span class="wu-unit">${esc(c.unit)}</span></div>
            <div class="wu-prog">
              <span class="wu-pgno">${page(SITES.length)}</span>
              <span class="wu-track"><i style="--f:${(SITES.length / TOTAL).toFixed(4)}"></i></span>
            </div>
          </div>
        </div>
      </div>`;
}

export default function scene(c, { lang }) {
  return `<section class="scene sc-warmup" data-scene="warmup" data-title="${esc(c.title)}" style="--len:460vh">
  <div class="scene-pin"><div class="container wu" data-r="0.85 1">
    <div class="wu-a">
      <div class="wu-head">
        <h2 class="h-xl wu-h">${twoTone(c.head, lang)}</h2>
        <p class="lead wu-lead wu-wide">${inline(c.lead, lang)}</p>
        <p class="visually-hidden">${inline(c.picture, lang)}</p>
      </div>
      <div class="wu-stage" data-r="0 0.08">
        <div class="wu-spill" aria-hidden="true">${SITES.map((s, k) => `<i${k === SITES.length - 1 ? ' class="on"' : ''} style="background-image:url(${DIR}/${s.img}-glow.webp)"></i>`).join('')}</div>
        ${win(c)}
      </div>
    </div>
    <div class="wu-b">
      <p class="lead wu-lead wu-narrow">${inline(c.lead, lang)}</p>
      <div class="wu-facts">${c.facts.map((f) => `<p>${inline(f, lang)}</p>`).join('')}</div>
    </div>
  </div></div>
</section>`;
}
