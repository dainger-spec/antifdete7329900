import { inline, esc } from '../../lib/html.mjs';
import { icon, mark } from '../../lib/kit.mjs';

export default function auth(c, { lang, state }) {
  const seg = (current) => `<nav class="seg full" aria-label="${lang === 'ru' ? 'Способ входа' : 'Sign-in method'}">${c.methods.map(([href, t]) => `<a href="${href}"${href === current ? ' aria-current="page"' : ''}>${esc(t)}</a>`).join('')}</nav>`;
  let main = '';
  let title = c.title;
  if (state === 'email') {
    const e = c.email;
    main = `<h1 class="h1">${inline(e.title, lang)}</h1><p class="lead">${inline(e.lead, lang)}</p>${seg('login.html')}
      <form class="form" action="login-code.html">
        <div><label class="field-label" for="email">${inline(e.label, lang)}</label><input class="input" id="email" type="email" name="email" autocomplete="email" placeholder="${esc(e.placeholder)}" required></div>
        <button class="btn primary block lg" type="submit">${inline(e.action, lang)}</button>
      </form>
      <p class="alt">${inline(e.alt, lang)}</p>`;
  } else if (state === 'code') {
    const k = c.code;
    title = k.title;
    main = `<a class="link-arrow" href="login.html" style="margin-bottom:24px">${icon('arrowLeft', 14)}${inline(k.change, lang)}</a>
      <h1 class="h1">${inline(k.title, lang)}</h1><p class="lead">${inline(k.lead, lang)}</p>
      <form class="form" action="account.html">
        <fieldset style="border:0;padding:0;margin:0"><legend class="field-label">${inline(k.label, lang)}</legend>
          <div class="otp">${Array.from({ length: 6 }, (_, i) => `<input class="input" inputmode="numeric" maxlength="1" aria-label="${lang === 'ru' ? 'Цифра' : 'Digit'} ${i + 1}"${i === 0 ? ' autofocus autocomplete="one-time-code"' : ''}>`).join('')}</div>
        </fieldset>
        <button class="btn primary block lg" type="submit">${inline(k.action, lang)}</button>
      </form>
      <p class="alt" style="display:flex;flex-wrap:wrap;gap:6px 16px"><a href="login-code.html">${inline(k.resend, lang)}</a></p>
      <p class="hint">${inline(k.hint, lang)}</p>`;
  } else if (state === 'key') {
    const k = c.key;
    title = k.title;
    main = `<h1 class="h1">${inline(k.title, lang)}</h1><p class="lead">${inline(k.lead, lang)}</p>${seg('login-key.html')}
      <form class="form" action="account.html">
        <div><label class="field-label" for="key">${inline(k.label, lang)}</label><input class="input mono" id="key" name="key" autocomplete="off" spellcheck="false" placeholder="${esc(k.placeholder)}"></div>
        <div class="note warn">${icon('exclamationTriangle', 18)}<div><p>${inline(k.warn, lang)}</p></div></div>
        <button class="btn primary block lg" type="submit">${inline(k.action, lang)}</button>
      </form>
      <p class="alt">${inline(k.alt, lang)}</p>`;
  } else {
    const s = c.signup;
    title = s.title;
    main = `<h1 class="h1">${inline(s.title, lang)}</h1><p class="lead">${inline(s.lead, lang)}</p>
      <div class="card" style="margin-top:28px"><h2 class="h4">${inline(s.emailTitle, lang)}</h2><p style="margin-top:4px">${inline(s.emailText, lang)}</p>
        <form class="form" action="login-code.html" style="margin-top:16px">
          <div><label class="field-label" for="email">${inline(s.label, lang)}</label><input class="input" id="email" type="email" autocomplete="email" placeholder="${esc(s.placeholder)}"></div>
          <label class="check"><input type="checkbox" required><span>${inline(s.agree, lang)}</span></label>
          <button class="btn primary block" type="submit">${inline(s.action, lang)}</button>
        </form></div>
      <div class="card" style="margin-top:12px;display:grid;grid-template-columns:minmax(0,1fr) auto;gap:14px;align-items:center"><div><h2 class="h4">${inline(s.keyTitle, lang)}</h2><p style="margin-top:4px">${inline(s.keyText, lang)}</p></div><a class="btn secondary" href="pricing.html">${inline(s.keyAction, lang)}</a></div>
      <p class="alt">${inline(s.alt, lang)}</p>`;
  }
  const sd = c.side;
  const side = `<aside class="auth-side"><div class="inner">
    ${mark(40)}
    <h2 class="h3" style="margin-top:24px">${inline(sd.title, lang)}</h2>
    <ul class="list-check" style="margin-top:16px">${sd.items.map(([ic, t]) => `<li>${icon(ic, 16)}<span>${inline(t, lang)}</span></li>`).join('')}</ul>
    <div class="note accent" style="margin-top:28px">${icon('key', 18)}<div><p>${inline(sd.note, lang)}</p></div></div>
  </div></aside>`;
  return { title, body: `<div class="auth"><div class="auth-main"><div class="auth-card">${main}</div></div>${side}</div>`, bodyClass: 'page-auth', hideFooter: true };
}
