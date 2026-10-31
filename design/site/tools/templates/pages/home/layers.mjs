// Scene "layers": isolation, as an exploded view. A profile's Safari window, seen front on, turns to
// an isometric view and comes apart into the five layers under it — window, process, data, network,
// key — each one drawn as the app or macOS would show it. Labels on hairlines name each layer as it
// separates (desktop); on a phone one caption at a time, under the stack, names the layer that lifts.
//
// Timeline (--p of the scene): 0.02–0.28 the window turns (--rt) from a large face-on shot, 0.26–0.56
// the layers part (--et), 0.36–0.80 the labels come in one by one. Without scenes: the finished view,
// every label shown. On a phone the view turns about one axis only, so each slab's words stay level
// and large enough to read; one caption at a time names the layer that lifts.
import { inline, esc } from '../../../lib/html.mjs';
import { icon, flag } from '../../../lib/kit.mjs';
import { avatar } from '../../components.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/layers.css'] };

const FILES = ['passwords.bin', 'cookies.bin', 'history.bin', 'webdata.pbsa'];

function faces(u) {
  const win = `<div class="ly-face lf-win">
      <div class="lw-bar"><span class="lw-tl"><i></i><i></i><i></i></span><span class="lw-btn">${icon('sidebar', 13)}</span><span class="lw-btn lw-nav">${icon('chevronLeft', 12)}${icon('chevronRight', 12)}</span><span class="lw-url">${icon('lockFill', 9)}<span>${esc(u.site)}</span></span><span class="lw-btn">${icon('plus', 12)}</span></div>
      <div class="lw-page">
        <div class="lw-top"><b>shop</b><i></i><i></i><i></i></div>
        <div class="lw-h">${esc(u.page)}</div>
        ${u.orders.map(([t, st, pr], i) => `<div class="lw-row"><i class="lw-th t${i}"></i><span>${esc(t)}</span><em>${esc(st)}</em><span class="pr">${esc(pr)}</span></div>`).join('')}
      </div>
    </div>`;
  // The profiles' own processes, this one selected; it sits last, on the edge the stack shows.
  const procs = u.procs.map((x, i) => ({ x, i })).reverse();
  const proc = `<div class="ly-face lf-proc">
      ${procs.map(({ x: [n, p], i }) => `<div class="lp-row${i === 0 ? ' on' : ''}">${avatar(n, i, 20)}<span class="lp-n">${esc(n)}</span><span class="lp-p">${esc(p)}</span></div>`).join('')}
    </div>`;
  const data = `<div class="ly-face lf-data">
      ${FILES.map((f) => `<div class="ld-file">${icon('doc', 15)}<code>${f}</code>${icon('lockFill', 10)}</div>`).join('')}
    </div>`;
  // Each setting and its value side by side, in the band the slab above leaves visible.
  const net = `<div class="ly-face lf-net">
      <div class="ln-row"><span>${esc(u.net[0][0])}</span><b>${flag('DE', 14)}${esc(u.net[0][1])}</b></div>
      <div class="ln-row"><span>${esc(u.net[1][0])}</span><b>${icon('lockFill', 11)}${esc(u.net[1][1])}</b></div>
      <div class="ln-row"><span>${esc(u.net[2][0])}</span><b>${esc(u.net[2][1])}</b></div>
    </div>`;
  const key = `<div class="ly-face lf-key">
      <span class="lk-cap">${icon('key', 15)}${esc(u.key)}</span>
      <code class="lk-alg">AES-256-GCM</code>
      <code class="lk-hex">7f3c 9a1e 04b2 d86f 31c0 · · · 5e21</code>
    </div>`;
  return [win, proc, data, net, key];
}

export default function layers(LY, { lang }) {
  const F = faces(LY.ui);
  const n = LY.items.length;
  // Each label's window on the scene's progress: it comes in as its layer has parted.
  const win = (i) => `${(0.36 + i * 0.085).toFixed(3)} ${(0.46 + i * 0.085).toFixed(3)}`;
  return `<section class="scene sc-layers" data-scene="layers" data-title="${esc(LY.title)}" style="--len:340vh">
  <div class="scene-pin"><div class="container ly-wrap">
    <header class="ly-head">
      <h2 class="h-xl">${twoTone(LY.head, lang)}</h2>
      <p class="lead">${inline(LY.lead, lang)}</p>
    </header>
    <div class="ly-stage" data-r="0.26 0.56">
      <div class="ly-rig" data-r="0.02 0.28" aria-hidden="true" data-sample>
        <div class="ly-ground"></div>
        ${F.map((f, i) => `<div class="ly ly-${i}" style="--k:${n - 1 - i}" data-r="${win(i)}"><div class="ly-edge"></div>${f}<i class="ly-hi"></i></div>`).join('')}
      </div>
      <ol class="ly-legend">
        ${LY.items.map((x, i) => `<li style="--k:${n - 1 - i}" data-r="${win(i)}"${i === n - 1 ? ' class="last"' : ''}><b>${inline(x.t, lang)}</b><span>${inline(x.d, lang)}</span></li>`).join('')}
      </ol>
    </div>
  </div></div>
</section>`;
}
