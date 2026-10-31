import { inline, esc, markdown, plain } from '../../lib/html.mjs';
import { icon, mark } from '../../lib/kit.mjs';

export default function blogPost(c, { lang }) {
  const p = c.post;
  const head = `<header class="post-head"><div class="container narrow">
    <nav class="breadcrumbs"><a href="blog.html">${inline(p.crumb, lang)}</a>${icon('chevronRight', 10)}<span class="tag">${esc(c.types[p.type])}</span></nav>
    <h1 class="h1">${inline(p.title, lang)}</h1>
    <p class="lead" style="margin-top:18px">${inline(p.lead, lang)}</p>
    <div class="meta"><span class="byline">${mark(20)}${inline(p.byline, lang)}</span><time>${inline(p.date, lang)}</time><span>${inline(p.readTime, lang)}</span></div>
  </div></header>`;
  const body = `<div class="container narrow" style="padding-bottom:64px"><hr style="margin-bottom:8px"><div class="prose">${markdown(p.body, lang, { icon })}</div>
    <div class="row" style="justify-content:space-between;margin-top:48px;padding-top:24px;border-top:1px solid var(--hairline)">
      <a class="link-arrow" href="blog.html">${icon('arrowLeft', 14)}${inline(p.back, lang)}</a>
      <button class="btn ghost sm copy-btn" type="button" data-copy="${esc(plain(p.title))}">${icon('link', 14)}<span class="idle">${inline(p.share, lang)}</span><span class="done">${lang === 'ru' ? 'Скопировано' : 'Copied'}</span></button>
    </div></div>`;
  const more = `<section class="section"><div class="container narrow"><h2 class="h4" style="margin-bottom:12px">${inline(p.more, lang)}</h2>
    <div class="posts">${c.posts.slice(0, 3).map((x) => `<a class="post-row" href="${x.href}" style="grid-template-columns:150px minmax(0,1fr);padding:20px 0"><div class="pd"><time>${inline(x.date, lang)}</time></div><div><h3 class="pt" style="font-size:18px;line-height:26px">${inline(x.title, lang)}</h3></div></a>`).join('')}</div>
  </div></section>`;
  return { title: p.title, description: p.lead, body: head + body + more, bodyClass: 'page-post' };
}
