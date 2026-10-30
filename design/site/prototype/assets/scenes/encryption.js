// Home scene "encryption": the sealed card's ciphertext condenses into a lock drawn in code.
// The lock is set in a monospace grid like the mark and lit the same way (one light from the top left): a
// body with a soft bevel and a keyhole that holds a little light, a shackle like a polished tube. Each of
// its characters comes from a character of the card's ciphertext at the same relative place, so the block
// of rows condenses into the lock's silhouette (left first, as the line of light sealed it), and turns from
// base64 into bits as it lands. Everything follows the scroll; nothing moves when the page is still.
// Without scenes (Reduce Motion, shots) the lock is drawn once, finished, beside the card.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  const sec = document.querySelector('.sc-encryption');
  if (!sec) return;
  const stage = sec.querySelector('.enc-stage');
  const cv = sec.querySelector('.enc-cv');
  const box = sec.querySelector('.enc-lockbox');
  const foot = sec.querySelector('.enc-foot');
  if (!stage || !cv) return;

  const { clamp01, smooth, easeInOut } = api;
  const L = (() => { const v = [-0.45, -0.62, 0.64], l = Math.hypot(v[0], v[1], v[2]); return v.map((x) => x / l); })();
  const BODY = [228, 233, 242], SHACKLE = [200, 214, 255], EDGE = [160, 184, 252];
  const hash = (a, b, c) => { let h = (a * 73856093) ^ (b * 19349663) ^ (c * 83492791); h = Math.imul(h ^ (h >>> 13), 1274126177); return (h ^ (h >>> 16)) >>> 0; };
  const [F0, F1] = (stage.dataset.r || '0.56 0.86').split(' ').map(Number);

  // The lock in units of its height, centred on (0, 0).
  const G = { bw: 0.82, bh: 0.57, rc: 0.11, rs: 0.25, rt: 0.078, bevel: 0.07 };
  G.bodyCy = 0.5 - G.bh / 2; G.bodyTop = 0.5 - G.bh;
  G.arcCy = -0.5 + G.rt + G.rs;
  G.keyCy = G.bodyCy - 0.04; G.keyR = 0.066;

  function sdBody(u, v) {
    const qx = Math.abs(u) - (G.bw / 2 - G.rc), qy = Math.abs(v - G.bodyCy) - (G.bh / 2 - G.rc);
    return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - G.rc;
  }
  function sdKey(u, v) {
    const dv = v - G.keyCy;
    const circle = Math.hypot(u, dv) - G.keyR;
    const half = 0.026 + Math.max(0, dv) * 0.12;
    const slot = Math.max(Math.abs(u) - half, Math.max(-dv, dv - 0.16));
    return Math.min(circle, slot);
  }

  /// The lock at (u, v): null outside it, { key: true } in the keyhole, else { a, rgb }.
  function look(u, v, h) {
    const grain = ((h >>> 9) & 15) / 150 - 0.05;
    const d = sdBody(u, v);
    if (d <= 0) {
      const k = sdKey(u, v);
      if (k <= 0) return { key: true };
      const e = -d;
      // The face: domed a little, so the light falls off from the top left to the bottom right.
      let nx = u * 0.55, ny = (v - G.bodyCy) * 0.62, nz = 1;
      let rim = 0;
      if (e < G.bevel) {
        const s = 0.003, gx = sdBody(u + s, v) - sdBody(u - s, v), gy = sdBody(u, v + s) - sdBody(u, v - s), gl = Math.hypot(gx, gy) || 1;
        const tilt = Math.pow(1 - e / G.bevel, 1.5);
        nx += (gx / gl) * tilt * 2.2; ny += (gy / gl) * tilt * 2.2; nz = Math.max(0.04, 1 - tilt * 0.85);
        rim = e < 0.016 ? 1 : 0;
      }
      const nl = Math.hypot(nx, ny, nz);
      const sh = Math.max(0, (nx * L[0] + ny * L[1] + nz * L[2]) / nl);
      let a = 0.03 + 1.02 * Math.pow(sh, 2.3) + 0.4 * Math.pow(sh, 18) + grain;
      // The keyhole's wall: lit on the far side (bottom right), in shadow on the near side.
      if (k < 0.026) { const s = (u * 0.55 + (v - G.keyCy) * 0.8) > 0 ? 0.35 : -0.25; a += s * (1 - k / 0.026); }
      if (rim && sh > 0.35) a += 0.08;
      // Never quite gone: the silhouette stays whole on the side away from the light.
      return { a: Math.max(0.085 + grain * 0.4, a), rgb: rim && sh > 0.5 ? EDGE : BODY };
    }
    if (v < G.bodyTop + 0.05) {
      let dl, dx, dy;
      if (v <= G.arcCy) { const r = Math.hypot(u, v - G.arcCy) || 1e-6; dl = r - G.rs; dx = u / r; dy = (v - G.arcCy) / r; }
      else { dl = Math.abs(u) - G.rs; dx = Math.sign(u) || 1; dy = 0; }
      if (Math.abs(dl) >= G.rt) return null;
      const t = dl / G.rt, nz = Math.sqrt(Math.max(0, 1 - t * t));
      const sh = Math.max(0, dx * t * L[0] + dy * t * L[1] + nz * L[2]);
      let a = 0.03 + 0.9 * Math.pow(sh, 2.5) + 0.6 * Math.pow(sh, 24) + grain;
      // A little shadow where the shackle goes into the body.
      a = Math.max(0.07 + grain * 0.4, a);
      if (v > G.bodyTop - 0.06) a *= 0.35 + 0.65 * clamp01((G.bodyTop - v) / 0.06);
      return { a, rgb: Math.abs(t) > 0.8 && sh > 0.3 ? EDGE : SHACKLE };
    }
    return null;
  }

  let ctx = null, W = 0, H = 0, dpr = 1, fsL = 10, cells = [], ghosts = [], keyAt = null, bloom = null, mono = 'monospace', last = -2, lastP = 0;
  const rgba = (rgb, a) => `rgba(${rgb[0] | 0},${rgb[1] | 0},${rgb[2] | 0},${Math.min(1, a).toFixed(3)})`;
  function parseRGBA(s) {
    const m = String(s).match(/rgba?\(([^)]+)\)/);
    if (!m) return { rgb: [132, 156, 214], a: 0.6 };
    const p = m[1].split(',').map(parseFloat);
    return { rgb: [p[0], p[1], p[2]], a: p.length > 3 ? p[3] : 1 };
  }

  /// The sealed card's ciphertext, character by character, where it stands on the stage: the lines of the
  /// rows, and the two characters in each row's tile (those only fade where they are).
  function lines(sr, tiles) {
    const out = [];
    sec.querySelectorAll('.enc-sealed .ct').forEach((el) => {
      const tile = el.classList.contains('enc-tile');
      const r = el.getBoundingClientRect();
      const cs = getComputedStyle(el);
      const fs = parseFloat(cs.fontSize);
      ctx.font = `${fs}px ${mono}`;
      const cw = ctx.measureText('0').width;
      const col = parseRGBA(cs.color);
      const text = el.textContent;
      const x0 = tile ? r.left + (r.width - cw * text.length) / 2 : r.left;
      const n = tile ? text.length : Math.min(text.length, Math.floor(r.width / cw));
      const glyphs = [];
      for (let k = 0; k < n; k++) {
        const x = x0 + k * cw;
        const fade = tile ? 1 : 1 - clamp01(((x + cw / 2 - r.left) / r.width - 0.78) / 0.22);
        if (fade < 0.04) continue;
        glyphs.push({ x: x - sr.left, y: r.top + r.height / 2 - sr.top, ch: text[k], fs, rgb: col.rgb, a: col.a * fade, n: 0, k, len: n });
      }
      if (!glyphs.length) return;
      if (tile) tiles.push(...glyphs); else out.push(glyphs);
    });
    return out;
  }

  function layout() {
    // Everything is placed relative to the canvas: the whole stage when still, the card's column when
    // playing (fewer pixels to clear and draw on every frame).
    const sr = cv.getBoundingClientRect();
    if (!sr.width || !sr.height) return false;
    dpr = Math.min(2, window.devicePixelRatio || 1);
    W = sr.width; H = sr.height;
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    ctx = cv.getContext('2d');
    ctx.textBaseline = 'middle';
    mono = getComputedStyle(sec.querySelector('.enc-t.ct') || sec).fontFamily || api.codeart.MONO;

    // Where the lock stands: beside the card (still) or above the names (playing).
    let area;
    if (api.scenesOn) {
      const bottom = (foot ? foot.offsetTop - stage.offsetTop : H) - (W < 600 ? 22 : 30);
      area = { x: 0, y: 0, w: W, h: Math.max(80, bottom) };
    } else {
      if (!box) return false;
      const br = box.getBoundingClientRect();
      area = { x: br.left - sr.left, y: br.top - sr.top, w: br.width, h: br.height };
    }
    const Hl = Math.min(area.h, area.w * 1.05, 400);
    const cx = area.x + area.w / 2, cy = area.y + area.h / 2;
    fsL = Math.max(7.5, Math.min(11, Hl / 32));
    ctx.font = `${fsL}px ${mono}`;
    const cw = ctx.measureText('0').width, LH = fsL * 1.2;
    const i0 = Math.floor((cx - (G.bw / 2) * Hl) / cw) - 1, i1 = Math.ceil((cx + (G.bw / 2) * Hl) / cw) + 1;
    const j0 = Math.floor((cy - Hl / 2) / LH) - 1, j1 = Math.ceil((cy + Hl / 2) / LH) + 1;
    cells = [];
    for (let j = j0; j <= j1; j++) {
      const py = (j + 0.5) * LH;
      for (let i = i0; i <= i1; i++) {
        const px = (i + 0.5) * cw, h = hash(i, j, 11);
        const s = look((px - cx) / Hl, (py - cy) / Hl, h);
        if (!s || s.key || s.a < 0.03) continue;
        cells.push({ tx: i * cw, ty: py, a: Math.min(1, s.a), rgb: s.rgb, h, bit: (h >>> 4) & 1 ? '1' : '0' });
      }
    }
    keyAt = { x: cx, y: cy + (G.keyCy + 0.06) * Hl, r: Hl * 0.17 };

    // Each character of the lock takes the card's character at the same relative place: the block of
    // ciphertext condenses into the lock's silhouette.
    const tiles = [];
    const src = api.scenesOn ? lines(sr, tiles) : [];
    ghosts = [];
    if (src.length && cells.length) {
      let tx0 = Infinity, tx1 = -Infinity, ty0 = Infinity, ty1 = -Infinity;
      for (const c of cells) { tx0 = Math.min(tx0, c.tx); tx1 = Math.max(tx1, c.tx); ty0 = Math.min(ty0, c.ty); ty1 = Math.max(ty1, c.ty); }
      const span = 0.86;
      for (const c of cells) {
        const nx = (c.tx - tx0) / (tx1 - tx0 || 1), ny = (c.ty - ty0) / (ty1 - ty0 || 1);
        const line = src[Math.min(src.length - 1, Math.round(ny * (src.length - 1)))];
        const s = line[Math.min(line.length - 1, Math.round(nx * span * (line[0].len - 1)))] || line[line.length - 1];
        c.s = s; s.n++;
        c.d = nx * 0.14 + ((c.h >>> 11) & 31) / 31 * 0.03;
      }
      // Characters no place in the lock asked for go the same way and fade as they arrive; the tiles'
      // characters fade where they are.
      src.forEach((line, li) => line.forEach((g) => {
        if (g.n) return;
        const nx = Math.min(1, g.k / (span * (g.len - 1))), ny = li / Math.max(1, src.length - 1);
        ghosts.push({ s: g, tx: tx0 + nx * (tx1 - tx0), ty: ty0 + ny * (ty1 - ty0), d: nx * 0.14, fly: true });
      }));
      tiles.forEach((g) => ghosts.push({ s: g, tx: g.x, ty: g.y, d: 0, fly: false }));
    }
    // A soft glow of the finished lock, made once.
    bloom = null;
    try {
      const a = document.createElement('canvas'); a.width = cv.width; a.height = cv.height;
      const g = a.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.font = `${fsL}px ${mono}`; g.textBaseline = 'middle';
      for (const c of cells) { g.fillStyle = rgba(c.rgb, c.a); g.fillText(c.bit, c.tx, c.ty); }
      const b = document.createElement('canvas'); b.width = cv.width; b.height = cv.height;
      const bg = b.getContext('2d');
      if ('filter' in bg) { bg.filter = `blur(${Math.round(7 * dpr)}px)`; bg.drawImage(a, 0, 0); bloom = b; }
    } catch (e) { bloom = null; }
    last = -2;
    return true;
  }

  function draw(f) {
    if (!ctx) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, cv.width, cv.height);
    if (f <= 0) return;
    const landed = smooth((f - 0.82) / 0.18);
    if (bloom && landed > 0) { ctx.globalAlpha = 0.5 * landed; ctx.drawImage(bloom, 0, 0); ctx.globalAlpha = 1; }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    // The keyhole holds a little light once the lock is whole.
    if (landed > 0 && keyAt) {
      const g = ctx.createRadialGradient(keyAt.x, keyAt.y, 0, keyAt.x, keyAt.y, keyAt.r);
      g.addColorStop(0, `rgba(170,196,255,${(0.6 * landed).toFixed(3)})`);
      g.addColorStop(0.3, `rgba(111,143,234,${(0.24 * landed).toFixed(3)})`);
      g.addColorStop(1, 'rgba(47,107,239,0)');
      ctx.fillStyle = g;
      ctx.fillRect(keyAt.x - keyAt.r, keyAt.y - keyAt.r, keyAt.r * 2, keyAt.r * 2);
    }
    ctx.font = `${fsL}px ${mono}`;
    const handoff = clamp01(f * 30);
    if (f < 1) {
      for (const g of ghosts) {
        const s = g.s;
        const u = clamp01((f - g.d) / 0.82);
        const ex = easeInOut(clamp01(u / 0.62)), ey = easeInOut(clamp01((u - 0.28) / 0.72));
        const a = s.a * handoff * (g.fly ? 1 - smooth(u / 0.9) : 1 - smooth(f / 0.3));
        if (a < 0.008) continue;
        const x = g.fly ? s.x + (g.tx - s.x) * ex : s.x, y = g.fly ? s.y + (g.ty - s.y) * ey : s.y;
        const sc = g.fly ? (s.fs / fsL) * (1 - (ex + ey) / 2) + (ex + ey) / 2 : s.fs / fsL;
        ctx.setTransform(dpr * sc, 0, 0, dpr * sc, dpr * x, dpr * y);
        ctx.fillStyle = rgba(s.rgb, a);
        ctx.fillText(s.ch, 0, 0);
      }
    }
    for (const c of cells) {
      if (f >= 1 || !c.s) {
        if (!c.s && f < 1) continue;
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.fillStyle = rgba(c.rgb, c.a);
        ctx.fillText(c.bit, c.tx, c.ty);
        continue;
      }
      const s = c.s;
      // First the rows draw in to the lock's width, then they settle into its shape.
      const u = clamp01((f - c.d) / 0.82);
      const ex = easeInOut(clamp01(u / 0.62)), ey = easeInOut(clamp01((u - 0.28) / 0.72));
      const e = (ex + ey) / 2;
      const x = s.x + (c.tx - s.x) * ex, y = s.y + (c.ty - s.y) * ey;
      const sc = (s.fs / fsL) * (1 - e) + e;
      const k = smooth(e);
      const a0 = (s.a / s.n) * handoff;
      // Dimmer in transit, where the drawn-in rows crowd: the lock brightens only as it settles.
      const a = (a0 + (c.a - a0) * k) * (1 - 0.42 * Math.sin(Math.PI * e));
      if (a < 0.008) continue;
      const rgb = [0, 1, 2].map((n) => s.rgb[n] + (c.rgb[n] - s.rgb[n]) * k);
      ctx.setTransform(dpr * sc, 0, 0, dpr * sc, dpr * x, dpr * y);
      ctx.fillStyle = rgba(rgb, a);
      ctx.fillText(e > 0.5 ? c.bit : s.ch, 0, 0);
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  const flight = (p) => clamp01((p - F0) / (F1 - F0));
  function redraw() { if (layout()) { const f = api.scenesOn ? flight(lastP) : 1; draw(f); last = f; } }

  if (api.scenesOn) {
    api.onScene('encryption', (p) => {
      lastP = p;
      if (!ctx && !layout()) return;
      const f = flight(p);
      if (Math.abs(f - last) < 0.0005) return;
      last = f;
      draw(f);
    });
  }
  // Laid out once the fonts are in (the grid depends on the monospace's width), and again on resize.
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(redraw); else redraw();
  let rt = 0;
  window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(redraw, 150); });
});
