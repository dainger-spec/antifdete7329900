// The highlight. 22.2–25.6 s «UDP — через прокси.»; 25.2–31.4 s how: the profile's WebRTC goes to Lumen's relay
// (TURN on 127.0.0.1), which sends it through the profile's SOCKS5 proxy (UDP ASSOCIATE) — sites and peers see
// the proxy's address; the network guard drops whatever would go around it (docs/TUNNEL.md on the trunk);
// 31.0–35.0 s a video call through the proxy; 34.6–39.0 s the proxy list's step-by-step check, UDP included.
(function () {
  'use strict';
  const F = window.Film, UI = window.UI;
  const E = F.ease;
  const f = (n) => n.toFixed(2);
  const P = () => UI.byId('shop');

  // MARK: «UDP — через прокси.»

  F.scene({
    id: 'udp', t0: 22.2, t1: 25.7, z: 6,
    build(el) {
      el.innerHTML = `
        <div class="fill" data-k="beam"></div>
        <div class="abs" style="left:0;right:0;top:250px;text-align:center">
          <div class="title" data-k="big" style="font-size:330px;font-weight:700;letter-spacing:-0.06em;line-height:0.9"><span class="sheen" data-k="udp" style="background-image:linear-gradient(100deg,#F4F4F5 0%,#F4F4F5 40%,#FFFFFF 47%,#B2C6FF 50%,#FFFFFF 53%,#F4F4F5 60%,#F4F4F5 100%)">UDP</span></div>
          <div class="title t-xl grey" data-k="l2" style="margin-top:18px">теперь через прокси.</div>
          <div class="sub" data-k="sub" style="margin-top:34px">WebRTC, видеозвонки, STUN и TURN — с адреса прокси, а не вашего Mac.</div>
        </div>`;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
      F.words(this.k.l2); F.words(this.k.sub);
    },
    update(lt, t, el) {
      const k = this.k;
      const bi = F.seg(lt, 0.05, 1.1, E.entry);
      F.opacity(k.big, F.seg(lt, 0.05, 0.6, E.out));
      F.blur(k.big, (1 - bi) * 26);
      F.transform(k.big, `scale(${f(F.lerp(1.18, 1, bi))})`);
      F.css(k.udp, 'background-position', `${f(100 - F.seg(lt, 0.5, 2.0, E.inOut) * 100)}% 0`);
      F.reveal(k.l2, lt, 0.55, { stagger: 0.09 });
      F.reveal(k.sub, lt, 1.2, { stagger: 0.025, dur: 0.8, blur: 8 });
      // A beam of light along Lumen's seam crosses behind the word.
      const b = F.seg(lt, 0.2, 2.6, E.camera);
      const x = F.lerp(-500, 2400, b);
      F.css(k.beam, 'background', `linear-gradient(108deg, rgba(0,0,0,0) ${f(x - 260)}px, rgba(111,143,234,0.10) ${f(x - 80)}px, rgba(178,198,255,0.32) ${f(x)}px, rgba(111,143,234,0.10) ${f(x + 80)}px, rgba(0,0,0,0) ${f(x + 260)}px)`);
      const out = F.seg(lt, 3.0, 3.5, E.in);
      F.opacity(el, F.seg(lt, 0, 0.2) * (1 - out));
      F.blur(el, out * 12);
    },
  });

  // MARK: How it goes

  const NODES = [
    { id: 'a', x: 300, y: 560, w: 260, h: 172, title: 'Профиль', sub: 'Safari · WebRTC' },
    { id: 'b', x: 760, y: 560, w: 260, h: 172, title: 'Ретранслятор Lumen', sub: 'TURN · 127.0.0.1' },
    { id: 'c', x: 1220, y: 560, w: 260, h: 172, title: 'SOCKS5-прокси', sub: 'UDP ASSOCIATE' },
    { id: 'd', x: 1650, y: 560, w: 260, h: 172, title: 'Сайт и собеседник', sub: 'видят 203.0.113.47' },
  ];

  F.scene({
    id: 'udpflow', t0: 25.25, t1: 31.5, z: 7,
    build(el) {
      const p = P();
      const art = {
        a: `<div style="display:flex;align-items:center;gap:10px">${UI.avatar(p.letters, p.color, 40, true)}<div><div style="font-size:19px;font-weight:600">${p.name}</div><div style="display:flex;gap:6px;align-items:center;font-size:15px;color:var(--t2);margin-top:3px">${UI.flag('DE', 15)} Германия</div></div></div>`,
        b: `<div style="display:flex;align-items:center;gap:12px"><div style="width:44px;height:44px;border-radius:12px;background:var(--bg4);display:flex;align-items:center;justify-content:center;color:var(--t1)">${UI.mark(30)}</div><div style="font-size:15px;color:var(--t2)">один на каждый<br>запущенный профиль</div></div>`,
        c: `<div style="display:flex;align-items:center;gap:12px">${UI.flag('DE', 40)}<div><div class="num" style="font-family:var(--mono);font-size:16px;color:var(--t1)">203.0.113.47</div><div style="margin-top:6px"><span class="badge g">UDP работает</span></div></div></div>`,
        d: `<div style="display:flex;align-items:center;gap:12px"><div style="width:44px;height:44px;border-radius:50%;background:var(--bg4);display:flex;align-items:center;justify-content:center;color:var(--t1)">${UI.icon('globe', 24)}</div><div style="font-size:15px;color:var(--t2)">адрес и страна —<br>как у страниц</div></div>`,
      };
      const node = (n) => `<div class="abs node" data-n="${n.id}" style="left:${n.x - n.w / 2}px;top:${n.y - n.h / 2}px;width:${n.w}px;height:${n.h}px">
          <div class="panel" style="position:absolute;inset:0;border-radius:22px;padding:20px 22px;background:rgba(14,15,19,0.92)">
            <div style="font-size:21px;font-weight:600;letter-spacing:-0.01em">${n.title}</div>
            <div style="font-size:14px;color:var(--t3);margin-top:3px">${n.sub}</div>
            <div style="margin-top:18px">${art[n.id]}</div>
          </div></div>`;
      el.innerHTML = `
        <div class="abs" data-k="head" style="left:150px;top:96px">
          <div class="title t-l" data-k="a">WebRTC идёт через прокси.</div>
          <div class="title t-l grey" data-k="b">Мимо — ни одного пакета.</div>
        </div>
        <svg class="fill" width="1920" height="1080" viewBox="0 0 1920 1080" data-k="svg">
          <defs>
            <filter id="u-glow" filterUnits="userSpaceOnUse" x="300" y="440" width="1360" height="240"><feGaussianBlur stdDeviation="7"/></filter>
            <filter id="u-glow2" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="5"/></filter>
            <linearGradient id="u-line" gradientUnits="userSpaceOnUse" x1="430" y1="0" x2="1520" y2="0"><stop offset="0" stop-color="#B9C8F0"/><stop offset="0.5" stop-color="#ECF0F8"/><stop offset="1" stop-color="#9FD4BB"/></linearGradient>
          </defs>
          <path data-k="pg" d="M430 560 H1520" stroke="#6F8FEA" stroke-width="10" fill="none" filter="url(#u-glow)" opacity="0.5"/>
          <path data-k="pl" d="M430 560 H1520" stroke="url(#u-line)" stroke-width="2.4" fill="none"/>
          <path data-k="bl" d="M300 646 V880 H690" stroke="#F2706A" stroke-width="2.2" fill="none" stroke-dasharray="7 9" opacity="0.8"/>
          <g data-k="packets"></g>
          <g data-k="bad"></g>
        </svg>
        ${NODES.map(node).join('')}
        <div class="abs" data-k="shield" style="left:690px;top:812px;width:420px;height:136px">
          <div class="panel" style="position:absolute;inset:0;border-radius:22px;padding:22px 24px;display:flex;gap:18px;align-items:center;background:rgba(14,15,19,0.92)">
            <div style="width:62px;height:62px;border-radius:18px;background:rgba(74,222,128,0.10);box-shadow:inset 0 0 0 1px rgba(74,222,128,0.3);display:flex;align-items:center;justify-content:center;color:#8FE3B0">${UI.icon('shieldCheck', 34)}</div>
            <div><div style="font-size:21px;font-weight:600">Сетевая защита Lumen</div><div style="font-size:15px;color:var(--t2);margin-top:4px;line-height:1.35">не даёт профилю соединиться мимо прокси</div></div>
          </div></div>
        <div class="abs" data-k="mac" style="left:1210px;top:842px;display:flex;align-items:center;gap:14px;color:var(--t3);font-size:19px">
          <span style="width:44px;height:44px;border-radius:50%;border:1.5px dashed rgba(242,112,106,0.6);display:flex;align-items:center;justify-content:center;color:#F59C97">${UI.icon('xmark', 20)}</span>
          <span>Напрямую, с адреса этого Mac</span></div>
        <div class="abs" data-k="count" style="left:1540px;top:820px;text-align:right;width:240px">
          <div class="num" style="font-family:var(--display);font-size:96px;font-weight:600;letter-spacing:-0.04em;line-height:1">0</div>
          <div style="font-size:17px;color:var(--t2);margin-top:4px">пакетов мимо прокси<br><span style="color:var(--t3);font-size:14px">захват каждого пакета в CI</span></div>
        </div>`;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
      F.words(this.k.a); F.words(this.k.b);
      this.nodes = F.$$(el, '.node');
      // packets on the main path: going right (above) and coming back (below)
      const svgNS = 'http://www.w3.org/2000/svg';
      this.pk = [];
      for (let i = 0; i < 26; i++) {
        const g = document.createElementNS(svgNS, 'g');
        g.innerHTML = `<rect x="-11" y="-3" width="22" height="6" rx="3" fill="#ECF0F8" filter="url(#u-glow2)" opacity="0.9"/><rect x="-8" y="-2" width="16" height="4" rx="2" fill="#FFFFFF"/>`;
        this.k.packets.appendChild(g);
        this.pk.push(g);
      }
      this.bad = [];
      for (let i = 0; i < 6; i++) {
        const g = document.createElementNS(svgNS, 'g');
        g.innerHTML = `<circle r="9" fill="#F2706A" filter="url(#u-glow2)" opacity="0.7"/><circle r="4" fill="#FFB4AE"/>`;
        this.k.bad.appendChild(g);
        this.bad.push(g);
      }
      this.plLen = 1090;
      this.blLen = 234 + 390;
    },
    update(lt, t, el) {
      const k = this.k;
      F.opacity(el, F.seg(lt, 0, 0.35) * (1 - F.seg(lt, 5.75, 6.25, E.in)));
      F.blur(el, F.seg(lt, 5.75, 6.25, E.in) * 10);
      F.reveal(k.a, lt, 0.1, { stagger: 0.06 });
      F.reveal(k.b, lt, 0.45, { stagger: 0.07 });
      this.nodes.forEach((n, i) => {
        const kk = F.seg(lt, 0.25 + i * 0.22, 1.05 + i * 0.22, E.entry);
        F.opacity(n, kk);
        F.blur(n, (1 - kk) * 10);
        F.transform(n, `translateY(${f((1 - kk) * 30)}px) scale(${f(0.94 + 0.06 * kk)})`);
      });
      // the path draws itself from the profile to the world
      const draw = F.seg(lt, 0.7, 1.9, E.inOut);
      for (const p of [k.pl, k.pg]) {
        p.setAttribute('stroke-dasharray', `${this.plLen} ${this.plLen}`);
        p.setAttribute('stroke-dashoffset', f(this.plLen * (1 - draw)));
      }
      // packets: each leaves at its own time and crosses in 1.6 s; the ones coming back ride a little lower
      this.pk.forEach((g, i) => {
        const back = i % 3 === 2;
        const start = 1.5 + i * 0.16 + (F.rand(i) * 0.08);
        const u = F.prog(lt, start, start + 1.7);
        const on = u > 0 && u < 1 && lt < 5.6;
        const x = back ? 1520 - 1090 * u : 430 + 1090 * u;
        const y = back ? 572 : 548;
        g.setAttribute('transform', `translate(${f(x)} ${y})`);
        g.setAttribute('opacity', on ? f(Math.min(1, Math.min(u, 1 - u) * 8)) : '0');
      });
      // the way around: drawn red and dashed, and every packet that takes it stops at the guard
      const bd = F.seg(lt, 2.2, 3.0, E.inOut);
      k.bl.setAttribute('stroke-dashoffset', f(-lt * 18));
      F.opacity(k.bl, 0.8 * bd);
      const sk = F.seg(lt, 2.5, 3.3, E.entry);
      F.opacity(k.shield, sk); F.blur(k.shield, (1 - sk) * 10);
      F.transform(k.shield, `translateY(${f((1 - sk) * 24)}px)`);
      const mk = F.seg(lt, 2.8, 3.5, E.entry);
      F.opacity(k.mac, mk * 0.95);
      this.bad.forEach((g, i) => {
        const start = 3.0 + i * 0.42;
        const u = F.prog(lt, start, start + 0.9);
        const seg1 = 234, seg2 = 390 - 20;
        const d = u * (seg1 + seg2);
        const x = d < seg1 ? 300 : 300 + (d - seg1);
        const y = d < seg1 ? 646 + d : 880;
        const on = u > 0 && u < 1;
        const pop = u > 0.92 ? (1 - u) / 0.08 : 1;
        g.setAttribute('transform', `translate(${f(x)} ${f(y)}) scale(${f(u > 0.92 ? 1 + (1 - pop) * 1.4 : 1)})`);
        g.setAttribute('opacity', on ? f(Math.min(1, u * 6) * pop) : '0');
      });
      const ck = F.seg(lt, 3.4, 4.2, E.entry);
      F.opacity(k.count, ck); F.blur(k.count, (1 - ck) * 8);
      F.transform(k.count, `translateY(${f((1 - ck) * 20)}px)`);
    },
  });

  // MARK: A video call, through the proxy

  F.scene({
    id: 'call', t0: 31.0, t1: 35.2, z: 8,
    build(el) {
      const p = P();
      const tile = (name, letters, color, bg, big) => `<div style="position:relative;flex:1;border-radius:18px;overflow:hidden;background:${bg}">
          <div style="position:absolute;inset:0;background:radial-gradient(ellipse 60% 70% at 50% 85%, rgba(0,0,0,0.35), rgba(0,0,0,0) 70%)"></div>
          <div class="spk" style="position:absolute;left:50%;top:46%;width:${big ? 150 : 120}px;height:${big ? 150 : 120}px;margin:-${big ? 75 : 60}px 0 0 -${big ? 75 : 60}px;border-radius:50%;background:${UI.PALETTE[color][0]};color:${UI.PALETTE[color][1]};display:flex;align-items:center;justify-content:center;font-size:${big ? 60 : 48}px;font-weight:600;box-shadow:0 0 0 0 rgba(255,255,255,0.4)">${letters}</div>
          <div style="position:absolute;left:16px;bottom:14px;font-size:17px;font-weight:500;color:#fff;background:rgba(0,0,0,0.35);padding:4px 10px;border-radius:8px">${name}</div></div>`;
      const page = `<div style="position:absolute;inset:0;background:#141519;padding:22px;display:flex;flex-direction:column;gap:16px">
          <div style="display:flex;gap:16px;flex:1">${tile('Анна', 'А', 1, 'linear-gradient(160deg,#3B4A6B,#1E2638)', true)}${tile('Вы', 'М', 0, 'linear-gradient(160deg,#4A3B52,#241C2A)', false)}</div>
          <div style="height:64px;display:flex;justify-content:center;gap:16px;align-items:center">
            ${['mic', 'video'].map((i) => `<div style="width:56px;height:56px;border-radius:50%;background:#2A2B31;display:flex;align-items:center;justify-content:center;color:#fff">${UI.icon(i, 24)}</div>`).join('')}
            <div style="width:82px;height:56px;border-radius:28px;background:#E5484D;display:flex;align-items:center;justify-content:center;color:#fff">${UI.icon('phoneDown', 26)}</div>
          </div></div>`;
      const fact = (k2, v, hot) => `<div class="fact" ${hot ? `data-hot="${hot}"` : ''} style="padding:9px 12px;margin:0 -12px;border-radius:10px;font-size:17px"><span class="k">${k2}</span><span class="v" style="max-width:260px">${v}</span></div>`;
      el.innerHTML = `
        <div class="abs" data-k="head" style="left:0;right:0;top:64px;text-align:center">
          <div class="title t-l"><span data-k="a">Видеозвонки —</span> <span class="grey" data-k="b">тоже через прокси.</span></div>
        </div>
        <div class="abs" data-k="win" style="left:110px;top:220px"></div>
        <div class="abs" data-k="card" style="left:1290px;top:262px;width:520px">
          <div class="panel" style="position:relative;border-radius:24px;padding:26px 30px 22px;background:rgba(11,12,15,0.94)">
            <div style="display:flex;gap:14px;align-items:center">${UI.avatar(p.letters, p.color, 48, true)}<div><div style="font-family:var(--display);font-size:24px;font-weight:700;letter-spacing:-0.02em">${p.name}</div>
              <div style="display:flex;gap:7px;align-items:center;font-size:15px;color:var(--t1);margin-top:3px"><i class="rdot"></i>Работает · звонок</div></div></div>
            <div style="margin-top:20px;padding-top:14px;border-top:1px solid var(--line)">
              <div style="font-size:12px;font-weight:600;letter-spacing:0.088em;text-transform:uppercase;color:var(--t3);margin-bottom:6px">Сеть</div>
              ${fact('Выход', `<span style="display:inline-flex;gap:8px;align-items:center">${UI.flag('DE', 16)}Германия · Берлин</span>`)}
              ${fact('Внешний IP', '<span style="font-family:var(--mono);font-size:16px">203.0.113.47</span>', 'ip')}
              ${fact('Прокси', '<span style="font-family:var(--mono);font-size:15px">SOCKS5 · de.gw.example</span>')}
              ${fact('UDP', '<span class="badge g">UDP работает</span>', 'udp')}
              ${fact('WebRTC', 'Через прокси, только ретранслятор', 'rtc')}
            </div>
            <div data-k="cand" style="margin-top:16px;padding:14px 16px;border-radius:14px;background:var(--field);box-shadow:inset 0 0 0 1px var(--line2);font-family:var(--mono);font-size:15px;color:var(--t2);line-height:1.6">
              <div style="color:var(--t3);font-family:var(--font);font-size:13px;margin-bottom:2px">Кандидат ICE, который видит собеседник</div>
              <span style="color:#AFC2F5">typ</span> relay · <span style="color:var(--t1)">203.0.113.47</span>:<span class="num">51 734</span></div>
          </div></div>`;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
      F.words(this.k.a); F.words(this.k.b);
      const s = UI.safari({ w: 1100, h: 700, profile: p, url: 'meet.example/room/48-21', page, dark: true });
      s.style.position = 'relative';
      this.k.win.appendChild(s);
      this.spk = F.$$(s, '.spk');
      this.hot = F.$$(el, '[data-hot]');
    },
    update(lt, t, el) {
      const k = this.k;
      F.opacity(el, F.seg(lt, 0, 0.3) * (1 - F.seg(lt, 3.7, 4.2, E.in)));
      F.blur(el, F.seg(lt, 3.7, 4.2, E.in) * 10);
      F.reveal(k.a, lt, 0.15, { stagger: 0.08 });
      F.reveal(k.b, lt, 0.4, { stagger: 0.08 });
      const wk = F.seg(lt, 0.0, 1.0, E.entry);
      F.transform(k.win, `translateX(${f((1 - wk) * -60)}px) perspective(2000px) rotateY(${f(F.lerp(14, 6, wk))}deg)`);
      F.opacity(k.win, wk);
      const ck = F.seg(lt, 0.35, 1.3, E.entry);
      F.transform(k.card, `translateX(${f((1 - ck) * 60)}px)`);
      F.opacity(k.card, ck);
      F.blur(k.card, (1 - ck) * 8);
      // Anna speaks: a soft ring breathes around her
      const sp = 0.5 + 0.5 * Math.sin(lt * 7);
      F.css(this.spk[0], 'box-shadow', `0 0 0 ${f(4 + sp * 8)}px rgba(159,212,187,${f(0.25 + 0.2 * sp)})`);
      // the facts that answer «through the proxy?» light up in turn
      this.hot.forEach((h, i) => {
        const a = 1.3 + i * 0.35;
        const kk = F.window(lt, a, 3.8, 0.4, 0.5);
        F.css(h, 'background', `rgba(74,222,128,${f(0.07 * kk)})`);
        F.css(h, 'box-shadow', `inset 0 0 0 1px rgba(74,222,128,${f(0.28 * kk)})`);
      });
      const cand = F.seg(lt, 2.2, 2.9, E.entry);
      F.opacity(k.cand, cand);
      F.transform(k.cand, `translateY(${f((1 - cand) * 12)}px)`);
    },
  });

  // MARK: The proxy list's check, step by step

  const PROXIES = [
    { cc: 'DE', name: 'Berlin 1', host: 'de.gw.example:1080', kind: 'SOCKS5', ip: '203.0.113.47', lat: 84, udp: 'g', n: 2 },
    { cc: 'US', name: 'New York 2', host: 'us.gw.example:1080', kind: 'SOCKS5', ip: '198.51.100.23', lat: 142, udp: 'g', n: 1 },
    { cc: 'JP', name: 'Tokyo', host: 'jp.gw.example:8080', kind: 'HTTP', ip: '203.0.113.90', lat: 231, udp: 'r', n: 1 },
    { cc: 'PT', name: 'Lisboa', host: 'pt.gw.example:1080', kind: 'SOCKS5', ip: '192.0.2.61', lat: 97, udp: 'g', n: 1 },
    { cc: 'NL', name: 'Amsterdam 4', host: 'nl.gw.example:1080', kind: 'SOCKS5', dead: true, n: 0 },
    { cc: 'FR', name: 'Paris 3', host: 'fr.gw.example:1080', kind: 'SOCKS5', ip: '198.51.100.140', lat: 1730, udp: 'n', n: 1 },
  ];
  const STEPS = [
    ['Адрес', 'Найден'],
    ['Соединение', 'Порт 1080 принимает соединения'],
    ['Рукопожатие', 'Отвечает как SOCKS5'],
    ['Логин', 'Принят'],
    ['Туннель', 'Открывает туннель к сайту'],
    ['UDP', 'UDP работает, тот же адрес'],
    ['Через прокси', 'Внешний IP 203.0.113.47'],
    ['Задержка', '84 мс, медиана из 3 туннелей'],
  ];

  F.scene({
    id: 'proxies', t0: 34.7, t1: 39.3, z: 9,
    build(el) {
      const udpBadge = (u) => (u === 'g' ? '<span class="badge g">UDP работает</span>' : u === 'r' ? '<span class="badge r">Нет UDP</span>' : '<span class="badge n">UDP не проверен</span>');
      const rows = PROXIES.map((p, i) => `<div class="prow" style="position:relative;display:flex;align-items:center;gap:12px;height:52px;padding:0 10px;border-radius:10px;${i === 0 ? 'background:var(--rowSel);' : ''}font-size:13px">
          <div style="width:236px;display:flex;gap:10px;align-items:center">${UI.flag(p.cc, 16)}<div><div style="font-weight:500">${p.name}</div><div style="font-family:var(--mono);font-size:11px;color:var(--t3)">${p.host}</div></div></div>
          <div style="width:70px;color:var(--t2)">${p.kind}</div>
          <div style="width:120px" class="pres-a"></div>
          <div style="width:76px;color:var(--t2)" class="num pres-b"></div>
          <div style="width:140px" class="pres-c"></div>
          <div style="flex:1;display:flex;gap:7px;align-items:center" class="pres-d"></div>
          <div style="position:absolute;left:58px;right:0;bottom:0;height:1px;background:var(--line)"></div></div>`).join('');
      const steps = STEPS.map((s) => `<div class="step" style="display:flex;gap:12px;align-items:flex-start;padding:7px 0">
          <span class="sg" style="flex:none;width:20px;height:20px;border-radius:50%;margin-top:1px;display:flex;align-items:center;justify-content:center;box-shadow:inset 0 0 0 1.5px var(--line3)"></span>
          <div><div style="font-size:13px;font-weight:500">${s[0]}</div><div style="font-size:12px;color:var(--t2);margin-top:1px">${s[1]}</div></div></div>`).join('');
      el.innerHTML = `
        <div class="abs" style="left:110px;top:352px;width:600px">
          <div class="caps" data-k="cap">Менеджер прокси</div>
          <div class="title t-m" style="margin-top:18px" data-k="a">Каждый прокси —</div>
          <div class="title t-m" data-k="a2">проверен по шагам.</div>
          <div class="title t-m grey" data-k="b">И UDP тоже.</div>
          <div class="sub s" style="margin-top:26px;white-space:normal;max-width:560px" data-k="s">Тип, страна, задержка и UDP — ещё до запуска профиля. Проверка идёт только через сам прокси.</div>
        </div>
        <div class="fill" style="perspective:2600px;perspective-origin:30% 50%"><div class="abs" data-k="win" style="left:700px;top:228px;transform-origin:0 50%"></div></div>`;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
      F.words(this.k.a); F.words(this.k.a2); F.words(this.k.b); F.words(this.k.s); F.words(this.k.cap);
      const win = F.el('div', 'win');
      win.style.width = '1340px';
      win.style.height = '640px';
      win.innerHTML = `${UI.traffic()}<div class="eclipse" data-e></div>
        <div style="position:absolute;left:28px;top:40px;right:360px">
          <div style="display:flex;align-items:center;gap:10px"><div><div style="font-family:var(--display);font-size:30px;font-weight:700;letter-spacing:-0.025em">Прокси</div><div style="font-size:13px;color:var(--t2);margin-top:4px">Прокси: 24 · работают: 21</div></div>
            <div style="margin-left:auto;display:flex;gap:8px"><div class="btn">Импорт…</div><div class="btn hot" data-chk>${UI.icon('refresh', 12)}Проверить все</div></div></div>
          <div style="display:flex;gap:12px;height:30px;align-items:center;padding:0 10px;margin-top:22px;border-bottom:1px solid var(--line);font-size:11px;font-weight:600;letter-spacing:0.088em;text-transform:uppercase;color:var(--t3)">
            <span style="width:236px">Прокси</span><span style="width:70px">Тип</span><span style="width:120px">Выход</span><span style="width:76px">Задержка</span><span style="width:140px">UDP</span><span>Состояние</span></div>
          ${rows}
        </div>
        <div class="insp" style="width:330px;padding:44px 24px 20px">
          <div style="display:flex;gap:10px;align-items:center">${UI.flag('DE', 34)}<div><div style="font-family:var(--display);font-size:22px;font-weight:700;letter-spacing:-0.02em">Berlin 1</div><div style="font-family:var(--mono);font-size:11.5px;color:var(--t3);margin-top:2px">socks5://de.gw.example:1080</div></div></div>
          <div class="sec" style="margin-top:18px;padding-top:14px"><div class="sec-t">Проверка по шагам</div>${steps}
          <div style="font-size:11.5px;color:var(--t3);margin-top:8px;line-height:1.4">Проверка идёт через сам прокси — никогда напрямую.</div></div>
        </div>`;
      // the Proxies window has the profiles window's light, dimmer
      this.k.win.appendChild(win);
      this.win = win;
      this.ecl = F.$(win, '[data-e]');
      this.rows = F.$$(win, '.prow').map((r, i) => ({ r, p: PROXIES[i], a: F.$(r, '.pres-a'), b: F.$(r, '.pres-b'), c: F.$(r, '.pres-c'), d: F.$(r, '.pres-d') }));
      this.steps = F.$$(win, '.step');
      this.udpBadge = udpBadge;
    },
    update(lt, t, el) {
      const k = this.k;
      F.opacity(el, F.seg(lt, 0, 0.3) * (1 - F.seg(lt, 4.1, 4.6, E.in)));
      F.blur(el, F.seg(lt, 4.1, 4.6, E.in) * 10);
      F.reveal(k.cap, lt, 0.1, { stagger: 0.05 });
      F.reveal(k.a, lt, 0.2, { stagger: 0.06 });
      F.reveal(k.a2, lt, 0.35, { stagger: 0.06 });
      F.reveal(k.b, lt, 0.6, { stagger: 0.08 });
      F.reveal(k.s, lt, 0.95, { stagger: 0.02, dur: 0.8, blur: 8 });
      const wk = F.seg(lt, 0.0, 1.2, E.entry);
      F.transform(k.win, `translateX(${f((1 - wk) * 160)}px) rotateY(${f(F.lerp(-24, -8, wk))}deg) scale(0.86)`);
      F.opacity(k.win, wk);
      F.css(this.ecl, 'background', UI.eclipseBG(1340, 640, 'profiles', 1, 1, 0.5));
      // «Проверить все»: each row checks, then says what it found
      this.rows.forEach(({ r, p, a, b, c, d }, i) => {
        const done = 1.1 + i * 0.28 + (p.dead ? 0.6 : 0);
        const key = lt < 0.9 ? 'idle' : lt < done ? 'run' : 'done';
        if (r._key !== key) {
          r._key = key;
          if (key === 'idle') { a.innerHTML = ''; b.textContent = ''; c.innerHTML = ''; d.innerHTML = '<span style="color:var(--t3)">Не проверен</span>'; }
          else if (key === 'run') { a.innerHTML = ''; b.textContent = ''; c.innerHTML = ''; d.innerHTML = '<i class="spin"></i><span style="color:var(--t2)">Проверка…</span>'; }
          else if (p.dead) { a.innerHTML = '<span style="color:var(--t3)">—</span>'; b.textContent = '—'; c.innerHTML = '<span style="color:var(--t3)">—</span>'; d.innerHTML = '<span style="width:8px;height:8px;border-radius:2px;background:var(--red);transform:rotate(45deg)"></span><span style="color:var(--red)">Молчит после соединения</span>'; }
          else {
            a.innerHTML = `<span style="display:inline-flex;gap:7px;align-items:center">${UI.flag(p.cc, 13)}<span class="num" style="font-family:var(--mono);font-size:11.5px">${p.ip}</span></span>`;
            b.textContent = p.lat >= 1000 ? (p.lat / 1000).toFixed(2).replace('.', ',') + ' с' : p.lat + ' мс';
            c.innerHTML = this.udpBadge(p.udp);
            d.innerHTML = '<i class="rdot"></i><span style="color:var(--t1)">Работает</span>';
          }
        }
        const spin = F.$(r, '.spin');
        if (spin) F.transform(spin, `rotate(${Math.round((lt * 420) % 360)}deg)`);
        const pop = F.seg(lt, done, done + 0.5, E.entry);
        F.opacity(c, key === 'done' ? pop : 1);
      });
      // the inspector's steps tick one after the other
      this.steps.forEach((s, i) => {
        const at = 1.2 + i * 0.22;
        const on = lt >= at;
        const g = F.$(s, '.sg');
        const key = on ? 'on' : 'off';
        if (g._key !== key) {
          g._key = key;
          g.innerHTML = on ? UI.icon('check', 12) : '';
          g.style.background = on ? 'rgba(74,222,128,0.14)' : 'transparent';
          g.style.color = '#8FE3B0';
          g.style.boxShadow = on ? 'inset 0 0 0 1px rgba(74,222,128,0.35)' : 'inset 0 0 0 1.5px var(--line3)';
        }
        F.opacity(s, 0.45 + 0.55 * F.seg(lt, at - 0.1, at + 0.25, E.out));
        if (i === 5) F.css(s, 'text-shadow', on ? '0 0 18px rgba(74,222,128,0.5)' : 'none');
      });
    },
  });
})();
