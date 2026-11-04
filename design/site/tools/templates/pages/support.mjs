import { inline, esc, plain } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';

export default function support(c, { lang }) {
  const h = c.hero;
  const hero = `<section class="page-hero"><canvas class="codetex" data-codeart="texture" aria-hidden="true"></canvas><div class="container">
    <p class="eyebrow">${inline(h.eyebrow, lang)}</p>
    <h1 class="h1">${inline(h.title, lang)}</h1>
    <p class="lead">${inline(h.lead, lang)}</p>
    <form class="search" role="search" style="max-width:560px;margin-top:32px" action="docs.html">${icon('magnifyingglass', 14)}<input class="input" type="search" placeholder="${esc(h.search)}" aria-label="${esc(h.search)}" style="height:48px;font-size:15px;padding-left:38px"></form>
  </div></section>`;

  const t = c.topics;
  const topics = `<section class="section"><div class="container">
    <h2 class="h3" style="margin-bottom:24px">${inline(t.title, lang)}</h2>
    <div class="grid c4">${t.items.map((i) => `<a class="card card-link reveal" href="docs-import-cookies.html"><span class="tile-icon neutral">${icon(i.icon, 18)}</span><h3 class="h4">${inline(i.t, lang)}</h3><p>${inline(i.d, lang)}</p></a>`).join('')}</div>
  </div></section>`;

  const f = c.form;
  const form = `<section class="section"><div class="container"><div class="split">
    <div><h2 class="h2">${inline(f.title, lang)}</h2><div class="note warn" style="margin-top:24px">${icon('exclamationTriangle', 18)}<div><p>${inline(f.never, lang)}</p></div></div></div>
    <form class="form card pad-lg" action="support.html">
      <div><label class="field-label" for="topic">${inline(f.topic, lang)}</label><div class="select"><select class="input" id="topic">${f.topics.map((x) => `<option>${esc(x)}</option>`).join('')}</select>${icon('chevronUpDown', 14)}</div></div>
      <div><label class="field-label" for="reply">${inline(f.email, lang)}</label><input class="input" id="reply" type="email" placeholder="you@example.com"><p class="hint">${inline(f.emailHint, lang)}</p></div>
      <div><label class="field-label" for="msg">${inline(f.message, lang)}</label><textarea class="input" id="msg" placeholder="${esc(f.messagePlaceholder)}"></textarea></div>
      <div><label class="check"><input type="checkbox"><span>${inline(f.logs, lang)}</span></label><p class="hint" style="margin-left:28px">${inline(f.logsHint, lang)}</p></div>
      <div><button class="btn primary lg" type="submit">${icon('envelope', 16)}${inline(f.send, lang)}</button></div>
    </form>
  </div></div></section>`;

  const k = c.contacts;
  const contacts = `<section class="section" id="contacts"><div class="container">
    <h2 class="h2" style="margin-bottom:32px">${inline(k.title, lang)}</h2>
    <div class="grid c3">${k.items.map((i) => `<div class="card reveal"><span class="tile-icon neutral">${icon(i.icon, 18)}</span><h3 class="h4">${inline(i.t, lang)}</h3><p><a href="mailto:${esc(plain(i.v))}">${inline(i.v, lang)}</a></p>${i.d ? `<p style="margin-top:8px">${inline(i.d, lang)}</p>` : ''}</div>`).join('')}
      <div class="card reveal"><span class="tile-icon neutral">${icon('house', 18)}</span><h3 class="h4">${inline(k.company, lang)}</h3><p>${inline(k.companyValue, lang)}</p></div></div>
  </div></section>`;

  return { body: hero + topics + form + contacts, bodyClass: 'page-support' };
}
