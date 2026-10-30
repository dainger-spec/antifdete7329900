// Home scene "mission" (tools/templates/pages/home/mission.mjs): one Safari window becomes many.
// Wide screens: at first a deck — the "Store" window in front, the others behind it, smaller and dimmer, only
// their bars peeking out above it; then the deck spreads into Mission Control, each window to its place
// (--fx/--fy/--fs in its style, set by the template), and the windows behind brighten as they arrive.
// Phones: the same deck, then it fans out vertically, like cards in Wallet: each window's bar shows above the
// next one, the front window whole at the foot.
// It also fits the room to the page (--k; the strip and card heights on a phone) — with or without scenes.
// Hooks run on scroll frames only: nothing moves while the page is still.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  const sec = document.querySelector('.sc-mission');
  if (!sec) return;
  const stage = sec.querySelector('.mi-stage');
  const ROOM = 1360;
  const SH = parseFloat(stage.style.getPropertyValue('--sh')) || 610;
  const wins = Array.from(sec.querySelectorAll('.mi-win')).map((el) => {
    const g = (k) => parseFloat(el.style.getPropertyValue(k));
    return { el, i: +el.dataset.i, w: g('--w'), h: g('--h'), fx: g('--fx'), fy: g('--fy'), fs: g('--fs'), slot: g('--slot') };
  });
  const n = wins.length;
  const l1 = sec.querySelector('.mi-l1');
  const { clamp01, easeInOut } = api;
  const wide = () => window.innerWidth >= 900;
  let k = 1, strip = 56, cardh = 300, top0 = 0, seen = '', last = -1, lastP = 0;
  const pin = sec.querySelector('.scene-pin');

  /// The room's scale on a wide screen (it fits the width and, while the scene plays, the height left under the
  /// headline); on a phone, while the scene plays, the bar strips share the height left (the front card may run
  /// off the foot of the screen). top0: where the deck starts — just under the headline's first line, in room
  /// pixels — so the opening frame has no empty band where the second line and the lead will come in.
  function fit() {
    const key = `${window.innerWidth}x${window.innerHeight}x${stage.clientHeight}`;
    if (key === seen) return;
    seen = key;
    if (wide()) {
      let kk = Math.min((sec.clientWidth - 72) / ROOM, 1.12);
      if (api.scenesOn && stage.clientHeight > 0) kk = Math.min(kk, stage.clientHeight / SH);
      k = Math.max(0.4, kk);
      sec.style.setProperty('--k', k.toFixed(4));
    } else {
      sec.style.removeProperty('--k');
      if (api.scenesOn) {
        const A = stage.clientHeight;
        strip = A - (n - 1) * 56 >= 220 ? 56 : Math.max(46, (A - 220) / (n - 1));
        cardh = Math.max(220, Math.min(380, A - (n - 1) * strip));
        sec.style.setProperty('--strip', `${strip.toFixed(1)}px`);
        sec.style.setProperty('--cardh', `${cardh.toFixed(1)}px`);
      }
    }
    if (api.scenesOn) {
      const sr = stage.getBoundingClientRect(), lb = l1.getBoundingClientRect().bottom;
      if (wide()) {
        top0 = (lb + 44 - (sr.top + sr.height / 2 - (SH * k) / 2)) / k;
      } else {
        // the closed deck stands in the middle of the space under the first line (not at its top)
        const free0 = lb + 28, free1 = pin.getBoundingClientRect().bottom - 16, deckH = cardh + (n - 1) * 9;
        top0 = Math.max(free0, (free0 + free1) / 2 - deckH / 2) - sr.top;
      }
    }
  }
  fit();
  window.addEventListener('resize', () => { fit(); last = -1; });
  // the headline's height (and so the room's) settles once the fonts are in
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { seen = ''; fit(); last = -1; if (api.scenesOn) draw(lastP); });
  if (!api.scenesOn) return;

  // Wide: the deck, in room pixels. The front window big; each window behind it a step narrower, its top a
  // step higher, a little dimmer — only their top edges show above the front one, like a stack of cards.
  const S0 = 0.92, STEP = 12;
  function deck(w) {
    const f = wins[0], frontTop = top0 + (n - 1) * STEP;
    if (w.i === 0) return { x: ROOM / 2, y: frontTop + (f.h * S0) / 2, s: S0, dim: 0 };
    const s = (f.w * S0 * (1 - 0.05 * w.i)) / w.w;
    return { x: ROOM / 2, y: frontTop - STEP * w.i + (w.h * s) / 2, s, dim: 0.16 + 0.09 * w.i };
  }
  // When each window leaves the deck (the front one last, so the deck opens around it)
  const DELAY = [0.06, 0, 0.02, 0.04, 0.015, 0.03];
  const SPREAD = 0.34, START = 0.08;

  // Layout is read only in fit() (load, resize, fonts), never on a scroll frame: here we only write transforms.
  api.onScene('mission', draw);
  function draw(p) {
    lastP = p;
    if (p === last) return;
    last = p;
    if (wide()) {
      for (const w of wins) {
        const e = easeInOut(clamp01((p - START - DELAY[w.i]) / SPREAD));
        const d = deck(w);
        const x = d.x + (w.fx - d.x) * e, y = d.y + (w.fy - d.y) * e, s = d.s + (w.fs - d.s) * e;
        const dimTo = w.i === 0 ? 0 : 0.16;
        w.el.style.transform = `translate(${(x - w.w / 2).toFixed(2)}px, ${(y - w.h / 2).toFixed(2)}px) scale(${s.toFixed(4)})`;
        w.el.style.setProperty('--dim', (d.dim + (dimTo - d.dim) * e).toFixed(3));
      }
    } else {
      // Phone: the deck starts under the headline's first line; each card behind is a step higher and
      // narrower. It fans out downwards into its strips while the second line and the lead come in above.
      const frontTop = top0 + (n - 1) * 9;
      for (const w of wins) {
        const back = n - 1 - w.slot;
        const e = easeInOut(clamp01((p - START - back * 0.02) / SPREAD));
        const y0 = frontTop - back * 9, s0 = 1 - back * 0.04, y1 = w.slot * strip;
        const y = y0 + (y1 - y0) * e, s = s0 + (1 - s0) * e;
        w.el.style.transform = `translateY(${y.toFixed(2)}px) scale(${s.toFixed(4)})`;
        const d0 = back ? 0.12 + 0.07 * back : 0, d1 = back * 0.05;
        w.el.style.setProperty('--dim', (d0 + (d1 - d0) * e).toFixed(3));
      }
    }
  }
});
