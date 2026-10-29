import { inline, esc, codeBlock, plain } from '../../lib/html.mjs';
import { icon, mark } from '../../lib/kit.mjs';
import { linkArrow } from '../components.mjs';

export default function download(c, { lang }) {
  const h = c.hero;
  const hero = `<section class="page-hero"><div class="container"><div class="split" style="align-items:center">
    <div>
      <p class="eyebrow">${inline(h.eyebrow, lang)}</p>
      <h1 class="h1">${inline(h.title, lang)}</h1>
      <p class="lead">${inline(h.lead, lang)}</p>
      <div class="btn-row stretch" style="margin-top:32px"><a class="btn primary lg" href="#install">${icon('download', 17)}${inline(h.button, lang)}</a></div>
      <p class="hero-meta">${h.meta.map((m) => `<span>${inline(m, lang)}</span>`).join('')}</p>
      <p style="margin-top:20px">${linkArrow('blog.html', h.other, lang)}</p>
    </div>
    <div class="reveal" style="display:flex;justify-content:center">
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
      ${codeBlock(plain(sg.code), sg.codeLabel, lang)}
      <p class="caption">${inline(sg.expect, lang)}</p>
    </div>
  </div></div></section>`;

  const f = c.first.screen;
  const first = `<section class="section"><div class="container"><div class="split">
    <div><h2 class="h2">${inline(c.first.title, lang)}</h2><p class="lead" style="margin-top:14px">${inline(c.first.lead, lang)}</p></div>
    <figure style="margin:0" class="reveal"><div class="appwin" aria-hidden="true" style="background:var(--backdrop)">
      <div class="titlebar" style="background:var(--backdrop);border-bottom:0"><span class="traffic"><i></i><i></i><i></i></span></div>
      <div style="padding:28px 40px 44px;display:grid;justify-items:center;gap:14px;text-align:center">
        <span style="display:inline-flex;align-items:center;gap:14px;color:var(--text-primary)">${mark(36)}</span>
        <div style="font:600 22px/28px var(--font-display)">${inline(f.title, lang)}</div>
        <p style="font:400 13px/18px var(--font);color:var(--text-secondary);max-width:420px">${inline(f.subtitle, lang)}</p>
        <div style="display:grid;gap:10px;width:100%;max-width:300px;margin-top:6px;text-align:left">
          <div class="input" style="height:32px;font-size:13px;line-height:30px;color:var(--text-tertiary)">${inline(f.field, lang)}</div>
          <div class="input" style="height:32px;font-size:13px;line-height:30px;color:var(--text-tertiary)">${inline(f.repeat, lang)}</div>
          <div style="font:400 11px/14px var(--font);color:var(--text-tertiary)">${inline(f.rule, lang)}</div>
          <span class="btn primary" style="height:36px;margin-top:4px">${inline(f.action, lang)}</span>
        </div>
      </div></div>
      <figcaption class="caption" style="margin-top:10px">${inline(c.first.caption, lang)}</figcaption></figure>
  </div></div></section>`;

  const help = `<section class="section"><div class="container">
    <h2 class="h2" style="margin-bottom:32px">${inline(c.help.title, lang)}</h2>
    <div class="grid c3">${c.help.items.map((i) => `<a class="card card-link reveal" href="${i.href}"><h3 class="h4">${inline(i.t, lang)}</h3><p>${inline(i.d, lang)}</p></a>`).join('')}</div>
  </div></section>`;

  return { body: [hero, req, install, sign, first, help].join('\n'), bodyClass: 'page-download' };
}
