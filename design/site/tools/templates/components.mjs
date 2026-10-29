// Pieces several pages share: buttons and links, check lists, notes, evidence rows, the drawn app
// (avatars, the progress ring, the Warm Up sheet), stat tiles.
import { icon, flag, avatarPalette, sampleAvatarIndex } from '../lib/kit.mjs';
import { esc, inline } from '../lib/html.mjs';

export const I = icon;

export function linkArrow(href, text, lang) {
  return `<a class="link-arrow" href="${href}">${inline(text, lang)}${icon('arrowRight', 14)}</a>`;
}

export function btn(href, text, kind = 'secondary', { size = '', iconName = '', lang } = {}) {
  return `<a class="btn ${kind}${size ? ' ' + size : ''}" href="${href}">${iconName ? icon(iconName, size === 'lg' ? 17 : 16) : ''}${inline(text, lang)}</a>`;
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

export function ring(fraction, size = 12) {
  const r = size / 2 - 1.25, c = 2 * Math.PI * r;
  const done = Math.max(0.04, Math.min(1, fraction)) * c;
  return `<svg class="pring" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" aria-hidden="true">` +
    `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="rgba(111,143,234,0.25)" stroke-width="2.5"/>` +
    `<circle class="pring-done" cx="${size / 2}" cy="${size / 2}" r="${r.toFixed(3)}" fill="none" stroke="#6F8FEA" stroke-width="2.5" stroke-dasharray="${done.toFixed(2)} ${c.toFixed(2)}" transform="rotate(-90 ${size / 2} ${size / 2})" data-circ="${c.toFixed(3)}"/></svg>`;
}

/// The app's Warm Up sheet, drawn (Features): where the sites come from, the proxy's country, how
/// thoroughly, the schedule, and a run in progress.
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
