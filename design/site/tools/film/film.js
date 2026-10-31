// The promo film v2 («Графит»): the stage's clock. Every frame is a pure function of the film's time: FILM.seek(t)
// shows the one shot that owns t and sets it to t (which window, where the camera is, which builds have cut in);
// FILM.plan(f) says how frame f is filmed (its shutter subframes, its capture layers) and what post.py puts under
// and over it (the plate and its frame, the 2D push, black, the glass reflection, the reeded glass, the depth
// of field plane, grain). Nothing depends on the frame before, so any frame can be filmed on its own.
//
// Per spec v2: type never animates (builds are hard cut-ins on their beat); cuts are hard; the only kinetic
// type is the S07 clock; motion blur only from shutter subframes, which never cross a cut or a build.
//
// Look at it in a browser: ?t=12.3 opens at that moment; ← → step a frame, with Shift a second.
(function () {
  'use strict';
  const TL = window.FILM_TIMELINE, PL = window.FILM_PLATES || {}, FPS = TL.fps, DUR = TL.duration, SH = TL.shot;
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => Array.from(el.querySelectorAll(s));
  const clamp01 = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x);
  const lerp = (a, b, u) => a + (b - a) * u;
  const span = (t, a, b) => clamp01((t - a) / (b - a));
  const sine = (x) => 0.5 - 0.5 * Math.cos(Math.PI * clamp01(x));
  const smooth = (x) => { x = clamp01(x); return x * x * (3 - 2 * x); };
  const outQuint = (x) => 1 - Math.pow(1 - clamp01(x), 5);
  const outCubic = (x) => 1 - Math.pow(1 - clamp01(x), 3);
  /// CSS cubic-bezier(x1, y1, x2, y2) as a function of x in 0…1.
  function bezier(x1, y1, x2, y2) {
    const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx, cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
    const X = (s) => ((ax * s + bx) * s + cx) * s, Y = (s) => ((ay * s + by) * s + cy) * s, dX = (s) => (3 * ax * s + 2 * bx) * s + cx;
    return (x) => {
      x = clamp01(x);
      let s = x;
      for (let i = 0; i < 8; i++) { const e = X(s) - x, d = dX(s); if (Math.abs(e) < 1e-7 || !d) break; s -= e / d; }
      let lo = 0, hi = 1;
      for (let i = 0; i < 30 && Math.abs(X(s) - x) > 1e-7; i++) { s = (lo + hi) / 2; if (X(s) < x) lo = s; else hi = s; }
      return Y(s);
    };
  }
  const ROLL = bezier(0.2, 0, 0, 1), CLOSE = bezier(0.65, 0, 0.25, 1);

  // MARK: Shots
  const SHOTS = TL.shots.map((s) => ({ ...s }));
  const byId = Object.fromEntries(SHOTS.map((s) => [s.id, s]));
  const shotAt = (t) => SHOTS.find((s) => t >= s.from - 1e-9 && t < s.to - 1e-9) || SHOTS[SHOTS.length - 1];
  const SEC = { S12: 'S11' };   // S12 is the S11 window under another camera
  const secOf = (id) => $(`[data-shot="${SEC[id] || id}"]`);
  const camOf = (id) => $('.cam', secOf(id));
  function cam(id, s = 1, ox = 960, oy = 540, x = 0, y = 0) {
    const tx = x + ox - ox * s, ty = y + oy - oy * s;
    camOf(id).style.transform = s === 1 && !x && !y ? '' : `translate(${tx.toFixed(3)}px, ${ty.toFixed(3)}px) scale(${s.toFixed(6)})`;
  }
  function cutins(id, t) { for (const e of $$('[data-on]', secOf(id))) e.classList.toggle('in', t >= +e.dataset.on - 1e-9); }
  let shown = null;
  function show(id) {
    const sec = SEC[id] || id;
    if (shown === sec) return;
    $$('.shot').forEach((el) => el.classList.toggle('on', el.dataset.shot === sec));
    shown = sec;
  }
  /// Every moment inside a shot where something swaps at once: subframes never straddle one.
  const EDGES = {
    S03: [SH.S03.line2], S04: SH.S04.cuts, S06: [SH.S06.line2], S07: SH.S07.changes, S08: [SH.S08.seam], S10: [...SH.S10.columns, SH.S10.footer],
    S11: [SH.S11.click, SH.S11.click + SH.S11.press / FPS, SH.S12.progress[0][0]], S13: [SH.S13.switch], S14: [SH.S14.line2, SH.S14.foot],
    S15: SH.S15.flips, S16: [SH.S16.spec], S17: [...SH.S17.pages, ...SH.S17.pages.map((p) => p + SH.S17.cookieLag)], S20: [SH.S20.lines],
  };
  function segment(shot, t) {
    let a = shot.from, b = shot.to;
    for (const e of EDGES[shot.id] || []) { if (e <= t + 1e-9 && e > a) a = e; if (e > t + 1e-9 && e < b) b = e; }
    return [a, b];
  }

  // MARK: Measured once, with every part laid out: baselines, hanging punctuation, where the chips and buttons are
  const M = {};
  function measure() {
    const root = document.documentElement;
    root.classList.add('measure');
    $$('.shot').forEach((el) => el.classList.add('on'));
    $$('.cut, .swap, .mpg').forEach((el) => el.classList.add('cur', 'on'));
    // hanging punctuation: a negative right margin equal to the mark's own advance
    for (const h of $$('.hang')) h.style.marginRight = `${(-h.getBoundingClientRect().width).toFixed(3)}px`;
    // every line by its baseline
    for (const el of $$('.tx[data-base]')) {
      el.style.top = '0px';
      const off = $('.bl', el).getBoundingClientRect().top - el.getBoundingClientRect().top;
      el.style.top = `${(+el.dataset.base - off).toFixed(3)}px`;
    }
    // S04: each window's chip centre in its own (unscaled) coordinates
    M.chips = $$('[data-shot="S04"] .cut').map((cut) => {
      const w = $('.mi-win', cut); w.style.transform = 'none';
      const r = w.getBoundingClientRect(), c = $('.mi-prof', w).getBoundingClientRect();
      return [c.left + c.width / 2 - r.left, c.top + c.height / 2 - r.top];
    });
    // S11/S12: «Weiter», the chip, the address field, in the window's own coordinates
    const kw = $('.kwin'); const K = 1.35;
    const kr = kw.getBoundingClientRect();
    const local = (el) => { const r = el.getBoundingClientRect(); return { x: (r.left - kr.left) / K, y: (r.top - kr.top) / K, w: r.width / K, h: r.height / K, cx: (r.left + r.width / 2 - kr.left) / K, cy: (r.top + r.height / 2 - kr.top) / K }; };
    M.kwin = { left: parseFloat(getComputedStyle(kw).left), top: parseFloat(getComputedStyle(kw).top), k: K };
    M.weiter = local($('.kwin .pxs-btn'));
    M.chip = local($('.kwin .pxw-prof'));
    M.addr = local($('.kwin .pxw-addr'));
    M.rl = local($('.kwin .pxw-rl'));
    M.head = local($('.kwin .pxs-h'));
    $$('.cut, .swap, .mpg').forEach((el) => el.classList.remove('cur', 'on'));
    $$('.shot').forEach((el) => el.classList.remove('on'));
    $$('[data-shot="S04"] .mi-win').forEach((w) => { w.style.transform = ''; });
    root.classList.remove('measure');
    shown = null;
  }

  // MARK: The display on the rendered Mac: corners per frame from the plate's sidecar (video/.cache/plates/<ID>.json,
  // plate px), or — until the renderer has made it — a stand-in path, so the stage can be filmed and judged.
  const DESK = [1920, 1247];
  const START = [[0, -83.5], [1920, -83.5], [1920, 1163.5], [0, 1163.5]];
  const STAND_IN = {
    R2: [[934, 304], [1430, 318], [1416, 650], [925, 615]],      // a rough 3/4 front-left end pose
    'PL-W': [[452, 92], [1488, 150], [1472, 760], [470, 712]],  // a rough low, close front-right camera
  };
  function plateGeom(id, fi) {
    const P = PL[id];
    if (P && P.frames && P.frames.length) {
      const k = 1920 / P.w;
      const i = Math.max(0, Math.min(P.frames.length - 1, fi));
      const a = P.frames[Math.floor(i)], b = P.frames[Math.min(P.frames.length - 1, Math.floor(i) + 1)], u = i - Math.floor(i);
      const mix = (p, q) => (p && q ? p.map((pt, j) => [lerp(pt[0], q[j][0], u) * k, lerp(pt[1], q[j][1], u) * k]) : p ? p.map((pt) => [pt[0] * k, pt[1] * k]) : null);
      if (a.display) return { quad: mix(a.display, b.display), notch: a.notch ? mix(a.notch, b.notch && b.notch.length === a.notch.length ? b.notch : a.notch) : null, radius: lerp(a.radius || 0, b.radius || 0, u) * k, real: true };
    }
    return null;
  }
  /// The stand-in notch: 13% of the display's width, 3.3% of its height, in the page's own coordinates.
  const NOTCH = [[836, 0], [1084, 0], [1084, 41], [836, 41]];
  function displayAt(id, t) {
    if (id === 'R2') {
      const fi = t * FPS - (PL.R2 ? PL.R2.filmFrom : 420);
      const g = plateGeom('R2', fi);
      if (g) return g;
      const u = sine(span(t, byId.S05.from, SH.S05.land));
      return { quad: START.map((p, j) => [lerp(p[0], STAND_IN.R2[j][0], u), lerp(p[1], STAND_IN.R2[j][1], u)]), notch: null, radius: lerp(0, 8, u), real: false };
    }
    const g = plateGeom(id, 0);
    return g || { quad: STAND_IN['PL-W'], notch: null, radius: 10, real: false };
  }
  /// The homography that maps the page rectangle (0,0)–(w,h) onto quad q (TL, TR, BR, BL).
  function homography(w, h, q) {
    const src = [[0, 0], [w, 0], [w, h], [0, h]];
    const A = [], B = [];
    for (let i = 0; i < 4; i++) {
      const [x, y] = src[i], [X, Y] = q[i];
      A.push([x, y, 1, 0, 0, 0, -x * X, -y * X]); B.push(X);
      A.push([0, 0, 0, x, y, 1, -x * Y, -y * Y]); B.push(Y);
    }
    for (let c = 0; c < 8; c++) {        // Gaussian elimination with partial pivoting
      let p = c; for (let r = c + 1; r < 8; r++) if (Math.abs(A[r][c]) > Math.abs(A[p][c])) p = r;
      [A[c], A[p]] = [A[p], A[c]]; [B[c], B[p]] = [B[p], B[c]];
      for (let r = 0; r < 8; r++) {
        if (r === c) continue;
        const k = A[r][c] / A[c][c];
        for (let k2 = c; k2 < 8; k2++) A[r][k2] -= k * A[c][k2];
        B[r] -= k * B[c];
      }
    }
    const [a, b, c, d, e, f, g, hh] = B.map((v, i) => v / A[i][i]);
    return { css: `matrix3d(${[a, d, 0, g, b, e, 0, hh, 0, 0, 1, 0, c, f, 0, 1].map((v) => +v.toPrecision(10)).join(',')})`, map: (x, y) => { const W = g * x + hh * y + 1; return [(a * x + b * y + c) / W, (d * x + e * y + f) / W]; } };
  }
  const unit = (p, q) => { const dx = q[0] - p[0], dy = q[1] - p[1], l = Math.hypot(dx, dy) || 1; return [dx / l, dy / l]; };
  const pt = (p) => `${p[0].toFixed(2)} ${p[1].toFixed(2)}`;
  function putScreen(sec, D) {
    const H = homography(DESK[0], DESK[1], D.quad);
    $('.screen', sec).style.transform = H.css;
    const [TLp, TRp, BRp, BLp] = D.quad, r = D.radius || 0;
    const ut = unit(TLp, TRp), ul = unit(TLp, BLp), ur = unit(TRp, BRp);
    const path = r > 0.5
      ? `M ${pt([TLp[0] + ul[0] * r, TLp[1] + ul[1] * r])} Q ${pt(TLp)} ${pt([TLp[0] + ut[0] * r, TLp[1] + ut[1] * r])} L ${pt([TRp[0] - ut[0] * r, TRp[1] - ut[1] * r])} Q ${pt(TRp)} ${pt([TRp[0] + ur[0] * r, TRp[1] + ur[1] * r])} L ${pt(BRp)} L ${pt(BLp)} Z`
      : `M ${pt(TLp)} L ${pt(TRp)} L ${pt(BRp)} L ${pt(BLp)} Z`;
    $('.dclip', sec).style.clipPath = `path("${path}")`;
    const notch = D.notch || NOTCH.map(([x, y]) => H.map(x, y));
    $('.dnotch', sec).style.clipPath = `path(evenodd, "M -400 -400 L 2320 -400 L 2320 1480 L -400 1480 Z M ${notch.map(pt).join(' L ')} Z")`;
    return { quad: D.quad, notch, radius: r, real: D.real };
  }

  // MARK: The shots — each sets its DOM for time t and returns what post.py needs for the frame
  const CARD = { id: 'PL-CARD', frame: 0, defocus: 48 };
  const plateFrame = (id, t, from) => Math.round(t * FPS) - (PL[id] ? PL[id].filmFrom : Math.round(from * FPS));
  const DO = {
    S01(t) { cutins('S01', t); return { plate: CARD }; },
    S02(t) { return { plate: { id: 'R1', frame: plateFrame('R1', t, byId.S02.from) }, layers: [] }; },
    S03(t) { cutins('S03', t); return { plate: CARD }; },
    S04(t) {
      const cuts = SH.S04.cuts, k = Math.max(0, cuts.findLastIndex((c) => t >= c - 1e-9));
      const len = (cuts[k + 1] ?? byId.S04.to) - cuts[k];
      $$('[data-shot="S04"] .cut').forEach((c, i) => c.classList.toggle('on', i === k));
      const [cx, cy] = M.chips[k], S = SH.S04.scale, [X, Y] = SH.S04.chip;
      const dx = SH.S04.drift * clamp01((t - cuts[k]) / len);
      $(`[data-shot="S04"] .cut[data-k="${k}"] .mi-win`).style.transform = `translate(${(X - S * cx + dx).toFixed(3)}px, ${(Y - S * cy).toFixed(3)}px) scale(${S})`;
      return { plate: CARD, cut: k };
    },
    S05(t) {
      const g = putScreen(secOf('S05'), displayAt('R2', t));
      const k = sine(span(t, SH.S05.reflect[0], SH.S05.reflect[1]));
      return { plate: { id: 'R2', frame: plateFrame('R2', t, byId.S05.from) }, reflect: +k.toFixed(4), display: g };
    },
    S06(t) { cutins('S06', t); return { plate: CARD }; },
    S07(t) {
      const ch = SH.S07.changes, c = Math.max(0, ch.findLastIndex((x) => t >= x - 1e-9));
      const sec = secOf('S07');
      $('.sw', sec).style.setProperty('--x', String(c));
      $$('.swap', sec).forEach((el) => el.classList.toggle('cur', +el.dataset.c === c));
      const LH = 257.6, u = c > 0 ? ROLL(span(t, ch[c], ch[c] + SH.S07.roll / FPS)) : 1;
      for (const dg of $$('.dg', sec)) {
        const spans = $$('.dg-in > span', dg).map((s) => s.textContent);
        const moving = c > 0 && spans[c] !== spans[c - 1];
        const y = moving ? (c - 1 + u) * LH : c * LH;
        $('.dg-in', dg).style.transform = y ? `translateY(${(-y).toFixed(3)}px)` : '';
      }
      return { plate: CARD, country: c };
    },
    S08(t) {
      const S = SH.S08, u = CLOSE(span(t, S.close[0], S.close[1])), d = (S.gap / 2) * (1 - u);
      const nx = 3 / Math.sqrt(10), ny = 1 / Math.sqrt(10);
      const sec = secOf('S08');
      $('.half-l', sec).style.transform = d ? `translate(${(-d * nx).toFixed(3)}px, ${(-d * ny).toFixed(3)}px)` : '';
      $('.half-r', sec).style.transform = d ? `translate(${(d * nx).toFixed(3)}px, ${(d * ny).toFixed(3)}px)` : '';
      $('.seam', sec).classList.toggle('in', t >= S.seam - 1e-9);
      $$('.sw', sec).forEach((w) => w.style.setProperty('--x', '1'));
      const s = 1 + (S.push[2] - 1) * sine(span(t, S.push[0], S.push[1]));
      cam('S08', s, 960, 540);
      return { plate: CARD, push: [s, 960, 540] };
    },
    S09(t) { cutins('S09', t); return { plate: CARD }; },
    S10(t) { cutins('S10', t); return { plate: CARD }; },
    S11(t) { return kontorShot(t, 'S11'); },
    S12(t) { return kontorShot(t, 'S12'); },
    S13(t) {
      const sec = secOf('S13'), dark = t >= SH.S13.switch - 1e-9;
      const w = $('.pxw', sec);
      w.classList.toggle('err', dark);
      w.classList.toggle('loading', !dark);
      $('.pxw-load', sec).style.setProperty('--l', dark ? '0' : String(SH.S12.progress[2][1]));
      const id = dark ? 'PL-D' : 'PL-W';
      const g = putScreen(sec, displayAt('PL-W', t));
      const c = [(g.quad[0][0] + g.quad[1][0] + g.quad[2][0] + g.quad[3][0]) / 4, (g.quad[0][1] + g.quad[1][1] + g.quad[2][1] + g.quad[3][1]) / 4];
      const s = 1 + (SH.S13.push - 1) * sine(span(t, byId.S13.from, byId.S13.to));
      cam('S13', s, c[0], c[1]);
      return { plate: { id, frame: 0 }, push: [s, c[0], c[1]], reflect: 1, display: g };
    },
    S14(t) { cutins('S14', t); return { ground: 'black', vignette: false }; },
    S15(t) {
      SH.S15.flips.forEach((a, i) => $(`[data-shot="S15"] .er[data-i="${i}"]`).classList.toggle('sealed', t >= a - 1e-9));
      const s = 1 + (SH.S15.push - 1) * sine(span(t, byId.S15.from, byId.S15.to));
      cam('S15', s, 960, 540);
      return { plate: CARD, push: [s, 960, 540] };
    },
    S16(t) { cutins('S16', t); return { plate: CARD }; },
    S17(t) {
      const S = SH.S17, p = Math.max(0, S.pages.findLastIndex((x) => t >= x - 1e-9));
      const c = Math.max(0, S.pages.findLastIndex((x) => t >= x + S.cookieLag - 1e-9));
      const sec = secOf('S17');
      $$('.mpg', sec).forEach((el, i) => {
        el.classList.toggle('cur', i === p);
        if (i === p) el.style.transform = `translateY(${(-(S.scroll / 1.5) * (t - S.pages[p])).toFixed(3)}px)`;
      });
      $$('.wst-l', sec).forEach((el, i) => el.classList.toggle('cur', i === p));
      $$('.wst-r', sec).forEach((el, i) => el.classList.toggle('cur', i === c));
      return { plate: CARD, layers: ['behind', 'front'], glass: { y0: 96 + 52 * 1.5, y1: 96 + (509.33 - 34) * 1.5 } };
    },
    S18(t) {
      const S = SH.S18, sec = secOf('S18'), plane = $('.plane', sec);
      const dolly = lerp(S.dolly[0], S.dolly[1], sine(span(t, byId.S18.from, byId.S18.to)));
      const tf = `rotateX(32deg) rotateZ(-6deg) translateX(${dolly.toFixed(3)}px)`;
      plane.style.transform = tf;
      // the plane's matrix: plane px (u, v, 0) → the perspective box's px (x, y, z toward the viewer)
      const o = [784, 544], pos = [176, -4];
      const m = new DOMMatrix().translate(pos[0] + o[0], pos[1] + o[1]).multiply(new DOMMatrix(tf)).translate(-o[0], -o[1]);
      const P = 2600, depth = (u, v) => P - m.transformPoint(new DOMPoint(u, v, 0, 1)).z;
      const centres = [[380, 260], [1188, 260], [380, 828], [1188, 828]];
      const k = Math.max(0, S.focus.findLastIndex((x) => t >= x - 1e-9));
      const r = k > 0 ? smooth(span(t, S.focus[k], S.focus[k] + S.rack / FPS)) : 1;
      const zf = lerp(depth(...centres[Math.max(0, k - 1)]), depth(...centres[k]), r);
      const zs = [[0, 0], [1568, 0], [1568, 1088], [0, 1088]].map(([u, v]) => depth(u, v));
      return { plate: { id: 'PL-FLOOR', frame: 0 }, dof: { m: Array.from(m.toFloat64Array()), P, o: [960, 540], zf: +zf.toFixed(3), zfar: +Math.max(...zs).toFixed(3), znear: +Math.min(...zs).toFixed(3), coc: 12, bins: 8, focus: k } };
    },
    S19(t) { return { plate: { id: 'R3', frame: plateFrame('R3', t, byId.S19.from) }, layers: [] }; },
    S20(t) { cutins('S20', t); return { plate: CARD }; },
    S21() { return { ground: 'black', vignette: false, grain: 0.5, layers: [] }; },
  };
  /// S11 and S12: the Store window at 1.35× (S11, push on «Weiter») and the toolbar macro at 2.4× (S12).
  function kontorShot(t, id) {
    const sec = secOf('S11'), S = SH.S11, P = SH.S12.progress;
    const w = $('.pxw', sec);
    const l = t < P[0][0] ? 0 : t < P[1][0] ? P[1][1] * outCubic(span(t, P[0][0], P[1][0])) : lerp(P[1][1], P[2][1], outCubic(span(t, P[1][0], P[2][0])));
    $('.pxw-load', sec).style.setProperty('--l', l.toFixed(5));
    w.classList.toggle('loading', t >= P[0][0] - 1e-9);
    $('.pxs-btn', sec).classList.toggle('down', t >= S.click - 1e-9 && t < S.click + S.press / FPS - 1e-9);
    // the pointer, in the window's own px: from (1500, 900) on the frame to «Weiter», ease-out quint
    const K = M.kwin.k, from = [(S.from[0] - M.kwin.left) / K, (S.from[1] - M.kwin.top) / K];
    const u = outQuint(span(t, S.pointer[0], S.pointer[1]));
    const x = lerp(from[0], M.weiter.cx, u), y = lerp(from[1], M.weiter.cy, u);
    $('.ptr', sec).style.transform = `translate(${(x - 1.5).toFixed(3)}px, ${(y - 1.5).toFixed(3)}px)`;
    const frame = (p) => [M.kwin.left + K * p[0], M.kwin.top + K * p[1]];
    if (id === 'S11') {
      const [ox, oy] = frame([M.weiter.cx, M.weiter.cy]);
      const s = 1 + (S.push - 1) * sine(span(t, byId.S11.from, byId.S11.to));
      cam('S11', s, ox, oy);
      return { plate: CARD, push: [s, ox, oy] };
    }
    // S12: 2.4× overall, framed from the chip to Safari's stop «×»; the toolbar's middle at y = 300 (as S04's
    // chip) or lower, so that the sign-in heading under it is wholly out of frame, never sliced by the edge
    const Z = 2.4 / K;
    const a = frame([(M.chip.x + M.rl.x + M.rl.w) / 2, M.chip.cy]);
    const head = frame([0, M.head.y])[1];
    const yc = Math.max(300, 1080 + 6 - Z * (head - a[1]));
    const s = 1 + (SH.S12.push - 1) * sine(span(t, byId.S12.from, byId.S12.to));
    const tx = 960 - Z * a[0], ty = yc - Z * a[1];
    camOf('S12').style.transform = `translate(${(960 - s * (960 - tx)).toFixed(3)}px, ${(yc - s * (yc - ty)).toFixed(3)}px) scale(${(Z * s).toFixed(6)})`;
    return { plate: CARD, push: [s, 960, yc] };
  }

  // MARK: Seek, plan
  let ready = null;
  let layer = null;
  function setLayer(name) {
    if (name === layer) return;
    const root = document.documentElement;
    root.classList.remove('layer-behind', 'layer-front');
    if (name === 'behind' || name === 'front') root.classList.add(`layer-${name}`);
    layer = name;
  }
  const settle = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  /// Put the stage at time t. opt.f: the frame being filmed (its shot owns t even at the shutter's edges);
  /// opt.layer: 'behind' / 'front' for the shots filmed in two layers (S17).
  async function seek(t, opt = {}) {
    await ready;
    const shot = opt.f != null ? shotAt(opt.f / FPS) : shotAt(t);
    setLayer(opt.layer || null);
    show(shot.id);
    const rec = DO[shot.id](t) || {};
    await settle();
    return rec;
  }
  /// How many 180° shutter subframes frame f averages (more only where something moves fast).
  function subframes(f) {
    const t = f / FPS, s = shotAt(t);
    if (s.id === 'S04' || s.id === 'S05') return SH[s.id].sub;
    if (s.id === 'S07') return SH.S07.changes.slice(1).some((c) => t >= c - 1e-9 && t < c + SH.S07.roll / FPS - 1e-9) ? SH.S07.sub : 1;
    if (s.id === 'S08') return t < SH.S08.close[1] - 1e-9 ? SH.S08.sub : 1;
    if (s.id === 'S11') return t >= SH.S11.pointer[0] && t < SH.S11.pointer[1] + 1 / FPS ? SH.S11.sub : 1;
    if (s.id === 'S18') return 4;
    return 1;
  }
  /// The plan of frame f: the subframe times (inside its shot and its segment), the capture layers, and the
  /// record post.py reads (the frame's own moment).
  async function plan(f) {
    const t = f / FPS, shot = shotAt(t), [a, b] = segment(shot, t);
    const n = subframes(f);
    const times = Array.from({ length: n }, (_, i) => {
      const ts = n === 1 ? t : t + ((i + 0.5) / n - 0.5) * (0.5 / FPS);
      return Math.min(b - 1e-6, Math.max(a, ts));
    });
    const r = await seek(t, { f });
    const rec = {
      f, t: +t.toFixed(6), shot: shot.id, ground: 'plate', plate: null, push: [1, 960, 540], reflect: 0, layers: ['dom'], sub: n,
      grain: 1, vignette: true, ...r,
    };
    if (rec.plate) rec.plate.file = `video/.cache/plates/${rec.plate.id}/${String(Math.max(0, rec.plate.frame)).padStart(4, '0')}.png`;
    rec.masks = masks(rec.shot);
    return { rec, times };
  }
  /// The chips' flags and the traffic lights in frame (1920 px boxes): the palette gate lets their colour be.
  function masks(id) {
    const sec = secOf(id), out = [];
    for (const el of $$('svg.flag, .mi-lights i, .sw-lights i, .pxw-lights i, .lights i', sec)) {
      const r = el.getBoundingClientRect();
      if (r.width < 0.5 || r.height < 0.5 || r.right < 0 || r.bottom < 0 || r.left > 1920 || r.top > 1080) continue;
      if (getComputedStyle(el).visibility !== 'visible') continue;
      out.push([r.left, r.top, r.width, r.height].map((v) => +v.toFixed(2)));
    }
    return out;
  }
  /// The screen pictures the renderer lights the scene with (capture.mjs --screens): the page alone, 1:1.
  async function screen(name) {
    await ready;
    const id = name === 'desktop6' ? 'S05' : 'S13';
    show(id);
    document.documentElement.classList.add('screens');
    const sec = secOf(id);
    camOf(id).style.transform = '';
    $('.screen', sec).style.transform = 'none';
    $('.dclip', sec).style.clipPath = 'none';
    $('.dnotch', sec).style.clipPath = 'none';
    if (id === 'S13') {
      const w = $('.pxw', sec), dark = name === 'error';
      w.classList.toggle('err', dark); w.classList.toggle('loading', !dark);
      $('.pxw-load', sec).style.setProperty('--l', dark ? '0' : String(SH.S12.progress[2][1]));
    }
    await settle();
  }
  /// QA states for the gates: S08 with one half alone and unclipped, no seam.
  async function qa(name, side) {
    await seek(12.75);
    const sec = secOf('S08');
    $('.seam', sec).classList.remove('in');
    camOf('S08').style.transform = '';
    for (const s of ['l', 'r']) {
      const h = $(`.half-${s}`, sec);
      h.style.transform = '';
      h.style.visibility = s === side ? 'visible' : 'hidden';
      h.style.clipPath = s === side ? 'none' : '';
    }
    await settle();
  }

  ready = (async () => {
    await new Promise((r) => (document.readyState === 'complete' ? r() : window.addEventListener('load', r, { once: true })));
    if (document.fonts) await document.fonts.ready;
    await Promise.all($$('img').map((img) => img.decode().catch(() => {})));
    measure();
  })();
  window.FILM = { seek, plan, subframes, screen, qa, ready, fps: FPS, duration: DUR, measured: M, shots: SHOTS };

  // MARK: Looking at it in a browser
  if (!navigator.webdriver) {
    document.documentElement.classList.add('look');
    const q = new URLSearchParams(location.search);
    let now = +(q.get('t') || 0);
    const go = (t) => { now = Math.max(0, Math.min(DUR - 1 / FPS, t)); return seek(now); };
    ready.then(() => go(now));
    window.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowRight') go(now + (e.shiftKey ? 1 : 1 / FPS));
      if (e.key === 'ArrowLeft') go(now - (e.shiftKey ? 1 : 1 / FPS));
    });
  }
})();
