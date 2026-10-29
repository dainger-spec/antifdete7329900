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
    const cls = kind === 'tbd' ? 'no-tbd' : 'rm';
    const sync = () => b.classList.toggle('on', kind === 'tbd' ? !root.classList.contains('no-tbd') : root.classList.contains('rm'));
    sync();
    b.addEventListener('click', () => {
      root.classList.toggle(cls);
      try { localStorage.setItem(kind === 'tbd' ? 'lumen-site-tbd' : 'lumen-site-rm', root.classList.contains(cls) ? (kind === 'tbd' ? '0' : '1') : (kind === 'tbd' ? '1' : '0')); } catch (e) { /* private mode */ }
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
