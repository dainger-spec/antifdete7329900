// Shared by chrome_lab.mjs (runs in a real Chromium page) and webkit_sim.mjs (an emulated canvas with
// WebKit-on-Cocoa vImage formulas). `engine` gives the NATIVE canvas operations; `rt` is the engine's
// round trip table rt[a*256+v] = unpremul(premul(v,a),a) (Chromium: measured; WebKit: vImage formulas).
function makeLab(engine, rt) {
  function fpHash(text, salt) {
    let h = (2166136261 ^ salt) >>> 0;
    for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 16777619); }
    return h >>> 0;
  }
  function fpMix(seed, index, value) {
    let h = (Math.imul((seed ^ index) >>> 0, 2654435761) ^ Math.imul(value | 0, 40503)) >>> 0;
    h ^= h >>> 15; h = Math.imul(h, 2246822507) >>> 0; h ^= h >>> 13; h = Math.imul(h, 3266489909) >>> 0; h ^= h >>> 16;
    return h >>> 0;
  }
  // representable values per alpha, ascending: R[a][p] = unpremul(p, a); and premul via lookup
  const R = [], P = [];
  for (let a = 0; a < 256; a++) {
    const s = new Set(); for (let v = 0; v < 256; v++) s.add(rt[a * 256 + v]);
    R[a] = [...s].sort((x, y) => x - y);
    const m = new Int16Array(256).fill(-1); R[a].forEach((u, p) => { m[u] = p; }); P[a] = m;
  }
  const premulT = (u, a) => P[a][rt[a * 256 + u]];
  const unpremulT = (p, a) => R[a][Math.min(p, R[a].length - 1)];
  const isFixed = (v, a) => rt[a * 256 + v] === v;
  // premultiply of ANY value (not only representable ones): nearest representable index at alpha a
  const premulT0 = (u, a) => P[a][rt[a * 256 + u]];   // the engine's premultiply of any u

  // key: what index feeds the hash. 'index' = position inside the returned ImageData (shipping code),
  // 'abs' = position in the canvas, 'content' = none (the pixel's value only).
  function keyOf(mode, i, ctx) {
    if (mode === 'content') return 0;
    if (mode === 'abs') { const p = i >> 2; return (((ctx.sy + ((p / ctx.w) | 0)) & 0xffff) << 16 | ((ctx.sx + (p % ctx.w)) & 0xffff)) >>> 0; }
    return i >> 2;
  }
  // The shipping noise (fingerprint.js / fp_patch.js), with an optional filter on the written value.
  function noiseU(data, seed, ctx, opts) {
    for (let i = 0; i < data.length; i += 4) {
      const a = data[i + 3];
      if (opts.opaqueOnly ? a !== 255 : (a === 0 || a === 255)) continue;
      const base = (data[i] & 0xfe) | ((data[i + 1] & 0xfe) << 8) | ((data[i + 2] & 0xfe) << 16) | (a << 24);
      const h = fpMix(seed, keyOf(opts.key, i, ctx), base);
      if (h % 5 !== 0) continue;
      const channel = i + ((h >>> 8) % 3);
      const v = (data[channel] & 0xfe) | ((h >>> 16) & 1);
      if (opts.onlyFixed && !isFixed(v, a)) continue;          // (b)
      data[channel] = opts.snap ? rt[a * 256 + v] : v;         // (a)
    }
    return data;
  }
  // (p) noise in premultiplied space: the decision ignores the low bit of the premultiplied values
  function noiseP(data, seed, ctx, opts) {
    for (let i = 0; i < data.length; i += 4) {
      const a = data[i + 3];
      if (a === 0 || a === 255) continue;
      const p0 = premulT(data[i], a), p1 = premulT(data[i + 1], a), p2 = premulT(data[i + 2], a);
      const base = (p0 & 0xfe) | ((p1 & 0xfe) << 8) | ((p2 & 0xfe) << 16) | (a << 24);
      const h = fpMix(seed, keyOf(opts.key, i, ctx), base);
      if (h % 5 !== 0) continue;
      const c = (h >>> 8) % 3;
      const p = [p0, p1, p2][c];
      let q = (p & 0xfe) | ((h >>> 16) & 1);
      if (q > a) q = p & 0xfe;
      data[i + c] = unpremulT(q, a);
    }
    return data;
  }
  // (q) noise the coverage (alpha) instead of a colour channel: a pixel's alpha class (a>>1) and the
  // seed decide; the alpha's low bit is set; the colour is re-quantised at the new alpha (premultiply,
  // unpremultiply). Black stays black, white stays white; every value is one the engine can return.
  function noiseQ(data, seed, ctx, opts) {
    for (let i = 0; i < data.length; i += 4) {
      const a = data[i + 3];
      if (a === 0 || a === 255) continue;
      const base = opts.key === 'content' ? (a >> 1) : (a >> 1);
      const h = fpMix(seed, opts.key === 'content' ? 0 : keyOf(opts.key, i, ctx), base);
      if (h % 5 !== 0) continue;
      const b = (a & 0xfe) | ((h >>> 16) & 1);
      if (b === a || b === 0 || b === 255) continue;
      for (let k = 0; k < 3; k++) data[i + k] = unpremulT(premulT0(data[i + k], b), b);
      data[i + 3] = b;
    }
    return data;
  }
  const variants = {
    off: null,
    cur: { noise: noiseU, opts: {} },
    a_snap: { noise: noiseU, opts: { snap: true } },
    b_fixed: { noise: noiseU, opts: { onlyFixed: true } },
    c_readback: { noise: noiseU, opts: {}, readback: true },
    e_engine: { noise: noiseU, opts: {}, engineFilter: true },
    d_opaque: { noise: noiseU, opts: { opaqueOnly: true } },
    p_premul: { noise: noiseP, opts: {} },
    q_alpha: { noise: noiseQ, opts: { key: 'content' } },
    'q_alpha+index': { noise: noiseQ, opts: { key: 'index' } },
  };
  for (const k of ['cur', 'b_fixed', 'e_engine', 'p_premul']) {
    variants[k + '+abs'] = { ...variants[k], opts: { ...variants[k].opts, key: 'abs' } };
    variants[k + '+content'] = { ...variants[k], opts: { ...variants[k].opts, key: 'content' } };
  }

  function makeShim(name, seedText) {
    const v = variants[name];
    const seed = fpHash(String(seedText), 7);
    if (!v) return { get: (c, sx, sy, sw, sh) => engine.get(c, sx, sy, sw, sh), encode: (c) => engine.encode(c) };
    const fill = (img, sx, sy) => {
      const ctx = { sx, sy, w: img.width };
      if (v.engineFilter) {     // (e): keep only what the engine's own round trip keeps
        const orig = new Uint8ClampedArray(img.data);
        v.noise(img.data, seed, ctx, v.opts);
        const scratch = engine.create(img.width, img.height);
        engine.put(scratch, img, 0, 0);
        const back = engine.get(scratch, 0, 0, img.width, img.height).data;
        const d = img.data;
        for (let i = 0; i < d.length; i += 4) {
          if (d[i] !== back[i] || d[i + 1] !== back[i + 1] || d[i + 2] !== back[i + 2]) { d[i] = orig[i]; d[i + 1] = orig[i + 1]; d[i + 2] = orig[i + 2]; }
        }
        return img;
      }
      v.noise(img.data, seed, ctx, v.opts);
      if (v.readback) {          // (c): return what the engine stores of the noised pixels
        const scratch = engine.create(img.width, img.height);
        engine.put(scratch, img, 0, 0);
        const back = engine.get(scratch, 0, 0, img.width, img.height);
        img.data.set(back.data);
      }
      return img;
    };
    return {
      get(c, sx, sy, sw, sh) { const img = engine.get(c, sx, sy, sw, sh); return fill(img, sx, sy); },
      encode(c) {
        const copy = engine.create(c.width, c.height);
        engine.draw(copy, c, 0, 0);
        const img = engine.get(copy, 0, 0, c.width, c.height);
        fill(img, 0, 0);
        engine.put(copy, img, 0, 0);
        return engine.encode(copy);
      },
    };
  }

  const fnv = (d) => { let h = 0x811c9dc5; for (let i = 0; i < d.length; i++) { h ^= d[i]; h = Math.imul(h, 0x01000193); } return (h >>> 0).toString(16).padStart(8, '0'); };
  const diff = (x, y) => { let n = 0; for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) n++; return n; };

  // Detectors: a page that has only the hooked get/encode plus native draw/put/create/decode.
  async function detect(shim, c1) {
    const W = c1.width, H = c1.height, out = {};
    const read = shim.get(c1, 0, 0, W, H).data;
    out.readHash = fnv(read);
    const png = shim.encode(c1);
    out.png = png;
    out.read = read;
    // D1: the probe (PNG drawn back into a canvas, read with the hooked getImageData)
    const img = await engine.decode(png);
    const c2 = engine.create(W, H); engine.draw(c2, img, 0, 0);
    out.D1_probe = diff(shim.get(c2, 0, 0, W, H).data, read);
    // D3: read twice; encode twice
    out.D3_readTwice = diff(shim.get(c1, 0, 0, W, H).data, read);
    out.D3_encodeTwice = shim.encode(c1) === png ? 0 : 1;
    // D4: a sub-rectangle read against the same pixels of the full read
    { const sx = 37, sy = 9, sw = 120, sh = 33; const s = shim.get(c1, sx, sy, sw, sh).data; let n = 0;
      for (let y = 0; y < sh; y++) for (let x = 0; x < sw; x++) for (let k = 0; k < 4; k++) if (s[(y * sw + x) * 4 + k] !== read[((sy + y) * W + sx + x) * 4 + k]) n++;
      out.D4_subrect = n; }
    // D5: put the read data into a new canvas and read it again
    { const c3 = engine.create(W, H); const im = engine.imageData(W, H); im.data.set(read); engine.put(c3, im, 0, 0);
      out.D5_putRead = diff(shim.get(c3, 0, 0, W, H).data, read); }
    // D6: values getImageData can never return (not fixed points of the engine's round trip)
    { let n = 0; for (let i = 0; i < read.length; i += 4) { const a = read[i + 3]; for (let k = 0; k < 3; k++) if (!isFixed(read[i + k], a)) n++; } out.D6_unrepresentable = n; }
    // D7: drawImage at (1,0) into another canvas, compare shifted
    { const c4 = engine.create(W + 1, H); engine.draw(c4, c1, 1, 0); const s = shim.get(c4, 0, 0, W + 1, H).data; let n = 0;
      for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) for (let k = 0; k < 4; k++) if (s[(y * (W + 1) + x + 1) * 4 + k] !== read[(y * W + x) * 4 + k]) n++;
      out.D7_translate = n; }
    // D8: known semi-transparent, representable pixels put and read back
    { const w = 256, h = 64, c5 = engine.create(w, h), im = engine.imageData(w, h); let i = 0;
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++, i += 4) { const a = 1 + ((y * 4 + (x >> 6)) % 254); const r = R[a]; im.data[i] = r[(x * 7) % r.length]; im.data[i + 1] = r[(x * 13 + y) % r.length]; im.data[i + 2] = r[(x * 3 + 5 * y) % r.length]; im.data[i + 3] = a; }
      engine.put(c5, im, 0, 0); out.D8_knownSemi = diff(shim.get(c5, 0, 0, w, h).data, im.data); }
    // D9: solid fill / opaque pattern
    { const w = 16, h = 16, c6 = engine.create(w, h), im = engine.imageData(w, h);
      for (let i = 0; i < im.data.length; i += 4) { im.data[i] = (i * 7) & 255; im.data[i + 1] = (i * 13) & 255; im.data[i + 2] = (i * 3) & 255; im.data[i + 3] = 255; }
      engine.put(c6, im, 0, 0); out.D9_opaque = diff(shim.get(c6, 0, 0, w, h).data, im.data); }
    // D10: colour constancy. Black, white and #069 drawn with the coverage of the probe drawing: a real
    // engine gives rgb (0,0,0), (255,255,255) and r = 0 at every partly transparent pixel.
    if (engine.withCoverage) {
      let n = 0;
      for (const col of [[0, 0, 0], [255, 255, 255], [0, 102, 153]]) {
        const c7 = engine.withCoverage(c1, col); const d = shim.get(c7, 0, 0, W, H).data;
        for (let i = 0; i < d.length; i += 4) { const a = d[i + 3]; if (!a || a === 255) continue;
          for (let k = 0; k < 3; k++) if ((col[k] === 0 && d[i + k] !== 0) || (col[k] === 255 && d[i + k] !== 255)) n++; }
      }
      out.D10_colourConstancy = n;
    }
    return out;
  }
  return { makeShim, detect, variants, fnv, diff, isFixed, rt, R, premulT, unpremulT };
}
if (typeof module !== 'undefined') module.exports = { makeLab };
