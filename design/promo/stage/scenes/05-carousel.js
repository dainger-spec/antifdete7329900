// 38.9–64.6 s: Lumen's features one card at a time on a carousel (2.3 s each): automation, every day, the Team
// plan, the Mac, the iPhone. Each card: its group, a two-tone title, one sentence, and a small film of its own.
(function () {
  'use strict';
  const F = window.Film, UI = window.UI;
  const E = F.ease;
  const f = (n) => n.toFixed(2);

  // MARK: The cards

  const CW = 1200, CH = 580;
  const mono = (s) => `<span style="font-family:var(--mono)">${s}</span>`;
  const pill = (t, cls = 'n', big) => `<span class="badge ${cls}" style="height:${big ? 34 : 28}px;font-size:${big ? 16 : 14}px;padding:0 ${big ? 15 : 12}px">${t}</span>`;
  const cursor = (cls = 'cur') => `<div class="${cls}" style="position:absolute;left:0;top:0;width:26px;height:26px;z-index:9">${UI.icon('cursor', 26)}<i class="rip" style="position:absolute;left:-14px;top:-14px;width:30px;height:30px;border-radius:50%;border:2px solid rgba(47,107,239,0.9);opacity:0"></i></div>`;
  // Moves a cursor along keys [[u, x, y], …] (a smooth path); clicks at times `clicks`.
  const moveCursor = (c, u, keys, clicks = []) => {
    const p = F.path(keys.map((q) => [q[0], [q[1], q[2]]]))(u);
    let press = 0, rip = 0;
    for (const cu of clicks) {
      press = Math.max(press, F.window(u, cu - 0.08, cu + 0.1, 0.06, 0.1));
      const r = F.prog(u, cu, cu + 0.45);
      if (r > 0 && r < 1) rip = r;
    }
    F.transform(c, `translate(${f(p[0])}px, ${f(p[1])}px) scale(${f(1 - press * 0.12)})`);
    const ring = c.querySelector('.rip');
    F.opacity(ring, rip > 0 ? 1 - rip : 0);
    F.transform(ring, `scale(${f(0.4 + rip * 1.6)})`);
  };
  const safariMini = (o) => {
    const s = UI.safari(o);
    s.style.position = 'absolute';
    s.style.left = o.x + 'px';
    s.style.top = o.y + 'px';
    return s.outerHTML;
  };
  const shopPage = (o = {}) => `<div style="position:absolute;inset:0;padding:18px 24px;font-family:var(--font);color:#111;background:#FAFAFA">
      <div style="display:flex;justify-content:space-between;align-items:center"><b style="font-size:20px;letter-spacing:-0.01em">shop.example</b>
        <div style="display:flex;gap:16px;font-size:14px;color:#333"><span class="sp-login" style="padding:5px 10px;border-radius:7px">Войти</span><span class="sp-cart" style="padding:5px 10px;border-radius:7px">Корзина</span></div></div>
      <div style="display:flex;gap:18px;margin-top:18px">
        <div style="width:190px;height:190px;border-radius:12px;background:linear-gradient(150deg,#E7D9C5,#B79B7A)"></div>
        <div style="flex:1"><div style="font-size:21px;font-weight:600">Шарф из шерсти мериноса</div><div style="font-size:15px;color:#666;margin-top:6px">Тёплый, мягкий, 180 × 30 см</div>
          <div style="font-size:24px;font-weight:700;margin-top:14px">49 €</div>
          ${o.email ? `<div class="sp-email" style="margin-top:12px;height:36px;border-radius:8px;border:1px solid #CCC;background:#fff;display:flex;align-items:center;padding:0 10px;font-size:14px;color:#111"></div>` : ''}
          <div class="sp-buy" style="display:inline-flex;margin-top:14px;height:40px;padding:0 20px;align-items:center;border-radius:20px;background:#111;color:#fff;font-size:15px;font-weight:600">В корзину</div></div></div></div>`;

  const FEATURES = [
    // 1. WebDriver
    {
      group: 'Автоматизация', a: 'WebDriver', b: 'в каждом профиле.',
      sub: 'Selenium и другие клиенты WebDriver подключаются к профилю как к Safari — готовые скрипты работают без переделки.',
      html: () => `
        <div style="position:absolute;left:40px;top:40px;width:620px;height:500px;border-radius:18px;background:var(--field);box-shadow:inset 0 0 0 1px var(--line2);overflow:hidden">
          <div style="height:42px;display:flex;align-items:center;gap:8px;padding:0 16px;border-bottom:1px solid var(--line);font-size:13px;color:var(--t3)"><i style="width:10px;height:10px;border-radius:50%;background:#3A3B40"></i><i style="width:10px;height:10px;border-radius:50%;background:#3A3B40"></i><i style="width:10px;height:10px;border-radius:50%;background:#3A3B40"></i><span style="margin-left:10px">checkout.py</span></div>
          <div class="code wd" style="padding:22px 24px;font-size:18.5px;line-height:1.66">${[
            '<span class="k">from</span> selenium <span class="k">import</span> webdriver',
            '',
            '<span class="c"># профиль Lumen — как обычная Safari</span>',
            'driver = webdriver.<span class="f">Remote</span>(',
            '    <span class="s">"http://127.0.0.1:4444/Магазин-3"</span>,',
            '    options=webdriver.<span class="f">SafariOptions</span>(),',
            ')',
            'driver.<span class="f">get</span>(<span class="s">"https://shop.example"</span>)',
            'driver.<span class="f">find_element</span>(<span class="s">"id"</span>, <span class="s">"buy"</span>).<span class="f">click</span>()',
          ].map((l) => `<div class="ln">${l || '&nbsp;'}</div>`).join('')}</div></div>
        ${safariMini({ x: 690, y: 64, w: 470, h: 330, profile: UI.byId('shop3'), url: 'shop.example', automation: true, page: shopPage() })}
        <div style="position:absolute;left:690px;top:412px;width:470px;font-size:14px;color:#F4B35F;display:flex;gap:8px;align-items:center">${UI.icon('bolt', 14)}Окно управляется WebDriver — как в Safari</div>
        <div style="position:absolute;left:690px;top:470px;display:flex;gap:10px">${pill('Selenium', 'n', true)}${pill('WebdriverIO', 'n', true)}${pill('safaridriver', 'b', true)}</div>
        ${cursor()}`,
      anim(u, root) {
        F.$$(root, '.wd .ln').forEach((l, i) => { const k = F.seg(u, -0.3 + i * 0.1, 0.1 + i * 0.1, E.out); F.opacity(l, k); F.transform(l, `translateX(${f((1 - k) * -10)}px)`); });
        const c = F.$(root, '.cur');
        moveCursor(c, u, [[0.6, 1060, 300], [1.3, 980, 252], [1.9, 975, 250]], [1.4]);
        F.opacity(c, F.seg(u, 0.55, 0.8));
        const buy = F.$(root, '.sp-buy');
        F.css(buy, 'background', u > 1.4 ? '#2F6BEF' : '#111');
        F.text(buy, u > 1.45 ? 'В корзине ✓' : 'В корзину');
      },
    },
    // 2. One-time codes
    {
      group: 'Каждый день', a: 'Коды 2FA —', b: 'прямо в профиле.',
      sub: 'Одноразовые коды хранятся рядом с паролем, как в приложении-аутентификаторе, и подставляются в поле сами.',
      html: () => {
        const row = (l, site, user, code, c) => `<div class="otp" style="display:flex;align-items:center;gap:14px;height:76px;padding:0 18px;border-radius:14px;border-bottom:1px solid var(--line)">
            <span style="width:40px;height:40px;border-radius:50%;background:${UI.PALETTE[c][0]};color:${UI.PALETTE[c][1]};display:flex;align-items:center;justify-content:center;font-weight:600">${l}</span>
            <div style="flex:1"><div style="font-size:17px;font-weight:500">${site}</div><div style="font-size:14px;color:var(--t3);margin-top:2px">${user}</div></div>
            <div class="num code-v" style="font-family:var(--mono);font-size:26px;letter-spacing:0.04em;color:var(--t1)">${code}</div>
            <svg class="ring" width="30" height="30" viewBox="0 0 30 30"><circle cx="15" cy="15" r="12" fill="none" stroke="rgba(255,255,255,0.12)" stroke-width="3"/><circle class="rc" cx="15" cy="15" r="12" fill="none" stroke="#9FD4BB" stroke-width="3" stroke-linecap="round" stroke-dasharray="75.4 75.4" transform="rotate(-90 15 15)"/></svg></div>`;
        return `<div style="position:absolute;left:40px;top:40px;width:600px;height:500px;border-radius:18px;background:rgba(11,12,15,0.9);box-shadow:inset 0 0 0 1px var(--line2);padding:22px 20px">
            <div style="display:flex;align-items:center;gap:10px;padding:0 4px 14px">${UI.icon('key', 18)}<span style="font-size:20px;font-weight:600">Пароли · Магазин DE</span></div>
            ${row('S', 'shop.example', 'anna@shop.example', '482 913', 0)}${row('M', 'mail.example', 'anna@mail.example', '730 551', 3)}${row('B', 'bank.example', 'a.schmidt', '118 042', 1)}
            <div style="font-size:14px;color:var(--t3);padding:16px 4px 0">Секрет — текстом, ссылкой otpauth:// или QR-кодом.</div></div>
          <div style="position:absolute;left:680px;top:70px;width:480px;height:440px;border-radius:18px;background:#FFFFFF;color:#111;padding:34px 36px;box-shadow:0 30px 70px rgba(0,0,0,0.5)">
            <div style="font-size:14px;color:#777">shop.example · Вход, шаг 2 из 2</div>
            <div style="font-size:26px;font-weight:700;margin-top:10px;letter-spacing:-0.01em">Введите код</div>
            <div style="font-size:15px;color:#555;margin-top:6px">из приложения-аутентификатора</div>
            <div class="fld" style="margin-top:22px;height:56px;border-radius:12px;border:2px solid #2F6BEF;display:flex;align-items:center;padding:0 16px;font-family:var(--mono);font-size:26px;letter-spacing:0.35em"></div>
            <div class="sug" style="margin-top:8px;border-radius:12px;background:#F2F2F7;box-shadow:0 10px 30px rgba(0,0,0,0.15);padding:6px">
              <div style="display:flex;align-items:center;gap:12px;height:54px;padding:0 12px;border-radius:9px;background:#2F6BEF;color:#fff">${UI.icon('key', 18)}<div style="flex:1"><div style="font-size:15px;font-weight:600">anna@shop.example</div><div style="font-size:13px;opacity:.85">Код из Lumen · 482 913</div></div></div></div>
            <div class="go" style="margin-top:22px;height:48px;border-radius:24px;background:#111;color:#fff;display:flex;align-items:center;justify-content:center;font-size:16px;font-weight:600">Подтвердить</div></div>`;
      },
      anim(u, root) {
        F.$$(root, '.rc').forEach((c, i) => {
          const left = 1 - ((u * 0.12 + 0.35 + i * 0.21) % 1);
          c.setAttribute('stroke-dasharray', `${f(75.4 * left)} 75.4`);
        });
        const sug = F.$(root, '.sug');
        const sk = F.window(u, 0.2, 1.25, 0.25, 0.15);
        F.opacity(sug, sk);
        F.transform(sug, `translateY(${f((1 - sk) * -8)}px)`);
        const code = '482913';
        const n = Math.floor(F.prog(u, 1.2, 1.5) * code.length + 0.001);
        F.text(F.$(root, '.fld'), code.slice(0, n));
        F.css(F.$(root, '.go'), 'background', u > 1.6 ? '#1F9D55' : '#111');
        F.text(F.$(root, '.go'), u > 1.6 ? 'Вход выполнен ✓' : 'Подтвердить');
        F.css(F.$(root, '.otp'), 'background', `rgba(47,107,239,${f(0.16 * F.window(u, 0.2, 1.4, 0.2, 0.3))})`);
      },
    },
    // 3. Profile health
    {
      group: 'Каждый день', a: 'Здоровье профиля —', b: 'одной кнопкой.',
      sub: 'Lumen сам сверит часовой пояс, язык и страну с IP прокси и подскажет, что исправить.',
      html: () => {
        const item = (cls, title, detail, fix) => `<div class="hi ${cls}" style="display:flex;align-items:center;gap:16px;height:74px;padding:0 20px;border-radius:16px;margin-bottom:8px;background:rgba(255,255,255,0.03);box-shadow:inset 0 0 0 1px var(--line)">
            <span class="hg" style="flex:none;width:30px;height:30px;border-radius:50%;display:flex;align-items:center;justify-content:center"></span>
            <div style="flex:1"><div class="ht" style="font-size:18px;font-weight:500">${title}</div><div class="hd" style="font-size:14px;color:var(--t3);margin-top:3px">${detail}</div></div>${fix ? `<div class="btn hot fixb" style="height:36px;font-size:15px;padding:0 16px">Исправить</div>` : ''}</div>`;
        return `<div style="position:absolute;left:60px;top:70px;width:380px;height:440px;display:flex;flex-direction:column;align-items:center">
            <svg width="300" height="300" viewBox="0 0 300 300"><circle cx="150" cy="150" r="128" fill="none" stroke="rgba(255,255,255,0.08)" stroke-width="16"/>
              <circle class="sc" cx="150" cy="150" r="128" fill="none" stroke="#E3A53C" stroke-width="16" stroke-linecap="round" stroke-dasharray="0 804" transform="rotate(-90 150 150)"/></svg>
            <div class="num scn" style="position:absolute;top:96px;font-family:var(--display);font-size:104px;font-weight:600;letter-spacing:-0.04em">0</div>
            <div style="position:absolute;top:214px;font-size:17px;color:var(--t2)">из 100</div>
            <div style="margin-top:22px;display:flex;align-items:center;gap:10px;font-size:19px">${UI.avatar('М', 0, 30, true)}Магазин DE</div></div>
          <div style="position:absolute;left:480px;top:60px;width:680px">
            ${item('h0', 'Часовой пояс совпадает с IP', 'Europe/Berlin — как у выхода прокси')}
            ${item('h1', 'IP прокси нет в чёрных списках', 'Проверено по спам-базам')}
            ${item('h2', 'Язык не как у страны', 'en-US, а IP — в Германии', true)}
            ${item('h3', 'WebRTC — с адреса прокси', 'Через ретранслятор, UDP работает')}
            ${item('h4', 'Отпечаток — как у Safari', 'Без шума и подмен')}</div>`;
      },
      anim(u, root) {
        const fixAt = 1.25;
        F.$$(root, '.hi').forEach((h, i) => {
          const at = -0.15 + i * 0.16;
          const on = u >= at;
          const warn = i === 2 && u < fixAt + 0.05;
          const g = F.$(h, '.hg');
          const key = !on ? 'off' : warn ? 'warn' : 'ok';
          if (g._k !== key) {
            g._k = key;
            g.innerHTML = key === 'ok' ? UI.icon('check', 15) : key === 'warn' ? UI.icon('exclamationTriangleFill', 15) : '';
            g.style.background = key === 'ok' ? 'rgba(74,222,128,0.14)' : key === 'warn' ? 'rgba(227,165,60,0.14)' : 'rgba(255,255,255,0.05)';
            g.style.color = key === 'ok' ? '#8FE3B0' : '#EBC07A';
            h.style.boxShadow = key === 'warn' ? 'inset 0 0 0 1px rgba(227,165,60,0.4)' : 'inset 0 0 0 1px var(--line)';
          }
          F.opacity(h, 0.35 + 0.65 * F.seg(u, at - 0.1, at + 0.2, E.out));
          if (i === 2) {
            const fixed = u >= fixAt + 0.05;
            F.text(F.$(h, '.ht'), fixed ? 'Язык как у страны' : 'Язык не как у страны');
            F.text(F.$(h, '.hd'), fixed ? 'de-DE, de — как в Германии' : 'en-US, а IP — в Германии');
            const b = F.$(h, '.fixb');
            F.opacity(b, fixed ? 1 - F.seg(u, fixAt + 0.05, fixAt + 0.3) : 1);
            F.transform(b, `scale(${f(1 - 0.08 * F.window(u, fixAt - 0.08, fixAt + 0.08, 0.05, 0.08))})`);
          }
        });
        const score = u < fixAt ? F.lerp(0, 86, F.seg(u, 0, 0.9, E.outCubic)) : F.lerp(86, 100, F.seg(u, fixAt + 0.05, fixAt + 0.6, E.outCubic));
        F.text(F.$(root, '.scn'), String(Math.round(score)));
        const sc = F.$(root, '.sc');
        sc.setAttribute('stroke-dasharray', `${f(804 * score / 100)} 804`);
        sc.setAttribute('stroke', score >= 99.5 ? '#4ADE80' : '#E3A53C');
      },
    },
    // 4. Proxy monitor
    {
      group: 'Каждый день', a: 'Монитор прокси.', b: 'Предупредит заранее.',
      sub: 'Фоновая проверка: жив ли прокси, не сменил ли страну, не попал ли в спам-базы — до того, как профиль откроют.',
      html: () => {
        const r = (cc, name, ip, cls) => `<div class="mr ${cls}" style="display:flex;align-items:center;gap:14px;height:64px;padding:0 20px;border-bottom:1px solid var(--line);font-size:17px">
            <span class="mf" style="display:flex">${UI.flag(cc, 22)}</span><span style="width:140px;font-weight:500">${name}</span>
            <span style="width:170px;font-family:var(--mono);font-size:15px;color:var(--t2)">${ip}</span><span class="ms" style="display:flex;align-items:center;gap:8px"><i class="rdot"></i><span>Работает</span></span></div>`;
        return `<div style="position:absolute;left:40px;top:40px;width:690px;height:500px;border-radius:18px;background:rgba(11,12,15,0.9);box-shadow:inset 0 0 0 1px var(--line2);overflow:hidden">
            <div style="display:flex;align-items:center;gap:12px;height:64px;padding:0 20px;border-bottom:1px solid var(--line)"><span style="font-size:20px;font-weight:600">Прокси</span>
              <span style="margin-left:auto;display:flex;gap:9px;align-items:center;font-size:15px;color:var(--t2)"><i class="mon" style="width:9px;height:9px;border-radius:50%;background:#4ADE80;box-shadow:0 0 10px rgba(74,222,128,0.8)"></i>Фоновая проверка</span></div>
            ${r('DE', 'Berlin 1', '203.0.113.47', 'm0')}${r('DE', 'Berlin 2', '203.0.113.52', 'm1')}${r('US', 'New York 2', '198.51.100.23', 'm2')}${r('PT', 'Lisboa', '192.0.2.61', 'm3')}${r('FR', 'Paris 3', '198.51.100.140', 'm4')}${r('SE', 'Stockholm', '192.0.2.18', 'm5')}
            <div class="scan" style="position:absolute;left:0;right:0;height:64px;background:linear-gradient(180deg,rgba(236,240,248,0),rgba(236,240,248,0.07),rgba(236,240,248,0));pointer-events:none"></div></div>
          <div class="notif nt" style="left:752px;top:150px;width:420px">
            <div class="app">${UI.mark(38)}</div>
            <div style="flex:1"><div style="display:flex"><span class="t">Lumen</span><span class="when">сейчас</span></div>
              <div class="b">Прокси Berlin 2 сменил страну: Германия → Нидерланды. «Магазин-3» не откроется, пока вы не проверите прокси.</div></div></div>`;
      },
      anim(u, root) {
        const scan = F.$(root, '.scan');
        const sy = 64 + ((u + 0.6) % 1.3) / 1.3 * 384;
        F.transform(scan, `translateY(${f(sy)}px)`);
        F.opacity(F.$(root, '.mon'), 0.55 + 0.45 * Math.abs(Math.sin(u * 3.2)));
        const set = (cls, key, flag, html, color) => {
          const r = F.$(root, '.' + cls);
          if (r._k === key) return;
          r._k = key;
          if (flag) F.$(r, '.mf').innerHTML = UI.flag(flag, 22);
          F.$(r, '.ms').innerHTML = html;
          r.style.background = color || 'transparent';
        };
        if (u > 0.55) set('m1', 'moved', 'NL', `<span style="width:9px;height:9px;border-radius:50%;background:var(--warn)"></span><span style="color:#EBC07A">Сменил страну: Нидерланды</span>`, 'rgba(227,165,60,0.07)');
        else set('m1', 'ok', 'DE', '<i class="rdot"></i><span>Работает</span>');
        if (u > 0.85) set('m3', 'spam', null, `<span style="width:9px;height:9px;border-radius:2px;transform:rotate(45deg);background:var(--red)"></span><span style="color:#F59C97">В спам-базе</span>`, 'rgba(242,112,106,0.07)');
        else set('m3', 'ok', null, '<i class="rdot"></i><span>Работает</span>');
        const n = F.$(root, '.nt');
        const nk = F.seg(u, 0.95, 1.5, E.entry);
        F.opacity(n, nk);
        F.transform(n, `translateX(${f((1 - nk) * 120)}px)`);
      },
    },
    // 5. Safari extensions per profile
    {
      group: 'Каждый день', a: 'Расширения Safari —', b: 'свои в каждом профиле.',
      sub: 'Блокировщик рекламы, криптокошелёк, переводчик: в одном профиле есть, в другом — нет.',
      html: () => {
        const bar = (p, cc, exts, y) => `<div class="xb" style="position:absolute;left:60px;top:${y}px;width:1080px;height:72px;border-radius:18px;background:#2A2B30;box-shadow:0 0 0 1px rgba(255,255,255,0.12),0 20px 50px rgba(0,0,0,0.5);display:flex;align-items:center;gap:14px;padding:0 18px">
            <div style="display:flex;gap:8px">${['#FF5F57', '#FEBC2E', '#28C840'].map((c) => `<i style="width:13px;height:13px;border-radius:50%;background:${c}"></i>`).join('')}</div>
            <div style="display:flex;align-items:center;gap:8px;height:38px;padding:0 14px 0 5px;border-radius:19px;background:#3A3B40;font-size:15px;font-weight:500">${UI.avatar(p.letters, p.color, 28)}${p.name}${UI.flag(cc, 16)}</div>
            <div style="flex:1;height:40px;border-radius:12px;background:#3A3B40;display:flex;align-items:center;justify-content:center;font-size:15px;color:#C7C7CC">${p.url}</div>
            <div style="display:flex;gap:10px">${exts.map((x) => `<div class="xi" style="width:46px;height:46px;border-radius:12px;background:${x[1]};display:flex;align-items:center;justify-content:center;color:#fff">${UI.icon(x[0], 24)}</div>`).join('')}</div>
            <div style="width:290px;font-size:14px;color:#A1A1A6;text-align:right" class="xl">${exts.map((x) => x[2]).join(' · ')}</div></div>`;
        return bar({ ...UI.byId('shop'), url: 'shop.example' }, 'DE', [['shield', '#3D7BF0', 'Блокировщик рекламы']], 70) +
          bar({ name: 'Crypto', letters: 'C', color: 7, url: 'wallet.example' }, 'CH', [['wallet', '#E58B2E', 'Криптокошелёк'], ['shield', '#3D7BF0', 'Блокировщик']], 230) +
          bar({ ...UI.byId('jp'), url: 'news.example.jp' }, 'JP', [['translate', '#2FA36B', 'Переводчик']], 390);
      },
      anim(u, root) {
        F.$$(root, '.xb').forEach((b, i) => {
          const k = F.seg(u, -0.4 + i * 0.15, 0.3 + i * 0.15, E.entry);
          F.opacity(b, k);
          F.transform(b, `translateY(${f((1 - k) * 30)}px)`);
        });
        F.$$(root, '.xi').forEach((x, i) => {
          const k = F.seg(u, 0.35 + i * 0.18, 0.75 + i * 0.18, E.entry);
          F.transform(x, `scale(${f(k)})`);
          F.opacity(x, k);
        });
        F.$$(root, '.xl').forEach((x, i) => F.opacity(x, F.seg(u, 0.6 + i * 0.2, 1.0 + i * 0.2)));
      },
    },
    // 6. Team: shared profiles with roles
    {
      group: 'Для команд · тариф Team', a: 'Общие профили.', b: 'Роли, блокировка, журнал.',
      sub: 'Кто-то только открывает, кто-то меняет. Пока один работает в профиле, у остальных он занят.',
      html: () => {
        const m = (l, c, name, role, cls, note) => `<div style="display:flex;align-items:center;gap:14px;height:62px;border-bottom:1px solid var(--line)">
            <span style="width:40px;height:40px;border-radius:50%;background:${UI.PALETTE[c][0]};color:${UI.PALETTE[c][1]};display:flex;align-items:center;justify-content:center;font-weight:600;font-size:17px">${l}</span>
            <span style="flex:1;font-size:18px">${name}${note ? `<span style="color:var(--t3);font-size:15px"> · ${note}</span>` : ''}</span>${pill(role, cls)}</div>`;
        const log = [['10:42', 'Анна открыла профиль'], ['10:44', 'Анна сменила прокси: Berlin 1 → Berlin 2'], ['10:51', 'Олег: профиль занят — ждёт'], ['11:03', 'Анна закрыла профиль'], ['11:03', 'Олег открыл профиль']];
        return `<div style="position:absolute;left:40px;top:40px;width:560px;height:500px;border-radius:18px;background:rgba(11,12,15,0.9);box-shadow:inset 0 0 0 1px var(--line2);padding:26px 28px">
            <div style="display:flex;align-items:center;gap:14px">${UI.avatar('М3', 1, 52)}<div><div style="font-family:var(--display);font-size:24px;font-weight:700;letter-spacing:-0.02em">Магазин-3</div><div style="font-size:14px;color:var(--t3);margin-top:2px">Общий профиль · 3 участника</div></div></div>
            <div class="lockb" style="margin-top:18px;display:flex;align-items:center;gap:10px;height:46px;padding:0 14px;border-radius:12px;background:rgba(227,165,60,0.08);box-shadow:inset 0 0 0 1px rgba(227,165,60,0.3);font-size:16px;color:#EBC07A">${UI.icon('lockFill', 16)}Сейчас в профиле работает Анна</div>
            <div style="margin-top:12px">${m('А', 1, 'Анна', 'Может менять', 'g', 'в профиле')}${m('О', 3, 'Олег', 'Только открывать', 'n', 'ждёт')}${m('И', 6, 'Ира', 'Только открывать', 'n')}</div></div>
          <div style="position:absolute;left:640px;top:40px;width:520px;height:500px;border-radius:18px;background:rgba(11,12,15,0.9);box-shadow:inset 0 0 0 1px var(--line2);padding:26px 28px">
            <div style="font-size:12px;font-weight:600;letter-spacing:0.088em;text-transform:uppercase;color:var(--t3)">Журнал</div>
            ${log.map((x) => `<div class="lg" style="display:flex;gap:16px;padding:15px 0;border-bottom:1px solid var(--line);font-size:17px"><span class="num" style="color:var(--t3);width:54px">${x[0]}</span><span>${x[1]}</span></div>`).join('')}</div>`;
      },
      anim(u, root) {
        F.$$(root, '.lg').forEach((l, i) => {
          const k = F.seg(u, -0.2 + i * 0.28, 0.25 + i * 0.28, E.entry);
          F.opacity(l, k);
          F.transform(l, `translateY(${f((1 - k) * 14)}px)`);
        });
        const lb = F.$(root, '.lockb');
        F.opacity(lb, F.seg(u, -0.1, 0.3));
      },
    },
    // 7. Hand a profile over, encrypted
    {
      group: 'Для команд · тариф Team', a: 'Профиль — клиенту.', b: 'Одним зашифрованным файлом.',
      sub: 'Все cookies, настройки, прокси и пароли — в одном файле под паролем. Коллеге или клиенту.',
      html: () => {
        const it = ['Cookies · 1 284', 'Настройки', 'Прокси', 'Пароли · 12', 'История'];
        return `<div class="who" style="position:absolute;left:70px;top:190px;text-align:center;width:180px"><div style="margin:0 auto;width:124px">${UI.avatar('Вы', 0, 124)}</div><div style="font-size:21px;margin-top:14px;color:var(--t2)">Вы</div></div>
          <div class="who2" style="position:absolute;left:950px;top:190px;text-align:center;width:180px"><div style="margin:0 auto;width:124px">${UI.avatar('К', 5, 124)}</div><div style="font-size:21px;margin-top:14px;color:var(--t2)">Клиент</div></div>
          <svg style="position:absolute;left:0;top:0" width="1200" height="580"><path class="arc" d="M260 250 Q600 40 940 250" fill="none" stroke="rgba(236,240,248,0.35)" stroke-width="2" stroke-dasharray="6 10"/></svg>
          <div class="doc" style="position:absolute;left:495px;top:120px;width:210px;height:270px">
            <div style="position:absolute;inset:0;border-radius:18px;background:linear-gradient(160deg,#23252C,#15161A);box-shadow:0 0 0 1px rgba(255,255,255,0.16),0 30px 60px rgba(0,0,0,0.6);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:16px">
              ${UI.mark(84)}<div style="font-size:17px;color:var(--t1);font-weight:500">Магазин-3.lumen</div></div>
            <div class="dl" style="position:absolute;right:-16px;bottom:-16px;width:52px;height:52px;border-radius:50%;background:#2F6BEF;display:flex;align-items:center;justify-content:center;color:#fff;box-shadow:0 10px 30px rgba(47,107,239,0.5)">${UI.icon('lockFill', 24)}</div></div>
          ${it.map((x, i) => `<div class="fi" style="position:absolute;left:0;top:0">${pill(x, 'n', true)}</div>`).join('')}
          <div class="cap2" style="position:absolute;left:0;right:0;top:468px;text-align:center;font-size:19px;color:var(--t2)">Зашифровано паролем файла · открывается в Lumen</div>`;
      },
      anim(u, root) {
        const items = F.$$(root, '.fi');
        const start = [[200, 430], [330, 480], [760, 470], [880, 420], [560, 500]];
        items.forEach((it, i) => {
          const k = F.seg(u, -0.3 + i * 0.12, 0.45 + i * 0.12, E.inOut);
          const x = F.lerp(start[i][0], 545, k), y = F.lerp(start[i][1], 240, k);
          F.transform(it, `translate(${f(x)}px, ${f(y)}px) scale(${f(1 - 0.6 * k)})`);
          F.opacity(it, (1 - F.seg(u, 0.35 + i * 0.12, 0.5 + i * 0.12)) * F.seg(u, -0.5 + i * 0.12, -0.2 + i * 0.12));
        });
        const lk = F.seg(u, 0.75, 1.05, E.entry);
        const dl = F.$(root, '.dl');
        F.transform(dl, `scale(${f(lk)})`);
        F.opacity(dl, lk);
        const fly = F.seg(u, 1.15, 1.95, E.inOut);
        const doc = F.$(root, '.doc');
        const px = F.lerp(0, 430, fly), py = -Math.sin(fly * Math.PI) * 140 + fly * 30;
        F.transform(doc, `translate(${f(px)}px, ${f(py)}px) scale(${f(1 - 0.5 * fly)}) rotate(${f(fly * 8)}deg)`);
        F.css(F.$(root, '.arc'), 'stroke-dashoffset', f(-u * 30));
        F.opacity(F.$(root, '.who2'), 0.55 + 0.45 * F.seg(u, 1.7, 2.0));
      },
    },
    // 8. Quick launch
    {
      group: 'Удобство на Mac', a: 'Профиль — в один шаг.', b: 'Не открывая программу.',
      sub: 'Значок в строке меню, Spotlight, Shortcuts и Raycast: «открой профиль Магазин-3».',
      html: () => `
        <div style="position:absolute;left:0;right:0;top:0;height:44px;background:rgba(30,31,36,0.92);border-bottom:1px solid rgba(255,255,255,0.08);display:flex;align-items:center;justify-content:flex-end;gap:22px;padding:0 24px;font-size:15px;color:#E5E5EA">
          <span class="mbi" style="display:flex;align-items:center;justify-content:center;width:34px;height:28px;border-radius:7px">${UI.glyph(18, '#F4F4F5')}</span>${UI.icon('wand', 16)}${UI.icon('magnifyingglass', 16)}<span>Чт 12 нояб. 10:41</span></div>
        <div class="menu mbm" style="left:860px;top:52px;width:300px">
          <div class="mh">Lumen</div>
          ${[['shop', true], ['shop3', false], ['north', true], ['jp', false]].map(([id, on]) => { const p = UI.byId(id); return `<div class="mi${id === 'shop3' ? ' hot' : ''}">${UI.avatar(p.letters, p.color, 22, on)}<span style="flex:1">${p.name}</span>${UI.flag(p.cc, 14)}</div>`; }).join('')}
          <div class="sep"></div><div class="mi">Открыть Lumen</div></div>
        <div class="spot" style="position:absolute;left:90px;top:170px;width:680px;border-radius:24px;background:rgba(40,41,46,0.9);box-shadow:inset 0 0.5px 0 rgba(255,255,255,0.25),0 0 0 0.5px rgba(255,255,255,0.14),0 30px 70px rgba(0,0,0,0.6);overflow:hidden">
          <div style="display:flex;align-items:center;gap:14px;height:76px;padding:0 24px;font-size:28px;color:#F2F2F7">${UI.icon('magnifyingglass', 24)}<span class="sq"></span><span class="caret" style="height:30px"></span></div>
          <div class="hit" style="display:flex;align-items:center;gap:14px;height:70px;margin:0 10px 10px;padding:0 14px;border-radius:14px;background:#2F6BEF">${UI.mark(42)}<div><div style="font-size:19px;font-weight:600">Магазин-3</div><div style="font-size:14px;opacity:.8">Профиль Lumen · Нидерланды</div></div><span style="margin-left:auto;font-size:14px;opacity:.85">Открыть ↩</span></div></div>
        <div style="position:absolute;left:90px;top:440px;display:flex;gap:12px">${['Строка меню', 'Spotlight', 'Shortcuts', 'Raycast'].map((x) => `<span class="ql">${pill(x, 'n', true)}</span>`).join('')}</div>`,
      anim(u, root) {
        const m = F.$(root, '.mbm');
        const mk = F.seg(u, -0.2, 0.15, E.out);
        F.opacity(m, mk);
        F.transform(m, `translateY(${f((1 - mk) * -6)}px)`);
        F.css(F.$(root, '.mbi'), 'background', `rgba(255,255,255,${f(0.18 * mk)})`);
        const q = 'открой профиль Магазин-3';
        F.text(F.$(root, '.sq'), q.slice(0, Math.floor(F.prog(u, 0.2, 1.1) * q.length)));
        const hit = F.$(root, '.hit');
        const hk = F.seg(u, 1.0, 1.3, E.entry);
        F.opacity(hit, hk);
        F.css(hit, 'transform', `translateY(${f((1 - hk) * -8)}px)`);
        F.$$(root, '.ql').forEach((x, i) => F.opacity(x, F.seg(u, 0.1 + i * 0.12, 0.45 + i * 0.12)));
      },
    },
    // 9. Bulk
    {
      group: 'Удобство на Mac', a: 'Список прокси →', b: '50 готовых профилей.',
      sub: 'Загрузили список — получили профили с тегами, cookies и своим прокси у каждого.',
      html: () => {
        const cities = [['DE', 'Berlin'], ['NL', 'Amsterdam'], ['FR', 'Paris'], ['US', 'New-York'], ['GB', 'London'], ['SE', 'Stockholm'], ['PT', 'Lisboa'], ['IT', 'Milano'], ['ES', 'Madrid'], ['PL', 'Warszawa'], ['JP', 'Tokyo'], ['CH', 'Zurich']];
        const lines = cities.map(([cc, c], i) => `<div style="white-space:nowrap"><span style="color:var(--t3)">socks5://</span>u${i + 1}:••••@${cc.toLowerCase()}.gw.example:1080 <span style="color:#6C7180"># ${c} ${i + 1}</span></div>`).join('');
        let grid = '';
        for (let i = 0; i < 50; i++) {
          const c = i % 8, cc = cities[i % cities.length][0];
          grid += `<div class="gp" style="position:absolute;left:${(i % 10) * 54}px;top:${Math.floor(i / 10) * 64}px;width:46px;height:46px">${UI.avatar(String(i + 1), c, 46)}<span style="position:absolute;right:-3px;bottom:-3px">${UI.flag(cc, 16)}</span></div>`;
        }
        return `<div style="position:absolute;left:40px;top:40px;width:440px;height:500px;border-radius:18px;background:var(--field);box-shadow:inset 0 0 0 1px var(--line2);overflow:hidden">
            <div style="height:48px;display:flex;align-items:center;padding:0 18px;border-bottom:1px solid var(--line);font-size:15px;color:var(--t2)">proxies.txt<span class="num" style="margin-left:auto;color:var(--t3)">50 строк</span></div>
            <div style="position:absolute;left:0;right:0;top:49px;bottom:0;overflow:hidden"><div class="pl" style="padding:14px 18px;font-family:var(--mono);font-size:14px;line-height:2.05;color:var(--t2)">${lines}${lines}</div></div></div>
          <div style="position:absolute;left:500px;top:250px;width:100px;display:flex;justify-content:center;color:var(--t1)" class="arrow">${UI.icon('arrowRightLong', 52)}</div>
          <div style="position:absolute;left:620px;top:60px;width:540px;height:420px">${grid}</div>
          <div style="position:absolute;left:620px;top:400px;display:flex;align-items:baseline;gap:14px"><span class="num cnt" style="font-family:var(--display);font-size:72px;font-weight:600;letter-spacing:-0.03em">0</span><span style="font-size:20px;color:var(--t2)">профилей · теги · cookies · прокси</span></div>`;
      },
      anim(u, root) {
        F.transform(F.$(root, '.pl'), `translateY(${f(-F.prog(u, -0.5, 2.0) * 300)}px)`);
        const gp = F.$$(root, '.gp');
        let shown = 0;
        gp.forEach((g, i) => {
          const at = 0.05 + i * 0.024;
          const k = F.seg(u, at, at + 0.3, E.entry);
          if (u > at + 0.15) shown++;
          F.opacity(g, k);
          F.transform(g, `scale(${f(0.4 + 0.6 * k)})`);
        });
        F.text(F.$(root, '.cnt'), String(Math.min(50, shown)));
        F.opacity(F.$(root, '.arrow'), 0.4 + 0.6 * F.seg(u, -0.2, 0.2));
      },
    },
    // 10. Record a scenario with the mouse, run it on a schedule
    {
      group: 'Удобство на Mac', a: 'Запишите сценарий мышкой.', b: 'Lumen повторит по расписанию.',
      sub: 'Просто кликайте в Safari — получится готовый сценарий. Например, прогрев профиля каждый день в 10:00.',
      html: () => `
        ${safariMini({ x: 40, y: 48, w: 600, h: 440, profile: UI.byId('shop3'), url: 'shop.example', page: shopPage({ email: true }) })}
        <div class="rec" style="position:absolute;left:530px;top:446px;display:flex;align-items:center;gap:8px;height:28px;padding:0 12px;border-radius:14px;background:#E5484D;color:#fff;font-size:13px;font-weight:600;z-index:5"><i style="width:8px;height:8px;border-radius:50%;background:#fff"></i>Запись</div>
        <div style="position:absolute;left:670px;top:48px;width:490px;height:440px;border-radius:18px;background:rgba(11,12,15,0.94);box-shadow:inset 0 0 0 1px var(--line2);overflow:hidden">
          <div style="height:48px;display:flex;align-items:center;gap:10px;padding:0 18px;border-bottom:1px solid var(--line);font-size:15px">${UI.icon('playRect', 16)}<span style="font-weight:600">Сценарий: прогрев магазина</span></div>
          <div class="code rc2" style="padding:18px 20px;font-size:15.5px;line-height:1.75">${[
            '<span class="k">await</span> page.<span class="f">goto</span>(<span class="s">\'https://shop.example\'</span>)',
            '<span class="k">await</span> page.<span class="f">click</span>(<span class="s">\'text=Войти\'</span>)',
            '<span class="k">await</span> page.<span class="f">type</span>(<span class="s">\'#email\'</span>, <span class="s">\'anna@…\'</span>)',
            '<span class="k">await</span> page.<span class="f">click</span>(<span class="s">\'text=Корзина\'</span>)',
          ].map((l) => `<div class="ln">${l}</div>`).join('')}</div>
          <div class="sch" style="position:absolute;left:18px;right:18px;bottom:18px;height:62px;border-radius:14px;background:var(--bg4);box-shadow:inset 0 0 0 1px var(--line3);display:flex;align-items:center;gap:12px;padding:0 16px;font-size:16px">${UI.icon('clock', 20)}<div><div style="font-weight:600">Каждый день в 10:00</div><div style="font-size:13px;color:var(--t3)">Магазин-3 · следующий запуск завтра</div></div></div></div>
        ${cursor()}`,
      anim(u, root) {
        const c = F.$(root, '.cur');
        moveCursor(c, u, [[-0.3, 420, 420], [0.25, 492, 130], [0.75, 395, 268], [1.3, 560, 130], [1.7, 556, 132]], [0.3, 0.8, 1.35]);
        F.opacity(c, F.seg(u, -0.35, -0.1));
        const lines = F.$$(root, '.rc2 .ln');
        const at = [-0.2, 0.35, 0.95, 1.4];
        lines.forEach((l, i) => { const k = F.seg(u, at[i], at[i] + 0.25, E.out); F.opacity(l, k); F.css(l, 'background', `rgba(47,107,239,${f(0.18 * F.window(u, at[i], at[i] + 0.8, 0.1, 0.4))})`); });
        const em = F.$(root, '.sp-email');
        const q = 'anna@shop.example';
        F.text(em, q.slice(0, Math.floor(F.prog(u, 0.85, 1.25) * q.length)));
        F.css(F.$(root, '.sp-login'), 'background', u > 0.3 && u < 0.6 ? 'rgba(47,107,239,0.15)' : 'transparent');
        F.css(F.$(root, '.sp-cart'), 'background', u > 1.35 && u < 1.7 ? 'rgba(47,107,239,0.15)' : 'transparent');
        const sch = F.$(root, '.sch');
        const sk = F.seg(u, 1.55, 1.95, E.entry);
        F.opacity(sch, sk);
        F.transform(sch, `translateY(${f((1 - sk) * 20)}px)`);
        F.opacity(F.$(root, '.rec'), 0.6 + 0.4 * Math.abs(Math.cos(u * 3)));
      },
    },
    // 11. One profile on the Mac and on the iPhone
    {
      group: 'Mac и iPhone', a: 'Один профиль —', b: 'на Mac и на iPhone.',
      sub: 'Профиль синхронизируется между устройствами — и мобильная личность настоящая, а не эмулированная.',
      html: () => {
        const row = (id, on) => { const p = UI.byId(id); return `<div style="display:flex;align-items:center;gap:10px;height:54px;padding:0 12px;border-bottom:1px solid var(--line)">${UI.avatar(p.letters, p.color, 32, on)}<div style="flex:1"><div style="font-size:14px;font-weight:600">${p.name}</div><div style="font-size:11.5px;color:var(--t3);display:flex;gap:5px;align-items:center">${UI.flag(p.cc, 11)}${p.country}</div></div>${on ? '<i class="rdot"></i>' : ''}</div>`; };
        const macRow = (id, on) => { const p = UI.byId(id); return `<div style="display:flex;align-items:center;gap:10px;height:40px;padding:0 10px;border-bottom:1px solid var(--line);font-size:12.5px">${UI.avatar(p.letters, p.color, 24, on)}<span style="flex:1;font-weight:500">${p.name}</span><span style="display:flex;gap:6px;align-items:center;width:130px">${UI.flag(p.cc, 12)}${p.country}</span><span style="width:90px;color:${on ? 'var(--t1)' : 'var(--t3)'}">${on ? 'Работает' : 'вчера'}</span></div>`; };
        return `<div style="position:absolute;left:70px;top:40px;width:680px">
            <div style="height:420px;border-radius:18px 18px 4px 4px;background:#0A0A0C;box-shadow:0 0 0 2px #2C2D32;padding:14px">
              <div style="position:relative;height:100%;border-radius:8px;overflow:hidden;background:var(--bg)">
                <div style="position:absolute;inset:0;background:${UI.eclipseBG(652, 392, 'profiles', 1, 1, 0.55)}"></div>
                <div style="position:absolute;left:20px;top:16px;font-family:var(--display);font-size:22px;font-weight:700">Профили</div>
                <div style="position:absolute;left:14px;right:14px;top:60px">${macRow('shop', true)}${macRow('north', true)}${macRow('shop3', false)}${macRow('travel', true)}${macRow('bank', false)}</div></div></div>
            <div style="height:26px;margin:0 -50px;border-radius:0 0 26px 26px;background:linear-gradient(180deg,#3A3B40,#1E1F23);box-shadow:0 20px 40px rgba(0,0,0,0.6)"></div></div>
          <div class="phone" style="position:absolute;left:880px;top:20px;width:250px;height:520px;border-radius:44px;background:#0A0A0C;box-shadow:0 0 0 3px #2C2D32,0 30px 60px rgba(0,0,0,0.6);padding:12px">
            <div style="position:relative;height:100%;border-radius:34px;overflow:hidden;background:var(--bg)">
              <div style="position:absolute;left:50%;top:10px;width:84px;height:24px;margin-left:-42px;border-radius:12px;background:#000"></div>
              <div style="position:absolute;left:16px;top:48px;font-family:var(--display);font-size:28px;font-weight:700">Сессии</div>
              <div style="position:absolute;left:4px;right:4px;top:96px">${row('shop', true)}${row('travel', true)}${row('north', false)}${row('shop3', false)}</div></div></div>
          <svg style="position:absolute;left:0;top:0" width="1200" height="580"><path class="sync" d="M760 230 C 800 150, 850 150, 880 210" fill="none" stroke="rgba(178,198,255,0.7)" stroke-width="2.5" stroke-dasharray="4 10" stroke-linecap="round"/></svg>
          <div class="synct" style="position:absolute;left:740px;top:110px;font-size:14px;color:#AFC2F5;display:flex;gap:6px;align-items:center">${UI.icon('syncArrows', 14)}Синхронизация</div>`;
      },
      anim(u, root) {
        F.css(F.$(root, '.sync'), 'stroke-dashoffset', f(-u * 40));
        const ph = F.$(root, '.phone');
        const k = F.seg(u, -0.4, 0.4, E.entry);
        F.transform(ph, `translateY(${f((1 - k) * 60)}px) rotate(${f((1 - k) * 6)}deg)`);
        F.opacity(F.$(root, '.synct'), F.seg(u, 0.2, 0.6));
      },
    },
  ];
  F.FEATURES = FEATURES;

  const T0 = 38.9, SLOT = 2.3, MOVE = 0.55;
  const center = (i) => T0 + MOVE + i * SLOT;

  // every move of the carousel is fast: blur it
  F.fastRange(T0, center(0), 4);
  for (let i = 0; i < FEATURES.length - 1; i++) F.fastRange(center(i) + SLOT - MOVE, center(i) + SLOT, 4);

  F.scene({
    id: 'carousel', t0: T0, t1: center(FEATURES.length - 1) + SLOT - MOVE + 0.35, z: 12,
    build(el) {
      el.innerHTML = `<div class="fill" data-k="glow" style="background:radial-gradient(ellipse 1100px 600px at 50% 70%, rgba(111,143,234,0.08), rgba(0,0,0,0) 70%)"></div>
        <div class="fill" style="perspective:2400px;perspective-origin:50% 60%"><div class="fill p3d" data-k="rig"></div></div>`;
      this.k = {};
      F.$$(el, '[data-k]').forEach((e) => (this.k[e.dataset.k] = e));
      this.cards = FEATURES.map((ft, i) => {
        const c = F.el('div', 'abs');
        c.style.left = (960 - CW / 2) + 'px';
        c.style.top = (650 - CH / 2) + 'px';
        c.style.width = CW + 'px';
        c.style.height = CH + 'px';
        c.innerHTML = `<div class="panel" style="position:absolute;inset:0;border-radius:30px;background:#0A0B0E">
            <div style="position:absolute;inset:0;background:${UI.eclipseBG(CW, CH, 'profiles', 1, 1, 0.42, '10,11,14')}"></div>
            <div class="inner" style="position:absolute;inset:0">${ft.html()}</div></div>`;
        this.k.rig.appendChild(c);
        const head = F.el('div', 'abs');
        head.style.left = '0'; head.style.right = '0'; head.style.top = '92px'; head.style.textAlign = 'center';
        head.innerHTML = `<div class="caps" style="color:#AFC2F5">${ft.group}</div>
          <div class="title t-m" style="margin-top:16px"><span class="ta">${ft.a}</span> <span class="tb grey">${ft.b}</span></div>
          <div class="sub s" style="margin:16px auto 0;max-width:1180px;white-space:normal">${ft.sub}</div>`;
        el.appendChild(head);
        const ta = F.$(head, '.ta'), tb = F.$(head, '.tb'), sb = F.$(head, '.sub'), cp = F.$(head, '.caps');
        F.words(ta); F.words(tb); F.words(sb); F.words(cp);
        return { c, head, ta, tb, sb, cp, inner: F.$(c, '.inner'), ft };
      });
    },
    update(lt, t, el) {
      const n = FEATURES.length;
      // where the carousel is: a float index that rests on each card and moves between them
      let p = -1 + F.seg(t, T0, center(0), E.smooth);
      for (let i = 0; i < n - 1; i++) {
        const a = center(i) + SLOT - MOVE;
        if (t >= a) p = i + F.seg(t, a, a + MOVE, E.smooth);
      }
      const endOut = F.seg(t, center(n - 1) + SLOT - MOVE - 0.2, center(n - 1) + SLOT - MOVE + 0.35, E.in);
      F.opacity(el, F.seg(t, T0, T0 + 0.3) * (1 - endOut));
      this.cards.forEach((cd, i) => {
        const d = i - p, ad = Math.abs(d);
        const vis = ad < 1.7;
        F.show(cd.c, vis);
        if (vis) {
          const x = d * 1310, z = -ad * 320, ry = -d * 26;
          F.transform(cd.c, `translate3d(${f(x)}px, 0, ${f(z)}px) rotateY(${f(ry)}deg)`);
          F.opacity(cd.c, 1 - 0.55 * Math.min(1, ad));
          F.blur(cd.c, Math.min(1, ad) * 5);
        }
        // the card's own small film runs from a little before it arrives to when it leaves
        const u = t - center(i);
        if (u > -0.7 && u < SLOT) cd.ft.anim(u, cd.inner);
        // its words: in as it arrives, out as it leaves
        const tin = center(i) - 0.32;
        const tout = center(i) + SLOT - MOVE - 0.05;
        const on = t > tin - 0.1 && t < tout + 0.45;
        F.show(cd.head, on);
        if (on) {
          F.reveal(cd.cp, t, tin - 0.05, { stagger: 0.02, dur: 0.6, blur: 6 });
          F.reveal(cd.ta, t, tin, { stagger: 0.06, dur: 0.75 });
          F.reveal(cd.tb, t, tin + 0.12, { stagger: 0.06, dur: 0.75 });
          F.reveal(cd.sb, t, tin + 0.3, { stagger: 0.012, dur: 0.6, blur: 6, rise: 0.3 });
          const o = F.seg(t, tout, tout + 0.4, E.in);
          F.opacity(cd.head, 1 - o);
          F.blur(cd.head, o * 10);
        }
      });
    },
  });
})();
