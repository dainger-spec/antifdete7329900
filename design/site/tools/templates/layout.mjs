// The page shell: <head>, the header with its navigation, the footer, and the prototype's own
// strip (language, decision marks, motion) that the real site will not have.
import { icon, mark, wordmark, faviconDataURL } from '../lib/kit.mjs';
import { esc, inline, typo, plain, productName } from '../lib/html.mjs';

const FAVICON = faviconDataURL();

/// The lockup: mark 24 + LUMEN 12 high (the app's sidebar lockup scaled for a 64 px header).
export function lockup(markSize = 24, wordHeight = 12.4, gap = 10) {
  return `<span class="lockup" style="display:inline-flex;align-items:center;gap:${gap}px">${mark(markSize)}${wordmark(wordHeight, 'currentColor')}</span>`;
}

export function header(ctx) {
  const { lang, c, slug, other } = ctx;
  const ru = lang === 'ru';
  const nav = c.nav.map(([href, label]) =>
    `<a href="${href}.html"${navCurrent(slug, href) ? ' aria-current="page"' : ''}>${esc(label)}</a>`).join('');
  const langSwitch = `<span class="lang" role="group" aria-label="${esc(c.a11y.language)}">` +
    `<a href="../ru/${other}" hreflang="ru" lang="ru"${ru ? ' aria-current="true"' : ''}>RU</a>` +
    `<a href="../en/${other}" hreflang="en" lang="en"${!ru ? ' aria-current="true"' : ''}>EN</a></span>`;
  // The other language, one tap away (the footer and the phone menu carry the full switch).
  const otherLang = ru
    ? `<a class="hlang" href="../en/${other}" hreflang="en" lang="en" title="English" aria-label="English">${icon('globe', 15)}<span>EN</span></a>`
    : `<a class="hlang" href="../ru/${other}" hreflang="ru" lang="ru" title="Русский" aria-label="Русский">${icon('globe', 15)}<span>RU</span></a>`;
  const account = slug.startsWith('login') || slug.startsWith('account') || slug === 'signup';
  const menuLinks = c.nav.map(([href, label]) =>
    `<a href="${href}.html"${navCurrent(slug, href) ? ' aria-current="page"' : ''}>${esc(label)}${icon('chevronRight', 16)}</a>`).join('');
  // The logo on the left, the sections in a capsule of glass in the middle, the actions on the right. The bar
  // itself is clear at the top of a page and turns to glass once the page scrolls under it (site.js).
  return `<header class="site-header">
  <div class="container hbar">
    <a class="brand" href="index.html" aria-label="${esc(productName())} — ${esc(c.a11y.home)}">${lockup()}<span class="hsub" data-hsub>${inline(ctx.sub || '', lang)}</span></a>
    <nav class="nav glass" aria-label="${esc(c.a11y.mainNav)}">${nav}</nav>
    <div class="header-end">
      ${otherLang}
      <a class="hlogin" href="login.html"${account ? ' aria-current="page"' : ''}>${esc(c.header.login)}</a>
      <a class="btn primary sm" href="download.html"><span class="long">${esc(c.header.download)}</span><span class="short">${esc(c.header.downloadShort)}</span></a>
      <details class="menu">
        <summary aria-label="${esc(c.a11y.menu)}">${icon('chevronDown', 18, 'open')}${icon('xmark', 16, 'close')}</summary>
        <div class="menu-panel">
          <nav aria-label="${esc(c.a11y.mainNav)}">${menuLinks}</nav>
          <div class="menu-foot">
            <a class="btn primary lg block" href="download.html">${icon('download', 16)}${esc(c.header.downloadLong)}</a>
            <div class="menu-row"><a class="btn secondary" href="login.html">${esc(c.header.login)}</a>${langSwitch.replace('class="lang"', 'class="lang seg"')}</div>
          </div>
        </div>
      </details>
    </div>
  </div>
</header>`;
}

function navCurrent(slug, href) {
  if (slug === href) return true;
  if (href === 'docs' && slug.startsWith('docs')) return true;
  if (href === 'blog' && slug.startsWith('blog')) return true;
  return false;
}

export function footer(ctx) {
  const { lang, c, other } = ctx;
  const col = (title, links) => `<div><h2>${esc(title)}</h2><ul>${links.map(([href, label]) => `<li><a href="${href}">${esc(label)}</a></li>`).join('')}</ul></div>`;
  return `<footer class="site-footer">
  <div class="container">
    <div class="footer-grid">
      <div class="footer-about">
        <a class="brand" href="index.html" aria-label="${esc(productName())}">${lockup(22, 11.4, 9)}</a>
        <p>${inline(c.footer.about, lang)}</p>
      </div>
      ${c.footer.columns.map(([t, links]) => col(t, links)).join('\n      ')}
    </div>
    <div class="footer-bottom">
      <span>${inline(c.footer.copyright, lang)}</span>
      <span class="row"><span>${inline(c.footer.noTracking, lang)}</span>
      <span class="lang" role="group" aria-label="${esc(c.a11y.language)}"><a href="../ru/${other}" hreflang="ru"${lang === 'ru' ? ' aria-current="true"' : ''}>RU</a><a href="../en/${other}" hreflang="en"${lang === 'en' ? ' aria-current="true"' : ''}>EN</a></span></span>
    </div>
  </div>
</footer>`;
}

/// The prototype's strip at the bottom of the window (hidden in renders and on phones).
function protoBar(ctx) {
  const { lang, other } = ctx;
  const ru = lang === 'ru';
  return `<div class="proto-bar" data-proto aria-label="${ru ? 'Панель прототипа' : 'Prototype bar'}">
  <a href="../index.html">${ru ? '← Все страницы' : '← All pages'}</a><span class="sep"></span>
  <a href="../ru/${other}"${ru ? ' class="on"' : ''}>RU</a><a href="../en/${other}"${!ru ? ' class="on"' : ''}>EN</a><span class="sep"></span>
  <button type="button" data-toggle="tbd" title="${ru ? 'Жёлтым — значения, которые решаете вы' : 'Yellow: values you decide'}">${ru ? 'Отметки решений' : 'Decision marks'}</button>
  <button type="button" data-toggle="rm" title="prefers-reduced-motion">${ru ? 'Без движения' : 'Reduce motion'}</button>
</div>`;
}

export function document(ctx, { title, description, body, bodyClass = '', hideFooter = false, scripts = [] }) {
  const { lang, c } = ctx;
  const fullTitle = title ? `${plain(title)} — ${productName()}` : `${productName()} — ${plain(c.meta.tagline)}`;
  description = plain(description || c.meta.description);
  return `<!doctype html>
<html lang="${lang}" class="no-js">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(fullTitle)}</title>
<meta name="description" content="${esc(description)}">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#060709">
<link rel="icon" type="image/svg+xml" href="${FAVICON}">
<link rel="alternate" hreflang="ru" href="../ru/${ctx.other}">
<link rel="alternate" hreflang="en" href="../en/${ctx.other}">
<link rel="stylesheet" href="../assets/site.css">
<script>document.documentElement.classList.replace('no-js','js');(function(){var q=new URLSearchParams(location.search),h=document.documentElement;if(q.get('shot')==='1')h.classList.add('shot');if(q.get('rec')==='1')h.classList.add('rec');try{if(q.get('tbd')==='1'||localStorage.getItem('lumen-site-tbd')==='1')h.classList.add('tbd-on');if(q.get('rm')==='1'||localStorage.getItem('lumen-site-rm')==='1')h.classList.add('rm');}catch(e){}})();</script>
</head>
<body class="${esc(bodyClass)}">
<a class="skip-link" href="#main">${esc(c.a11y.skip)}</a>
${header(ctx)}
<main id="main">
${body}
</main>
${hideFooter ? '' : footer(ctx)}
${protoBar(ctx)}
${scripts.map((x) => `<script src="../assets/${x}" defer></script>`).join('\n')}
<script src="../assets/site.js" defer></script>
</body>
</html>
`;
}

export { typo };
