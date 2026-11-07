// A worker loaded from a URL (q2_probe.js): PrivacyScripts' hookWorkers only reaches blob workers.
(async () => {
  const r = { cores: navigator.hardwareConcurrency, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone, language: navigator.language };
  if (typeof OffscreenCanvas === 'function') {
    try {
      const c = new OffscreenCanvas(240, 60); const x = c.getContext('2d');
      x.textBaseline = 'top'; x.font = '14px Arial'; x.fillStyle = '#069'; x.fillText('Lumen ✓ Cwm fjordbank glyphs vext quiz', 2, 15);
      const d = x.getImageData(0, 0, 240, 60).data; let h = 0x811c9dc5;
      for (let i = 0; i < d.length; i++) { h ^= d[i]; h = Math.imul(h, 0x01000193); }
      r.offscreen = (h >>> 0).toString(16);
    } catch (e) { r.offscreen = 'error ' + e.message; }
  } else r.offscreen = 'absent';
  postMessage(r);
})();
