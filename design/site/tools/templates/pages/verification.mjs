import { inline, esc } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';
import { btn, result, note } from '../components.mjs';

export default function verification(c, { lang }) {
  const hero = `<section class="page-hero"><canvas class="codetex" data-codeart="texture" aria-hidden="true"></canvas><div class="container">
    <p class="eyebrow">${inline(c.hero.eyebrow, lang)}</p>
    <h1 class="h1">${inline(c.hero.title, lang)}</h1>
    <p class="lead">${inline(c.hero.lead, lang)}</p>
    <div class="run-card" style="margin-top:40px">
      <div><div class="rk">${inline(c.run.label, lang)}</div><div class="rv">${c.run.items.map((i) => `<span>${inline(i, lang)}</span>`).join('')}</div></div>
      <div class="row" style="gap:16px">${result('same', c.run.status, lang)}<span class="btn secondary sm" aria-disabled="true">${icon('doc', 14)}${inline(c.run.report, lang)}</span></div>
    </div>
  </div></section>`;

  const chipnav = `<nav class="chipnav" data-chipnav aria-label="${esc(c.navTitle)}"><div class="scroller">${c.nav.map(([id, t]) => `<a href="#${id}">${esc(t)}</a>`).join('')}</div></nav>`;
  const localnav = `<aside class="local-nav" data-localnav aria-label="${esc(c.navTitle)}"><h2>${esc(c.navTitle)}</h2><div class="track"><ol>${c.nav.map(([id, t]) => `<li><a href="#${id}">${esc(t)}</a></li>`).join('')}</ol><span class="indicator" style="opacity:0"></span></div></aside>`;
  const sec = (id, title, lead, inner) => `<section class="fblock" id="${id}"><h2 class="h2">${inline(title, lang)}</h2>${lead ? `<p class="lead">${inline(lead, lang)}</p>` : ''}${inner}</section>`;

  const cp = c.compare;
  const compare = sec('compare', cp.title, cp.lead, `<div class="table-wrap reveal" style="margin-top:36px">
    <div class="ev-head">${cp.head.map((h) => `<span>${esc(h)}</span>`).join('')}</div>
    ${cp.rows.map((r) => `<div class="ev-row">
      <div><div class="et">${inline(r.t, lang)}</div><div class="es">${inline(r.s, lang)}</div></div>
      <div><div class="score">${esc(r.score)} <small>${lang === 'ru' ? 'из' : 'of'} ${esc(r.of)}</small></div></div>
      <div class="ed">${result(r.res[0], r.res[1], lang)}<p>${inline(r.d, lang)}</p>${r.note ? `<p style="margin-top:8px;display:flex;gap:8px;align-items:flex-start;color:var(--text-tertiary);font:var(--t-caption)">${icon('refresh', 13)}<span>${inline(r.note, lang)}</span></p>` : ''}</div>
    </div>`).join('')}
  </div>
  <div class="legend">${cp.legend.map(([k, t]) => result(k, t, lang)).join('')}</div>`);

  const df = c.differences;
  const kindTag = (k) => k === 'product' ? `<span class="tag accent">${inline(df.kinds.product, lang)}</span>` : `<span class="tag">${inline(df.kinds.bench, lang)}</span>`;
  const differences = sec('differences', df.title, df.lead, `<div class="table-wrap reveal" style="margin-top:36px"><div class="table-scroll"><table class="table stack-mobile">
    <thead><tr>${df.head.map((h, i) => `<th${i === 1 ? ' class="num"' : ''}>${esc(h)}</th>`).join('')}</tr></thead>
    <tbody>${df.rows.map((r) => `<tr>
      <td class="strong" data-label="${esc(df.head[0])}" style="min-width:200px">${inline(r.t, lang)}<span class="sub">${inline(r.keys, lang)}</span></td>
      <td class="num" data-label="${esc(df.head[1])}" style="color:var(--text-primary);font-weight:600">${esc(r.n)}</td>
      <td data-label="${esc(df.head[2])}">${kindTag(r.kind)}</td>
      <td data-label="${esc(df.head[3])}">${inline(r.d, lang)}</td></tr>`).join('')}</tbody>
  </table></div></div>`);

  const lk = c.leaks;
  const leaks = sec('leaks', lk.title, lk.lead, `<div class="leak-grid" style="margin-top:36px">${lk.items.map((it) => `<div class="leak reveal">
    <div class="lh"><div class="lt">${inline(it.t, lang)}</div>${result('same', it.res, lang)}</div>
    <p>${inline(it.d, lang)}</p>
    <p class="how">${icon('terminal', 12)} ${inline(it.how, lang)}</p>
  </div>`).join('')}</div>`);

  const eb = c.everyBuild;
  const every = sec('every-build', eb.title, eb.lead, `<div class="table-wrap reveal" style="margin-top:36px"><div class="table-scroll"><table class="table stack-mobile">
    <thead><tr>${eb.head.map((h) => `<th>${esc(h)}</th>`).join('')}</tr></thead>
    <tbody>${eb.rows.map((r) => `<tr><td class="strong" data-label="${esc(eb.head[0])}" style="min-width:180px">${inline(r[0], lang)}</td><td data-label="${esc(eb.head[1])}">${inline(r[1], lang)}</td><td data-label="${esc(eb.head[2])}" style="white-space:nowrap">${result('same', r[2], lang)}</td></tr>`).join('')}</tbody>
  </table></div></div>`);

  const y = c.yourself;
  const r = c.reports;
  const yourself = sec('yourself', y.title, y.lead, `<ol class="steps" style="margin-top:36px">${y.steps.map((s) => `<li><div><h3>${inline(s.t, lang)}</h3><p>${inline(s.d, lang)}</p></div></li>`).join('')}</ol>
    ${note(y.note, lang, '', 'infoCircle')}
    <div style="margin-top:56px"><h3 class="h3">${inline(r.title, lang)}</h3><p class="muted" style="margin-top:8px">${inline(r.lead, lang)}</p>
      <div class="run-card" style="margin-top:20px"><div><div class="rv" style="margin:0">${r.sample.map((s, i) => `<span>${i === 0 ? `<strong>${inline(s, lang)}</strong>` : inline(s, lang)}</span>`).join('')}</div><div class="rk" style="margin-top:6px">${inline(r.status, lang)}</div></div>
      <span class="btn secondary sm" aria-disabled="true">${icon('download', 14)}JSON</span></div></div>`);

  const ct = c.cta;
  const cta = `<section class="cta-band"><div class="container"><div class="inner">
    <div><h2 class="h2">${inline(ct.title, lang)}</h2><p class="lead" style="margin-top:12px">${inline(ct.lead, lang)}</p></div>
    <div class="btn-row stretch">${btn('support.html#contacts', ct.primary, 'primary', { size: 'lg', iconName: 'envelope', lang })}${btn('how-it-works.html', ct.secondary, 'secondary', { size: 'lg', lang })}</div>
  </div></div></section>`;

  return {
    body: `${hero}\n${chipnav}\n<div class="container"><div class="with-nav" style="padding-top:40px;padding-bottom:40px">${localnav}<div class="fblocks">${[compare, differences, leaks, every, yourself].join('\n')}</div></div></div>\n${cta}`,
    bodyClass: 'page-verification',
  };
}
