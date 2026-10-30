// Scene "layers": isolation, as an exploded view — five layers of one profile part as you scroll.
import { inline, esc } from '../../../lib/html.mjs';
import { icon } from '../../../lib/kit.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/layers.css'] };

export default function layers(LY, { lang }) {
  const layerFace = [
    `<span class="lyf-bar"><i></i><i></i><i></i><em></em></span><span class="lyf-page"><i></i><i></i><i class="s"></i></span>`,
    `<span class="lyf-chip">${icon('cpu', 14)}WebKit</span><span class="lyf-chip">${icon('folder', 14)}~/profile</span>`,
    `<span class="lyf-row">${icon('cookie', 13)}<i></i>${icon('lockFill', 11)}</span><span class="lyf-row">${icon('key', 13)}<i></i>${icon('lockFill', 11)}</span><span class="lyf-row">${icon('clock', 13)}<i></i>${icon('lockFill', 11)}</span>`,
    `<span class="lyf-net"><i class="dot"></i><i class="ln"></i>${icon('network', 14)}<i class="ln"></i>${icon('globe', 14)}</span><span class="lyf-net off"><i class="dot"></i><i class="ln dash"></i>${icon('xmark', 12)}</span>`,
    `<span class="lyf-key">${icon('key', 18)}<code>AES-256-GCM</code></span>`,
  ];
  return `<section class="scene layers" data-scene="layers" data-title="${esc(LY.title)}" style="--len:300vh">
  <div class="scene-pin"><div class="container ly-grid">
    <div class="ly-text">
      <h2 class="h-xl">${twoTone(LY.head, lang)}</h2>
      <p class="lead">${inline(LY.lead, lang)}</p>
      <ol class="ly-labels">${LY.items.map((x, i) => `<li data-r="${(0.12 + i * 0.1).toFixed(2)} ${(0.24 + i * 0.1).toFixed(2)}"><span class="ly-ic">${icon(x.icon, 16)}</span><span><b>${inline(x.t, lang)}</b><span>${inline(x.d, lang)}</span></span></li>`).join('')}</ol>
    </div>
    <div class="ly-stage" data-r="0.04 0.62" aria-hidden="true">
      <div class="ly-stack">${LY.items.map((x, i) => `<div class="ly" style="--k:${LY.items.length - 1 - i};--i:${i}"><div class="ly-face">${layerFace[i]}</div><span class="ly-name">${inline(x.t, lang)}</span></div>`).join('')}</div>
    </div>
  </div></div>
</section>`;
}
