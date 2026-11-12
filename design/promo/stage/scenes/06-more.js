// 64.2–71.0 s: «И это ещё не всё.» — more of what Lumen does, tiles on a plane tilted in 3D (the site's bento),
// the camera gliding over it while each tile's small picture plays.
(function () {
  'use strict';
  const F = window.Film, UI = window.UI;
  const E = F.ease;
  const f = (n) => n.toFixed(2);

  const chip = (t, cls = 'n') => `<span class="badge ${cls}" style="height:26px;font-size:14px;padding:0 11px">${t}</span>`;
  const TILES = [
    { ic: 'flame', t: 'Прогрев по расписанию', d: 'Готовые списки сайтов для 26 стран',
      art: `<div style="display:flex;align-items:center;gap:10px;font-size:15px"><span class="num tw" style="color:var(--t1)">Прогрев 7/12</span><span class="pbar" style="width:90px;height:4px"><i class="tb" style="width:52px"></i></span><span class="num tc" style="color:var(--t2)">· cookies: 158</span></div>` },
    { ic: 'key', t: 'Пароли и автозаполнение', d: 'Свои у каждого профиля, как в Safari',
      art: `<div style="display:flex;flex-direction:column;gap:7px"><div style="height:34px;border-radius:9px;background:var(--field);box-shadow:inset 0 0 0 1px var(--line2);display:flex;align-items:center;padding:0 12px;font-size:15px">anna@shop.example</div><div style="height:34px;border-radius:9px;background:var(--field);box-shadow:inset 0 0 0 1px var(--line2);display:flex;align-items:center;padding:0 12px;font-size:15px;letter-spacing:.2em" class="pw">••••••••••</div></div>` },
    { ic: 'cookie', t: 'Импорт и экспорт cookies', d: 'Битый файл — импортируется всё читаемое',
      art: `<div style="display:flex;gap:8px;flex-wrap:wrap">${chip('JSON')}${chip('cookies.txt')}${chip('Playwright')}${chip('Selenium')}</div>` },
    { ic: 'lockFill', t: 'Шифрование хранилища', d: 'Остановленный профиль не прочитать даже нам',
      art: `<div style="display:flex;gap:8px">${chip('AES-256-GCM', 'b')}${chip('Argon2id', 'b')}</div>` },
    { ic: 'syncArrows', t: 'Синхронизация между Mac', d: 'Сервер видит только шифротекст',
      art: `<div style="display:flex;align-items:center;gap:14px;color:var(--t2)">${UI.icon('laptop', 34)}<span class="sy" style="color:var(--t1)">${UI.icon('syncArrows', 22)}</span>${UI.icon('laptop', 34)}</div>` },
    { ic: 'iphone', t: 'Вид iPhone и iPad', d: 'Окно и User-Agent мобильной Safari',
      art: `<div style="display:flex;align-items:flex-end;gap:12px;color:var(--t2)"><div style="width:30px;height:56px;border-radius:7px;box-shadow:inset 0 0 0 2px currentColor"></div><div style="width:50px;height:66px;border-radius:7px;box-shadow:inset 0 0 0 2px currentColor"></div><span class="num" style="font-size:14px">390 × 844</span></div>` },
    { ic: 'hourglass', t: 'Временные профили', d: 'Закрыли окно — ничего не осталось',
      art: `<div style="display:flex;gap:8px">${chip('Без истории')}${chip('Без cookies')}${chip('Без следов')}</div>` },
    { ic: 'camera', t: 'Подмена камеры', d: 'Своя картинка или видео для страниц',
      art: `<div style="display:flex;gap:3px;height:46px;border-radius:8px;overflow:hidden;width:190px">${['#E8E8E8', '#E6D44A', '#4FD1D9', '#4FCB58', '#D64FD0', '#D94848', '#3E4FD6'].map((c) => `<i style="flex:1;background:${c};opacity:.85"></i>`).join('')}</div>` },
    { ic: 'eye', t: 'Что видят сайты', d: 'Профиль рядом с Safari этого Mac',
      art: `<div style="display:flex;flex-direction:column;gap:6px;font-size:14px">${['Заголовки', 'TLS', 'Окно'].map((x) => `<div style="display:flex;gap:8px;align-items:center"><span style="color:#8FE3B0">${UI.icon('check', 13)}</span><span style="color:var(--t2);width:96px">${x}</span><span style="color:var(--t1)">как в Safari</span></div>`).join('')}</div>` },
    { ic: 'magnifyingglass', t: 'Палитра команд', d: 'Любой профиль и действие — по буквам',
      art: `<div style="height:40px;border-radius:10px;background:var(--field);box-shadow:inset 0 0 0 1px var(--line2);display:flex;align-items:center;gap:9px;padding:0 12px;font-size:15px;color:var(--t1)">${UI.icon('magnifyingglass', 14)}<span class="pq">Маг</span><span class="caret"></span><span class="kcap" style="font-size:12px">⌘K</span></div>` },
    { ic: 'keyboard', t: 'Вставка как печать', d: 'Поле, которое не даёт вставить, — получит текст',
      art: `<div style="display:flex;gap:6px;align-items:center">${['⌃', '⌘', 'V'].map((x) => `<span style="min-width:38px;height:38px;border-radius:9px;background:var(--bg4);box-shadow:inset 0 -2px 0 rgba(0,0,0,.4),inset 0 0 0 1px var(--line3);display:flex;align-items:center;justify-content:center;font-size:17px">${x}</span>`).join('')}<span class="ty" style="margin-left:10px;font-size:15px;color:var(--t2)"></span></div>` },
    { ic: 'terminal', t: 'API автоматизации', d: 'Запуск, cookies и остановка из скрипта',
      art: `<div class="code" style="font-size:14px;line-height:1.5;color:var(--t2)"><span style="color:var(--t3)">$</span> pbctl start <span class="s">"Магазин DE"</span> --hidden</div>` },
  ];

  F.scene({
    id: 'more', t0: 64.2, t1: 71.0, z: 13,
    build(el) {
      const tile = (x, i) => `<div class="tile" style="position:absolute;left:${(i % 4) * 440}px;top:${Math.floor(i / 4) * 290}px;width:420px;height:270px">
          <div class="panel" style="position:absolute;inset:0;border-radius:26px;padding:26px 28px;background:linear-gradient(180deg,rgba(255,255,255,0.045),rgba(255,255,255,0.015)), #0C0D10">
            <div style="width:44px;height:44px;border-radius:12px;background:var(--bg4);box-shadow:inset 0 0 0 1px var(--line2);display:flex;align-items:center;justify-content:center;color:var(--t1)">${UI.icon(x.ic, 22)}</div>
            <div style="font-size:23px;font-weight:600;letter-spacing:-0.01em;margin-top:16px">${x.t}</div>
            <div style="font-size:15px;color:var(--t3);margin-top:5px">${x.d}</div>
            <div style="position:absolute;left:28px;right:24px;bottom:26px">${x.art}</div>
          </div></div>`;
      el.innerHTML = `
        <div class="abs" data-k="head" style="left:0;right:0;top:64px;text-align:center;z-index:5">
          <div class="title t-l"><span data-k="a">И это</span> <span class="grey" data-k="b">ещё не всё.</span></div>
        </div>
        <div class="fill" style="perspective:2200px;perspective-origin:50% 30%"><div class="abs p3d" data-k="plane" style="left:0;top:0;width:1740px;height:850px;transform-origin:870px 425px">${TILES.map(tile).join('')}</div></div>
        <div class="fill" style="pointer-events:none;background:linear-gradient(180deg,#000 0,rgba(0,0,0,0.9) 150px,rgba(0,0,0,0) 300px)"></div>`;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
      F.words(this.k.a); F.words(this.k.b);
      this.tiles = F.$$(el, '.tile');
      this.k.tw = F.$(el, '.tw'); this.k.tc = F.$(el, '.tc'); this.k.tb = F.$(el, '.tb');
      this.k.pq = F.$(el, '.pq'); this.k.ty = F.$(el, '.ty'); this.k.sy = F.$(el, '.sy');
    },
    update(lt, t, el) {
      const k = this.k;
      F.opacity(el, F.seg(lt, 0, 0.35) * (1 - F.seg(lt, 6.3, 6.8, E.in)));
      F.blur(el, F.seg(lt, 6.3, 6.8, E.in) * 10);
      F.reveal(k.a, lt, 0.2, { stagger: 0.06 });
      F.reveal(k.b, lt, 0.6, { stagger: 0.08 });
      // the plane: tilted back, gliding from its top-left to its bottom-right as one long move
      const g = F.seg(lt, 0, 6.8, E.camera);
      const x = F.lerp(150, 30, g), y = F.lerp(250, 120, g);
      const rx = F.lerp(26, 20, g), rz = F.lerp(-7, -4, g);
      F.transform(k.plane, `translate3d(${f(x)}px, ${f(y)}px, 0) rotateX(${f(rx)}deg) rotateZ(${f(rz)}deg) scale(${f(F.lerp(1.06, 1.12, g))})`);
      this.tiles.forEach((tl, i) => {
        const a = 0.25 + ((i % 4) + Math.floor(i / 4)) * 0.16;
        const kk = F.seg(lt, a, a + 1.0, E.entry);
        F.opacity(tl, kk);
        F.transform(tl, `translateZ(${f((1 - kk) * -260)}px)`);
        F.blur(tl, (1 - kk) * 6);
      });
      // small lives: the warm-up goes on, the palette is typed into, the paste types itself
      const wp = 7 + Math.min(4, Math.floor(F.prog(lt, 1.2, 6.0) * 5));
      F.text(k.tw, `Прогрев ${wp}/12`);
      F.text(k.tc, `· cookies: ${158 + (wp - 7) * 23}`);
      F.css(k.tb, 'width', `${Math.round((90 * wp) / 12)}px`);
      const word = 'Магазин DE';
      F.text(k.pq, word.slice(0, Math.max(1, Math.min(word.length, Math.floor(F.prog(lt, 1.6, 3.4) * word.length)))));
      const typed = 'Пароль-из-письма';
      F.text(k.ty, typed.slice(0, Math.floor(F.prog(lt, 2.2, 5.0) * typed.length)));
      F.transform(k.sy, `rotate(${f(lt * 60)}deg)`);
    },
  });
})();
