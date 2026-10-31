import { inline, esc, markdown } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';
import { docsNav } from './docs.mjs';

export default function docsArticle(c, { lang }) {
  const a = c.article;
  const crumbs = `<nav class="breadcrumbs" aria-label="${lang === 'ru' ? 'Путь' : 'Breadcrumbs'}"><a href="docs.html">${inline(a.crumbs[0], lang)}</a>${icon('chevronRight', 10)}<span>${inline(a.crumbs[1], lang)}</span></nav>`;
  const article = `<article>
    ${crumbs}
    <h1 class="h1" style="font-size:40px;line-height:46px">${inline(a.title, lang)}</h1>
    <p class="lead" style="margin-top:14px;max-width:720px">${inline(a.lead, lang)}</p>
    <p class="doc-meta">${a.meta.map((m) => `<span>${inline(m, lang)}</span>`).join('')}</p>
    <hr style="margin:32px 0 8px">
    <div class="prose">${markdown(a.body, lang, { icon })}</div>
    <p class="caption" style="margin-top:48px">${inline(a.feedback, lang)}</p>
    <nav class="pager" aria-label="${lang === 'ru' ? 'Соседние статьи' : 'Nearby articles'}">
      <a href="docs-import-cookies.html"><div class="k">← ${esc(a.prevLabel)} · ${inline(a.prev[0], lang)}</div><div class="t">${inline(a.prev[1], lang)}</div></a>
      <a class="next" href="docs-import-cookies.html"><div class="k">${inline(a.next[0], lang)} · ${esc(a.nextLabel)} →</div><div class="t">${inline(a.next[1], lang)}</div></a>
    </nav>
  </article>`;
  const toc = `<aside class="toc" data-toc><h2>${lang === 'ru' ? 'На этой странице' : 'On this page'}</h2><ul>${a.toc.map(([id, t]) => `<li><a href="#${id}">${inline(t, lang)}</a></li>`).join('')}</ul></aside>`;
  return {
    title: a.title,
    description: a.lead,
    body: `<div class="container"><div class="docs-layout">${docsNav(c, lang, a.title)}${article}${toc}</div></div>`,
    bodyClass: 'page-docs-article',
  };
}
