// 70.5–75.0 s: the two halves of the mark come together, the seam lights, LUMEN; the line the site ends with and
// its button. Domain: lumenbrowser.io (the owner's decision, design/site/README.md on claude/site-prototype).
(function () {
  'use strict';
  const F = window.Film, UI = window.UI;
  const E = F.ease;
  const f = (n) => n.toFixed(2);

  F.fastRange(70.5, 71.35, 4); // the halves flying in
  F.scene({
    id: 'final', t0: 70.5, t1: 75.0, z: 20,
    build(el) {
      el.innerHTML = `
        <div class="fill" data-k="halo"></div>
        <svg class="fill" width="1920" height="1080" viewBox="0 0 1920 1080">
          <defs>
            <filter id="fz-glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="8"/></filter>
            <radialGradient id="fz-disc" cx="38%" cy="34%" r="75%"><stop offset="0%" stop-color="#FFFFFF"/><stop offset="60%" stop-color="#EEF1F8"/><stop offset="100%" stop-color="#D9DEEA"/></radialGradient>
          </defs>
          <path data-k="h0" fill="url(#fz-disc)"/><path data-k="h1" fill="url(#fz-disc)"/>
          <line data-k="sg" stroke="#6F8FEA" stroke-width="12" stroke-linecap="round" filter="url(#fz-glow)"/>
          <line data-k="sc" stroke="#C9D7FF" stroke-width="2" stroke-linecap="round"/>
        </svg>
        <div class="abs" data-k="word" style="left:0;top:0">${UI.wordmark(58, '#F4F4F5')}</div>
        <div class="abs" data-k="tag" style="left:0;right:0;top:590px;text-align:center"><div class="sub" style="font-size:30px;color:var(--t2)" data-k="tagt">Мультиаккаунт-браузер для Mac</div></div>
        <div class="abs" data-k="cta" style="left:0;right:0;top:672px;display:flex;justify-content:center;align-items:center;gap:30px">
          <div style="height:60px;padding:0 32px;border-radius:30px;background:#2F6BEF;color:#fff;display:flex;align-items:center;font-size:21px;font-weight:600;box-shadow:inset 0 1px 0 rgba(255,255,255,0.22),0 12px 40px rgba(47,107,239,0.35)">Попробуйте бесплатно</div>
          <div style="font-size:23px;color:#AFC2F5;font-weight:500">lumenbrowser.io</div>
        </div>`;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
      F.words(this.k.tagt);
      const svg = this.k.word.querySelector('svg');
      this.wordW = parseFloat(svg.getAttribute('width'));
    },
    update(lt, t, el) {
      const k = this.k;
      F.opacity(el, F.seg(lt, 0, 0.3));
      // the halves arrive from far apart along the seam and meet with the mark's gap
      const meet = F.seg(lt, 0.0, 1.05, E.entry);
      const shrink = F.seg(lt, 1.15, 1.95, E.camera);
      const R = F.lerp(150, 58, shrink);
      const lockW = 2 * R + 30 + this.wordW * shrink;
      const cx = F.lerp(960, 960 - lockW / 2 + R, shrink), cy = F.lerp(500, 470, shrink);
      const gap = (3 / 19) * R, slide = (6 / 19) * R + (1 - meet) * 900;
      const spread = (1 - meet) * 80;
      k.h0.setAttribute('d', F.halfPath(-1, cx - F.SN[0] * spread, cy - F.SN[1] * spread, R, gap, slide));
      k.h1.setAttribute('d', F.halfPath(1, cx + F.SN[0] * spread, cy + F.SN[1] * spread, R, gap, slide));
      F.opacity(k.h0, F.seg(lt, 0.0, 0.5));
      F.opacity(k.h1, F.seg(lt, 0.0, 0.5));
      // the seam lights as they meet
      const lit = F.seg(lt, 0.85, 1.25, E.out) * (1 - 0.5 * F.seg(lt, 1.6, 2.6, E.inOut));
      const L = R * 1.0;
      for (const ln of [k.sg, k.sc]) {
        ln.setAttribute('x1', f(cx - F.SD[0] * L)); ln.setAttribute('y1', f(cy - F.SD[1] * L));
        ln.setAttribute('x2', f(cx + F.SD[0] * L)); ln.setAttribute('y2', f(cy + F.SD[1] * L));
      }
      F.opacity(k.sg, lit);
      F.opacity(k.sc, lit);
      k.sg.setAttribute('stroke-width', f(12 * R / 150));
      const halo = F.seg(lt, 0.6, 1.5, E.out) * F.lerp(1, 0.55, shrink);
      F.css(k.halo, 'background',
        UI.softDisc(cx, cy, R * 1.08, R * 0.25, '220,228,248', 0.42 * halo) + ', ' +
        UI.softDisc(cx, cy, R * 1.4, R * 0.7, '160,184,252', 0.2 * halo) + ', ' +
        UI.softDisc(cx, cy, R * 2.2, R * 1.6, '111,143,234', 0.1 * halo));
      // LUMEN written in
      const wx = cx + R + 30, wy = cy - 29;
      F.transform(k.word, `translate(${f(wx)}px, ${f(wy)}px)`);
      const wr = F.seg(lt, 1.3, 2.1, E.camera);
      F.css(k.word, 'clip-path', `inset(-20px ${f((1 - wr) * 100)}% -20px -20px)`);
      F.opacity(k.word, F.seg(lt, 1.25, 1.5));
      F.reveal(k.tagt, lt, 1.9, { stagger: 0.07 });
      const ck = F.seg(lt, 2.4, 3.2, E.entry);
      F.opacity(k.cta, ck);
      F.blur(k.cta, (1 - ck) * 8);
      F.transform(k.cta, `translateY(${f((1 - ck) * 18)}px)`);
    },
  });
})();
