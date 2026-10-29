// Lumen website prototype — the little JavaScript the pages use. Everything works without it:
// the content is in the HTML, menus and FAQ are <details>, the billing switch is CSS, and the hero
// demonstration shows its final state. This file only adds motion and conveniences:
//   - reveal on scroll (once, 240 ms), never with Reduce Motion;
//   - the hero demonstration: a profile launched through its proxy, then warmed up (plays once);
//   - the local navigation's active section (features, docs);
//   - copy buttons on code;
//   - the prototype's strip (decision marks, Reduce Motion stand-in).
(function () {
  'use strict';
  const root = document.documentElement;
  const media = window.matchMedia('(prefers-reduced-motion: reduce)');
  const reduced = () => media.matches || root.classList.contains('rm');
  const shot = root.classList.contains('shot');

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

  // MARK: Home: the scene comes together once
  document.querySelectorAll('.stage').forEach((stage) => {
    if (shot || reduced()) { stage.classList.add('in'); return; }
    requestAnimationFrame(() => requestAnimationFrame(() => stage.classList.add('in')));
  });

  // MARK: Home: "proxy down, IP hidden" — switches itself once when first seen, then waits for clicks
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

  // MARK: Home: the warm-up card counts its cookies once, when first seen
  document.querySelectorAll('[data-warm]').forEach((card) => {
    const n = card.querySelector('[data-count-to]');
    const bar = card.querySelector('.wbar i');
    if (!n || shot || reduced() || !('IntersectionObserver' in window)) return;
    const to = +n.getAttribute('data-count-to');
    const width = bar ? bar.style.width : '';
    n.textContent = '0';
    if (bar) bar.style.width = '0%';
    const io = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      if (bar) bar.style.width = width;
      const t0 = performance.now(), dur = 1400;
      const tick = (t) => {
        const p = Math.min(1, (t - t0) / dur);
        n.textContent = String(Math.round(to * (1 - Math.pow(1 - p, 3))));
        if (p < 1) requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }, { threshold: 0.5 });
    io.observe(card);
  });

  // MARK: Home v3: the split planet
  // A dotted globe (land points from world.js) in orthographic projection, cut by the mark's steep seam
  // (one across for three up); on first sight its halves slide apart along the seam to the mark's
  // proportions (gap 3, slide 6 of radius 19), then it turns slowly while it is on screen. Profiles' exit
  // countries carry chips. Reduce Motion: drawn once, split, still.
  document.querySelectorAll('[data-globe]').forEach((canvas) => {
    const raw = window.LUMEN_WORLD;
    if (!raw || !canvas.getContext) return;
    const wrap = canvas.closest('[data-globe-wrap]');
    const chips = Array.from(wrap.querySelectorAll('.gchip'));
    const bin = atob(raw);
    const count = bin.length / 4;
    const P = new Float32Array(count * 3);
    const i16 = (k) => { const v = bin.charCodeAt(k) | (bin.charCodeAt(k + 1) << 8); return v & 0x8000 ? v - 0x10000 : v; };
    const toVec = (latDeg, lonDeg, out, o) => {
      const lat = latDeg * Math.PI / 180, lon = lonDeg * Math.PI / 180;
      out[o] = Math.cos(lat) * Math.sin(lon); out[o + 1] = Math.sin(lat); out[o + 2] = Math.cos(lat) * Math.cos(lon);
    };
    for (let i = 0; i < count; i++) toVec(i16(i * 4) / 100, i16(i * 4 + 2) / 100, P, i * 3);
    const pins = chips.map((c) => { const v = new Float32Array(3); toVec(+c.dataset.lat, +c.dataset.lon, v, 0); return v; });
    const ctx = canvas.getContext('2d');
    const SL = Math.hypot(1, 3), D = { x: 1 / SL, y: -3 / SL }, N = { x: -D.y, y: D.x };
    const TILT = 0.36, LAMBDA0 = 25 * Math.PI / 180, SPEED = 0.03; // radians, radians per second
    let W = 0, H = 0, dpr = 1, cx = 0, cy = 0, R = 0, lambda = LAMBDA0, split = 0, t0 = 0, last = 0, raf = 0, running = false;
    const still = () => shot || reduced();

    function layout() {
      const r = canvas.getBoundingClientRect();
      dpr = Math.min(2, window.devicePixelRatio || 1);
      W = r.width; H = r.height;
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
      const wide = W >= 900;
      cx = wide ? W * 0.735 : W / 2;
      cy = wide ? H * 0.5 : H * 0.5;
      R = wide ? Math.min(H * 0.40, W * 0.255) : Math.min(W * 0.40, H * 0.40);
    }

    function project(v, out) {
      const cl = Math.cos(lambda), sl = Math.sin(lambda), ct = Math.cos(TILT), st = Math.sin(TILT);
      const x1 = v[0] * cl + v[2] * sl, z1 = -v[0] * sl + v[2] * cl, y1 = v[1];
      const y2 = y1 * ct - z1 * st, z2 = y1 * st + z1 * ct;
      out.x = cx + R * x1; out.y = cy - R * y2; out.z = z2;
      return out;
    }

    const BUCKETS = 7;
    function draw(elapsed) {
      const gap = (R * 3 / 19) * 0.85 * split, slide = (R * 6 / 19) * 0.85 * split;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, W, H);
      // A faint haze behind the planet.
      const haze = ctx.createRadialGradient(cx, cy, R * 0.15, cx, cy, R * 1.5);
      haze.addColorStop(0, 'rgba(94,132,235,0.11)'); haze.addColorStop(1, 'rgba(94,132,235,0)');
      ctx.fillStyle = haze; ctx.fillRect(0, 0, W, H);
      // The two halves' outlines and bodies, as in the mark.
      for (const side of [1, -1]) {
        const ox = side * slide / 2 * D.x, oy = side * slide / 2 * D.y;
        const h = side * gap / 2, half = Math.sqrt(Math.max(0, R * R - h * h));
        const ax = cx + ox + N.x * h - D.x * half, ay = cy + oy + N.y * h - D.y * half;
        const bx = cx + ox + N.x * h + D.x * half, by = cy + oy + N.y * h + D.y * half;
        const angA = Math.atan2(ay - cy - oy, ax - cx - ox), angB = Math.atan2(by - cy - oy, bx - cx - ox);
        ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo(bx, by);
        ctx.arc(cx + ox, cy + oy, R, angB, angA, side < 0);
        ctx.closePath();
        ctx.fillStyle = 'rgba(111,143,234,0.035)'; ctx.fill();
        ctx.strokeStyle = 'rgba(255,255,255,0.09)'; ctx.lineWidth = 1; ctx.stroke();
      }
      // Land.
      const paths = Array.from({ length: BUCKETS }, () => new Path2D());
      const q = { x: 0, y: 0, z: 0 };
      for (let i = 0; i < count; i++) {
        project([P[i * 3], P[i * 3 + 1], P[i * 3 + 2]], q);
        if (q.z <= 0.02) continue;
        const dist = (q.x - cx) * N.x + (q.y - cy) * N.y;
        if (Math.abs(dist) < gap / 2) continue;
        const side = dist >= 0 ? 1 : -1;
        const x = q.x + side * slide / 2 * D.x, y = q.y + side * slide / 2 * D.y;
        const b = Math.min(BUCKETS - 1, Math.floor(q.z * BUCKETS));
        const r = 0.65 + q.z * 1.0;
        paths[b].moveTo(x + r, y); paths[b].arc(x, y, r, 0, Math.PI * 2);
      }
      for (let b = 0; b < BUCKETS; b++) {
        ctx.fillStyle = `rgba(124,152,236,${(0.16 + 0.7 * (b + 0.5) / BUCKETS).toFixed(3)})`;
        ctx.fill(paths[b]);
      }
      // Exit countries.
      chips.forEach((chip, k) => {
        project(pins[k], q);
        const dist = (q.x - cx) * N.x + (q.y - cy) * N.y, side = dist >= 0 ? 1 : -1;
        const x = q.x + side * slide / 2 * D.x, y = q.y + side * slide / 2 * D.y;
        const face = Math.max(0, Math.min(1, (q.z - 0.08) / 0.25));
        const appear = still() ? 1 : Math.max(0, Math.min(1, (elapsed - 1000 - k * 140) / 240));
        const a = face * appear;
        if (a > 0.01) {
          ctx.beginPath(); ctx.arc(x, y, 7, 0, Math.PI * 2); ctx.strokeStyle = `rgba(169,189,245,${0.4 * a})`; ctx.lineWidth = 1.2; ctx.stroke();
          ctx.beginPath(); ctx.arc(x, y, 3.2, 0, Math.PI * 2); ctx.fillStyle = `rgba(214,224,252,${a})`; ctx.fill();
        }
        chip.style.opacity = a.toFixed(3);
        const left = chip.dataset.side === 'l';
        chip.style.transform = `translate(${Math.round(left ? x - 12 - chip.offsetWidth : x + 12)}px, ${Math.round(y - 15)}px)`;
      });
    }

    function tick(now) {
      if (!running) return;
      if (!t0) { t0 = now; last = now; }
      const elapsed = now - t0;
      const p = Math.max(0, Math.min(1, (elapsed - 200) / 1100));
      split = 1 - Math.pow(1 - p, 3);
      lambda += SPEED * Math.min(64, now - last) / 1000;
      last = now;
      draw(elapsed);
      raf = requestAnimationFrame(tick);
    }
    function start() { if (running || still()) return; running = true; last = 0; raf = requestAnimationFrame((n) => { last = n; tick(n); }); }
    function stop() { running = false; cancelAnimationFrame(raf); }

    layout();
    if (still()) { split = 1; draw(1e9); }
    window.addEventListener('resize', () => { layout(); if (still()) draw(1e9); });
    if ('IntersectionObserver' in window) {
      new IntersectionObserver((entries) => { entries.forEach((e) => (e.isIntersecting && !document.hidden ? start() : stop())); }, { threshold: 0.05 }).observe(canvas);
    } else start();
    document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); else if (canvas.getBoundingClientRect().bottom > 0) start(); });
  });

  // MARK: Home v3: the tiles play once when first seen, and again on hover
  const TILE = {
    safari(el, done) {
      const rows = Array.from(el.querySelectorAll('.srow')), bar = el.querySelector('.scanbar'), foot = el.querySelector('.sfoot');
      rows.forEach((r) => r.classList.remove('ok'));
      foot.style.opacity = '0';
      const step = 190, h = rows[0] ? rows[0].offsetHeight : 40;
      bar.style.transform = 'translateY(0)';
      later(120, () => { bar.style.opacity = '1'; });
      rows.forEach((r, i) => {
        later(200 + i * step, () => { bar.style.transform = `translateY(${i * h}px)`; });
        later(320 + i * step, () => r.classList.add('ok'));
      });
      later(320 + rows.length * step, () => { bar.style.opacity = '0'; foot.style.opacity = '1'; done(); });
    },
    proxy(el, done) {
      const route = el.querySelector('.route');
      route.classList.remove('down', 'flow');
      void route.offsetWidth;
      later(150, () => route.classList.add('flow'));
      later(1500, () => { route.classList.remove('flow'); route.classList.add('down'); done(); });
    },
    isolation(el, done) {
      const sp = el.querySelector('.split');
      sp.classList.remove('on');
      void sp.offsetWidth;
      later(250, () => sp.classList.add('on'));
      later(800, done);
    },
    warmup(el, done) {
      const n = el.querySelector('[data-count-to]'), bar = el.querySelector('.wbar i'), sites = Array.from(el.querySelectorAll('.wsites span'));
      const to = +n.dataset.countTo, width = '33.3%';
      sites.forEach((s, i) => { s.classList.toggle('done', false); s.classList.add('todo'); });
      bar.style.width = '0%'; n.textContent = '0';
      later(150, () => { bar.style.width = width; });
      const t0 = performance.now(), dur = 1400;
      const tick = (t) => { const p = Math.min(1, (t - t0) / dur); n.textContent = String(Math.round(to * (1 - Math.pow(1 - p, 3)))); if (p < 1) requestAnimationFrame(tick); else done(); };
      requestAnimationFrame(tick);
      sites.slice(0, 4).forEach((s, i) => later(250 + i * 300, () => { s.classList.remove('todo'); s.classList.add('done'); }));
    },
    encryption(el, done) {
      const rows = Array.from(el.querySelectorAll('.crow'));
      const AB = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
      rows.forEach((row, i) => {
        const bits = row.querySelector('[data-cipher]'), word = row.firstElementChild.textContent.toLowerCase();
        row.classList.add('busy'); bits.textContent = word;
        later(250 + i * 160, () => {
          const t0 = performance.now();
          const tick = (t) => {
            const p = (t - t0) / 520;
            if (p >= 1) { bits.textContent = '••••••••••••'; row.classList.remove('busy'); if (i === rows.length - 1) done(); return; }
            let s = '';
            for (let k = 0; k < 12; k++) s += k / 12 < p ? '•' : AB[(Math.random() * AB.length) | 0];
            bits.textContent = s;
            requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);
        });
      });
    },
  };
  let laterTimers = [];
  function later(ms, fn) { laterTimers.push(setTimeout(fn, ms)); }
  document.querySelectorAll('[data-tile]').forEach((el) => {
    const play = TILE[el.dataset.tile];
    if (!play || shot || reduced()) return;
    let busy = false, seen = false;
    const run = () => { if (busy) return; busy = true; play(el, () => { busy = false; }); };
    if ('IntersectionObserver' in window) {
      const io = new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting) && !seen) { seen = true; io.disconnect(); run(); } }, { threshold: 0.45 });
      io.observe(el);
    }
    if (matchMedia('(hover: hover) and (pointer: fine)').matches) el.addEventListener('mouseenter', () => { if (seen) run(); });
  });

  // MARK: Home v3: the three numbers count up once
  document.querySelectorAll('.proof3 [data-count-to]').forEach((n) => {
    const to = +n.dataset.countTo;
    if (!to || shot || reduced() || !('IntersectionObserver' in window)) return;
    n.textContent = '0';
    const io = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      const t0 = performance.now(), dur = to > 100 ? 1300 : 900;
      const tick = (t) => { const p = Math.min(1, (t - t0) / dur); n.textContent = String(Math.round(to * (1 - Math.pow(1 - p, 3)))); if (p < 1) requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
    }, { threshold: 0.6 });
    io.observe(n);
  });

  // MARK: The hero demonstration

  document.querySelectorAll('[data-demo-root]').forEach((demo) => {
    const L = JSON.parse(demo.getAttribute('data-labels') || '{}');
    const $ = (sel) => demo.querySelector(sel);
    const at = (name) => demo.querySelector(`[data-at="${name}"]`);
    const statusBox = $('[data-demo="status"]');
    const press = $('[data-demo="press"]');
    const cookiesEl = $('[data-demo="cookies"]');
    const pageEl = $('[data-demo="page"]');
    const bar = $('[data-demo="bar"]');
    const sites = Array.from(demo.querySelectorAll('[data-site]'));
    const TOTAL = 12, FINAL_PAGES = 4, FINAL_COOKIES = 84; // UISnapshots: Northwind, warm-up 4/12, cookies 84
    const ICON_PLAY = '<svg class="icon" width="12" height="12" viewBox="0 0 16 16" aria-hidden="true"><path d="M5.2 3.4L12.6 8L5.2 12.6Z" fill="currentColor" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></svg>';
    const ICON_STOP = '<svg class="icon" width="12" height="12" viewBox="0 0 16 16" aria-hidden="true"><rect x="4.2" y="4.2" width="7.6" height="7.6" rx="1.4" fill="currentColor"/></svg>';
    const CHECK = '<svg class="icon" width="10" height="10" viewBox="0 0 16 16" aria-hidden="true"><path d="M3.2 8.4l3 3 6.6-7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    const MINUS = '<svg class="icon" width="10" height="10" viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8h9" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';
    let timers = [];
    let raf = 0;

    function ring(fraction) {
      const size = 12, r = size / 2 - 1.25, c = 2 * Math.PI * r, done = Math.max(0.04, Math.min(1, fraction)) * c;
      return `<svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><circle cx="6" cy="6" r="${r}" fill="none" stroke="rgba(111,143,234,0.25)" stroke-width="2.5"/><circle cx="6" cy="6" r="${r}" fill="none" stroke="#6F8FEA" stroke-width="2.5" stroke-dasharray="${done.toFixed(2)} ${c.toFixed(2)}" transform="rotate(-90 6 6)"/></svg>`;
    }
    function setStatus(kind, pages = 0, cookies = 0) {
      let glyph, label, tail = '';
      if (kind === 'stopped') { glyph = '<i class="ring"></i>'; label = L.stopped; }
      else if (kind === 'starting') { glyph = '<i class="spin"></i>'; label = L.starting; }
      else if (kind === 'running') { glyph = '<i class="dot"></i>'; label = L.running; }
      else { glyph = ring(pages / TOTAL); label = `${L.warmup} ${pages}/${TOTAL}`; tail = ` · cookies: ${cookies}`; }
      statusBox.innerHTML = `<span class="status s-${kind}"><span class="glyph">${glyph}</span><span class="label">${label}</span>${tail ? `<span class="tail">${tail}</span>` : ''}</span>`;
      press.innerHTML = kind === 'stopped' ? ICON_PLAY : ICON_STOP;
    }
    function setSites(visited) {
      sites.forEach((s, k) => {
        s.classList.toggle('done', k < visited);
        s.classList.toggle('todo', k >= visited);
        s.classList.toggle('now', k === visited - 1);
        s.querySelector('svg').outerHTML = k < visited ? CHECK : MINUS;
      });
      if (pageEl) pageEl.textContent = String(Math.max(1, visited));
      if (bar) bar.style.width = `${(visited / TOTAL) * 100}%`;
    }
    const show = (name, on = true) => { const el = at(name); if (el) { el.classList.toggle('is-hidden', !on); el.classList.remove('is-off'); } };
    const off = (name, on = true) => { const el = at(name); if (el) el.classList.toggle('is-off', on); };
    const draw = (name, on = true) => { const el = at(name); if (el) el.classList.toggle('is-undrawn', !on); };

    function initial() {
      setStatus('stopped');
      ['process', 'proxy', 'sites'].forEach((n) => off(n));
      ['link1', 'link2'].forEach((n) => draw(n, false));
      ['direct', 'tz', 'lang', 'appears', 'warm', 'live'].forEach((n) => show(n, false));
      press.classList.remove('on');
      cookiesEl.textContent = '0';
      setSites(0);
      demo.setAttribute('data-step', '0');
    }
    function final() {
      timers.forEach(clearTimeout); timers = [];
      cancelAnimationFrame(raf);
      ['process', 'proxy', 'sites'].forEach((n) => off(n, false));
      ['link1', 'link2'].forEach((n) => draw(n, true));
      ['direct', 'tz', 'lang', 'appears', 'warm', 'live'].forEach((n) => show(n, true));
      press.classList.remove('on');
      setStatus('warmup', FINAL_PAGES, FINAL_COOKIES);
      cookiesEl.textContent = String(FINAL_COOKIES);
      setSites(FINAL_PAGES);
      demo.setAttribute('data-step', 'final');
    }
    const later = (ms, fn) => timers.push(setTimeout(fn, ms));

    function play() {
      timers.forEach(clearTimeout); timers = [];
      cancelAnimationFrame(raf);
      initial();
      if (reduced()) {
        // No motion: three plain states, each shown for a moment.
        later(500, () => { setStatus('running'); ['process', 'proxy', 'sites'].forEach((n) => off(n, false)); ['link1', 'link2'].forEach((n) => draw(n, true)); ['direct', 'tz', 'lang', 'appears', 'live'].forEach((n) => show(n)); });
        later(1300, final);
        return;
      }
      later(450, () => { press.classList.add('on'); });
      later(600, () => { press.classList.remove('on'); setStatus('starting'); off('process', false); });
      later(950, () => { draw('link1'); });
      later(1150, () => { off('proxy', false); });
      later(1450, () => { draw('link2'); });
      later(1650, () => { off('sites', false); show('live'); });
      later(2000, () => { show('direct'); });
      later(2350, () => { show('tz'); });
      later(2450, () => { show('lang'); });
      later(2800, () => { show('appears'); setStatus('running'); });
      later(3400, () => { show('warm'); setStatus('warmup', 1, 0); setSites(1); });
      // Pages 1 → 4 while the count rises to the sample's 84 (UISnapshots), then it stops.
      const start = 3400, perPage = 650;
      later(start, () => {
        const t0 = performance.now(), dur = perPage * (FINAL_PAGES - 1) + 300;
        const tick = (now) => {
          const p = Math.min(1, (now - t0) / dur);
          const pages = Math.min(FINAL_PAGES, 1 + Math.floor(((now - t0) / perPage)));
          const cookies = Math.round(FINAL_COOKIES * (1 - Math.pow(1 - p, 2)));
          cookiesEl.textContent = String(cookies);
          setStatus('warmup', pages, cookies);
          setSites(pages);
          if (p < 1) raf = requestAnimationFrame(tick); else final();
        };
        raf = requestAnimationFrame(tick);
      });
    }

    const replay = $('[data-demo="replay"]');
    if (replay) replay.addEventListener('click', play);
    if (shot) { final(); return; }
    // Plays once, when it is first seen; then it rests on its final state (nothing moves in rest).
    if ('IntersectionObserver' in window) {
      initial();
      const io = new IntersectionObserver((entries) => {
        if (entries.some((e) => e.isIntersecting)) { io.disconnect(); play(); }
      }, { threshold: 0.35 });
      io.observe(demo);
    } else {
      final();
    }
  });
})();
