// Scene "encryption": a profile's data, sealed. A window of the profile "Store" (the same profile, password
// and pages the other scenes show) with five real-looking rows: a saved password, cookies, a history entry, a
// bookmark and site data. As you scroll, a line of light at the angle of the mark's seam sweeps across it and
// every field it passes is ciphertext behind it (CSS: two copies of the window's face clipped at the line; the
// light is clipped to the window). Then the window's chrome falls away, the lines of ciphertext slide onto one
// grid and close into a block, and a second pass of the same light carves a lock out of the block, lit like
// the mark (assets/scenes/encryption.js, canvas). The lead gives way to the key line (only you know the master
// password) and the scene ends on AES-256-GCM and Argon2id, then holds.
// Without scenes (no JavaScript, Reduce Motion, shots) it is one still: the headline and the key line, the
// window half sealed, the lock beside it (drawn by the script; without JavaScript a picture of the same lock,
// assets/scenes/encryption/lock.png), the two names under them. The window is sample data ([data-sample]).
import { inline, esc } from '../../../lib/html.mjs';
import { avatar } from '../../components.mjs';
import { flag } from '../../../lib/kit.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/encryption.css'], scripts: ['scenes/encryption.js'] };

// Ciphertext that looks like the real thing (base64 of AES-GCM output) and is the same on every build:
// a small seeded generator, one stream per field. (The script uses the same one for the block's new rows.)
const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
export function cipher(seed, n) {
  let s = seed >>> 0;
  let out = '';
  for (let i = 0; i < n; i++) {
    s = (s + 0x6D2B79F5) >>> 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    out += B64[((t ^ (t >>> 14)) >>> 0) % 64];
  }
  return out;
}

function row(r, i, sealed, lang) {
  const k = 977 * (i + 1);
  const tile = sealed ? '<span class="enc-tile"></span>' : `<span class="enc-tile">${esc(r.tile)}</span>`;
  const t = sealed ? `<span class="enc-t ct">${esc(cipher(k + 2, 72))}</span>` : `<span class="enc-t">${esc(r.t)}</span>`;
  const s = sealed
    ? `<span class="enc-s ct">${esc(cipher(k + 3, 72))}</span>`
    : `<span class="enc-s">${esc(r.s)}${r.secret ? '<span class="enc-dots">••••<span class="enc-dots-2">••</span><span class="enc-dots-3">••••</span></span>' : ''}</span>`;
  return `<li class="enc-row">${tile}<span class="enc-txt">${t}${s}</span><span class="enc-kind">${inline(r.kind, lang)}</span></li>`;
}

// One face of the window: a unified title bar (traffic lights, the profile, its country and locale) and the rows.
function face(c, sealed, lang) {
  return `<div class="enc-face ${sealed ? 'enc-sealed' : 'enc-plain'}">
        <div class="enc-bar"><span class="traffic color"><i></i><i></i><i></i></span>${avatar(c.profile.name, 0, 24)}<span class="enc-name">${esc(c.profile.name)}</span><span class="enc-meta">${flag('DE', 14)}<span>${esc(c.profile.lang)}<span class="enc-meta-tz"> · ${esc(c.profile.zone)}</span></span></span></div>
        <ul class="enc-rows">${c.rows.map((r, i) => row(r, i, sealed, lang)).join('')}</ul>${sealed ? '<i class="enc-sheen"></i>' : ''}
      </div>`;
}

export default function scene(c, { lang }) {
  return `<section class="scene sc-encryption" data-scene="encryption" data-title="${esc(c.title)}" style="--len:400vh">
  <div class="scene-pin"><div class="container enc">
    <div class="enc-head">
      <h2 class="h-xl">${twoTone(c.head, lang)}</h2>
      <div class="enc-say" data-r="0.64 0.72">
        <p class="lead enc-lead">${inline(c.lead, lang)}</p>
        <p class="lead enc-key">${inline(c.key, lang)}</p>
      </div>
      <p class="visually-hidden">${inline(c.picture, lang)}</p>
    </div>
    <div class="enc-stage" data-r="0.42 0.7" aria-hidden="true">
      <div class="enc-card" data-r="0.05 0.36" data-sample>
      ${face(c, false, lang)}
      ${face(c, true, lang)}
        <div class="enc-light"><i class="enc-beam"></i><i class="enc-glint enc-glint-t"></i><i class="enc-glint enc-glint-b"></i></div>
      </div>
      <div class="enc-lockbox"></div>
      <canvas class="enc-cv"></canvas>
    </div>
    <div class="enc-foot" data-r="0.71 0.8">
      <dl class="enc-specs">${c.specs.map((x) => `<div><dt>${esc(x.t)}</dt><dd>${inline(x.d, lang)}</dd></div>`).join('')}</dl>
    </div>
  </div></div>
</section>`;
}
