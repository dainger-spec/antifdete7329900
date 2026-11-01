import { inline, esc } from '../../lib/html.mjs';
import { icon, mark } from '../../lib/kit.mjs';

// Sign-in and sign-up, focused — as the owner asked, after Resend's sign-up page, in Lumen's own drawing (no art copied):
// one column in the middle of a dark field; at the top a way back and the language; the mark in its tile, a title, the
// way to the other form («Already have an account? Sign in»), the fields, one button that stays dim until the form is
// filled, and the small print under it. The site's header and footer step aside. Behind it all, two arcs of light — the
// mark's circle, drawn in CSS (bands of radial light under conic masks), with grain and a dark centre so the form always
// reads. As the account server has it (docs/SITE_API.md, docs/CONTRACT.md §5): email and password; a code from the email
// confirms a registration and resets a password, nothing else. No Google or GitHub sign-in: the server has none. No «send
// me news» box: there are no marketing emails. Accepting the terms is a line under the button.
export default function auth(c, { lang, slug, state }) {
  const ru = lang === 'ru';
  const other = `../${ru ? 'en' : 'ru'}/${slug}.html`;
  const otp = () => `<div class="otp" data-otp>${Array.from({ length: 6 }, (_, i) => `<input class="input" inputmode="numeric" pattern="[0-9]" maxlength="1" required aria-label="${ru ? 'Цифра' : 'Digit'} ${i + 1}"${i === 0 ? ' autofocus autocomplete="one-time-code"' : ''}>`).join('')}</div>`;
  const pwInput = (id, auto, min = true) => `<div class="pw"><input class="input" id="${id}" type="password" autocomplete="${auto}"${min ? ' minlength="10"' : ''} required><button class="pw-eye" type="button" aria-label="${esc(c.eye.show)}" data-show="${esc(c.eye.show)}" data-hide="${esc(c.eye.hide)}">${icon('eye', 17)}${icon('eyeSlash', 17)}</button></div>`;
  const pw = (id, label, auto, hint = '') => `<div><label class="field-label" for="${id}">${inline(label, lang)}</label>${pwInput(id, auto)}${hint ? `<p class="hint">${inline(hint, lang)}</p>` : ''}</div>`;
  const emailField = (x, autofocus = true) => `<div><label class="field-label" for="email">${inline(x.label, lang)}</label><input class="input" id="email" type="email" autocomplete="email" placeholder="${esc(x.placeholder)}" required${autofocus ? ' autofocus' : ''}></div>`;
  const note = `<p class="auth2-note">${icon('key', 14)}<span>${inline(c.note, lang)}</span></p>`;

  let doc = c.title, title = '', alt = '', lead = '', action = '', fields = '', after = '';
  let back = { href: 'index.html', t: c.home };
  if (state === 'email') {
    const e = c.email;
    doc = e.doc; title = e.title; alt = e.alt; action = 'account.html';
    fields = `${emailField(e)}
        <div><div class="field-row"><label class="field-label" for="password">${inline(e.password, lang)}</label><a class="field-link" href="reset-password.html">${inline(e.forgot, lang)}</a></div>${pwInput('password', 'current-password', false)}</div>
        <button class="btn primary block lg" type="submit">${inline(e.action, lang)}</button>`;
    after = note;
  } else if (state === 'signup') {
    const s = c.signup;
    doc = s.doc; title = s.title; alt = s.alt; action = 'signup-code.html';
    fields = `${emailField(s)}
        ${pw('password', s.password, 'new-password', s.passwordHint)}
        <button class="btn primary block lg" type="submit">${inline(s.action, lang)}</button>`;
    after = `${note}<p class="auth2-legal">${inline(s.legal, lang)}</p>`;
  } else if (state === 'code') {
    const k = c.code;
    doc = title = k.title; lead = k.lead; action = 'account.html';
    back = { href: 'signup.html', t: k.change };
    fields = `<fieldset><legend class="field-label">${inline(k.label, lang)}</legend>${otp()}</fieldset>
        <button class="btn primary block lg" type="submit">${inline(k.action, lang)}</button>`;
    after = `<p class="auth2-legal">${inline(k.hint, lang)}</p>`;
  } else if (state === 'reset') {
    const r = c.reset;
    doc = title = r.title; lead = r.lead; alt = r.alt; action = 'reset-password-code.html';
    fields = `${emailField(r)}
        <button class="btn primary block lg" type="submit">${inline(r.action, lang)}</button>`;
  } else {
    const r = c.resetCode;
    doc = title = r.title; lead = r.lead; action = 'account.html';
    back = { href: 'reset-password.html', t: c.code.change };
    fields = `<fieldset><legend class="field-label">${inline(r.label, lang)}</legend>${otp()}</fieldset>
        ${pw('new', r.password, 'new-password', r.passwordHint)}
        ${pw('repeat', r.repeat, 'new-password')}
        <button class="btn primary block lg" type="submit">${inline(r.action, lang)}</button>`;
    after = `<p class="auth2-legal">${inline(r.note, lang)}</p>`;
  }

  // The reset form puts «Remembered it? Sign in» under the button; the others put the way to the other form under the title.
  const altTop = state === 'reset' ? '' : alt;
  const card = `<div class="auth2-card">
      <span class="auth2-mark">${mark(52)}</span>
      <h1 class="auth2-title">${inline(title, lang)}</h1>
      ${altTop ? `<p class="auth2-alt">${inline(altTop, lang)}</p>` : ''}${lead ? `<p class="auth2-lead">${inline(lead, lang)}</p>` : ''}
      <form class="form auth2-form" action="${action}">
        ${fields}
      </form>
      ${state === 'reset' ? `<p class="auth2-alt small">${inline(alt, lang)}</p>` : ''}${after}
    </div>`;
  const top = `<div class="auth2-top">
      <a class="auth2-back" href="${back.href}">${icon('chevronLeft', 15)}<span>${inline(back.t, lang)}</span></a>
      <a class="auth2-lang" href="${other}" hreflang="${ru ? 'en' : 'ru'}" lang="${ru ? 'en' : 'ru'}" title="${ru ? 'English' : 'Русский'}">${icon('globe', 15)}<span>${ru ? 'EN' : 'RU'}</span></a>
    </div>`;
  const bg = '<div class="auth2-bg" aria-hidden="true"><i class="r1"></i><i class="r2"></i></div>';
  // Show or hide the password; the six code cells move along by themselves and take a pasted code whole.
  const script = `<script>(function(){
  document.querySelectorAll('.pw-eye').forEach(function(b){b.addEventListener('click',function(){var i=b.previousElementSibling,on=i.type==='password';i.type=on?'text':'password';b.classList.toggle('on',on);b.setAttribute('aria-label',on?b.dataset.hide:b.dataset.show);i.focus();});});
  document.querySelectorAll('[data-otp]').forEach(function(g){var f=[].slice.call(g.querySelectorAll('input'));f.forEach(function(x,k){
    x.addEventListener('input',function(){x.value=x.value.replace(/\\D/g,'').slice(-1);if(x.value&&f[k+1])f[k+1].focus();});
    x.addEventListener('keydown',function(e){if(e.key==='Backspace'&&!x.value&&f[k-1])f[k-1].focus();});
    x.addEventListener('paste',function(e){var d=((e.clipboardData||window.clipboardData).getData('text')||'').replace(/\\D/g,'').slice(0,6);if(d.length>1){e.preventDefault();f.forEach(function(y,j){y.value=d[j]||'';});f[Math.min(d.length,5)].focus();}});
  });});
})();</script>`;
  return { title: doc, body: `<div class="auth2">${bg}${top}<div class="auth2-mid">${card}</div></div>${script}`, bodyClass: 'page-auth', hideFooter: true };
}
