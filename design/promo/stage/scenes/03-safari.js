// 12.6–18.6 s: «Настоящая Safari в каждом профиле.» The row opens as Safari's window; the camera pulls back:
// four profiles, four countries — one news site in each one's language, at each one's local time.
// 18.2–22.4 s: «Сайты видят обычную Safari.» 448 · 31/31 · 15/15 · 10/10 (the site's facts, CI #388/#385).
(function () {
  'use strict';
  const F = window.Film, UI = window.UI;
  const E = F.ease;
  const f = (n) => n.toFixed(2);

  // One news site, as each profile's language and time zone show it (sample text).
  const NEWS = {
    DE: { date: 'Donnerstag, 12. November 2026', city: 'Berlin', hh: 14, mm: 32, kicker: 'Zeitumstellung', h1: 'Eine Stunde zurück — und um fünf ist es dunkel',
      p: 'Seit Sonntag gilt wieder die Winterzeit. Was die gewonnene Stunde mit Schlaf, Stimmung und Verkehr macht.', nav: ['Politik', 'Wirtschaft', 'Kultur', 'Sport', 'Reise'],
      cards: ['Der Abend im Konzerthaus', 'Mit dem Zug an die Ostsee', 'Kaffee wird wieder teurer'] },
    US: { date: 'Thursday, November 12, 2026', city: 'New York', hh: 8, mm: 32, kicker: 'Daylight saving', h1: 'An hour back — and dark by five',
      p: 'Standard time is back. What the extra hour does to sleep, mood and the morning commute.', nav: ['Politics', 'Business', 'Culture', 'Sports', 'Travel'],
      cards: ['A night at the concert hall', 'By train to the coast', 'Coffee prices climb again'] },
    JP: { date: '2026年11月12日（木）', city: '東京', hh: 22, mm: 32, kicker: '季節', h1: '紅葉前線、週末にも都心へ',
      p: '今年の紅葉は例年より一週間ほど遅れて見頃を迎えそうです。週末の人出と天気をまとめました。', nav: ['政治', '経済', '文化', 'スポーツ', '旅'],
      cards: ['コンサートホールの夜', '列車で海へ', 'コーヒーがまた値上がり'], jp: true },
    PT: { date: 'quinta-feira, 12 de novembro de 2026', city: 'Lisboa', hh: 13, mm: 32, kicker: 'Mudança da hora', h1: 'Uma hora a menos — e às cinco já é noite',
      p: 'O horário de inverno voltou. O que a hora a mais faz ao sono, ao humor e ao trânsito.', nav: ['Política', 'Economia', 'Cultura', 'Desporto', 'Viagens'],
      cards: ['Uma noite no Coliseu', 'De comboio até ao mar', 'O café volta a subir'] },
  };
  const IMG = [
    'linear-gradient(160deg, #F2C9A0 0%, #E58E6A 38%, #6C5B8E 72%, #2F3554 100%)',
    'linear-gradient(170deg, #BFD9EE 0%, #7FB0D6 45%, #3E6E99 100%)',
    'linear-gradient(150deg, #D8C9B0 0%, #9C8467 55%, #4D3D2E 100%)',
    'linear-gradient(165deg, #CFE3C9 0%, #86B08A 50%, #3C5E48 100%)',
  ];

  function newsPage(cc) {
    const n = NEWS[cc];
    const ff = n.jp ? 'var(--jp)' : '"Bitstream Charter", Charter, Georgia, serif';
    const sans = n.jp ? 'var(--jp)' : 'var(--font)';
    const bars = (w, c = '#E4E4E8') => `<div style="height:9px;width:${w}%;background:${c};border-radius:5px;margin:7px 0"></div>`;
    return `<div style="position:absolute;inset:0;padding:22px 46px;font-family:${sans};color:#111">
      <div style="display:flex;align-items:flex-end;justify-content:space-between;border-bottom:2px solid #111;padding-bottom:12px">
        <div style="font-size:13px;color:#555;width:300px">${n.date}</div>
        <div style="font-family:'Bitstream Charter',Charter,Georgia,serif;font-size:46px;font-weight:700;letter-spacing:-0.02em;line-height:1">Meridian</div>
        <div style="width:300px;text-align:right;font-size:13px;color:#555"><span class="clock" style="font-weight:600;color:#111;font-variant-numeric:tabular-nums">${String(n.hh).padStart(2, '0')}:${n.mm}</span> · ${n.city}</div>
      </div>
      <div style="display:flex;gap:26px;justify-content:center;font-size:13px;font-weight:600;padding:11px 0;border-bottom:1px solid #DDD;color:#333">${n.nav.map((x) => `<span>${x}</span>`).join('')}</div>
      <div style="display:flex;gap:34px;margin-top:22px">
        <div style="flex:1.25">
          <div style="font-size:12px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:#B5432F">${n.kicker}</div>
          <div style="font-family:${ff};font-size:${n.jp ? 38 : 40}px;font-weight:700;line-height:1.12;letter-spacing:-0.01em;margin-top:8px">${n.h1}</div>
          <div style="font-family:${ff};font-size:17px;line-height:1.5;color:#444;margin-top:12px">${n.p}</div>
          ${bars(96)}${bars(91)}${bars(94)}${bars(60)}
        </div>
        <div style="flex:1;border-radius:6px;background:${IMG[0]};min-height:250px"></div>
      </div>
      <div style="display:flex;gap:24px;margin-top:24px;border-top:1px solid #DDD;padding-top:18px">
        ${n.cards.map((c, i) => `<div style="flex:1"><div style="height:118px;border-radius:5px;background:${IMG[i + 1]}"></div><div style="font-family:${ff};font-size:19px;font-weight:700;line-height:1.25;margin-top:10px">${c}</div>${bars(88)}${bars(70)}</div>`).join('')}
      </div>
    </div>`;
  }
  F.newsPage = newsPage;

  const WINS = [
    { id: 'shop', cc: 'DE', url: 'meridian.example', x: 0, y: 0 },
    { id: 'north', cc: 'US', url: 'meridian.example' },
    { id: 'jp', cc: 'JP', url: 'meridian.example' },
    { id: 'travel', cc: 'PT', url: 'meridian.example' },
  ];
  // Where each window ends, in the pulled-back view (centre x, centre y, scale, rotateY, z).
  const SPOT = [
    [590, 405, 0.42, 7, 0],
    [1330, 405, 0.42, -7, 0],
    [590, 772, 0.42, 7, 0],
    [1330, 772, 0.42, -7, 0],
  ];
  const CITY = { DE: 'Берлин', US: 'Нью-Йорк', JP: 'Токио', PT: 'Лиссабон' };

  F.fastRange(12.6, 13.6, 3);  // Safari's window settling out of the zoom
  F.fastRange(13.95, 15.7, 2); // the pull back, the windows out of the depth
  F.scene({
    id: 'safari', t0: 12.6, t1: 18.7, z: 4,
    build(el) {
      el.innerHTML = `<div class="fill" data-k="bg"></div>
        <div class="fill" data-k="cam" style="perspective:2400px;perspective-origin:50% 50%"><div class="fill p3d" data-k="rig"></div></div>
        <div class="abs" data-k="title" style="left:0;right:0;top:64px;text-align:center">
          <div class="title t-l"><span data-k="a">Настоящая Safari</span> <span class="grey" data-k="b">в каждом профиле.</span></div>
        </div>
        <div class="abs" data-k="sub" style="left:0;right:0;top:996px;text-align:center"><div class="sub s" data-k="subt">Системный WebKit и родное окно Safari. Свой процесс, IP, язык и часовой пояс.</div></div>`;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
      F.words(this.k.a); F.words(this.k.b); F.words(this.k.subt);
      this.wins = WINS.map((w, i) => {
        const p = UI.byId(w.id);
        const s = UI.safari({ w: 1280, h: 800, profile: p, url: w.url, page: newsPage(w.cc) });
        s.style.left = (960 - 640) + 'px';
        s.style.top = (540 - 400) + 'px';
        s.style.transformOrigin = '50% 50%';
        const badge = F.el('div', 'abs');
        badge.innerHTML = `<div style="display:flex;align-items:center;gap:11px;height:50px;padding:0 20px 0 12px;border-radius:999px;background:rgba(18,19,23,0.9);box-shadow:inset 0 1px 0 rgba(255,255,255,0.14),0 0 0 1px rgba(255,255,255,0.12),0 18px 40px rgba(0,0,0,0.55)">${UI.flag(w.cc, 26)}<span style="font-size:21px;color:var(--t1);font-weight:500">${CITY[w.cc]}</span><span class="num bt" style="font-size:21px;color:var(--t2)">00:00</span></div>`;
        badge.style.left = '0px';
        badge.style.top = '0px';
        badge.style.zIndex = '10';
        s._clock = F.$(s, '.clock');
        s._badge = badge;
        s._bt = F.$(badge, '.bt');
        this.k.rig.appendChild(s);
        el.appendChild(badge);
        return s;
      });
    },
    update(lt, t, el) {
      const k = this.k;
      // The first window settles out of the zoom; the others come out of the depth as the camera pulls back.
      const settle = F.seg(lt, 0.0, 1.25, E.outCubic);
      const pull = F.seg(lt, 1.35, 3.0, E.camera);
      F.opacity(el, F.seg(lt, 0.0, 0.5, E.out) * (1 - F.seg(lt, 5.6, 6.1, E.in)));
      this.wins.forEach((w, i) => {
        const [sx, sy, ss, ry, sz] = SPOT[i];
        let x, y, s, r, z, o;
        if (i === 0) {
          const s0 = F.lerp(1.4, 0.98, settle);
          x = F.lerp(960, sx, pull); y = F.lerp(560, sy, pull); s = F.lerp(s0, ss, pull); r = F.lerp(0, ry, pull); z = 0;
          o = 1;
          F.blur(w, (1 - settle) * 10);
        } else {
          const k2 = F.seg(lt, 1.55 + i * 0.16, 3.1 + i * 0.16, E.entry);
          x = sx + (1 - k2) * (sx - 960) * 0.25; y = sy + (1 - k2) * (sy - 540) * 0.25;
          s = ss; r = ry; z = F.lerp(-1400, sz, k2); o = F.seg(lt, 1.55 + i * 0.16, 2.3 + i * 0.16, E.out);
          F.blur(w, (1 - k2) * 8);
        }
        // a slow drift, so nothing is ever quite still
        const drift = Math.sin((lt + i) * 0.7) * 4;
        F.transform(w, `translate3d(${f(x - 960)}px, ${f(y - 540 + drift)}px, ${f(z)}px) rotateY(${f(r)}deg) scale(${f(s)})`);
        F.opacity(w, o);
        // Local time: the minute turns over at 4.4 s in every window at once — each in its own zone.
        const n = NEWS[WINS[i].cc];
        const turned = lt >= 4.4 ? 1 : 0;
        const hm = `${String(n.hh).padStart(2, '0')}:${n.mm + turned}`;
        F.text(w._clock, hm);
        F.text(w._bt, hm);
        // The badge floats over the window's bottom-left corner, half out of it.
        const b = w._badge;
        const bk = F.seg(lt, 2.3 + i * 0.12, 3.3 + i * 0.12, E.entry);
        const bx = x - 640 * s + 28, by = y + 400 * s - 25 + drift;
        F.transform(b, `translate(${f(bx)}px, ${f(by + (1 - bk) * 14)}px)`);
        F.opacity(b, bk * F.seg(lt, 0, 0.1));
        F.blur(b, (1 - bk) * 6);
      });
      F.reveal(k.a, lt, 2.2, { stagger: 0.08 });
      F.reveal(k.b, lt, 2.45, { stagger: 0.08 });
      F.reveal(k.subt, lt, 3.0, { stagger: 0.025, dur: 0.8, blur: 8, rise: 0.4 });
    },
  });

  // MARK: Parity with Safari

  F.scene({
    id: 'parity', t0: 18.2, t1: 22.5, z: 5,
    build(el) {
      const stat = (n, d, label) => `<div class="pst" style="display:flex;align-items:center;gap:18px;padding:18px 0;border-top:1px solid var(--line2)">
          <span style="width:30px;height:30px;border-radius:50%;background:rgba(74,222,128,.12);color:#8FE3B0;display:flex;align-items:center;justify-content:center">${UI.icon('check', 16)}</span>
          <span style="font-size:26px;color:var(--t1);flex:1">${label}</span>
          <span class="num" style="font-family:var(--display);font-size:40px;font-weight:600;letter-spacing:-0.02em"><span class="c" data-n="${n}">0</span><span style="color:var(--t3)">/${d}</span></span></div>`;
      el.innerHTML = `
        <div class="fill" style="background:radial-gradient(ellipse 900px 700px at 72% 52%, rgba(111,143,234,0.10), rgba(0,0,0,0) 70%)"></div>
        <div class="abs" style="left:150px;top:300px">
          <div class="caps" data-k="cap">Проверено на каждой сборке</div>
          <div class="title t-xl" style="margin-top:22px" data-k="a">Сайты видят</div>
          <div class="title t-xl grey" data-k="b">обычную Safari.</div>
          <div class="sub" style="margin-top:30px;max-width:640px;white-space:normal" data-k="s">Без шума в отпечатке: canvas, WebGL и шрифты — как у Safari на этом Mac.</div>
        </div>
        <div class="abs" data-k="right" style="left:1060px;top:190px;width:700px">
          <div class="num" style="font-family:var(--display);font-weight:600;font-size:250px;letter-spacing:-0.06em;line-height:0.9" data-k="big">0</div>
          <div class="sub" style="margin:8px 0 34px;color:var(--t2)" data-k="bcap">признаков сверяем с настоящей Safari</div>
          ${stat(31, 31, 'Заголовки запросов')}${stat(15, 15, 'TLS и HTTP/2')}${stat(10, 10, 'Геометрия окна')}
        </div>`;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
      F.words(this.k.a); F.words(this.k.b); F.words(this.k.s); F.words(this.k.cap);
      this.stats = F.$$(el, '.pst');
    },
    update(lt, t, el) {
      const k = this.k;
      F.opacity(el, F.seg(lt, 0, 0.3) * (1 - F.seg(lt, 3.75, 4.25, E.in)));
      F.blur(el, F.seg(lt, 3.75, 4.25, E.in) * 12);
      F.reveal(k.cap, lt, 0.15, { stagger: 0.05 });
      F.reveal(k.a, lt, 0.25, { stagger: 0.08 });
      F.reveal(k.b, lt, 0.5, { stagger: 0.08 });
      F.reveal(k.s, lt, 1.0, { stagger: 0.02, dur: 0.8, blur: 8 });
      const c = F.seg(lt, 0.35, 1.9, E.outQuint);
      F.text(k.big, F.count(0, 448, c));
      const bi = F.seg(lt, 0.3, 1.1, E.entry);
      F.opacity(k.big, bi);
      F.blur(k.big, (1 - bi) * 14);
      F.transform(k.big, `translateY(${f((1 - bi) * 40)}px)`);
      F.opacity(k.bcap, F.seg(lt, 0.8, 1.4, E.out));
      this.stats.forEach((s, i) => {
        const a = 1.0 + i * 0.22;
        const kk = F.seg(lt, a, a + 0.8, E.entry);
        F.opacity(s, kk);
        F.transform(s, `translateY(${f((1 - kk) * 24)}px)`);
        const cnt = F.$(s, '.c');
        F.text(cnt, F.count(0, +cnt.dataset.n, F.seg(lt, a, a + 1.0, E.outCubic)));
      });
    },
  });
})();
