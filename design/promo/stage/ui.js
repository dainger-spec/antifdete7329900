// The app's drawn pieces for the film, in the "Eclipse" design: windows, the sidebar, rows, avatars, the
// inspector, Safari's window, the eclipse light. Built once per scene as DOM; scenes animate them by time.
// The mark, the wordmark, the flags and the SF Symbol stand-ins come from design/prototypes/kit (window.Lumen).
(function () {
  'use strict';
  const L = window.Lumen;
  const F = window.Film;
  const UI = (window.UI = {});

  // MARK: Symbols — the kit's, and a few more drawn the same way (16 grid, 1.4 stroke)

  const stroke = (d, w = 1.4) => `<path d="${d}" fill="none" stroke="currentColor" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"/>`;
  const rect = (x, y, w, h, r, sw = 1.4) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" fill="none" stroke="currentColor" stroke-width="${sw}"/>`;
  const circle = (cx, cy, r, w = 1.4) => `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="currentColor" stroke-width="${w}"/>`;
  const dot = (cx, cy, r) => `<circle cx="${cx}" cy="${cy}" r="${r}" fill="currentColor"/>`;
  const fill = (d) => `<path d="${d}" fill="currentColor"/>`;

  const MORE = {
    playRect: rect(1.6, 3, 12.8, 10, 2) + `<path d="M6.6 5.8L10.4 8 6.6 10.2Z" fill="currentColor"/>`,
    terminal: rect(1.6, 2.6, 12.8, 10.8, 1.8) + stroke('M4.6 6.4l2.2 1.9-2.2 1.9M8.6 10.3h3'),
    book: stroke('M8 4.2C6.6 3 4.6 2.6 2 2.8v9.6c2.6-.2 4.6.2 6 1.4 1.4-1.2 3.4-1.6 6-1.4V2.8c-2.6-.2-4.6.2-6 1.4zM8 4.2v9.6'),
    laptop: rect(3, 3.2, 10, 7.4, 1.3) + stroke('M1.4 13h13.2'),
    iphone: rect(4.4, 1.4, 7.2, 13.2, 1.8) + stroke('M7 3.4h2', 1.2),
    sidebarRight: rect(1.6, 2.6, 12.8, 10.8, 2) + stroke('M10.2 2.8v10.4'),
    pencil: stroke('M10.6 2.6l2.8 2.8-7.8 7.8-3.4.6.6-3.4z'),
    back: stroke('M10 3.4L5.4 8 10 12.6', 1.6),
    fwd: stroke('M6 3.4L10.6 8 6 12.6', 1.6),
    share: stroke('M8 1.8v8M5.2 4.4L8 1.6l2.8 2.8M4.4 7H3.6v7.2h8.8V7h-.8'),
    tabs: rect(2, 4.6, 9.6, 9.4, 1.6) + stroke('M4.6 2.4h7.6c.8 0 1.4.6 1.4 1.4v7.4'),
    plus: stroke('M8 3v10M3 8h10', 1.6),
    reload: stroke('M13.2 8a5.2 5.2 0 1 1-1.6-3.8M13.4 2.6v3h-3'),
    refresh: stroke('M13.2 8a5.2 5.2 0 1 1-1.6-3.8M13.4 2.6v3h-3'),
    video: rect(1.4, 4, 9.2, 8, 1.8) + stroke('M10.6 7.2l4-2.2v6l-4-2.2'),
    mic: rect(5.6, 1.6, 4.8, 8, 2.4) + stroke('M3.4 7.6a4.6 4.6 0 0 0 9.2 0M8 12.2v2.2'),
    phoneDown: fill('M8 6c2.6 0 4.9.7 6.3 1.9.5.4.6 1.1.3 1.7l-.7 1.2c-.3.5-.9.7-1.4.5l-1.8-.7c-.5-.2-.8-.7-.7-1.2l.1-.9C9.3 8.2 6.7 8.2 5.9 8.5l.1.9c.1.5-.2 1-.7 1.2l-1.8.7c-.5.2-1.1 0-1.4-.5l-.7-1.2c-.3-.6-.2-1.3.3-1.7C3.1 6.7 5.4 6 8 6z'),
    camera: rect(1.4, 4.2, 13.2, 9.4, 2) + stroke('M5.4 4.2l1-1.8h3.2l1 1.8') + circle(8, 8.8, 2.6),
    key: circle(5.2, 10.8, 2.8) + stroke('M7.2 8.8l6.2-6.2M11.2 4.8l1.6 1.6M9.6 6.4l1.4 1.4'),
    cookie: stroke('M13.7 8.7A5.8 5.8 0 1 1 7.3 2.3a1.9 1.9 0 0 0 2.5 2.3 1.9 1.9 0 0 0 2.3 2.4 1.9 1.9 0 0 0 1.6 1.7z') + dot(5.6, 6.4, 0.85) + dot(6.4, 10.3, 0.85) + dot(10, 10.6, 0.85),
    translate: stroke('M2.2 4.2h7.2M5.8 2.4v1.8M3.9 4.2c.6 2.6 2.4 4.6 5 5.5M7.8 4.2C7.3 6.8 5.4 8.9 2.6 9.9M8.8 13.6l2.6-6.2 2.6 6.2M9.6 11.7h3.6', 1.3),
    wallet: rect(1.8, 4.2, 12.4, 9.2, 1.7) + stroke('M3.6 4.2l6.9-1.9c.7-.2 1.4.3 1.4 1v.9M10.4 8.8h3.8') + dot(11.6, 8.8, 0.8),
    shield: stroke('M8 1.6l5.2 2v4.1c0 3.3-2.2 5.7-5.2 6.7-3-1-5.2-3.4-5.2-6.7V3.6z'),
    shieldFill: `<path d="M8 1.6l5.2 2v4.1c0 3.3-2.2 5.7-5.2 6.7-3-1-5.2-3.4-5.2-6.7V3.6z" fill="currentColor"/>`,
    bell: stroke('M4 11.4V7.6a4 4 0 0 1 8 0v3.8l1.2 1.4H2.8zM6.6 13.8a1.5 1.5 0 0 0 2.8 0'),
    person: circle(8, 5.4, 2.6) + stroke('M2.8 13.6c.7-2.6 2.7-4 5.2-4s4.5 1.4 5.2 4'),
    person3: circle(8, 5, 2.2) + stroke('M4.2 12.6c.6-2.2 2-3.4 3.8-3.4s3.2 1.2 3.8 3.4') + circle(3.4, 6.4, 1.6, 1.2) + circle(12.6, 6.4, 1.6, 1.2) + stroke('M.8 12c.3-1.4 1.2-2.4 2.6-2.4M15.2 12c-.3-1.4-1.2-2.4-2.6-2.4', 1.2),
    docLock: stroke('M4 1.6h5l3.4 3.4v9.4H4z') + stroke('M9 1.6V5h3.4', 1.2) + `<rect x="5.8" y="9" width="4.4" height="3.4" rx=".8" fill="currentColor"/>` + stroke('M6.6 9V8a1.4 1.4 0 0 1 2.8 0v1', 1.1),
    cursor: `<path d="M3.2 1.8l9.4 6.4-4.1.8 2.4 4.6-1.6.8-2.4-4.6-3 2.8z" fill="#FFFFFF" stroke="#111" stroke-width=".9" stroke-linejoin="round"/>`,
    record: circle(8, 8, 6.2) + dot(8, 8, 3),
    calendar: rect(2, 3, 12, 11, 1.7) + stroke('M2 6.6h12M5 1.8v2.4M11 1.8v2.4'),
    bolt: stroke('M9 1.8L3.6 9h4.2L7 14.2 12.4 7H8.2z'),
    layers: stroke('M8 2.2l6 3.2-6 3.2-6-3.2zM2 8.2l6 3.2 6-3.2M2 11l6 3.2 6-3.2'),
    sparkle: stroke('M8 1.8l1.4 4.2 4.4 1.6-4.4 1.6L8 13.4l-1.4-4.2L2.2 7.6l4.4-1.6z', 1.2),
    keyboard: rect(1.4, 3.8, 13.2, 8.4, 1.6) + stroke('M4 6.6h.1M6.4 6.6h.1M8.8 6.6h.1M11.2 6.6h.1M4 9.4h8', 1.6),
    command: stroke('M5.6 5.6h4.8v4.8H5.6zM5.6 5.6V4a1.6 1.6 0 1 0-1.6 1.6h1.6M10.4 5.6V4A1.6 1.6 0 1 1 12 5.6h-1.6M5.6 10.4V12A1.6 1.6 0 1 1 4 10.4h1.6M10.4 10.4V12a1.6 1.6 0 1 0 1.6-1.6h-1.6', 1.2),
    eye: stroke('M1.4 8S3.8 3.6 8 3.6 14.6 8 14.6 8 12.2 12.4 8 12.4 1.4 8 1.4 8z') + circle(8, 8, 2.1),
    pulse: stroke('M1.4 8.4h3l1.8-4.2 3 8.2 1.8-4h3.6'),
    antenna: circle(8, 8, 1.4) + stroke('M5.2 5.2a4 4 0 0 0 0 5.6M10.8 5.2a4 4 0 0 1 0 5.6M3.2 3.2a6.8 6.8 0 0 0 0 9.6M12.8 3.2a6.8 6.8 0 0 1 0 9.6'),
    arrowRightLong: stroke('M1.6 8h12.6M10.2 4.2L14 8l-3.8 3.8', 1.5),
    menuBar: rect(1.4, 3, 13.2, 10, 1.8) + stroke('M1.6 5.8h12.8'),
    puzzle: stroke('M3 5.2h2.6a1.5 1.5 0 1 1 3 0H11v2.6a1.5 1.5 0 1 1 0 3V13H8.4a1.5 1.5 0 1 0-3 0H3v-2.6a1.5 1.5 0 1 0 0-3z'),
    stethoscope: stroke('M3.4 2v3.6a2.6 2.6 0 0 0 5.2 0V2M6 8.2v1.6a3.4 3.4 0 0 0 6.8 0V8.6') + circle(12.8, 7, 1.5, 1.3),
    wand: stroke('M2.4 13.6l7.4-7.4M9.8 2v2M13.8 6h-2M12.6 3.2l-1.4 1.4M8.6 6.2l1.2 1.2', 1.4),
    docText: stroke('M4 1.6h5l3.4 3.4v9.4H4z') + stroke('M9 1.6V5h3.4M6 8h4.4M6 10.4h4.4', 1.2),
  };

  UI.icon = (name, size = 14, extra = '') => {
    const body = MORE[name] || (L.ICONS && L.ICONS[name]);
    if (!body) throw new Error('no icon ' + name);
    return `<svg class="icon" width="${size}" height="${size}" viewBox="0 0 16 16" ${extra} aria-hidden="true">${body}</svg>`;
  };
  UI.flag = (code, size = 14) => L.flagSVG(code, size);
  UI.mark = (size, opts = {}) => L.geometry.markSVG(size, { tile: '#111216', ...opts });
  UI.glyph = (size, color = '#F4F4F5') => L.geometry.glyphSVG(size, color);
  UI.wordmark = (height, color = '#F4F4F5') => L.geometry.wordmarkSVG(height, color);
  UI.lockup = (mark = 22, word = 11.2, gap = 10) => `<div class="lockup" style="gap:${gap}px">${UI.mark(mark)}${UI.wordmark(word)}</div>`;

  // MARK: Profiles' glyphs (Theme.swift, ProfileAvatar.palette — eight)

  UI.PALETTE = [
    ['#273553', '#B9C8F0'], ['#243A33', '#9FD4BB'], ['#3B332A', '#E0CDB3'], ['#312C45', '#C9BCEB'],
    ['#2A2F3A', '#C3C9D4'], ['#1F3A3D', '#9ED8DB'], ['#3D2630', '#EAB8C8'], ['#34361F', '#D6D9A0'],
  ];
  UI.avatar = (letters, color, size = 30, running = false) => {
    const [bg, fg] = UI.PALETTE[color % UI.PALETTE.length];
    const fs = size * (letters.length > 1 ? 0.34 : 0.4);
    const d = size >= 44 ? 12 : Math.max(7, size * 0.3);
    return `<div class="avatar" style="width:${size}px;height:${size}px;background:${bg};color:${fg};font-size:${fs.toFixed(1)}px">${letters}` +
      `<i class="on" style="width:${d}px;height:${d}px;${running ? '' : 'opacity:0'}"></i></div>`;
  };

  // MARK: The eclipse (EclipseLight.swift): five circles per corner, blurred — drawn as radial gradients

  /// A blurred disc's edge as gradient stops: 0.5·(1 − erf((r − R)/(σ√2))).
  const erf = (x) => {
    const s = Math.sign(x), a = Math.abs(x), t = 1 / (1 + 0.3275911 * a);
    const y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-a * a);
    return s * y;
  };
  UI.softDisc = (cx, cy, R, sigma, rgb, alpha) => {
    if (sigma < 0.6) sigma = 0.6;
    const stops = [];
    const n = 9;
    for (let i = 0; i <= n; i++) {
      const r = R - 2.6 * sigma + (5.2 * sigma * i) / n;
      if (r < 0) continue;
      const v = 0.5 * (1 - erf((r - R) / (sigma * Math.SQRT2)));
      stops.push(`rgba(${rgb},${(alpha * v).toFixed(4)}) ${r.toFixed(1)}px`);
    }
    if (R - 2.6 * sigma > 0) stops.unshift(`rgba(${rgb},${alpha.toFixed(4)}) 0px`);
    return `radial-gradient(circle at ${cx.toFixed(1)}px ${cy.toFixed(1)}px, ${stops.join(', ')})`;
  };

  const SPEC = {
    lock: { ref: 920, tr: { d: 1274, x: -725, y: -699, halo: [-30, 19], glow: [-12, 8], rim: [-9, 6], pen: [-3, 2], sh: [46, -30], from: [120, -80] },
      bl: { d: 930, x: -560, y: -680, halo: [27, -22], glow: [11, -9], rim: [8, -7], pen: [3, -2], sh: [-40, 33], from: [-110, 90] } },
    profiles: { ref: 1000, tr: { d: 1109, x: -709, y: -687, halo: [-28, 19], glow: [-11, 7], rim: [-8, 5.5], pen: [-2.5, 1.7], sh: [43, -29], from: [110, -74] },
      bl: { d: 921, x: -523, y: -717, halo: [26, -23], glow: [10, -9], rim: [7.5, -6.6], pen: [2.3, -2], sh: [-39, 34], from: [-96, 84] } },
  };
  const BLUR = { halo: 46, glow: 8, rim: 0.8, pen: 18, sh: 36 };

  /// The background-image of one eclipse window's light (both corners), `k` 0…1 how far they came in,
  /// `lit` 0…1 the light at their edges.
  UI.eclipseBG = (w, h, place = 'profiles', k = 1, lit = 1, bright = 1, bgRGB = '8,9,11') => {
    const s = SPEC[place], sc = h / s.ref;
    const layers = [];
    for (const corner of ['tr', 'bl']) {
      const d = s[corner], D = d.d * sc, R = D / 2;
      const cx = corner === 'tr' ? w - d.x * sc - R : d.x * sc + R;
      const cy = corner === 'tr' ? d.y * sc + R : h - d.y * sc - R;
      const mx = (1 - k) * d.from[0] * sc, my = (1 - k) * d.from[1] * sc;
      const at = (o) => [cx + mx + o[0] * sc, cy + my + o[1] * sc];
      // painted top first: shadow, penumbra, rim, glow, halo
      layers.push(UI.softDisc(...at(d.sh), R, BLUR.sh * sc, bgRGB, 1));
      layers.push(UI.softDisc(...at(d.pen), R, BLUR.pen * sc, '43,46,53', 1));
      layers.push(UI.softDisc(...at(d.rim), R, BLUR.rim * sc, '236,240,248', lit * bright));
      layers.push(UI.softDisc(...at(d.glow), R, BLUR.glow * sc, '236,240,248', 0.5 * lit * bright));
      layers.push(UI.softDisc(...at(d.halo), R, BLUR.halo * sc, '236,240,248', 0.22 * lit * bright));
    }
    return layers.join(', ');
  };

  // MARK: Windows

  UI.traffic = (grey = false) => `<div class="traffic${grey ? ' grey' : ''}"><i></i><i></i><i></i></div>`;

  /// Sample profiles (as UISnapshots' sample rows, with the film's names).
  UI.PROFILES = [
    { id: 'shop', name: 'Магазин DE', letters: 'М', color: 0, cc: 'DE', country: 'Германия', city: 'Берлин', tz: 'Europe/Berlin', seen: 'Mac · Safari 26', dev: 'laptop', tags: [['магазин', 0]], state: 'run', ip: '203.0.113.47', proxy: 'SOCKS5 · de.gw.example:1080', lat: 84, lang: 'de-DE, de' },
    { id: 'north', name: 'Northwind', letters: 'N', color: 3, cc: 'US', country: 'США', city: 'Нью-Йорк', tz: 'America/New_York', seen: 'Mac · Safari 26', dev: 'laptop', tags: [['реклама', 3]], state: 'warm' },
    { id: 'jp', name: 'Research JP', letters: 'R', color: 5, cc: 'JP', country: 'Япония', city: 'Токио', tz: 'Asia/Tokyo', seen: 'Mac · Safari 26', dev: 'laptop', tags: [], state: 'start' },
    { id: 'travel', name: 'Travel', letters: 'T', color: 2, cc: 'PT', country: 'Португалия', city: 'Лиссабон', tz: 'Europe/Lisbon', seen: 'iPhone · Safari 26', dev: 'iphone', tags: [['мобайл', 1]], state: 'start' },
    { id: 'shop3', name: 'Магазин-3', letters: 'М3', color: 1, cc: 'NL', country: 'Нидерланды', seen: 'Mac · Safari 26', dev: 'laptop', tags: [['магазин', 0]], state: 'stop', last: 'вчера' },
    { id: 'ads', name: 'Ads FR', letters: 'A', color: 6, cc: 'FR', country: 'Франция', seen: 'Mac · Safari 26', dev: 'laptop', tags: [['реклама', 3]], state: 'stop', last: '2 ч назад' },
    { id: 'bank', name: 'Banking', letters: 'B', color: 4, cc: 'GB', country: 'Великобритания', seen: 'Mac · Safari 26', dev: 'laptop', tags: [], state: 'stop', last: '3 дн. назад' },
    { id: 'nord', name: 'Nordic', letters: 'N', color: 7, cc: 'SE', country: 'Швеция', seen: 'Mac · Safari 26', dev: 'laptop', tags: [['прогрев', 1]], state: 'stop', last: 'на прошлой неделе' },
    { id: 'personal', name: 'Personal', letters: 'P', color: 4, cc: null, country: 'Напрямую', seen: 'Mac · Safari 26', dev: 'laptop', tags: [], state: 'stop', last: 'Никогда' },
  ];
  UI.byId = (id) => UI.PROFILES.find((p) => p.id === id);

  UI.tagLine = (tags) => tags.map(([t, c]) => `<span><i style="background:${UI.PALETTE[c][1]}"></i>${t}</span>`).join('');

  /// One profile row (ProfileRow): returns the element; the state cell is `.cell-state`.
  UI.row = (p, opts = {}) => {
    const r = F.el('div', 'row' + (opts.sel ? ' sel' : ''));
    const exit = p.cc ? `${UI.flag(p.cc, 14)}<span>${p.country}</span>` : `<span style="width:14px;display:flex;justify-content:center;color:var(--t3)">${UI.icon('arrowRight', 11)}</span><span style="color:var(--t2)">Напрямую</span>`;
    r.innerHTML = `<div class="chk"></div><div class="namecell">${UI.avatar(p.letters, p.color, 30, p.state === 'run' || p.state === 'warm')}` +
      `<span class="nm">${p.name}</span><span class="tags">${UI.tagLine(p.tags)}</span></div>` +
      `<div class="cell-exit">${exit}</div><div class="cell-seen">${UI.icon(p.dev, 12)}<span>${p.seen}</span></div>` +
      `<div class="cell-state"></div><div class="cell-act">${opts.sel ? `<div class="ring-btn">${UI.icon(p.state === 'stop' ? 'playFill' : 'stopFill', 9)}</div><div class="ibtn" style="width:28px;height:28px">${UI.icon('ellipsis', 14)}</div>` : ''}</div>`;
    r._p = p;
    r._state = F.$(r, '.cell-state');
    r._dot = F.$(r, '.avatar .on');
    return r;
  };

  /// Draws a row's state cell for a state: 'run' (since), 'warm' (page, total, cookies), 'start', 'stop'.
  UI.rowState = (r, s) => {
    const key = JSON.stringify(s);
    if (r._stateKey === key) return;
    r._stateKey = key;
    const c = r._state;
    if (s.kind === 'run') c.innerHTML = `<i class="rdot"></i><span style="color:var(--t1)">Работает</span><span class="num" style="color:var(--t3)">${s.since || ''}</span>`;
    else if (s.kind === 'warm') c.innerHTML = `<span class="num" style="font-size:12px;color:var(--t1)">Прогрев ${s.page}/${s.total}</span><span class="pbar" style="width:48px"><i style="width:${Math.round((48 * s.page) / s.total)}px"></i></span><span class="num" style="font-size:12px;color:var(--t2)">· cookies: ${s.cookies}</span>`;
    else if (s.kind === 'start') c.innerHTML = `<i class="spin" style="transform:rotate(${Math.round(s.spin || 0)}deg)"></i><span style="color:var(--t2)">Запуск…</span>`;
    else c.innerHTML = `<span>${s.last || ''}</span>`;
  };

  /// The Profiles window (ProfilesScreen): sidebar, header, the list in groups, the inspector.
  UI.profilesWindow = (o = {}) => {
    const w = o.w || 1600, h = o.h || 960;
    const win = F.el('div', 'win');
    win.style.width = w + 'px';
    win.style.height = h + 'px';
    const ecl = F.el('div', 'eclipse');
    win.appendChild(ecl);
    win._eclipse = ecl;
    const nav = (ic, title, n, on) => `<div class="nav${on ? ' on' : ''}"><span class="ic">${UI.icon(ic, 13)}</span><span>${title}</span>${n != null ? `<span class="n">${n}</span>` : ''}</div>`;
    const sb = F.el('div', 'sb');
    sb.innerHTML = `<div class="band"></div>${UI.lockup(22, 11.2, 10)}` +
      `<div class="palette-btn">${UI.icon('magnifyingglass', 12)}<span>Команды и поиск</span><span class="kcap">⌘K</span></div>` +
      nav('person2', 'Профили', 9, true) + nav('globe', 'Прокси', 24) + nav('playRect', 'Сценарии') + nav('terminal', 'API автоматизации') + nav('book', 'Справка') +
      `<div class="cap">Подборки</div>` + nav('playCircle', 'Запущенные', 4) + nav('network', 'Через прокси', 8) + nav('arrowRight', 'Напрямую', 1) + nav('hourglass', 'Временные', 0) +
      `<div class="cap">Теги</div>` +
      `<div class="nav"><span class="ic"><i class="tagdot" style="background:${UI.PALETTE[0][1]}"></i></span><span>магазин</span><span class="n">2</span></div>` +
      `<div class="nav"><span class="ic"><i class="tagdot" style="background:${UI.PALETTE[3][1]}"></i></span><span>реклама</span><span class="n">2</span></div>` +
      `<div class="nav"><span class="ic"><i class="tagdot" style="background:${UI.PALETTE[1][1]}"></i></span><span>мобайл</span><span class="n">1</span></div>` +
      `<div class="foot"><div class="syncline">${UI.icon('checkmarkIcloud', 13)}<span>Синхронизировано<br>2 мин назад</span></div>` +
      `<div class="btnrow"><div class="btn full">${UI.icon('lock', 13)}Заблокировать</div><div class="ibtn">${UI.icon('gearshape', 15)}</div></div></div>`;
    win.appendChild(sb);
    win.insertAdjacentHTML('beforeend', UI.traffic());
    const main = F.el('div', 'main');
    main.style.right = o.inspector ? '320px' : '0';
    main.innerHTML = `<div class="hdr"><div><h1>Профили</h1><div class="countline">Профилей: 9 · запущено: <span class="nrun">4</span></div></div>` +
      `<div class="search">${UI.icon('magnifyingglass', 12)}<span>Поиск</span></div>` +
      `<div class="ibtn${o.inspector ? ' on' : ''}">${UI.icon('sidebarRight', 15)}</div><div class="ibtn">${UI.icon('ellipsis', 15)}</div>` +
      `<div class="btn primary">${UI.icon('plus', 12)}Новый профиль</div></div>`;
    const list = F.el('div', 'list');
    list.innerHTML = `<div class="colhdr"><span style="flex:1;padding-left:74px">Имя</span><span style="width:192px">Выход в сеть</span><span style="width:150px">Видится как</span><span style="width:196px">Состояние</span><span style="width:68px"></span></div>`;
    const rows = {};
    const groups = o.groups || [['Запущены', ['shop', 'north', 'jp', 'travel']], ['Готовы к запуску', ['shop3', 'ads', 'bank', 'nord', 'personal']]];
    for (const [title, ids] of groups) {
      const g = F.el('div', 'grp', `<span>${title}</span><span class="num">${ids.length}</span>`);
      list.appendChild(g);
      for (const id of ids) {
        const p = UI.byId(id);
        const r = UI.row(p, { sel: o.selected === id });
        rows[id] = r;
        list.appendChild(r);
        UI.rowState(r, p.state === 'stop' ? { kind: 'stop', last: p.last } : { kind: 'run', since: '' });
      }
    }
    list.insertAdjacentHTML('beforeend', `<div class="footnote">${UI.icon('lock', 12)}<span>Остановленные профили зашифрованы мастер-паролем.</span></div>`);
    main.appendChild(list);
    win.appendChild(main);
    if (o.inspector) {
      const insp = UI.inspector(UI.byId(o.inspector));
      win.appendChild(insp);
      win._insp = insp;
    }
    win._rows = rows;
    win._main = main;
    win._sb = sb;
    win._nrun = F.$(main, '.nrun');
    win._w = w;
    win._h = h;
    return win;
  };

  /// The inspector (ProfileInspectorView) for a running profile with a SOCKS5 proxy that carries UDP.
  UI.inspector = (p) => {
    const e = F.el('div', 'insp');
    const fact = (k, v, cls = '', attr = '') => `<div class="fact" ${attr}><span class="k">${k}</span><span class="v ${cls}">${v}</span></div>`;
    e.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:flex-start">${UI.avatar(p.letters, p.color, 56, true)}<div class="ibtn">${UI.icon('pencil', 14)}</div></div>` +
      `<h2>${p.name}</h2><div class="status"><i class="rdot"></i><span>Работает</span><span class="num" style="color:var(--t3)">12 мин</span></div>` +
      `<div style="margin-top:4px;font-size:12px;color:var(--t3)" class="tags">${UI.tagLine(p.tags)}</div>` +
      `<div style="display:flex;gap:10px;margin-top:16px"><div class="btn">${UI.icon('stopFill', 10)}Остановить</div><div class="btn ghost">Новое окно</div></div>` +
      `<div class="sec"><div class="sec-t">Сеть</div>` +
      fact('Выход', `<span style="display:inline-flex;gap:7px;align-items:center">${UI.flag(p.cc, 13)}${p.country} · ${p.city}</span>`) +
      fact('Внешний IP', p.ip, 'mono') + fact('Прокси', p.proxy, 'mono') + fact('Задержка', `<span class="num">${p.lat} мс</span>`) +
      fact('UDP', '<span class="badge g" style="height:20px">UDP работает</span>', '', 'data-k="udp"') +
      fact('Часовой пояс', `${p.tz} · по прокси`) +
      fact('WebRTC', 'Через прокси, только ретранслятор', '', 'data-k="rtc"') +
      `<div style="margin-top:8px;font-size:13px;display:flex;gap:4px;align-items:center">Проверить прокси ${UI.icon('arrowRight', 10)}</div></div>` +
      `<div class="sec"><div class="sec-t">Как видят сайты</div>` + fact('Устройство', p.seen) + fact('Языки', p.lang) + fact('Окно', '1600 × 960') + `</div>`;
    return e;
  };

  /// Safari's window (macOS 26): toolbar with the profile's chip and the address, then the page.
  UI.safari = (o) => {
    const e = F.el('div', 'safari' + (o.dark ? ' dark' : '') + (o.automation ? ' automation' : ''));
    e.style.width = o.w + 'px';
    e.style.height = o.h + 'px';
    const p = o.profile;
    const chip = p ? `<div class="chip">${UI.avatar(p.letters, p.color, 22, false)}<span>${p.name}</span>${p.cc ? UI.flag(p.cc, 13) : ''}</div>` : '';
    e.innerHTML = `<div class="bar">${UI.traffic(o.grey)}<div class="tb">${UI.icon('sidebarRight', 15)}</div><div class="tb">${UI.icon('back', 14)}</div><div class="tb" style="opacity:.45">${UI.icon('fwd', 14)}</div>` +
      chip + `<div class="addr">${o.automation ? '' : `<span class="lockg">${UI.icon('lock', 11)}</span>`}<span class="url">${o.url || ''}</span></div>` +
      `<div class="tb">${UI.icon('share', 14)}</div><div class="tb">${UI.icon('plus', 14)}</div><div class="tb">${UI.icon('tabs', 14)}</div></div>` +
      `<div class="page">${o.page || ''}</div>`;
    e._page = F.$(e, '.page');
    return e;
  };

  /// A card of the app's own design, for the feature scenes: a dark panel with a hairline.
  UI.panel = (w, h, html = '', cls = '') => {
    const e = F.el('div', 'panel ' + cls, html);
    e.style.width = w + 'px';
    e.style.height = h + 'px';
    return e;
  };
})();
