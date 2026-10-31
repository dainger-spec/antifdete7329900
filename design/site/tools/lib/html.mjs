// Text helpers for the page templates: escaping, the inline markup copy may use, typography
// (non-breaking spaces where Russian and English typesetting want them), and a small Markdown
// reader for long texts (legal pages, the docs and blog templates).

export const esc = (s) => String(s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

let product = { name: 'Lumen', domain: 'lumen.example' };
export function setProduct(p) { product = { ...product, ...p }; }
export const productName = () => product.name;

const NBSP = ' ';
// Russian: one- and two-letter words (prepositions, conjunctions, particles) stick to the next word;
// a dash sticks to the word before it; a number to the unit after it.
const RU_SHORT = /(^|[\s(«„"—–])(в|во|без|до|из|к|ко|на|над|не|ни|о|об|от|по|под|при|про|с|со|у|и|а|но|да|за|для|что|как|или|же|ли|бы|то|мы|вы|он|она|они|их|его|её|это|все|всё|нет|так|уже|чем|где|кто|ещё|при|раз|т\.|е\.)\s+/gi;
const EN_SHORT = /(^|[\s(“"—–])(a|an|the|of|to|in|on|at|by|or|and|is|it|as|if|no|so|we|you|its|for|not|per)\s+/gi;

function typoText(text, lang) {
  let t = text;
  if (lang === 'ru') {
    // Twice, so runs of short words ("и в", "а не") all stick.
    t = t.replace(RU_SHORT, (m, pre, w) => `${pre}${w}${NBSP}`).replace(RU_SHORT, (m, pre, w) => `${pre}${w}${NBSP}`);
  } else {
    t = t.replace(EN_SHORT, (m, pre, w) => `${pre}${w}${NBSP}`);
  }
  t = t.replace(/ (—|–) /g, `${NBSP}$1 `);
  t = t.replace(/(\d) (МиБ|МБ|КБ|ГБ|Мбит|мин|с|ч|дн\.|дней|дня|день|%|MiB|MB|KB|GB|min|s|h|px|бит|bit)(?=[\s.,;:)]|$)/g, `$1${NBSP}$2`);
  t = t.replace(/(№|§) (\d)/g, `$1${NBSP}$2`);
  // A number keeps the word after it ("26 стран", "448 признаков", "14 differences").
  t = t.replace(/(\d) ([A-Za-zА-Яа-яЁё])/g, `$1${NBSP}$2`);
  return t;
}

/// Applies typography to the text between tags, never inside <code>, <pre>, <kbd> or attributes.
export function typo(html, lang) {
  const parts = String(html).split(/(<[^>]+>)/);
  let skip = 0;
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i];
    if (p.startsWith('<')) {
      if (/^<(code|pre|kbd|script|style)\b/i.test(p)) skip++;
      else if (/^<\/(code|pre|kbd|script|style)>/i.test(p)) skip = Math.max(0, skip - 1);
      continue;
    }
    if (!skip && p) parts[i] = typoText(p, lang);
  }
  return parts.join('');
}

/// Inline markup in copy strings: **strong**, `code`, [text](href), _em_, {{name}}, {{domain}},
/// {{tbd:qN:text}} (a value the owner decides, highlighted in the prototype), {{nb:…}} (no wrap).
export function inline(s, lang) {
  if (s == null) return '';
  let out = esc(s);
  out = out.replace(/\{\{name\}\}/g, esc(product.name)).replace(/\{\{domain\}\}/g, esc(product.domain));
  out = out.replace(/`([^`]+)`/g, (m, c) => `<code>${c}</code>`);
  out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  out = out.replace(/(^|[\s(])_([^_]+)_(?=[\s.,;:)!?]|$)/g, '$1<em>$2</em>');
  out = out.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, t, href) => `<a href="${href}">${t}</a>`);
  out = out.replace(/\{\{tbd:(q\d+):([^}]*)\}\}/g, (m, q, t) => `<span class="tbd" data-q="${q}" title="Решение владельца: вопрос ${q.slice(1)}">${t}</span>`);
  out = out.replace(/\{\{nb:([^}]*)\}\}/g, (m, t) => `<span style="white-space:nowrap">${t}</span>`);
  return lang ? typo(out, lang) : out;
}

/// The same markup reduced to plain text (titles, meta descriptions, attributes).
export function plain(s) {
  if (s == null) return '';
  return String(s)
    .replace(/\{\{name\}\}/g, product.name).replace(/\{\{domain\}\}/g, product.domain)
    .replace(/\{\{tbd:q\d+:([^}]*)\}\}/g, '$1').replace(/\{\{nb:([^}]*)\}\}/g, '$1')
    .replace(/\*\*([^*]+)\*\*/g, '$1').replace(/`([^`]+)`/g, '$1').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');
}

/// A small Markdown reader: ## / ### headings (with ids), paragraphs, - and 1. lists, > quotes,
/// | tables |, ``` code ```, and ::: note|warn|accent … ::: callouts. Inline markup as above.
export function markdown(src, lang, { icon } = {}) {
  const lines = String(src).replace(/\r/g, '').split('\n');
  const out = [];
  let i = 0;
  const slug = (t) => t.toLowerCase().replace(/<[^>]+>/g, '').replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-|-$/g, '');
  const flushPara = (buf) => { if (buf.length) out.push(`<p>${inline(buf.join(' '), lang)}</p>`); };
  let para = [];
  while (i < lines.length) {
    const line = lines[i];
    const t = line.trim();
    if (!t) { flushPara(para); para = []; i++; continue; }
    let m;
    if ((m = t.match(/^(#{2,3})\s+(.*?)(?:\s+\{#([\w-]+)\})?$/))) {
      flushPara(para); para = [];
      const level = m[1].length;
      const id = m[3] || slug(m[2]);
      out.push(`<h${level} id="${id}">${inline(m[2], lang)}</h${level}>`);
      i++; continue;
    }
    if (t.startsWith('```')) {
      flushPara(para); para = [];
      const label = t.slice(3).trim();
      const body = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) { body.push(lines[i]); i++; }
      i++;
      out.push(codeBlock(body.join('\n'), label, lang));
      continue;
    }
    if ((m = t.match(/^:::\s*(note|warn|accent|danger)\s*$/))) {
      flushPara(para); para = [];
      const kind = m[1];
      const body = [];
      i++;
      while (i < lines.length && lines[i].trim() !== ':::') { body.push(lines[i]); i++; }
      i++;
      const ic = { note: 'infoCircle', warn: 'exclamationTriangle', accent: 'infoCircle', danger: 'exclamationTriangle' }[kind];
      out.push(`<div class="note ${kind === 'note' ? '' : kind}">${icon ? icon(ic, 18) : ''}<div>${markdown(body.join('\n'), lang, { icon })}</div></div>`);
      continue;
    }
    if (t.startsWith('|')) {
      flushPara(para); para = [];
      const rows = [];
      while (i < lines.length && lines[i].trim().startsWith('|')) { rows.push(lines[i].trim()); i++; }
      const cells = (r) => r.replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
      const head = cells(rows[0]);
      const body = rows.slice(2).map(cells);
      out.push(`<div class="table-wrap"><div class="table-scroll"><table class="table stack-mobile"><thead><tr>${head.map((h) => `<th>${inline(h, lang)}</th>`).join('')}</tr></thead><tbody>` +
        body.map((r) => `<tr>${r.map((c, k) => `<td data-label="${esc(head[k].replace(/[*`]/g, ''))}"${k === 0 ? ' class="strong"' : ''}>${inline(c, lang)}</td>`).join('')}</tr>`).join('') +
        `</tbody></table></div></div>`);
      continue;
    }
    if (/^[-*]\s+/.test(t) || /^\d+\.\s+/.test(t)) {
      flushPara(para); para = [];
      const ordered = /^\d+\./.test(t);
      const items = [];
      while (i < lines.length) {
        const l = lines[i].trim();
        if (/^[-*]\s+/.test(l) || /^\d+\.\s+/.test(l)) { items.push(l.replace(/^([-*]|\d+\.)\s+/, '')); i++; }
        else if (l && !/^(#|\||```|:::|>)/.test(l) && items.length && lines[i].startsWith('  ')) { items[items.length - 1] += ' ' + l; i++; }
        else break;
      }
      const tag = ordered ? 'ol' : 'ul';
      out.push(`<${tag}>${items.map((it) => `<li>${inline(it, lang)}</li>`).join('')}</${tag}>`);
      continue;
    }
    if (t.startsWith('>')) {
      flushPara(para); para = [];
      const body = [];
      while (i < lines.length && lines[i].trim().startsWith('>')) { body.push(lines[i].trim().replace(/^>\s?/, '')); i++; }
      out.push(`<blockquote><p>${inline(body.join(' '), lang)}</p></blockquote>`);
      continue;
    }
    para.push(t);
    i++;
  }
  flushPara(para);
  return out.join('\n');
}

/// A code block with a copy button; `# comment` lines are dimmed, `$` prompts kept out of the copy.
export function codeBlock(code, label = '', lang = 'ru', copyLabel) {
  const lines = String(code).split('\n');
  const html = lines.map((l) => {
    if (/^\s*#/.test(l)) return `<span class="c">${esc(l)}</span>`;
    return esc(l).replace(/^(\$ )/, '<span class="p" aria-hidden="true">$1</span>');
  }).join('\n');
  const copy = copyLabel || (lang === 'en' ? ['Copy', 'Copied'] : ['Скопировать', 'Скопировано']);
  const plain = lines.filter((l) => !/^\s*#/.test(l)).map((l) => l.replace(/^\$ /, '')).join('\n').trim();
  return `<div class="code">${label || true ? `<div class="code-head"><span>${esc(label || (lang === 'en' ? 'Terminal' : 'Терминал'))}</span>` +
    `<button class="copy-btn" type="button" data-copy="${esc(plain)}"><span class="idle">${copy[0]}</span><span class="done">${copy[1]}</span></button></div>` : ''}` +
    `<pre><code>${html}</code></pre></div>`;
}
