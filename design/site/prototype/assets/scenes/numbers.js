// Home scene "numbers": each figure climbs to its value as it comes up the screen — tied to the scroll,
// so it stops when the scroll stops and runs back if you scroll back. From the moment the figure's top
// enters the window (0) until it is 40 % of the window up (1); every figure is whole once it can be
// read in the middle of the screen. Scenes only: without them (Reduce Motion, shots, no JavaScript)
// the figures are simply their values.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  if (!api.scenesOn) return;
  const items = Array.from(document.querySelectorAll('.sc-numbers [data-count]'))
    .map((n) => ({ n, to: +n.dataset.count, last: -1 }))
    .filter((x) => x.to > 0);
  if (!items.length) return;
  // Keep each figure's width while it counts, so the line does not jitter.
  const hold = () => items.forEach((x) => {
    x.n.style.minWidth = ''; const keep = x.n.textContent; x.n.textContent = String(x.to);
    x.n.style.display = 'inline-block'; x.n.style.textAlign = 'right';
    x.n.style.minWidth = `${x.n.getBoundingClientRect().width}px`; x.n.textContent = keep;
  });
  hold();
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(hold);
  let queued = false;
  function update() {
    queued = false;
    const vh = window.innerHeight;
    for (const x of items) {
      const r = x.n.getBoundingClientRect();
      const t = api.clamp01((vh - r.top) / (vh * 0.4));
      const v = Math.round(x.to * api.easeOut(t));
      if (v !== x.last) { x.last = v; x.n.textContent = String(v); }
    }
  }
  const kick = () => { if (!queued) { queued = true; requestAnimationFrame(update); } };
  window.addEventListener('scroll', kick, { passive: true });
  window.addEventListener('resize', kick);
  update();
});
