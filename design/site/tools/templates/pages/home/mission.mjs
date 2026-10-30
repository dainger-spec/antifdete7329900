// Scene "mission": all your profiles at once, each in a window of its own. One Safari window becomes many:
// the scene opens on a single window (the "Store" profile's shop admin); as it scrolls, the other windows come
// out from behind it and everything spreads the way Mission Control lays out a Mac's windows — each window a
// different profile on a different site. Under each window, as in Mission Control, its name: the profile's
// flag and name. "Store" keeps the focus ring; the others show the inactive window's grey traffic lights.
// On a phone the same window opens large under the first line, then slides down while the others fan out
// above it like cards in Wallet: every window's bar (and with it the profile: flag and name, at full size)
// shows above the next; the front window shows its site at the foot. A short phone screen gets four windows.
//
// The windows are drawn at their own size (a Mac window of 780–960 px) and scaled into the room; the room is
// one design space (1360 wide) scaled to the page by --k (assets/scenes/mission.js; a ladder of steps in the
// CSS without JavaScript). On a phone each window is the card's real width and only the site inside it is
// scaled (--kp), so the bar and its text stay at full size.
//
// The sites in the windows are sample data (a store's admin in German, an ads console in English, a help
// desk in British English, a checkout on a Japanese staging server, a sales pipeline in Dutch, a blog editor
// in French), so they live here and not in copy/; every window is [data-sample] and aria-hidden — the scene's
// meaning is in the headline, the lead and a sentence for screen readers (copy: label).
import { inline, esc } from '../../../lib/html.mjs';
import { flag } from '../../../lib/kit.mjs';

export const assets = { styles: ['scenes/mission.css'], scripts: ['scenes/mission.js'] };

// MARK: Small line icons (16 px grid, 1.5 px strokes) for the sites and the Safari bar
const sv = (body, w = 16, h = 16) => `<svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;
const IC = {
  sidebar: sv('<rect x="1.75" y="2.75" width="14.5" height="10.5" rx="2.4"/><path d="M6.5 2.75v10.5"/><path d="M3.6 5.6h1.2M3.6 7.6h1.2"/>', 18),
  back: sv('<path d="M10 3 5 8l5 5"/>'),
  fwd: sv('<path d="m6 3 5 5-5 5"/>'),
  page: sv('<rect x="3.25" y="1.75" width="9.5" height="12.5" rx="1.8"/><path d="M5.75 5.5h4.5M5.75 8h4.5M5.75 10.5h2.5"/>'),
  share: sv('<path d="M8 1.75v8.5M5 4.5 8 1.6l3 2.9"/><path d="M5.2 6.6H4.4a1.6 1.6 0 0 0-1.6 1.6v4.6a1.6 1.6 0 0 0 1.6 1.6h7.2a1.6 1.6 0 0 0 1.6-1.6V8.2a1.6 1.6 0 0 0-1.6-1.6h-.8"/>'),
  plus: sv('<path d="M8 2.5v11M2.5 8h11"/>'),
  tabs: sv('<rect x="1.75" y="4.75" width="10" height="9.5" rx="1.8"/><path d="M4.75 2.25h7.5a2 2 0 0 1 2 2v7"/>', 17),
  chev: '<svg width="9" height="9" viewBox="0 0 9 9" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="m2 3.4 2.5 2.5L7 3.4"/></svg>',
  home: sv('<path d="M2.5 7.2 8 2.6l5.5 4.6"/><path d="M4 6.2v7.2h8V6.2"/>'),
  box: sv('<path d="M2.5 5 8 2.4 13.5 5v6.2L8 13.8l-5.5-2.6z"/><path d="M2.5 5 8 7.6 13.5 5M8 7.6v6.2"/>'),
  tag: sv('<path d="M2.5 2.5h5.2l5.8 5.8-5.2 5.2-5.8-5.8z"/><circle cx="5.4" cy="5.4" r="0.9"/>'),
  person: sv('<circle cx="8" cy="5.4" r="2.6"/><path d="M3 13.5c.6-2.6 2.6-4 5-4s4.4 1.4 5 4"/>'),
  mega: sv('<path d="M2.5 6.4v3.2h2.2L10 12.6V3.4L4.7 6.4z"/><path d="M12.4 6.2c.7.5.7 3.1 0 3.6"/>'),
  percent: sv('<path d="m3.5 12.5 9-9"/><circle cx="4.6" cy="4.6" r="1.6"/><circle cx="11.4" cy="11.4" r="1.6"/>'),
  chart: sv('<path d="M2.5 13.5h11"/><path d="M4.5 11V8M8 11V4.5M11.5 11V6.5"/>'),
  globe: sv('<circle cx="8" cy="8" r="5.6"/><path d="M2.4 8h11.2M8 2.4c1.6 1.6 2.4 3.5 2.4 5.6S9.6 12 8 13.6C6.4 12 5.6 10.1 5.6 8S6.4 4 8 2.4z"/>'),
  gear: sv('<circle cx="8" cy="8" r="2.2"/><path d="M8 1.8v1.8M8 12.4v1.8M1.8 8h1.8M12.4 8h1.8M3.6 3.6l1.3 1.3M11.1 11.1l1.3 1.3M3.6 12.4l1.3-1.3M11.1 4.9l1.3-1.3"/>'),
  search: sv('<circle cx="7" cy="7" r="4.4"/><path d="m10.4 10.4 3.2 3.2"/>'),
  bell: sv('<path d="M4 11.2V7.4a4 4 0 0 1 8 0v3.8l1.2 1.3H2.8z"/><path d="M6.6 13.8a1.5 1.5 0 0 0 2.8 0"/>'),
  inbox: sv('<path d="M2.5 9.2 4.2 3.5h7.6l1.7 5.7v3.3h-11z"/><path d="M2.5 9.2h3.2l.9 1.6h2.8l.9-1.6h3.2"/>'),
  user2: sv('<circle cx="8" cy="6" r="2.4"/><path d="M3.5 13c.6-2 2.4-3.2 4.5-3.2s3.9 1.2 4.5 3.2"/>'),
  clock: sv('<circle cx="8" cy="8" r="5.6"/><path d="M8 4.8V8l2.2 1.4"/>'),
  check: sv('<circle cx="8" cy="8" r="5.6"/><path d="m5.6 8.1 1.7 1.7 3.2-3.4"/>'),
  trash: sv('<path d="M3 4.5h10M6.2 4.5V3h3.6v1.5M4.4 4.5l.6 9h6l.6-9"/>'),
  cal: sv('<rect x="2.5" y="3.2" width="11" height="10.3" rx="1.8"/><path d="M2.5 6.4h11M5.4 1.9v2.6M10.6 1.9v2.6"/>'),
  filter: sv('<path d="M2.5 4h11M4.5 8h7M6.5 12h3"/>'),
  bold: sv('<path d="M5 3h4a2.4 2.4 0 0 1 0 4.8H5zM5 7.8h4.6a2.6 2.6 0 0 1 0 5.2H5z"/>'),
  ital: sv('<path d="M9.8 3 6.2 13M6.4 3h5M4.8 13h5"/>'),
  link: sv('<path d="M6.8 9.2 9.2 6.8"/><path d="M7.6 4.4 8.8 3.2a2.6 2.6 0 0 1 3.7 3.7l-1.2 1.2M8.4 11.6l-1.2 1.2a2.6 2.6 0 0 1-3.7-3.7l1.2-1.2"/>'),
  image: sv('<rect x="2.2" y="3" width="11.6" height="10" rx="1.8"/><circle cx="5.8" cy="6.4" r="1.1"/><path d="m2.6 11.6 3.4-3 2.4 2 2-1.6 3 2.6"/>'),
  list: sv('<path d="M6 4.5h7.5M6 8h7.5M6 11.5h7.5"/><circle cx="3.2" cy="4.5" r="0.6"/><circle cx="3.2" cy="8" r="0.6"/><circle cx="3.2" cy="11.5" r="0.6"/>'),
  quote: sv('<path d="M3.5 11.5c0-3 .8-5 3-6.5M9 11.5c0-3 .8-5 3-6.5"/>'),
  reply: sv('<path d="M6.5 4 2.8 7.6l3.7 3.6"/><path d="M3 7.6h6.2c2.4 0 4.1 1.6 4.3 4.4"/>'),
  star: sv('<path d="m8 2.6 1.6 3.4 3.7.4-2.8 2.5.8 3.6L8 10.7l-3.3 1.8.8-3.6-2.8-2.5 3.7-.4z"/>'),
  lockS: sv('<rect x="3.5" y="7" width="9" height="6.5" rx="1.6"/><path d="M5.4 7V5.2a2.6 2.6 0 0 1 5.2 0V7"/>'),
};

// MARK: Charts — a smooth line through sample points (Catmull-Rom → cubic Bézier), in a 0…100 × 0…40 box
function curve(ys, w = 100, h = 40) {
  const pts = ys.map((y, i) => [i * w / (ys.length - 1), h - y * h]);
  let d = `M${pts[0][0].toFixed(2)} ${pts[0][1].toFixed(2)}`;
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6], c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += `C${c1[0].toFixed(2)} ${c1[1].toFixed(2)} ${c2[0].toFixed(2)} ${c2[1].toFixed(2)} ${p2[0].toFixed(2)} ${p2[1].toFixed(2)}`;
  }
  return d;
}
const area = (ys, w = 100, h = 40) => `${curve(ys, w, h)}L${w} ${h}L0 ${h}Z`;
const chart = (lines, { w = 100, h = 40, grid = 4, fill = 0 } = {}) =>
  `<svg class="ch" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">` +
  Array.from({ length: grid }, (_, i) => `<path class="ch-g" d="M0 ${(h / grid * i + 0.5).toFixed(2)}H${w}" vector-effect="non-scaling-stroke"/>`).join('') +
  (fill ? `<path class="ch-a" d="${area(lines[0], w, h)}"/>` : '') +
  lines.map((ys, i) => `<path class="ch-l ch-l${i}" d="${curve(ys, w, h)}" vector-effect="non-scaling-stroke"/>`).join('') + '</svg>';

// MARK: The sites (sample data, each in the language of its profile's country)

// Store — a shop's admin in German (light)
function store() {
  const nav = [['home', 'Übersicht', '', 1], ['box', 'Bestellungen', '12'], ['tag', 'Produkte'], ['person', 'Kunden'], ['mega', 'Marketing'], ['percent', 'Rabatte'], ['chart', 'Analysen']];
  const kpi = [['Umsatz', '2.410,80 €', '+12 %'], ['Bestellungen', '38', '+4'], ['Besucher', '1.204', '+9 %'], ['Konversionsrate', '3,1 %', '+0,4']];
  const orders = [['#1048', 'Lena Hoffmann', 'Bezahlt', '48,90 €'], ['#1047', 'Jonas Weber', 'Bezahlt', '112,00 €'], ['#1046', 'Mia Schulz', 'Offen', '29,90 €'], ['#1045', 'Felix Wagner', 'Bezahlt', '64,50 €'], ['#1044', 'Anna Becker', 'Versandt', '89,00 €'], ['#1043', 'Paul Richter', 'Versandt', '36,40 €'], ['#1042', 'Emma Koch', 'Bezahlt', '74,80 €'], ['#1041', 'Noah Klein', 'Versandt', '52,00 €']];
  const top = [['Hausmischung, 500 g', '14', '#C9B49A'], ['Äthiopien Guji, 250 g', '9', '#B7C2CF'], ['Espresso Nord, 1 kg', '6', '#3A3A3F'], ['Handmühle Classic', '3', '#D8D3CB']];
  const today = [0.08, 0.06, 0.05, 0.1, 0.22, 0.34, 0.3, 0.42, 0.56, 0.5, 0.62, 0.7, 0.66, 0.78];
  const prev = [0.06, 0.05, 0.08, 0.12, 0.18, 0.24, 0.3, 0.32, 0.38, 0.44, 0.42, 0.5, 0.54, 0.52];
  return `<div class="ms ms-store" lang="de">
    <aside class="st-side">
      <div class="st-shop"><span class="st-logo">R</span><b>Röstwerk</b>${IC.chev}</div>
      <nav>${nav.map(([i, t, n, on]) => `<span${on ? ' class="on"' : ''}>${IC[i]}${t}${n ? `<em>${n}</em>` : ''}</span>`).join('')}</nav>
      <div class="st-sec">Verkaufskanäle</div>
      <nav><span>${IC.globe}Onlineshop</span><span>${IC.box}Marktplatz</span></nav>
      <div class="st-set">${IC.gear}Einstellungen</div>
    </aside>
    <div class="st-main">
      <div class="st-top"><span class="st-search">${IC.search}Suchen<kbd>⌘ K</kbd></span><span class="st-bell">${IC.bell}</span><span class="st-me">LH</span></div>
      <div class="st-h"><b>Übersicht</b><span class="st-seg"><i class="on">Heute</i><i>7 Tage</i><i>30 Tage</i></span></div>
      <div class="st-kpi">${kpi.map(([t, v, d]) => `<div><span>${t}</span><b>${v}</b><em>${d}</em></div>`).join('')}</div>
      <div class="st-row">
        <div class="st-card st-chart"><div class="st-ct"><b>Umsatz im Zeitverlauf</b><span><i class="k0"></i>Heute<i class="k1"></i>Gestern</span></div>
          ${chart([today, prev], { fill: 1 })}
          <div class="st-axis"><span>00:00</span><span>06:00</span><span>12:00</span><span>18:00</span></div></div>
        <div class="st-card st-orders"><div class="st-ct"><b>Letzte Bestellungen</b><span>Alle ansehen</span></div>
          <ul>${orders.map(([n, who, st, v]) => `<li><b>${n}</b><span>${who}</span><i class="${st === 'Offen' ? 'wait' : st === 'Versandt' ? 'ship' : 'ok'}">${st}</i><em>${v}</em></li>`).join('')}</ul></div>
        <div class="st-card st-top5"><div class="st-ct"><b>Meistverkauft</b><span>Heute</span></div>
          <ul>${top.map(([t, q, c]) => `<li><i style="--c:${c}"></i><span>${t}</span><em>${q}</em></li>`).join('')}</ul></div>
      </div>
    </div>
  </div>`;
}

// Ads — an ads console in English (dark)
function ads() {
  const rows = [
    [1, 'Autumn sale — Search', 'Active', '$120.00/day', '48,210', '1,904', '3.95%', '$842.10'],
    [1, 'Brand — Display', 'Active', '$80.00/day', '96,544', '2,317', '2.40%', '$611.35'],
    [0, 'Retargeting — Q4', 'Paused', '$60.00/day', '22,190', '1,086', '4.89%', '$402.80'],
    [1, 'New arrivals — Video', 'Active', '$150.00/day', '41,082', '1,733', '4.22%', '$905.15'],
    [0, 'Holiday preview', 'Draft', '$90.00/day', '—', '—', '—', '—'],
  ];
  const clicks = [0.3, 0.36, 0.33, 0.42, 0.4, 0.5, 0.47, 0.55, 0.6, 0.56, 0.66, 0.7, 0.68, 0.78, 0.74, 0.82];
  const impr = [0.5, 0.52, 0.48, 0.55, 0.58, 0.54, 0.6, 0.62, 0.58, 0.64, 0.62, 0.66, 0.7, 0.66, 0.72, 0.7];
  return `<div class="ms ms-ads" lang="en-US">
    <header class="ad-top"><span class="ad-logo"><i></i>Reach <span>Ads</span></span>
      <nav><span>Overview</span><span class="on">Campaigns</span><span>Audiences</span><span>Creatives</span><span>Billing</span></nav>
      <span class="ad-acct">Lumen Labs${IC.chev}</span><span class="ad-me">AR</span></header>
    <div class="ad-h"><b>Campaigns</b><span class="ad-date">${IC.cal}Oct 1 – Oct 29, 2026</span><span class="ad-new">${IC.plus}New campaign</span></div>
    <div class="ad-metrics"><div class="on"><span>Clicks</span><b>7,040</b></div><div><span>Impressions</span><b>208K</b></div><div><span>Avg. CTR</span><b>3.38%</b></div><div><span>Cost</span><b>$2,761.40</b></div></div>
    <div class="ad-chart">${chart([clicks, impr], { grid: 4 })}</div>
    <div class="ad-table">
      <div class="ad-tr ad-th"><span></span><span>Campaign</span><span>Status</span><span>Budget</span><span>Impr.</span><span>Clicks</span><span>CTR</span><span>Cost</span></div>
      ${rows.map(([on, n, st, b, im, cl, ctr, co]) => `<div class="ad-tr"><span><i class="ad-sw${on ? ' on' : ''}"></i></span><span class="ad-n">${n}</span><span class="ad-st ${st.toLowerCase()}"><i></i>${st}</span><span>${b}</span><span>${im}</span><span>${cl}</span><span>${ctr}</span><span>${co}</span></div>`).join('')}
    </div>
  </div>`;
}

// Support — a help desk in British English (light)
function support() {
  const list = [
    ['Charlotte Hughes', 'Can I change my delivery address?', 'Hi, I ordered on Tuesday and I’ve just moved — is it too late to send it to…', '10:42', 1],
    ['Oliver Bennett', 'Parcel arrived damaged', 'The box was crushed on one side and the lid of the grinder is cracked…', '09:58'],
    ['Harry Clarke', 'Invoice for October', 'Could you send a VAT invoice for order 1031? Our accounts team needs…', '09:15'],
    ['Amelia Wright', 'Thank you!', 'Just wanted to say the beans were lovely — we’ll order again before…', 'Yesterday'],
    ['George Turner', 'Discount code not working', 'The code from your newsletter says it has expired, but the email…', 'Yesterday'],
    ['Isla Morgan', 'Wholesale enquiry', 'We run a small café in Bristol and would like to ask about…', 'Mon'],
  ];
  const folders = [['inbox', 'Inbox', '24', 1], ['user2', 'Assigned to me', '6'], ['clock', 'Waiting', '3'], ['check', 'Solved'], ['trash', 'Spam']];
  return `<div class="ms ms-desk" lang="en-GB">
    <aside class="dk-side"><div class="dk-brand"><i></i>Helpdesk</div>
      <nav>${folders.map(([i, t, n, on]) => `<span${on ? ' class="on"' : ''}>${IC[i]}${t}${n ? `<em>${n}</em>` : ''}</span>`).join('')}</nav>
      <div class="dk-sec">Views</div><nav><span>${IC.star}Priority</span><span>${IC.tag}Orders</span><span>${IC.tag}Wholesale</span></nav></aside>
    <div class="dk-list"><div class="dk-lh"><b>Inbox</b><span>${IC.filter}</span></div>
      ${list.map(([who, s, pre, t, on]) => `<div class="dk-item${on ? ' on' : ''}"><div><b>${who}</b><time>${t}</time></div><span>${s}</span><p>${pre}</p></div>`).join('')}</div>
    <div class="dk-read">
      <div class="dk-rh"><b>Can I change my delivery address?</b><span class="dk-tag">Open</span></div>
      <div class="dk-from"><span class="dk-av">CH</span><div><b>Charlotte Hughes</b><span>to support · 10:42</span></div></div>
      <div class="dk-body"><p>Hi there,</p><p>I ordered on Tuesday (order 1043) and I’ve just moved house. Is it too late to send it to my new address in Clifton? Happy to pay any difference in postage.</p><p>Many thanks,<br>Charlotte</p></div>
      <div class="dk-reply"><span>${IC.reply}Reply to Charlotte…</span><i>Send</i></div>
    </div>
  </div>`;
}

// QA — a checkout on a Japanese staging server (light)
function qa() {
  const fields = [['お名前', '山田 花子', 1], ['メールアドレス', 'hanako@example.jp', 1], ['郵便番号', '150-0001', 0.45], ['都道府県', '東京都', 0.45, 1], ['住所', '渋谷区神宮前 1-2-3', 1]];
  return `<div class="ms ms-shop" lang="ja">
    <div class="jp-stage">ステージング環境 · テスト用データ</div>
    <header class="jp-top"><b>ひかり書店</b><span class="jp-steps"><i class="done">カート</i>${IC.chev}<i class="on">お届け先</i>${IC.chev}<i>お支払い</i>${IC.chev}<i>確認</i></span><span class="jp-lock">${IC.lockS}</span></header>
    <div class="jp-main">
      <div class="jp-form"><b class="jp-ht">お届け先</b>
        ${fields.map(([l, v, w, sel]) => `<label style="--fw:${w}"><span>${l}</span><i>${v}${sel ? IC.chev : ''}</i></label>`).join('')}
        <span class="jp-check"><i></i>請求先も同じ住所にする</span>
      </div>
      <div class="jp-sum"><b class="jp-ht">ご注文内容</b>
        <div class="jp-item"><i style="--c:#C9D3E3"></i><div><b>夜行列車の旅</b><span>文庫 · 1点</span></div><em>¥1,980</em></div>
        <div class="jp-item"><i style="--c:#E6DCCB"></i><div><b>秋の読書ノート</b><span>単行本 · 1点</span></div><em>¥2,300</em></div>
        <div class="jp-tot"><span>小計</span><em>¥4,280</em></div><div class="jp-tot"><span>送料</span><em>無料</em></div>
        <div class="jp-tot jp-all"><span>合計</span><em>¥4,280</em></div>
        <span class="jp-go">お支払いへ進む</span>
      </div>
    </div>
  </div>`;
}

// Sales — a sales pipeline in Dutch (dark)
function sales() {
  const cols = [
    ['Nieuw', '€ 18.400', [['Van Dijk Bouw', '€ 4.800', 'SB'], ['Studio Noord', '€ 2.600', 'MV'], ['Fietsfabriek Utrecht', '€ 11.000', 'SB']]],
    ['Contact', '€ 9.750', [['Bakkerij De Molen', '€ 1.950', 'LK'], ['Kantoor Visser', '€ 7.800', 'MV']]],
    ['Offerte', '€ 23.200', [['Hotel Het Anker', '€ 15.400', 'LK'], ['Groene Tuinen', '€ 3.600', 'SB'], ['De Boekenkast', '€ 4.200', 'MV']]],
    ['Gewonnen', '€ 12.900', [['Café Zuid', '€ 2.900', 'LK'], ['Brouwerij Oost', '€ 10.000', 'SB']]],
  ];
  return `<div class="ms ms-crm" lang="nl">
    <header class="cr-top"><span class="cr-logo"><i></i>Pijplijn</span><span class="cr-search">${IC.search}Zoeken</span><span class="cr-me">SB</span></header>
    <div class="cr-h"><b>Verkoopkansen</b><span class="cr-seg"><i class="on">Bord</i><i>Lijst</i></span><span class="cr-new">${IC.plus}Nieuwe kans</span></div>
    <div class="cr-board">${cols.map(([t, sum, cards], ci) => `<div class="cr-col"><div class="cr-ch"><b>${t}</b><span>${sum}</span></div>
      ${cards.map(([n, v, who], k) => `<div class="cr-card${ci === 2 && k === 0 ? ' hot' : ''}"><b>${n}</b><span>${v}</span><div><i class="cr-dot" style="--c:${['#7FA0F0', '#8CC9A8', '#D9B57A', '#B9A6EA'][(ci + k) % 4]}"></i><em>${who}</em></div></div>`).join('')}</div>`).join('')}</div>
  </div>`;
}

// Blog — a blog editor in French (light)
function blog() {
  return `<div class="ms ms-blog" lang="fr">
    <header class="bl-top"><span class="bl-back">${IC.back}Articles</span><span class="bl-state">Brouillon enregistré</span><span class="bl-prev">Aperçu</span><span class="bl-pub">Publier</span></header>
    <div class="bl-tools">${['bold', 'ital', 'link', 'list', 'quote', 'image'].map((i) => IC[i]).join('')}</div>
    <div class="bl-main">
      <article class="bl-doc">
        <span class="bl-kick">Voyages</span>
        <h5>Les cafés de Lisbonne, un matin d’octobre</h5>
        <p>À huit heures, la ville sent encore la pluie. Dans la rue des Fanqueiros, un comptoir de zinc, trois tabourets et une machine qui siffle : on y boit la bica debout, en deux gorgées, avant de repartir vers le fleuve.</p>
        <p>Les habitués ne regardent pas la carte. Ils saluent, posent une pièce, et la tasse arrive déjà sucrée. Plus haut, à Graça, les terrasses s’ouvrent sur les toits orange et le bruit du tram.</p>
        <blockquote>« Ici, le café n’est pas une pause. C’est la ville qui s’arrête avec vous. »</blockquote>
        <p>Nous avons passé une semaine à goûter les cafés du quartier, de la torréfaction familiale au comptoir de gare…</p>
      </article>
      <aside class="bl-side"><b>Paramètres</b>
        <label><span>Catégorie</span><i>Voyages${IC.chev}</i></label>
        <label><span>Étiquettes</span><i class="bl-tags"><em>Lisbonne</em><em>Café</em></i></label>
        <label><span>Publication</span><i>Immédiatement${IC.chev}</i></label>
        <label><span>Auteur</span><i>Claire Martin</i></label>
      </aside>
    </div>
  </div>`;
}

// MARK: The windows: profile, site, Safari window size, look; their place in the room and in the deck.
// Order = the deck from the front (0) to the back. `row`/`col`: Mission Control on a wide screen.
const SITES = [
  { site: store, url: 'roestwerk.example', w: 960, h: 600, dark: 0, row: 1, col: 1, s: 0.44 },
  { site: ads, url: 'reach.example', w: 900, h: 580, dark: 1, row: 0, col: 0, s: 0.4 },
  { site: support, url: 'desk.example', w: 940, h: 580, dark: 0, row: 0, col: 1, s: 0.4 },
  { site: qa, url: 'hikari-shop.example', w: 820, h: 580, dark: 0, row: 0, col: 2, s: 0.4 },
  { site: sales, url: 'pijplijn.example', w: 880, h: 580, dark: 1, row: 1, col: 2, s: 0.4 },
  { site: blog, url: 'carnet.example', w: 780, h: 580, dark: 0, row: 1, col: 0, s: 0.4 },
];

// Mission Control: rows centred in the room (ROOM wide), windows centred on their row's middle line; the
// names of a row's windows sit on one line, under the row's lowest window. Everything in room pixels; the CSS
// and the script read the result from the windows' style.
const FEW = 4;
const ROOM = 1360, GAP = 52, LABEL = 44, ROWGAP = 26;
function layout() {
  const rows = [0, 1].map((r) => SITES.map((s, i) => ({ ...s, i })).filter((s) => s.row === r).sort((a, b) => a.col - b.col));
  const out = [];
  let y = 0;
  rows.forEach((row) => {
    const hs = row.map((s) => s.h * s.s), ws = row.map((s) => s.w * s.s);
    const rh = Math.max(...hs), total = ws.reduce((a, b) => a + b, 0) + GAP * (row.length - 1);
    let x = (ROOM - total) / 2;
    row.forEach((s, k) => {
      out[s.i] = { fx: x + ws[k] / 2, fy: y + rh / 2, fs: s.s, lx: x + ws[k] / 2, ly: y + rh + 16 };
      x += ws[k] + GAP;
    });
    y += rh + LABEL + ROWGAP;
  });
  return { places: out, height: Math.round(y - ROWGAP) };
}

// The Safari bar (macOS 26, compact: one tab), with the profile in it: flag and name.
function bar(p, url) {
  return `<div class="mi-bar">
        <span class="mi-lights"><i></i><i></i><i></i></span>
        <span class="mi-cap mi-side">${IC.sidebar}${IC.chev}</span>
        <span class="mi-cap mi-hist">${IC.back}${IC.fwd}</span>
        <span class="mi-cap mi-prof">${flag(p.code, 16)}<span>${esc(p.name)}</span></span>
        <span class="mi-cap mi-addr"><span class="mi-pg">${IC.page}</span><span class="mi-url">${esc(url)}</span></span>
        <span class="mi-cap mi-tools">${IC.share}${IC.plus}${IC.tabs}</span>
      </div>`;
}

export default function scene(c, { lang }) {
  const { places, height } = layout();
  const n = SITES.length;
  const wins = SITES.map((s, i) => {
    const p = c.profiles[i], q = places[i];
    // On a phone the deck goes top (the back) to bottom (the front): slot n-1 is the front window. A short
    // phone screen shows the first FEW windows only (.mi-few): --slot4 is their order then.
    const slot = n - 1 - i, slot4 = i < FEW ? FEW - 1 - i : -1;
    return `<div class="mi-win${s.dark ? ' dark' : ''}${i === 0 ? ' focus' : ''}${i >= FEW ? ' mi-extra' : ''}" data-i="${i}" style="--w:${s.w};--h:${s.h};--fx:${q.fx.toFixed(1)};--fy:${q.fy.toFixed(1)};--fs:${s.s};--slot:${slot};--slot4:${slot4};z-index:${n - i}">
      ${i === 0 ? '<i class="mi-ring" data-r="0.56 0.68"></i>' : ''}<div class="mi-frame">
      ${bar(p, s.url)}
      <div class="mi-page">${s.site()}</div>
      </div>
    </div>`;
  }).join('\n    ');
  const labels = SITES.map((s, i) => {
    const p = c.profiles[i], q = places[i];
    return `<span class="mi-label${i === 0 ? ' focus' : ''}" style="--lx:${q.lx.toFixed(1)};--ly:${q.ly.toFixed(1)}">${flag(p.code, 16)}${esc(p.name)}</span>`;
  }).join('');
  return `<section class="scene sc-mission" data-scene="mission" data-title="${esc(c.title)}" style="--len:240vh">
  <div class="scene-pin">
    <div class="mi">
      <div class="container mi-head">
        <h2 class="h-xl mi-h"><span class="mi-l1">${inline(c.head[0], lang)}</span> <span class="dim mi-l2" data-r="0.38 0.5">${inline(c.head[1], lang)}</span></h2>
        <p class="lead mi-lead" data-r="0.46 0.58">${inline(c.lead, lang)}</p>
      </div>
      <div class="mi-stage" aria-hidden="true" style="--sh:${height}">
        <div class="mi-room" data-sample>
    ${wins}
          <div class="mi-labels" data-r="0.5 0.62">${labels}</div>
        </div>
      </div>
      <p class="visually-hidden">${inline(c.label, lang)}</p>
    </div>
  </div>
</section>`;
}
