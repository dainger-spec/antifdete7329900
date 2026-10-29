import { inline, esc, plain } from '../../lib/html.mjs';
import { icon, flag } from '../../lib/kit.mjs';
import { linkArrow, btn, checkList, note, result, stat, warmupSheet, avatar } from '../components.mjs';

export default async function features(c, { lang, copy }) {
  const ru = lang === 'ru';

  const hero = `<section class="page-hero">
  <div class="container">
    <p class="eyebrow">${inline(c.hero.eyebrow, lang)}</p>
    <h1 class="h1">${inline(c.hero.title, lang)}</h1>
    <p class="lead">${inline(c.hero.lead, lang)}</p>
  </div>
</section>`;

  const chipnav = `<nav class="chipnav" data-chipnav aria-label="${esc(c.navTitle)}"><div class="scroller">${c.nav.map(([id, t]) => `<a href="#${id}">${esc(t)}</a>`).join('')}</div></nav>`;
  const localnav = `<aside class="local-nav" data-localnav aria-label="${esc(c.navTitle)}"><h2>${esc(c.navTitle)}</h2><div class="track"><ol>${c.nav.map(([id, t]) => `<li><a href="#${id}">${esc(t)}</a></li>`).join('')}</ol><span class="indicator" style="opacity:0"></span></div></aside>`;

  const head = (b) => `<h2 class="h2">${inline(b.title, lang)}</h2><p class="lead">${inline(b.lead, lang)}</p>`;

  // 1. Safari
  const s = c.safari;
  const safari = `<section class="fblock" id="safari">${head(s)}
  <div class="fgrid single">
    <div class="measure">${checkList(s.points, lang, { accent: true })}</div>
    <div class="table-wrap reveal"><table class="table compact stack-mobile">
      <thead><tr>${s.table.head.map((h, i) => `<th${i === 2 ? ' style="color:var(--text-primary)"' : ''}>${inline(h, lang)}</th>`).join('')}</tr></thead>
      <tbody>${s.table.rows.map((r) => `<tr><td data-label="${esc(s.table.head[0])}">${inline(r[0], lang)}</td><td data-label="${esc(plain(s.table.head[1]))}">${inline(r[1], lang)}</td><td class="strong" data-label="${esc(plain(s.table.head[2]))}">${inline(r[2], lang)}</td></tr>`).join('')}</tbody>
    </table></div>
  </div>
</section>`;

  // 2. Process per profile
  const p = c.process;
  const tree = p.tree;
  const proc = (x, n) => `<div class="node" style="display:grid;grid-template-columns:minmax(0,1fr);gap:8px;padding:12px 14px">
      <div class="nv">${avatar(x.name, n, 18)}${esc(x.name)}<span class="tag" style="margin-left:auto;height:20px;font-size:11px">${icon('cpu', 11)}${ru ? 'процесс' : 'process'}</span></div>
      <div style="display:flex;flex-wrap:wrap;gap:6px">
        <span class="chip" style="height:24px"><span class="k">${esc(tree.k.lang)}</span>${esc(x.lang)}</span>
        <span class="chip" style="height:24px"><span class="k">${esc(tree.k.tz)}</span>${esc(x.tz)}</span>
        <span class="chip" style="height:24px"><span class="k">${esc(tree.k.exit)}</span>${x.code ? flag(x.code, 12) : icon('arrowRight', 11)}${esc(x.exit)}</span>
      </div></div>`;
  const process = `<section class="fblock" id="process">${head(p)}
  <div class="fgrid">
    <div>${checkList(p.points, lang, { accent: true })}</div>
    <figure class="diagram reveal" style="display:grid;gap:0">
      <div class="node on" style="display:flex;align-items:center;gap:10px"><span class="tile-icon neutral" style="margin:0;width:28px;height:28px">${icon('lockFill', 14)}</span><div><div class="nv">${inline(tree.manager, lang)}</div><div class="ns">${inline(tree.managerSub, lang)}</div></div></div>
      <div style="display:grid;grid-template-columns:18px minmax(0,1fr);">
        <div style="border-left:1.5px solid var(--strong-border);margin-left:14px;margin-bottom:34px"></div>
        <div style="display:grid;gap:10px;padding-top:12px">${tree.procs.map((x, i) => `<div style="position:relative">${proc(x, [2, 4, 1][i])}<span style="position:absolute;left:-4px;top:22px;width:4px;border-top:1.5px solid var(--strong-border)"></span></div>`).join('')}</div>
      </div>

    </figure>
  </div>
</section>`;

  // 3. Encryption
  const e = c.encryption;
  const keys = `<figure class="diagram reveal"><div class="dtitle">${inline(e.keys.title, lang)}</div><div class="keys">
    ${e.keys.levels.map((l, i) => `${i ? '<div class="arrow"></div>' : ''}<div class="kl"><span class="ki">${icon(l.icon, 13)}</span><div><div class="kt">${inline(l.t, lang)}</div><div class="kd">${inline(l.d, lang)}</div></div></div>`).join('')}
    <div class="arrow"></div>
    <div class="branch">${e.keys.files.map((f) => `<span class="chip">${icon('lock', 11)}${inline(f, lang)}</span>`).join('')}</div>
  </div></figure>`;
  const encryption = `<section class="fblock" id="encryption">${head(e)}
  <div class="fgrid">
    <div>${checkList(e.points, lang, { accent: true })}</div>
    <div>${keys}</div>
  </div>
</section>`;

  // 4. Proxy
  const x = c.proxy;
  const dm = x.demo;
  const failWin = `<div class="pdemo" data-pdemo>
    <input type="checkbox" id="pd-off" class="visually-hidden">
    <div class="pdemo-bar">
      <span class="pstate"><i></i><span class="when-on">${esc(dm.on)}</span><span class="when-off">${esc(dm.off)}</span></span>
      <label for="pd-off" class="btn secondary sm" role="button"><span class="when-on">${icon('xmark', 13)}${esc(dm.toggleOff)}</span><span class="when-off">${icon('refresh', 13)}${esc(dm.toggleOn)}</span></label>
    </div>
    <div class="swin front pwin" aria-live="polite">
      <div class="sbar"><span class="traffic color"><i></i><i></i><i></i></span><span class="snav">${icon('chevronLeft', 13)}${icon('chevronRight', 13)}</span><span class="surl">${icon('lock', 10)}example.com</span><span class="schip">${avatar(dm.profile, 3, 16)}<span>${esc(dm.profile)}</span>${flag('US', 13)}</span></div>
      <div class="pstage">
        <div class="ppage when-on-block"><div class="sk-row"><i class="sk w30"></i><i class="sk w15 r"></i></div><div class="sk-hero"></div><div class="sk-cards"><i></i><i></i><i></i></div><span class="pseen ok">${flag('US', 13)}${esc(dm.seesOn)}</span></div>
        <div class="ppage err when-off-block"><span class="perr-ic">${icon('shieldSlash', 30)}</span><strong>${esc(dm.error)}</strong><span class="pseen good">${icon('check', 13)}${esc(dm.seesOff)}</span></div>
      </div>
    </div>
  </div>`;
  const l = x.list;
  const plist = `<div class="table-wrap reveal"><table class="table compact stack-mobile">
    <thead><tr><th>${esc(l.head[0])}</th><th>${esc(l.head[2])}</th><th class="num">${esc(l.head[3])}</th></tr></thead>
    <tbody>${l.rows.map((r) => `<tr>
      <td data-label="${esc(l.head[0])}"><span style="display:block;color:var(--text-primary);font-weight:500">${esc(r.label || r.host)}</span><span class="sub">${esc(r.kind)}${r.label ? ` · <span class="mono">${esc(r.host)}</span>` : ''}</span></td>
      <td data-label="${esc(l.head[2])}">${r.dead ? result('fail', r.dead, lang) : `<span class="row" style="gap:7px;flex-wrap:nowrap">${flag(r.code, 14)}${esc(r.exit)}</span>`}</td>
      <td data-label="${esc(l.head[3])}" class="num">${r.ms ? esc(r.ms) : '—'}</td></tr>`).join('')}</tbody></table></div>`;
  const proxy = `<section class="fblock" id="proxy">${head(x)}
  <div class="fgrid">
    <div>${checkList(x.points, lang, { accent: true, glyph: 'shieldCheck' })}</div>
    ${failWin}
  </div>
  <div class="fgrid" style="margin-top:56px">
    <div><h3 class="h3">${inline(l.title, lang)}</h3><p class="muted" style="margin-top:10px">${inline(l.lead, lang)}</p>
      <ul class="list-check" style="margin-top:20px">${[l.check, l.diagnose, l.assign].map((t) => `<li>${icon('check', 16)}<span>${inline(t, lang)}</span></li>`).join('')}</ul></div>
    <figure style="margin:0">${plist}</figure>
  </div>
</section>`;

  // 5. Verification (teaser)
  const v = c.verification;
  const verification = `<section class="fblock" id="verification">${head(v)}
  <div class="stats c3 reveal" style="margin-top:40px">${v.stats.map((st) => stat(st, lang)).join('')}</div>
  <p style="margin-top:20px">${linkArrow('verification.html', v.link, lang)}</p>
</section>`;

  // 6. Noise
  const n = c.noise;
  const same = ru
    ? [['Canvas', 'тот же data URL, байт в байт'], ['WebGL', 'производитель, рендерер, расширения, параметры'], ['Шрифты', 'метрики текста'], ['Navigator и экран', 'все значения']]
    : [['Canvas', 'the same data URL, byte for byte'], ['WebGL', 'vendor, renderer, extensions, parameters'], ['Fonts', 'text metrics'], ['Navigator and screen', 'every value']];
  const noise = `<section class="fblock" id="noise">${head(n)}
  <div class="fgrid">
    <div class="stack-lg">${n.paras.map((t) => `<p class="muted">${inline(t, lang)}</p>`).join('')}</div>
    <div class="stack">
      <div class="table-wrap reveal"><div class="panel-head" style="border-bottom:1px solid var(--hairline)"><div><h3 style="font:600 15px/22px var(--font)">${ru ? 'Профиль против Safari на том же Mac' : 'A profile against Safari on the same Mac'}</h3><p>${ru ? 'Каждая сборка, страница-зонд' : 'Every build, the probe page'}</p></div></div>
        <table class="table compact"><tbody>${same.map(([k, d]) => `<tr><td class="strong">${esc(k)}<span class="sub">${esc(d)}</span></td><td class="num">${result('same', ru ? 'совпадает' : 'identical', lang)}</td></tr>`).join('')}</tbody></table></div>
    </div>
  </div>
</section>`;

  // 7. Warm-up
  const w = c.warmup;
  const warmup = `<section class="fblock" id="warmup">${head(w)}
  <div class="fgrid">
    <div>${checkList(w.points, lang, { accent: true, glyph: 'flame' })}</div>
    <div class="reveal" style="position:sticky;top:calc(var(--header-h) + 80px)">${warmupSheet(c.warmup.sheet, lang)}</div>
  </div>
</section>`;

  // 8. Data
  const d = c.data;
  const data = `<section class="fblock" id="data">${head(d)}
  <div class="grid c3" style="margin-top:40px">${d.items.map((it) => `<div class="card reveal"><span class="tile-icon">${icon(it.icon, 18)}</span><h3 class="h4">${inline(it.title, lang)}</h3><p>${inline(it.text, lang)}</p></div>`).join('')}</div>
</section>`;

  const ct = c.cta;
  const st = c.steps;
  const steps = `<section class="band"><div class="container">
    <h2 class="h2 big center-text">${inline(st.title, lang)}</h2>
    <ol class="steps3">${st.items.map((it) => `<li class="reveal"><h3>${inline(it.t, lang)}</h3><p>${inline(it.d, lang)}</p></li>`).join('')}</ol>
  </div></section>`;
  const faq = `<section class="section" id="faq"><div class="container medium">
    <h2 class="h2 big" style="margin-bottom:32px">${inline(c.faqTitle, lang)}</h2>
    <div class="faq">${c.faq.map((f, i) => `<details${i === 0 ? ' open' : ''}><summary>${inline(f.q, lang)}${icon('chevronDown', 16)}</summary><div class="answer"><p>${inline(f.a, lang)}</p></div></details>`).join('')}</div>
  </div></section>`;

  const cta = `<section class="cta-band"><div class="container"><div class="inner">
    <div><h2 class="h2">${inline(ct.title, lang)}</h2><p class="lead" style="margin-top:12px">${inline(ct.lead, lang)}</p></div>
    <div class="btn-row stretch">${btn('download.html', ct.primary, 'primary', { size: 'lg', iconName: 'download', lang })}${btn('pricing.html', ct.secondary, 'secondary', { size: 'lg', lang })}</div>
  </div></div></section>`;

  return {
    body: `${hero}\n${chipnav}\n<div class="container"><div class="with-nav" style="padding-top:56px;padding-bottom:40px">${localnav}<div class="fblocks">${[safari, process, encryption, proxy, verification, noise, warmup, data].join('\n')}</div></div></div>\n${steps}\n${faq}\n${cta}`,
    bodyClass: 'page-features',
  };
}
