// Scene "bento": everything else Safari users expect, as a grid of tiles. Each tile: a title and one
// sentence (white, then grey, in one run, as Apple sets them), and under it a piece of the app's own
// interface — the password prompt, the History window, the cookie import sheet, two Macs in sync, the
// export sheet and its file, an ephemeral profile — drawn on the app's tokens, in its own words
// (Localizable.strings). The pictures bleed off the tile's lower edge like a product shot.
// Everything inside a picture is decorative (aria-hidden) and sample data (data-sample).
import { inline, esc } from '../../../lib/html.mjs';
import { icon, glyph } from '../../../lib/kit.mjs';
import { linkArrow, avatar } from '../../components.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/bento.css'] };

const MAG = '<svg class="icon" width="13" height="13" viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="4.6" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M10.4 10.4L14 14" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>';
const tl = '<span class="mw-tl"><i></i><i></i><i></i></span>';

function passwords(P) {
  return `<div class="pw-win">
      <div class="mw-bar">${tl}<span class="mw-nav">${icon('chevronLeft', 13)}${icon('chevronRight', 13)}</span><span class="mw-url">${icon('lockFill', 9)}${esc(P.site)}</span><span class="mw-key">${icon('key', 13)}</span></div>
      <div class="pw-page"><div class="pw-form">
        <b>${esc(P.signIn)}</b>
        <span class="pw-in">${esc(P.user)}</span>
        <span class="pw-in pw-dots">••••••••••••</span>
        <span class="pw-go">${esc(P.button)}</span>
      </div></div>
    </div>
    <div class="pw-pop">
      <span class="pw-ic">${icon('key', 18)}</span>
      <b>${esc(P.ask)}</b>
      <p>${esc(P.msg)}</p>
      <div class="pw-btns"><span class="mb">${esc(P.notNow)}</span><span class="mb pri">${esc(P.save)}</span></div>
    </div>`;
}

function history(H) {
  const tone = ['#273553', '#3B332A', '#243A33', '#312C45'];
  return `<div class="hs-win">
      <div class="mw-bar">${tl}<span class="mw-title">${esc(H.window)}</span></div>
      <div class="hs-body">
        <span class="hs-search">${MAG}${esc(H.search)}</span>
        <span class="hs-day">${esc(H.day)}</span>
        ${H.rows.map((r, i) => `<span class="hs-row"><i class="fav" style="background:${tone[i % tone.length]}">${esc(r.t[0])}</i><span><b>${esc(r.t)}</b><em>${esc(r.u)}</em></span><time>${esc(r.time)}</time></span>`).join('')}
      </div>
    </div>`;
}

function cookies(C) {
  return `<div class="ck-sheet">
      <b class="sh-title">${esc(C.window)}</b>
      <span class="ck-file"><span class="ck-doc">${icon('doc', 18)}</span><span><b>${esc(C.file)}</b><em>${esc(C.format)}</em></span></span>
      <code class="ck-pre">.shop.example	TRUE	/	TRUE	session	a3f9c27e…
.shop.example	TRUE	/	TRUE	cart	1b44e0d2…
.shop.example	FALSE	/	TRUE	lang	de-DE</code>
      <span class="ck-sum">${icon('check', 13)}${esc(C.summary)}</span>
      <span class="sh-act"><span class="mb pri">${esc(C.action)}</span></span>
    </div>`;
}

function sync(S) {
  const mac = (name, ic) => `<div class="sy-mac">
      <span class="sy-head">${icon(ic, 18)}<span><b>${esc(name)}</b><em>${icon('check', 10)}${esc(S.synced)}</em></span></span>
      ${S.profiles.map((p, i) => `<span class="sy-row">${avatar(p, i, 22)}<b>${esc(p)}</b>${icon('check', 12)}</span>`).join('')}
    </div>`;
  const lines = ['9f3a1c7e04b2d86f5e21', 'U2FsdGVkX1+q0Rk3vLwq', 'c41de09a77f3b8e2105d', 'mQ8xZ0pT4r+eW1sKdL9a', '04b2d86f9f3a1c7e5e21', 'X7hNq2Lr8vPc0YtA3eSg', 'b8e2105dc41de09a77f3'];
  return `${mac(S.macs[0], 'laptop')}
    <div class="sy-wire"><code>${lines.join('\n')}</code><span class="sy-lock">${icon('lockFill', 14)}</span></div>
    ${mac(S.macs[1], 'desktop')}`;
}

function exporting(E) {
  return `<div class="ex-sheet">
      <b class="sh-title">${esc(E.window)}</b>
      <p>${esc(E.explain)}</p>
      <span class="ex-label">${esc(E.password)}</span>
      <span class="ex-field">••••••••••••</span>
      <span class="sh-act"><span class="mb pri">${esc(E.action)}</span></span>
    </div>
    <div class="ex-file">
      <span class="ex-doc"><i class="fold"></i><span class="ex-mark">${glyph(34, '#1B1F27')}</span><span class="ex-lock">${icon('lockFill', 13)}</span></span>
      <span class="ex-name">${esc(E.file)}</span>
    </div>`;
}

function ephemeral(E) {
  return `<div class="ep-ghost"><span class="mw-tl"><i></i><i></i><i></i></span><span class="ep-empty">${esc(E.empty)}</span></div>
    <div class="ep-row">${avatar(E.name, 4, 34)}<span><b>${esc(E.name)}</b><em>${icon('hourglass', 12)}${esc(E.row)}</em></span></div>`;
}

export default function bento(BE, { lang }) {
  const tile = (cls, x, art) => `<article class="bx ${cls} reveal">
    <div class="bx-copy"><h3>${inline(x.t, lang)}.</h3> <p>${inline(x.d, lang)}</p></div>
    <div class="bx-art" aria-hidden="true" data-sample>${art}</div>
  </article>`;
  return `<section class="sc-bento" data-scene="bento" data-title="${esc(BE.title)}"><div class="container">
    <h2 class="h-xl bx-head reveal">${twoTone(BE.head, lang)}</h2>
    <div class="bx-grid">
      ${tile('w2 bx-pw', BE.passwords, passwords(BE.passwords))}
      ${tile('bx-hs', BE.history, history(BE.history))}
      ${tile('bx-ck', BE.cookies, cookies(BE.cookies))}
      ${tile('w2 bx-sy', BE.sync, sync(BE.sync))}
      ${tile('w2 bx-ex', BE.export, exporting(BE.export))}
      ${tile('bx-ep', BE.ephemeral, ephemeral(BE.ephemeral))}
    </div>
    <p class="bx-more reveal">${linkArrow('features.html', BE.link, lang)}</p>
  </div></section>`;
}
