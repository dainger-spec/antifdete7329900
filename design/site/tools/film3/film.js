// The promo film (tools/film3): 30 seconds in which every frame is a function of the film's clock. The stage
// (video/stage3/<lang>.html) holds every shot; FILM.seek(t) puts it at moment t — which shots are seen, where
// their camera is, how they are turned in 3D, how far each home-page scene has played (site.js drives a scene by
// the progress it is given here instead of by the scroll), the titles, the transitions. Nothing depends on the
// frame before, so any frame can be filmed on its own (capture.mjs films ranges of frames in parallel).
//
// Look at it in a browser: ?t=12.3 opens at that moment; ← → step a frame, with Shift a second; Space plays.
(function () {
  'use strict';
  const TL = window.FILM_TIMELINE, FPS = TL.fps, DUR = TL.duration, CUE = TL.cues;
  // The vertical cut (9:16, Stories): the same shots, each 16:9 composition re-framed in a 1080 × 1920 frame (VF)
  const VERT = document.documentElement.classList.contains('vert');
  const FW = VERT ? 1080 : 1920, FH = VERT ? 1920 : 1080;
  let NOW = 0;
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => Array.from(el.querySelectorAll(s));
  const clamp01 = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x);
  const lerp = (a, b, u) => a + (b - a) * u;
  const span = (t, a, b) => clamp01((t - a) / (b - a));
  const E = {
    lin: (x) => x,
    out: (x) => 1 - Math.pow(1 - x, 3),
    in: (x) => x * x * x,
    in2: (x) => x * x,
    inOut: (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2),
    expo: (x) => (x >= 1 ? 1 : 1 - Math.pow(2, -10 * x)),
    expoIn: (x) => (x <= 0 ? 0 : Math.pow(2, 10 * x - 10)),
    smooth: (x) => x * x * (3 - 2 * x),
    sine: (x) => 0.5 - 0.5 * Math.cos(Math.PI * x),
  };
  /// Keys [[t, v, ease?], …] → one smooth curve through them (a monotone cubic, Fritsch–Carlson): it never
  /// overshoots a key and its speed never jumps, so a move flows through its keys instead of stopping at each
  /// (v1 eased every segment on its own: the camera halted at every key — the jerks). It starts from rest and comes
  /// to rest at the last key; E.lin on the first key starts it at speed, on the last key keeps its speed (into a cut).
  /// Neighbouring equal values hold.
  function keys(k, t) {
    const n = k.length;
    if (n === 1 || t <= k[0][0]) return k[0][1];
    if (t >= k[n - 1][0]) return k[n - 1][1];
    const d = [];
    for (let i = 0; i < n - 1; i++) d.push((k[i + 1][1] - k[i][1]) / (k[i + 1][0] - k[i][0]));
    const m = new Array(n).fill(0);
    for (let i = 1; i < n - 1; i++) {
      if (d[i - 1] * d[i] <= 0) continue;
      const h0 = k[i][0] - k[i - 1][0], h1 = k[i + 1][0] - k[i][0];
      m[i] = (3 * (h0 + h1)) / ((2 * h1 + h0) / d[i - 1] + (h1 + 2 * h0) / d[i]);
    }
    if (k[0][2] === E.lin) m[0] = d[0];
    if (k[n - 1][2] === E.lin) m[n - 1] = d[n - 2];
    let i = 0;
    while (t > k[i + 1][0]) i++;
    const h = k[i + 1][0] - k[i][0], u = (t - k[i][0]) / h, u2 = u * u, u3 = u2 * u;
    return (2 * u3 - 3 * u2 + 1) * k[i][1] + (u3 - 2 * u2 + u) * h * m[i] + (-2 * u3 + 3 * u2) * k[i + 1][1] + (u3 - u2) * h * m[i + 1];
  }
  const shotEl = (n) => $(`[data-shot="${n}"]`);
  const camEl = (n) => $(`[data-shot="${n}"] > .cam`);
  const drive = (name, p) => window.LumenFilm && window.LumenFilm.play(name, p);
  const css = (el, props) => { for (const k in props) el.style.setProperty(k, props[k]); };

  /// A shot seen or not, and how much (its opacity).
  function show(n, on, opacity = 1) {
    const el = shotEl(n);
    const seen = !!on && opacity > 0.001;
    el.classList.toggle('on', seen);
    el.style.opacity = seen && opacity < 0.999 ? opacity.toFixed(4) : '';
  }

  // MARK: Cameras
  /// A camera: a stage point P is seen at (tx, ty) + k·P (a uniform scale, then a move; frame px).
  const Cam = (k = 1, tx = 0, ty = 0) => ({ k, tx, ty });
  /// Scale s about the stage point (ox, oy), then move by (x, y).
  const about = (s, ox = 960, oy = 540, x = 0, y = 0) => Cam(s, x + ox - ox * s, y + oy - oy * s);
  /// B, then A.
  const then = (A, B) => Cam(A.k * B.k, A.tx + A.k * B.tx, A.ty + A.k * B.ty);
  /// Where rect r (stage px: centre, width, height) is seen through camera A.
  const seen = (A, r) => ({ cx: A.tx + A.k * r.cx, cy: A.ty + A.k * r.cy, w: A.k * r.w, h: A.k * r.h });
  const LAST = {};
  function cam(n, A) {
    if (VERT) A = then(VF(n, NOW), A);
    LAST[n] = A;
    camEl(n).style.transform = `translate(${A.tx.toFixed(2)}px, ${A.ty.toFixed(2)}px) scale(${A.k.toFixed(5)})`;
  }
  /// The vertical cut: where a shot's 16:9 composition sits in the 9:16 frame — its frame point (cx, cy) seen at
  /// (X, Y), k times larger. Two shots that dive one into the other share one framing through the dive, so the
  /// window still turns into the window.
  const fitV = (k, cx, cy, X, Y) => Cam(k, X - k * cx, Y - k * cy);
  const mixV = (A, B, u) => Cam(A.k * Math.pow(B.k / A.k, u), lerp(A.tx, B.tx, u), lerp(A.ty, B.ty, u));
  const VSHOT = {
    // the Mac: whole while it is closed and wide, closer as it opens (a slow push in), followed as it turns
    hero: (t) => fitV(keys([[0, 0.86], [2.2, 1.0], [4.05, 1.08]], t), keys([[1.0, 960], [2.6, 985], [4.05, 1100]], t), 640, 540, 1130),
    // out of the dive the shop's window is centred, then the wall of windows is framed as it spreads
    mission: (t) => fitV(keys([[4.5, 0.85], [5.3, 1.08]], t), keys([[4.5, 960], [5.3, 1086]], t), keys([[4.5, 570], [5.3, 766]], t), 540, keys([[4.5, 1000], [5.3, 1100]], t)),
    sites: () => fitV(0.95, 644, 608, 540, 740),
    safari: () => fitV(0.6, 960, 632, 540, 1120),
    numbers: () => fitV(1.0, 960, 430, 540, 820),
    layers: () => fitV(0.92, 760, 700, 430, 1080),
    // close on the sign-in form while it loads, then back to the whole window as it fails
    proxy: (t) => fitV(0.9, 960, 560, keys([[15.5, 298], [17.25, 298], [18.0, 540]], t), keys([[15.5, 810], [17.25, 810], [18.0, 1110]], t)),
    encryption: () => fitV(0.95, 960, 600, 540, 1080),
    warmup: () => fitV(0.72, 988, 700, 540, 1110),
  };
  function VF(n, t) {
    if (n === 'hero' || (n === 'mission' && t < CUE.dive[1])) {
      return t >= CUE.dive[0] ? mixV(VSHOT.hero(CUE.dive[0]), VSHOT.mission(CUE.dive[1]), E.inOut(span(t, CUE.dive[0], CUE.dive[1]))) : VSHOT.hero(t);
    }
    if (n === 'mission' || (n === 'sites' && t < CUE.through[1])) {
      return t >= CUE.through[0] ? mixV(VSHOT.mission(CUE.through[0]), VSHOT.sites(CUE.through[1]), E.inOut(span(t, CUE.through[0], CUE.through[1]))) : VSHOT.mission(t);
    }
    return VSHOT[n] ? VSHOT[n](t) : Cam();
  }
  /// A dive through a window, u 0 → 1: the leaving shot (its camera `base`) zooms into rect `from` until it
  /// covers rect `to` as the arriving shot frames it (camera `base2`); the arriving shot starts with `to` seen
  /// exactly where `from` is seen, so one window turns into the other. The zoom is geometric: an even speed.
  function dive(u, base, from, base2, to) {
    const f = seen(base, from), g = seen(base2, to);
    const Z = Math.pow(g.w / f.w, u);
    const cx = lerp(f.cx, g.cx, u), cy = lerp(f.cy, g.cy, u);
    const leave = then(Cam(Z, cx - Z * f.cx, cy - Z * f.cy), base);
    const k = (Z * f.w) / to.w;
    return { leave, enter: Cam(k, cx - k * to.cx, cy - k * to.cy) };
  }
  /// A scene turned in 3D inside its shot (the shot's camera gives the perspective): degrees about its point (ox, oy).
  function tilt(n, { rx = 0, ry = 0, rz = 0, ox = 960, oy = 540, z = 0 } = {}) {
    const el = $(`[data-shot="${n}"] .scene`);
    el.style.transformOrigin = `${ox}px ${oy}px`;
    el.style.transform = rx || ry || rz || z ? `translateZ(${z.toFixed(1)}px) rotateX(${rx.toFixed(3)}deg) rotateY(${ry.toFixed(3)}deg) rotateZ(${rz.toFixed(3)}deg)` : '';
  }

  // MARK: Light: the seam that wipes (the mark's own line, leaning 1 : 3), flashes, black
  const seam = $('.fx-seam'), flash = $('.fx-flash'), black = $('.fx-black');
  const LEAN = Math.atan(1 / 3) * 180 / Math.PI;
  /// The polygon of the frame left of the seam when its middle is at x = xc.
  const leftOf = (xc) => `polygon(-10px -10px, ${(xc + FH / 6).toFixed(1)}px -10px, ${(xc - FH / 6).toFixed(1)}px ${FH + 10}px, -10px ${FH + 10}px)`;
  /// The same, for a part inside a camera C: the seam's line taken into the part's own coordinates.
  const leftOfIn = (xc, C) => {
    const c = (xc - C.tx + (FH / 2 - C.ty) / 3) / C.k;
    return `polygon(-4000px -2000px, ${(c + 2000 / 3).toFixed(1)}px -2000px, ${(c - 4000 / 3).toFixed(1)}px 4000px, -4000px 4000px)`;
  };
  function wipe(t, a, b) {
    const u = E.inOut(span(t, a, b));
    return { u, xc: lerp(-(FH / 6 + 240), FW + FH / 6 + 240, u), glow: Math.sin(Math.PI * span(t, a, b)), on: t >= a && t <= b };
  }
  function clipShot(n, w) { shotEl(n).style.clipPath = w && w.u < 1 ? leftOf(w.xc) : ''; }

  // MARK: Titles — big; each word rises into its line from below, and on out of it at the end
  const TITLES = Object.fromEntries($$('.ttl').map((el) => [el.dataset.title, { el, words: $$('.w', el).map((w) => ({ w, l3: !!w.closest('.ln3') })) }]));
  function title(name, t, a, b, { l3 = a + 0.35, stagger = 0.06 } = {}) {
    const T = TITLES[name];
    const on = t >= a - 0.02 && t < b + 0.6;
    T.el.classList.toggle('on', on);
    if (!on) return;
    let i = 0;
    T.words.forEach((x, k) => {
      const start = x.l3 ? l3 : a + (i++) * stagger;
      const u = E.expo(span(t, start, start + 0.75));
      const v = E.in(span(t, b + k * 0.025, b + k * 0.025 + 0.34));
      const y = (1 - u) * 118 - v * 118;
      const blur = (1 - u) * 7 + v * 9;
      x.w.style.transform = `translateY(${y.toFixed(2)}%)`;
      x.w.style.opacity = (Math.min(1, u * 1.4) * (1 - v)).toFixed(3);
      x.w.style.filter = blur > 0.05 ? `blur(${blur.toFixed(2)}px)` : 'none';
    });
  }

  // MARK: The opening: the MacBook's frames (tools/film/hero.mjs, 60 a second from t = 0) under the name
  const HERO_N = Math.round(4.4 * FPS) + 1;
  const heroCv = $('.hero-cv'), hctx = heroCv.getContext('2d');
  let heroShown = -1;
  async function heroFrame(i) {
    i = Math.max(0, Math.min(HERO_N - 1, i));
    if (i === heroShown) return;
    const img = new Image();
    img.src = `../.cache/hero/${String(i).padStart(3, '0')}.png`;
    try { await img.decode(); hctx.drawImage(img, 0, 0, heroCv.width, heroCv.height); }
    catch (e) { hctx.fillStyle = '#101216'; hctx.fillRect(0, 0, heroCv.width, heroCv.height); hctx.fillStyle = '#556'; hctx.font = '48px sans-serif'; hctx.fillText(`hero frame ${i} not rendered yet`, 120, 1000); }
    heroShown = i;
  }
  // Where the display is in the last frames of the opening (frame px): the dive goes into it.
  const DISPLAY = { cx: 1229, cy: 609, w: 638, h: 414 };
  const brand = $('.brand'), brandIn = $('.brand-in');

  // MARK: Measured once (cameras at rest, flat): where a window is in a scene, so a shot can dive into the next
  const M = {};
  function measure() {
    const rect = (sel) => { const r = $(sel).getBoundingClientRect(); return { cx: r.left + r.width / 2, cy: r.top + r.height / 2, w: r.width, h: r.height, x: r.left, y: r.top }; };
    const reel = $('.reel');
    if (VERT) reel.style.transform = 'none';             // measured at the stage's own size
    const shots = ['mission', 'sites', 'features', 'numbers', 'encryption', 'layers'];
    shots.forEach((n) => { shotEl(n).classList.add('on'); shotEl(n).style.opacity = '0'; camEl(n).style.transform = ''; });
    drive('mission', 0); M.store0 = rect('.shot-mission .mi-win.focus');
    drive('mission', 1); M.store1 = rect('.shot-mission .mi-win.focus');
    drive('sites', 0.2); M.sites = rect('.shot-sites .sw');
    M.grid = rect('.shot-features .bx-grid');
    M.tiles = $$('.shot-features .bx');
    M.fig = rect('.shot-numbers .nm-hero .nm-fig');
    drive('encryption', 0.05); M.card = rect('.shot-encryption .enc-card');
    drive('layers', 0.7); M.stack = rect('.shot-layers .ly-2');
    shots.forEach((n) => { shotEl(n).classList.remove('on'); shotEl(n).style.opacity = ''; });
    reel.style.transform = '';
  }
  // The shots' cameras at rest (the dives are laid over them)
  // after the name the Mac settles a little lower, under the title
  const heroBase = (t) => about(1 + 0.02 * E.sine(span(t, 1.6, CUE.dive[0])) - 0.03 * E.inOut(span(t, 1.7, 2.6)), 960, 1000, 0, 34 * E.inOut(span(t, 1.7, 2.6)));
  const missionBase = (t) => about(keys([[4.55, 1], [5.0, 0.78], [6.3, 0.86], [6.7, 0.96]], t), 960, 1000, keys([[4.55, 0], [5.0, 170], [6.3, 120], [6.7, 0]], t), keys([[4.55, 0], [5.0, 70], [6.3, 40], [6.7, 0]], t));
  const sitesBase = (t) => about(keys([[7.04, 1], [7.6, 0.9], [9.5, 0.95, E.lin]], t), 640, 600, keys([[7.04, 0], [7.6, -70], [9.5, -60, E.lin]], t), 0);

  // MARK: The end card's mark, drawn once with the site's code art
  let codeart = null;
  (window.LumenScenes = window.LumenScenes || []).push((api) => { codeart = api.codeart; });
  const endMark = $('.end-mark');
  function drawEnd() {
    if (!codeart) return;
    const { surface, paintHalves, paintSeam, tokenMaps } = codeart;
    const cvs = ['.end-l', '.end-r', '.end-seam'].map((s) => $(s, endMark));
    const surfaces = cvs.map((c) => surface(c, 3, 12));
    const S0 = surfaces[0];
    if (!S0.W) return;
    const L = { cx: S0.W / 2, cy: S0.H / 2, R: Math.min(S0.W, S0.H) / 2 / 1.22, LH: 15 };
    const tokens = tokenMaps(L, S0.cw);
    surfaces.forEach((S) => S.ctx.clearRect(0, 0, S.W, S.H));
    paintHalves(surfaces[0], L, { which: [0], tokens });
    paintHalves(surfaces[1], L, { which: [1], tokens });
    paintSeam(surfaces[2], L, 1, 1);
  }
  /// A part that comes in: up out of a blur.
  function rise(el, t, a, { dy = 40, dur = 0.7, blur = 12, scale = 0, x = '' } = {}) {
    const v = span(t, a, a + dur), u = E.expo(v);
    el.style.opacity = E.out(clamp01(v * 1.6)).toFixed(3);
    el.style.filter = v < 1 ? `blur(${((1 - E.out(v)) * blur).toFixed(2)}px)` : 'none';
    el.style.transform = `${x}translateY(${((1 - u) * dy).toFixed(2)}px)${scale ? ` scale(${(1 - scale * (1 - u)).toFixed(4)})` : ''}`;
  }

  // MARK: The shots
  const SHOTS = [
    { name: 'hero', from: 0, to: 4.56, async frame(t) {
      await heroFrame(Math.round(t * FPS));
      const ud = E.inOut(span(t, CUE.dive[0], CUE.dive[1]));
      cam('hero', ud > 0 ? dive(ud, heroBase(t), DISPLAY, missionBase(4.55), M.store0).leave : heroBase(t));
      show('hero', true, 1 - E.smooth(span(t, CUE.dive[1] - 0.2, CUE.dive[1])));
      // the name: revealed by the seam of light, held, then it flies at the camera as the lid opens
      const w = wipe(t, CUE.brand[0], CUE.brand[1]);
      const out = span(t, CUE.brandOut[0], CUE.brandOut[1]);
      brand.style.visibility = t < CUE.brandOut[1] ? 'visible' : 'hidden';
      brand.style.clipPath = w.u < 1 ? (VERT ? leftOfIn(w.xc, LAST.hero) : leftOf(w.xc)) : '';
      const grow = 1 + 0.035 * span(t, CUE.brand[1], CUE.brandOut[0]) + 1.1 * E.expoIn(out);
      brandIn.style.transform = `scale(${grow.toFixed(4)})`;
      brandIn.style.opacity = (1 - E.in(out)).toFixed(3);
      brandIn.style.filter = out > 0 ? `blur(${(16 * E.in(out)).toFixed(2)}px)` : 'none';
      title('hero', t, 2.15, 3.92);
    } },
    { name: 'mission', from: 4.3, to: 7.1, frame(t) {
      drive('mission', keys([[4.55, 0], [4.75, 0.03], [6.35, 0.97], [6.6, 1, E.out]], t));
      const ud = E.inOut(span(t, CUE.dive[0], CUE.dive[1])), uo = E.inOut(span(t, CUE.through[0], CUE.through[1]));
      if (t < CUE.dive[1]) cam('mission', dive(ud, heroBase(t), DISPLAY, missionBase(4.55), M.store0).enter);
      else if (uo > 0) cam('mission', dive(uo, missionBase(t), M.store1, sitesBase(CUE.through[1]), M.sites).leave);
      else cam('mission', missionBase(t));
      // the wall of windows turns away to the right as it spreads, and faces us again for the dive
      tilt('mission', { ry: keys([[4.55, 0], [5.2, 24], [6.0, 18], [6.6, 0]], t), rx: keys([[4.55, 0], [5.2, 9], [6.0, 7], [6.6, 0]], t), ox: 960, oy: 600 });
      show('mission', true, Math.min(E.smooth(span(t, CUE.dive[0] + 0.12, CUE.dive[1] - 0.05)), 1 - E.smooth(span(t, CUE.through[1] - 0.1, CUE.through[1] + 0.02))));
      title('mission', t, 4.72, 6.55);
    } },
    { name: 'sites', from: 6.86, to: 9.56, frame(t) {
      drive('sites', keys([[7.0, 0.2], [7.55, 0.29, E.lin], [7.85, 0.405, E.lin], [8.3, 0.59, E.lin], [8.6, 0.705, E.lin], [9.0, 0.8, E.lin], [9.45, 0.9, E.out]], t));
      const uo = E.inOut(span(t, CUE.through[0], CUE.through[1]));
      const out = E.in(span(t, 9.34, 9.54));
      cam('sites', t < CUE.through[1] ? dive(uo, missionBase(t), M.store1, sitesBase(CUE.through[1]), M.sites).enter : then(about(1 + 0.25 * out, 960, 560), sitesBase(t)));
      tilt('sites', { ry: keys([[7.04, 0], [7.7, 16], [9.5, 11, E.lin]], t), rx: keys([[7.04, 0], [7.7, 5], [9.5, 3, E.lin]], t), ox: M.sites.cx, oy: M.sites.cy });
      show('sites', true, Math.min(E.smooth(span(t, 6.86, 7.0)), 1 - out));
      // the country and its time roll past like a slot, a country a change
      const at = CUE.countries;
      const cur = keys([[at[1] - 0.16, 0], [at[1] + 0.14, 1], [at[2] - 0.16, 1], [at[2] + 0.14, 2]], t);
      const vel = Math.abs(keys([[at[1] - 0.16, 0], [at[1] + 0.14, 1], [at[2] - 0.16, 1], [at[2] + 0.14, 2]], t + 0.01) - cur) * 100;
      const enter = E.expo(span(t, 7.1, 7.6));
      $$('.shot-sites .cty-i').forEach((el, i) => {
        el.style.transform = `translateY(${((i - cur) * 420 + (1 - enter) * 160).toFixed(2)}px)`;
        el.style.filter = vel > 0.02 || enter < 1 ? `blur(${Math.min(14, vel * 6 + (1 - enter) * 12).toFixed(2)}px)` : 'none';
        el.style.opacity = (i === 0 ? Math.min(1, enter * 1.4) : 1).toFixed(3);
      });
      rise($('.shot-sites .cty-k'), t, 7.1, { dy: 30 });
    } },
    { name: 'safari', from: 9.36, to: 11.8, frame(t) {
      // an open book swings in from the edge; the same fingerprint is read on both pages, row by row
      const open = E.out(span(t, CUE.vsIn[0] - 0.12, CUE.vsIn[1]));
      const ry = keys([[CUE.vsIn[0] - 0.12, 80, E.lin], [CUE.vsIn[1], 26], [CUE.fly[0], 18, E.lin]], t);
      $('.vs-l').style.transform = `rotateY(${ry.toFixed(3)}deg)`;
      $('.vs-r').style.transform = `rotateY(${(-ry).toFixed(3)}deg)`;
      CUE.rows.forEach((r, i) => {
        const sl = span(t, r, r + 0.18), sr = span(t, r + 0.16, r + 0.34);
        $$(`.vs-l .vs-row[data-i="${i}"], .vs-r .vs-row[data-i="${i}"]`).forEach((row, side) => {
          const s = side ? sr : sl;
          css(row, { '--s': E.inOut(s).toFixed(3) });
          $('.vs-scan', row).style.opacity = (Math.sin(Math.PI * s) * 0.9).toFixed(3);
        });
        const eq = $(`.vs-eq[data-i="${i}"]`);
        rise(eq, t, r + 0.3, { dy: 0, dur: 0.45, blur: 10, scale: 0.35, x: 'translateX(-50%) ' });
      });
      $('.vs-spine').style.opacity = (0.35 * open + 0.65 * span(t, CUE.rows[0], CUE.rows[2] + 0.4)).toFixed(3);
      // then into the spine: through the book to the number
      const fly = E.expoIn(span(t, CUE.fly[0], CUE.fly[1]));
      cam('safari', about(1 + 0.04 * span(t, 9.5, CUE.fly[0]) + 3.2 * fly, 960, 640));
      show('safari', true, 1 - E.smooth(span(t, CUE.fly[1] - 0.12, CUE.fly[1] + 0.04)));
      title('safari', t, 9.56, 11.1);
    } },
    { name: 'numbers', from: 11.6, to: 13.68, frame(t) {
      const img = $('.shot-numbers .nm-macro img');
      css(img, { '--on': E.out(span(t, 11.62, 12.0)).toFixed(3), '--k': lerp(0.12, 0.6, span(t, 11.6, 13.7)).toFixed(4) });
      $$('.shot-numbers .nm-hero .nm-fig').forEach((f) => css(f, { '--v': E.out(span(t, CUE.slam - 0.04, CUE.slam + 0.25)).toFixed(3) }));
      const slam = E.expo(span(t, CUE.slam - 0.05, CUE.slam + 0.55));
      cam('numbers', about(lerp(1.75, 1.22, slam) + 0.05 * E.in2(span(t, 12.1, 13.7)), M.fig.cx, M.fig.cy, 960 - M.fig.cx, 430 - M.fig.cy));
      show('numbers', true, E.smooth(span(t, 11.62, 11.76)));
      title('probe', t, 11.98, 12.98, { stagger: 0.04 });
    } },
    { name: 'layers', from: 13.34, to: 15.5, frame(t) {
      drive('layers', keys([[13.34, 0], [13.5, 0.04], [14.0, 0.27], [15.2, 0.62, E.lin], [15.5, 0.66, E.out]], t));
      // the camera comes round the stack as it parts
      tilt('layers', { ry: keys([[13.34, -16], [15.5, 10, E.lin]], t), rx: keys([[13.34, 4], [15.5, -2, E.lin]], t), ox: M.stack.cx, oy: M.stack.cy });
      cam('layers', about(1.28 + 0.06 * span(t, 13.34, 15.5), M.stack.cx, M.stack.cy, 760 - M.stack.cx, 700 - M.stack.cy));
      clipShot('layers', wipe(t, CUE.wipe1[0], CUE.wipe1[1]));
      show('layers', true);
      title('layers', t, 13.62, 15.3);
      $$('.shot-layers .lw li').forEach((li, i) => {
        const a = CUE.words[i];
        rise(li, t, a, { dy: 50, dur: 0.5, blur: 10 });
        li.style.color = t < (CUE.words[i + 1] ?? 99) + 0.05 ? '#F6F7F9' : '#9099A8';
      });
    } },
    { name: 'proxy', from: 15.5, to: 18.62, frame(t) {
      drive('proxy', keys([[15.5, 0], [15.6, 0.05, E.lin], [15.84, 0.125, E.lin], [16.25, 0.34, E.out], [16.5, 0.4, E.lin], [16.8, 0.43, E.lin], [16.95, 0.468, E.lin], [17.25, 0.5, E.lin], [17.8, 0.665, E.inOut], [18.6, 0.74, E.lin]], t));
      tilt('proxy', { rx: keys([[17.3, 0], [18.6, 13, E.out]], t), ry: keys([[17.3, 0], [18.6, -8, E.out]], t), ox: 960, oy: 640 });
      cam('proxy', about(1 + 0.03 * E.sine(span(t, 15.5, 17.0)) - 0.06 * E.in2(span(t, 17.3, 18.6)), 960, 600, 0, 46 * E.inOut(span(t, 17.25, 17.9))));
      show('proxy', true, 1 - E.smooth(span(t, 18.36, 18.52)));
      title('proxy', t, 17.3, 18.3, { l3: 17.72 });
    } },
    { name: 'encryption', from: 18.5, to: 21.16, frame(t) {
      drive('encryption', keys([[18.5, 0.03], [19.45, 0.36, E.lin], [20.3, 0.72, E.lin], [20.8, 0.86, E.out], [21.16, 0.9, E.lin]], t));
      // close on the window, tipped back, while the light seals it; then up to the lock and its two names
      const k = keys([[18.5, 1.55], [19.4, 1.45, E.out], [20.1, 1.1], [21.16, 1.05, E.out]], t);
      const oy = keys([[18.5, M.card.cy], [19.4, M.card.cy], [20.1, 650], [21.16, 650]], t);
      const y = keys([[18.5, 110], [19.4, 100], [20.1, -40], [21.16, -46]], t);
      cam('encryption', about(k, 960, oy, 0, y));
      tilt('encryption', { rx: keys([[18.5, 22], [19.5, 12], [20.1, 0]], t), ry: keys([[18.5, -10], [19.5, -6], [20.1, 0]], t), ox: M.card.cx, oy: M.card.cy });
      show('encryption', true, E.smooth(span(t, 18.5, 18.68)));
      title('encryption', t, 18.62, 20.5);
      rise($('.shot-encryption .cn'), t, 20.3, { dy: 40 });
    } },
    { name: 'warmup', from: 20.84, to: 23.0, frame(t) {
      drive('warmup', keys([[20.84, 0], [21.0, 0.02, E.lin], [22.95, 0.74, E.lin]], t));
      tilt('warmup', { ry: keys([[20.84, 14], [23, 6, E.lin]], t), rx: keys([[20.84, 7], [23, 3, E.lin]], t), ox: 960, oy: 680 });
      cam('warmup', about(0.95 + 0.04 * span(t, 20.84, 23), 960, 680, 70, 20));
      clipShot('warmup', wipe(t, CUE.wipe2[0], CUE.wipe2[1]));
      show('warmup', true);
      title('warmup', t, 21.12, 22.5);
    } },
    { name: 'features', from: 23.0, to: 25.56, frame(t) {
      // the grid of tiles as a plane tilted back, gliding up and away under the title
      const u = span(t, 23.0, 25.6), g = M.grid;
      const rx = lerp(40, 30, E.out(u)), rz = lerp(-13, -8, E.out(u)), yc = lerp(800, 560, E.out(u));
      const fx = VERT ? 540 : 960, fy = VERT ? lerp(1560, 1200, E.out(u)) : yc, fk = VERT ? 0.66 : 0.98;
      camEl('features').style.transform = `translate(${fx}px, ${fy.toFixed(2)}px) rotateX(${rx.toFixed(3)}deg) rotateZ(${rz.toFixed(3)}deg) scale(${fk}) translate(${(-g.cx).toFixed(1)}px, ${(-g.cy).toFixed(1)}px)`;
      M.tiles.forEach((el, i) => {
        // a head start, so the plane is there on the cut; each tile lands on its note
        const a = CUE.tiles[Math.min(i, CUE.tiles.length - 1)] - 0.16;
        const v = span(t, a, a + 0.55);
        el.style.opacity = E.out(clamp01(v * 1.5)).toFixed(3);
        el.style.transform = `translateY(${((1 - E.expo(v)) * 110).toFixed(2)}px)`;
        el.style.filter = v < 1 ? `blur(${((1 - E.out(v)) * 10).toFixed(2)}px)` : 'none';
      });
      const ep = $('.shot-features .ep-win');
      if (ep) ep.style.setProperty('--x', E.inOut(span(t, 23.9, 24.6)).toFixed(3));
      show('features', true, 1 - E.smooth(span(t, 25.36, 25.52)));
      title('features', t, 23.0, 25.2);
    } },
    { name: 'end', from: 25.5, to: 30.01, frame(t) {
      const q = E.inOut(span(t, 25.62, CUE.meet));
      endMark.style.setProperty('--q', q.toFixed(4));
      const hv = (0.12 + 0.88 * E.out(span(t, 25.55, 26.1))).toFixed(3);
      $('.end-l').style.opacity = hv; $('.end-r').style.opacity = hv;
      $('.end-seam').style.opacity = E.out(span(t, CUE.meet - 0.08, CUE.meet + 0.2)).toFixed(3);
      $('.end-glow').style.opacity = (0.25 + 0.75 * E.out(span(t, CUE.meet - 0.1, CUE.meet + 0.5)) - 0.25 * E.sine(span(t, CUE.meet + 0.5, 30))).toFixed(3);
      rise($('.end-name'), t, CUE.name, { dy: 36 });
      rise($('.end-line'), t, CUE.name + 0.3, { dy: 30 });
      rise($('.end-btn'), t, CUE.name + 0.6, { dy: 24, x: 'translateX(-50%) ' });
      // the mark rises a little as the words come in under it
      endMark.style.transform = `translateY(${(-36 * E.inOut(span(t, CUE.name - 0.2, CUE.name + 0.8))).toFixed(2)}px)`;
      cam('end', about(1 + 0.035 * E.sine(span(t, 25.5, 30)), VERT ? 540 : 960, VERT ? 900 : 520));
      show('end', true, E.smooth(span(t, 25.5, 25.66)));
    } },
  ];

  // MARK: Over everything: the seam, the flashes, black
  function fx(t) {
    const ws = [wipe(t, CUE.brand[0], CUE.brand[1]), wipe(t, CUE.wipe1[0], CUE.wipe1[1]), wipe(t, CUE.wipe2[0], CUE.wipe2[1])];
    const w = ws.find((x) => x.on);
    seam.style.opacity = w ? w.glow.toFixed(3) : '0';
    seam.style.transform = `translate(${((w ? w.xc : -200) - 3).toFixed(1)}px, 0) rotate(${LEAN.toFixed(3)}deg)`;
    const pulse = (a, k, len = 0.5) => (t < a - 0.06 ? 0 : t < a ? k * span(t, a - 0.06, a) : k * Math.pow(1 - span(t, a, a + len), 2));
    flash.style.opacity = Math.max(pulse(CUE.brand[1] - 0.1, 0.3, 0.7), pulse(CUE.dive[1], 0.35), pulse(CUE.slam, 0.6, 0.6), pulse(CUE.meet, 0.6, 0.9)).toFixed(3);
    const dip = (a, b) => Math.sin(Math.PI * span(t, a, b));
    black.style.opacity = Math.max(dip(18.34, 18.7) * 0.97, dip(25.34, 25.7)).toFixed(3);
  }

  // MARK: Seek
  let ready = null;
  async function seek(t) {
    await ready;
    NOW = t;
    for (const s of SHOTS) {
      if (t >= s.from && t < s.to) await s.frame(t);
      else { show(s.name, false); shotEl(s.name).style.clipPath = ''; }
    }
    for (const n of Object.keys(TITLES)) {
      const owner = { probe: 'numbers' }[n] || n;
      if (!SHOTS.some((s) => s.name === owner && t >= s.from && t < s.to)) TITLES[n].el.classList.remove('on');
    }
    fx(t);
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    return t;
  }
  /// How many moments of the shutter (180°) a frame at t averages: every frame that moves gets motion blur (3
  /// moments), the fast moves more; the shutter never spans a hard cut.
  function blurAt(t) {
    const near = (a, b) => t >= a && t <= b;
    const cuts = [9.36, 11.6, 15.5, 23.0, 25.5];
    if (cuts.some((c) => Math.abs(t - c) < 0.5 / FPS)) return 1;
    // the light's seam is a thin line crossing the frame in half a second: averaged moments would show it two or
    // three times over, so the wipes are filmed sharp
    if (near(CUE.brand[0] - 0.02, CUE.brand[1] + 0.02) || near(CUE.wipe1[0] - 0.02, CUE.wipe1[1] + 0.02) || near(CUE.wipe2[0] - 0.02, CUE.wipe2[1] + 0.02)) return 1;
    if (near(CUE.dive[0], CUE.dive[1] + 0.05) || near(CUE.through[0], CUE.through[1] + 0.02) || near(CUE.fly[0], CUE.fly[1] + 0.05)) return 6;
    if (near(CUE.brandOut[0], CUE.brandOut[1]) || near(9.34, 9.95) || near(CUE.slam, CUE.slam + 0.3) || near(CUE.wipe1[0], CUE.wipe1[1]) || near(CUE.wipe2[0], CUE.wipe2[1]) || near(25.6, CUE.meet + 0.05)) return 5;
    if (near(7.6, 8.0) || near(8.35, 8.75) || near(23.02, 24.0)) return 5;
    if (t > 27.6) return 2;                   // the end card barely moves
    return 3;
  }

  ready = (async () => {
    await new Promise((r) => (document.readyState === 'complete' ? r() : window.addEventListener('load', r, { once: true })));
    if (document.fonts) await document.fonts.ready;
    await Promise.all($$('img').map((img) => (img.complete ? Promise.resolve() : new Promise((r) => { img.onload = img.onerror = r; }))));
    await Promise.all($$('img').map((img) => img.decode().catch(() => {})));
    measure();
    drawEnd();
    Object.values(TITLES).forEach((T) => T.el.classList.remove('on'));
  })();
  window.FILM = { seek, blurAt, ready, fps: FPS, duration: DUR, measured: M };

  // MARK: Looking at it in a browser
  const q = new URLSearchParams(location.search);
  if (!navigator.webdriver) {
    let now = +(q.get('t') || 0), playing = false;
    const go = (t) => { now = Math.max(0, Math.min(DUR - 1 / FPS, t)); return seek(now); };
    ready.then(() => go(now));
    window.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowRight') go(now + (e.shiftKey ? 1 : 1 / FPS));
      if (e.key === 'ArrowLeft') go(now - (e.shiftKey ? 1 : 1 / FPS));
      if (e.key === ' ') {
        playing = !playing;
        const t0 = performance.now() - now * 1000;
        const tick = async () => { if (!playing) return; await go((performance.now() - t0) / 1000); if (now >= DUR - 1 / FPS) playing = false; requestAnimationFrame(tick); };
        tick();
      }
    });
  }
})();
