// Scene "sites": what a site sees. One Safari window (macOS 26: Liquid Glass toolbar, one tab) shows the same
// news site in three profiles in turn — Store (Germany), Ads (USA), QA (Japan). As the scene scrolls, the
// profile in the toolbar changes and the page re-sets itself line by line, top to bottom: language, date
// format, local time, even the weather unit. Beside it (under it on a phone) a quiet list says what the
// site sees for each profile — country, language, time zone, local time; a light marks the one in the window.
//
// The site in the window is sample data: its text is German, English and Japanese whatever the page's
// language, so it lives here and not in copy/. Its dates and times are inside [data-sample]: one moment,
// Thursday 29 October 2026, 13:32 UTC — 14:32 in Berlin (CET), 9:32 in New York (EDT), 22:32 in Tokyo.
//
// Every changing text is a "roll": its three variants share one grid cell (the cell takes the largest) and
// the scene's script moves --x of each roll from 0 to 2; a variant shows while --x is at its index (--k).
// Without the script --x is 0: the first profile, finished.
import { inline, esc } from '../../../lib/html.mjs';
import { flag } from '../../../lib/kit.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: ['scenes/sites.css'], scripts: ['scenes/sites.js'] };

const LANGS = ['de', 'en', 'ja'];

/// The site, one edition per profile (same order as the profiles in copy). "\n" in a title is a line break
/// on wide windows (Japanese breaks between phrases, not anywhere).
const SITE = [
  {
    edition: 'Ausgabe Deutschland', signin: 'Anmelden', subscribe: 'Abonnieren',
    date: 'Donnerstag, 29. Oktober 2026', time: '14:32 Uhr', city: 'Berlin', temp: '9 °C', sky: 'Bewölkt',
    nav: ['Politik', 'Wirtschaft', 'Kultur', 'Wissen', 'Reisen', 'Sport'],
    kicker: 'Winterzeit',
    title: 'Eine Stunde zurück —\nund um fünf ist es dunkel',
    dek: 'Seit Sonntag gilt wieder die Winterzeit. Was die gewonnene Stunde mit Schlaf, Stimmung und dem Leben in der Stadt macht.',
    dekS: 'Seit Sonntag gilt die Winterzeit. Was die gewonnene Stunde mit uns macht.',
    by: 'Wissen · 6 Min. Lesezeit',
    most: 'Meistgelesen',
    items: ['Nachtzüge: Wohin es diesen Winter geht', 'Warum wir im Herbst anders schlafen', 'Die schönsten Lesesäle der Stadt'],
    more: [['Kultur', 'Ein Abend im Konzerthaus'], ['Reisen', 'Mit dem Zug an die Ostsee'], ['Wirtschaft', 'Kaffee wird wieder teurer']],
  },
  {
    edition: 'U.S. Edition', signin: 'Sign in', subscribe: 'Subscribe',
    date: 'Thursday, October 29, 2026', time: '9:32 a.m. ET', city: 'New York', temp: '54 °F', sky: 'Cloudy',
    nav: ['U.S.', 'World', 'Business', 'Culture', 'Science', 'Travel'],
    kicker: 'Daylight Saving Time',
    title: 'Clocks fall back Sunday —\nand it’s dark by five',
    dek: 'Daylight saving time ends this weekend across most of the country. Sleep researchers on making the darker evenings easier.',
    dekS: 'Daylight saving time ends this weekend. How to make the dark evenings easier.',
    by: 'Science · 6 min read',
    most: 'Most read',
    items: ['The night trains worth booking this winter', 'Why we sleep differently in the fall', 'The city’s most beautiful reading rooms'],
    more: [['Culture', 'Concert hall, opening night'], ['Travel', 'By train to the coast'], ['Business', 'Why coffee costs more again']],
  },
  {
    edition: '日本版', signin: 'ログイン', subscribe: '購読する',
    date: '2026年10月29日（木）', time: '22:32', city: '東京', temp: '17 °C', sky: 'くもり',
    nav: ['国内', '国際', '経済', '文化', '科学', '旅'],
    kicker: '季節',
    title: '紅葉前線、週末にも都心へ\n見頃は来月中旬から',
    dek: '今年の紅葉は例年より一週間ほど遅れ、見頃は十一月中旬から。各地の名所と、混雑を避けて歩ける時間帯をまとめました。',
    dekS: '今年の紅葉は例年より一週間ほど遅れ、見頃は十一月中旬から。',
    by: '旅 · 6分で読めます',
    most: 'よく読まれている記事',
    items: ['夜行列車で行く、この冬いちばんの旅', '秋になると眠りが変わるのはなぜか', '街でいちばん美しい図書館の閲覧室'],
    more: [['文化', '新しいコンサートホールの夜'], ['旅', '列車で海辺の町へ'], ['経済', 'コーヒー、また値上がりへ']],
  },
];

/// A roll: the three variants of one text in one cell; d is its place in the wave down the page.
const roll = (d, variants, cls = '') =>
  `<span class="rl${cls ? ' ' + cls : ''}" data-d="${d}">${variants.map((v, k) => `<span class="rv" style="--k:${k}" lang="${LANGS[k]}">${v}</span>`).join('')}</span>`;
const each = (fn) => SITE.map(fn);
const field = (d, key, cls) => roll(d, each((s) => esc(s[key])), cls);
const lines = (t) => esc(t).replace(/\n/g, '<br class="mp-br"> ');

// SF Symbols-like toolbar glyphs, drawn at 16 px (1.5 px strokes).
const svg = (body, w = 16) => `<svg width="${w}" height="16" viewBox="0 0 ${w} 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;
const G = {
  sidebar: svg('<rect x="1.75" y="2.75" width="14.5" height="10.5" rx="2.4"/><path d="M6.5 2.75v10.5"/><path d="M3.6 5.6h1.2M3.6 7.6h1.2"/>', 18),
  back: svg('<path d="M10 3 5 8l5 5"/>'),
  fwd: svg('<path d="m6 3 5 5-5 5"/>'),
  page: svg('<rect x="3.25" y="1.75" width="9.5" height="12.5" rx="1.8"/><path d="M5.75 5.5h4.5M5.75 8h4.5M5.75 10.5h2.5"/>'),
  share: svg('<path d="M8 1.75v8.5M5 4.5 8 1.6l3 2.9"/><path d="M5.2 6.6H4.4a1.6 1.6 0 0 0-1.6 1.6v4.6a1.6 1.6 0 0 0 1.6 1.6h7.2a1.6 1.6 0 0 0 1.6-1.6V8.2a1.6 1.6 0 0 0-1.6-1.6h-.8"/>'),
  plus: svg('<path d="M8 2.5v11M2.5 8h11"/>'),
  tabs: svg('<rect x="1.75" y="4.75" width="10" height="9.5" rx="1.8"/><path d="M4.75 2.25h7.5a2 2 0 0 1 2 2v7"/>', 17),
  chevron: '<svg width="9" height="9" viewBox="0 0 9 9" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="m2 3.4 2.5 2.5L7 3.4"/></svg>',
};

/// The Safari window with the site (decorative: aria-hidden; its meaning is in the list and a sentence).
function safari(profiles) {
  return `<div class="sw" aria-hidden="true" data-sample>
      <div class="sw-bar">
        <span class="sw-lights"><i></i><i></i><i></i></span>
        <span class="sw-cap sw-side">${G.sidebar}${G.chevron}</span>
        <span class="sw-cap sw-hist">${G.back}${G.fwd}</span>
        <span class="sw-cap sw-prof">${roll(0, profiles.map((p) => `${flag(p.code, 14)}<span>${esc(p.name)}</span>`), 'sw-who')}</span>
        <span class="sw-addr"><span class="sw-pg">${G.page}</span><span class="sw-url">meridian.example</span><i class="sw-load"></i></span>
        <span class="sw-cap sw-tools">${G.share}${G.plus}${G.tabs}</span>
      </div>
      <div class="sw-page">
        <div class="mp-util">
          ${roll(2, each((s) => `${esc(s.edition)}${G.chevron}`), 'mp-ed')}
          <span class="mp-acct">${field(2, 'signin', 'mp-in')}${roll(3, each((s) => `<span class="mp-sub">${esc(s.subscribe)}</span>`), 'mp-subs')}</span>
        </div>
        <header class="mp-mast">
          <span class="mp-when">${field(3, 'date', 'mp-date')}${field(4, 'time', 'mp-time')}</span>
          <span class="mp-logo">Meridian</span>
          <span class="mp-wx">${roll(3, each((s) => `${esc(s.city)} ${esc(s.temp)}`), 'mp-city')}${field(4, 'sky', 'mp-sky')}</span>
        </header>
        ${roll(4, each((s) => `${esc(s.date)}<i> · </i>${esc(s.time)}`), 'b mp-datel')}
        <nav class="mp-nav">${roll(5, each((s) => s.nav.map((n) => `<span>${esc(n)}</span>`).join('')), 'b')}</nav>
        <div class="mp-main">
          <article class="mp-story">
            ${field(6, 'kicker', 'b mp-kick')}
            ${roll(7, each((s) => lines(s.title)), 'b mp-title')}
            ${field(8, 'dek', 'b mp-dek mp-dek-l')}${field(8, 'dekS', 'b mp-dek mp-dek-s')}
            ${field(9, 'by', 'b mp-by')}
          </article>
          <aside class="mp-most">
            ${field(6, 'most', 'b mp-mt')}
            <ol>${SITE[0].items.map((_, i) => `<li><span class="mp-n">${i + 1}</span>${roll(7 + i, each((s) => esc(s.items[i])), 'b')}</li>`).join('')}</ol>
          </aside>
        </div>
        <div class="mp-more">${SITE[0].more.map((_, i) => `<div>${roll(10, each((s) => `<b>${esc(s.more[i][0])}</b>${esc(s.more[i][1])}`), 'b')}</div>`).join('')}</div>
      </div>
    </div>`;
}

export default function scene(c, { lang }) {
  const P = c.profiles;
  const head = c.head.map((l) => l.replace(/ (—|–)/g, ' $1'));
  return `<section class="scene sc-sites" data-scene="sites" data-title="${esc(c.title)}" style="--len:310vh">
  <div class="scene-pin">
    <div class="container sit">
      <h2 class="h-xl sit-head">${twoTone(head, lang)}</h2>
      <div class="sit-stage" data-r="0 0.14">
        <i class="sit-light" aria-hidden="true"></i>
        ${safari(P)}
        <p class="visually-hidden">${inline(c.label, lang)}</p>
      </div>
      <div class="sit-side" data-r="0.02 0.14">
        <p class="sit-k">${inline(c.sees, lang)}</p>
        <div class="sit-track" data-d="1">
        <ol class="sit-list">
          ${P.map((p, k) => `<li class="sit-it" style="--k:${k}">
            <span class="sit-who">${flag(p.code, 14)}<span>${esc(p.name)}</span></span>
            <span class="sit-c">${esc(p.country)}</span>
            <span class="sit-t" data-sample>${esc(p.time)}</span>
            <span class="sit-m mono">${esc(p.lang)} · ${esc(p.zone)}</span>
          </li>`).join('')}
        </ol>
        <i class="sit-bar" aria-hidden="true"></i>
        </div>
        <p class="sit-lead">${inline(c.lead, lang)}</p>
      </div>
    </div>
  </div>
</section>`;
}
