// Helpers the home scenes share.
import { inline, esc, plain } from '../../../lib/html.mjs';

// Short words that should not end a line (they stay with the next word).
export const STICKY = { ru: new Set('в во без до из к ко на над не ни о об от по под при про с со у и а но да за для что как или же ли бы то мы вы это все всё нет так уже чем где кто ещё свой своя свои'.split(' ')), en: new Set('a an the of to in on at by or and is it as if no so we you its for not per'.split(' ')) };

/// A two-tone headline: the first line white, the rest grey (.dim).
export const twoTone = (lines, lang) => [].concat(lines).map((l, i) => `<span${i ? ' class="dim"' : ''}>${inline(l, lang)}</span>`).join(' ');

/// A paragraph whose words light up one by one as the scene scrolls (CSS: --p of the scene, --i of the
/// word, --n words). *Starred* phrases are set in the accent gradient.
export function manifest(text, lang, cls = 'manifest') {
  let accent = false;
  const words = plain(text).split(/\s+/).map((w) => {
    const open = w.startsWith('*'), close = w.endsWith('*') || w.endsWith('*.') || w.endsWith('*,');
    if (open) accent = true;
    const word = w.replace(/\*/g, '');
    const out = { word, accent };
    if (close) accent = false;
    return out;
  });
  const sticky = STICKY[lang] || STICKY.en;
  return `<p class="${cls}" style="--n:${words.length}">${words.map((x, i) =>
    `<span class="w${x.accent ? ' acc' : ''}" style="--i:${i}">${esc(x.word)}</span>${i < words.length - 1 ? (sticky.has(x.word.toLowerCase()) ? ' ' : ' ') : ''}`).join('')}</p>`;
}
