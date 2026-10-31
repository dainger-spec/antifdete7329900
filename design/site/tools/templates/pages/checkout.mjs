import { inline, esc } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';

// The payment page: our own, not the processor's (q8). The server gets an address from the processor's API; the
// page shows it with a QR code, the amount, a timer and the status, and the person never leaves the site. The
// processor's name appears nowhere. Minimal on purpose: one narrow column — what you pay and for how long, then a
// single card with the transfer (coin, QR, amount, address, status and timer), then two short lines. Everything in
// the card is sample data (data-sample): the address is not a real one, and the QR code is a drawing for the mock-up
// (on the real page it is made from the address and the amount). The month / year switch is two radios and CSS.

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
  const [m, y] = c.periods;
  const both = (a, b, cls = '') => `<span class="p-m${cls}">${a}</span><span class="p-y${cls}">${b}</span>`;
  const tbd = (q, html) => `<span class="tbd" data-q="${q}" title="Решение владельца: вопрос ${q.slice(1)}">${html}</span>`;
  const style = `<style>
    .pay { max-width: 440px; margin: 0 auto; padding: 32px 0 112px; text-align: center; }
    #pay-month:checked ~ .container .pay label[for="pay-month"], #pay-year:checked ~ .container .pay label[for="pay-year"] { background: rgba(255, 255, 255, 0.12); color: var(--text-primary); }
    #pay-month:focus-visible ~ .container .pay label[for="pay-month"], #pay-year:focus-visible ~ .container .pay label[for="pay-year"] { outline: 2px solid var(--accent); outline-offset: 1px; }
    .pay-back { display: inline-flex; align-items: center; gap: 6px; font: var(--t-small); color: var(--text-tertiary); }
    .pay-back:hover { color: var(--text-primary); text-decoration: none; }
    .pay-head { margin-top: 40px; display: grid; justify-items: center; gap: 6px; }
    .pay-plan { font: var(--t-small); color: var(--text-secondary); }
    .pay-sum { font: 600 56px/60px var(--font-display); letter-spacing: -0.025em; color: var(--text-primary); font-variant-numeric: tabular-nums; }
    .pay-head .seg { margin-top: 14px; }
    .pay-until { margin-top: 10px; font: 400 13px/18px var(--font); color: var(--text-tertiary); }
    .pay-card { margin-top: 36px; padding: 24px; display: grid; grid-template-columns: minmax(0, 1fr); justify-items: center; gap: 18px; background: var(--surface); border: 1px solid var(--hairline); border-radius: var(--r-card); }
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
  </style>`;
  const body = `${style}
  <input type="radio" name="pay-period" id="pay-month" class="visually-hidden" checked>
  <input type="radio" name="pay-period" id="pay-year" class="visually-hidden">
  <div class="container"><div class="pay" data-pay>
    <a class="pay-back" href="account.html">${icon('arrowLeft', 13)}${inline(c.back, lang)}</a>
    <h1 class="visually-hidden">${inline(c.title, lang)}</h1>
    <div class="pay-head">
      <p class="pay-plan">${inline(c.plan, lang)}</p>
      <div class="pay-sum">${both(inline(m[1], lang), inline(y[1], lang))}</div>
      <div class="seg" role="group" aria-label="${lang === 'ru' ? 'Период' : 'Period'}"><label for="pay-month">${inline(m[0], lang)}</label><label for="pay-year">${inline(y[0], lang)}</label></div>
      <p class="pay-until" data-sample>${both(inline(m[2], lang), inline(y[2], lang))}</p>
    </div>
    <section class="pay-card" aria-label="${esc(c.qr)}">
      ${tbd('q13', `<span class="seg">${c.coins.map((x, i) => `<a${i === 0 ? ' aria-current="true"' : ''}>${esc(x)}</a>`).join('')}</span>`)}
      <div class="pay-qr" data-sample role="img" aria-label="${esc(c.qr)}">${qrDrawing(c.address, 168)}</div>
      <div class="pay-amount" data-sample>${both(esc(m[3]), esc(y[3]))}</div>
      <div class="pay-net" data-sample>${inline(c.network, lang)}</div>
      <div class="pay-addr" data-sample><span>${esc(c.address)}</span><button type="button" data-copy="${esc(c.address)}" aria-label="${esc(c.copy)}" title="${esc(c.copy)}">${icon('copy', 15)}</button></div>
      <div class="pay-status"><span><span class="live"><i class="dot"></i>${inline(c.status, lang)}</span><span class="gone">${inline(c.expired, lang)} <a href="checkout.html">${inline(c.newAddress, lang)}</a></span></span><span class="t live" data-sample>${icon('clock', 13)}<span class="lbl">${inline(c.timerLabel, lang)}</span> <b data-timer>${esc(c.timer)}</b></span></div>
    </section>
    <p class="pay-note">${inline(c.exact, lang)}<br>${inline(c.after, lang)}</p>
  </div></div>`;
  // The timer counts down in the prototype (not in screenshots, ?shot=1, which stay as they are).
  const script = `<script>(function () {
    document.querySelectorAll('[data-copy]').forEach(function (b) { b.addEventListener('click', function () { if (navigator.clipboard) navigator.clipboard.writeText(b.getAttribute('data-copy')); }); });
    if (/[?&]shot=1/.test(location.search)) return;
    var el = document.querySelector('[data-timer]'), pay = document.querySelector('[data-pay]'); if (!el) return;
    var left = 14 * 60 + 59;
    var t = setInterval(function () {
      left = Math.max(0, left - 1);
      el.textContent = String(Math.floor(left / 60)).padStart(2, '0') + ':' + String(left % 60).padStart(2, '0');
      if (!left) { clearInterval(t); pay.classList.add('expired'); }
    }, 1000);
  })();</script>`;
  return { body: body + script, bodyClass: 'page-checkout', hideFooter: true };
}
