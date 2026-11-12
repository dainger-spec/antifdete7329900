// 0–3.9 s: an eclipse ends. A dark disc slides off a bright one; light breaks out at the edge; the bright disc
// cracks along Lumen's seam and becomes the mark; LUMEN is written beside it.
// 3.4–6.8 s: «Каждому аккаунту — своя Safari.»
(function () {
  'use strict';
  const F = window.Film, UI = window.UI;
  const E = F.ease;

  // The split disc of LumenMarkGeometry (radius 19, gap 3, slide 6, seam one across for three up), one half at a
  // time, with any gap and slide — so the disc can crack open from whole.
  const SD = [1 / Math.hypot(1, 3), -3 / Math.hypot(1, 3)];
  const SN = [-SD[1], SD[0]];
  const f = (n) => n.toFixed(2);
  function halfPath(side, cx, cy, R, gap, slide) {
    const h = (side * gap) / 2, shift = (side * slide) / 2;
    const c = [cx + SD[0] * shift, cy + SD[1] * shift];
    const half = Math.sqrt(Math.max(0, R * R - h * h));
    const a = [SN[0] * h - SD[0] * half, SN[1] * h - SD[1] * half];
    const b = [SN[0] * h + SD[0] * half, SN[1] * h + SD[1] * half];
    const angB = Math.atan2(b[1], b[0]);
    const angA = Math.atan2(a[1], a[0]);
    // the arc from b round the outside to a, on the half's side
    const m = [SN[0] * side * R, SN[1] * side * R];
    const pos = (v) => { v %= 2 * Math.PI; if (v <= 0) v += 2 * Math.PI; return v; };
    const positive = pos(angA - angB);
    const sweep = pos(Math.atan2(m[1], m[0]) - angB) < positive ? positive : positive - 2 * Math.PI;
    const large = Math.abs(sweep) > Math.PI ? 1 : 0, dir = sweep > 0 ? 1 : 0;
    return `M${f(c[0] + a[0])} ${f(c[1] + a[1])}L${f(c[0] + b[0])} ${f(c[1] + b[1])}` +
      `A${f(R)} ${f(R)} 0 ${large} ${dir} ${f(c[0] + a[0])} ${f(c[1] + a[1])}Z`;
  }
  F.halfPath = halfPath;
  F.SD = SD;
  F.SN = SN;

  F.scene({
    id: 'open', t0: 0, t1: 4.0, z: 1,
    build(el) {
      el.innerHTML = `
        <div class="fill" data-k="halo"></div>
        <svg class="fill" width="1920" height="1080" viewBox="0 0 1920 1080" data-k="svg">
          <defs>
            <filter id="o-seamglow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="9"/></filter>
            <filter id="o-soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="2.2"/></filter>
            <radialGradient id="o-disc" cx="38%" cy="34%" r="75%">
              <stop offset="0%" stop-color="#FFFFFF"/><stop offset="60%" stop-color="#EEF1F8"/><stop offset="100%" stop-color="#D9DEEA"/>
            </radialGradient>
          </defs>
          <g data-k="sun"><path data-k="h0" fill="url(#o-disc)"/><path data-k="h1" fill="url(#o-disc)"/></g>
          <g data-k="seam"><line data-k="sg" stroke="#6F8FEA" stroke-width="14" stroke-linecap="round" filter="url(#o-seamglow)"/>
            <line data-k="sc" stroke="#C9D7FF" stroke-width="2.4" stroke-linecap="round"/></g>
        </svg>
        <div class="fill" data-k="moon"></div>
        <div class="fill" data-k="flare"></div>
        <div class="abs" data-k="word" style="left:0;top:0">${UI.wordmark(64, '#F4F4F5')}</div>
      `;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
    },
    update(lt, t, el) {
      const k = this.k;
      // Where the mark is: large in the middle, then small at the left of the lockup.
      const shrink = F.seg(lt, 2.55, 3.45, E.camera);
      const R = F.lerp(205, 62, shrink);
      const wordW = 64 * (UI._wordRatio || 4.62);
      const lockW = 2 * R + 34 + wordW * shrink;
      const cx = F.lerp(960, 960 - lockW / 2 + R, shrink);
      const cy = F.lerp(500, 520, shrink);

      // The disc cracks: gap and slide grow from nothing to the mark's proportions (3 and 6 of 19).
      const crack = F.seg(lt, 2.05, 2.75, E.entry);
      const gap = (3 / 19) * R * crack, slide = (6 / 19) * R * crack;
      k.h0.setAttribute('d', halfPath(-1, cx, cy, R, gap, slide));
      k.h1.setAttribute('d', halfPath(1, cx, cy, R, gap, slide));

      // The seam: light in the crack, brightest as it opens, then a calm line.
      const seamOn = F.seg(lt, 1.85, 2.15, E.out);
      const seamLen = F.seg(lt, 1.85, 2.35, E.entry);
      const seamFade = 1 - 0.55 * F.seg(lt, 2.8, 3.6, E.inOut);
      const L = R * 1.0 * seamLen;
      for (const line of [k.sg, k.sc]) {
        line.setAttribute('x1', f(cx - SD[0] * L)); line.setAttribute('y1', f(cy - SD[1] * L));
        line.setAttribute('x2', f(cx + SD[0] * L)); line.setAttribute('y2', f(cy + SD[1] * L));
      }
      F.opacity(k.sg, seamOn * seamFade * (0.85 + 0.5 * (1 - crack)));
      F.opacity(k.sc, seamOn * seamFade);
      k.sc.setAttribute('stroke-width', f(Math.max(1.4, 2.6 * (R / 205))));
      k.sg.setAttribute('stroke-width', f(14 * (R / 205)));

      // The moon: a soft black disc, a hair larger than the sun, sliding off up and to the right.
      const away = F.seg(lt, 1.15, 2.35, E.smooth);
      const mx = cx + F.lerp(10, 520, away), my = cy + F.lerp(-7, -360, away);
      const moonR = R * 1.035;
      F.css(k.moon, 'background', UI.softDisc(mx, my, moonR, 2.2, '0,0,0', 1));
      F.opacity(k.moon, 1 - F.seg(lt, 2.0, 2.4, E.linear));

      // The corona and the halo around the sun: it gathers, peaks as the edge breaks, then settles as glow.
      const corona = F.seg(lt, 0.15, 1.25, E.out);
      const settle = F.seg(lt, 2.2, 3.4, E.inOut);
      const haloA = corona * F.lerp(1, 0.38, settle);
      F.css(k.halo, 'background',
        UI.softDisc(cx, cy, R * 1.02, R * 0.06, '236,240,248', 0.9 * corona * (1 - away)) + ', ' +
        UI.softDisc(cx, cy, R * 1.05, R * 0.2, '220,228,248', 0.5 * haloA) + ', ' +
        UI.softDisc(cx, cy, R * 1.25, R * 0.55, '160,184,252', 0.26 * haloA) + ', ' +
        UI.softDisc(cx, cy, R * 1.6, R * 1.1, '111,143,234', 0.12 * haloA));
      F.opacity(k.sun, F.seg(lt, 0.9, 1.4, E.out));

      // The diamond: one point of light where the edge first breaks, with a thin streak.
      const dia = F.window(lt, 1.05, 2.05, 0.28, 0.6, E.out, E.inOut);
      const ang = Math.atan2(cy - my, cx - mx); // the side of the sun the moon leaves first
      const px = cx + Math.cos(ang) * R, py = cy + Math.sin(ang) * R;
      F.css(k.flare, 'background',
        `radial-gradient(circle at ${f(px)}px ${f(py)}px, rgba(255,255,255,${f(0.95 * dia)}) 0px, rgba(236,240,248,${f(0.6 * dia)}) 10px, rgba(160,184,252,${f(0.22 * dia)}) 46px, rgba(111,143,234,0) 150px),` +
        `radial-gradient(ellipse 520px 6px at ${f(px)}px ${f(py)}px, rgba(220,230,255,${f(0.55 * dia)}) 0%, rgba(160,184,252,0) 100%)`);

      // LUMEN, written in from the left behind a moving edge of light.
      const word = k.word;
      if (!UI._wordRatio) {
        const svg = word.querySelector('svg');
        UI._wordRatio = parseFloat(svg.getAttribute('width')) / 64;
      }
      const wx = cx + R + 34, wy = cy - 32;
      F.transform(word, `translate(${f(wx)}px, ${f(wy)}px)`);
      const wr = F.seg(lt, 2.75, 3.55, E.camera);
      F.css(word, 'clip-path', `inset(-20px ${f((1 - wr) * 100)}% -20px -20px)`);
      F.opacity(word, F.seg(lt, 2.7, 3.0, E.out));

      // Out: the lockup lifts and blurs away as the title comes.
      const out = F.seg(lt, 3.45, 3.95, E.in);
      F.opacity(el, 1 - out);
      F.blur(el, out * 14);
    },
  });

  // MARK: The first title

  F.scene({
    id: 'title', t0: 3.5, t1: 7.0, z: 2,
    build(el) {
      el.innerHTML = `
        <div class="abs" data-k="block" style="left:0;right:0;top:330px;text-align:center">
          <div class="title t-xl" data-k="l1">Каждому аккаунту —</div>
          <div class="title t-xl grey" data-k="l2"><span class="w sheen" data-k="s1">своя</span> <span class="w sheen" data-k="s2">Safari.</span></div>
          <div class="sub" data-k="sub" style="margin-top:34px">Свои cookies, IP, язык и часовой пояс у каждого профиля.</div>
        </div>`;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
      F.words(this.k.l1);
      this.k.l2._words = [this.k.s1, this.k.s2];
      F.words(this.k.sub);
    },
    update(lt) {
      const k = this.k;
      F.reveal(k.l1, lt, 0.15, { stagger: 0.09 });
      F.reveal(k.l2, lt, 0.45, { stagger: 0.12 });
      F.reveal(k.sub, lt, 1.0, { stagger: 0.03, dur: 0.8, blur: 8, rise: 0.4 });
      // A light passes over «своя Safari.»
      const sweep = F.seg(lt, 0.9, 2.3, E.inOut);
      for (const s of [k.s1, k.s2]) F.css(s, 'background-position', `${f(100 - sweep * 100)}% 0`);
      // Leaves upward as the window rises.
      const out = F.seg(lt, 2.75, 3.4, E.in);
      F.transform(k.block, `translateY(${f(-out * 120)}px)`);
      F.opacity(k.block, 1 - out);
      F.blur(k.block, out * 12);
    },
  });
})();
