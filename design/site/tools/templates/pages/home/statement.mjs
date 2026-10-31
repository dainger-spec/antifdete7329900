// Scene "statement": the idea in one paragraph; its words light up one by one as you scroll (the one
// place for this device on the page). *Starred* phrases are set in the accent blue.
//
// The paragraph is set word by word so each word can carry its own light (--i of --n). Typesetting is
// done here, not by the browser: short words stick to the next word, a sentence's first word to its
// second, a dash to the word before it, and the closing accent phrase stays whole, so no line ends on «в»
// or on a lone «Сайты», and no line holds a single word.
import { esc, plain } from '../../../lib/html.mjs';
import { STICKY } from './lib.mjs';

export const assets = { styles: ['scenes/statement.css'] };

const NBSP = ' ';

function words(text, lang) {
  let accent = false;
  const list = plain(text).split(/[ \t\n]+/).filter(Boolean).map((w) => {
    if (w.startsWith('*')) accent = true;
    const out = { w: w.replace(/\*/g, ''), accent };
    if (/\*[.,;:!?]?$/.test(w)) accent = false;
    return out;
  });
  const sticky = STICKY[lang] || STICKY.en;
  // A closing accent phrase of up to four words stays on one line («все аккаунты сразу»).
  let tail = list.length - 2;
  while (tail > 0 && list[tail - 1].accent && list[list.length - 1].accent && list.length - tail < 4) tail--;
  return list.map((x, i) => {
    const next = list[i + 1];
    let glue = ' ';
    if (!next) glue = '';
    else if (sticky.has(x.w.toLowerCase())) glue = NBSP;            // «в отдельной», «и история»
    else if (i === 0 || /[.!?]$/.test(list[i - 1].w)) glue = NBSP;     // a sentence never leaves its first word behind: «Сайты видят»
    else if (/^[—–]$/.test(next.w)) glue = NBSP;                       // «Safari —»
    else if (i >= tail) glue = NBSP;                                   // no lone word (or split phrase) on the last line
    return { ...x, glue };
  });
}

export default function statement(c, { lang }) {
  const ws = words(c.text, lang);
  const body = ws.map((x, i) => `<span class="w${x.accent ? ' acc' : ''}" style="--i:${i}">${esc(x.w)}</span>${x.glue}`).join('');
  return `<section class="scene sc-statement" data-scene="statement" data-title="${esc(c.title)}" style="--len:230vh">
  <div class="scene-pin"><div class="container">
    <p class="st-text" data-r="0.05 0.8" style="--n:${ws.length}">${body}</p>
  </div></div>
</section>`;
}
