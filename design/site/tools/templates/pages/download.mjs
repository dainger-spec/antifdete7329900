import { inline, esc, codeBlock, plain } from '../../lib/html.mjs';
import { icon, mark } from '../../lib/kit.mjs';
import { linkArrow } from '../components.mjs';

export default function download(c, { lang }) {
  const h = c.hero;
  const hero = `<section class="page-hero"><canvas class="codetex" data-codeart="texture" aria-hidden="true"></canvas><div class="container"><div class="split" style="align-items:center">
    <div>
      <p class="eyebrow">${inline(h.eyebrow, lang)}</p>
      <h1 class="h1">${inline(h.title, lang)}</h1>
      <p class="lead">${inline(h.lead, lang)}</p>
      <div class="btn-row stretch" style="margin-top:32px"><a class="btn primary lg" href="#install">${icon('download', 17)}${inline(h.button, lang)}</a></div>
      <p class="hero-meta">${h.meta.map((m) => `<span>${inline(m, lang)}</span>`).join('')}</p>
      <p style="margin-top:20px">${linkArrow('blog.html', h.other, lang)}</p>
    </div>
    <div class="reveal dmg-card" style="display:flex;justify-content:center">
      <div class="card" style="padding:40px 48px;display:grid;justify-items:center;gap:18px;text-align:center;min-width:300px">
        ${mark(112)}
        <div><div style="font:600 17px/22px var(--font)">${esc(plain('{{name}}'))}.dmg</div><div class="caption" style="margin-top:4px">${inline(h.meta[2], lang)}</div></div>
        <div class="row" style="gap:8px;justify-content:center"><span class="tag">${icon('signature', 12)}Developer ID</span><span class="tag">${icon('shieldCheck', 12)}${lang === 'ru' ? 'Заверено Apple' : 'Notarized'}</span></div>
      </div>
    </div>
  </div></div></section>`;

  const req = `<section class="section"><div class="container"><div class="split">
    <h2 class="h2">${inline(c.req.title, lang)}</h2>
    <dl class="kv">${c.req.rows.map(([k, v]) => `<dt>${inline(k, lang)}</dt><dd>${inline(v, lang)}</dd>`).join('')}</dl>
  </div></div></section>`;

  const install = `<section class="section" id="install"><div class="container"><div class="split">
    <h2 class="h2">${inline(c.install.title, lang)}</h2>
    <ol class="steps">${c.install.steps.map((s) => `<li><div><h3>${inline(s.t, lang)}</h3><p>${inline(s.d, lang)}</p></div></li>`).join('')}</ol>
  </div></div></section>`;

  const sg = c.sign;
  const sign = `<section class="section" id="signature"><div class="container"><div class="split">
    <div><h2 class="h2">${inline(sg.title, lang)}</h2><p class="lead" style="margin-top:14px">${inline(sg.lead, lang)}</p></div>
    <div class="stack-lg">
      <dl class="kv">${sg.rows.map(([k, v]) => `<dt>${inline(k, lang)}</dt><dd>${inline(v, lang)}</dd>`).join('')}</dl>
      <details class="fold"><summary>${inline(sg.check, lang)}${icon('chevronDown', 14)}</summary><div class="fold-in">
        ${codeBlock(plain(sg.code), sg.codeLabel, lang)}
        <p class="caption" style="margin-top:14px">${inline(sg.expect, lang)}</p>
      </div></details>
    </div>
  </div></div></section>`;

  const help = `<section class="section"><div class="container">
    <h2 class="h2" style="margin-bottom:32px">${inline(c.help.title, lang)}</h2>
    <div class="grid c3">${c.help.items.map((i) => `<a class="card card-link reveal" href="${i.href}"><h3 class="h4">${inline(i.t, lang)}</h3><p>${inline(i.d, lang)}</p></a>`).join('')}</div>
  </div></section>`;

  return { body: [hero, req, install, sign, help].join('\n'), bodyClass: 'page-download' };
}
