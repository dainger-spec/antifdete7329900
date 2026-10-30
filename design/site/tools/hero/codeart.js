// The Lumen mark in code characters, for the hero renderer (tools/hero/renderer.js). A port of the site's
// painter (prototype/assets/site.js, "Code art"): the split disc of LumenMarkGeometry (radius 19, gap 3,
// slide 6; seam direction (1, -3)), binary in a monospace grid, each half a profile with a few of its own
// values, shaded like a sphere lit from the top left, and a line of light in the seam. Same constants and
// hash as the site, so the mark on the rendered MacBook is the mark on the page.
(function () {
  'use strict';
  const SEAM_LEN = Math.hypot(1, 3), SD = [1 / SEAM_LEN, -3 / SEAM_LEN], SN = [3 / SEAM_LEN, 1 / SEAM_LEN];
  const GAP = 3 / 19, SLIDE = 6 / 19;
  const LIGHT = (() => { const v = [-0.42, -0.58, 0.7], l = Math.hypot(v[0], v[1], v[2]); return v.map((x) => x / l); })();
  const TOKENS = [
    [[-0.42, -0.66, 'de-DE'], [-0.08, -0.84, 'Europe/Berlin'], [0.3, -0.72, 'cookies'], [0.62, -0.46, 'store']],
    [[-0.58, 0.2, 'en-US'], [-0.24, 0.1, 'America/New_York'], [0.14, 0.08, 'cookies'], [0.5, 0.06, 'ads']],
  ];
  const HALF_RGB = ['226,231,240', '196,211,255'];
  const EDGE_RGB = '160,184,252';
  const MONO = '"DejaVu Sans Mono", "SF Mono", ui-monospace, Menlo, monospace';
  const hash = (a, b, c) => { let h = (a * 73856093) ^ (b * 19349663) ^ (c * 83492791); h = Math.imul(h ^ (h >>> 13), 1274126177); return (h ^ (h >>> 16)) >>> 0; };
  const smooth = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x));

  /// The offset of each half's centre from the disc's centre, in radii (half 1 = +o, half 0 = -o).
  const OFF = [GAP / 2 * SN[0] + SLIDE / 2 * SD[0], GAP / 2 * SN[1] + SLIDE / 2 * SD[1]];

  function tokenMaps(L, cw) {
    return TOKENS.map((list) => {
      const m = new Map();
      list.forEach(([v, u, s]) => {
        const r0 = Math.round(v * L.R / L.LH), c0 = Math.round(u * L.R / cw);
        m.set(r0 * 10000 + c0 - 1, ' '); m.set(r0 * 10000 + c0 + s.length, ' ');
        for (let k = 0; k < s.length; k++) m.set(r0 * 10000 + c0 + k, s[k]);
      });
      return m;
    });
  }

  /// Paints halves onto ctx (already scaled to local px). L = {cx, cy, R, LH}; cw = character width.
  /// which: halves drawn in full; ghost: alpha of the left half's empty place (0 = none); gain: brightness.
  function paintHalves(ctx, cw, L, opts) {
    eachChar(cw, L, opts, (ch, x, y, a, rgb) => { ctx.fillStyle = `rgba(${rgb},${Math.min(1, a).toFixed(3)})`; ctx.fillText(ch, x, y); });
  }
  /// Every character of the figure: fn(char, x (left), y (middle), alpha, "r,g,b", {qx, qy, half}) with qx, qy
  /// the position in the half's own unit disc.
  function eachChar(cw, L, { which = [0, 1], ghost = 0, gain = 1, tokens = null }, fn) {
    const { cx, cy, R, LH } = L;
    const [ox, oy] = OFF;
    const i0 = Math.max(0, Math.floor((cx - 1.3 * R) / cw)), i1 = Math.ceil((cx + 1.3 * R) / cw);
    const j0 = Math.max(0, Math.floor((cy - 1.3 * R) / LH)), j1 = Math.ceil((cy + 1.3 * R) / LH);
    for (let j = j0; j <= j1; j++) {
      const py = (j + 0.5) * LH;
      for (let i = i0; i <= i1; i++) {
        const px = (i + 0.5) * cw, x = (px - cx) / R, y = (py - cy) / R;
        let half = -1, qx = x - ox, qy = y - oy;
        if (qx * qx + qy * qy <= 1 && qx * SN[0] + qy * SN[1] >= 0) half = 1;
        else { qx = x + ox; qy = y + oy; if (qx * qx + qy * qy <= 1 && qx * SN[0] + qy * SN[1] <= 0) half = 0; }
        if (half < 0) continue;
        const faint = ghost > 0 && half === 0 && !which.includes(0);
        if (!which.includes(half) && !faint) continue;
        const r2 = qx * qx + qy * qy, z = Math.sqrt(1 - r2);
        const shade = Math.max(0, qx * LIGHT[0] + qy * LIGHT[1] + z * LIGHT[2]);
        const lc = Math.round(qx * R / cw), lr = Math.round(qy * R / LH);
        const h = hash(lc, lr, half);
        const fromSeam = Math.abs(qx * SN[0] + qy * SN[1]) * R;
        const edge = fromSeam < cw * 1.4;
        const tk = tokens && tokens[half].get(lr * 10000 + lc);
        if (tk === ' ') continue;
        let a = 0.07 + 0.86 * Math.pow(shade, 1.9) + 0.22 * Math.pow(shade, 14) + ((h >>> 9) & 15) / 160 - 0.045;
        if (r2 > 0.92) a += 0.08;
        if (edge) a += 0.25;
        if (tk) a += 0.12;
        a *= gain;
        let rgb = edge ? EDGE_RGB : HALF_RGB[half];
        if (faint) { a *= 0.16 * ghost; rgb = '130,150,215'; }
        if (a < 0.03) continue;
        fn(tk || ((h >>> 3) & 1 ? '1' : '0'), i * cw, py, a, rgb, { qx, qy, half });
      }
    }
  }

  /// The seam: a line of light along the cut, from -len to +len radii; width scales with the radius.
  function paintSeam(ctx, L, len, alpha, k = 1) {
    if (len <= 0 || alpha <= 0) return;
    const { cx, cy, R } = L, l = R * 1.02 * len;
    const line = () => { ctx.beginPath(); ctx.moveTo(cx - SD[0] * l, cy - SD[1] * l); ctx.lineTo(cx + SD[0] * l, cy + SD[1] * l); ctx.stroke(); };
    ctx.save();
    ctx.lineCap = 'round'; ctx.shadowColor = 'rgba(111,143,234,0.9)';
    ctx.shadowBlur = 22 * k; ctx.lineWidth = 6 * k; ctx.strokeStyle = `rgba(111,143,234,${(0.22 * alpha).toFixed(3)})`; line();
    ctx.shadowBlur = 7 * k; ctx.lineWidth = 1.2 * k; ctx.strokeStyle = `rgba(178,198,255,${(0.92 * alpha).toFixed(3)})`; line();
    ctx.restore();
  }

  window.CodeArt = { eachChar, paintHalves, paintSeam, tokenMaps, MONO, OFF, SD, SN, smooth };
})();
