// The Lumen mark in code characters, for the hero renderer (tools/hero/renderer.js). A port of the site's
// painter (prototype/assets/site.js, "Code art"): the split disc of LumenMarkGeometry (radius 19, gap 3,
// slide 6; seam direction (1, -3)), binary in a monospace grid, each half a profile with a few of its own
// values, shaded like a sphere lit from the top left, and a line of light in the seam. Same constants and
// hash as the site, so the mark on the rendered MacBook is the mark on the page.
// LOOKS.neutral is the film's version (spec v2 §5.10): neutral inks, 20 rows, more real profile strings, one
// flat 3 px #2F6BEF seam (paintSeamFlat) and the solid split glyph to cross-fill into (solidPath, paintSolid:
// LumenMarkGeometry, as kit.mjs glyph()). The site keeps the default look.
(function () {
  'use strict';
  const SEAM_LEN = Math.hypot(1, 3), SD = [1 / SEAM_LEN, -3 / SEAM_LEN], SN = [3 / SEAM_LEN, 1 / SEAM_LEN];
  const GAP = 3 / 19, SLIDE = 6 / 19;
  const LIGHT = (() => { const v = [-0.42, -0.58, 0.7], l = Math.hypot(v[0], v[1], v[2]); return v.map((x) => x / l); })();
  const TOKENS = [
    [[-0.42, -0.66, 'de-DE'], [-0.08, -0.84, 'Europe/Berlin'], [0.3, -0.72, 'cookies'], [0.62, -0.46, 'store']],
    [[-0.48, 0.2, 'en-US'], [-0.24, 0.1, 'America/New_York'], [0.14, 0.08, 'cookies'], [0.5, 0.06, 'ads']],
  ];
  const HALF_RGB = ['226,231,240', '196,211,255'];
  const EDGE_RGB = '160,184,252';
  // The film's mark (look 'neutral'): finer (20 rows), neutral inks, 0/1 runs with more of each profile's real
  // values, placed by cell so every string sits whole inside its half at 20 rows. Half 0 (left, the one that
  // lifts out) is the German profile, half 1 the US and Japanese ones.
  const TOKENS_FILM = [
    [[-14 / 20, -22, 'Europe/Berlin'], [-9 / 20, -30, 'de-DE'], [-5 / 20, -16, 'cookies'], [0, -34, 'Europe/Paris'], [5 / 20, -20, 'fr-FR'], [10 / 20, -28, 'nl-NL']],
    [[-12 / 20, 20, 'en-US'], [-7 / 20, 14, 'America/New_York'], [-2 / 20, 24, 'session_id'], [3 / 20, 8, 'ja-JP'], [8 / 20, 16, 'Asia/Tokyo'], [13 / 20, 4, 'en-GB']],
  ].map((list) => list.map(([v, c, s]) => [v, c * 0.024084, s]));   // columns → radii (DejaVu Sans Mono: cw = 0.024084 R at 20 rows)
  /// Looks: the site's hero (blue-white inks, the default) and the film's neutral one.
  const LOOKS = {
    site: { inks: HALF_RGB, edge: EDGE_RGB, ghost: '130,150,215', tokens: TOKENS },
    neutral: { inks: ['200,200,204', '236,236,238'], edge: '236,236,238', ghost: '120,120,124', tokens: TOKENS_FILM, seam: '#2F6BEF', seamPx: 3, solid: '236,236,238', rows: 20 },
  };
  const MONO = '"DejaVu Sans Mono", "SF Mono", ui-monospace, Menlo, monospace';
  const hash = (a, b, c) => { let h = (a * 73856093) ^ (b * 19349663) ^ (c * 83492791); h = Math.imul(h ^ (h >>> 13), 1274126177); return (h ^ (h >>> 16)) >>> 0; };
  const smooth = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x));

  /// The offset of each half's centre from the disc's centre, in radii (half 1 = +o, half 0 = -o).
  const OFF = [GAP / 2 * SN[0] + SLIDE / 2 * SD[0], GAP / 2 * SN[1] + SLIDE / 2 * SD[1]];

  function tokenMaps(L, cw, tokens = TOKENS) {
    return tokens.map((list) => {
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
  /// flat (0..1) eases the sphere shading of half 1 (the one that stays on the display) towards an even
  /// brightness, so the half reads clearly next to the bright floating one; gains = per-half brightness.
  function eachChar(cw, L, { which = [0, 1], ghost = 0, gain = 1, gains = [1, 1], flat = 0, tokens = null, inks = HALF_RGB, edgeRGB = EDGE_RGB, ghostRGB = '130,150,215' }, fn) {
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
        if (flat > 0 && half === 1) a = a + (0.5 + 0.3 * shade + ((h >>> 9) & 15) / 120 + (edge ? 0.25 : 0) + (tk ? 0.12 : 0) - a) * flat;
        a *= gain * gains[half];
        let rgb = edge ? edgeRGB : inks[half];
        if (faint) { a *= 0.16 * ghost; rgb = ghostRGB; }
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

  /// The seam as the film draws it: one flat line (`px` wide on the display canvas, no blur, no shadow).
  function paintSeamFlat(ctx, L, len, alpha, px = 3, color = '#2F6BEF') {
    if (len <= 0 || alpha <= 0) return;
    const { cx, cy, R } = L, l = R * 1.02 * len;
    ctx.save();
    ctx.globalAlpha = Math.min(1, alpha); ctx.lineCap = 'butt'; ctx.lineWidth = px; ctx.strokeStyle = color;
    ctx.beginPath(); ctx.moveTo(cx - SD[0] * l, cy - SD[1] * l); ctx.lineTo(cx + SD[0] * l, cy + SD[1] * l); ctx.stroke();
    ctx.restore();
  }

  /// The solid split disc: LumenMarkGeometry.large (radius 19, gap 3, slide 6 on the 64 grid, seam (1, -3)),
  /// the same construction as the kit's glyphPath (kit.mjs glyph()), scaled so radius 19 = L.R, centred on
  /// (L.cx, L.cy). which: the halves to draw (0 left, 1 right).
  function solidPath(ctx, L, which = [0, 1]) {
    const s = L.R / 19, d = SD, n = [-d[1], d[0]];
    const pos = (a) => { let v = a % (2 * Math.PI); if (v <= 0) v += 2 * Math.PI; return v; };
    ctx.beginPath();
    for (const side of [1, -1]) {
      if (!which.includes(side > 0 ? 1 : 0)) continue;
      const h = side * 1.5, shift = side * 3;
      const c = [L.cx + d[0] * shift * s, L.cy + d[1] * shift * s];
      const half = Math.sqrt(19 * 19 - h * h);
      const a = [n[0] * h - d[0] * half, n[1] * h - d[1] * half], b = [n[0] * h + d[0] * half, n[1] * h + d[1] * half];
      const m = [n[0] * side * 19, n[1] * side * 19];
      const angA = Math.atan2(a[1], a[0]), angB = Math.atan2(b[1], b[0]), angM = Math.atan2(m[1], m[0]);
      const positive = pos(angA - angB);
      const sweep = pos(angM - angB) < positive ? positive : positive - 2 * Math.PI;
      ctx.moveTo(c[0] + a[0] * s, c[1] + a[1] * s); ctx.lineTo(c[0] + b[0] * s, c[1] + b[1] * s);
      ctx.arc(c[0], c[1], 19 * s, angB, angB + sweep, sweep < 0);
      ctx.closePath();
    }
  }
  function paintSolid(ctx, L, alpha, rgb = '236,236,238', which = [0, 1]) {
    if (alpha <= 0) return;
    ctx.save(); ctx.fillStyle = `rgba(${rgb},${Math.min(1, alpha).toFixed(3)})`; solidPath(ctx, L, which); ctx.fill(); ctx.restore();
  }

  window.CodeArt = { eachChar, paintHalves, paintSeam, paintSeamFlat, paintSolid, solidPath, tokenMaps, LOOKS, MONO, OFF, SD, SN, smooth };
})();
