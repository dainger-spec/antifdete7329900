// Home scene "cta": the mark in code, drawn once per size on three canvases (left half, right half, the
// seam) with site.js's code art; the scroll only moves and fades them (--q on .ct-art), so nothing is
// redrawn while you scroll and nothing moves when you stop. --q: 0 when the mark's top enters the
// window, 1 when it has risen 45 % of the window. Without scenes the mark is drawn whole (--q stays 1).
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  const art = document.querySelector('.sc-cta .ct-art');
  if (!art) return;
  const [cl, cr, cs] = ['.ct-l', '.ct-r', '.ct-seam'].map((s) => art.querySelector(s));
  const { surface, paintHalves, paintSeam, tokenMaps } = api.codeart;

  function draw() {
    const scale = Math.min(3, Math.max(2, (window.devicePixelRatio || 1) * 1.5));
    const fs = art.offsetWidth < 300 ? 8 : 9.5, LH = art.offsetWidth < 300 ? 10 : 12;
    const surfaces = [cl, cr, cs].map((c) => surface(c, scale, fs));
    const S0 = surfaces[0];
    if (!S0.W) return false;
    const L = { cx: S0.W / 2, cy: S0.H / 2, R: Math.min(S0.W, S0.H) / 2 / 1.22, LH };
    const tokens = tokenMaps(L, S0.cw);
    surfaces.forEach((S) => S.ctx.clearRect(0, 0, S.W, S.H));
    paintHalves(surfaces[0], L, { which: [0], tokens });
    paintHalves(surfaces[1], L, { which: [1], tokens });
    paintSeam(surfaces[2], L, 1, 1);
    art.querySelector('.art-fallback').style.display = 'none';
    return true;
  }
  draw();
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(draw);
  let rt = 0;
  window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(draw, 150); });

  if (!api.scenesOn) return;
  let queued = false, last = -1;
  function update() {
    queued = false;
    const vh = window.innerHeight, r = art.getBoundingClientRect();
    const q = api.easeOut(api.clamp01((vh - r.top) / (vh * 0.45)));
    if (Math.abs(q - last) < 0.001) return;
    last = q;
    art.style.setProperty('--q', q.toFixed(4));
  }
  const kick = () => { if (!queued) { queued = true; requestAnimationFrame(update); } };
  window.addEventListener('scroll', kick, { passive: true });
  window.addEventListener('resize', kick);
  update();
});
