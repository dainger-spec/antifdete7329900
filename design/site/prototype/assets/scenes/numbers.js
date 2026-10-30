// Home scene "numbers": scroll-tied, scenes only (without them every figure and the picture are simply
// finished). Two things follow the scroll, and stop when it stops:
//  - the macro shot: --k (0 when its top enters the window, 1 when its bottom leaves) drifts the camera
//    along the line of code; --on brings the display up while it rises into the lower half;
//  - each figure: --v (0 → 1) while its top climbs from 96 % to 74 % of the window height (a column's
//    figures a little after one another), so every figure is whole well below the middle of the window.
// No figure counts: a count would show values that are not facts.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  if (!api.scenesOn) return;
  const root = document.querySelector('.sc-numbers');
  if (!root) return;
  const hero = root.querySelector('.nm-hero'), img = root.querySelector('.nm-macro img');
  const figs = Array.from(root.querySelectorAll('.nm-fig')).map((el) => ({ el, c: +(el.style.getPropertyValue('--c') || 0), v: -1 }));
  let k0 = -1, on0 = -1, queued = false;
  function update() {
    queued = false;
    const vh = window.innerHeight;
    const r = hero.getBoundingClientRect();
    if (r.bottom > -vh && r.top < 2 * vh) {
      const k = api.clamp01((vh - r.top) / (vh + r.height));
      const on = api.smooth((vh - r.top) / (vh * 0.55));
      if (Math.abs(k - k0) > 0.0005) { k0 = k; img.style.setProperty('--k', k.toFixed(4)); }
      if (Math.abs(on - on0) > 0.002) { on0 = on; img.style.setProperty('--on', on.toFixed(3)); }
    }
    for (const f of figs) {
      const t = f.el.getBoundingClientRect().top;
      const v = api.easeOut((vh * (0.96 - f.c * 0.025) - t) / (vh * 0.22));
      if (Math.abs(v - f.v) > 0.002) { f.v = v; f.el.style.setProperty('--v', v.toFixed(3)); }
    }
  }
  const kick = () => { if (!queued) { queued = true; requestAnimationFrame(update); } };
  window.addEventListener('scroll', kick, { passive: true });
  window.addEventListener('resize', kick);
  update();
});
