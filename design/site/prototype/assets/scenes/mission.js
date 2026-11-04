// Home scene "mission" (tools/templates/pages/home/mission.mjs): one Safari window becomes many.
// Wide screens: the scene opens on one large window, "Store"; the other windows wait behind it, hidden. As
// the scene scrolls they come out from behind it — out of its shade, to full brightness — and every window
// goes to its place in Mission Control (--fx/--fy/--fs in its style, set by the template).
// Phones: the "Store" window opens tall, right under the headline's first line; it slides down and settles
// at its final height while the windows behind it fan out above it, like cards in Wallet: each window's bar
// shows above the next one. A short screen keeps four windows (.mi-few).
// It also fits the room to the page (--k on a wide screen; the card heights on a phone). Layout is read only
// in fit() (load, resize, fonts) — never on a scroll frame — and hooks run on scroll frames only: nothing
// moves while the page is still.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  const sec = document.querySelector('.sc-mission');
  if (!sec) return;
  const stage = sec.querySelector('.mi-stage');
  const pin = sec.querySelector('.scene-pin');
  const l1 = sec.querySelector('.mi-l1');
  const ROOM = 1360, BAR = 48, FEW = 4, CARD_MIN = 280, CARD_MAX = 420;
  const SH = parseFloat(stage.style.getPropertyValue('--sh')) || 610, CW = 1200;
  const wins = Array.from(sec.querySelectorAll('.mi-win')).map((el) => {
    const g = (k) => parseFloat(el.style.getPropertyValue(k));
    return {
      el, frame: el.querySelector('.mi-frame'), i: +el.dataset.i,
      w: g('--w'), h: g('--h'), fx: g('--fx'), fy: g('--fy'), fs: g('--fs'), slot6: g('--slot'), slot4: g('--slot4'),
    };
  });
  const n = wins.length;
  const { clamp01, easeInOut } = api;
  const wide = () => window.innerWidth >= 900;
  // k: the room's scale; s0/top0: the first window's scale and top when the scene opens (room px on a wide
  // screen, px from the stage's top on a phone); few/cardh/h0: the phone's deck.
  let k = 1, s0 = 1, top0 = 0, few = false, cardh = 360, h0 = 360, seen = '', last = -1, lastP = 0, mode = '';

  function fit() {
    const key = `${window.innerWidth}x${window.innerHeight}x${stage.clientHeight}`;
    if (key === seen) return;
    seen = key;
    mode = wide() ? 'wide' : 'phone';
    if (mode === 'wide') {
      sec.classList.remove('mi-few');
      sec.style.removeProperty('--cardh');
      sec.style.removeProperty('--h0');
      wins[0].frame.style.height = '';
      // the windows span about CW of the room's width: up to the page's gutters, and on a wide screen no more
      // than 40 px past the text column on each side
      let kk = Math.min(Math.min(sec.clientWidth - 64, 1280) / CW, 1.12);
      if (api.scenesOn && stage.clientHeight > 0) kk = Math.min(kk, stage.clientHeight / SH);
      k = Math.max(0.4, kk);
      sec.style.setProperty('--k', k.toFixed(4));
      if (!api.scenesOn) return;
      // The opening window: just under the first line, as large as the frame allows (on screen, up to a
      // little over its own size)
      const sr = stage.getBoundingClientRect(), lb = l1.getBoundingClientRect().bottom + 44;
      const roomTop = sr.top + sr.height / 2 - (SH * k) / 2;
      const room = (pin.getBoundingClientRect().bottom - 56 - lb) / k;
      const f = wins[0];
      s0 = Math.max(0.5, Math.min(1.2 / k, room / f.h, (sec.clientWidth - 96) / k / f.w));
      top0 = (lb - roomTop) / k;
    } else {
      sec.style.removeProperty('--k');
      if (!api.scenesOn) return;
      // The deck at the foot of the frame: the windows behind show their bars, the front one what is left
      // (four windows if six would leave it too little). The opening window: under the first line, as tall
      // as the frame allows, its top a little lower when there is room to spare.
      const A = stage.clientHeight;
      few = A - (n - 1) * BAR < CARD_MIN;
      sec.classList.toggle('mi-few', few);
      const nv = few ? FEW : n;
      cardh = Math.max(200, Math.min(CARD_MAX, A - (nv - 1) * BAR));
      const sr = stage.getBoundingClientRect(), lb = l1.getBoundingClientRect().bottom + 24;
      const free = pin.getBoundingClientRect().bottom - 20 - lb;
      // (no taller than the store's page: about 1080 px of it, scaled like the site in the card)
      const kp = parseFloat(getComputedStyle(sec).getPropertyValue('--kp')) || 0.42;
      h0 = Math.max(cardh, Math.min(BAR + 1080 * kp, free));
      top0 = lb + Math.min(40, Math.max(0, free - h0) * 0.3) - sr.top;
      sec.style.setProperty('--cardh', `${cardh.toFixed(1)}px`);
      sec.style.setProperty('--h0', `${h0.toFixed(1)}px`);
    }
  }
  fit();
  window.addEventListener('resize', () => { fit(); last = -1; if (api.scenesOn) draw(lastP); });
  // the headline's height (and so the room's) settles once the fonts are in
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { seen = ''; fit(); last = -1; if (api.scenesOn) draw(lastP); });
  if (!api.scenesOn) return;

  // When each window leaves the first one (wide screens; the front one moves with them, so the group opens
  // around it), and how long the spread takes.
  const DELAY = [0.03, 0, 0.02, 0.035, 0.012, 0.026];
  const START = 0.02, SPREAD = 0.5;

  api.onScene('mission', draw);
  function draw(p) {
    lastP = p;
    if (p === last) return;
    last = p;
    if (mode === 'wide') {
      const f = wins[0], cx = ROOM / 2, cy = top0 + (f.h * s0) / 2;
      for (const w of wins) {
        const e = easeInOut(clamp01((p - START - DELAY[w.i]) / SPREAD));
        // behind the first window: centred on it, small enough to hide behind it whatever its shape
        const d = w.i === 0 ? s0 : Math.min((f.w * s0) / w.w, (f.h * s0) / w.h) * 0.94;
        const x = cx + (w.fx - cx) * e, y = cy + (w.fy - cy) * e, s = d + (w.fs - d) * e;
        w.el.style.transform = `translate(${(x - w.w / 2).toFixed(2)}px, ${(y - w.h / 2).toFixed(2)}px) scale(${s.toFixed(4)})`;
        if (w.i) {
          w.el.style.opacity = clamp01(e / 0.08).toFixed(3);
          w.el.style.setProperty('--dim', ((1 - e) * 0.45).toFixed(3));
        }
      }
    } else {
      // Phone: one motion for the whole deck. The front window slides from under the headline's first line
      // down to the foot and shrinks to its final height; the others come out above it into their strips.
      const e = easeInOut(clamp01((p - START) / SPREAD));
      for (const w of wins) {
        const slot = few ? w.slot4 : w.slot6;
        if (slot < 0) continue;
        const y = top0 + (slot * BAR - top0) * e;
        w.el.style.transform = `translateY(${y.toFixed(2)}px)`;
        if (w.i === 0) {
          w.frame.style.height = `${(h0 + (cardh - h0) * e).toFixed(1)}px`;
        } else {
          w.el.style.opacity = clamp01(e / 0.06).toFixed(3);
          w.el.style.setProperty('--dim', ((1 - e) * 0.4).toFixed(3));
        }
      }
    }
  }
  draw(0);
});
