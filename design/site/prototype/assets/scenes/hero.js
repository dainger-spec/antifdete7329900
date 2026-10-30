// Home scene "hero": scrubs the MacBook's rendered frames (assets/scenes/hero/{d,m}/NN.webp, made by
// tools/hero/render.mjs) on a canvas with the scroll, the way Apple's product pages do. Landscape frames for
// screens wider than tall, portrait ones for phones. Frames load in the background, the first and the last
// first; until a frame is in, the nearest loaded one stands in. Draws only when the progress or the size
// changes: nothing moves by itself. Without scenes the section's still picture is used and this does nothing.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  'use strict';
  if (!api.scenesOn) return;
  const stage = document.querySelector('.sc-hero .hr-stage');
  if (!stage) return;
  const canvas = stage.querySelector('.hr-film');
  const ctx = canvas.getContext('2d', { alpha: false });
  const END = 0.86;                 // the film ends here; the rest of the scene holds the last frame
  const sets = {};
  for (const k of ['d', 'm']) {
    const [dir, n, w, h, top] = (stage.dataset[k] || '').split('|');
    if (dir) sets[k] = { dir, n: +n, w: +w, h: +h, top: +top, imgs: new Array(+n), ok: new Array(+n).fill(false), started: false };
  }
  const copy = document.querySelector('.sc-hero .hr-copy'), cta = copy && copy.querySelector('.hr-cta');
  let set = null, p = 0, drawn = -1, drawnY = 0, raf = 0, W = 0, H = 0, clear = 0;

  const pick = () => (innerWidth < 600 || innerWidth / innerHeight < 0.78 ? sets.m : sets.d) || sets.d;
  function load(S) {
    if (S.started) return;
    S.started = true;
    // first, last, then coarse to fine so that any scroll position soon has a frame near it
    const order = [0, S.n - 1];
    for (let step = 16; step >= 1; step = step >> 1) for (let i = 0; i < S.n; i += step) if (!order.includes(i)) order.push(i);
    let next = 0, active = 0;
    const pump = () => {
      while (active < 6 && next < order.length) {
        const i = order[next++], img = new Image();
        active++;
        img.decoding = 'async';
        img.onload = () => {
          const done = () => { S.ok[i] = true; active--; if (S === set && Math.abs(i - frameAt(p)) <= Math.abs(drawn - frameAt(p))) kick(true); pump(); };
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
  function size() {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    W = Math.round(canvas.clientWidth * dpr); H = Math.round(canvas.clientHeight * dpr);
    if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; }
    // the lowest point of the words (device px), plus a margin, measured with the words in place
    if (cta) clear = (cta.offsetParent === copy ? copy.offsetTop + cta.offsetTop + cta.offsetHeight + 28 : 0) * dpr;
    const s = pick();
    if (s !== set) { set = s; load(set); }
    drawn = -1;
  }
  function draw() {
    raf = 0;
    if (!set || !W) return;
    const f = nearest(frameAt(p));
    // on screens shorter than the frames were composed for, the words reach down to the Mac: lower the
    // picture just enough at the start, and give the room back as the words leave
    const sc = Math.max(W / set.w, H / set.h);
    const sh = H / sc, sy = (set.h - sh) * (set === sets.d ? 0.62 : 0.5);
    const lid = (set.top * set.h - sy) * sc;
    const dy = Math.round(Math.max(0, clear - lid) * (1 - api.smooth(p / 0.22)));
    if (f < 0 || (f === drawn && dy === drawnY)) return;
    drawn = f; drawnY = dy;
    // cover the screen; a landscape frame keeps a little more of its bottom (the Mac) than of its top
    const img = set.imgs[f];
    const sw = W / sc, sx = (set.w - sw) / 2;
    ctx.fillStyle = '#060709'; ctx.fillRect(0, 0, W, H);
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(img, sx, sy, sw, sh, 0, dy, W, H);
  }
  function kick(force) { if (force) drawn = -1; if (!raf) raf = requestAnimationFrame(draw); }

  size();
  api.onScene('hero', (q, el) => {
    p = q;
    // the words are links only while they are visible
    el.style.setProperty('--copy-pe', q < 0.12 ? 'auto' : 'none');
    kick(false);
  });
  let rt = 0;
  window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(() => { size(); kick(true); }, 100); });
});
