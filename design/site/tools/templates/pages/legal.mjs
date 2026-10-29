import { inline, esc, markdown } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';

export default function legal(c, { lang, slug, state }) {
  const doc = c[state];
  const tabs = `<nav class="seg" aria-label="${esc(c.title)}" style="margin-bottom:28px">${c.tabs.map(([href, t]) => `<a href="${href}"${href === `${slug}.html` ? ' aria-current="page"' : ''}>${esc(t)}</a>`).join('')}</nav>`;
  const hero = `<section class="page-hero" style="padding-bottom:40px"><div class="container">
    ${tabs}
    <h1 class="h1">${inline(doc.title, lang)}</h1>
    <p class="lead">${inline(doc.lead, lang)}</p>
    <p class="doc-meta"><span>${inline(c.updatedLabel, lang)} ${inline(c.updated, lang)}</span></p>
  </div></section>`;
  const toc = `<aside class="local-nav" data-localnav aria-label="${esc(c.tocTitle)}"><h2>${esc(c.tocTitle)}</h2><div class="track"><ol>${doc.toc.map(([id, t]) => `<li><a href="#${id}">${inline(t, lang)}</a></li>`).join('')}</ol><span class="indicator" style="opacity:0"></span></div></aside>`;
  const body = `<div class="container"><div class="with-nav" style="padding-bottom:96px;border-top:1px solid var(--divider);padding-top:48px">${toc}<div class="prose legal">${markdown(doc.body, lang, { icon })}</div></div></div>`;
  return { title: doc.title, description: doc.lead, body: hero + body, bodyClass: `page-legal page-${state}` };
}
