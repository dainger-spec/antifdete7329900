import { inline, esc, markdown } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';
import { docsNav, docsOrder } from './docs.mjs';

// A documentation article: its text from copy/source/<lang>/docs-<article>.mjs (title, lead, toc, body in the site's
// markdown); the navigation, the crumbs and Previous / Next from the index (docs.mjs). An article says how many of its
// statements are marked unconfirmed ({{unv:…}}, ::: unv) — they are visible, so nobody reads a guess.
const WORDS_RU = ['', 'минуту', 'две минуты', 'три минуты', 'четыре минуты', 'пять минут', 'шесть минут', 'семь минут', 'восемь минут', 'девять минут', 'десять минут'];
const WORDS_EN = ['', 'one minute', 'two minutes', 'three minutes', 'four minutes', 'five minutes', 'six minutes', 'seven minutes', 'eight minutes', 'nine minutes', 'ten minutes'];

export default async function docsArticle(a, { lang, slug, copy }) {
  const c = await copy('docs');
  const order = docsOrder(c);
  const k = order.findIndex((x) => x.slug === slug);
  const me = order[k], prev = order[k - 1], next = order[k + 1];
  const words = a.body.replace(/[`*#|:{}()[\]]/g, ' ').split(/\s+/).filter(Boolean).length;
  const minutes = Math.max(1, Math.min(10, Math.round(words / (lang === 'ru' ? 160 : 200))));
  const unv = (a.body.match(/\{\{unv:|^::: unv/gm) || []).length;
  const ui = c.article;
  const crumbs = `<nav class="breadcrumbs" aria-label="${lang === 'ru' ? 'Путь' : 'Breadcrumbs'}"><a href="docs.html">${inline(ui.home, lang)}</a>${icon('chevronRight', 10)}<span>${inline(me.section, lang)}</span></nav>`;
  const meta = [ui.source, `${ui.read}: ${(lang === 'ru' ? WORDS_RU : WORDS_EN)[minutes]}`];
  const pager = `<nav class="pager" aria-label="${lang === 'ru' ? 'Соседние статьи' : 'Nearby articles'}">
      ${prev ? `<a href="${prev.slug}.html"><div class="k">← ${esc(ui.prevLabel)} · ${inline(prev.section, lang)}</div><div class="t">${inline(prev.title, lang)}</div></a>` : '<span></span>'}
      ${next ? `<a class="next" href="${next.slug}.html"><div class="k">${inline(next.section, lang)} · ${esc(ui.nextLabel)} →</div><div class="t">${inline(next.title, lang)}</div></a>` : '<span></span>'}
    </nav>`;
  const article = `<article>
    ${crumbs}
    <h1 class="h1" style="font-size:40px;line-height:46px">${inline(a.title, lang)}</h1>
    <p class="lead" style="margin-top:14px;max-width:720px">${inline(a.lead, lang)}</p>
    <p class="doc-meta">${meta.map((m) => `<span>${inline(m, lang)}</span>`).join('')}${unv ? `<span class="unv-count" title="${esc(ui.unv)}">${icon('exclamationTriangle', 12)} ${esc(ui.unv)}</span>` : ''}</p>
    <hr style="margin:32px 0 8px">
    <div class="prose">${markdown(a.body, lang, { icon })}</div>
    <p class="caption" style="margin-top:48px">${inline(ui.feedback, lang)}</p>
    ${pager}
  </article>`;
  const toc = `<aside class="toc" data-toc><h2>${lang === 'ru' ? 'На этой странице' : 'On this page'}</h2><ul>${a.toc.map(([id, t]) => `<li><a href="#${id}">${inline(t, lang)}</a></li>`).join('')}</ul></aside>`;
  return {
    title: a.title,
    description: a.lead,
    body: `<div class="container"><div class="docs-layout">${docsNav(c, lang, slug)}${article}${toc}</div></div>`,
    bodyClass: 'page-docs-article',
  };
}
