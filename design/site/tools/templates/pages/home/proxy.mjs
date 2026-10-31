// Scene "proxy": the proxy goes down — and there is no connection. One Safari window (macOS 26, dark appearance)
// of the Store profile, Germany, filmed as a short shot in three takes:
//   1. Close-up. The camera sits close on the window's top edge: the profile's chip (flag + name), the address
//      field and, below them, a white sign-in page that fills the screen and lights the room. A quiet line over
//      the window says whose proxy this is. Continue is pressed; Safari's progress bar runs along the address
//      field with the scroll, slows, and stops dead. The line turns: the proxy isn't responding.
//   2. Lights out. The bar goes, the white page and the light it threw go dark (a decisive drop, not a fade),
//      and for a beat the window is empty. Safari's own error comes up.
//   3. Pull back. The camera draws back to the whole window, now under the headline; two captions follow.
//
// Timeline (scene progress, 300vh): 0–0.05 the line "through proxy Berlin 1" · 0.07–0.125 Continue pressed and
// let go · 0.10–0.34 the progress bar runs and slows to a dead stop (the field's Reload is Stop meanwhile) ·
// 0.32–0.38 the line turns to "isn't responding" (out, then in) · 0.43–0.465 the room light dims, 0.435–0.46 the page drops dark,
// Reload is back · 0.46–0.49 a dark beat · from 0.49 Safari's error (later where, close up, it would not fit the
// screen; proxy.js sets --px-err) · 0.48–0.66 the camera draws back (proxy.js) · 0.55–0.575 the line goes ·
// 0.575–0.665 the headline · 0.67–0.75 and 0.76–0.86 the captions (on a phone one at a time: 0.67–0.75 "no way
// around it", which gives way at 0.78–0.82 to the proof, 0.82–0.9). On every screen the close-up is framed by
// proxy.js so that nothing is cut to a sliver and the page runs off the bottom.
//
// The site in the window is sample data (German, as the profile's language follows its proxy's country), so it
// lives here and not in copy/. Without the scenes (no JavaScript, Reduce Motion, shots) the section shows its last
// picture: the headline, the window with Safari's error, the two captions.
import { inline, esc } from '../../../lib/html.mjs';
import { flag } from '../../../lib/kit.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/proxy.css'], scripts: ['scenes/proxy.js'] };

const HOST = 'kontor.example';

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
  reload: svg('<path d="M8 3.4a5 5 0 1 0 4.4 2.6"/><path d="m6.2 1.5 2 1.9-2 1.9"/>'),
  stop: svg('<path d="m4.2 4.2 7.6 7.6M11.8 4.2l-7.6 7.6"/>'),
  bag: svg('<path d="M3.2 5.4h9.6l-.7 8.1a1 1 0 0 1-1 .9H4.9a1 1 0 0 1-1-.9z"/><path d="M5.6 5.4V4.6a2.4 2.4 0 0 1 4.8 0v.8"/>'),
  find: svg('<circle cx="7" cy="7" r="4.6"/><path d="m10.4 10.4 3.6 3.6"/>'),
};

/// The site: a store's sign-in page (German; sample data). Its wordmark and form sit in the middle, so the
/// close-up frames them whole; the icons sit at the edges.
const site = `<div class="pxs">
        <div class="pxs-top"><span class="pxs-ico">${G.find}</span><span class="pxs-logo">Kontor</span><span class="pxs-ico">${G.bag}</span></div>
        <div class="pxs-main">
          <div class="pxs-form">
            <span class="pxs-h">Anmelden</span>
            <span class="pxs-sub">Mit Ihrem Kundenkonto.</span>
            <span class="pxs-label">E-Mail-Adresse</span>
            <span class="pxs-field">anna@mail.example</span>
            <span class="pxs-btn" data-r="0.07 0.085"><b class="pxs-press" data-r="0.095 0.125"></b><span>Weiter</span></span>
            <span class="pxs-alt"><span>Noch kein Kundenkonto?</span> <u>Registrieren</u></span>
          </div>
        </div>
      </div>`;

/// The Safari window (decorative: aria-hidden; its meaning is in the headline, the captions and a sentence).
export function safari(c) {
  const body = esc(c.errorBody).replace(/\{host\}/g, `<i>${HOST}</i>`);
  return `<div class="pxw" aria-hidden="true" data-sample>
      <div class="pxw-bar">
        <span class="pxw-lights"><i></i><i></i><i></i></span>
        <span class="pxw-cap pxw-side">${G.sidebar}${G.chevron}</span>
        <span class="pxw-cap pxw-hist">${G.back}${G.fwd}</span>
        <span class="pxw-cap pxw-prof">${flag('DE', 14)}<span>${esc(c.profile)}</span></span>
        <span class="pxw-addr">
          <span class="pxw-pg">${G.page}</span><span class="pxw-url">${HOST}</span>
          <span class="pxw-rl" data-r="0.098 0.102"><span class="pxw-rl-in" data-r="0.44 0.445">${G.reload}${G.stop}</span></span>
          <span class="pxw-load" data-r="0.43 0.44"><i data-r="0.1 0.34"></i></span>
        </span>
        <span class="pxw-cap pxw-tools">${G.share}${G.plus}${G.tabs}</span>
      </div>
      <div class="pxw-page">
        <div class="pxw-err"><b>${esc(c.errorTitle)}</b><span>${body}</span></div>
        <div class="pxw-site" data-r="0.435 0.46">${site}</div>
      </div>
    </div>`;
}

/// A line of text: a bold start, the rest grey.
const note = ([lead, rest], lang, sub = (s) => s) => `<strong>${sub(inline(lead, lang))}</strong> ${inline(rest, lang)}`;

export default function scene(c, { lang }) {
  const proxyName = (s) => s.replace('{proxy}', `<span class="px-nb" data-sample>${esc(c.proxy)}</span>`);
  return `<section class="scene sc-proxy" data-scene="proxy" data-title="${esc(c.title)}" style="--len:300vh">
  <div class="scene-pin">
    <div class="container px">
      <div class="px-top">
        <p class="px-status px-live" data-r="0 0.05" aria-hidden="true"><span data-r="0.32 0.342">${note(c.live, lang, proxyName)}</span></p>
        <p class="px-status px-drop" data-r="0.35 0.38" aria-hidden="true"><span data-r="0.55 0.575">${note(c.drop, lang, proxyName)}</span></p>
        <h2 class="h-xl px-head" data-r="0.575 0.665">${twoTone(c.head, lang)}</h2>
      </div>
      <div class="px-stage">
        <div class="px-cam">
          <i class="px-light" data-r="0.43 0.465" aria-hidden="true"></i>
          ${safari(c)}
        </div>
        <p class="visually-hidden">${inline(c.label, lang)}</p>
      </div>
      <div class="px-notes">
        <p class="px-note px-closed" data-r="0.67 0.75"><span data-r="0.78 0.82">${note(c.closed, lang)}</span></p>
        <p class="px-note px-proof" data-r="0.76 0.86"><span data-r="0.82 0.9">${note(c.proof, lang)}</span></p>
      </div>
    </div>
  </div>
</section>`;
}
