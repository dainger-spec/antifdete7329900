// 6.1–12.8 s: «Все аккаунты. Сразу.» The Profiles window (Eclipse) rises; its light comes in from the corners
// as the app's does; profiles start one after the other; the inspector shows the selected profile's network —
// its proxy carries UDP and its WebRTC goes through it. Then the camera moves in on the row that opens next.
(function () {
  'use strict';
  const F = window.Film, UI = window.UI;
  const E = F.ease;
  const f = (n) => n.toFixed(2);

  F.fastRange(6.1, 6.9, 3);   // the window rising
  F.fastRange(10.6, 13.0, 2);  // the push into the row
  F.scene({
    id: 'profiles', t0: 6.1, t1: 13.0, z: 3,
    build(el) {
      el.innerHTML = `
        <div class="abs" data-k="title" style="left:0;right:0;top:64px;text-align:center">
          <div class="title t-l"><span data-k="a">Все аккаунты.</span> <span class="grey" data-k="b">Сразу.</span></div>
        </div>
        <div class="fill" data-k="cam" style="perspective:2600px;perspective-origin:50% 40%"><div class="abs p3d" data-k="rig" style="left:0;top:0;width:1920px;height:1080px"></div></div>
        <div class="fill" data-k="floor"></div>`;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
      F.words(this.k.a);
      F.words(this.k.b);
      const win = UI.profilesWindow({ inspector: 'shop', selected: 'shop' });
      win.style.left = (960 - 800) + 'px';
      win.style.top = (540 - 480) + 'px';
      this.k.rig.appendChild(win);
      this.win = win;
      // the facts to light up in the inspector
      this.udp = F.$(win._insp, '[data-k="udp"]');
      this.rtc = F.$(win._insp, '[data-k="rtc"]');
      for (const e of [this.udp, this.rtc]) { e.style.borderRadius = '8px'; e.style.margin = '0 -8px'; e.style.padding = '5px 8px'; }
    },
    update(lt, t, el) {
      const k = this.k, win = this.win, rows = win._rows;

      // The title
      F.reveal(k.a, lt, 0.35, { stagger: 0.08 });
      F.reveal(k.b, lt, 0.6, { stagger: 0.08 });
      const titleOut = F.seg(lt, 4.1, 4.7, E.in);
      F.opacity(k.title, 1 - titleOut);
      F.blur(k.title, titleOut * 10);

      // The window rises out of the dark and lies back to the viewer.
      const rise = F.seg(lt, 0.0, 1.5, E.entry);
      const y0 = F.lerp(760, 78, rise);
      const rx = F.lerp(38, 0, rise);
      let s = F.lerp(0.74, 0.8, rise);
      // Then the camera moves in on the row of «Магазин DE»: a long, even push.
      const push = F.seg(lt, 4.3, 6.9, E.camera);
      s = F.lerp(s, 2.1, push);
      const row = rows.shop;
      // the row's place in the window (window coords): main left 232 + list 20 + row centre
      const rowY = row.offsetTop + win._main.offsetTop + 108 + 26;
      const rowX = 232 + 20 + 330;
      const tx = F.lerp(0, (800 - rowX) * s, push);
      const ty = F.lerp(y0, (480 - rowY) * s + 0, push);
      F.transform(k.rig, `translate3d(${f(tx)}px, ${f(ty)}px, 0) rotateX(${f(rx)}deg) scale(${f(s)})`);
      F.css(k.rig, 'transform-origin', '960px 540px');
      F.opacity(k.rig, F.seg(lt, 0.0, 0.5, E.out));

      // The window's own light: the eclipses come in from beyond the corners, the edge light follows.
      const kin = F.seg(lt, 0.5, 2.3, E.entry);
      const lit = F.seg(lt, 0.95, 2.6, E.out);
      F.css(win._eclipse, 'background', UI.eclipseBG(1600, 960, 'profiles', kin, lit, 0.62));

      // Profiles start: «Запуск…» with its spinner, then the green dot lights and «Работает».
      const starts = [['shop', 1.0, 1.75], ['jp', 1.3, 2.2], ['travel', 1.6, 2.6]];
      let running = 1;
      for (const [id, a, b] of starts) {
        const r = rows[id];
        if (lt < a) UI.rowState(r, { kind: 'start', spin: (lt * 360) % 360 });
        else if (lt < b) UI.rowState(r, { kind: 'start', spin: (lt * 400) % 360 });
        else UI.rowState(r, { kind: 'run', since: '1 мин' });
        const lit2 = F.seg(lt, b - 0.05, b + 0.6, E.entry);
        F.transform(r._dot, `scale(${f(0.2 + 0.8 * lit2)})`);
        F.opacity(r._dot, lit2);
        if (lt >= b) running++;
      }
      // The warm-up goes on in Northwind: pages and cookies.
      const pages = [[0, 3, 61], [1.9, 4, 84], [3.1, 5, 107], [4.3, 6, 131], [5.5, 7, 158]];
      let cur = pages[0];
      for (const p of pages) if (lt >= p[0]) cur = p;
      UI.rowState(rows.north, { kind: 'warm', page: cur[1], total: 12, cookies: cur[2] });
      F.text(win._nrun, String(running));

      // In the inspector: UDP and WebRTC light up in turn.
      const u = F.window(lt, 2.7, 6.2, 0.5, 0.8);
      const r2 = F.window(lt, 3.1, 6.2, 0.5, 0.8);
      F.css(this.udp, 'background', `rgba(74,222,128,${f(0.07 * u)})`);
      F.css(this.udp, 'box-shadow', `inset 0 0 0 1px rgba(74,222,128,${f(0.3 * u)}), 0 0 30px rgba(74,222,128,${f(0.18 * u)})`);
      F.css(this.rtc, 'background', `rgba(236,240,248,${f(0.06 * r2)})`);
      F.css(this.rtc, 'box-shadow', `inset 0 0 0 1px rgba(236,240,248,${f(0.22 * r2)})`);

      // The scene hands over to Safari's window, which grows out of the row.
      const out = F.seg(lt, 6.35, 6.9, E.in);
      F.opacity(k.cam, 1 - out);
      F.blur(k.cam, out * 6);
    },
  });
})();
