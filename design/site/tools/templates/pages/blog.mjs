import { inline, esc } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';

export default function blog(c, { lang }) {
  const l = c.list;
  const hero = `<section class="page-hero"><div class="container">
    <p class="eyebrow">${inline(l.eyebrow, lang)}</p>
    <h1 class="h1">${inline(l.title, lang)}</h1>
    <p class="lead">${inline(l.lead, lang)}</p>
  </div></section>`;
  const filters = `<div class="row" style="justify-content:space-between;margin-bottom:8px">
    <nav class="seg" aria-label="${lang === 'ru' ? 'Фильтр' : 'Filter'}">${l.filters.map(([id, t], i) => `<a href="blog.html"${i === 0 ? ' aria-current="page"' : ''}>${esc(t)}</a>`).join('')}</nav>
    <a class="link-arrow" href="blog.html">${icon('wave', 14)}${inline(l.feed, lang)}</a>
  </div>`;
  const rows = c.posts.map((p) => `<a class="post-row reveal" href="${p.href}">
    <div class="pd"><time>${inline(p.date, lang)}</time><br><span class="tag${p.type === 'update' ? ' accent' : ''}">${esc(c.types[p.type])}</span></div>
    <div><h2 class="pt">${inline(p.title, lang)}</h2><p class="ps">${inline(p.summary, lang)}</p></div>
  </a>`).join('');
  return { body: `${hero}<section style="padding-bottom:var(--section-pad)"><div class="container">${filters}<div class="posts" style="margin-top:24px">${rows}</div></div></section>`, bodyClass: 'page-blog' };
}
