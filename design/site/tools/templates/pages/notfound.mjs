import { inline, esc } from '../../lib/html.mjs';
import { icon, glyph } from '../../lib/kit.mjs';

export default function notfound(c, { lang }) {
  return {
    title: c.title,
    body: `<section class="notfound"><div class="container"><div class="split" style="align-items:center">
      <div class="art" aria-hidden="true" style="color:var(--text-primary)">${glyph(220, 'var(--surface)').replace('fill="var(--surface)"', 'fill="#1E222A" stroke="rgba(255,255,255,0.10)" stroke-width="0.4"')}</div>
      <div>
        <p class="code404">${inline(c.code, lang)}</p>
        <h1 class="h1" style="margin-top:12px">${inline(c.heading, lang)}</h1>
        <p class="lead" style="margin-top:14px">${inline(c.lead, lang)}</p>
        <div class="btn-row" style="margin-top:28px">${c.links.map(([href, t], i) => `<a class="btn ${i === 0 ? 'primary' : 'secondary'}" href="${href}">${esc(t)}</a>`).join('')}</div>
        <form class="search" role="search" style="max-width:420px;margin-top:28px" action="docs.html">${icon('magnifyingglass', 14)}<input class="input" type="search" placeholder="${esc(c.search)}" aria-label="${esc(c.search)}"></form>
      </div>
    </div></div></section>`,
    bodyClass: 'page-404',
  };
}
