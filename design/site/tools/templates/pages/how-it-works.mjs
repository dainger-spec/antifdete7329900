import { inline, esc } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';
import { linkArrow, btn, note } from '../components.mjs';

export default function howItWorks(c, { lang }) {
  const hero = `<section class="page-hero"><div class="container">
    <p class="eyebrow">${inline(c.hero.eyebrow, lang)}</p>
    <h1 class="h1">${inline(c.hero.title, lang)}</h1>
    <p class="lead">${inline(c.hero.lead, lang)}</p>
  </div></section>`;
  const chipnav = `<nav class="chipnav" data-chipnav aria-label="${esc(c.navTitle)}"><div class="scroller">${c.nav.map(([id, t]) => `<a href="#${id}">${esc(t)}</a>`).join('')}</div></nav>`;
  const localnav = `<aside class="local-nav" data-localnav aria-label="${esc(c.navTitle)}"><h2>${esc(c.navTitle)}</h2><div class="track"><ol>${c.nav.map(([id, t]) => `<li><a href="#${id}">${esc(t)}</a></li>`).join('')}</ol><span class="indicator" style="opacity:0"></span></div></aside>`;
  const paras = (list) => list.map((p) => `<p>${inline(p, lang)}</p>`).join('');
  const sec = (id, title, inner) => `<section class="fblock" id="${id}"><h2 class="h2">${inline(title, lang)}</h2>${inner}</section>`;

  // Overview: manager → profile process (inside the kernel's sandbox) → proxy → internet
  const d = c.overview.diagram;
  const box = (title, items, ic, extra = '') => `<div class="node on" style="padding:14px 16px;${extra}"><div class="nv" style="margin-bottom:10px">${icon(ic, 15)}${inline(title, lang)}</div><div style="display:flex;flex-wrap:wrap;gap:6px">${items.map((i) => `<span class="chip" style="height:24px">${inline(i, lang)}</span>`).join('')}</div></div>`;
  const arrow = (label) => `<div class="hiw-arrow"><span class="line"></span><span class="lbl">${inline(label, lang)}</span></div>`;
  const overviewDiagram = `<figure class="diagram hiw reveal" style="margin-top:32px">
    <div class="hiw-flow">
      ${box(d.manager, d.managerItems, 'lockFill')}
      ${arrow(d.grant)}
      <div class="hiw-kernel"><div class="hiw-kernel-label">${icon('shieldCheck', 12)}${inline(d.kernel, lang)}</div>${box(d.process, d.processItems, 'compass')}</div>
      ${arrow(d.only)}
      <div style="display:grid;gap:10px">
        <div class="node on"><div class="nk">${inline(d.proxy, lang)}</div><div class="nv">${icon('network', 14)}${inline(d.proxySub, lang)}</div></div>
        <div class="node"><div class="nk">${inline(d.net, lang)}</div><div class="nv">${icon('globe', 14)}${inline(d.netSub, lang)}</div></div>
      </div>
    </div>
  </figure>`;
  const overview = sec('overview', c.overview.title, `<div class="prose" style="margin-top:20px">${paras(c.overview.paras)}</div>${overviewDiagram}`);

  const pt = c.process.table;
  const process = sec('process', c.process.title, `<div class="prose" style="margin-top:20px">${paras(c.process.paras)}</div>
    <div class="table-wrap reveal" style="margin-top:28px"><table class="table stack-mobile"><thead><tr>${pt.head.map((h) => `<th>${esc(h)}</th>`).join('')}</tr></thead>
    <tbody>${pt.rows.map((r) => `<tr><td class="strong" data-label="${esc(pt.head[0])}">${inline(r[0], lang)}</td><td data-label="${esc(pt.head[1])}">${inline(r[1], lang)}</td></tr>`).join('')}</tbody></table></div>`);

  const k = c.keys.diagram;
  const keysDiagram = `<figure class="diagram reveal" style="margin-top:28px"><div class="dtitle">${inline(k.title, lang)}</div>
    <div class="keys">
      ${k.rows.map((r, i) => `${i ? '<div class="arrow"></div>' : ''}<div class="kl"><span class="ki">${icon(r.icon, 13)}</span><div><div class="kt">${inline(r.t, lang)}</div><div class="kd">${inline(r.d, lang)}</div></div></div>`).join('')}
      <div class="arrow"></div>
      <div class="kl"><span class="ki">${icon('layers', 13)}</span><div><div class="kd" style="margin:2px 0 8px">${inline(k.hkdf, lang)}</div><div style="display:flex;flex-wrap:wrap;gap:6px">${k.vault.map((v) => `<span class="chip">${icon('lock', 11)}${inline(v, lang)}</span>`).join('')}</div></div></div>
      <div class="arrow"></div>
      <div class="kl"><span class="ki">${icon('person2', 13)}</span><div><div class="kt">${inline(k.profile.t, lang)}</div><div class="kd">${inline(k.profile.d, lang)}</div><div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:10px">${k.files.map((v) => `<span class="chip">${icon('lock', 11)}${inline(v, lang)}</span>`).join('')}</div></div></div>
    </div></figure>`;
  const keys = sec('keys', c.keys.title, `<div class="prose" style="margin-top:20px">${paras(c.keys.paras.slice(0, 2))}</div>${keysDiagram}<div class="prose" style="margin-top:28px">${paras(c.keys.paras.slice(2))}</div>`);

  const n = c.network;
  const network = sec('network', n.title, `<div class="prose" style="margin-top:20px">${paras(n.paras)}</div>
    <div class="table-wrap reveal" style="margin-top:28px"><div class="table-scroll"><table class="table stack-mobile"><thead><tr>${n.head.map((h) => `<th>${esc(h)}</th>`).join('')}</tr></thead>
    <tbody>${n.rows.map((r) => `<tr><td class="strong" data-label="${esc(n.head[0])}">${inline(r[0], lang)}</td><td data-label="${esc(n.head[1])}">${inline(r[1], lang)}</td><td data-label="${esc(n.head[2])}">${icon('check', 13)} ${inline(r[2], lang)}</td></tr>`).join('')}</tbody></table></div></div>
    <div class="row" style="justify-content:space-between;margin-top:18px"><span class="caption">${inline(n.note, lang)}</span>${linkArrow('verification.html', n.link, lang)}</div>`);

  const s = c.sync;
  const sync = sec('sync', s.title, `<div class="prose" style="margin-top:20px">${paras(s.paras)}</div>
    <div class="knows reveal" style="margin-top:28px">
      <div><h3>${icon('server', 16)}${inline(s.knowsTitle, lang)}</h3><ul>${s.knows.map((x) => `<li>${inline(x, lang)}</li>`).join('')}</ul></div>
      <div><h3>${icon('lockFill', 16)}${inline(s.notTitle, lang)}</h3><ul>${s.not.map((x) => `<li>${inline(x, lang)}</li>`).join('')}</ul></div>
    </div>`);

  const l = c.limits;
  const limits = sec('limits', l.title, `<p class="lead" style="margin-top:14px">${inline(l.lead, lang)}</p>
    <div class="table-wrap reveal" style="margin-top:28px">${l.items.map((it, i) => `<div class="ev-row" style="grid-template-columns:28px minmax(0,1fr);gap:14px"><span class="tile-icon neutral" style="width:28px;height:28px;margin:0">${icon(['cpu', 'creditcard', 'network', 'lock', 'key'][i], 14)}</span><div><div class="et">${inline(it.t, lang)}</div><p class="ed" style="margin-top:4px">${inline(it.d, lang)}</p></div></div>`).join('')}</div>`);

  const ct = c.cta;
  const cta = `<section class="cta-band"><div class="container"><div class="inner">
    <div><h2 class="h2">${inline(ct.title, lang)}</h2><p class="lead" style="margin-top:12px">${inline(ct.lead, lang)}</p></div>
    <div class="btn-row stretch">${btn('verification.html', ct.primary, 'primary', { size: 'lg', lang })}${btn('docs.html', ct.secondary, 'secondary', { size: 'lg', lang })}</div>
  </div></div></section>`;

  return {
    body: `${hero}\n${chipnav}\n<div class="container"><div class="with-nav" style="padding-top:56px;padding-bottom:40px">${localnav}<div class="fblocks">${[overview, process, keys, network, sync, limits].join('\n')}</div></div></div>\n${cta}`,
    bodyClass: 'page-how',
  };
}
