import { inline, esc } from '../../lib/html.mjs';
import { icon, glyph } from '../../lib/kit.mjs';

// The payment page: our own, not the processor's (q8). The server gets an address from the processor's API; the
// page shows it with a QR code, the amount, a timer and the status, and the person never leaves the site. The
// processor's name appears nowhere. The structure of an ordinary checkout: a bar on top with the way back and the
// Lumen Pay mark; then «Order» (the plan, month or year, the total and how long it runs) and «Transfer» (the coin,
// the QR code, the amount and the address — each with a copy button — the network, the one rule that matters, the
// status and the timer). Side by side on a computer, the order first on a phone. The coin is picked from a list with
// a search field — there will be many coins and networks; picking one changes the amount, the network, the address
// and the QR code. Everything in the transfer is sample data (data-sample): the addresses are not real ones, and the
// QR code is a drawing for the mock-up (on the real page it is made from the address and the amount). The month /
// year switch is two radios and CSS.

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
  // (the network is named only where it isn't the coin's own: USDT on Tron, not «Bitcoin · Bitcoin»)
  const coinRow = (x) => `<span class="coin-t">${esc(x.t)}</span><span class="coin-n">${esc(x.n)}</span><span class="coin-net">${x.net.toLowerCase() === x.n.toLowerCase() ? '' : esc(x.net)}</span>`;
  // a round copy button: site.js copies its data-copy and marks it .copied for a moment (a tick)
  const copyBtn = (value, label, attr) => `<button type="button" class="pay-copy" data-copy="${esc(value)}" ${attr} aria-label="${esc(label)}" title="${esc(label)}"><span class="idle">${icon('copy', 15)}</span><span class="done">${icon('check', 15)}</span></button>`;
  const amount = (v) => `<b>${esc(v)} <span data-ticker>${esc(k0.t)}</span></b>`;
  // the rule for the transfer, in the server's words (docs/SITE_API.md §5) with this invoice's amount, coin and network
  const [ex0, exRest] = c.exact.split('{amount}');
  const [ex1, exRest2] = exRest.split('{ticker}');
  const [ex2, ex3] = exRest2.split('{network}');
  const exactText = `${inline(ex0, lang)}<span data-sample>${both(esc(k0.m), esc(k0.y))}</span>${inline(ex1, lang)}<span data-ex-t>${esc(k0.t)}</span>${inline(ex2, lang)}<span data-ex-net>${esc(k0.net)}</span>${inline(ex3, lang)}`;
  const style = `<style>
    .pay { max-width: 940px; margin: 0 auto; padding: 16px 0 112px; }
    /* the bar on top: the way back on the left, the mark in the middle (an iOS navigation bar) */
    .pay-top { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; min-height: 48px; }
    .pay-back { justify-self: start; display: inline-flex; align-items: center; gap: 6px; height: 36px; margin-left: -10px; padding: 0 14px 0 10px; border-radius: var(--r-pill); font: var(--t-ui); color: var(--text-secondary); }
    .pay-back:hover { color: var(--text-primary); background: var(--lgc-tint); text-decoration: none; }
    /* Lumen Pay: the round mark alone (no tile behind it) and «Pay» — our own payment page, never the processor's name */
    .pay-brand { display: inline-flex; align-items: center; gap: 2px; color: var(--text-primary); }
    .pay-brand svg { display: block; flex: none; }
    .pay-brand .pay-pay { font: 600 24px/1 var(--font-display); letter-spacing: -0.015em; }
    /* the order and the transfer: side by side on a computer, one after the other on a phone */
    .pay-grid { margin-top: 24px; display: grid; grid-template-columns: minmax(0, 340px) minmax(0, 1fr); gap: 24px; align-items: start; }
    .pay-col:first-child { position: sticky; top: calc(var(--header-stack) + 20px); }
    .pay-h { margin: 0 8px 10px; font: 600 13px/18px var(--font); letter-spacing: 0.01em; color: var(--text-tertiary); }
    .pay-order, .pay-card { padding: 22px; border-radius: 28px; }
    .pay-card { --rim: var(--lg-rim-strong); }
    .pay-name { font: 600 19px/26px var(--font-display); letter-spacing: -0.01em; color: var(--text-primary); }
    .pay-order .seg { margin-top: 14px; }
    #pay-month:checked ~ .container .pay label[for="pay-month"], #pay-year:checked ~ .container .pay label[for="pay-year"] { background: linear-gradient(180deg, rgba(255, 255, 255, 0.17), rgba(255, 255, 255, 0.10)); box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.18), 0 2px 8px rgba(0, 0, 0, 0.35); color: var(--text-primary); }
    #pay-month:focus-visible ~ .container .pay label[for="pay-month"], #pay-year:focus-visible ~ .container .pay label[for="pay-year"] { outline: 2px solid var(--accent); outline-offset: 1px; }
    .pay-line { background: linear-gradient(90deg, rgba(255, 255, 255, 0), rgba(255, 255, 255, 0.12) 20%, rgba(255, 255, 255, 0.12) 80%, rgba(255, 255, 255, 0)) top / 100% 1px no-repeat; }
    .pay-total { margin-top: 20px; padding-top: 16px; display: flex; align-items: baseline; justify-content: space-between; gap: 12px; }
    .pay-total .k { font: var(--t-small); color: var(--text-secondary); }
    .pay-sum { font: 600 34px/40px var(--font-display); letter-spacing: -0.02em; color: var(--text-primary); font-variant-numeric: tabular-nums; }
    .pay-until { margin-top: 4px; font: var(--t-caption); color: var(--text-tertiary); }
    /* the coin: one line closed; open, a search field and a list that scrolls */
    .pay-label { margin: 0 4px 8px; font: var(--t-caption); color: var(--text-tertiary); }
    .coin-wrap { width: 100%; }
    .coin { position: relative; width: 100%; text-align: left; }
    .coin-btn { width: 100%; display: flex; align-items: center; gap: 8px; height: 48px; padding: 0 16px 0 18px; border-radius: var(--r-pill); color: var(--text-primary); font: var(--t-ui); cursor: pointer; }
    .coin-btn[aria-expanded="true"] { box-shadow: var(--lgc-edge), 0 0 0 1.5px rgba(111, 143, 234, 0.6); }
    .coin-btn svg { flex: none; color: var(--text-tertiary); }
    .coin-t { font-weight: 600; color: var(--text-primary); }
    .coin-n { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text-tertiary); }
    .coin-btn .coin-n { color: var(--text-secondary); }
    .coin-net { margin-left: auto; flex: none; color: var(--text-secondary); font: 400 13px/18px var(--font); }
    /* the list is opaque: it opens over the white QR code, and names in it must read whatever is under it */
    .coin-pop { position: absolute; left: 0; right: 0; top: calc(100% + 8px); z-index: 30; padding: 6px; border-radius: 24px; background: #181A20; -webkit-backdrop-filter: none; backdrop-filter: none; }
    .coin-pop[hidden] { display: none; }
    .coin-search { display: flex; align-items: center; gap: 8px; height: 40px; padding: 0 14px; margin-bottom: 4px; border-radius: var(--r-pill); background: rgba(255, 255, 255, 0.06); box-shadow: var(--lgs); color: var(--text-tertiary); }
    .coin-search input { flex: 1; min-width: 0; height: 100%; border: 0; outline: 0; background: transparent; color: var(--text-primary); font: var(--t-ui); }
    .coin-list { list-style: none; margin: 0; padding: 0; max-height: 264px; overflow-y: auto; }
    .coin-list li { display: flex; align-items: center; gap: 8px; height: 42px; padding: 0 14px; border-radius: 14px; font: var(--t-ui); cursor: pointer; outline: 0; }
    .coin-list li:hover, .coin-list li:focus { background: rgba(255, 255, 255, 0.07); }
    .coin-list li .ok { flex: none; width: 14px; color: var(--accent); visibility: hidden; }
    .coin-list li[aria-selected="true"] .ok { visibility: visible; }
    .coin-list li[hidden] { display: none; }
    .coin-empty { padding: 10px; font: var(--t-small); color: var(--text-tertiary); }
    /* the QR code on white in a frame of glass, and beside it (under it on a phone) what to send and where */
    .pay-main { margin-top: 20px; display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 26px; align-items: center; }
    .pay-qr { margin: 8px; padding: 12px; border-radius: 22px; background: #fff; line-height: 0; box-shadow: 0 0 0 7px rgba(255, 255, 255, 0.055), 0 0 0 8px rgba(255, 255, 255, 0.11), 0 24px 50px -24px rgba(0, 0, 0, 0.9); }
    .pay-rows { margin: 0; }
    .pay-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; min-height: 50px; }
    .pay-row + .pay-row { border-top: 1px solid var(--divider); }
    .pay-row dt { font: var(--t-small); color: var(--text-tertiary); }
    .pay-row dd { margin: 0; min-width: 0; font: 500 15px/22px var(--font); color: var(--text-primary); text-align: right; }
    .pay-amount b { font: 600 18px/24px var(--font-display); letter-spacing: -0.005em; font-variant-numeric: tabular-nums; }
    .pay-amount .p-m, #pay-year:checked ~ .container .pay .pay-amount .p-y { display: inline-flex; align-items: center; gap: 10px; }
    .pay-addr { border-top: 1px solid var(--divider); padding-top: 10px; }
    .pay-addr-k { display: flex; align-items: center; justify-content: space-between; gap: 12px; font: var(--t-small); color: var(--text-tertiary); }
    .pay-a { margin-top: 6px; padding: 10px 14px; border-radius: 14px; background: rgba(255, 255, 255, 0.045); box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.06); font: 400 13px/20px var(--font-mono); color: var(--text-primary); overflow-wrap: anywhere; word-break: break-all; text-wrap: balance; }
    .pay-copy { flex: none; position: relative; display: grid; place-items: center; width: 34px; height: 34px; border: 0; border-radius: 50%; background: var(--lgc-tint); box-shadow: var(--lgs); color: var(--text-secondary); cursor: pointer; }
    .pay-copy:hover { background: var(--lgc-hover); color: var(--text-primary); }
    .pay-copy .done, .pay-copy.copied .idle { display: none; }
    .pay-copy.copied .done { display: grid; color: #8FDDB6; }
    .pay-copy .idle { display: grid; }
    /* the one rule that matters, then the status and the timer */
    .pay-exact { margin-top: 18px; display: grid; grid-template-columns: 16px minmax(0, 1fr); gap: 10px; padding: 12px 14px; border-radius: 16px; background: linear-gradient(180deg, rgba(111, 143, 234, 0.14), rgba(111, 143, 234, 0.07)); box-shadow: inset 0 1px 0 rgba(200, 214, 255, 0.12); font: var(--t-small); color: var(--text-secondary); }
    .pay-exact svg { margin-top: 3px; color: var(--accent); }
    /* the server: «show this line prominently, not in small print» — body size, and the exchange's fee in bold */
    .pay-exact { font: var(--t-body); color: var(--text-primary); }
    .pay-exact svg { margin-top: 5px; }
    .pay-exact strong { font-weight: 600; color: #FFFFFF; }
    .pay-status { margin-top: 18px; padding-top: 16px; display: flex; align-items: center; justify-content: space-between; gap: 12px; font: var(--t-small); color: var(--text-secondary); white-space: nowrap; }
    .pay-status .dot { display: inline-block; width: 7px; height: 7px; margin-right: 8px; border-radius: 50%; background: var(--accent); vertical-align: 1px; }
    .pay-status .t { display: inline-flex; align-items: center; gap: 6px; color: var(--text-tertiary); }
    .pay-status .t b { font: 500 13px/20px var(--font-mono); color: var(--text-secondary); }
    .pay-status .gone, .pay.expired .pay-status .live { display: none; }
    .pay.expired .pay-status .gone { display: inline; }
    .pay-after { margin-top: 6px; font: var(--t-caption); color: var(--text-tertiary); }
    /* month or year: two radios, no script */
    .pay .p-y, #pay-year:checked ~ .container .pay .p-m { display: none; }
    #pay-year:checked ~ .container .pay .p-y { display: inline; }
    @media (max-width: 899px) {
      .pay { max-width: 520px; }
      .pay-grid { grid-template-columns: minmax(0, 1fr); gap: 22px; margin-top: 16px; }
      .pay-col:first-child { position: static; }
    }
    @media (max-width: 599px) {
      .pay-order, .pay-card { padding: 18px; border-radius: 26px; }
      .pay-main { grid-template-columns: minmax(0, 1fr); justify-items: center; gap: 14px; }
      .pay-info { justify-self: stretch; min-width: 0; }
      .pay-status .lbl { display: none; }
      .pay-sum { font-size: 30px; line-height: 36px; }
    }
    @media (max-width: 389px) { .coin-btn .coin-n { display: none; } }
  </style>`;
  const coin = `<div class="tbd coin-wrap" data-q="q13" title="Решение владельца: вопрос 13"><div class="coin" data-sample>
      <button type="button" class="coin-btn lg-c" aria-haspopup="listbox" aria-expanded="false" aria-labelledby="pay-coin-label">${coinRow(k0)}${icon('chevronUpDown', 14)}</button>
      <div class="coin-pop lg-f" hidden>
        ${c.coins.length > 6 ? `<label class="coin-search">${icon('magnifyingglass', 14)}<input type="search" placeholder="${esc(c.coinSearch)}" aria-label="${esc(c.coinSearch)}" autocomplete="off"></label>` : ''}
        <ul class="coin-list" role="listbox" aria-label="${esc(c.coinLabel)}">${c.coins.map((x, i) => `<li role="option" tabindex="-1" data-i="${i}" aria-selected="${i === 0}">${coinRow(x)}<span class="ok">${icon('check', 14)}</span></li>`).join('')}</ul>
        <p class="coin-empty" hidden>${inline(c.coinEmpty, lang)}</p>
      </div>
    </div></div>`;
  const body = `${style}
  <input type="radio" name="pay-period" id="pay-month" class="visually-hidden" checked>
  <input type="radio" name="pay-period" id="pay-year" class="visually-hidden">
  <div class="container"><div class="pay" data-pay>
    <div class="pay-top">
      <a class="pay-back" href="account.html">${icon('arrowLeft', 14)}${inline(c.back, lang)}</a>
      <span class="pay-brand" role="img" aria-label="Lumen Pay">${glyph(34)}<span class="pay-pay" aria-hidden="true">${esc(c.brand)}</span></span>
    </div>
    <h1 class="visually-hidden">${inline(c.title, lang)}</h1>
    <div class="pay-grid">
      <section class="pay-col" aria-labelledby="pay-order-h">
        <h2 class="pay-h" id="pay-order-h">${inline(c.order, lang)}</h2>
        <div class="pay-order lg">
          <p class="pay-name">${inline(c.plan, lang)}</p>
          <div class="seg full" role="group" aria-label="${esc(c.period)}"><label for="pay-month">${inline(m[0], lang)}</label><label for="pay-year">${inline(y[0], lang)}</label></div>
          <div class="pay-total pay-line"><span class="k">${inline(c.total, lang)}</span><span class="pay-sum">${both(inline(m[1], lang), inline(y[1], lang))}</span></div>
          <p class="pay-until" data-sample>${both(inline(m[2], lang), inline(y[2], lang))}</p>
        </div>
      </section>
      <section class="pay-col" aria-labelledby="pay-transfer-h">
        <h2 class="pay-h" id="pay-transfer-h">${inline(c.transfer, lang)}</h2>
        <div class="pay-card lg">
          <p class="pay-label" id="pay-coin-label">${inline(c.coinLabel, lang)}</p>
          ${coin}
          <div class="pay-main">
            <div class="pay-qr" data-sample role="img" aria-label="${esc(c.qr)}" data-qr>${qrDrawing(k0.a, 168)}</div>
            <div class="pay-info">
              <dl class="pay-rows">
                <div class="pay-row"><dt>${inline(c.amount, lang)}</dt><dd class="pay-amount" data-sample>${both(amount(k0.m) + copyBtn(k0.m, c.copyAmount, 'data-amount="m"'), amount(k0.y) + copyBtn(k0.y, c.copyAmount, 'data-amount="y"'))}</dd></div>
                <div class="pay-row"><dt>${inline(c.networkLabel, lang)}</dt><dd data-sample data-net>${esc(k0.net)}</dd></div>
              </dl>
              <div class="pay-addr">
                <div class="pay-addr-k"><span>${inline(c.address, lang)}</span>${copyBtn(k0.a, c.copy, 'data-addr-copy')}</div>
                <p class="pay-a" data-sample data-addr>${esc(k0.a)}</p>
              </div>
            </div>
          </div>
          <p class="pay-exact">${icon('infoCircle', 15)}<span>${exactText}</span></p>
          <div class="pay-status pay-line"><span><span class="live"><i class="dot"></i>${inline(c.status, lang)}</span><span class="gone">${inline(c.expired, lang)} <a href="checkout.html">${inline(c.newAddress, lang)}</a></span></span><span class="t live" data-sample>${icon('clock', 13)}<span class="lbl">${inline(c.timerLabel, lang)}</span> <b data-timer>${esc(c.timer)}</b></span></div>
          <p class="pay-after">${inline(c.after, lang)}</p>
        </div>
      </section>
    </div>
  </div></div>`;
  // The prototype's behaviour: the coin list (open, search, pick — the amount, network, address and QR follow) and
  // the timer counting down (not in screenshots, ?shot=1, which stay as they are). Copying is site.js's [data-copy].
  const data = JSON.stringify(c.coins.map((x) => ({ t: x.t, m: x.m, y: x.y, a: x.a, net: x.net })));
  const script = `<script>(function () {
    var COINS = ${data};
    ${qrDrawing.toString()}
    var pay = document.querySelector('[data-pay]'), box = pay.querySelector('.coin'), btn = box.querySelector('.coin-btn'), pop = box.querySelector('.coin-pop');
    var q = pop.querySelector('input'), items = Array.prototype.slice.call(pop.querySelectorAll('li')), empty = pop.querySelector('.coin-empty');
    function open(on) { pop.hidden = !on; btn.setAttribute('aria-expanded', on ? 'true' : 'false'); if (on) { if (q) { q.value = ''; filter(); q.focus(); } else { (pop.querySelector('[aria-selected="true"]') || items[0]).focus(); } } }
    function filter() { if (!q) return; var s = q.value.trim().toLowerCase(), n = 0; items.forEach(function (li) { var hit = !s || li.textContent.toLowerCase().indexOf(s) >= 0; li.hidden = !hit; if (hit) n++; }); empty.hidden = n > 0; }
    function pick(li) {
      var x = COINS[+li.getAttribute('data-i')];
      items.forEach(function (o) { o.setAttribute('aria-selected', o === li ? 'true' : 'false'); });
      btn.innerHTML = li.innerHTML.replace(/<span class="ok">[\\s\\S]*$/, '') + btn.querySelector('svg:last-child').outerHTML;
      ['m', 'y'].forEach(function (k) {
        var b = pay.querySelector('[data-amount="' + k + '"]'), amt = b.previousElementSibling;
        amt.firstChild.textContent = x[k] + ' '; amt.querySelector('[data-ticker]').textContent = x.t; b.setAttribute('data-copy', x[k]);
      });
      pay.querySelector('[data-net]').textContent = x.net;
      pay.querySelector('.pay-exact .p-m').textContent = x.m; pay.querySelector('.pay-exact .p-y').textContent = x.y;
      pay.querySelector('[data-ex-t]').textContent = x.t; pay.querySelector('[data-ex-net]').textContent = x.net;
      pay.querySelector('[data-addr]').textContent = x.a; pay.querySelector('[data-addr-copy]').setAttribute('data-copy', x.a);
      pay.querySelector('[data-qr]').innerHTML = qrDrawing(x.a, 168);
      open(false); btn.focus();
    }
    btn.addEventListener('click', function () { open(pop.hidden); });
    if (q) q.addEventListener('input', filter);
    items.forEach(function (li) { li.addEventListener('click', function () { pick(li); }); });
    pop.addEventListener('keydown', function (e) {
      var vis = items.filter(function (li) { return !li.hidden; }), i = vis.indexOf(document.activeElement);
      if (e.key === 'ArrowDown') { e.preventDefault(); (vis[i + 1] || vis[0]).focus(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); if (i > 0) vis[i - 1].focus(); else if (q) q.focus(); }
      else if (e.key === 'Enter') { e.preventDefault(); if (i >= 0) pick(vis[i]); else if (vis.length) pick(vis[0]); }
      else if (e.key === 'Escape') { open(false); btn.focus(); }
    });
    document.addEventListener('click', function (e) { if (!box.contains(e.target)) open(false); });
    if (/[?&]shot=1/.test(location.search)) return;
    var el = pay.querySelector('[data-timer]'), left = 29 * 60 + 59;
    var t = setInterval(function () {
      left = Math.max(0, left - 1);
      el.textContent = String(Math.floor(left / 60)).padStart(2, '0') + ':' + String(left % 60).padStart(2, '0');
      if (!left) { clearInterval(t); pay.classList.add('expired'); }
    }, 1000);
  })();</script>`;
  return { body: body + script, bodyClass: 'page-checkout', hideFooter: true };
}
