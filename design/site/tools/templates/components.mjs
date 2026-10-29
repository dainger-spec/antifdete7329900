// Pieces several pages share: section heads, cards, the drawn app (profile rows, status glyphs),
// the hero demonstration, evidence rows and small UI parts.
import { icon, flag, avatarPalette, sampleAvatarIndex } from '../lib/kit.mjs';
import { esc, inline } from '../lib/html.mjs';

export const I = icon;

export function sectionHead({ eyebrow, title, lead, center = false, level = 2, id }, lang) {
  return `<div class="section-head${center ? ' center' : ''}">` +
    (eyebrow ? `<p class="eyebrow">${inline(eyebrow, lang)}</p>` : '') +
    `<h${level} class="h2"${id ? ` id="${id}"` : ''}>${inline(title, lang)}</h${level}>` +
    (lead ? `<p class="lead">${inline(lead, lang)}</p>` : '') + `</div>`;
}

export function linkArrow(href, text, lang) {
  return `<a class="link-arrow" href="${href}">${inline(text, lang)}${icon('arrowRight', 14)}</a>`;
}

export function btn(href, text, kind = 'secondary', { size = '', iconName = '', lang } = {}) {
  return `<a class="btn ${kind}${size ? ' ' + size : ''}" href="${href}">${iconName ? icon(iconName, size === 'lg' ? 17 : 16) : ''}${inline(text, lang)}</a>`;
}

export function featureCard({ icon: ic, title, text, href }, lang, { more } = {}) {
  const inner = `<span class="tile-icon">${icon(ic, 18)}</span><h3 class="h4">${inline(title, lang)}</h3><p>${inline(text, lang)}</p>`;
  return href
    ? `<a class="card card-link feature-card reveal" href="${href}">${inner}${more ? `<p class="more link-arrow">${inline(more, lang)}${icon('arrowRight', 14)}</p>` : ''}</a>`
    : `<div class="card feature-card reveal">${inner}</div>`;
}

export function checkList(items, lang, { accent = false, glyph = 'check' } = {}) {
  return `<ul class="list-check${accent ? ' accent' : ''}">${items.map((t) => `<li>${icon(glyph, 16)}<span>${inline(t, lang)}</span></li>`).join('')}</ul>`;
}

export function note(text, lang, kind = '', ic = 'infoCircle') {
  return `<div class="note ${kind}">${icon(ic, 18)}<div><p>${inline(text, lang)}</p></div></div>`;
}

/// A result with its own shape per state (never colour alone): same ✓, diff ≠, na ?, fail ✕.
export function result(kind, label, lang) {
  const g = { same: icon('check', 12), diff: icon('notEqual', 12), na: icon('question', 12), fail: icon('xmark', 12) }[kind];
  return `<span class="res ${kind}"><span class="g">${g}</span>${inline(label, lang)}</span>`;
}

// MARK: The app, drawn

/// ProfileAvatar for the sample profiles of UISnapshots.sampleRows (n = their order there).
export function avatar(name, n, size = 20) {
  const p = avatarPalette[sampleAvatarIndex(n) % avatarPalette.length];
  return `<span class="avatar" style="width:${size}px;height:${size}px;border-radius:${(size * 0.22).toFixed(2)}px;background:${p.fill};color:${p.text};font-size:${(size * 0.43).toFixed(2)}px" aria-hidden="true">${esc(name[0])}</span>`;
}

/// The status column: ● running, ○ stopped, a spinner while starting, a progress ring while warming up.
export function status(kind, label, tail = '', fraction = 0) {
  let glyph;
  if (kind === 'running') glyph = '<i class="dot"></i>';
  else if (kind === 'starting') glyph = '<i class="spin"></i>';
  else if (kind === 'warmup') glyph = ring(fraction);
  else glyph = '<i class="ring"></i>';
  return `<span class="status s-${kind}"><span class="glyph">${glyph}</span><span class="label">${esc(label)}</span>${tail ? `<span class="tail">${tail}</span>` : ''}</span>`;
}

export function ring(fraction, size = 12) {
  const r = size / 2 - 1.25, c = 2 * Math.PI * r;
  const done = Math.max(0.04, Math.min(1, fraction)) * c;
  return `<svg class="pring" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" aria-hidden="true">` +
    `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="rgba(111,143,234,0.25)" stroke-width="2.5"/>` +
    `<circle class="pring-done" cx="${size / 2}" cy="${size / 2}" r="${r.toFixed(3)}" fill="none" stroke="#6F8FEA" stroke-width="2.5" stroke-dasharray="${done.toFixed(2)} ${c.toFixed(2)}" transform="rotate(-90 ${size / 2} ${size / 2})" data-circ="${c.toFixed(3)}"/></svg>`;
}

export function exitLabel(kind, label, code) {
  if (kind === 'direct') return `<span class="exit">${icon('arrowRight', 12)}<span>${esc(label)}</span></span>`;
  return `<span class="exit">${flag(code, 14)}<span>${esc(label)}</span></span>`;
}

// MARK: The hero demonstration

/// The app's Profiles list (three of UISnapshots' sample rows) next to a diagram of the selected
/// profile's network; site.js replays the launch and the warm-up. Without JavaScript, and with
/// Reduce Motion, the final state shows: the state of UISnapshots' Northwind row.
export function heroDemo(d, lang) {
  const t = (s) => esc(s);
  const sites = ['google.de', 'spiegel.de', 'zeit.de', 'idealo.de', 'otto.de', 'chefkoch.de'];
  const total = 12, visited = 4, cookies = 84;
  const pageText = d.warm.page.replace('{n}', `<span data-demo="page">${visited}</span>`).replace('{total}', String(total));
  const tail = ` · cookies: <span data-demo="tailcookies">${cookies}</span>`;
  return `<div class="demo" data-demo-root data-labels="${esc(JSON.stringify(d.status))}" aria-label="${t(d.label)}" role="group">
  <div class="demo-stage">
    <div class="appwin" aria-hidden="true">
      <div class="titlebar"><span class="traffic"><i></i><i></i><i></i></span><span class="wtitle">${t(d.window)}</span></div>
      <div class="cols colhead"><span>${t(d.cols[0])}</span><span>${t(d.cols[1])}</span><span class="c-exit">${t(d.cols[2])}</span><span></span></div>
      <div class="rows">
        <div class="cols prow selected" data-demo="row">
          <span class="name">${avatar('Northwind', 2)}<span>${t(d.rows.northwind.name)}</span></span>
          <span data-demo="status">${status('warmup', `${d.status.warmup} ${visited}/${total}`, tail, visited / total)}</span>
          <span class="c-exit">${exitLabel('proxy', d.rows.northwind.exit, 'DE')}</span>
          <span class="act"><span class="press" data-demo="press">${icon('stopFill', 12)}</span></span>
        </div>
        <div class="cols prow">
          <span class="name">${avatar('Research', 4)}<span>${t(d.rows.research.name)}</span></span>
          <span>${status('stopped', d.status.stopped)}</span>
          <span class="c-exit">${exitLabel('proxy', d.rows.research.exit, 'NL')}</span>
          <span class="act"><span class="press">${icon('playFill', 12)}</span></span>
        </div>
        <div class="cols prow">
          <span class="name">${avatar('Personal', 1)}<span>${t(d.rows.personal.name)}</span></span>
          <span>${status('running', d.status.running)}</span>
          <span class="c-exit">${exitLabel('direct', d.rows.personal.exit)}</span>
          <span class="act"><span class="press">${icon('stopFill', 12)}</span></span>
        </div>
        <div class="cols prow">
          <span class="name">${avatar('Shopping', 6)}<span>${t(d.rows.shopping.name)}</span><span style="color:var(--text-tertiary);display:inline-flex">${icon('hourglass', 12)}</span></span>
          <span>${status('stopped', d.status.stopped)}</span>
          <span class="c-exit">${exitLabel('direct', d.rows.shopping.exit)}</span>
          <span class="act"><span class="press">${icon('playFill', 12)}</span></span>
        </div>
        <div class="cols prow">
          <span class="name">${avatar('Banking', 7)}<span>${t(d.rows.banking.name)}</span></span>
          <span>${status('stopped', d.status.stopped)}</span>
          <span class="c-exit"><span class="exit">${icon('globe', 13)}<span class="mono" style="font-size:12px">10.20.0.2:3128</span></span></span>
          <span class="act"><span class="press">${icon('playFill', 12)}</span></span>
        </div>
      </div>
    </div>
    <div class="diagram netpath">
      <div class="dtitle"><span>${t(d.net.title)}</span><span class="tag accent" data-at="live">${icon('shieldCheck', 12)}${t(d.net.live)}</span></div>
      <div class="path">
        <div class="node on" data-at="process"><div class="nk">${t(d.net.process)}</div><div class="nv">${icon('cpu', 14)}Northwind</div><div class="ns">${t(d.net.processSub)}</div></div>
        <div class="link" data-at="link1"><i></i><b></b></div>
        <div class="node on" data-at="proxy"><div class="nk">${t(d.net.proxy)}</div><div class="nv">${icon('network', 14)}SOCKS5</div><div class="ns mono">${t(d.net.proxyHost)}</div></div>
        <div class="link" data-at="link2"><i></i><b></b></div>
        <div class="node on" data-at="sites"><div class="nk">${t(d.net.sites)}</div><div class="nv">${flag('DE', 14)}${t(d.net.country)}</div><div class="ns">${t(d.net.sitesSub)}</div></div>
      </div>
      <div class="direct" data-at="direct"><span class="stub"></span><span></span><div class="node closed">${icon('lock', 13)}<span>${t(d.net.direct)} — ${t(d.net.closed)}</span></div></div>
      <div class="ident">
        <span class="chip" data-at="tz"><span class="k">${t(d.net.tz)}</span>Europe/Berlin</span>
        <span class="chip" data-at="lang"><span class="k">${t(d.net.lang)}</span>de-DE</span>
        <span class="chip" data-at="appears"><span class="k">${t(d.net.appears)}</span>${t(d.net.appearsValue)}</span>
      </div>
      <div class="warm" data-at="warm">
        <div><div class="wk">${t(d.warm.title)}</div><div class="wv">${icon('flame', 14)}<span>${pageText}</span></div></div>
        <div class="count"><div class="n" data-demo="cookies">${cookies}</div><div class="u">${t(d.warm.unit)}</div></div>
        <div class="bar"><i data-demo="bar" style="width:${(visited / total * 100).toFixed(1)}%"></i></div>
        <div class="sites">${sites.map((s, k) => `<span class="site ${k < visited ? 'done' : 'todo'}${k === visited - 1 ? ' now' : ''}" data-site="${k}">${icon(k < visited ? 'check' : 'minus', 10)}${s}</span>`).join('')}</div>
        <div class="ghost-window" style="grid-column:1/-1">${icon('eyeSlash', 13)}${t(d.warm.hidden)}</div>
      </div>
    </div>
  </div>
  <div class="demo-caption"><span>${inline(d.caption, lang)}</span><button class="btn ghost sm" type="button" data-demo="replay">${icon('refresh', 14)}${t(d.replay)}</button></div>
</div>`;
}

/// The warm-up sheet as the app draws it (strings from Localizable.strings), static.
export function warmupSheet(s, lang) {
  const seg = (items, on) => `<div class="seg full" aria-hidden="true">${items.map((x, i) => `<a${i === on ? ' aria-current="true"' : ''}>${esc(x)}</a>`).join('')}</div>`;
  return `<div class="appwin sheet" aria-hidden="true" style="background:var(--raised)">
  <div class="titlebar" style="background:var(--raised)"><span class="wtitle">${esc(s.title)}</span></div>
  <div style="padding:18px 18px 6px;display:grid;gap:14px">
    ${seg(s.sources, 1)}
    <div class="row" style="gap:8px;font:500 13px/18px var(--font)">${flag(s.flag || 'SE', 14)}${esc(s.country)}</div>
    <p style="font:400 12px/17px var(--font);color:var(--text-tertiary);margin-top:-6px">${esc(s.explain)}</p>
    <div style="display:grid;gap:8px"><div style="font:500 12px/16px var(--font);color:var(--text-secondary)">${esc(s.quality)}</div>${seg(s.qualities, 1)}<div style="font:400 12px/16px var(--font);color:var(--text-tertiary)">${esc(s.qualityDetail)}</div></div>
    <label class="check" style="font-size:13px"><input type="checkbox" checked tabindex="-1"><span>${esc(s.schedule)}</span></label>
  </div>
  <div style="margin:10px 18px 0;padding:14px 0;border-top:1px solid var(--hairline);display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px 16px;align-items:center">
    <div><div style="display:flex;align-items:center;gap:8px;font:500 13px/18px var(--font)">${ring(4 / 12, 14)}${esc(s.progress)}</div><div class="meter" style="margin-top:10px;height:3px"><i style="width:33.3%"></i></div></div>
    <div style="text-align:right"><div style="font:600 24px/28px var(--font-display);font-variant-numeric:tabular-nums">84</div><div style="font:400 11px/14px var(--font);color:var(--text-tertiary)">${esc(s.cookies)}</div></div>
  </div>
  <div style="display:flex;align-items:center;justify-content:space-between;gap:12px;padding:12px 18px 16px;border-top:1px solid var(--hairline)">
    <span style="display:flex;gap:6px;align-items:center;font:400 12px/16px var(--font);color:var(--text-tertiary)">${icon('eyeSlash', 13)}${esc(s.invisible)}</span>
    <span class="btn sm secondary" style="height:28px">${esc(s.stop)}</span>
  </div>
</div>`;
}

/// A stat tile: big number (optionally "of N"), what it counts, where it comes from.
export function stat({ n, of, t, s }, lang) {
  return `<div class="stat"><div class="n">${esc(n)}${of ? `<small>/${esc(of)}</small>` : ''}</div><div class="t">${inline(t, lang)}</div>${s ? `<div class="s">${inline(s, lang)}</div>` : ''}</div>`;
}
