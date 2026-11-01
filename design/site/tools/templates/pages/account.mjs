import { inline, esc } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';

// The account: four sections — overview, Macs and sync, payments, settings. On a computer, a column on the left
// (who you are, the sections, Sign out); on a phone, a tab bar at the bottom, as in an app, and one column of cards
// and lists, so nothing on a page needs a table or a sideways scroll. Every user value is sample data
// (data-sample): the email, dates, device codes, the sync objects and payments.
export default function account(c, { lang, slug, state }) {
  const here = `${slug}.html`;
  const side = `<aside class="acc-side" aria-label="${lang === 'ru' ? 'Разделы кабинета' : 'Account sections'}">
    <div class="acc-who" data-sample><span class="avatar">${esc(c.who.initial)}</span><div style="min-width:0"><div class="e">${inline(c.who.email, lang)}</div><div class="p">${inline(c.who.plan, lang)}</div></div></div>
    <ul>${c.nav.map(([href, ic, t]) => `<li><a href="${href}"${href === here ? ' aria-current="page"' : ''}>${icon(ic, 16)}${esc(t)}</a></li>`).join('')}</ul>
    <a class="acc-out" href="index.html">${icon('logout', 16)}${esc(c.logout)}</a>
  </aside>`;
  const tabs = `<nav class="acc-tabs" aria-label="${lang === 'ru' ? 'Разделы кабинета' : 'Account sections'}">${c.nav.map(([href, ic, t]) => `<a href="${href}"${href === here ? ' aria-current="page"' : ''}>${icon(ic, 22)}<span>${esc(t)}</span></a>`).join('')}</nav>`;
  const row = (href, ic, k, v, sample = true) => `<li><a class="acc-row" href="${href}"><span class="ic">${icon(ic, 16)}</span><span class="k">${inline(k, lang)}</span><span class="v"${sample ? ' data-sample' : ''}>${inline(v, lang)}</span>${icon('chevronRight', 14)}</a></li>`;
  let content = '';

  if (state === 'overview') {
    const o = c.overview;
    content = `<h1 class="acc-title">${inline(o.title, lang)}</h1>
      <section class="acc-card plan" data-sample>
        <div class="plan-top"><div class="plan-name">${inline(o.plan, lang)}</div><span class="tag ok">${icon('check', 12)}${inline(o.status, lang)}</span></div>
        <p class="plan-meta">${inline(o.meta, lang)}</p>
        <div class="plan-until"><span class="k">${inline(o.untilLabel, lang)}</span><span class="v">${inline(o.until, lang)}</span></div>
        <div class="plan-bar" aria-hidden="true"><i style="width:94%"></i></div>
        <p class="plan-left">${inline(o.left, lang)}</p>
        <div class="plan-actions"><a class="btn primary" href="checkout.html">${icon('wallet', 15)}${inline(o.renew, lang)}</a><a class="btn ghost" href="pricing.html">${inline(o.change, lang)}</a></div>
      </section>
      <p class="acc-hint">${icon('envelope', 14)}<span>${inline(o.hint, lang)}</span></p>
      <ul class="acc-list">${o.rows.map(([href, ic, k, v]) => row(href, ic, k, v)).join('')}</ul>`;
  } else if (state === 'devices') {
    const d = c.devices, s = d.sync;
    content = `<h1 class="acc-title">${inline(d.title, lang)}</h1>
      <h2 class="acc-h">${inline(d.macs, lang)} · <span data-sample>${inline(d.count, lang)}</span></h2>
      <ul class="acc-list" data-sample>${d.list.map((m) => `<li><div class="acc-row tall"><span class="ic">${icon('laptop', 16)}</span><span class="k">${esc(d.mac)} <span class="code-badge">${esc(m.code)}</span>${m.current ? ` <span class="tag accent">${esc(d.thisMac)}</span>` : ''}<span class="sub">${inline(m.seen, lang)} · IP <span class="mono">${esc(m.ip)}</span></span></span>${m.current ? '' : `<a class="btn ghost sm danger-text" href="account-devices.html">${inline(d.revoke, lang)}</a>`}</div></li>`).join('')}</ul>
      <p class="acc-hint">${icon('infoCircle', 14)}<span>${inline(d.note, lang)}</span></p>
      <h2 class="acc-h" id="sync" style="margin-top:36px">${inline(s.title, lang)}</h2>
      <div class="acc-stats" data-sample>${s.stats.map(([k, v]) => `<div><div class="n">${inline(v, lang)}</div><div class="k">${inline(k, lang)}</div></div>`).join('')}</div>
      <section class="acc-card server"><details>
        <summary><span class="ic">${icon('lockFill', 15)}</span><span class="k"><span class="t">${inline(s.serverTitle, lang)}</span><span class="sub">${inline(s.serverSub, lang)}</span></span>${icon('chevronDown', 14)}</summary>
        <div class="server-in">
          <p class="lead-s">${inline(s.serverLead, lang)}</p>
          <ul class="server-list" data-sample>${s.rows.map(([n, z]) => `<li><span class="mono">${esc(n)}</span><span>${esc(z)}</span></li>`).join('')}<li class="more">${inline(s.more, lang)}</li></ul>
          <p class="acc-hint">${icon('infoCircle', 14)}<span>${inline(s.headerNote, lang)}</span></p>
        </div>
      </details></section>
      <div class="acc-danger"><a class="btn ghost sm danger-text" href="account-devices.html">${inline(s.danger.action, lang)}</a><span>${inline(s.danger.text, lang)}</span></div>`;
  } else if (state === 'invoices') {
    const v = c.invoices;
    content = `<h1 class="acc-title">${inline(v.title, lang)}</h1>
      <ul class="acc-list" data-sample>${v.rows.map(([date, no, sum, coin, status]) => `<li><div class="acc-row tall"><span class="ic">${icon('wallet', 16)}</span><span class="k">${esc(date)}<span class="sub"><span class="mono">${esc(no)}</span> · ${esc(coin)} · <span class="ok-text">${icon('check', 11)}${esc(status)}</span></span></span><span class="sum">${inline(sum, lang)}</span><a class="btn ghost sm icon-only" href="account-invoices.html" title="${esc(v.pdf)}" aria-label="${esc(v.pdf)}">${icon('download', 15)}</a></div></li>`).join('')}</ul>
      <p class="acc-hint">${icon('infoCircle', 14)}<span>${inline(v.note, lang)}</span></p>`;
  } else {
    const s = c.settings;
    content = `<h1 class="acc-title">${inline(s.title, lang)}</h1>
      <h2 class="acc-h">${inline(s.signin.title, lang)}</h2>
      <ul class="acc-list" data-sample>${s.signin.rows.map(([k, v], i) => `<li><div class="acc-row"><span class="k">${inline(k, lang)}</span><span class="v">${inline(v, lang)}</span>${i === 0 ? `<a class="btn ghost sm" href="account-settings.html">${inline(s.signin.change, lang)}</a>` : ''}</div></li>`).join('')}</ul>
      <h2 class="acc-h">${inline(s.email.title, lang)}</h2>
      <ul class="acc-list">${s.email.items.map(([t, on, locked]) => locked ? `<li><div class="acc-row"><span class="k">${inline(t, lang)}</span><span class="v">${inline(s.email.always, lang)}</span></div></li>` : `<li><label class="acc-row"><span class="k">${inline(t, lang)}</span><input class="switch" type="checkbox"${on ? ' checked' : ''}></label></li>`).join('')}
        <li><div class="acc-row"><span class="k">${inline(s.email.lang, lang)}</span><span class="seg"><a aria-current="${lang === 'ru'}">RU</a><a aria-current="${lang === 'en'}">EN</a></span></div></li></ul>
      <h2 class="acc-h">${inline(s.sessions.title, lang)}</h2>
      <ul class="acc-list"><li><div class="acc-row"><span class="ic">${icon('globe', 16)}</span><span class="k">${inline(s.sessions.current, lang)}</span></div></li>
        <li class="phone-only"><a class="acc-row" href="index.html"><span class="ic">${icon('logout', 16)}</span><span class="k">${inline(s.sessions.out, lang)}</span>${icon('chevronRight', 14)}</a></li>
        <li><a class="acc-row" href="login.html"><span class="ic">${icon('logout', 16)}</span><span class="k">${inline(s.sessions.all, lang)}</span>${icon('chevronRight', 14)}</a></li></ul>
      <div class="acc-danger" style="margin-top:36px"><a class="btn ghost sm" href="account-settings.html">${inline(s.key.action, lang)}</a><span>${inline(s.key.text, lang)}</span></div>
      <div class="acc-danger"><a class="btn ghost sm danger-text" href="account-settings.html">${inline(s.danger.action, lang)}</a><span>${inline(s.danger.text, lang)}</span></div>`;
  }
  return { title: c.title, body: `<div class="container"><div class="acc">${side}<div class="acc-main">${content}</div></div></div>${tabs}`, bodyClass: 'page-account', hideFooter: true };
}
