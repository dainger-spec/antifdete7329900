// Stand-ins for the SF Symbols the app uses, drawn on a 16-unit grid at about SF's regular weight.
// The app keeps the real symbols (names in the comments); these only let the prototypes show
// shape and size without loading anything.
(function (L) {
  'use strict';

  const stroke = (d, w = 1.4) => `<path d="${d}" fill="none" stroke="currentColor" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"/>`;
  const fill = (d, rule = 'nonzero') => `<path d="${d}" fill="currentColor" fill-rule="${rule}"/>`;
  const circle = (cx, cy, r, w = 1.4) => `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="currentColor" stroke-width="${w}"/>`;
  const dot = (cx, cy, r) => `<circle cx="${cx}" cy="${cy}" r="${r}" fill="currentColor"/>`;

  function gear() {
    // gearshape: eight teeth around a ring
    let d = '';
    const teeth = 8, rOut = 7, rIn = 5.6;
    for (let i = 0; i < teeth * 2; i++) {
      const a0 = (i / (teeth * 2)) * Math.PI * 2 - Math.PI / 2;
      const a1 = ((i + 1) / (teeth * 2)) * Math.PI * 2 - Math.PI / 2;
      const r = i % 2 === 0 ? rOut : rIn;
      const p0 = [8 + r * Math.cos(a0 + 0.06), 8 + r * Math.sin(a0 + 0.06)];
      const p1 = [8 + r * Math.cos(a1 - 0.06), 8 + r * Math.sin(a1 - 0.06)];
      d += (i === 0 ? 'M' : 'L') + p0.map((v) => v.toFixed(2)).join(' ') + 'L' + p1.map((v) => v.toFixed(2)).join(' ');
    }
    return stroke(d + 'Z', 1.3) + circle(8, 8, 2.2, 1.3);
  }

  const ICONS = {
    magnifyingglass: circle(6.8, 6.8, 4.6) + stroke('M10.2 10.2L14 14', 1.6),
    plus: stroke('M8 3v10M3 8h10', 1.6),
    ellipsis: dot(3.4, 8, 1.3) + dot(8, 8, 1.3) + dot(12.6, 8, 1.3),
    playFill: `<path d="M5.2 3.4L12.6 8L5.2 12.6Z" fill="currentColor" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>`,
    stopFill: `<rect x="4.2" y="4.2" width="7.6" height="7.6" rx="1.4" fill="currentColor"/>`,
    // plus.rectangle.on.rectangle (New Window)
    newWindow: stroke('M5 3.6V3.2a1.7 1.7 0 0 1 1.7-1.7h6.1a1.7 1.7 0 0 1 1.7 1.7v5.6a1.7 1.7 0 0 1-1.7 1.7h-.4') +
      `<rect x="1.5" y="5" width="9.5" height="9.5" rx="1.8" fill="none" stroke="currentColor" stroke-width="1.4"/>` + stroke('M6.25 7.5v4.5M4 9.75h4.5', 1.3),
    lock: stroke('M5.2 7V5.2a2.8 2.8 0 0 1 5.6 0V7') + `<rect x="3.4" y="7" width="9.2" height="7" rx="1.8" fill="none" stroke="currentColor" stroke-width="1.4"/>`,
    lockFill: stroke('M5.2 7V5.2a2.8 2.8 0 0 1 5.6 0V7', 1.5) + `<rect x="3.2" y="6.8" width="9.6" height="7.4" rx="1.8" fill="currentColor"/>`,
    hourglass: stroke('M4 1.8h8M4 14.2h8M5 1.8c0 3.1 6 3.1 6 6.2s-6 3.1-6 6.2M11 1.8c0 3.1-6 3.1-6 6.2s6 3.1 6 6.2'),
    person2: circle(6, 5.4, 2.3) + stroke('M1.9 13.6c.5-2.6 2.1-4 4.1-4s3.6 1.4 4.1 4') + stroke('M9.6 3.4a2.2 2.2 0 1 1 1.4 4') + stroke('M11.4 9.4c1.6.2 2.8 1.5 3.2 3.6'),
    playCircle: circle(8, 8, 6.4) + `<path d="M6.6 5.3L10.9 8L6.6 10.7Z" fill="currentColor" stroke="currentColor" stroke-width=".8" stroke-linejoin="round"/>`,
    network: circle(8, 8, 6.4) + `<ellipse cx="8" cy="8" rx="2.7" ry="6.4" fill="none" stroke="currentColor" stroke-width="1.2"/>` + stroke('M1.8 8h12.4M2.9 4.7h10.2M2.9 11.3h10.2', 1.1),
    globe: circle(8, 8, 6.4) + `<ellipse cx="8" cy="8" rx="2.7" ry="6.4" fill="none" stroke="currentColor" stroke-width="1.2"/>` + stroke('M1.8 8h12.4', 1.1),
    arrowRight: stroke('M2.6 8h10.6M9.4 4.2L13.2 8l-3.8 3.8', 1.5),
    checkmarkIcloud: stroke('M4.6 12.6h6.9a3 3 0 0 0 .3-6 4 4 0 0 0-7.6 1A2.6 2.6 0 0 0 4.6 12.6z') + stroke('M6.4 9.3l1.3 1.3 2.6-2.7', 1.3),
    syncArrows: stroke('M13.2 6.6A5.3 5.3 0 0 0 3.5 5.1M2.8 9.4a5.3 5.3 0 0 0 9.7 1.5') + stroke('M3.2 2.4v2.9h2.9M12.8 13.6v-2.9H9.9'),
    exclamationTriangleFill: fill('M8 1.6c.5 0 .9.3 1.2.8l5.9 10.5c.5.9-.1 2-1.2 2H2.1c-1.1 0-1.7-1.1-1.2-2L6.8 2.4c.3-.5.7-.8 1.2-.8zM7.25 5.4h1.5v4.7h-1.5zM8 11.1a.9.9 0 1 0 0 1.8.9.9 0 0 0 0-1.8z', 'evenodd'),
    exclamationTriangle: stroke('M8 2.2l6.2 11H1.8z') + stroke('M8 6v3.6', 1.5) + dot(8, 11.6, .85),
    xmarkCircleFill: fill('M8 1a7 7 0 1 1 0 14A7 7 0 0 1 8 1zM5.5 4.4L4.4 5.5 6.9 8l-2.5 2.5 1.1 1.1L8 9.1l2.5 2.5 1.1-1.1L9.1 8l2.5-2.5-1.1-1.1L8 6.9z', 'evenodd'),
    xmark: stroke('M4.2 4.2l7.6 7.6M11.8 4.2l-7.6 7.6', 1.5),
    infoCircle: circle(8, 8, 6.4) + stroke('M8 7.2v4.4', 1.5) + dot(8, 4.9, .9),
    gearshape: gear(),
    clock: circle(8, 8, 6.4) + stroke('M8 4.4V8l2.6 1.6'),
    flame: stroke('M8 1.6c.6 2.5 4.2 4 4.2 7.6a4.2 4.2 0 0 1-8.4 0c0-1.7.8-2.8 1.9-3.7.1 1.3.7 2.2 1.6 2.5C7.2 6.1 7 3.9 8 1.6z'),
    chevronDown: stroke('M4.2 6.2L8 10l3.8-3.8', 1.5),
    chevronUpDown: stroke('M5.2 6.1L8 3.3l2.8 2.8M5.2 9.9L8 12.7l2.8-2.8', 1.4),
    chevronUp: stroke('M4.2 9.8L8 6l3.8 3.8', 1.5),
    check: stroke('M3.4 8.4l3 3 6.2-7', 1.8),
    doc: stroke('M4 1.6h5l3.4 3.4v9.4H4z') + stroke('M9 1.6V5h3.4', 1.2),
    shieldCheck: stroke('M8 1.6l5.2 2v4.1c0 3.3-2.2 5.7-5.2 6.7-3-1-5.2-3.4-5.2-6.7V3.6z') + stroke('M5.6 8.1l1.7 1.7 3.2-3.4', 1.4),
    shieldSlash: stroke('M8 1.6l5.2 2v4.1c0 3.3-2.2 5.7-5.2 6.7-3-1-5.2-3.4-5.2-6.7V3.6z') + stroke('M3 3l10 10', 1.3),
    folder: stroke('M1.8 4.2c0-.8.6-1.4 1.4-1.4h3.1l1.5 1.6h5c.8 0 1.4.6 1.4 1.4v6.4c0 .8-.6 1.4-1.4 1.4H3.2c-.8 0-1.4-.6-1.4-1.4z'),
    key: circle(5, 8, 3) + stroke('M8 8h6.4M12.2 8v2.4M14.2 8v1.8'),
    trash: stroke('M2.8 4h10.4M6.2 4V2.6h3.6V4M4.2 4l.7 9.6h6.2L11.8 4M6.8 6.6v4.6M9.2 6.6v4.6'),
    arrowUp: stroke('M8 13V3.4M4.6 6.6L8 3.2l3.4 3.4', 1.4),
    arrowDown: stroke('M8 3v9.6M4.6 9.4L8 12.8l3.4-3.4', 1.4),
    filter: stroke('M2 4h12M4.5 8h7M7 12h2', 1.5),
    sidebar: `<rect x="1.6" y="2.6" width="12.8" height="10.8" rx="2" fill="none" stroke="currentColor" stroke-width="1.4"/>` + stroke('M6 2.6v10.8'),
  };

  const SPRITE_ID = 'lumen-icon-sprite';
  function ensureSprite() {
    if (typeof document === 'undefined' || document.getElementById(SPRITE_ID)) return;
    const symbols = Object.entries(ICONS)
      .map(([name, body]) => `<symbol id="i-${name}" viewBox="0 0 16 16">${body}</symbol>`).join('');
    const holder = document.createElement('div');
    holder.innerHTML = `<svg id="${SPRITE_ID}" xmlns="http://www.w3.org/2000/svg" style="position:absolute;width:0;height:0;overflow:hidden" aria-hidden="true">${symbols}</svg>`;
    document.body.prepend(holder.firstChild);
  }

  /// An icon `size` points square in the current text colour.
  function icon(name, size = 16, cls = '') {
    if (!ICONS[name]) throw new Error(`no icon ${name}`);
    return `<svg class="icon ${cls}" width="${size}" height="${size}" viewBox="0 0 16 16" aria-hidden="true"><use href="#i-${name}"/></svg>`;
  }

  L.ICONS = ICONS;
  L.icon = icon;
  L.ensureIconSprite = ensureSprite;
  if (typeof document !== 'undefined') {
    if (document.body) ensureSprite();
    else document.addEventListener('DOMContentLoaded', ensureSprite);
  }
})(globalThis.Lumen = globalThis.Lumen || {});
