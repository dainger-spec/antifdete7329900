// Home scene "encryption": the sealed window's ciphertext closes into a block, and the block is carved into a
// lock drawn in code (canvas). Two clean beats, never two glyphs on one place:
//   1. The window's chrome falls away. Each line of ciphertext stays one intact string (one fillText) and
//      slides, as a rigid row, onto the lock's grid: its type eases from the window's size to the grid's,
//      and the fade at its end opens to the block's width. New rows fade in between them on the same grid,
//      so the lines close into a clean rectangle of base64.
//   2. A front at the angle of the seam (1 : 3) — the same light that sealed the data — crosses the block.
//      Behind it, cells outside the lock are gone and cells inside take their light: the lock is lit from
//      the top left like the mark, with a domed face, a complete rim, a polished tube for the shackle, a
//      keyhole cut as clean empty cells with a pinpoint of light in it, and a few readable tokens in its
//      body the way the mark carries its values. The lock keeps the block's characters: base64, which is
//      what is really on the disk.
// The block, the new rows and the lit lock are drawn once per layout into small offscreen canvases; a frame
// only composites them (and ten lines). Everything follows the scroll; nothing moves when the page is still.
// Without scenes (Reduce Motion, shots) the lock is drawn once, finished, beside the window.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  const sec = document.querySelector('.sc-encryption');
  if (!sec) return;
  const stage = sec.querySelector('.enc-stage');
  const cv = sec.querySelector('.enc-cv');
  const box = sec.querySelector('.enc-lockbox');
  const foot = sec.querySelector('.enc-foot');
  if (!stage || !cv || !cv.getContext) return;

  const { clamp01, smooth, easeInOut } = api;
  const [F0, F1] = (stage.dataset.r || '0.42 0.7').split(' ').map(Number);
  // The beats, in the stage's own progress (0…1 over F0…F1).
  const T = { move: 0.04, moveLen: 0.36, stagger: 0.07, fill: [0.26, 0.46], carve: [0.47, 0.98], glow: [0.84, 1] };

  const L = (() => { const v = [-0.45, -0.62, 0.64], l = Math.hypot(v[0], v[1], v[2]); return v.map((x) => x / l); })();
  const SEALED = [132, 156, 214], BODY = [228, 233, 242], SHACKLE = [204, 216, 252], EDGE = [168, 190, 252];
  const A_BLOCK = 0.5;
  const SN = [3 / Math.hypot(3, 1), 1 / Math.hypot(3, 1)];
  const hash = (a, b, c) => { let h = (a * 73856093) ^ (b * 19349663) ^ (c * 83492791); h = Math.imul(h ^ (h >>> 13), 1274126177); return (h ^ (h >>> 16)) >>> 0; };
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function cipher(seed, n) {
    let s = seed >>> 0, out = '';
    for (let i = 0; i < n; i++) {
      s = (s + 0x6D2B79F5) >>> 0;
      let t = Math.imul(s ^ (s >>> 15), 1 | s);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      out += B64[((t ^ (t >>> 14)) >>> 0) % 64];
    }
    return out;
  }

  // The lock, in units of its height, centred on (0, 0): a rounded body, a shackle (a tube of radius rt
  // around an arch of radius rs), a keyhole a little above the body's middle.
  const G = { bw: 0.8, bh: 0.56, rc: 0.085, rs: 0.212, rt: 0.07, bevel: 0.06, keyR: 0.066, slot: 0.16, slotW: 0.026 };
  G.bodyCy = 0.5 - G.bh / 2; G.bodyTop = 0.5 - G.bh;
  G.arcCy = -0.5 + G.rt + G.rs;
  // A few of the lock's own values, set into its body like the mark's: [row, first column] in units of height.
  const TOKENS = [[0.025, -0.31, 'vault.seal'], [0.095, 0.075, 'aes-256-gcm'], [0.3, -0.31, 'argon2id'], [0.4, 0.11, 'store']];

  function sdBody(u, v) {
    const qx = Math.abs(u) - (G.bw / 2 - G.rc), qy = Math.abs(v - G.bodyCy) - (G.bh / 2 - G.rc);
    return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - G.rc;
  }

  let ctx = null, W = 0, H = 0, dpr = 1, mono = 'monospace', fsL = 10, cw = 6, LH = 12, base = 0;
  let geo = null, lines = [], tokens = [], imgs = null, scratch = null, last = -2, lastP = 0;
  const rgba = (rgb, a) => `rgba(${rgb[0] | 0},${rgb[1] | 0},${rgb[2] | 0},${Math.max(0, Math.min(1, a)).toFixed(3)})`;
  function parseRGBA(s) {
    const m = String(s).match(/rgba?\(([^)]+)\)/);
    if (!m) return { rgb: SEALED, a: 0.6 };
    const p = m[1].split(',').map(parseFloat);
    return { rgb: [p[0], p[1], p[2]], a: p.length > 3 ? p[3] : 1 };
  }
  const offscreen = (w, h) => { const c = document.createElement('canvas'); c.width = Math.max(1, Math.ceil(w * dpr)); c.height = Math.max(1, Math.ceil(h * dpr)); return c; };

  /// The lock at a cell: null outside, 'hole' in the keyhole, else its light and colour.
  function look(u, v, h, key) {
    const grain = ((h >>> 9) & 15) / 160 - 0.045;
    const d = sdBody(u, v);
    if (d <= 0) {
      if (key(u, v)) return 'hole';
      const e = -d;
      // The face is domed a little, so the light falls off from the top left to the bottom right; near the
      // edge it turns over a soft bevel.
      let nx = u * 1.05, ny = (v - G.bodyCy) * 1.25, nz = 1;
      if (e < G.bevel) {
        const s = 0.003, gx = sdBody(u + s, v) - sdBody(u - s, v), gy = sdBody(u, v + s) - sdBody(u, v - s), gl = Math.hypot(gx, gy) || 1;
        const tilt = Math.pow(1 - e / G.bevel, 1.6);
        nx += (gx / gl) * tilt * 1.9; ny += (gy / gl) * tilt * 1.9; nz = Math.max(0.1, 1 - tilt * 0.8);
      }
      const nl = Math.hypot(nx, ny, nz);
      const sh = Math.max(0, (nx * L[0] + ny * L[1] + nz * L[2]) / nl);
      const a = 0.08 + 0.9 * Math.pow(sh, 2.1) + 0.26 * Math.pow(sh, 14) + grain;
      // Never lost on the side away from the light: the body stays whole.
      return { a: Math.max(0.2 + grain * 0.5, a), rgb: BODY, part: 0 };
    }
    if (v < G.bodyTop + 0.04) {
      let dl, dx, dy;
      if (v <= G.arcCy) { const r = Math.hypot(u, v - G.arcCy) || 1e-6; dl = r - G.rs; dx = u / r; dy = (v - G.arcCy) / r; }
      else { dl = Math.abs(u) - G.rs; dx = Math.sign(u) || 1; dy = 0; }
      if (Math.abs(dl) >= G.rt) return null;
      const t = dl / G.rt, nz = Math.sqrt(Math.max(0, 1 - t * t));
      const sh = Math.max(0, dx * t * L[0] + dy * t * L[1] + nz * L[2]);
      let a = 0.1 + 0.84 * Math.pow(sh, 2.4) + 0.5 * Math.pow(sh, 22) + grain;
      a = Math.max(0.18 + grain * 0.5, a);
      // A little shadow where the shackle goes into the body.
      if (v > G.bodyTop - 0.05) a *= 0.45 + 0.55 * clamp01((G.bodyTop - v) / 0.05);
      return { a, rgb: SHACKLE, part: 1 };
    }
    return null;
  }

  /// The sealed window's lines of ciphertext, where they stand on the canvas (one per field).
  function readLines(sr) {
    const out = [];
    sec.querySelectorAll('.enc-sealed .ct').forEach((el) => {
      const r = el.getBoundingClientRect();
      const cs = getComputedStyle(el);
      const fs = parseFloat(cs.fontSize), lh = parseFloat(cs.lineHeight) || r.height;
      ctx.font = `${fs}px ${mono}`;
      const m = ctx.measureText('0');
      const fa = m.fontBoundingBoxAscent || fs * 0.8, fd = m.fontBoundingBoxDescent || fs * 0.2;
      const col = parseRGBA(cs.color);
      out.push({
        text: el.textContent, fs, x: r.left - sr.left, w: r.width,
        yb: r.top - sr.top + (lh - (fa + fd)) / 2 + fa, yc: r.top - sr.top + r.height / 2,
        rgb: col.rgb, a: col.a,
      });
    });
    return out;
  }

  function layout() {
    const sr = cv.getBoundingClientRect();
    if (!sr.width || !sr.height) return false;
    dpr = Math.min(2, window.devicePixelRatio || 1);
    W = sr.width; H = sr.height;
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    ctx = cv.getContext('2d');
    ctx.textBaseline = 'alphabetic';
    const ctEl = sec.querySelector('.enc-t.ct');
    mono = (ctEl && getComputedStyle(ctEl).fontFamily) || api.codeart.MONO;

    // Where the lock stands: above the names (playing) or in its box beside the window (still).
    let area;
    if (api.scenesOn) {
      const bottom = (foot ? foot.offsetTop - stage.offsetTop : H) - (W < 600 ? 26 : 34);
      area = { x: 0, y: 0, w: W, h: Math.max(120, bottom) };
    } else {
      if (!box) return false;
      const br = box.getBoundingClientRect();
      if (!br.width) return false;
      area = { x: br.left - sr.left, y: br.top - sr.top, w: br.width, h: br.height };
    }
    const H0 = Math.min(area.h, area.w * 1.05, 420);
    fsL = Math.max(8, Math.min(11.5, H0 / (W < 600 ? 30 : 34)));
    const Hl = Math.min(H0, area.h - fsL * 1.6);
    ctx.font = `${fsL}px ${mono}`;
    const m0 = ctx.measureText('0');
    cw = m0.width; LH = Math.round(fsL * 1.24 * 2) / 2;
    const fa = m0.fontBoundingBoxAscent || fsL * 0.8, fd = m0.fontBoundingBoxDescent || fsL * 0.2;
    base = (fa - fd) / 2; // from a row's centre to its baseline
    const cx = Math.round(area.x + area.w / 2), cy = Math.round(area.y + area.h / 2);

    // The grid: columns c and rows r counted from the lock's centre, so the lock is symmetric.
    const C = Math.ceil((G.bw / 2) * Hl / cw), R = Math.floor((Hl / 2) / LH);
    const cMin = -C, cMax = C, rMin = -R, rMax = R;
    const nC = cMax - cMin + 1, nR = rMax - rMin + 1;
    const X = (c) => cx + c * cw - cw / 2; // a glyph's left edge
    const Y = (r) => cy + r * LH; // a row's centre
    // The keyhole: a round head and a slot, centred on a row and on the middle column.
    // The shape sits half a row inside the grid's top row, so the arch's top is a full run of cells.
    const sh = R * LH - Hl / 2 + LH / 2;
    const vOf = (r) => (r * LH + sh) / Hl;
    const keyRow = Math.round(((G.bodyCy - 0.05) * Hl - sh) / LH), keyCy = vOf(keyRow);
    const key = (u, v) => {
      const dv = v - keyCy;
      if (Math.hypot(u * 0.92, dv) <= G.keyR) return true;
      return dv > 0 && dv < G.slot && Math.abs(u) <= G.slotW + dv * 0.09;
    };
    const cells = new Map();
    for (let r = rMin; r <= rMax; r++) {
      for (let c = cMin; c <= cMax; c++) {
        const h = hash(c, r, 11);
        const s = look(c * cw / Hl, vOf(r), h, key);
        if (s) cells.set(r * 1000 + c, s);
      }
    }
    // The rim: every cell at the lock's outline gets a little more light and the edge colour, so the shape is
    // complete on the side away from the light too. Round the keyhole the edge facing the light is lit and
    // the one facing away is in shade.
    const inLock = (r, c) => { const s = cells.get(r * 1000 + c); return s && s !== 'hole'; };
    const isHole = (r, c) => cells.get(r * 1000 + c) === 'hole';
    cells.forEach((s, k) => {
      if (s === 'hole') return;
      const r = Math.round(k / 1000), c = k - r * 1000;
      const out = !inLock(r - 1, c) && !isHole(r - 1, c) || !inLock(r + 1, c) && !isHole(r + 1, c) || !inLock(r, c - 1) && !isHole(r, c - 1) || !inLock(r, c + 1) && !isHole(r, c + 1);
      const hl = isHole(r - 1, c) || isHole(r, c - 1) || isHole(r - 1, c - 1); // the hole is above / left: its far wall
      const hn = isHole(r + 1, c) || isHole(r, c + 1) || isHole(r + 1, c + 1); // the hole is below / right: its near wall
      if (out) { s.a = Math.max(s.a, 0.34) + 0.1; s.rgb = EDGE; }
      if (hl) { s.a = Math.max(s.a, 0.42) + 0.22; s.rgb = EDGE; }
      else if (hn) s.a *= 0.62;
    });

    // The block: one string per row. The window's lines take the rows at their relative height; the rows
    // between them are new.
    lines = readLines(sr);
    const rowText = new Map();
    if (lines.length) {
      const y0 = lines[0].yc, y1 = lines[lines.length - 1].yc;
      let prev = -Infinity;
      lines.forEach((l, k) => {
        let r = rMin + Math.round(((l.yc - y0) / (y1 - y0 || 1)) * (nR - 1));
        if (r <= prev) r = prev + 1;
        prev = r; l.r = r;
        let text = l.text;
        if (text.length < nC) text += cipher(4099 + k, nC - text.length);
        l.text = text;
        rowText.set(r, text.slice(0, nC));
      });
    }
    for (let r = rMin; r <= rMax; r++) if (!rowText.has(r)) rowText.set(r, cipher(7001 + (r - rMin) * 131, nC));
    const charAt = (r, c) => rowText.get(r)[c - cMin];

    // The tokens, and the blank cell either side of each.
    tokens = [];
    const tokenAt = new Set();
    TOKENS.forEach(([v, u, s], ti) => {
      const r = Math.round((v * Hl - sh) / LH), c0 = Math.round(u * Hl / cw);
      for (let k = -1; k <= s.length; k++) {
        const c = c0 + k, cell = cells.get(r * 1000 + c);
        if (!cell || cell === 'hole' || c < cMin || c > cMax) continue;
        const ch = k < 0 || k >= s.length ? ' ' : s[k];
        tokens.push({ x: X(c), y: Y(r), ch, b64: charAt(r, c), a: Math.min(1, cell.a + 0.14), rgb: BODY, d: (X(c) + cw / 2) * SN[0] + Y(r) * SN[1], ti });
        tokenAt.add(r * 1000 + c);
      }
    });

    // The images, each the size of the block (and a margin for the glow).
    const pad = 22;
    const bx = X(cMin) - pad, by = Y(rMin) - LH / 2 - pad, bw = nC * cw + pad * 2, bh = nR * LH + pad * 2;
    geo = { cx, cy, Hl, cMin, cMax, rMin, rMax, nC, nR, bx, by, bw, bh, X, Y, keyX: cx, keyY: cy + keyRow * LH, blockW: nC * cw };
    const paint = (fn) => { const c = offscreen(bw, bh), g = c.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, -bx * dpr, -by * dpr); g.font = `${fsL}px ${mono}`; g.textBaseline = 'alphabetic'; fn(g); return c; };
    const lineRows = new Set(lines.map((l) => l.r));
    const fresh = paint((g) => {
      g.fillStyle = rgba(SEALED, A_BLOCK);
      for (let r = rMin; r <= rMax; r++) if (!lineRows.has(r)) g.fillText(rowText.get(r), X(cMin), Y(r) + base);
    });
    const block = paint((g) => {
      g.fillStyle = rgba(SEALED, A_BLOCK);
      for (let r = rMin; r <= rMax; r++) g.fillText(rowText.get(r), X(cMin), Y(r) + base);
      // The tokens' cells are drawn on their own, so a cell never shows two glyphs.
      tokens.forEach((t) => g.clearRect(t.x, t.y - LH / 2, cw, LH));
    });
    const lock = paint((g) => {
      cells.forEach((s, k) => {
        if (s === 'hole' || tokenAt.has(k)) return;
        const r = Math.round(k / 1000), c = k - r * 1000;
        g.fillStyle = rgba(s.rgb, s.a);
        g.fillText(charAt(r, c), X(c), Y(r) + base);
      });
    });
    // A soft glow of the finished lock, made once: blurred where the canvas can blur, else drawn small and
    // scaled up (a cheap blur that works everywhere).
    let bloom = null;
    try {
      const b = offscreen(bw, bh), bg = b.getContext('2d');
      if (typeof bg.filter === 'string') {
        bg.filter = `blur(${Math.round(8 * dpr)}px)`;
        bg.drawImage(lock, 0, 0);
        bg.filter = 'none';
      } else {
        const sm = document.createElement('canvas'); sm.width = Math.max(1, Math.round(b.width / 8)); sm.height = Math.max(1, Math.round(b.height / 8));
        const sg = sm.getContext('2d'); sg.imageSmoothingEnabled = true; sg.drawImage(lock, 0, 0, sm.width, sm.height);
        bg.imageSmoothingEnabled = true; bg.imageSmoothingQuality = 'high'; bg.drawImage(sm, 0, 0, b.width, b.height);
      }
      bloom = b;
    } catch (e) { bloom = null; }
    imgs = { fresh, block, lock, bloom };
    scratch = offscreen(bw, bh);
    last = -2;
    return true;
  }

  const put = (img, alpha = 1, op = 'source-over') => {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = alpha; ctx.globalCompositeOperation = op;
    ctx.drawImage(img, Math.round(geo.bx * dpr), Math.round(geo.by * dpr));
    ctx.globalAlpha = 1; ctx.globalCompositeOperation = 'source-over';
  };
  /// An image through a straight soft edge across the block at the seam's angle: `from` is the alpha behind
  /// the front (towards the top left), `to` ahead of it; `stops` adds a peak (the light on the front).
  function masked(img, front, band, stops) {
    const g = scratch.getContext('2d');
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.globalCompositeOperation = 'source-over';
    g.clearRect(0, 0, scratch.width, scratch.height);
    g.drawImage(img, 0, 0);
    g.setTransform(dpr, 0, 0, dpr, -geo.bx * dpr, -geo.by * dpr);
    const a = front - band / 2, b = front + band / 2;
    const gr = g.createLinearGradient(a * SN[0], a * SN[1], b * SN[0], b * SN[1]);
    stops.forEach(([o, al]) => gr.addColorStop(o, `rgba(0,0,0,${al})`));
    g.globalCompositeOperation = 'destination-in';
    g.fillStyle = gr;
    g.fillRect(geo.bx, geo.by, geo.bw, geo.bh);
    g.globalCompositeOperation = 'source-over';
    return scratch;
  }

  function drawTokens(front, band) {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.font = `${fsL}px ${mono}`;
    for (const t of tokens) {
      const m = front === Infinity ? 1 : clamp01(0.5 - (t.d - front) / band); // 1 behind the front
      if (m >= 0.5) { if (t.ch !== ' ') { ctx.fillStyle = rgba(t.rgb, t.a * m); ctx.fillText(t.ch, t.x, t.y + base); } }
      else { ctx.fillStyle = rgba(SEALED, A_BLOCK * (1 - m)); ctx.fillText(t.b64, t.x, t.y + base); }
    }
  }

  /// A pinpoint of light inside the keyhole.
  function keyLight(a) {
    if (a <= 0) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const r = geo.Hl * 0.07, x = geo.keyX, y = geo.keyY;
    const g = ctx.createRadialGradient(x, y, 0, x, y, r);
    g.addColorStop(0, `rgba(178,198,255,${(0.35 * a).toFixed(3)})`);
    g.addColorStop(0.35, `rgba(111,143,234,${(0.16 * a).toFixed(3)})`);
    g.addColorStop(1, 'rgba(47,107,239,0)');
    ctx.fillStyle = g;
    ctx.fillRect(x - r, y - r, r * 2, r * 2);
  }

  function drawLock() {
    if (imgs.bloom) put(imgs.bloom, 0.42);
    put(imgs.lock);
    drawTokens(Infinity, 1);
    keyLight(1);
  }

  function draw(f) {
    if (!ctx || !geo) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1; ctx.globalCompositeOperation = 'source-over';
    ctx.clearRect(0, 0, cv.width, cv.height);
    if (f <= 0) return;
    const glow = smooth((f - T.glow[0]) / (T.glow[1] - T.glow[0]));
    if (f >= 1) { drawLock(); return; }
    const fc = (f - T.carve[0]) / (T.carve[1] - T.carve[0]);
    if (fc <= 0) {
      // Beat 1: the new rows fade in on the grid; the window's lines slide onto it as rigid rows.
      const fa = smooth((f - T.fill[0]) / (T.fill[1] - T.fill[0]));
      if (fa > 0) put(imgs.fresh, fa);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const n = lines.length;
      lines.forEach((l, k) => {
        const u = easeInOut(clamp01((f - T.move - T.stagger * (k / Math.max(1, n - 1))) / T.moveLen));
        const fs = l.fs + (fsL - l.fs) * u;
        const x = l.x + (geo.X(geo.cMin) - l.x) * u;
        const yb = l.yb + (geo.Y(l.r) + base - l.yb) * u;
        const vis = l.w + (geo.blockW - l.w) * u;
        const solid = Math.min(0.999, 0.78 + 0.22 * u);
        const rgb = [0, 1, 2].map((i) => l.rgb[i] + (SEALED[i] - l.rgb[i]) * u);
        const a = l.a + (A_BLOCK - l.a) * u;
        const gr = ctx.createLinearGradient(x, 0, x + vis, 0);
        gr.addColorStop(0, rgba(rgb, a)); gr.addColorStop(solid, rgba(rgb, a)); gr.addColorStop(1, rgba(rgb, 0));
        ctx.font = `${fs.toFixed(3)}px ${mono}`;
        ctx.fillStyle = gr;
        ctx.fillText(l.text, x, yb);
      });
      return;
    }
    // Beat 2: the front crosses the block; behind it the lock, ahead of it the block.
    const corners = [[geo.bx, geo.by], [geo.bx + geo.bw, geo.by], [geo.bx, geo.by + geo.bh], [geo.bx + geo.bw, geo.by + geo.bh]].map(([x, y]) => x * SN[0] + y * SN[1]);
    const band = Math.max(70, geo.Hl * 0.22);
    const d0 = Math.min(...corners) - band / 2, d1 = Math.max(...corners) + band / 2;
    const front = d0 + (d1 - d0) * smooth(clamp01(fc));
    if (imgs.bloom && glow > 0) put(imgs.bloom, 0.42 * glow);
    put(masked(imgs.block, front, band, [[0, 0], [1, 1]]));
    put(masked(imgs.lock, front, band, [[0, 1], [1, 0]]));
    // The light on the front: the lock's own cells, brighter for a moment as it passes.
    put(masked(imgs.lock, front - band * 0.2, band * 0.75, [[0, 0], [0.55, 0.85], [1, 0]]), 1, 'lighter');
    drawTokens(front, band);
    keyLight(glow);
  }

  const flight = (p) => clamp01((p - F0) / (F1 - F0));
  function redraw() {
    if (!layout()) return;
    if (api.scenesOn) { last = flight(lastP); draw(last); } else { drawLock(); }
  }

  if (api.scenesOn) {
    api.onScene('encryption', (p) => {
      lastP = p;
      if (!geo && !layout()) return;
      const f = flight(p);
      if (Math.abs(f - last) < 0.0004) return;
      last = f;
      draw(f);
    });
  }
  // Laid out once the fonts are in (the grid depends on the monospace's width), and again on resize.
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(redraw); else redraw();
  let rt = 0;
  window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(redraw, 150); });
});
