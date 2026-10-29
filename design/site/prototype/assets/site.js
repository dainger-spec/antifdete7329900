// Lumen website prototype — the little JavaScript the pages use. Everything works without it:
// the content is in the HTML, menus and FAQ are <details>, the billing switch and the proxy demo are
// CSS, and every picture shows its final state. This file only adds motion and conveniences:
//   - reveal on scroll (once, 240 ms), never with Reduce Motion;
//   - home: the mark drawn in code (comes up once, then rests; a pointer is a soft light over it),
//     the tiles (each plays once when first seen, again on hover) and the three numbers (count once);
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
  // Each half is a profile: its own binary and a few of its own values (language, time zone), and the
  // seam between them is a line of light. "field": the first screen, a faint code texture with the figure
  // in [data-art]; "mark": the figure alone (the last call). On first sight the seam lights, the halves
  // part and the code comes up from the seam outwards, once (about 1.4 s); after that nothing moves by
  // itself. A mouse pointer is a soft light over the code. Reduce Motion and shots: drawn once, finished,
  // no light. Without JavaScript the plain mark stands in (.art-fallback). "texture": the same faint
  // code behind a page's title, still, stronger to the right so the words stay clear.
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
  const hash = (a, b, c) => { let h = (a * 73856093) ^ (b * 19349663) ^ (c * 83492791); h = Math.imul(h ^ (h >>> 13), 1274126177); return (h ^ (h >>> 16)) >>> 0; };
  const smooth = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x));
  const easeOut = (x) => 1 - Math.pow(1 - Math.min(1, Math.max(0, x)), 3);
  const easeInOut = (x) => { x = Math.min(1, Math.max(0, x)); return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
  const fieldChar = (i, j) => { const line = CODE[j % CODE.length] + '    '; return line[(i + j * 23) % line.length]; };

  document.querySelectorAll('canvas[data-codeart]').forEach((canvas) => {
    const kind = canvas.dataset.codeart;
    const host = canvas.parentElement;
    const anchor = kind === 'field' ? host.querySelector('[data-art]') : host;
    const texture = kind === 'texture';
    if (!anchor) return;
    const ctx = canvas.getContext('2d');
    const still = () => shot || reduced();
    let FS = 12, LH = 15, FONT = '';
    let W = 0, H = 0, cw = 7, cx = 0, cy = 0, R = 0, quiet = null, field = null, tok = [new Map(), new Map()];
    let fig = null, fctx = null, fx = 0, fy = 0, fbox = 0;
    const glow = 'filter' in ctx;
    let t0 = 0, started = false, done = false, raf = 0;
    const light = { x: 0, y: 0, tx: 0, ty: 0, a: 0, ta: 0 };
    const LR = 190;

    function layout() {
      const r = canvas.getBoundingClientRect();
      W = r.width; H = r.height;
      if (!W || !H) return false;
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
      if (texture) {
        FS = 12; LH = 15; FONT = `${FS}px ui-monospace, "SF Mono", Menlo, "DejaVu Sans Mono", monospace`;
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.font = FONT; ctx.textBaseline = 'middle';
        cw = ctx.measureText('0').width;
        field = drawField(dpr);
        return true;
      }
      const a = anchor.getBoundingClientRect();
      cx = a.left - r.left + a.width / 2; cy = a.top - r.top + a.height / 2;
      R = Math.min(a.width, a.height) / 2 / 1.2;
      // The grid gets finer as the figure gets smaller, so the disc keeps its shape on a phone.
      FS = R > 200 ? 12 : R > 120 ? 10 : 8.5; LH = Math.round(FS * 1.24 * 2) / 2;
      FONT = `${FS}px ui-monospace, "SF Mono", Menlo, "DejaVu Sans Mono", monospace`;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.font = FONT; ctx.textBaseline = 'middle';
      cw = ctx.measureText('0').width;
      fbox = Math.ceil(2.7 * R); fx = cx - fbox / 2; fy = cy - fbox / 2;
      fig = document.createElement('canvas'); fig.width = Math.ceil(fbox * dpr); fig.height = Math.ceil(fbox * dpr);
      fctx = fig.getContext('2d'); fctx.setTransform(dpr, 0, 0, dpr, 0, 0); fctx.font = FONT; fctx.textBaseline = 'middle';
      const text = kind === 'field' && host.querySelector('.hero4-text');
      const tr = text && text.getBoundingClientRect();
      quiet = tr ? { l: tr.left - r.left, t: tr.top - r.top, r: tr.right - r.left, b: tr.bottom - r.top } : null;
      tok = kind === 'field' && R > 200 ? TOKENS.map((list) => {
        const m = new Map();
        list.forEach(([v, u, s]) => {
          const r0 = Math.round(v * R / LH), c0 = Math.round(u * R / cw);
          m.set(r0 * 10000 + c0 - 1, ' '); m.set(r0 * 10000 + c0 + s.length, ' ');
          for (let k = 0; k < s.length; k++) m.set(r0 * 10000 + c0 + k, s[k]);
        });
        return m;
      }) : [new Map(), new Map()];
      field = kind === 'field' ? drawField(dpr) : null;
      return true;
    }

    // The faint code all over the first screen: quieter behind the words, a dark halo round the figure.
    function fieldAlpha(px, py) {
      const d = Math.hypot(px - cx, py - cy) / R;
      let a = (0.034 + 0.05 * Math.exp(-Math.pow((d - 1.4) / 0.55, 2))) * smooth((d - 1.22) / 0.3);
      a *= (0.25 + 0.75 * smooth((py - 40) / 160)) * smooth((H - py) / 180);
      if (quiet) { const out = Math.max(quiet.l - px, px - quiet.r, quiet.t - py, py - quiet.b, 0); a *= 0.4 + 0.6 * smooth(out / 140); }
      return a;
    }
    const textureAlpha = (px, py) => 0.05 * smooth((px / W) * 1.5 - 0.4) * smooth((H - py) / 140) * (0.3 + 0.7 * smooth((py - 30) / 140));
    function drawField(dpr) {
      const alpha = texture ? textureAlpha : fieldAlpha;
      const off = document.createElement('canvas');
      off.width = canvas.width; off.height = canvas.height;
      const o = off.getContext('2d');
      o.setTransform(dpr, 0, 0, dpr, 0, 0); o.font = FONT; o.textBaseline = 'middle';
      const cols = Math.ceil(W / cw), rows = Math.ceil(H / LH);
      for (let j = 0; j < rows; j++) {
        const py = (j + 0.5) * LH;
        for (let i = 0; i < cols; i++) {
          const ch = fieldChar(i, j);
          if (ch === ' ') continue;
          const a = alpha((i + 0.5) * cw, py);
          if (a < 0.008) continue;
          o.fillStyle = `rgba(160,170,190,${a.toFixed(3)})`;
          o.fillText(ch, i * cw, py);
        }
      }
      return off;
    }

    function drawSeam(len, alpha) {
      const l = R * 1.02 * len;
      const line = () => { ctx.beginPath(); ctx.moveTo(cx - SD[0] * l, cy - SD[1] * l); ctx.lineTo(cx + SD[0] * l, cy + SD[1] * l); ctx.stroke(); };
      ctx.save();
      ctx.lineCap = 'round';
      ctx.shadowColor = 'rgba(111,143,234,0.9)';
      ctx.shadowBlur = 26; ctx.lineWidth = 7; ctx.strokeStyle = `rgba(111,143,234,${(0.2 * alpha).toFixed(3)})`; line();
      ctx.shadowBlur = 8; ctx.lineWidth = 1.3; ctx.strokeStyle = `rgba(178,198,255,${(0.9 * alpha).toFixed(3)})`; line();
      ctx.restore();
    }

    function draw(now) {
      const t = done ? Infinity : now - t0;
      ctx.clearRect(0, 0, W, H);
      if (texture) { ctx.drawImage(field, 0, 0, W, H); return; }
      if (field) { ctx.globalAlpha = done ? 1 : smooth(t / 900); ctx.drawImage(field, 0, 0, W, H); ctx.globalAlpha = 1; }
      const k = done ? 1 : easeInOut((t - 300) / 1000);
      const ox = k * (GAP / 2 * SN[0] + SLIDE / 2 * SD[0]), oy = k * (GAP / 2 * SN[1] + SLIDE / 2 * SD[1]);
      drawSeam(done ? 1 : easeOut(t / 450), done ? 1 : smooth(t / 200));
      fctx.clearRect(0, 0, fbox, fbox);
      const lit = light.a > 0.01;
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
          const r2 = qx * qx + qy * qy, z = Math.sqrt(1 - r2);
          const shade = Math.max(0, qx * LIGHT[0] + qy * LIGHT[1] + z * LIGHT[2]);
          const lc = Math.round(qx * R / cw), lr = Math.round(qy * R / LH);
          const h = hash(lc, lr, half);
          const fromSeam = Math.abs(qx * SN[0] + qy * SN[1]) * R;
          const edge = fromSeam < cw * 1.4;
          const tk = tok[half].get(lr * 10000 + lc);
          if (tk === ' ') continue;
          let a = 0.07 + 0.86 * Math.pow(shade, 1.9) + 0.22 * Math.pow(shade, 14) + ((h >>> 9) & 15) / 160 - 0.045;
          if (r2 > 0.92) a += 0.08;
          if (edge) a += 0.25;
          if (tk) a += 0.12;
          if (!done) a *= smooth((t - 150 - fromSeam * 1.5) / 380);
          if (lit) { const dx = px - light.x, dy = py - light.y, dd = Math.sqrt(dx * dx + dy * dy); if (dd < LR) a += 0.32 * light.a * Math.pow(1 - dd / LR, 2); }
          if (a < 0.03) continue;
          fctx.fillStyle = `rgba(${edge ? EDGE_RGB : HALF_RGB[half]},${Math.min(1, a).toFixed(3)})`;
          fctx.fillText(tk || ((h >>> 3) & 1 ? '1' : '0'), i * cw - fx, py - fy);
        }
      }
      // A soft glow under the characters (the figure blurred once), then the characters themselves.
      if (glow) { ctx.save(); ctx.filter = `blur(${Math.max(4, FS * 0.6)}px)`; ctx.globalAlpha = 0.7; ctx.drawImage(fig, fx, fy, fbox, fbox); ctx.restore(); }
      ctx.drawImage(fig, fx, fy, fbox, fbox);
      if (lit && field) {
        // Under the light the faint code reads: what each profile is.
        const i0f = Math.max(0, Math.floor((light.x - LR) / cw)), i1f = Math.ceil((light.x + LR) / cw);
        const j0f = Math.max(0, Math.floor((light.y - LR) / LH)), j1f = Math.ceil((light.y + LR) / LH);
        for (let j = j0f; j <= j1f; j++) {
          const py = (j + 0.5) * LH;
          for (let i = i0f; i <= i1f; i++) {
            const ch = fieldChar(i, j);
            if (ch === ' ') continue;
            const px = (i + 0.5) * cw, dd = Math.hypot(px - light.x, py - light.y);
            if (dd >= LR) continue;
            const a = 0.24 * light.a * Math.pow(1 - dd / LR, 2) * (fieldAlpha(px, py) / 0.1);
            if (a < 0.01) continue;
            ctx.fillStyle = `rgba(190,200,220,${Math.min(0.5, a).toFixed(3)})`;
            ctx.fillText(ch, i * cw, py);
          }
        }
      }
    }

    function frame(now) {
      raf = 0;
      if (!done && now - t0 >= 1700) done = true;
      light.x += (light.tx - light.x) * 0.2; light.y += (light.ty - light.y) * 0.2; light.a += (light.ta - light.a) * 0.12;
      const moving = Math.abs(light.tx - light.x) > 0.4 || Math.abs(light.ty - light.y) > 0.4 || Math.abs(light.ta - light.a) > 0.01;
      if (!moving) light.a = light.ta;
      draw(now);
      if (!done || moving) raf = requestAnimationFrame(frame);
    }
    const kick = () => { if (!raf && started && !still()) raf = requestAnimationFrame(frame); };

    function start() {
      if (started || !layout()) return;
      started = true;
      if (still() || texture) { done = true; anchor.classList.add('in'); draw(0); return; }
      t0 = performance.now();
      setTimeout(() => anchor.classList.add('in'), 1150);
      kick();
    }
    if (still() || !('IntersectionObserver' in window)) start();
    else {
      const io = new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting)) { io.disconnect(); start(); } }, { threshold: 0.2 });
      io.observe(canvas);
    }
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { if (started && layout()) { if (done) draw(0); else kick(); } });
    let rt = 0;
    window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(() => { if (started && layout()) { if (done) draw(0); else kick(); } }, 120); });
    if (kind === 'field' && matchMedia('(hover: hover) and (pointer: fine)').matches) {
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

  // MARK: Home: the tiles play once when first seen, and again on hover
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
      // Each value wipes into dots, left to right: no random letters, nothing flickers.
      const rows = Array.from(el.querySelectorAll('.crow'));
      rows.forEach((row, i) => {
        const bits = row.querySelector('[data-cipher]'), word = row.firstElementChild.textContent.toLowerCase().padEnd(12, ' ');
        row.classList.add('busy'); bits.textContent = word;
        later(300 + i * 180, () => {
          const t0 = performance.now();
          const tick = (t) => {
            const p = Math.min(1, (t - t0) / 640);
            let s = '';
            for (let k = 0; k < 12; k++) s += k / 12 < p ? '•' : word[k];
            bits.textContent = s;
            if (p < 1) { requestAnimationFrame(tick); return; }
            row.classList.remove('busy');
            if (i === rows.length - 1) done();
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

  // MARK: Home: the three numbers count up once
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
})();
