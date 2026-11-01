import { inline, esc } from '../../lib/html.mjs';
import { icon, mark } from '../../lib/kit.mjs';

export default function auth(c, { lang, state }) {
  // As the account server has it (docs/SITE_API.md): email and password; a code from the email confirms a
  // registration and resets a password, nothing else.
  const otp = (autofocus = true) => `<div class="otp">${Array.from({ length: 6 }, (_, i) => `<input class="input" inputmode="numeric" maxlength="1" aria-label="${lang === 'ru' ? 'Цифра' : 'Digit'} ${i + 1}"${i === 0 && autofocus ? ' autofocus autocomplete="one-time-code"' : ''}>`).join('')}</div>`;
  const pw = (id, label, auto, hint = '') => `<div><label class="field-label" for="${id}">${inline(label, lang)}</label><input class="input" id="${id}" type="password" autocomplete="${auto}" minlength="10" required>${hint ? `<p class="hint">${inline(hint, lang)}</p>` : ''}</div>`;
  let main = '';
  let title = c.title;
  if (state === 'email') {
    const e = c.email;
    main = `<h1 class="h1">${inline(e.title, lang)}</h1><p class="lead">${inline(e.lead, lang)}</p>
      <form class="form" action="account.html">
        <div><label class="field-label" for="email">${inline(e.label, lang)}</label><input class="input" id="email" type="email" name="email" autocomplete="email" placeholder="${esc(e.placeholder)}" required></div>
        <div><div class="field-row"><label class="field-label" for="password">${inline(e.password, lang)}</label><a class="field-link" href="reset-password.html">${inline(e.forgot, lang)}</a></div><input class="input" id="password" type="password" autocomplete="current-password" required></div>
        <button class="btn primary block lg" type="submit">${inline(e.action, lang)}</button>
      </form>
      <p class="alt">${inline(e.alt, lang)}</p>`;
  } else if (state === 'signup') {
    const s = c.signup;
    title = s.title;
    main = `<h1 class="h1">${inline(s.title, lang)}</h1><p class="lead">${inline(s.lead, lang)}</p>
      <form class="form" action="signup-code.html">
        <div><label class="field-label" for="email">${inline(s.label, lang)}</label><input class="input" id="email" type="email" autocomplete="email" placeholder="${esc(s.placeholder)}" required></div>
        ${pw('password', s.password, 'new-password', s.passwordHint)}
        <label class="check"><input type="checkbox" required><span>${inline(s.agree, lang)}</span></label>
        <button class="btn primary block lg" type="submit">${inline(s.action, lang)}</button>
      </form>
      <p class="alt">${inline(s.alt, lang)}</p>`;
  } else if (state === 'code') {
    const k = c.code;
    title = k.title;
    main = `<a class="link-arrow" href="signup.html" style="margin-bottom:24px">${icon('arrowLeft', 14)}${inline(k.change, lang)}</a>
      <h1 class="h1">${inline(k.title, lang)}</h1><p class="lead">${inline(k.lead, lang)}</p>
      <form class="form" action="account.html">
        <fieldset style="border:0;padding:0;margin:0"><legend class="field-label">${inline(k.label, lang)}</legend>${otp()}</fieldset>
        <button class="btn primary block lg" type="submit">${inline(k.action, lang)}</button>
      </form>
      <p class="hint" style="margin-top:16px">${inline(k.hint, lang)}</p>`;
  } else if (state === 'reset') {
    const r = c.reset;
    title = r.title;
    main = `<h1 class="h1">${inline(r.title, lang)}</h1><p class="lead">${inline(r.lead, lang)}</p>
      <form class="form" action="reset-password-code.html">
        <div><label class="field-label" for="email">${inline(r.label, lang)}</label><input class="input" id="email" type="email" autocomplete="email" placeholder="${esc(r.placeholder)}" required></div>
        <button class="btn primary block lg" type="submit">${inline(r.action, lang)}</button>
      </form>
      <p class="alt">${inline(r.alt, lang)}</p>`;
  } else {
    const r = c.resetCode;
    title = r.title;
    main = `<a class="link-arrow" href="reset-password.html" style="margin-bottom:24px">${icon('arrowLeft', 14)}${inline(c.code.change, lang)}</a>
      <h1 class="h1">${inline(r.title, lang)}</h1><p class="lead">${inline(r.lead, lang)}</p>
      <form class="form" action="account.html">
        <fieldset style="border:0;padding:0;margin:0"><legend class="field-label">${inline(r.label, lang)}</legend>${otp()}</fieldset>
        ${pw('new', r.password, 'new-password', r.passwordHint)}
        ${pw('repeat', r.repeat, 'new-password')}
        <button class="btn primary block lg" type="submit">${inline(r.action, lang)}</button>
      </form>
      <p class="hint" style="margin-top:16px">${inline(r.note, lang)}</p>`;
  }
  const sd = c.side;
  const side = `<aside class="auth-side${state === 'code' || state === 'resetCode' ? ' quiet' : ''}"><div class="inner">
    ${mark(40)}
    <h2 class="h3" style="margin-top:24px">${inline(sd.title, lang)}</h2>
    <ul class="list-check" style="margin-top:16px">${sd.items.map(([ic, t]) => `<li>${icon(ic, 16)}<span>${inline(t, lang)}</span></li>`).join('')}</ul>
    <div class="note accent" style="margin-top:28px">${icon('key', 18)}<div><p>${inline(sd.note, lang)}</p></div></div>
  </div></aside>`;
  return { title, body: `<div class="auth"><div class="auth-main"><div class="auth-card">${main}</div></div>${side}</div>`, bodyClass: 'page-auth', hideFooter: true };
}
