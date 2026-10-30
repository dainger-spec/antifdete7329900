// Home scene "numbers": each number counts up once, when it comes into view (with scenes only).
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  document.querySelectorAll('.nm-item [data-count]').forEach((n) => {
    const to = +n.dataset.count;
    if (!to || !api.scenesOn || !('IntersectionObserver' in window)) return;
    n.textContent = '0';
    const io = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      const t0 = performance.now(), dur = to > 100 ? 1400 : 900;
      const tick = (t) => { const k = Math.min(1, (t - t0) / dur); n.textContent = String(Math.round(to * api.easeOut(k))); if (k < 1) requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
    }, { threshold: 0.6 });
    io.observe(n);
  });
});
