import { inline, esc } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';

// Every article link leads to the one article template (docs-import-cookies.html): the docs are a
// structure and a template here, not content.
const ARTICLE = 'docs-import-cookies.html';

export default function docs(c, { lang }) {
  const x = c.index;
  const hero = `<section class="page-hero"><div class="container">
    <p class="eyebrow">${inline(x.eyebrow, lang)}</p>
    <h1 class="h1">${inline(x.title, lang)}</h1>
    <p class="lead">${inline(x.lead, lang)}</p>
    <form class="search" role="search" style="max-width:560px;margin-top:32px" action="${ARTICLE}">
      ${icon('magnifyingglass', 14)}<input class="input" type="search" name="q" placeholder="${esc(x.search)}" aria-label="${esc(x.search)}" style="height:48px;font-size:15px;padding-left:38px"><kbd>/</kbd>
    </form>
    <div class="row" style="margin-top:20px;gap:8px 10px"><span class="caption">${inline(x.popularTitle, lang)}:</span>${x.popular.map(([href, t]) => `<a class="chip" href="${href}" style="color:var(--text-secondary)">${inline(t, lang)}</a>`).join('')}</div>
  </div></section>`;

  const sections = `<section style="padding-bottom:var(--section-pad)"><div class="container">
    <div class="doc-sections">${c.sections.map((s) => `<div class="card reveal"><span class="tile-icon">${icon(s.icon, 18)}</span><h2 class="h4">${inline(s.title, lang)}</h2>
      <ul>${s.items.map((i) => `<li><a href="${ARTICLE}">${inline(i, lang)}</a></li>`).join('')}</ul></div>`).join('')}</div>
  </div></section>`;

  return { body: hero + sections, bodyClass: 'page-docs' };
}

/// The docs' left column: every section with its articles; the current one marked.
export function docsNav(c, lang, current) {
  const list = c.sections.map((s) => `<h2>${inline(s.title, lang)}</h2><ul>${s.items.map((i) => `<li><a href="${ARTICLE}"${i === current ? ' aria-current="page"' : ''}>${inline(i, lang)}</a></li>`).join('')}</ul>`).join('');
  const search = `<div class="search">${icon('magnifyingglass', 14)}<input class="input" type="search" placeholder="${esc(c.nav.search)}" aria-label="${esc(c.nav.search)}"></div>`;
  return `<nav class="docs-nav" aria-label="${esc(c.nav.toggle)}">
    <details class="docs-nav-toggle"><summary>${esc(c.nav.toggle)}${icon('chevronDown', 14)}</summary><div class="inner">${search}${list}</div></details>
    <div class="docs-nav-full">${search}${list}</div>
  </nav>`;
}
