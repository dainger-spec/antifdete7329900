import { inline, esc } from '../../lib/html.mjs';
import { icon, mark, wordmark } from '../../lib/kit.mjs';

// The payment page: our own, not the processor's (q8). The server gets an address from the processor's API; the
// page shows it with a QR code, the amount, a timer and the status, and the person never leaves the site. The
// processor's name appears nowhere. Minimal on purpose: one narrow column — what you pay and for how long, then a
// single card with the transfer (coin, QR, amount, address, status and timer), then two short lines. The coin is
// picked from a list with a search field — there will be many coins and networks; picking one changes the amount,
// the network, the address and the QR code. Everything in the card is sample data (data-sample): the addresses are
// not real ones, and the QR code is a drawing for the mock-up (on the real page it is made from the address and the
// amount). The month / year switch is two radios and CSS.

/// A QR-like drawing for the mock-up: 25 × 25 modules with the three finder squares, the timing lines and modules
/// from a seeded generator — deterministic, so every build draws the same picture.
function qrDrawing(seed, size) {
  const N = 25, Q = 2, M = N + 2 * Q;
  let s = 0;
  for (const ch of seed) s = (s * 31 + ch.charCodeAt(0)) >>> 0;
  const rnd = () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
  const on = Array.from({ length: N }, () => Array(N).fill(false));
  const fixed = Array.from({ length: N }, () => Array(N).fill(false));
  const finder = (x0, y0) => { for (let y = -1; y <= 7; y++) for (let x = -1; x <= 7; x++) {
    const X = x0 + x, Y = y0 + y; if (X < 0 || Y < 0 || X >= N || Y >= N) continue;
    fixed[Y][X] = true;
    const d = Math.max(Math.abs(x - 3), Math.abs(y - 3));
    on[Y][X] = d !== 2 && d <= 3;
  } };
  finder(0, 0); finder(N - 7, 0); finder(0, N - 7);
  for (let i = 8; i < N - 8; i++) { on[6][i] = on[i][6] = i % 2 === 0; fixed[6][i] = fixed[i][6] = true; }
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (!fixed[y][x]) on[y][x] = rnd() < 0.48;
  let rects = '';
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (on[y][x]) rects += `<rect x="${x + Q}" y="${y + Q}" width="1" height="1"/>`;
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${M} ${M}" shape-rendering="crispEdges" aria-hidden="true"><rect width="${M}" height="${M}" fill="#fff"/><g fill="#0B0C0F">${rects}</g></svg>`;
}

export default function checkout(c, { lang }) {
  const [m, y] = c.periods, k0 = c.coins[0];
  const both = (a, b, cls = '') => `<span class="p-m${cls}">${a}</span><span class="p-y${cls}">${b}</span>`;
  const net = (n) => esc(c.network.replace('{net}', n));
  // (the network is named only where it isn't the coin's own: USDT on Tron, not «Bitcoin · Bitcoin»)
  const coinRow = (x) => `<span class="coin-t">${esc(x.t)}</span><span class="coin-n">${esc(x.n)}</span><span class="coin-net">${x.net.toLowerCase() === x.n.toLowerCase() ? '' : esc(x.net)}</span>`;
  const style = `<style>
    .pay { max-width: 440px; margin: 0 auto; padding: 32px 0 112px; text-align: center; }
    #pay-month:checked ~ .container .pay label[for="pay-month"], #pay-year:checked ~ .container .pay label[for="pay-year"] { background: rgba(255, 255, 255, 0.12); color: var(--text-primary); }
    #pay-month:focus-visible ~ .container .pay label[for="pay-month"], #pay-year:focus-visible ~ .container .pay label[for="pay-year"] { outline: 2px solid var(--accent); outline-offset: 1px; }
    .pay-back { display: inline-flex; align-items: center; gap: 6px; font: var(--t-small); color: var(--text-tertiary); }
    .pay-back:hover { color: var(--text-primary); text-decoration: none; }
    /* Lumen Pay: the mark, LUMEN and «Pay» — our own payment page, never the processor's name */
    .pay-brand { display: inline-flex; align-items: center; gap: 10px; margin-top: 36px; color: var(--text-primary); }
    .pay-brand .pay-wm svg { display: block; }
    .pay-brand .pay-pay { font: 600 23px/1 var(--font-display); letter-spacing: -0.01em; margin-left: -1px; }
    .pay-head { margin-top: 26px; display: grid; justify-items: center; gap: 6px; }
    .pay-plan { font: var(--t-small); color: var(--text-secondary); }
    .pay-sum { font: 600 56px/60px var(--font-display); letter-spacing: -0.025em; color: var(--text-primary); font-variant-numeric: tabular-nums; }
    .pay-head .seg { margin-top: 14px; }
    .pay-until { margin-top: 10px; font: 400 13px/18px var(--font); color: var(--text-tertiary); }
    .pay-card { margin-top: 36px; padding: 24px; display: grid; grid-template-columns: minmax(0, 1fr); justify-items: center; gap: 18px; background: var(--surface); border: 1px solid var(--hairline); border-radius: var(--r-card); }
    /* the coin: one line closed; open, a search field and a list that scrolls */
    .coin-wrap { width: 100%; }
    .coin { position: relative; width: 100%; text-align: left; }
    .coin-btn { width: 100%; display: flex; align-items: center; gap: 8px; height: 44px; padding: 0 12px 0 14px; border-radius: 10px; background: var(--control-fill); border: 1px solid var(--hairline); color: var(--text-primary); font: var(--t-ui); cursor: pointer; }
    .coin-btn:hover { border-color: var(--strong-border, rgba(255, 255, 255, 0.16)); }
    .coin-btn[aria-expanded="true"] { border-color: rgba(111, 143, 234, 0.55); }
    .coin-btn svg { flex: none; color: var(--text-tertiary); }
    .coin-t { font-weight: 600; color: var(--text-primary); }
    .coin-n { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text-tertiary); }
    .coin-net { margin-left: auto; flex: none; color: var(--text-secondary); font: 400 13px/18px var(--font); }
    .coin-pop { position: absolute; left: 0; right: 0; top: calc(100% + 6px); z-index: 30; padding: 6px; border-radius: 12px; background: #1E222A; border: 1px solid var(--hairline); box-shadow: 0 18px 50px rgba(0, 0, 0, 0.55); }
    .coin-pop[hidden] { display: none; }
    .coin-search { display: flex; align-items: center; gap: 8px; height: 38px; padding: 0 10px; margin-bottom: 4px; border-radius: 8px; background: var(--control-fill); color: var(--text-tertiary); }
    .coin-search input { flex: 1; min-width: 0; height: 100%; border: 0; outline: 0; background: transparent; color: var(--text-primary); font: var(--t-ui); }
    .coin-list { list-style: none; margin: 0; padding: 0; max-height: 264px; overflow-y: auto; }
    .coin-list li { display: flex; align-items: center; gap: 8px; height: 40px; padding: 0 10px; border-radius: 8px; font: var(--t-ui); cursor: pointer; outline: 0; }
    .coin-list li:hover, .coin-list li:focus { background: rgba(255, 255, 255, 0.07); }
    .coin-list li .ok { flex: none; width: 14px; color: var(--accent); visibility: hidden; }
    .coin-list li[aria-selected="true"] .ok { visibility: visible; }
    .coin-list li[hidden] { display: none; }
    .coin-empty { padding: 10px; font: var(--t-small); color: var(--text-tertiary); }
    .pay-qr { padding: 10px; border-radius: 14px; background: #fff; line-height: 0; }
    .pay-amount { font: 600 22px/28px var(--font-display); letter-spacing: -0.01em; color: var(--text-primary); }
    .pay-net { margin-top: -14px; font: 400 13px/18px var(--font); color: var(--text-tertiary); }
    .pay-addr { width: 100%; display: flex; align-items: center; gap: 4px; padding: 4px 4px 4px 14px; border-radius: 10px; background: var(--control-fill); border: 1px solid var(--hairline); text-align: left; }
    .pay-addr span { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font: 400 13px/20px var(--font-mono); color: var(--text-primary); }
    .pay-addr button { flex: none; display: grid; place-items: center; width: 34px; height: 34px; border: 0; border-radius: 8px; background: transparent; color: var(--text-secondary); cursor: pointer; }
    .pay-addr button:hover { background: rgba(255, 255, 255, 0.08); color: var(--text-primary); }
    .pay-status { width: 100%; display: flex; align-items: center; justify-content: space-between; gap: 12px; padding-top: 16px; border-top: 1px solid var(--hairline); font: var(--t-small); color: var(--text-secondary); white-space: nowrap; }
    .pay-status .dot { display: inline-block; width: 7px; height: 7px; margin-right: 8px; border-radius: 50%; background: var(--accent); vertical-align: 1px; }
    .pay-status .t { display: inline-flex; align-items: center; gap: 6px; color: var(--text-tertiary); }
    .pay-status .t b { font: 500 13px/20px var(--font-mono); color: var(--text-secondary); }
    .pay-status .gone, .pay.expired .pay-status .live { display: none; }
    .pay.expired .pay-status .gone { display: inline; }
    .pay-note { margin-top: 18px; font: 400 13px/20px var(--font); color: var(--text-tertiary); }
    /* month or year: two radios, no script */
    .pay .p-y, #pay-year:checked ~ .container .pay .p-m { display: none; }
    #pay-year:checked ~ .container .pay .p-y { display: inline; }
    @media (max-width: 599px) { .pay-status .lbl { display: none; } .pay-sum { font-size: 48px; line-height: 52px; } }
    @media (max-width: 389px) { .coin-btn .coin-n { display: none; } }
  </style>`;
  const coin = `<div class="tbd coin-wrap" data-q="q13" title="Решение владельца: вопрос 13"><div class="coin" data-sample>
      <button type="button" class="coin-btn" aria-haspopup="listbox" aria-expanded="false" aria-label="${esc(c.coinLabel)}">${coinRow(k0)}${icon('chevronUpDown', 14)}</button>
      <div class="coin-pop" hidden>
        <label class="coin-search">${icon('magnifyingglass', 14)}<input type="search" placeholder="${esc(c.coinSearch)}" aria-label="${esc(c.coinSearch)}" autocomplete="off"></label>
        <ul class="coin-list" role="listbox" aria-label="${esc(c.coinLabel)}">${c.coins.map((x, i) => `<li role="option" tabindex="-1" data-i="${i}" aria-selected="${i === 0}">${coinRow(x)}<span class="ok">${icon('check', 14)}</span></li>`).join('')}</ul>
        <p class="coin-empty" hidden>${inline(c.coinEmpty, lang)}</p>
      </div>
    </div></div>`;
  const body = `${style}
  <input type="radio" name="pay-period" id="pay-month" class="visually-hidden" checked>
  <input type="radio" name="pay-period" id="pay-year" class="visually-hidden">
  <div class="container"><div class="pay" data-pay>
    <a class="pay-back" href="account.html">${icon('arrowLeft', 13)}${inline(c.back, lang)}</a>
    <h1 class="visually-hidden">${inline(c.title, lang)}</h1>
    <div><span class="pay-brand" aria-label="Lumen Pay">${mark(30)}<span class="pay-wm">${wordmark(16, 'currentColor')}</span><span class="pay-pay">${esc(c.brand)}</span></span></div>
    <div class="pay-head">
      <p class="pay-plan">${inline(c.plan, lang)}</p>
      <div class="pay-sum">${both(inline(m[1], lang), inline(y[1], lang))}</div>
      <div class="seg" role="group" aria-label="${lang === 'ru' ? 'Период' : 'Period'}"><label for="pay-month">${inline(m[0], lang)}</label><label for="pay-year">${inline(y[0], lang)}</label></div>
      <p class="pay-until" data-sample>${both(inline(m[2], lang), inline(y[2], lang))}</p>
    </div>
    <section class="pay-card" aria-label="${esc(c.qr)}">
      ${coin}
      <div class="pay-qr" data-sample role="img" aria-label="${esc(c.qr)}" data-qr>${qrDrawing(k0.a, 168)}</div>
      <div class="pay-amount" data-sample>${both(`${esc(k0.m)} ${esc(k0.t)}`, `${esc(k0.y)} ${esc(k0.t)}`)}</div>
      <div class="pay-net" data-sample data-net>${net(k0.net)}</div>
      <div class="pay-addr" data-sample><span data-addr>${esc(k0.a)}</span><button type="button" data-copy="${esc(k0.a)}" aria-label="${esc(c.copy)}" title="${esc(c.copy)}">${icon('copy', 15)}</button></div>
      <div class="pay-status"><span><span class="live"><i class="dot"></i>${inline(c.status, lang)}</span><span class="gone">${inline(c.expired, lang)} <a href="checkout.html">${inline(c.newAddress, lang)}</a></span></span><span class="t live" data-sample>${icon('clock', 13)}<span class="lbl">${inline(c.timerLabel, lang)}</span> <b data-timer>${esc(c.timer)}</b></span></div>
    </section>
    <p class="pay-note">${inline(c.exact, lang)}<br>${inline(c.after, lang)}</p>
  </div></div>`;
  // The prototype's behaviour: the coin list (open, search, pick — the amount, network, address and QR follow), the
  // copy button, and the timer counting down (not in screenshots, ?shot=1, which stay as they are).
  const data = JSON.stringify(c.coins.map((x) => ({ t: x.t, m: x.m, y: x.y, a: x.a, net: c.network.replace('{net}', x.net) })));
  const script = `<script>(function () {
    var COINS = ${data};
    ${qrDrawing.toString()}
    var pay = document.querySelector('[data-pay]'), box = pay.querySelector('.coin'), btn = box.querySelector('.coin-btn'), pop = box.querySelector('.coin-pop');
    var q = pop.querySelector('input'), items = Array.prototype.slice.call(pop.querySelectorAll('li')), empty = pop.querySelector('.coin-empty');
    var copyBtn = pay.querySelector('[data-copy]');
    function open(on) { pop.hidden = !on; btn.setAttribute('aria-expanded', on ? 'true' : 'false'); if (on) { q.value = ''; filter(); q.focus(); } }
    function filter() { var s = q.value.trim().toLowerCase(), n = 0; items.forEach(function (li) { var hit = !s || li.textContent.toLowerCase().indexOf(s) >= 0; li.hidden = !hit; if (hit) n++; }); empty.hidden = n > 0; }
    function pick(li) {
      var x = COINS[+li.getAttribute('data-i')];
      items.forEach(function (o) { o.setAttribute('aria-selected', o === li ? 'true' : 'false'); });
      btn.innerHTML = li.innerHTML.replace(/<span class="ok">[\\s\\S]*$/, '') + btn.querySelector('svg:last-child').outerHTML;
      pay.querySelector('.pay-amount .p-m').textContent = x.m + ' ' + x.t;
      pay.querySelector('.pay-amount .p-y').textContent = x.y + ' ' + x.t;
      pay.querySelector('[data-net]').textContent = x.net;
      pay.querySelector('[data-addr]').textContent = x.a; copyBtn.setAttribute('data-copy', x.a);
      pay.querySelector('[data-qr]').innerHTML = qrDrawing(x.a, 168);
      open(false); btn.focus();
    }
    btn.addEventListener('click', function () { open(pop.hidden); });
    q.addEventListener('input', filter);
    items.forEach(function (li) { li.addEventListener('click', function () { pick(li); }); });
    pop.addEventListener('keydown', function (e) {
      var vis = items.filter(function (li) { return !li.hidden; }), i = vis.indexOf(document.activeElement);
      if (e.key === 'ArrowDown') { e.preventDefault(); (vis[i + 1] || vis[0]).focus(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); if (i <= 0) q.focus(); else vis[i - 1].focus(); }
      else if (e.key === 'Enter') { e.preventDefault(); if (i >= 0) pick(vis[i]); else if (vis.length) pick(vis[0]); }
      else if (e.key === 'Escape') { open(false); btn.focus(); }
    });
    document.addEventListener('click', function (e) { if (!box.contains(e.target)) open(false); });
    copyBtn.addEventListener('click', function () { if (navigator.clipboard) navigator.clipboard.writeText(copyBtn.getAttribute('data-copy')); });
    if (/[?&]shot=1/.test(location.search)) return;
    var el = pay.querySelector('[data-timer]'), left = 14 * 60 + 59;
    var t = setInterval(function () {
      left = Math.max(0, left - 1);
      el.textContent = String(Math.floor(left / 60)).padStart(2, '0') + ':' + String(left % 60).padStart(2, '0');
      if (!left) { clearInterval(t); pay.classList.add('expired'); }
    }, 1000);
  })();</script>`;
  return { body: body + script, bodyClass: 'page-checkout', hideFooter: true };
}
