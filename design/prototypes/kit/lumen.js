// Small runtime shared by the prototypes: the app's drawn pieces as HTML, URL options, and the
// viewer frame around a prototype window (language, scenario, Reduce Motion, new-string markers).
(function (L) {
  'use strict';

  const params = new URLSearchParams(location.search);
  L.params = params;
  /// ?frame=0: only the window, at the top-left (what the PNG renders use).
  L.frameless = params.get('frame') === '0';
  L.reduceMotion = params.get('rm') === '1' || matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (L.reduceMotion) document.documentElement.classList.add('reduce-motion');
  document.documentElement.lang = L.lang;

  // MARK: Drawn pieces

  function avatar(name, paletteIndex, size = 20) {
    const p = L.avatar.PALETTE[paletteIndex % L.avatar.PALETTE.length];
    const initial = (name.trim()[0] || '·').toUpperCase();
    const radius = (size * 0.22).toFixed(2);
    return `<span class="avatar" style="width:${size}px;height:${size}px;border-radius:${radius}px;background:${p.fill};color:${p.text};font-size:${(size * 0.43).toFixed(2)}px" aria-hidden="true">${L.escapeHTML(initial)}</span>`;
  }

  function lockup(kind = 'sidebar', color = 'var(--textPrimary)') {
    const spec = kind === 'large' ? { mark: 36, word: 22, gap: 14 } : { mark: 20, word: 11.2, gap: 8 };
    return `<span class="lockup" style="display:inline-flex;align-items:center;gap:${spec.gap}px;color:${color}" role="img" aria-label="Lumen">` +
      L.geometry.markSVG(spec.mark) + L.geometry.wordmarkSVG(spec.word, 'currentColor') + '</span>';
  }

  /// A determinate ring: `fraction` of a 12 pt circle drawn in the accent (warm-up progress).
  function progressRing(fraction, size = 12, color = 'var(--accent)') {
    const r = size / 2 - 1.25, c = 2 * Math.PI * r;
    const done = Math.max(0.04, Math.min(1, fraction)) * c;
    return `<svg class="progress-ring" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" aria-hidden="true">` +
      `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="rgba(111,143,234,0.25)" stroke-width="2.5"/>` +
      `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${color}" stroke-width="2.5" stroke-dasharray="${done.toFixed(2)} ${c.toFixed(2)}" transform="rotate(-90 ${size / 2} ${size / 2})" style="transition:stroke-dasharray 200ms linear"/></svg>`;
  }

  /// Status glyph + label (PROPOSED): every state has its own shape, so none is told by colour alone.
  function status(kind, label = '', extra = '') {
    let glyph;
    switch (kind) {
      case 'running': glyph = '<i class="dot"></i>'; break;
      case 'starting': glyph = '<i class="spinner"></i>'; break;
      case 'warmup': glyph = progressRing(extra.fraction || 0); break;
      case 'sealing': glyph = `<span style="color:var(--textSecondary)">${L.icon('lockFill', 11)}</span>`; break;
      case 'failed': glyph = `<span style="color:var(--warning)">${L.icon('exclamationTriangleFill', 12)}</span>`; break;
      default: glyph = '<i class="ring"></i>';
    }
    const tail = extra.tail ? `<span class="tail">${extra.tail}</span>` : '';
    return `<span class="status s-${kind}"><span class="glyph">${glyph}</span><span class="label">${label}${tail}</span></span>`;
  }

  // MARK: Viewer frame

  /// Builds the page: in frameless mode only the window; otherwise the window centred under a strip
  /// of options. `scenarios`: [{id, title}]; the current one comes from ?state=.
  function shell({ title, width, height, scenarios = [], note = '' }) {
    const root = document.getElementById('app');
    const win = document.createElement('div');
    win.className = 'window';
    win.style.width = width + 'px';
    win.style.height = height + 'px';
    if (L.frameless) {
      document.body.style.background = 'var(--surface)';
      root.appendChild(win);
      return win;
    }
    const state = params.get('state') || (scenarios[0] && scenarios[0].id) || '';
    const link = (changes) => {
      const p = new URLSearchParams(location.search);
      for (const [k, v] of Object.entries(changes)) { if (v === null) p.delete(k); else p.set(k, v); }
      return '?' + p.toString();
    };
    const bar = document.createElement('div');
    bar.className = 'viewer-bar';
    bar.innerHTML = `
      <strong>${L.escapeHTML(title)}</strong>
      <span class="viewer-group">${['ru', 'en'].map((l) => `<a href="${link({ lang: l })}" class="${L.lang === l ? 'on' : ''}">${l.toUpperCase()}</a>`).join('')}</span>
      ${scenarios.length ? `<span class="viewer-group">${scenarios.map((s) => `<a href="${link({ state: s.id })}" class="${state === s.id ? 'on' : ''}">${L.escapeHTML(s.title)}</a>`).join('')}</span>` : ''}
      <span class="viewer-group">
        <a href="${link({ rm: L.reduceMotion ? null : '1' })}" class="${L.reduceMotion ? 'on' : ''}">Reduce Motion</a>
        <a href="${link({ marknew: L.params.get('marknew') === '1' ? null : '1' })}" class="${L.params.get('marknew') === '1' ? 'on' : ''}">${L.lang === 'en' ? 'Mark new strings' : 'Новые строки'}</a>
      </span>
      ${note ? `<span class="viewer-note">${note}</span>` : ''}`;
    const stage = document.createElement('div');
    stage.className = 'viewer-stage';
    stage.appendChild(win);
    root.append(bar, stage);
    return win;
  }

  const viewerCSS = `
    .viewer-bar { position: sticky; top: 0; z-index: 50; display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: center;
      padding: 10px 16px; background: #0B0C0F; border-bottom: 1px solid rgba(255,255,255,.08); font: 12px/16px var(--font); color: #A2A9B6; }
    .viewer-bar strong { color: #ECEEF2; font-weight: 600; }
    .viewer-group { display: inline-flex; gap: 2px; padding: 2px; border-radius: 7px; background: rgba(255,255,255,.05); }
    .viewer-group a { color: #A2A9B6; text-decoration: none; padding: 3px 8px; border-radius: 5px; }
    .viewer-group a.on { background: rgba(255,255,255,.14); color: #ECEEF2; }
    .viewer-note { color: #8A93A3; }
    .viewer-stage { padding: 24px; display: flex; justify-content: center; }
    .viewer-stage > .window { border-radius: 12px; box-shadow: 0 0 0 1px rgba(255,255,255,.10); }`;
  const style = document.createElement('style');
  style.textContent = viewerCSS;
  document.head.appendChild(style);

  L.avatarHTML = avatar;
  L.lockupHTML = lockup;
  L.progressRing = progressRing;
  L.statusHTML = status;
  L.shell = shell;
})(globalThis.Lumen = globalThis.Lumen || {});
