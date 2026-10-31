import { inline, esc } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';
import { result } from '../components.mjs';

// Every user value on these pages is example data (data-sample): the email, dates, device codes, the
// sync objects and invoices. Plan names and amounts are the owner's decisions (yellow).
export default function account(c, { lang, slug, state }) {
  const nav = `<aside class="account-nav" aria-label="${lang === 'ru' ? 'Разделы кабинета' : 'Account sections'}">
    <div class="who"><div class="e" data-sample>${inline(c.who.email, lang)}</div><div class="p">${inline(c.who.plan, lang)}</div></div>
    <ul>${c.nav.map(([href, ic, t]) => `<li><a href="${href}"${href === `${slug}.html` ? ' aria-current="page"' : ''}>${icon(ic, 15)}${esc(t)}</a></li>`).join('')}
    <li class="sep" aria-hidden="true"></li><li><a href="index.html">${icon('logout', 15)}${esc(c.logout)}</a></li></ul>
  </aside>`;
  const head = (t, l, extra = '') => `<div class="account-head"><div><h1 class="h1">${inline(t, lang)}</h1><p>${inline(l, lang)}</p></div>${extra}</div>`;
  const kv = (rows) => `<dl class="kv">${rows.map(([k, v]) => `<dt>${inline(k, lang)}</dt><dd>${inline(v, lang)}</dd>`).join('')}</dl>`;
  let content = '';

  if (state === 'subscription') {
    const s = c.subscription;
    content = head(s.title, s.lead) + `
      <section class="panel"><div class="panel-head"><div><h2>${inline(s.plan.title, lang)}</h2></div><span class="tag ok">${icon('check', 12)}${inline(s.plan.status, lang)}</span></div>
        <div class="panel-body" data-sample><div style="font:600 24px/30px var(--font-display);padding:16px 0 4px">${inline(s.plan.name, lang)}</div>${kv(s.plan.rows)}</div>
        <div class="panel-foot"><span>${inline(s.plan.foot, lang)}</span><span class="row"><a class="btn secondary sm" href="pricing.html">${inline(s.plan.change, lang)}</a><a class="btn ghost sm" href="account.html">${inline(s.plan.cancel, lang)}</a></span></div></section>
      <section class="panel"><div class="panel-head"><h2>${inline(s.payment.title, lang)}</h2></div>
        <div class="panel-body pad"><div class="device" style="padding:0;border:0"><span class="dicon">${icon('creditcard', 18)}</span><div><div class="dn">${inline(s.payment.card, lang)}</div><div class="dm">${inline(s.payment.cardSub, lang)}</div></div><span class="dact"><a class="btn secondary sm" href="account.html">${inline(s.payment.update, lang)}</a></span></div></div>
        <div class="panel-foot"><span>${inline(s.payment.crypto, lang)}</span><a class="btn ghost sm" href="account.html">${icon('wallet', 14)}${inline(s.payment.cryptoAction, lang)}</a></div></section>`;
  } else if (state === 'devices') {
    const d = c.devices;
    content = head(d.title, d.lead) + `
      <section class="panel"><div class="panel-head"><h2 data-sample>${inline(d.count, lang)}</h2></div>
        <div class="panel-body" data-sample>${d.list.map((m) => `<div class="device"><span class="dicon">${icon('laptop', 18)}</span>
          <div><div class="dn">${esc(d.mac)} <span class="caption">${esc(d.codeLabel)}</span> <span class="code-badge">${esc(m.code)}</span>${m.current ? `<span class="tag accent">${esc(d.thisMac)}</span>` : ''}</div>
          <div class="dm">${inline(m.added, lang)} · ${inline(m.seen, lang)} · ${esc(d.ipLabel)} <span class="mono">${esc(m.ip)}</span></div></div>
          <span class="dact">${m.current ? '' : `<a class="btn danger sm" href="account-devices.html">${inline(d.revoke, lang)}</a>`}</span></div>`).join('')}</div>
        <div class="panel-foot"><span style="display:flex;gap:8px;align-items:flex-start">${icon('infoCircle', 14)}<span>${inline(d.note, lang)}</span></span></div></section>`;
  } else if (state === 'sync') {
    const s = c.sync;
    content = head(s.title, s.lead) + `
      <section class="panel"><div class="stats c3" style="border:0;background:transparent" data-sample>${s.stats.map(([k, v]) => `<div class="stat"><div class="t" style="margin:0 0 6px">${inline(k, lang)}</div><div class="n" style="font-size:28px;line-height:34px">${inline(v, lang)}</div></div>`).join('')}</div></section>
      <section class="panel"><div class="panel-head"><div><h2>${inline(s.objectsTitle, lang)}</h2><p>${inline(s.objectsLead, lang)}</p></div></div>
        <div class="table-scroll" data-sample><table class="table compact stack-mobile"><thead><tr>${s.head.map((h, i) => `<th${i === 1 || i === 2 ? ' class="num"' : ''}>${esc(h)}</th>`).join('')}</tr></thead>
        <tbody>${s.rows.map((r) => `<tr><td data-label="${esc(s.head[0])}"><span class="mono" style="color:var(--text-primary)">${esc(r[0])}</span></td><td class="num" data-label="${esc(s.head[1])}">${esc(r[1])}</td><td class="num" data-label="${esc(s.head[2])}">${esc(r[2])}</td><td data-label="${esc(s.head[3])}">${esc(r[3])}</td></tr>`).join('')}</tbody></table></div>
        <div class="panel-foot"><span data-sample>${inline(s.more, lang)}</span><span>${inline(s.names, lang)}</span></div></section>
      <div class="note" style="margin-top:20px">${icon('infoCircle', 18)}<div><p>${inline(s.headerNote, lang)}</p></div></div>
      <section class="panel danger-zone" style="margin-top:20px"><div class="panel-head"><div><h2>${inline(s.danger.title, lang)}</h2><p>${inline(s.danger.text, lang)}</p></div><a class="btn danger sm" href="account-sync.html">${inline(s.danger.action, lang)}</a></div></section>`;
  } else if (state === 'invoices') {
    const v = c.invoices;
    content = head(v.title, v.lead) + `
      <section class="panel"><div class="table-scroll" data-sample><table class="table stack-mobile"><thead><tr>${v.head.map((h, i) => `<th${i === 2 ? ' class="num"' : ''}>${esc(h)}</th>`).join('')}</tr></thead>
        <tbody>${v.rows.map((r) => `<tr><td data-label="${esc(v.head[0])}">${esc(r[0])}</td><td data-label="${esc(v.head[1])}"><span class="mono">${esc(r[1])}</span></td><td class="num strong" data-label="${esc(v.head[2])}">${inline(r[2], lang)}</td><td data-label="${esc(v.head[3])}">${icon(/Карта|Card/.test(r[3]) ? 'creditcard' : 'wallet', 13)} ${esc(r[3])}</td><td data-label="${esc(v.head[4])}">${result('same', r[4], lang)}</td><td class="num"><a class="btn ghost sm" href="account-invoices.html">${icon('download', 13)}${esc(v.pdf)}</a></td></tr>`).join('')}</tbody></table></div>
        <div class="panel-foot"><span>${inline(v.note, lang)}</span></div></section>`;
  } else {
    const s = c.settings;
    content = head(s.title, s.lead) + `
      <section class="panel"><div class="panel-head"><h2>${inline(s.signin.title, lang)}</h2><a class="btn secondary sm" href="account-settings.html">${inline(s.signin.change, lang)}</a></div>
        <div class="panel-body" data-sample>${kv(s.signin.rows)}</div>
        <div class="panel-foot"><span>${inline(s.signin.toKeyText, lang)}</span><a class="btn ghost sm" href="login-key.html">${icon('key', 14)}${inline(s.signin.toKey, lang)}</a></div></section>
      <section class="panel"><div class="panel-head"><h2>${inline(s.email.title, lang)}</h2></div>
        <div class="panel-body pad" style="display:grid;gap:14px">${s.email.items.map(([t, on, locked]) => `<label class="check" style="justify-content:space-between;align-items:center;font-size:15px;color:var(--text-primary)"><span>${inline(t, lang)}</span><input class="switch" type="checkbox"${on ? ' checked' : ''}${locked ? ' disabled' : ''}></label>`).join('')}
          <div class="row" style="justify-content:space-between"><span style="font-size:15px">${inline(s.email.lang, lang)}</span><span class="seg"><a aria-current="${lang === 'ru'}">RU</a><a aria-current="${lang === 'en'}">EN</a></span></div></div></section>
      <section class="panel"><div class="panel-head"><h2>${inline(s.sessions.title, lang)}</h2><a class="btn secondary sm" href="login.html">${inline(s.sessions.all, lang)}</a></div>
        <div class="panel-body pad"><div class="row">${icon('globe', 15)}<span>${inline(s.sessions.current, lang)}</span></div></div></section>
      <section class="panel danger-zone"><div class="panel-head"><div><h2>${inline(s.danger.title, lang)}</h2><p>${inline(s.danger.text, lang)}</p></div><a class="btn danger sm" href="account-settings.html">${inline(s.danger.action, lang)}</a></div></section>`;
  }
  return { title: c.title, body: `<div class="container"><div class="account">${nav}<div>${content}</div></div></div>`, bodyClass: 'page-account', hideFooter: true };
}
