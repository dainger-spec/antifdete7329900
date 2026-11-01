import { inline, esc } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';

// The docs' index: the sections and their articles (copy/source/<lang>/docs.mjs). Every link leads to a real
// article — docs-<article>.html, its text in copy/source/<lang>/docs-<article>.mjs.
export default function docs(c, { lang }) {
  const x = c.index;
  const first = c.sections[0].items[0][0];
  const hero = `<section class="page-hero"><canvas class="codetex" data-codeart="texture" aria-hidden="true"></canvas><div class="container">
    <p class="eyebrow">${inline(x.eyebrow, lang)}</p>
    <h1 class="h1">${inline(x.title, lang)}</h1>
    <p class="lead">${inline(x.lead, lang)}</p>
    <form class="search" role="search" style="max-width:560px;margin-top:32px" action="${first}.html">
      ${icon('magnifyingglass', 14)}<input class="input" type="search" name="q" placeholder="${esc(x.search)}" aria-label="${esc(x.search)}" style="height:48px;font-size:15px;padding-left:38px"><kbd>/</kbd>
    </form>
  </div></section>`;

  const sections = `<section style="padding-bottom:var(--section-pad)"><div class="container">
    <div class="doc-sections">${c.sections.map((s) => `<div class="card reveal"><span class="tile-icon">${icon(s.icon, 18)}</span><h2 class="h4">${inline(s.title, lang)}</h2>
      <ul>${s.items.map(([slug, t]) => `<li><a href="${slug}.html">${inline(t, lang)}</a></li>`).join('')}</ul></div>`).join('')}</div>
  </div></section>`;

  return { body: hero + sections, bodyClass: 'page-docs' };
}

/// Every article in reading order, with its section: [{ slug, title, section }].
export function docsOrder(c) {
  return c.sections.flatMap((s) => s.items.map(([slug, title]) => ({ slug, title, section: s.title })));
}

/// The docs' left column: every section with its articles; the current one marked.
export function docsNav(c, lang, current) {
  const list = c.sections.map((s) => `<h2>${inline(s.title, lang)}</h2><ul>${s.items.map(([slug, t]) => `<li><a href="${slug}.html"${slug === current ? ' aria-current="page"' : ''}>${inline(t, lang)}</a></li>`).join('')}</ul>`).join('');
  const search = `<div class="search">${icon('magnifyingglass', 14)}<input class="input" type="search" placeholder="${esc(c.nav.search)}" aria-label="${esc(c.nav.search)}"></div>`;
  return `<nav class="docs-nav" aria-label="${esc(c.nav.toggle)}">
    <details class="docs-nav-toggle"><summary>${esc(c.nav.toggle)}${icon('chevronDown', 14)}</summary><div class="inner">${search}${list}</div></details>
    <div class="docs-nav-full">${search}${list}</div>
  </nav>`;
}
