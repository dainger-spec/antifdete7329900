// Lumen's drawn pieces, ported from the app so the prototypes show the real thing:
//  - the mark's split disc (LumenMark.swift, LumenMarkGeometry.glyph) — same construction, same
//    arc-to-Bézier conversion;
//  - the continuous-corner tile (SwiftUI RoundedRectangle(style: .continuous)) — approximated with
//    Figma's corner smoothing 0.6, which is close to Apple's curve but not identical;
//  - the profile glyph's palette (Theme.swift, ProfileAvatar) and the country flags (CountryFlag.swift).
// A classic script: prototypes are opened from file://, where module imports are blocked.
(function (L) {
  'use strict';

  // MARK: The mark

  const CUTS = {
    // LumenMarkGeometry.large / .small / .bareSmall
    large: { grid: 64, cx: 32, cy: 32, radius: 19, gap: 3, slide: 6 },
    small: { grid: 16, cx: 8, cy: 8, radius: 5, gap: 2, slide: 2 },
    bareSmall: { grid: 16, cx: 8, cy: 8, radius: 6, gap: 2, slide: 2.5 },
  };
  const SEAM = { dx: 1, dy: -3 }; // one across for three up (y points down)

  function cutForTileSize(size) { return size >= 28 ? CUTS.large : CUTS.small; }
  function cutForBareSize(size) { return size >= 28 ? CUTS.large : CUTS.bareSmall; }

  // PROPOSED: three optical cuts chosen by the size in pixels (points × display scale), not points.
  // Today a 16 pt mark on a Retina screen (32 px) gets the 16-grid cut drawn twice as large: a 4 px
  // seam, 12.5 % of the tile, so the mark reads as a slashed zero; and the jump from 27 to 28 pt changes
  // the seam from 3.4 to 1.3 pt. The 32-grid cut keeps the large mark's proportions (seam ≈ 6 %,
  // slide = 2 × seam) down to 24 px; the 16-grid cut stays for 1× screens.
  const REFINED = {
    tile16: { grid: 16, cx: 8, cy: 8, radius: 5, gap: 2, slide: 2.5 },
    tile32: { grid: 32, cx: 16, cy: 16, radius: 10, gap: 2, slide: 4 },
    tile64: CUTS.large,
    bare16: CUTS.bareSmall,
    bare32: { grid: 32, cx: 16, cy: 16, radius: 12, gap: 2.25, slide: 4.5 },
    bare64: CUTS.large,
  };
  function refinedTileCut(pixels) { return pixels < 24 ? REFINED.tile16 : pixels < 48 ? REFINED.tile32 : REFINED.tile64; }
  function refinedBareCut(pixels) { return pixels < 24 ? REFINED.bare16 : pixels < 48 ? REFINED.bare32 : REFINED.bare64; }

  function positiveAngle(a) {
    let v = a % (2 * Math.PI);
    if (v <= 0) v += 2 * Math.PI;
    return v;
  }

  const f = (n) => (Math.round(n * 1000) / 1000).toString();

  // A circular arc as cubic Béziers of at most 90° each (LumenMarkGeometry.appendArc).
  function arc(cx, cy, r, start, sweep) {
    const segments = Math.max(1, Math.ceil(Math.abs(sweep) / (Math.PI / 2) - 1e-9));
    const step = sweep / segments;
    const k = (4 / 3) * Math.tan(step / 4);
    let d = '';
    for (let i = 0; i < segments; i++) {
      const s = start + step * i, e = s + step;
      const c1x = cx + r * (Math.cos(s) - k * Math.sin(s)), c1y = cy + r * (Math.sin(s) + k * Math.cos(s));
      const c2x = cx + r * (Math.cos(e) + k * Math.sin(e)), c2y = cy + r * (Math.sin(e) - k * Math.cos(e));
      d += `C${f(c1x)} ${f(c1y)} ${f(c2x)} ${f(c2y)} ${f(cx + r * Math.cos(e))} ${f(cy + r * Math.sin(e))}`;
    }
    return d;
  }

  /// Both halves of the disc in the square (x, y, size). `seam` and the cut can be overridden to try
  /// other proportions; the defaults are the app's.
  function glyphPath(cut, x, y, size, seam = SEAM) {
    const scale = size / cut.grid;
    const len = Math.hypot(seam.dx, seam.dy);
    const d = { x: seam.dx / len, y: seam.dy / len };
    const n = { x: -d.y, y: d.x };
    let path = '';
    for (const side of [1, -1]) {
      const h = side * cut.gap / 2;
      const shift = side * cut.slide / 2;
      const c = { x: cut.cx + d.x * shift, y: cut.cy + d.y * shift };
      const half = Math.sqrt(cut.radius * cut.radius - h * h);
      const a = { x: n.x * h - d.x * half, y: n.y * h - d.y * half };
      const b = { x: n.x * h + d.x * half, y: n.y * h + d.y * half };
      const m = { x: n.x * side * cut.radius, y: n.y * side * cut.radius };
      const angleA = Math.atan2(a.y, a.x), angleB = Math.atan2(b.y, b.x), angleM = Math.atan2(m.y, m.x);
      const positive = positiveAngle(angleA - angleB);
      const sweep = positiveAngle(angleM - angleB) < positive ? positive : positive - 2 * Math.PI;
      const P = (v) => ({ x: x + (c.x + v.x) * scale, y: y + (c.y + v.y) * scale });
      const pa = P(a), pb = P(b), pc = P({ x: 0, y: 0 });
      path += `M${f(pa.x)} ${f(pa.y)}L${f(pb.x)} ${f(pb.y)}` + arc(pc.x, pc.y, cut.radius * scale, angleB, sweep) + 'Z';
    }
    return path;
  }

  // MARK: Continuous corners

  /// A rounded rectangle with smoothed ("continuous") corners: Figma's construction
  /// (cubic, circular arc, cubic per corner). smoothing 0.6 ≈ Apple's continuous corner.
  function squirclePath(x, y, w, h, r, smoothing = 0.6) {
    const rad = (deg) => (deg * Math.PI) / 180;
    const budget = Math.min(w, h) / 2;
    let p = Math.min((1 + smoothing) * r, budget);
    let s = smoothing;
    if (p === budget) s = Math.min(s, p / r - 1);
    const arcMeasure = 90 * (1 - s);
    const arcSection = Math.sin(rad(arcMeasure / 2)) * r * Math.SQRT2;
    const alpha = (90 - arcMeasure) / 2;
    const p3p4 = r * Math.tan(rad(alpha / 2));
    const beta = 45 * s;
    const c = p3p4 * Math.cos(rad(beta));
    const d = c * Math.tan(rad(beta));
    const b = (p - arcSection - c - d) / 3;
    const a = 2 * b;
    const A = f(a), AB = f(a + b), ABC = f(a + b + c), C = f(c), D = f(d), BC = f(b + c), S = f(arcSection), R = f(r);
    return [
      `M${f(x + w - p)} ${f(y)}`,
      `c${A} 0 ${AB} 0 ${ABC} ${D}`, `a${R} ${R} 0 0 1 ${S} ${S}`, `c${D} ${C} ${D} ${BC} ${D} ${ABC}`,
      `L${f(x + w)} ${f(y + h - p)}`,
      `c0 ${A} 0 ${AB} ${-d} ${ABC}`, `a${R} ${R} 0 0 1 ${-arcSection} ${S}`, `c${-c} ${D} ${-(b + c)} ${D} ${-(a + b + c)} ${D}`,
      `L${f(x + p)} ${f(y + h)}`,
      `c${-a} 0 ${-(a + b)} 0 ${-(a + b + c)} ${-d}`, `a${R} ${R} 0 0 1 ${-arcSection} ${-arcSection}`, `c${-d} ${-c} ${-d} ${-(b + c)} ${-d} ${-(a + b + c)}`,
      `L${f(x)} ${f(y + p)}`,
      `c0 ${-a} 0 ${-(a + b)} ${D} ${-(a + b + c)}`, `a${R} ${R} 0 0 1 ${S} ${-arcSection}`, `c${C} ${-d} ${BC} ${-d} ${ABC} ${-d}`,
      'Z',
    ].join('');
  }

  /// LumenMark: near-black continuous tile (radius 0.2235 × size), a light ring 12 % (1 pt from 28 pt,
  /// 0.5 pt below), the split disc in the cut for that size.
  function markSVG(size, opts = {}) {
    const tile = opts.tile || '#16181D';
    const glyph = opts.glyph || '#F4F5F7';
    const ring = opts.ring === undefined ? 'rgba(255,255,255,0.12)' : opts.ring;
    const cut = opts.cut || cutForTileSize(size);
    const ringWidth = opts.ringWidth || (size >= 28 ? 1 : 0.5);
    const t = squirclePath(0, 0, size, size, size * 0.2235);
    const inset = ringWidth / 2;
    const ringPath = squirclePath(inset, inset, size - ringWidth, size - ringWidth, size * 0.2235 - inset);
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" aria-hidden="true">` +
      `<path d="${t}" fill="${tile}"/>` +
      (ring ? `<path d="${ringPath}" fill="none" stroke="${ring}" stroke-width="${ringWidth}"/>` : '') +
      `<path d="${glyphPath(cut, 0, 0, size, opts.seam)}" fill="${glyph}"/></svg>`;
  }

  function glyphSVG(size, color = '#F4F5F7', cut) {
    const c = cut || cutForBareSize(size);
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" aria-hidden="true">` +
      `<path d="${glyphPath(c, 0, 0, size)}" fill="${color}"/></svg>`;
  }

  /// LUMEN, `height` points tall (the small cut below 16).
  function wordmarkSVG(height, color = '#ECEEF2') {
    const w = L.WORDMARK[height < 16 ? 'small' : 'regular'];
    const width = (height * w.width) / w.height;
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${f(width)}" height="${height}" viewBox="0 0 ${w.width} ${w.height}" aria-hidden="true">` +
      `<path d="${w.d}" fill="${color}"/></svg>`;
  }

  // MARK: Profile glyphs (ProfileAvatar)

  const PALETTE = [
    { fill: '#273553', text: '#B9C8F0' }, // blue
    { fill: '#243A33', text: '#9FD4BB' }, // green
    { fill: '#3B332A', text: '#E0CDB3' }, // sand
    { fill: '#312C45', text: '#C9BCEB' }, // lavender
    { fill: '#2A2F3A', text: '#C3C9D4' }, // gray
  ];
  /// The sample profiles of UISnapshots.sampleRows: UUID bytes (n,1C,5E,17,0,n,40,0,80,0…,n).
  function sampleAvatarIndex(n) { return (3 * n + 0x1C + 0x5E + 0x17 + 0x40 + 0x80) % PALETTE.length; }
  function keyAvatarIndex(key) {
    let sum = 0;
    for (const byte of new TextEncoder().encode(key)) sum += byte;
    return sum % PALETTE.length;
  }

  // MARK: Flags (CountryFlag.swift, FlagArt)

  const black = '#3A3A3F', white = '#F4F5F7', red = '#D7383B', gold = '#F2C13D';
  const hb = (...c) => ({ bands: c, horizontal: true });
  const vb = (...c) => ({ bands: c, horizontal: false });
  const FLAGS = {
    DE: hb(black, red, gold), NL: hb('#C7333E', white, '#3B5FB0'), AT: hb(red, white, red), RU: hb(white, '#2A5DB0', red),
    UA: hb('#2F6BC1', '#F5CF3A'), PL: hb(white, red), HU: hb(red, white, '#3C8A4E'), BG: hb(white, '#2E8B57', red),
    LT: hb(gold, '#2E7D4F', '#C7333E'), EE: hb('#3A7DD1', black, white), LU: hb(red, white, '#3BA3DB'),
    ES: { bands: [red, gold, red], weights: [1, 2, 1], horizontal: true },
    FR: vb('#2E4FA3', white, red), IT: vb('#2E8B57', white, red), IE: vb('#2E9A5B', white, '#F08A3C'),
    BE: vb(black, '#F2CF3A', red), RO: vb('#2B4FA3', gold, red),
    SE: { nordic: ['#2B6CB5', gold] }, FI: { nordic: [white, '#1F4F9E'] }, DK: { nordic: [red, white] },
    NO: { nordic: [red, white, '#1F3F8F'] }, CH: { cross: [red, white] }, JP: { disc: [white, red, 0.5] },
    US: { special: 'US' }, GB: { special: 'GB' }, PT: { special: 'PT' },
  };

  function flagShapes(code, s) {
    const art = FLAGS[code];
    const rect = (x, y, w, h, c) => `<rect x="${f(x * s)}" y="${f(y * s)}" width="${f(w * s)}" height="${f(h * s)}" fill="${c}"/>`;
    const disc = (x, y, r, c) => `<circle cx="${f(x * s)}" cy="${f(y * s)}" r="${f(r * s)}" fill="${c}"/>`;
    if (!art) return null;
    if (art.bands) {
      const weights = art.weights || art.bands.map(() => 1);
      const total = weights.reduce((a, b) => a + b, 0);
      let start = 0, out = '';
      art.bands.forEach((c, i) => {
        const len = weights[i] / total;
        out += art.horizontal ? rect(0, start, 1, len + 0.002, c) : rect(start, 0, len + 0.002, 1, c);
        start += len;
      });
      return out;
    }
    if (art.nordic) {
      const [field, cross, inner] = art.nordic;
      let out = rect(0, 0, 1, 1, field) + rect(0, 0.4, 1, 0.2, cross) + rect(0.3, 0, 0.2, 1, cross);
      if (inner) out += rect(0, 0.45, 1, 0.1, inner) + rect(0.35, 0, 0.1, 1, inner);
      return out;
    }
    if (art.cross) return rect(0, 0, 1, 1, art.cross[0]) + rect(0.2, 0.4, 0.6, 0.2, art.cross[1]) + rect(0.4, 0.2, 0.2, 0.6, art.cross[1]);
    if (art.disc) return rect(0, 0, 1, 1, art.disc[0]) + disc(art.disc[2], 0.5, 0.3, art.disc[1]);
    if (art.special === 'US') {
      let out = '';
      for (let i = 0; i < 7; i++) out += rect(0, i / 7, 1, 1 / 7 + 0.001, i % 2 === 0 ? red : white);
      return out + rect(0, 0, 0.5, 4 / 7, '#2C3E7A');
    }
    if (art.special === 'GB') {
      let out = rect(0, 0, 1, 1, '#24357A');
      for (const angle of [45, -45]) {
        out += `<g transform="translate(${f(s / 2)} ${f(s / 2)}) rotate(${angle})">` +
          `<rect x="${f(-s)}" y="${f(-0.1 * s)}" width="${f(2 * s)}" height="${f(0.2 * s)}" fill="${white}"/>` +
          `<rect x="${f(-s)}" y="${f(-0.035 * s)}" width="${f(2 * s)}" height="${f(0.07 * s)}" fill="${red}"/></g>`;
      }
      return out + rect(0, 0.36, 1, 0.28, white) + rect(0.36, 0, 0.28, 1, white) + rect(0, 0.42, 1, 0.16, red) + rect(0.42, 0, 0.16, 1, red);
    }
    if (art.special === 'PT') {
      return rect(0, 0, 0.4, 1, '#2F7A52') + rect(0.4, 0, 0.6, 1, red) + disc(0.4, 0.5, 0.17, gold) + disc(0.4, 0.5, 0.08, red);
    }
    return null;
  }

  let flagSerial = 0;
  /// A flat circle flag with its 1 pt ring of 22 % white (0.75 pt below 14 pt).
  function flagSVG(code, size = 14) {
    const id = `fl${++flagSerial}`;
    const inner = flagShapes(code, size);
    const ring = size >= 14 ? 1 : 0.75;
    const body = inner
      ? `<clipPath id="${id}"><circle cx="${size / 2}" cy="${size / 2}" r="${size / 2}"/></clipPath><g clip-path="url(#${id})">${inner}</g>`
      : `<circle cx="${size / 2}" cy="${size / 2}" r="${size / 2}" fill="rgba(255,255,255,0.06)"/>`;
    return `<svg class="flag" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" aria-hidden="true">${body}` +
      `<circle cx="${size / 2}" cy="${size / 2}" r="${size / 2 - ring / 2}" fill="none" stroke="rgba(255,255,255,0.22)" stroke-width="${ring}"/></svg>`;
  }

  L.geometry = { CUTS, SEAM, REFINED, cutForTileSize, cutForBareSize, refinedTileCut, refinedBareCut, glyphPath, squirclePath, markSVG, glyphSVG, wordmarkSVG };
  L.avatar = { PALETTE, sampleAvatarIndex, keyAvatarIndex };
  L.flagSVG = flagSVG;
})(globalThis.Lumen = globalThis.Lumen || {});
