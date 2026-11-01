#!/usr/bin/env node
// Lumen's mail, generated from one place: the frame and the texts of every letter the server sends
// (lumen-api-server, internal/mail/templates.go), in Russian and English, as the files the server
// embeds — <name>.<lang>.html (Go html/template) and <name>.<lang>.txt (Go text/template, the
// subject in {{define "subject"}} on its first line). Then render.go parses each file the way the
// server will, runs it with sample data and writes the previews; check.mjs holds the rules.
//
//   node design/site/email/src/build.mjs        # templates → email/templates, previews → prototype/email
//
// The owner's brief: the way big companies send a code — the logo, one line, the code large, the
// signature; no banners, columns, illustrations, gradient buttons, pictures of text or open-tracking
// pixels. Tables, not flexbox or grid; inline styles only, no <style>; one column, at most 600 px;
// every colour set (the site is dark, so is the mail, and full-inversion dark modes turn it light
// as a whole — nothing is ever dark on dark); the logo a picture with alt «Lumen», so the letter
// reads without pictures; a text version beside every HTML one; the code in a large monospaced face.
// The format is agreed with the server agent: lumen-api-server, docs/SITE_API.md §11 — the logo goes
// into the letter itself (LogoURL = cid:lumen-mark-1, a template.URL), or, with LogoURL empty, the
// mark is the word «Lumen»; nothing is loaded from outside. Colours, type and the mark come from the site prototype (prototype/assets/site.css,
// the Liquid Glass tokens). html/template drops HTML comments, so there are no Outlook conditional
// comments: the 600 px column is width="600" with max-width:100%, and the button is a link with
// thick borders, which Outlook draws.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { typo } from '../../tools/lib/html.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const EMAIL = path.resolve(HERE, '..');
const SITE = path.resolve(EMAIL, '..');

// The site's tokens (prototype/assets/site.css): the page, surfaces, the three text tones, the
// accent and the light primary button. Hex only: Outlook knows no rgba().
const C = {
  page: '#060709', // --backdrop (Liquid Glass)
  surface: '#161920', // --surface
  line: '#1E222A', // --raised: dividers
  edge: '#252A33', // --raised-inset: the code box's and the receipt's border
  text: '#ECEEF2', // --text-primary
  text2: '#A2A9B6', // --text-secondary
  text3: '#8A93A3', // --text-tertiary
  accent: '#6F8FEA', // --accent: links
  button: '#F4F5F8', // .btn.primary
  buttonText: '#0A0B0E',
};
// The site's system faces, with what Windows and Android have in their place.
const FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', Roboto, Helvetica, Arial, sans-serif";
const MONO = "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace";
const type = (size, lh, color, weight = 400) => `font-family:${FONT};font-size:${size}px;line-height:${lh}px;font-weight:${weight};color:${color};mso-line-height-rule:exactly;`;

// The letters. Texts are the server's own (templates.go), laid out for the frame: a lead line, then
// the code, a button, details or more lines, then notes in the second tone. Two changes, both
// reported to the server agent: «don't reply to this mail» becomes «there is nothing to do» (replies
// now reach support), and the deletion letter names the sync data too (docs/SITE_API.md §4).
// Markup in texts: [label](url) is a link; {{…}} is a Go template action.
const MAILS = {
  signup_code: {
    ru: {
      subject: 'Код подтверждения Lumen: {{.Code}}',
      pre: 'Код действует 15 минут.',
      lead: 'Код для создания аккаунта Lumen:',
      code: '{{.Code}}',
      notes: ['Код действует 15 минут. Если вы не создавали аккаунт, ничего делать не нужно.'],
    },
    en: {
      subject: 'Your Lumen confirmation code: {{.Code}}',
      pre: 'The code is valid for 15 minutes.',
      lead: 'Your code to create a Lumen account:',
      code: '{{.Code}}',
      notes: ['The code is valid for 15 minutes. If you did not sign up, there is nothing to do.'],
    },
  },
  signup_existing: {
    ru: {
      subject: 'У вас уже есть аккаунт Lumen',
      pre: 'Войдите или сбросьте пароль.',
      lead: 'Кто-то — возможно, вы — пытался создать аккаунт Lumen с этим адресом. Аккаунт с ним уже есть.',
      button: ['Войти', '{{.SiteURL}}/login'],
      link: ['Забыли пароль?', '{{.SiteURL}}/reset-password'],
      notes: ['Если это были не вы, ничего делать не нужно.'],
    },
    en: {
      subject: 'You already have a Lumen account',
      pre: 'Sign in, or reset your password.',
      lead: 'Someone — perhaps you — tried to create a Lumen account with this address. There already is one.',
      button: ['Sign in', '{{.SiteURL}}/login'],
      link: ['Forgot your password?', '{{.SiteURL}}/reset-password'],
      notes: ['If it was not you, there is nothing to do.'],
    },
  },
  password_reset_code: {
    ru: {
      subject: 'Сброс пароля Lumen: {{.Code}}',
      pre: 'Код действует 15 минут.',
      lead: 'Код для нового пароля:',
      code: '{{.Code}}',
      notes: ['Код действует 15 минут. После смены пароля все входы в аккаунт будут завершены. Если вы не просили сброс, ничего делать не нужно — пароль останется прежним.'],
    },
    en: {
      subject: 'Reset your Lumen password: {{.Code}}',
      pre: 'The code is valid for 15 minutes.',
      lead: 'Your code to set a new password:',
      code: '{{.Code}}',
      notes: ['The code is valid for 15 minutes. Changing the password signs every session out. If you did not ask for this, there is nothing to do — the password stays as it is.'],
    },
  },
  password_changed: {
    ru: {
      subject: 'Пароль Lumen изменён',
      pre: 'Все прежние входы завершены.',
      lead: 'Пароль вашего аккаунта Lumen изменён, все прежние входы завершены.',
      notes: ['Если это были не вы, [сбросьте пароль]({{.SiteURL}}/reset-password) и напишите в поддержку — просто ответьте на это письмо.'],
    },
    en: {
      subject: 'Your Lumen password was changed',
      pre: 'Every earlier session is signed out.',
      lead: 'The password of your Lumen account was changed and every earlier session signed out.',
      notes: ['If it was not you, [reset the password]({{.SiteURL}}/reset-password) and contact support — just reply to this email.'],
    },
  },
  invite: {
    ru: {
      subject: 'Приглашение в команду Lumen',
      pre: 'Приглашение действует до {{.Expires}}.',
      lead: '{{.OwnerEmail}} приглашает вас в свою команду Lumen. У вас будет свой вход — со своим паролем.',
      button: ['Принять приглашение', '{{.AcceptURL}}'],
      notes: ['Если аккаунта Lumen у вас ещё нет, создайте его с этим адресом, затем откройте ссылку. Приглашение действует до {{.Expires}}.'],
    },
    en: {
      subject: 'An invitation to a Lumen team',
      pre: 'The invitation is valid until {{.Expires}}.',
      lead: '{{.OwnerEmail}} invites you to their Lumen team. You will have a sign-in of your own, with your own password.',
      button: ['Accept the invitation', '{{.AcceptURL}}'],
      notes: ['If you have no Lumen account yet, create one with this address, then open the link. The invitation is valid until {{.Expires}}.'],
    },
  },
  seat_revoked: {
    ru: {
      subject: 'Ваше место в команде Lumen закрыто',
      pre: 'Профили на ваших Mac остаются на месте.',
      lead: 'Ваше место в команде Lumen закрыто.',
      notes: ['Профили на ваших Mac остаются на месте; без действующего тарифа Lumen открывает их только для экспорта данных.'],
    },
    en: {
      subject: 'Your seat in a Lumen team was closed',
      pre: 'The profiles on your Macs stay where they are.',
      lead: 'Your seat in a Lumen team was closed.',
      notes: ['The profiles on your Macs stay where they are; without an active plan Lumen opens them only to export their data.'],
    },
  },
  reminder: {
    ru: {
      subject: 'Оплаченный период Lumen заканчивается {{.When}}',
      pre: 'Тариф «{{.PlanName}}» оплачен до {{.Ends}}.',
      lead: 'Тариф «{{.PlanName}}» оплачен до {{.Ends}}.',
      body: ['Автоматических списаний нет: чтобы продолжить, оплатите следующий период — он начнётся с конца текущего, ни один день не пропадёт.'],
      button: ['Продлить', '{{.SiteURL}}/account'],
      notes: ['Если не продлевать, Lumen продолжит открывать профили для экспорта данных. Данные профилей не удаляются никогда.'],
    },
    en: {
      subject: 'Your Lumen period ends {{.When}}',
      pre: 'Your “{{.PlanName}}” plan is paid until {{.Ends}}.',
      lead: 'Your “{{.PlanName}}” plan is paid until {{.Ends}}.',
      body: ['Nothing is charged automatically: to go on, pay for the next period — it starts where this one ends, no day is lost.'],
      button: ['Renew', '{{.SiteURL}}/account'],
      notes: ['Without a renewal, Lumen keeps opening your profiles to export their data. Profile data is never deleted.'],
    },
  },
  payment_received: {
    ru: {
      subject: 'Оплата получена — {{.Number}}',
      pre: 'Оплаченный период продлится до {{.Ends}}.',
      lead: 'Счёт {{.Number}} оплачен.',
      details: [['Тариф', '«{{.PlanName}}», {{.Cycle}}'], ['Сумма', '${{.PriceUSD}} ({{.Amount}} {{.Ticker}})'], ['Оплачено до', '{{.Ends}}']],
      notes: ['Возврат: 14 дней с первой оплаты без объяснения причин; после продления — 7 дней, если в новом периоде вы не работали. Возвращаем в той же монете и в том же количестве.'],
    },
    en: {
      subject: 'Payment received — {{.Number}}',
      pre: 'Your paid period lasts until {{.Ends}}.',
      lead: 'Invoice {{.Number}} is paid.',
      details: [['Plan', '“{{.PlanName}}”, {{.Cycle}}'], ['Amount', '${{.PriceUSD}} ({{.Amount}} {{.Ticker}})'], ['Paid until', '{{.Ends}}']],
      notes: ['Refunds: within 14 days of the first payment, no questions asked; after a renewal, within 7 days if you did not work in the new period. We refund in the same coin and the same amount.'],
    },
  },
  deletion_scheduled: {
    ru: {
      subject: 'Аккаунт Lumen будет удалён',
      pre: 'До {{.Due}} удаление можно отменить.',
      lead: 'Мы получили просьбу удалить ваш аккаунт Lumen.',
      body: ['{{.Due}} будут удалены адрес почты, пароль, устройства, места в команде и зашифрованные данные синхронизации на сервере. Записи о платежах сохраняются без адреса почты — их требует учёт.', 'До этой даты удаление можно отменить: войдите в аккаунт.'],
      button: ['Войти в аккаунт', '{{.SiteURL}}/account'],
      notes: ['Профили на ваших Mac этим не затрагиваются: они хранятся только у вас, Lumen их не удаляет.'],
    },
    en: {
      subject: 'Your Lumen account will be deleted',
      pre: 'Until {{.Due}} the deletion can be cancelled.',
      lead: 'We received a request to delete your Lumen account.',
      body: ['On {{.Due}} the email address, password, devices, team seats and the encrypted sync data on the server will be deleted. Payment records are kept without the email address, as accounting requires.', 'Until then the deletion can be cancelled: sign in.'],
      button: ['Sign in', '{{.SiteURL}}/account'],
      notes: ['The profiles on your Macs are not touched: they are only on your Macs, and Lumen does not delete them.'],
    },
  },
  deletion_cancelled: {
    ru: {
      subject: 'Удаление аккаунта Lumen отменено',
      pre: 'Аккаунт остаётся.',
      lead: 'Удаление аккаунта отменено, аккаунт остаётся.',
      notes: ['Войдите в Lumen на своих Mac заново.'],
    },
    en: {
      subject: 'Your Lumen account will not be deleted',
      pre: 'Your account stays.',
      lead: 'The deletion is cancelled; your account stays.',
      notes: ['Sign in to Lumen on your Macs again.'],
    },
  },
};
const SIGNATURE = { ru: '— Lumen', en: '— Lumen' };
const FOOTER = { ru: 'Ответ на это письмо придёт в поддержку Lumen.', en: 'Replies to this email reach Lumen support.' };

// Literal text is HTML-escaped; {{…}} actions stay as they are (html/template escapes their values).
const esc = (s) => s.split(/(\{\{[^}]*\}\})/).map((p, i) => (i % 2 ? p : p.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'))).join('');
const linkStyle = `color:${C.accent};text-decoration:underline;`;
// [label](url) is a link; when the url is the site's ({{.SiteURL}}…), it is a link only if the server
// passed SiteURL to that letter (docs/SITE_API.md §11 lists no fields for some letters).
const guard = (url) => (url.startsWith('{{.SiteURL}}') ? ['{{if .SiteURL}}', '{{end}}'] : ['', '']);
const inlineHTML = (s) => s.split(/(\[[^\]]+\]\([^)]+\))/).map((p) => {
  const m = p.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
  if (!m) return esc(p);
  const a = `<a href="${m[2]}" target="_blank" style="${linkStyle}">${esc(m[1])}</a>`;
  const [open, close] = guard(m[2]);
  return open ? `${open}${a}{{else}}${esc(m[1])}${close}` : a;
}).join('');
const inlineText = (s) => s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (all, label, url) => {
  const [open, close] = guard(url);
  return `${label}${open} (${url})${close}`;
});

const row = (pad, inner, style = '') => `<tr><td align="left" style="padding:${pad};${style}">${inner}</td></tr>`;

function html(lang, m) {
  const rows = [];
  // the logo (docs/SITE_API.md §11): the picture the server puts into the letter (cid:), its alt «Lumen» set
  // in the site's type small enough to fit the 48 px box whole; with no picture, the mark is the word, in
  // the letter's own light colour (never a dark word on the dark page)
  rows.push(row('0 0 32px', `{{if .LogoURL}}<img src="{{.LogoURL}}" width="48" height="48" alt="Lumen" style="display:block;width:48px;height:48px;border:0;outline:none;text-decoration:none;${type(13, 48, C.text, 600)}">{{else}}<span style="display:inline-block;${type(20, 48, C.text, 600)}letter-spacing:0.02em;">Lumen</span>{{end}}`));
  rows.push(row('0', inlineHTML(m.lead), type(16, 26, C.text)));
  if (m.code) {
    rows.push(row('20px 0 0', `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${C.surface}" style="width:100%;background-color:${C.surface};border:1px solid ${C.edge};border-radius:14px;border-collapse:separate;"><tr><td align="left" style="padding:20px 24px;font-family:${MONO};font-size:34px;line-height:40px;font-weight:600;letter-spacing:8px;color:${C.text};mso-line-height-rule:exactly;">${m.code}</td></tr></table>`));
  }
  for (const p of m.body || []) rows.push(row('14px 0 0', inlineHTML(p), type(16, 26, C.text)));
  if (m.details) {
    const cells = m.details.map(([k, v], i) => {
      const top = i ? `border-top:1px solid ${C.line};` : '';
      return `<tr><td align="left" valign="top" style="padding:12px 0;${top}${type(14, 20, C.text3)}">${esc(k)}</td><td align="right" valign="top" style="padding:12px 0 12px 16px;${top}${type(14, 20, C.text, 500)}">${esc(v)}</td></tr>`;
    }).join('');
    rows.push(row('20px 0 0', `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${C.surface}" style="width:100%;background-color:${C.surface};border:1px solid ${C.edge};border-radius:14px;border-collapse:separate;"><tr><td style="padding:4px 20px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:collapse;">${cells}</table></td></tr></table>`));
  }
  if (m.button) {
    const [label, href] = m.button;
    // a link with thick borders in the button's colour: a button everywhere, Outlook included
    const btn = `<td bgcolor="${C.button}" style="background-color:${C.button};border-radius:999px;"><a href="${href}" target="_blank" style="display:inline-block;border:solid ${C.button};border-width:13px 24px;border-radius:999px;background-color:${C.button};${type(15, 20, C.buttonText, 600)}text-decoration:none;">${esc(label)}</a></td>`;
    const link = m.link ? `<td style="padding:0 0 0 20px;${type(15, 20, C.accent)}"><a href="${m.link[1]}" target="_blank" style="${linkStyle}text-decoration:none;">${esc(m.link[0])}</a></td>` : '';
    rows.push(row('24px 0 0', `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;"><tr>${btn}${link}</tr></table>`));
  }
  for (const n of m.notes || []) rows.push(row('20px 0 0', inlineHTML(n), type(14, 22, C.text2)));
  rows.push(row('28px 0 0', esc(SIGNATURE[lang]), type(16, 26, C.text)));
  rows.push(row('40px 0 0', `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:collapse;"><tr><td height="1" bgcolor="${C.line}" style="height:1px;line-height:1px;font-size:1px;background-color:${C.line};color:${C.line};">&nbsp;</td></tr></table>`));
  rows.push(row('16px 0 0', esc(FOOTER[lang]), type(12, 18, C.text3)));
  // the preview line inboxes show: hidden, and padded so the body doesn't run on after it
  const pre = `<div style="display:none;max-height:0;max-width:0;overflow:hidden;mso-hide:all;font-size:1px;line-height:1px;color:${C.page};opacity:0;">${esc(m.pre)}${'&#847;&zwnj;&nbsp;'.repeat(40)}</div>`;
  return `<!doctype html>
<html lang="${lang}" dir="ltr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="x-apple-disable-message-reformatting">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<meta name="format-detection" content="telephone=no, date=no, address=no, email=no">
</head>
<body bgcolor="${C.page}" style="margin:0;padding:0;background-color:${C.page};-webkit-text-size-adjust:100%;text-size-adjust:100%;">
${pre}
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${C.page}" style="width:100%;background-color:${C.page};border-collapse:collapse;">
<tr><td align="center" bgcolor="${C.page}" style="padding:40px 16px 48px;background-color:${C.page};">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" bgcolor="${C.page}" style="width:600px;max-width:100%;background-color:${C.page};border-collapse:collapse;">
${rows.join('\n')}
</table>
</td></tr>
</table>
</body>
</html>
`;
}

function text(lang, m) {
  const parts = [inlineText(m.lead)];
  if (m.code) parts.push(m.code);
  for (const p of m.body || []) parts.push(inlineText(p));
  if (m.details) parts.push(m.details.map(([k, v]) => `${k}: ${v}`).join('\n'));
  const links = [];
  if (m.button) links.push(`${m.button[0]}: ${m.button[1]}`);
  if (m.link) links.push(`${m.link[0]} ${m.link[1]}`);
  if (links.length) parts.push(links.join('\n'));
  for (const n of m.notes || []) parts.push(inlineText(n));
  parts.push(SIGNATURE[lang]);
  parts.push(FOOTER[lang]);
  return `{{define "subject"}}${m.subject}{{end}}${parts.join('\n\n')}\n`;
}

const out = path.join(EMAIL, 'templates');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
let n = 0;
for (const [name, langs] of Object.entries(MAILS)) {
  for (const lang of ['ru', 'en']) {
    const m = langs[lang];
    // the site's typography: a number keeps its word, a dash its word before it, short Russian words the next one —
    // never inside a template action ({{if .LogoURL}} must keep its plain space)
    const acts = [];
    const shielded = html(lang, m).replace(/\{\{[^}]*\}\}/g, (a) => `\u0000${acts.push(a) - 1}\u0000`);
    fs.writeFileSync(path.join(out, `${name}.${lang}.html`), typo(shielded, lang).replace(/\u0000(\d+)\u0000/g, (x, i) => acts[+i]));
    fs.writeFileSync(path.join(out, `${name}.${lang}.txt`), text(lang, m));
    n += 2;
  }
}
// the logo the server puts into each letter lies beside the templates (docs/SITE_API.md §11)
fs.copyFileSync(path.join(EMAIL, 'src', 'lumen-mark-1.png'), path.join(out, 'lumen-mark-1.png'));
console.log(`WROTE ${n} templates and the logo → email/templates`);

// The server's engine reads every file and runs it with sample data: previews into prototype/email.
execFileSync('go', ['run', path.join(HERE, 'render.go'), EMAIL, path.join(SITE, 'prototype', 'email')], { stdio: 'inherit' });
// The rules.
execFileSync(process.execPath, [path.join(HERE, 'check.mjs')], { stdio: 'inherit' });
