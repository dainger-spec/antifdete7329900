// Writes the texts of every page, as a reader sees them, to copy/{ru,en}/<page>.md — from the built pages
// themselves, so the readable copy and the prototype never drift apart. The source the pages are built
// from is copy/source/{ru,en}/*.mjs; edit there, then build and export again.
//
//   node design/site/tools/export-copy.mjs
//
// Values the owner decides are written ⟦qN: value⟧ (question N in the README).
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { SITE } from './lib/kit.mjs';
import { PAGES, LANGS } from './build.mjs';

const { chromium } = createRequire(import.meta.url)('playwright');

const NAMES = {
  ru: { index: 'Главная', features: 'Возможности', 'how-it-works': 'Как устроено', verification: 'Как мы проверяем', pricing: 'Цены', download: 'Скачать', docs: 'Документация — структура', 'docs-import-cookies': 'Документация — шаблон статьи', blog: 'Обновления — список', 'blog-no-noise': 'Обновления — запись', login: 'Вход по email', 'login-code': 'Вход: код из письма', 'login-key': 'Вход по ключу', signup: 'Регистрация', account: 'Кабинет: подписка и оплата', 'account-devices': 'Кабинет: устройства', 'account-sync': 'Кабинет: синхронизация', 'account-invoices': 'Кабинет: счета', 'account-settings': 'Кабинет: настройки', privacy: 'Политика конфиденциальности', terms: 'Условия использования', refunds: 'Правила возврата', support: 'Поддержка и контакты', 404: 'Страница 404' },
  en: { index: 'Home', features: 'Features', 'how-it-works': 'How it works', verification: 'How we verify', pricing: 'Pricing', download: 'Download', docs: 'Docs — structure', 'docs-import-cookies': 'Docs — article template', blog: 'Updates — list', 'blog-no-noise': 'Updates — post', login: 'Sign in by email', 'login-code': 'Sign in: the emailed code', 'login-key': 'Sign in with a key', signup: 'Sign up', account: 'Account: subscription and billing', 'account-devices': 'Account: devices', 'account-sync': 'Account: sync', 'account-invoices': 'Account: invoices', 'account-settings': 'Account: settings', privacy: 'Privacy policy', terms: 'Terms of use', refunds: 'Refund policy', support: 'Support and contact', 404: 'Page 404' },
};

// Runs in the page: <main> (and, for the shared file, header and footer) as Markdown.
function toMarkdown(selector) {
  const BLOCK = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'UL', 'OL', 'TABLE', 'PRE', 'BLOCKQUOTE', 'DETAILS', 'FIGURE', 'DL', 'FORM', 'FIGCAPTION', 'LI']);
  const inline = (node) => {
    let out = '';
    node.childNodes.forEach((n) => {
      if (n.nodeType === 3) { out += n.data.replace(/\s+/g, ' '); return; }
      if (n.nodeType !== 1) return;
      const el = n;
      if (el.matches('svg, script, style, [aria-hidden="true"]:not(.appwin):not(.demo)')) return;
      if (el.classList.contains('tbd')) { out += `⟦${el.dataset.q}: ${el.textContent.trim()}⟧`; return; }
      if (el.tagName === 'CODE' || el.classList.contains('mono') || el.tagName === 'KBD') { out += '`' + el.textContent.trim() + '`'; return; }
      if (el.tagName === 'STRONG' || el.tagName === 'B') { out += `**${inline(el).trim()}**`; return; }
      if (el.tagName === 'EM') { out += `_${inline(el).trim()}_`; return; }
      if (el.tagName === 'BR') { out += ' '; return; }
      if (el.tagName === 'INPUT') { if (el.placeholder) out += `[поле: ${el.placeholder}]`; return; }
      if (el.tagName === 'A' && el.classList.contains('btn')) { out += ` [${inline(el).trim()}] `; return; }
      if (el.tagName === 'BUTTON') { out += ` [${inline(el).trim()}] `; return; }
      if (el.tagName === 'A') { out += inline(el); return; }
      out += inline(el) + (getComputedStyle(el).display.startsWith('inline') ? '' : ' ');
    });
    return out;
  };
  const clean = (s) => s.replace(/[ \t]+/g, ' ').replace(/ +([.,;:!?»)])/g, '$1').trim();
  const lines = [];
  const walk = (node) => {
    node.childNodes.forEach((n) => {
      if (n.nodeType === 3) { const t = clean(n.data); if (t) lines.push(t, ''); return; }
      if (n.nodeType !== 1) return;
      const el = n;
      if (el.matches('svg, script, style, [data-proto], .indicator, .chipnav, .skip-link, .avatar, .traffic')) return;
      const t = el.tagName;
      // Drawn UI: one line per row, node or chip; meta lines joined with a middle dot.
      if (el.matches('.cols')) { const s = Array.from(el.children).map((c) => clean(inline(c))).filter(Boolean).join(' — '); if (s) lines.push(`- ${s}`); return; }
      if (el.matches('.rows')) { walk(el); lines.push(''); return; }
      if (el.matches('.chip')) { const k = el.querySelector('.k'); const s = k ? `${clean(k.textContent)}: ${clean(inline(el).replace(k.textContent, ''))}` : clean(inline(el)); if (s) lines.push(`- ${s}`, ''); return; }
      if (el.matches('.sites, .ident, .branch')) { const s = Array.from(el.children).map((c) => { const k = c.querySelector('.k'); return k ? `${clean(k.textContent)}: ${clean(inline(c).replace(k.textContent, ''))}` : clean(inline(c)); }).filter(Boolean).join(' · '); if (s) lines.push(s, ''); return; }
      if (el.matches('.node, .kl')) { const s = Array.from(el.children).map((c) => clean(inline(c))).filter(Boolean).join(' — ') || clean(inline(el)); if (s) lines.push(`- ${s}`, ''); return; }
      if (el.matches('.hero-meta, .doc-meta, .meta, .rv, .legend')) { const s = Array.from(el.children).map((c) => clean(inline(c))).filter(Boolean).join(' · '); if (s) lines.push(s, ''); return; }
      if (/^H[1-4]$/.test(t)) { lines.push('#'.repeat(+t[1]) + ' ' + clean(inline(el)), ''); return; }
      if (t === 'P' || t === 'FIGCAPTION' || t === 'LABEL' || t === 'LEGEND' || t === 'TIME') { const s = clean(inline(el)); if (s) lines.push(s, ''); return; }
      if (t === 'UL' || t === 'OL') { Array.from(el.children).forEach((li, i) => { const s = clean(inline(li)); if (s) lines.push(`${t === 'OL' ? `${i + 1}.` : '-'} ${s}`); }); lines.push(''); return; }
      if (t === 'TABLE') {
        const rows = Array.from(el.querySelectorAll('tr')).map((tr) => Array.from(tr.children).map((c) => clean(inline(c)).replace(/\|/g, '\\|')));
        if (!rows.length) return;
        const w = Math.max(...rows.map((r) => r.length));
        const fix = (r) => r.concat(Array(w - r.length).fill(''));
        const head = el.querySelector('thead') ? fix(rows.shift()) : Array(w).fill('');
        lines.push(`| ${head.join(' | ')} |`, `|${' --- |'.repeat(w)}`, ...rows.map((r) => `| ${fix(r).join(' | ')} |`), '');
        return;
      }
      if (t === 'DL') { const kids = Array.from(el.children); for (let i = 0; i < kids.length; i += 2) lines.push(`- **${clean(inline(kids[i]))}** — ${clean(inline(kids[i + 1] || el))}`); lines.push(''); return; }
      if (t === 'DETAILS') { const sum = el.querySelector('summary'); lines.push(`**${clean(inline(sum))}**`, ''); Array.from(el.children).filter((c) => c !== sum).forEach(walk); return; }
      if (t === 'PRE') { lines.push('```', el.textContent.replace(/\n$/, ''), '```', ''); return; }
      if (t === 'BLOCKQUOTE') { lines.push('> ' + clean(inline(el)), ''); return; }
      if (t === 'SELECT') { lines.push('Варианты: ' + Array.from(el.options).map((o) => o.textContent).join(' · '), ''); return; }
      if (t === 'TEXTAREA') { lines.push(`[поле: ${el.placeholder}]`, ''); return; }
      if (t === 'A' || t === 'BUTTON' || el.classList.contains('btn') || el.classList.contains('tag') || el.classList.contains('chip') || el.classList.contains('res')) { const s = clean(inline(el)); if (s) lines.push(el.classList.contains('btn') || t === 'BUTTON' ? `[${s}]` : s, ''); return; }
      // A container: if it holds only inline content, it is one paragraph; otherwise walk into it.
      const hasBlock = Array.from(el.querySelectorAll('*')).some((d) => BLOCK.has(d.tagName) || ['block', 'flex', 'grid', 'table', 'list-item'].includes(getComputedStyle(d).display));
      if (!hasBlock) { const s = clean(inline(el)); if (s) lines.push(s, ''); return; }
      walk(el);
    });
  };
  document.querySelectorAll(selector).forEach(walk);
  return lines.join('\n').replace(/\n{3,}/g, '\n\n').trim() + '\n';
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, reducedMotion: 'reduce' });
await ctx.route((u) => !u.href.startsWith('file:'), (r) => r.abort());
for (const lang of LANGS) {
  const dir = path.join(SITE, 'copy', lang);
  fs.mkdirSync(dir, { recursive: true });
  for (const page of PAGES) {
    const file = path.join(SITE, 'prototype', lang, `${page.slug}.html`);
    if (!fs.existsSync(file)) continue;
    const p = await ctx.newPage();
    await p.goto(pathToFileURL(file).href + '?shot=1');
    const body = await p.evaluate(toMarkdown, 'main');
    const meta = await p.evaluate(() => ({ title: document.title, description: document.querySelector('meta[name=description]').content }));
    const head = lang === 'ru'
      ? `<!-- Сгенерировано tools/export-copy.mjs из prototype/${lang}/${page.slug}.html. Источник текста — copy/source/${lang}/*.mjs: правьте там. ⟦qN: …⟧ — решение владельца (вопрос N в README). -->`
      : `<!-- Generated by tools/export-copy.mjs from prototype/${lang}/${page.slug}.html. The source is copy/source/${lang}/*.mjs: edit there. ⟦qN: …⟧ is the owner's decision (question N in the README). -->`;
    const out = `${head}\n\n# ${NAMES[lang][page.slug]}\n\n${lang === 'ru' ? 'Заголовок окна' : 'Window title'}: ${meta.title}\n\n${lang === 'ru' ? 'Описание для поиска' : 'Search description'}: ${meta.description}\n\n---\n\n${body}`;
    fs.writeFileSync(path.join(dir, `${page.slug === 'index' ? 'home' : page.slug}.md`), out);
    await p.close();
  }
  // Header and footer, once.
  const p = await ctx.newPage();
  await p.goto(pathToFileURL(path.join(SITE, 'prototype', lang, 'index.html')).href + '?shot=1');
  const shared = await p.evaluate(toMarkdown, '.site-header nav.nav, .site-header .header-end > a, .site-footer');
  fs.writeFileSync(path.join(dir, '_header-footer.md'), `# ${lang === 'ru' ? 'Шапка и подвал (на всех страницах)' : 'Header and footer (every page)'}\n\n${shared}`);
  await p.close();
}
await browser.close();
console.log('EXPORTED copy/{ru,en}/*.md');
