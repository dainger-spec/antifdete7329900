import { inline, esc } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';

// The payment page: our own, not the processor's (q8). The server gets an address from the processor's API; the
// page shows it with a QR code, the amount, a timer and the status, and the person never leaves the site. The
// processor's name appears nowhere. Everything in the payment panel is sample data (data-sample): the address is
// not a real one, and the QR code is a drawing for the mock-up (on the real page the code is made from the address).

/// A QR-like drawing for the mock-up: 25 × 25 modules with the three finder squares, the timing lines and modules
/// from a seeded generator — deterministic, so every build draws the same picture.
function qrDrawing(seed, size = 196) {
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
  return `<svg class="qr" width="${size}" height="${size}" viewBox="0 0 ${M} ${M}" shape-rendering="crispEdges" role="img"><rect width="${M}" height="${M}" fill="#fff"/><g fill="#0B0C0F">${rects}</g></svg>`;
}

export default function checkout(c, { lang }) {
  const o = c.order, p = c.pay;
  const kv = (rows) => `<dl class="kv">${rows.map(([k, v]) => `<dt>${inline(k, lang)}</dt><dd>${inline(v, lang)}</dd>`).join('')}</dl>`;
  const order = `<section class="panel"><div class="panel-head"><div><h2>${inline(o.title, lang)}</h2><p>${inline(o.plan, lang)}</p></div></div>
    <div class="panel-body pad" style="display:grid;gap:16px">
      <div class="seg" role="group" aria-label="${lang === 'ru' ? 'Период' : 'Period'}">${o.periods.map(([t, v, note], i) => `<a${i === 0 ? ' aria-current="true"' : ''}>${inline(t, lang)} · ${inline(v, lang)}${note ? ` <span class="caption">${inline(note, lang)}</span>` : ''}</a>`).join('')}</div>
      <div data-sample>${kv(o.rows)}</div>
    </div>
    <div class="panel-foot"><span style="display:flex;gap:8px;align-items:flex-start">${icon('envelope', 14)}<span>${inline(o.note, lang)}</span></span></div></section>`;
  const steps = p.steps.map((t, i) => `<li class="row" style="gap:10px;align-items:center;${i === 0 ? 'color:var(--text-primary)' : 'color:var(--text-tertiary)'}">${i === 0 ? icon('hourglass', 15) : icon(i === 1 ? 'syncArrows' : 'check', 15)}<span>${inline(t, lang)}</span></li>`).join('');
  const pay = `<section class="panel"><div class="panel-head"><div><h2>${inline(p.title, lang)}</h2><p>${inline(p.coinsNote, lang)}</p></div></div>
    <div class="panel-body pad" style="display:grid;gap:20px">
      <div class="row" style="gap:12px;flex-wrap:wrap"><span class="caption">${inline(p.coinLabel, lang)}</span><div class="seg" role="group">${p.coins.map((x, i) => `<a${i === 0 ? ' aria-current="true"' : ''}>${esc(x)}</a>`).join('')}</div></div>
      <div class="pay-grid" data-sample>
        <figure class="pay-qr">${qrDrawing(p.address)}<figcaption class="caption">${inline(p.qr, lang)}</figcaption></figure>
        <div style="display:grid;gap:14px;min-width:0">
          ${kv(p.rows)}
          <div><div class="caption" style="margin-bottom:6px">${inline(p.addressLabel, lang)}</div>
            <div class="row" style="gap:8px;align-items:center;min-width:0"><code class="mono pay-addr">${esc(p.address)}</code><button class="btn secondary sm" type="button" data-copy="${esc(p.address)}">${icon('copy', 14)}${inline(p.copy, lang)}</button></div></div>
          <div class="row" style="gap:8px;align-items:center">${icon('clock', 15)}<span>${inline(p.timerLabel, lang)}</span> <strong class="mono" data-timer>${esc(p.timer)}</strong></div>
        </div>
      </div>
      <div class="note">${icon('exclamationTriangle', 18)}<div><p>${inline(p.exact, lang)}</p></div></div>
      <div><div class="caption" style="margin-bottom:10px">${inline(p.statusTitle, lang)}</div><ol class="pay-steps" style="list-style:none;margin:0;padding:0;display:grid;gap:10px">${steps}</ol></div>
    </div>
    <div class="panel-foot"><span>${inline(p.stay, lang)}</span></div></section>
    <p class="caption" style="margin-top:14px;display:flex;gap:10px;align-items:center;justify-content:space-between;flex-wrap:wrap"><span>${inline(p.expired, lang)}</span><a class="btn ghost sm" href="checkout.html">${icon('refresh', 14)}${inline(p.newAddress, lang)}</a></p>`;
  // The timer counts down in the prototype (not in screenshots, ?shot=1, which stay as they are).
  const script = `<script>(function () {
    if (/[?&]shot=1/.test(location.search)) return;
    var el = document.querySelector('[data-timer]'); if (!el) return;
    var left = 14 * 60 + 59;
    setInterval(function () { left = Math.max(0, left - 1); el.textContent = String(Math.floor(left / 60)).padStart(2, '0') + ':' + String(left % 60).padStart(2, '0'); }, 1000);
    document.querySelectorAll('[data-copy]').forEach(function (b) { b.addEventListener('click', function () { if (navigator.clipboard) navigator.clipboard.writeText(b.getAttribute('data-copy')); }); });
  })();</script>`;
  const style = `<style>
    .checkout { display: grid; grid-template-columns: minmax(0, 430px) minmax(0, 1fr); gap: 24px; align-items: start; padding: 40px 0 96px; }
    .checkout .seg { max-width: 100%; flex-wrap: wrap; }
    .pay-grid { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 24px; align-items: start; }
    .pay-qr { margin: 0; display: grid; gap: 8px; justify-items: center; }
    .pay-qr .qr { border-radius: 10px; display: block; }
    .pay-addr { display: block; min-width: 0; overflow-wrap: anywhere; padding: 8px 10px; border-radius: 8px; background: var(--card); box-shadow: inset 0 0 0 1px var(--hairline); color: var(--text-primary); font-size: 13px; line-height: 18px; }
    @media (max-width: 899px) { .checkout { grid-template-columns: minmax(0, 1fr); } }
    @media (max-width: 599px) { .pay-grid { grid-template-columns: minmax(0, 1fr); justify-items: center; } .pay-grid > div { width: 100%; } }
  </style>`;
  const body = `${style}<div class="container"><p style="padding-top:28px"><a class="link-arrow" href="account.html">${icon('arrowLeft', 14)} ${inline(c.back, lang)}</a></p>
    <h1 class="h1" style="margin-top:12px">${inline(c.title, lang)}</h1>
    <div class="checkout">${order}<div>${pay}</div></div></div>${script}`;
  return { body, bodyClass: 'page-checkout', hideFooter: true };
}
