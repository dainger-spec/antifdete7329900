// Home scene "warmup" (tools/templates/pages/home/warmup.mjs): the hidden window goes through the sites as the
// scene scrolls. For each site: the address changes and Safari's blue line runs along the address field
// while the page loads; the frosted page comes in, is read (it scrolls under the glass) and gives way to
// the next. The count of cookies climbs as pages load and are read; "Page n of 12" and its line follow.
// The last part lifts the picture so the facts under it come into view (--lift, measured here).
// Everything is a function of the scroll; nothing moves by itself. Without scenes the HTML is the finished
// picture (dn.se, page 4 of 12, 84 cookies) and this script does nothing.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  'use strict';
  const sec = document.querySelector('.sc-warmup');
  if (!sec || !api.scenesOn) return;
  const { clamp01, smooth, easeOut, easeInOut } = api;
  const pin = sec.querySelector('.scene-pin');
  const wu = sec.querySelector('.wu');
  const win = sec.querySelector('.wu-win');
  const view = sec.querySelector('.wu-view');
  const pages = Array.from(sec.querySelectorAll('.wu-pg'));
  const spill = Array.from(sec.querySelectorAll('.wu-spill i'));
  const hosts = Array.from(sec.querySelectorAll('.wu-host'));
  const load = sec.querySelector('.wu-load');
  const num = sec.querySelector('.wu-n');
  const pn = sec.querySelector('.wu-pn');
  const fill = sec.querySelector('.wu-track i');
  const total = +win.dataset.total || 12;
  const cookies = pages.map((p) => +p.dataset.cookies || 0);
  const reads = pages.map((p) => +p.dataset.read || 0);
  const N = pages.length;

  // The timeline (scene progress): site k starts loading at CUT[k] and is read until the next one starts;
  // the last one is read until END, then the lift.
  const CUT = [0.04, 0.2, 0.41, 0.62];
  const END = 0.84;
  const LOAD = 0.04;     // the blue line's run
  const FADE = 0.03;     // the new page coming in under the glass
  const end = (k) => (k + 1 < N ? CUT[k + 1] : END);

  // A reader scrolls in spurts: three moves a page, each followed by a pause to read.
  const SPURTS = 3;
  const reading = (x) => { const q = x * SPURTS, n = Math.min(SPURTS - 1, Math.floor(q)); return (n + easeInOut(clamp01((q - n) / 0.55))) / SPURTS; };

  let below = pages.map(() => 0); // how far each page reaches below the view (px)
  let vh = 0;
  let lastP = -1;

  function measure() {
    vh = view.clientHeight;
    below = pages.map((p) => Math.max(0, p.offsetHeight - vh));
    const padBottom = window.innerWidth < 600 ? 36 : 56;
    const lift = Math.max(0, wu.offsetHeight + padBottom - pin.clientHeight);
    sec.style.setProperty('--lift', `${Math.round(lift)}px`);
  }

  function frame(p) {
    if (p === lastP) return;
    lastP = p;
    let k = -1;
    for (let i = 0; i < N; i++) if (p >= CUT[i]) k = i;

    // Pages: each comes in over the last (fades up from a little below), then is read, then stays under the
    // next one until that one is in.
    for (let i = 0; i < N; i++) {
      const pg = pages[i];
      const a = smooth((p - CUT[i] - LOAD * 0.45) / FADE);
      const covered = i + 1 < N && p >= CUT[i + 1] + LOAD * 0.45 + FADE;
      const op = covered ? 0 : a;
      const y = -Math.min(reads[i] * below[i], vh * 1.2) * reading(clamp01((p - CUT[i] - LOAD) / (end(i) - CUT[i] - LOAD))) + (1 - a) * 18;
      pg.style.opacity = op.toFixed(3);
      pg.style.visibility = op > 0 ? 'visible' : 'hidden'; // a page out of sight keeps no layer
      pg.style.transform = `translate3d(0, ${y.toFixed(1)}px, 0)`;
      pg.classList.remove('on');
      if (spill[i]) { spill[i].style.opacity = (0.14 * op).toFixed(3); spill[i].classList.remove('on'); }
    }

    // The address: the next host rolls in from below as the old one rolls away (Safari changes it at once).
    for (let i = 0; i < N; i++) {
      const inn = i === 0 ? 1 : smooth((p - CUT[i]) / 0.012);
      const out = i + 1 < N ? smooth((p - CUT[i + 1]) / 0.012) : 0;
      const op = inn * (1 - out);
      hosts[i].style.opacity = op.toFixed(3);
      hosts[i].style.transform = `translate3d(0, ${((1 - inn) * 9 - out * 9).toFixed(1)}px, 0)`;
      hosts[i].classList.remove('on');
    }

    // Safari's loading line for the page that is loading now
    if (k >= 0) {
      const l = clamp01((p - CUT[k]) / LOAD);
      load.style.setProperty('--l', easeOut(l).toFixed(3));
      load.style.setProperty('--lo', (1 - smooth((p - CUT[k] - LOAD) / 0.012)).toFixed(3));
    } else {
      load.style.setProperty('--lo', '0');
    }

    // Cookies: most arrive as a page loads, the rest while it is read.
    let c = 0;
    if (k >= 0) {
      const from = k ? cookies[k - 1] : 0;
      const t = clamp01((p - CUT[k] - LOAD * 0.5) / ((end(k) - CUT[k]) * 0.75));
      c = from + (cookies[k] - from) * easeOut(t);
    }
    num.textContent = String(Math.round(c));

    // Page n of 12: the line grows with each page's load
    const n = Math.max(1, k + 1);
    pn.textContent = String(n);
    const f = k < 0 ? 0 : (k + easeOut(clamp01((p - CUT[k]) / LOAD))) / total;
    fill.style.setProperty('--f', f.toFixed(4));
  }

  // Re-measure when the pictures arrive, the fonts settle or the window changes, and redraw where we are.
  let cur = null;
  const again = () => { measure(); lastP = -1; if (cur !== null) frame(cur); };
  measure();
  pages.forEach((p) => { const img = p.querySelector('img'); if (img && !img.complete) img.addEventListener('load', again, { once: true }); });
  let rt = 0;
  window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(again, 100); });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(again);
  api.onScene('warmup', (p) => { cur = p; frame(p); });
});
