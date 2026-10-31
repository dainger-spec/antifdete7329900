// Home scene "warmup" (tools/templates/pages/home/warmup.mjs): the hidden window goes through the sites as the
// scene scrolls. For each site: the address changes (and the site's name on the glass with it) and Safari's
// blue line runs along the address field while the page loads; the new page replaces the old one when it
// paints, is read (it scrolls under the glass in a reader's spurts) and gives way to the next. The count of
// cookies climbs as pages load and are read; "Page n of 12" and its line follow. The camera pushes in all
// along (CSS, the stage's --t). The last part lifts the picture so the facts under it come into view (--lift,
// measured here). Everything is a function of the scroll; nothing moves by itself. Without scenes the HTML
// is the finished picture (dn.se, page 4 of 12, 84 cookies) and this script does nothing.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  'use strict';
  const sec = document.querySelector('.sc-warmup');
  if (!sec || !api.scenesOn) return;
  const { clamp01, smooth, easeOut, easeInOut } = api;
  const pin = sec.querySelector('.scene-pin');
  const wu = sec.querySelector('.wu');
  const a = sec.querySelector('.wu-a');
  const win = sec.querySelector('.wu-win');
  const view = sec.querySelector('.wu-view');
  const pages = Array.from(sec.querySelectorAll('.wu-pg'));
  const spill = Array.from(sec.querySelectorAll('.wu-spill i'));
  const hosts = Array.from(sec.querySelectorAll('.wu-host'));
  const names = Array.from(sec.querySelectorAll('.wu-site'));
  const load = sec.querySelector('.wu-load');
  const num = sec.querySelector('.wu-n');
  const read = [sec.querySelector('.wu-count'), sec.querySelector('.wu-prog')]; // the readout's two blocks
  const pn = sec.querySelector('.wu-pn');
  const fill = sec.querySelector('.wu-track i');
  const total = +win.dataset.total || 12;
  const cookies = pages.map((p) => +p.dataset.cookies || 0);
  const reads = pages.map((p) => +p.dataset.read || 0);
  const N = pages.length;

  // The timeline (scene progress): site k starts loading at CUT[k] and is read until the next one starts;
  // the last one is read until END, then a short hold and the lift (CSS: data-r "0.85 1"). The first page
  // is already loading when the scene arrives, so the window is never empty.
  const CUT = [0, 0.12, 0.33, 0.54];
  const END = 0.82;
  const LOAD = 0.035;    // the blue line's run
  const PAINT = 0.7;     // the new page replaces the old one when the line is this far along
  const SWAP = 0.012;    // … quickly, as Safari does: a swap, not a dissolve
  const FIRST = 0.6;     // how far the first page's line has run when the scene arrives
  const end = (k) => (k + 1 < N ? CUT[k + 1] : END);
  // how far the blue line of page k has run at p
  const line = (k, p) => (k === 0 ? FIRST + (1 - FIRST) * clamp01(p / (LOAD * (1 - FIRST))) : clamp01((p - CUT[k]) / LOAD));
  // when page k paints (the first one is there from the start)
  const paint = (k) => (k === 0 ? -1 : CUT[k] + LOAD * PAINT);

  // A reader scrolls in spurts: three moves a page, each followed by a pause to read.
  const SPURTS = 3;
  const reading = (x) => { const q = x * SPURTS, n = Math.min(SPURTS - 1, Math.floor(q)); return (n + easeInOut(clamp01((q - n) / 0.55))) / SPURTS; };

  let below = pages.map(() => 0); // how far each page reaches below the view (px)
  let vh = 0;
  let lastP = -1;
  let lift = 0, header = 64, readTop = [0, 0]; // for fading the readout if the lift takes it under the header

  function measure() {
    vh = view.clientHeight;
    below = pages.map((p) => Math.max(0, p.offsetHeight - vh));
    // Lift frame B into view, but never so far that the window's foot goes under the header.
    const narrow = window.innerWidth < 600;
    const padBottom = narrow ? 36 : 56;
    header = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--header-h')) || 64;
    const want = wu.offsetHeight + padBottom - pin.clientHeight;
    const foot = a.offsetHeight - (parseFloat(getComputedStyle(a).paddingBottom) || 0); // the window's foot in frame A
    const most = foot - header - 24;
    lift = Math.round(Math.max(0, Math.min(want, most)));
    sec.style.setProperty('--lift', `${lift}px`);
    // where the readout's blocks sit in the pinned frame once the camera has pushed in (layout only: the stage
    // at full size, before the lift)
    readTop = read.map((b) => { let y = 0; for (let el = b; el && el !== pin; el = el.offsetParent) y += el.offsetTop; return y; });
  }

  function frame(p) {
    if (p === lastP) return;
    lastP = p;
    let k = 0;
    for (let i = 0; i < N; i++) if (p >= CUT[i]) k = i;

    // Pages: each replaces the last when it paints (rising the last few pixels into place), is read, and
    // stays under the next one until that one has painted.
    for (let i = 0; i < N; i++) {
      const pg = pages[i];
      const t0 = paint(i);
      const inn = i === 0 ? 1 : smooth((p - t0) / SWAP);
      const covered = i + 1 < N && p >= paint(i + 1) + SWAP;
      const op = covered ? 0 : inn;
      const span = end(i) - CUT[i] - LOAD;
      const r = reading(clamp01((p - Math.max(0, CUT[i] + LOAD)) / span));
      const y = -Math.min(reads[i] * below[i], vh * 1.2) * r + (1 - inn) * 10;
      pg.style.opacity = op.toFixed(3);
      pg.style.visibility = op > 0 ? 'visible' : 'hidden'; // a page out of sight keeps no layer
      pg.style.transform = `translate3d(0, ${y.toFixed(1)}px, 0)`;
      pg.classList.remove('on');
      if (spill[i]) { spill[i].style.opacity = (0.12 * op).toFixed(3); spill[i].classList.remove('on'); }
    }

    // The address and the site's name on the glass: the next host rolls in from below as the old one rolls
    // away, the moment the next page is asked for.
    for (let i = 0; i < N; i++) {
      const inn = i === 0 ? 1 : smooth((p - CUT[i]) / 0.012);
      const out = i + 1 < N ? smooth((p - CUT[i + 1]) / 0.012) : 0;
      const op = inn * (1 - out);
      const dy = (1 - inn) - out;
      hosts[i].style.opacity = op.toFixed(3);
      hosts[i].style.transform = `translate3d(0, ${(dy * 9).toFixed(1)}px, 0)`;
      hosts[i].classList.remove('on');
      names[i].style.opacity = op.toFixed(3);
      names[i].style.transform = `translate3d(0, ${(dy * 16).toFixed(1)}px, 0)`;
      names[i].classList.remove('on');
    }

    // Safari's loading line for the page that is loading now; it fades when the page is in.
    const l = line(k, p);
    load.style.setProperty('--l', easeOut(l).toFixed(3));
    load.style.setProperty('--lo', (1 - smooth((p - CUT[k] - LOAD) / 0.012)).toFixed(3));

    // Cookies: most arrive as a page loads, the rest while it is read.
    const from = k ? cookies[k - 1] : 0;
    const t = clamp01((p - CUT[k] - (k ? LOAD * 0.5 : 0)) / ((end(k) - CUT[k]) * 0.75));
    num.textContent = String(Math.round(from + (cookies[k] - from) * easeOut(t)));

    // Page n of 12: the line grows with each page's load
    pn.textContent = String(k + 1);
    fill.style.setProperty('--f', ((k + easeOut(l)) / total).toFixed(4));

    // If the lift would take a block of the readout up under the header (small screens), it fades out on its
    // way rather than being cut; where it still fits below the header, it stays.
    const gone = (1 - smooth(clamp01((p - 0.85) / 0.15) * 1.7)).toFixed(3);
    read.forEach((b, i) => { b.style.opacity = readTop[i] - lift >= header + 8 ? '1' : gone; });
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
