// Scene "proxy": the proxy goes down — and there is no connection. One Safari window (macOS 26, dark appearance)
// of the Store profile, Germany. The scene opens close on its toolbar: a sign-in page is open, lit white, loaded
// through the proxy. The camera draws back; Continue is pressed and Safari's progress bar runs along the address
// field with the scroll — then stops dead: the proxy has stopped answering. The bar goes, the page's light goes
// out, and Safari shows its own error. A quiet line above the window follows it ("Through the proxy Berlin 1" →
// "The proxy Berlin 1 isn't answering"), then gives way to the headline; two captions come up under the window.
//
// Timeline (scene progress, 360vh): 0–0.22 the camera draws back from the toolbar to the middle of the screen
// (proxy.js) · 0.15–0.21 "Through the proxy Berlin 1" · 0.17–0.2 Continue pressed · 0.2–0.36 the progress bar runs
// and slows to a stop · 0.355–0.395 the line turns to "isn't answering" · 0.39–0.42 the bar goes · 0.4–0.46 the page
// and its light go out · 0.465–0.53 Safari's error · 0.5–0.62 the window settles under the headline · 0.56–0.66 the
// headline · 0.6–0.68 and 0.65–0.73 the captions (on a phone one at a time: the proof takes the place of "never
// around it" at 0.76–0.86).
//
// The site in the window is sample data (German, as the profile's language follows its proxy's country), so it
// lives here and not in copy/. Without the scenes (no JavaScript, Reduce Motion, shots) the section shows its last
// picture: the headline, the window with Safari's error, the two captions.
import { inline, esc } from '../../../lib/html.mjs';
import { flag } from '../../../lib/kit.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/proxy.css'], scripts: ['scenes/proxy.js'] };

const HOST = 'atelier-nord.example';

// SF Symbols-like toolbar glyphs, drawn at 16 px (1.5 px strokes).
const svg = (body, w = 16) => `<svg width="${w}" height="16" viewBox="0 0 ${w} 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;
const G = {
  sidebar: svg('<rect x="1.75" y="2.75" width="14.5" height="10.5" rx="2.4"/><path d="M6.5 2.75v10.5"/><path d="M3.6 5.6h1.2M3.6 7.6h1.2"/>', 18),
  back: svg('<path d="M10 3 5 8l5 5"/>'),
  fwd: svg('<path d="m6 3 5 5-5 5"/>'),
  page: svg('<rect x="3.25" y="1.75" width="9.5" height="12.5" rx="1.8"/><path d="M5.75 5.5h4.5M5.75 8h4.5M5.75 10.5h2.5"/>'),
  share: svg('<path d="M8 1.75v8.5M5 4.5 8 1.6l3 2.9"/><path d="M5.2 6.6H4.4a1.6 1.6 0 0 0-1.6 1.6v4.6a1.6 1.6 0 0 0 1.6 1.6h7.2a1.6 1.6 0 0 0 1.6-1.6V8.2a1.6 1.6 0 0 0-1.6-1.6h-.8"/>'),
  plus: svg('<path d="M8 2.5v11M2.5 8h11"/>'),
  tabs: svg('<rect x="1.75" y="4.75" width="10" height="9.5" rx="1.8"/><path d="M4.75 2.25h7.5a2 2 0 0 1 2 2v7"/>', 17),
  chevron: '<svg width="9" height="9" viewBox="0 0 9 9" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="m2 3.4 2.5 2.5L7 3.4"/></svg>',
  bag: svg('<path d="M3.2 5.4h9.6l-.7 8.1a1 1 0 0 1-1 .9H4.9a1 1 0 0 1-1-.9z"/><path d="M5.6 5.4V4.6a2.4 2.4 0 0 1 4.8 0v.8"/>'),
};

/// The site: a store's sign-in page (German; sample data).
const site = `<div class="pxs">
        <div class="pxs-top"><span class="pxs-logo">Atelier Nord</span><span class="pxs-right"><span class="pxs-nav"><span>Kollektion</span><span>Journal</span><span>Hilfe</span></span><span class="pxs-bag">${G.bag}</span></span></div>
        <div class="pxs-main">
          <div class="pxs-form">
            <span class="pxs-h">Anmelden</span>
            <span class="pxs-sub">Mit Ihrem Kundenkonto bei Atelier Nord.</span>
            <span class="pxs-label">E-Mail-Adresse</span>
            <span class="pxs-field">anna.berg@mail.example</span>
            <span class="pxs-btn" data-r="0.17 0.2"><span>Weiter</span></span>
            <span class="pxs-alt">Noch kein Kundenkonto? <u>Registrieren</u></span>
          </div>
        </div>
      </div>`;

/// The Safari window (decorative: aria-hidden; its meaning is in the headline, the captions and a sentence).
function safari(c) {
  const body = esc(c.errorBody).replace(/\{host\}/g, `<i>${HOST}</i>`);
  return `<div class="pxw" aria-hidden="true" data-sample>
      <div class="pxw-bar">
        <span class="pxw-lights"><i></i><i></i><i></i></span>
        <span class="pxw-cap pxw-side">${G.sidebar}${G.chevron}</span>
        <span class="pxw-cap pxw-hist">${G.back}${G.fwd}</span>
        <span class="pxw-cap pxw-prof">${flag('DE', 14)}<span>${esc(c.profile)}</span></span>
        <span class="pxw-addr"><span class="pxw-pg">${G.page}</span><span class="pxw-url">${HOST}</span><span class="pxw-load" data-r="0.39 0.42"><i data-r="0.2 0.36"></i></span></span>
        <span class="pxw-cap pxw-tools">${G.share}${G.plus}${G.tabs}</span>
      </div>
      <div class="pxw-page">
        <div class="pxw-err" data-r="0.465 0.53"><b>${esc(c.errorTitle)}</b><span>${body}</span></div>
        <div class="pxw-site" data-r="0.4 0.46">${site}</div>
      </div>
    </div>`;
}

/// A caption: a bold start, the rest grey.
const note = ([lead, rest], lang, sub = (s) => s) => `<strong>${sub(inline(lead, lang))}</strong> ${inline(rest, lang)}`;

export default function scene(c, { lang }) {
  const proxyName = (s) => s.replace('{proxy}', `<span class="px-nb" data-sample>${esc(c.proxy)}</span>`);
  return `<section class="scene sc-proxy" data-scene="proxy" data-title="${esc(c.title)}" style="--len:360vh">
  <div class="scene-pin">
    <div class="container px">
      <div class="px-top">
        <p class="px-status px-live" data-r="0.15 0.21" aria-hidden="true"><span data-r="0.355 0.375">${note(c.live, lang, proxyName)}</span></p>
        <p class="px-status px-drop" data-r="0.375 0.395" aria-hidden="true"><span data-r="0.5 0.53">${note(c.drop, lang, proxyName)}</span></p>
        <h2 class="h-xl px-head" data-r="0.56 0.66">${twoTone(c.head, lang)}</h2>
      </div>
      <div class="px-stage">
        <div class="px-cam">
          <i class="px-light" data-r="0.4 0.46" aria-hidden="true"></i>
          ${safari(c)}
        </div>
        <p class="visually-hidden">${inline(c.label, lang)}</p>
      </div>
      <div class="px-notes">
        <p class="px-note px-closed" data-r="0.6 0.68"><span data-r="0.76 0.8">${note(c.closed, lang)}</span></p>
        <p class="px-note px-proof" data-r="0.65 0.73"><span data-r="0.8 0.86">${note(c.proof, lang)}</span></p>
      </div>
    </div>
  </div>
</section>`;
}
