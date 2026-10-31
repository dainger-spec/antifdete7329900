// Lumen website prototype — the little JavaScript the pages use. Everything works without it:
// the content is in the HTML, menus and FAQ are <details>, the billing switch and the proxy demo are
// CSS, and every picture shows its final state. This file only adds motion and conveniences:
//   - the header turns to glass once the page scrolls under it;
//   - home: a presentation in scenes that play with the scroll ("Scenes"; each scene's own script is in
//     assets/scenes/); none of it without JavaScript, with Reduce Motion or in shots;
//   - reveal on scroll (once), never with Reduce Motion;
//   - features: the proxy demo switches itself off once when first seen;
//   - the local navigation's active section (features, docs);
//   - copy buttons on code;
//   - the prototype's strip (decision marks, Reduce Motion stand-in).
(function () {
  'use strict';
  const root = document.documentElement;
  const media = window.matchMedia('(prefers-reduced-motion: reduce)');
  const reduced = () => media.matches || root.classList.contains('rm');
  const shot = root.classList.contains('shot');
  // Scenes play only with JavaScript, without Reduce Motion and outside shots; otherwise each section shows
  // its finished picture in normal flow. Modules below add a hook per scene: fn(progress 0…1, element).
  const scenesOn = !shot && !reduced() && !!document.querySelector('[data-scene]');
  if (scenesOn) root.classList.add('js-scenes');
  const SCENE = {};
  const onScene = (name, fn) => { (SCENE[name] = SCENE[name] || []).push(fn); };
  const clamp01 = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x);

  // MARK: Prototype strip

  document.querySelectorAll('[data-toggle]').forEach((b) => {
    const kind = b.getAttribute('data-toggle');
    const cls = kind === 'tbd' ? 'tbd-on' : 'rm';
    const sync = () => b.classList.toggle('on', root.classList.contains(cls));
    sync();
    b.addEventListener('click', () => {
      root.classList.toggle(cls);
      try { localStorage.setItem(kind === 'tbd' ? 'lumen-site-tbd' : 'lumen-site-rm', root.classList.contains(cls) ? '1' : '0'); } catch (e) { /* private mode */ }
      sync();
      if (cls === 'rm') revealAll();
    });
  });

  // MARK: Header: clear at the top of a page, glass once the page scrolls under it

  const headerEl = document.querySelector('.site-header');
  if (headerEl) {
    const sync = () => headerEl.classList.toggle('scrolled', window.scrollY > 4);
    sync();
    window.addEventListener('scroll', sync, { passive: true });
  }

  // MARK: Header: the section you are in, under the name (phones and tablets)

  const hsub = document.querySelector('[data-hsub]');
  const titled = Array.from(document.querySelectorAll('main [data-title]'));
  if (hsub && titled.length) {
    let current = hsub.textContent, queued = false;
    const pick = () => {
      queued = false;
      const line = window.innerHeight * 0.45;
      let title = titled[0].dataset.title;
      for (const el of titled) if (el.getBoundingClientRect().top <= line) title = el.dataset.title;
      if (title === current) return;
      current = title;
      if (reduced()) { hsub.textContent = title; return; }
      hsub.classList.add('swap');
      setTimeout(() => { hsub.textContent = title; hsub.classList.remove('swap'); }, 160);
    };
    window.addEventListener('scroll', () => { if (!queued) { queued = true; requestAnimationFrame(pick); } }, { passive: true });
    pick();
  }

  // MARK: Reveal on scroll

  const revealables = Array.from(document.querySelectorAll('.reveal'));
  function revealAll() { revealables.forEach((el) => el.classList.add('in')); }
  if (shot || reduced() || !('IntersectionObserver' in window)) {
    revealAll();
  } else {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (!e.isIntersecting) return;
        // Siblings that arrive together come in 40 ms apart, at most four steps.
        const el = e.target;
        const siblings = el.parentElement ? Array.from(el.parentElement.children).filter((x) => x.classList.contains('reveal')) : [];
        const i = Math.min(3, Math.max(0, siblings.indexOf(el)));
        el.style.transitionDelay = `${i * 40}ms`;
        el.classList.add('in');
        io.unobserve(el);
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    revealables.forEach((el) => {
      // Already on screen at load: show at once, no motion.
      const r = el.getBoundingClientRect();
      if (r.top < window.innerHeight * 0.92) el.classList.add('in'); else io.observe(el);
    });
  }

  // MARK: Copy buttons

  document.querySelectorAll('[data-copy]').forEach((b) => {
    b.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(b.getAttribute('data-copy')); } catch (e) { return; }
      b.classList.add('copied');
      setTimeout(() => b.classList.remove('copied'), 1500);
    });
  });

  // MARK: Local navigation (features, docs, legal): the section in view is marked

  document.querySelectorAll('[data-localnav], [data-toc]').forEach((nav) => {
    const links = Array.from(nav.querySelectorAll('a[href^="#"]'));
    const chipLinks = Array.from(document.querySelectorAll('[data-chipnav] a[href^="#"]'));
    const targets = links.map((a) => document.getElementById(a.getAttribute('href').slice(1))).filter(Boolean);
    const indicator = nav.querySelector('.indicator');
    function mark(id) {
      links.forEach((a) => a.classList.toggle('active', a.getAttribute('href') === `#${id}`));
      chipLinks.forEach((a) => {
        const on = a.getAttribute('href') === `#${id}`;
        a.classList.toggle('active', on);
        if (on && a.parentElement && !shot) a.parentElement.scrollTo({ left: a.offsetLeft - 20, behavior: reduced() ? 'auto' : 'smooth' });
      });
      const active = links.find((a) => a.classList.contains('active'));
      if (indicator && active) {
        indicator.style.height = `${active.offsetHeight}px`;
        indicator.style.transform = `translateY(${active.offsetTop}px)`;
        indicator.style.opacity = '1';
      }
    }
    if (!targets.length) return;
    let current = targets[0].id;
    mark(current);
    const io = new IntersectionObserver((entries) => {
      const visible = entries.filter((e) => e.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
      if (visible.length) { current = visible[0].target.id; mark(current); }
    }, { rootMargin: '-30% 0px -60% 0px', threshold: 0 });
    targets.forEach((t) => io.observe(t));
  });

  // MARK: Features: "proxy down, IP hidden" — switches itself once when first seen, then waits for clicks
  document.querySelectorAll('[data-pdemo]').forEach((demo) => {
    const box = demo.querySelector('#pd-off');
    if (!box) return;
    if (shot) { box.checked = true; return; }
    if (!('IntersectionObserver' in window)) return;
    const io = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      setTimeout(() => { if (!box.dataset.touched) box.checked = true; }, reduced() ? 0 : 1100);
    }, { threshold: 0.5 });
    box.addEventListener('change', () => { box.dataset.touched = '1'; });
    io.observe(demo);
  });

  // MARK: Code art: the mark drawn in characters (home)
  // The split disc of the mark (LumenMarkGeometry: radius 19, gap 3, slide 6) set in a monospace grid.
  // Each half is a profile: its own binary and a few of its own values (language, time zone), and the seam
  // between them is a line of light. On the first screen it lives on a MacBook (drawn in CSS 3D): the right
  // half on its display ("screen"), the left half on a canvas of its own ("pop") that comes out of the
  // screen to float in front of it. "field": the faint code behind the first screen; "mark": the figure
  // alone (the last call); "texture": the faint code behind a page's title, still.
  // Everything plays once, on first sight; after that nothing moves by itself. A mouse pointer is a soft
  // light over the code. Reduce Motion and shots: drawn once, finished, no light. Without JavaScript the
  // display shows the plain mark (.art-fallback).
  const SEAM_LEN = Math.hypot(1, 3), SD = [1 / SEAM_LEN, -3 / SEAM_LEN], SN = [3 / SEAM_LEN, 1 / SEAM_LEN];
  const GAP = 3 / 19, SLIDE = 6 / 19;
  const LIGHT = (() => { const v = [-0.42, -0.58, 0.7], l = Math.hypot(v[0], v[1], v[2]); return v.map((x) => x / l); })();
  const CODE = [
    'profile.store { exit: "DE"; lang: "de-DE"; tz: "Europe/Berlin"; proxy: socks5 }',
    'profile.ads { exit: "US"; lang: "en-US"; tz: "America/New_York"; proxy: https }',
    'cookies(profile) -> own; passwords(profile) -> own; history(profile) -> own',
    'webkit.process(per: profile); window = safari',
    'route(profile) = proxy; direct = closed; udp = closed; webrtc = closed',
    'tls.handshake == safari; headers.order == safari; http2 == safari',
    'vault.seal(aes-256-gcm, key: argon2id(master))',
    'warmup(profile, sites: country(proxy)) -> cookies',
  ];
  // Each profile's own values, set into its half: [row, first column] in radii from the half's centre.
  const TOKENS = [
    [[-0.42, -0.66, 'de-DE'], [-0.08, -0.84, 'Europe/Berlin'], [0.3, -0.72, 'cookies'], [0.62, -0.46, 'store']],
    [[-0.58, 0.2, 'en-US'], [-0.24, 0.1, 'America/New_York'], [0.14, 0.08, 'cookies'], [0.5, 0.06, 'ads']],
  ];
  const HALF_RGB = ['226,231,240', '196,211,255'];
  const EDGE_RGB = '160,184,252';
  const MONO = '"SF Mono", ui-monospace, Menlo, "DejaVu Sans Mono", monospace';
  const hash = (a, b, c) => { let h = (a * 73856093) ^ (b * 19349663) ^ (c * 83492791); h = Math.imul(h ^ (h >>> 13), 1274126177); return (h ^ (h >>> 16)) >>> 0; };
  const smooth = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x));
  const easeOut = (x) => 1 - Math.pow(1 - Math.min(1, Math.max(0, x)), 3);
  const easeInOut = (x) => { x = Math.min(1, Math.max(0, x)); return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
  const fieldChar = (i, j) => { const line = CODE[j % CODE.length] + '    '; return line[(i + j * 23) % line.length]; };
  const still = () => shot || reduced();
  const finePointer = matchMedia('(hover: hover) and (pointer: fine)').matches;

  /// A canvas sized to its box (local CSS pixels, so it also works inside 3D transforms), drawn at `scale`.
  function surface(canvas, scale, fs) {
    const W = canvas.offsetWidth, H = canvas.offsetHeight;
    canvas.width = Math.max(1, Math.round(W * scale)); canvas.height = Math.max(1, Math.round(H * scale));
    const ctx = canvas.getContext('2d');
    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    ctx.font = `${fs}px ${MONO}`; ctx.textBaseline = 'middle';
    return { canvas, ctx, W, H, cw: ctx.measureText('0').width };
  }

  /// The figure's halves on one surface. which: which halves to draw (0 left, 1 right); ghost: the left
  /// half's place, faint; t: ms into the reveal (Infinity when done); light: {x, y, a, r} in local pixels.
  function paintHalves(S, L, { which = [0, 1], ghost = false, t = Infinity, tokens = null, light = null }) {
    const { ctx, cw } = S, { cx, cy, R, LH } = L;
    const ox = GAP / 2 * SN[0] + SLIDE / 2 * SD[0], oy = GAP / 2 * SN[1] + SLIDE / 2 * SD[1];
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
        const faint = ghost && half === 0 && !which.includes(0);
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
        if (t !== Infinity) a *= smooth((t - 150 - fromSeam * 1.5) / 380);
        if (light && light.a > 0.01) { const dd = Math.hypot(px - light.x, py - light.y); if (dd < light.r) a += 0.34 * light.a * Math.pow(1 - dd / light.r, 2); }
        let rgb = edge ? EDGE_RGB : HALF_RGB[half];
        if (faint) { a *= 0.16; rgb = '130,150,215'; }
        if (a < 0.03) continue;
        ctx.fillStyle = `rgba(${rgb},${Math.min(1, a).toFixed(3)})`;
        ctx.fillText(tk || ((h >>> 3) & 1 ? '1' : '0'), i * S.cw, py);
      }
    }
  }
  function paintSeam(S, L, len, alpha) {
    if (len <= 0) return;
    const { ctx } = S, { cx, cy, R } = L, l = R * 1.02 * len;
    const line = () => { ctx.beginPath(); ctx.moveTo(cx - SD[0] * l, cy - SD[1] * l); ctx.lineTo(cx + SD[0] * l, cy + SD[1] * l); ctx.stroke(); };
    ctx.save();
    ctx.lineCap = 'round'; ctx.shadowColor = 'rgba(111,143,234,0.9)';
    ctx.shadowBlur = 22; ctx.lineWidth = 6; ctx.strokeStyle = `rgba(111,143,234,${(0.22 * alpha).toFixed(3)})`; line();
    ctx.shadowBlur = 7; ctx.lineWidth = 1.2; ctx.strokeStyle = `rgba(178,198,255,${(0.92 * alpha).toFixed(3)})`; line();
    ctx.restore();
  }
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
  const mirror = (glow, S) => { if (!glow) return; glow.width = S.canvas.width; glow.height = S.canvas.height; const g = glow.getContext('2d'); g.clearRect(0, 0, glow.width, glow.height); g.drawImage(S.canvas, 0, 0); };
  const onFirstSight = (el, fn, threshold = 0.2) => {
    if (still() || !('IntersectionObserver' in window)) { fn(); return; }
    const io = new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting)) { io.disconnect(); fn(); } }, { threshold });
    io.observe(el);
  };

  // The faint code: behind the first screen ("field", quieter behind the words and round the Mac, a light
  // under the pointer) and behind page titles ("texture", still).
  document.querySelectorAll('canvas[data-codeart="field"], canvas[data-codeart="texture"]').forEach((canvas) => {
    const texture = canvas.dataset.codeart === 'texture';
    const host = canvas.parentElement;
    let S = null, field = null, quiet = null, mac = null;
    const light = { x: 0, y: 0, tx: 0, ty: 0, a: 0, ta: 0, r: 190 };
    let raf = 0;
    function alphaAt(px, py) {
      if (texture) return 0.05 * smooth((px / S.W) * 1.5 - 0.4) * smooth((S.H - py) / 140) * (0.3 + 0.7 * smooth((py - 30) / 140));
      let a = 0.042 * (0.25 + 0.75 * smooth((py - 40) / 160)) * smooth((S.H - py) / 180);
      if (quiet) { const out = Math.max(quiet.l - px, px - quiet.r, quiet.t - py, py - quiet.b, 0); a *= 0.4 + 0.6 * smooth(out / 140); }
      if (mac) { const d = Math.hypot((px - mac.x) / mac.rx, (py - mac.y) / mac.ry); a *= 0.45 + 0.55 * smooth((d - 0.55) / 0.6); }
      return a;
    }
    function layout() {
      const r = canvas.getBoundingClientRect();
      if (!r.width || !r.height) return false;
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      S = surface(canvas, dpr, 12); S.ctx.font = `12px ${MONO}`;
      quiet = null; mac = null;
      const off = document.createElement('canvas'); off.width = canvas.width; off.height = canvas.height;
      const o = off.getContext('2d'); o.setTransform(dpr, 0, 0, dpr, 0, 0); o.font = `12px ${MONO}`; o.textBaseline = 'middle';
      const cols = Math.ceil(S.W / S.cw), rows = Math.ceil(S.H / 15);
      for (let j = 0; j < rows; j++) {
        const py = (j + 0.5) * 15;
        for (let i = 0; i < cols; i++) {
          const ch = fieldChar(i, j);
          if (ch === ' ') continue;
          const a = alphaAt((i + 0.5) * S.cw, py);
          if (a < 0.008) continue;
          o.fillStyle = `rgba(160,170,190,${a.toFixed(3)})`;
          o.fillText(ch, i * S.cw, py);
        }
      }
      field = off;
      return true;
    }
    function draw() {
      const { ctx, W, H, cw } = S;
      ctx.clearRect(0, 0, W, H);
      ctx.drawImage(field, 0, 0, W, H);
      if (light.a <= 0.01) return;
      const i0 = Math.max(0, Math.floor((light.x - light.r) / cw)), i1 = Math.ceil((light.x + light.r) / cw);
      const j0 = Math.max(0, Math.floor((light.y - light.r) / 15)), j1 = Math.ceil((light.y + light.r) / 15);
      for (let j = j0; j <= j1; j++) {
        const py = (j + 0.5) * 15;
        for (let i = i0; i <= i1; i++) {
          const ch = fieldChar(i, j);
          if (ch === ' ') continue;
          const px = (i + 0.5) * cw, dd = Math.hypot(px - light.x, py - light.y);
          if (dd >= light.r) continue;
          const a = 0.24 * light.a * Math.pow(1 - dd / light.r, 2) * (alphaAt(px, py) / 0.042);
          if (a < 0.01) continue;
          ctx.fillStyle = `rgba(190,200,220,${Math.min(0.5, a).toFixed(3)})`;
          ctx.fillText(ch, i * cw, py);
        }
      }
    }
    function frame() {
      raf = 0;
      light.x += (light.tx - light.x) * 0.2; light.y += (light.ty - light.y) * 0.2; light.a += (light.ta - light.a) * 0.12;
      const moving = Math.abs(light.tx - light.x) > 0.4 || Math.abs(light.ty - light.y) > 0.4 || Math.abs(light.ta - light.a) > 0.01;
      if (!moving) light.a = light.ta;
      draw();
      if (moving) raf = requestAnimationFrame(frame);
    }
    const kick = () => { if (!raf) raf = requestAnimationFrame(frame); };
    function start() {
      if (!layout()) return;
      if (!texture && !still()) { canvas.style.opacity = '0'; canvas.style.transition = 'opacity 900ms ease-out'; requestAnimationFrame(() => { canvas.style.opacity = '1'; }); }
      draw();
    }
    start();
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { if (layout()) draw(); });
    let rt = 0;
    window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(() => { if (layout()) draw(); }, 120); });
    if (!texture && finePointer) {
      host.addEventListener('pointermove', (e) => {
        if (still()) return;
        const r = canvas.getBoundingClientRect();
        light.tx = e.clientX - r.left; light.ty = e.clientY - r.top;
        if (light.a < 0.01) { light.x = light.tx; light.y = light.ty; }
        light.ta = 1; kick();
      });
      host.addEventListener('pointerleave', () => { light.ta = 0; kick(); });
    }
  });

  // The last call: the mark alone, small; it comes up from the seam once when first seen.
  document.querySelectorAll('canvas[data-codeart="mark"]').forEach((canvas) => {
    let S = null, L = null, t0 = 0, raf = 0, done = false;
    function layout() {
      S = surface(canvas, Math.min(3, Math.max(2, (window.devicePixelRatio || 1) * 1.5)), 8.5);
      if (!S.W) return false;
      L = { cx: S.W / 2, cy: S.H / 2, R: Math.min(S.W, S.H) / 2 / 1.2, LH: 10.5 };
      return true;
    }
    function draw(now) {
      const t = done ? Infinity : now - t0;
      S.ctx.clearRect(0, 0, S.W, S.H);
      paintSeam(S, L, done ? 1 : easeOut(t / 450), done ? 1 : smooth(t / 200));
      paintHalves(S, L, { t });
    }
    function frame(now) { raf = 0; if (now - t0 >= 1500) done = true; draw(now); if (!done) raf = requestAnimationFrame(frame); }
    onFirstSight(canvas, () => {
      if (!layout()) return;
      if (still()) { done = true; draw(0); return; }
      t0 = performance.now(); raf = requestAnimationFrame(frame);
    });
  });

  // MARK: Scenes: the home page as a presentation
  // Each [data-scene] pins while it plays (CSS, .js-scenes). On every scroll frame it gets --p, its progress
  // from 0 (its top reaches the top of the window) to 1 (its bottom reaches the bottom); each part with
  // data-r="a b" gets --t, the same progress mapped onto [a, b]. CSS turns those into motion; the hooks
  // below draw what CSS cannot. Counts ([data-count]) climb with the --t of the part they sit in.

  // Scene scripts (assets/scenes/<scene>.js, loaded before this file) queue a function on
  // window.LumenScenes; each is called here with the engine's helpers, before the first frame. A script
  // that comes later is called at once.
  const sceneAPI = {
    scenesOn, still, reduced, shot, finePointer, onScene, onFirstSight, clamp01, smooth, easeOut, easeInOut,
    codeart: { surface, paintHalves, paintSeam, tokenMaps, mirror, MONO, CODE },
  };
  const queued = Array.isArray(window.LumenScenes) ? window.LumenScenes : [];
  window.LumenScenes = { push: (fn) => fn(sceneAPI) };
  queued.forEach((fn) => { try { fn(sceneAPI); } catch (e) { console.error(e); } });

  if (scenesOn) {
    const scenes = Array.from(document.querySelectorAll('[data-scene]')).map((el) => ({
      el, name: el.dataset.scene, last: -1,
      parts: Array.from(el.querySelectorAll('[data-r]')).map((part) => {
        const [a, b] = part.dataset.r.split(' ').map(Number);
        return { part, a, b, last: -1, counts: Array.from(part.querySelectorAll('[data-count]')).map((n) => ({ n, to: +n.dataset.count })) };
      }),
    }));
    /// One scene at progress p: its --p, every part's --t and counts, then the scene's hooks.
    function apply(s, p) {
      if (Math.abs(p - s.last) < 0.0002) return;
      s.last = p;
      s.el.style.setProperty('--p', p.toFixed(4));
      for (const q of s.parts) {
        const t = clamp01((p - q.a) / (q.b - q.a));
        if (Math.abs(t - q.last) < 0.0002) continue;
        q.last = t;
        q.part.style.setProperty('--t', t.toFixed(4));
        q.counts.forEach((c) => { c.n.textContent = String(Math.round(c.to * easeOut(t))); });
      }
      (SCENE[s.name] || []).forEach((fn) => fn(p, s.el));
    }
    if (root.classList.contains('film')) {
      // The promo film (tools/film) plays the scenes by its own clock instead of the scroll.
      window.LumenFilm = { play(name, p) { scenes.forEach((s) => { if (s.name === name) apply(s, clamp01(p)); }); } };
    } else {
      let ticking = false;
      const update = () => {
        ticking = false;
        const vh = window.innerHeight;
        for (const s of scenes) {
          const r = s.el.getBoundingClientRect();
          if (r.bottom < -vh || r.top > vh * 2) continue;
          const total = r.height - vh;
          apply(s, total > 0 ? clamp01(-r.top / total) : (r.top <= 0 ? 1 : 0));
        }
      };
      const onScroll = () => { if (!ticking) { ticking = true; requestAnimationFrame(update); } };
      window.addEventListener('scroll', onScroll, { passive: true });
      window.addEventListener('resize', () => { scenes.forEach((s) => { s.last = -1; s.parts.forEach((q) => { q.last = -1; }); }); onScroll(); });
      update();
    }
  }
})();
