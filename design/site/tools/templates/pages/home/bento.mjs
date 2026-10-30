// Scene "bento": everything else, as a bento grid of small pictures.
import { inline, esc } from '../../../lib/html.mjs';
import { icon } from '../../../lib/kit.mjs';
import { linkArrow, avatar } from '../../components.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/bento.css'] };

export default function bento(BE, { lang }) {
  const tile = (cls, t, d, art) => `<article class="bx ${cls} reveal"><div class="bx-art" aria-hidden="true">${art}</div><h3>${inline(t, lang)}</h3><p>${inline(d, lang)}</p></article>`;
  return `<section class="bentox" data-title="${esc(BE.title)}"><div class="container">
    <h2 class="h-xl center-text reveal">${twoTone(BE.head, lang)}</h2>
    <div class="bx-grid">
      ${tile('w2 pw', BE.passwords.t, BE.passwords.d, `<span class="pw-card glass"><span class="pw-site">${icon('lockFill', 11)}${esc(BE.passwords.site)}</span><span class="pw-field">${icon('key', 13)}<i>••••••••••</i></span><span class="pw-btn">${esc(BE.passwords.save)}</span></span>`)}
      ${tile('hs', BE.history.t, BE.history.d, `<span class="hs-list">${BE.history.rows.map((r, i) => `<span><i style="--h:${[18, 220, 150][i]}"></i>${esc(r)}</span>`).join('')}</span>`)}
      ${tile('ck', BE.cookies.t, BE.cookies.d, `<span class="ck-flow"><span class="ck-file">${icon('doc', 16)}<code>${esc(BE.cookies.file)}</code></span>${icon('arrowRight', 16)}${avatar(BE.cookies.profile || 'M', 2, 34)}</span>`)}
      ${tile('w2 sy', BE.sync.t, BE.sync.d, `<span class="sy-flow">${icon('laptop', 40)}<i class="sy-ln"></i><span class="sy-pk">${icon('lockFill', 13)}</span><i class="sy-ln"></i>${icon('laptop', 40)}</span>`)}
      ${tile('w2 ex', BE.export.t, BE.export.d, `<span class="ex-file">${icon('doc', 44)}<span class="ex-lk">${icon('lockFill', 13)}</span></span>`)}
      ${tile('ep', BE.ephemeral.t, BE.ephemeral.d, `<span class="ep-art">${icon('hourglass', 40)}<i></i><i></i><i></i></span>`)}
    </div>
    <p class="center-text reveal" style="margin-top:40px">${linkArrow('features.html', BE.link, lang)}</p>
  </div></section>`;
}
