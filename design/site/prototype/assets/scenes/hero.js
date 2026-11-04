// Home scene "hero": scrubs the MacBook's rendered frames (assets/scenes/hero/{d,m}/NN.webp, made by
// tools/hero/render.mjs) on a canvas with the scroll, the way Apple's product pages do. Landscape frames for
// screens wider than tall, portrait ones for phones. A small poster of the first frame comes first, then the
// frames, the first and the last first, then coarse to fine; until a frame is in, the nearest loaded one
// stands in. Draws only when the progress or the size changes: nothing moves by itself. Without scenes the
// section's still picture is used and this does nothing.
//
// Fitting: the frames were composed for one shape of screen. On others the picture is fitted to the room the
// words leave: at the start the whole Mac sits between the words and the bottom edge (lowered, or a little
// smaller, if it has to be); at the end the floating half and the Mac sit clear of the closing line (on
// desktop the line is at the top, on phones at the bottom). In between the picture is the frame as rendered.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  'use strict';
  if (!api.scenesOn) return;
  const sec = document.querySelector('.sc-hero');
  const stage = sec && sec.querySelector('.hr-stage');
  if (!stage) return;
  const canvas = stage.querySelector('.hr-film');
  const ctx = canvas.getContext('2d', { alpha: false });
  const END = 0.9;                  // the film ends here; the rest of the scene holds the last frame
  const sets = {};
  for (const k of ['d', 'm']) {
    const v = (stage.dataset[k] || '').split('|');
    if (v[0]) sets[k] = { k, dir: v[0], n: +v[1], w: +v[2], h: +v[3], a: v[4].split(',').map(Number), z: v[5].split(',').map(Number), poster: v[6], imgs: new Array(+v[1]), ok: new Array(+v[1]).fill(false), started: false, post: null };
  }
  const copy = sec.querySelector('.hr-copy'), cta = copy && copy.querySelector('.hr-cta'), cap = sec.querySelector('.hr-caption');
  let set = null, p = 0, drawn = '', raf = 0, W = 0, H = 0, dpr = 1, room = null;

  const pick = () => (innerWidth < 600 || innerWidth / innerHeight < 0.78 ? sets.m : sets.d) || sets.d;
  function load(S) {
    if (S.started) return;
    S.started = true;
    if (S.poster) { const im = new Image(); im.onload = () => { S.post = im; if (S === set) kick(true); }; im.src = S.poster; }
    const order = [0, S.n - 1];
    for (let step = 16; step >= 1; step = step >> 1) for (let i = 0; i < S.n; i += step) if (!order.includes(i)) order.push(i);
    let next = 0, active = 0;
    const pump = () => {
      while (active < 6 && next < order.length) {
        const i = order[next++], img = new Image();
        active++;
        img.decoding = 'async';
        img.onload = () => {
          const done = () => { S.ok[i] = true; active--; if (S === set) kick(true); pump(); };
          if (img.decode) img.decode().then(done, done); else done();
        };
        img.onerror = () => { active--; pump(); };
        img.src = `${S.dir}${String(i).padStart(2, '0')}.webp`;
        S.imgs[i] = img;
      }
    };
    pump();
  }
  const frameAt = (q) => Math.round(api.clamp01(q / END) * (set.n - 1));
  function nearest(f) {
    for (let d = 0; d < set.n; d++) { if (f - d >= 0 && set.ok[f - d]) return f - d; if (f + d < set.n && set.ok[f + d]) return f + d; }
    return -1;
  }
  /// The y of an element's box inside the section's pinned screen, in CSS px.
  const pin = sec.querySelector('.scene-pin');
  const yIn = (el, edge) => { let y = edge ? el.offsetHeight : 0; for (let e = el; e && e !== pin && e !== sec; e = e.offsetParent) y += e.offsetTop; return y; };
  function size() {
    dpr = Math.min(2, window.devicePixelRatio || 1);
    W = Math.round(canvas.clientWidth * dpr); H = Math.round(canvas.clientHeight * dpr);
    if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; }
    const s = pick();
    if (s !== set) { set = s; sec.dataset.set = s.k; load(set); }
    // the room the words leave, measured with them in place (their transforms do not move offsets)
    const head = -parseFloat(getComputedStyle(sec).marginTop) || 0;
    const margin = Math.max(20, Math.min(44, innerHeight * 0.04));
    const words = cta ? yIn(cta, true) + Math.min(36, innerHeight * 0.04) : head;
    let end;
    if (set.k === 'm') end = [head + 12, cap ? yIn(cap, false) - 20 : innerHeight - margin];
    else end = [cap ? yIn(cap, true) + 20 : head, innerHeight - margin];
    room = { start: [words, innerHeight - margin].map((v) => v * dpr), end: end.map((v) => v * dpr) };
    drawn = '';
  }
  /// The vertical transform (y' = y * k + o, x scaled by k round the middle) that puts [top, bot] inside
  /// [lo, hi]: unchanged if it fits, else moved the least, else made smaller.
  function fit(top, bot, lo, hi) {
    if (bot - top > hi - lo) { const k = (hi - lo) / (bot - top); return { k, o: lo - top * k }; }
    if (top < lo) return { k: 1, o: lo - top };
    if (bot > hi) return { k: 1, o: hi - bot };
    return { k: 1, o: 0 };
  }
  function draw() {
    raf = 0;
    if (!set || !W) return;
    const f = nearest(frameAt(p));
    const img = f >= 0 ? set.imgs[f] : set.post;
    if (!img) return;
    // cover the screen; a landscape frame keeps a little more of its bottom (the Mac) than of its top
    const sc = Math.max(W / set.w, H / set.h);
    const sw = W / sc, sh = H / sc, sx = (set.w - sw) / 2, sy = (set.h - sh) * (set.k === 'd' ? 0.62 : 0.5);
    const Y = (fy) => (fy * set.h - sy) * sc;
    const a = fit(Y(set.a[0]), Y(set.a[1]), room.start[0], room.start[1]);
    const z = fit(Y(set.z[0]), Y(set.z[1]), room.end[0], room.end[1]);
    const ea = 1 - api.smooth(p / 0.24), ez = api.smooth((p - 0.6) / 0.16);
    const k = 1 + (a.k - 1) * ea + (z.k - 1) * ez, o = a.o * ea + z.o * ez;
    const key = `${f}|${img === set.post ? 'p' : ''}|${k.toFixed(4)}|${o.toFixed(1)}`;
    if (key === drawn) return;
    drawn = key;
    ctx.fillStyle = '#060709'; ctx.fillRect(0, 0, W, H);
    ctx.imageSmoothingQuality = 'high';
    // the whole frame, so that a picture moved or made smaller brings in what the cover crop left out
    // (the frames' edges are the page's black)
    const s = sc * k;
    ctx.drawImage(img, (W - W * k) / 2 - sx * s, o - sy * s, set.w * s, set.h * s);
  }
  function kick(force) { if (force) drawn = ''; if (!raf) raf = requestAnimationFrame(draw); }

  size();
  api.onScene('hero', (q, el) => {
    p = q;
    // the words are links only while they are visible
    el.style.setProperty('--copy-pe', q < 0.12 ? 'auto' : 'none');
    kick(false);
  });
  let rt = 0;
  window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(() => { size(); kick(true); }, 100); });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { size(); kick(true); });
});
