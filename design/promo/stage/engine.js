// The film's engine: time in seconds is the only input. Every scene draws itself from `t` alone (no CSS
// animations, no transitions, no timers), so any frame can be drawn on its own, in any order — the capture
// (tools/capture.mjs) asks for frames by time, and `index.html?t=12.3` shows one moment.
(function () {
  'use strict';
  const F = (window.Film = window.Film || {});
  F.W = 1920;
  F.H = 1080;
  F.FPS = 60;

  // MARK: Numbers

  F.clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  F.lerp = (a, b, k) => a + (b - a) * k;
  /// 0…1 as t goes from a to b (clamped).
  F.prog = (t, a, b) => (b === a ? (t >= b ? 1 : 0) : F.clamp((t - a) / (b - a)));
  F.mix = (a, b, k) => a.map((v, i) => F.lerp(v, b[i], k));

  /// CSS's cubic-bezier(x1, y1, x2, y2), solved for y at x.
  F.bezier = (x1, y1, x2, y2) => {
    const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
    const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
    const sx = (u) => ((ax * u + bx) * u + cx) * u;
    const sy = (u) => ((ay * u + by) * u + cy) * u;
    const dx = (u) => (3 * ax * u + 2 * bx) * u + cx;
    return (x) => {
      if (x <= 0) return 0;
      if (x >= 1) return 1;
      let u = x;
      for (let i = 0; i < 8; i++) {
        const e = sx(u) - x;
        if (Math.abs(e) < 1e-6) break;
        const d = dx(u);
        if (Math.abs(d) < 1e-6) break;
        u -= e / d;
      }
      let lo = 0, hi = 1;
      for (let i = 0; i < 30 && Math.abs(sx(u) - x) > 1e-6; i++) {
        if (sx(u) < x) lo = u; else hi = u;
        u = (lo + hi) / 2;
      }
      return sy(u);
    };
  };

  F.ease = {
    linear: (k) => k,
    /// The app's entry curve (Motion.entry): fast start, long soft landing.
    entry: F.bezier(0.16, 1, 0.3, 1),
    /// Theme.appearAnimation.
    appear: F.bezier(0.2, 0.8, 0.2, 1),
    out: F.bezier(0, 0, 0.58, 1),
    in: F.bezier(0.42, 0, 1, 1),
    inOut: F.bezier(0.42, 0, 0.58, 1),
    /// A camera move: slow out, slow in, no dead stop.
    camera: F.bezier(0.45, 0.05, 0.25, 1),
    smooth: F.bezier(0.65, 0, 0.35, 1),
    outCubic: (k) => 1 - Math.pow(1 - k, 3),
    inCubic: (k) => k * k * k,
    outQuint: (k) => 1 - Math.pow(1 - k, 5),
    inQuad: (k) => k * k,
    expoOut: (k) => (k >= 1 ? 1 : 1 - Math.pow(2, -10 * k)),
  };

  /// Eased progress from a to b.
  F.seg = (t, a, b, ease = F.ease.entry) => ease(F.prog(t, a, b));

  /// A value that eases in at a, out at b: 0 before, 1 after, a plateau between in and out.
  F.window = (t, a, b, inDur, outDur, easeIn = F.ease.entry, easeOut = F.ease.inOut) =>
    Math.min(F.seg(t, a, a + inDur, easeIn), 1 - F.seg(t, b - outDur, b, easeOut));

  /// A smooth path through keys [[t, v], …]: monotone cubic (Fritsch–Carlson), still at the first and
  /// last key only — the move never stops at a key between (the v4 film's lesson). Values may be arrays.
  F.path = (keys) => {
    const n = keys.length;
    const ts = keys.map((k) => k[0]);
    const dims = Array.isArray(keys[0][1]) ? keys[0][1].length : 0;
    const vals = keys.map((k) => (dims ? k[1] : [k[1]]));
    const D = dims || 1;
    const m = [];
    for (let d = 0; d < D; d++) {
      const s = [];
      for (let i = 0; i < n - 1; i++) s.push((vals[i + 1][d] - vals[i][d]) / (ts[i + 1] - ts[i]));
      const md = new Array(n).fill(0);
      for (let i = 1; i < n - 1; i++) {
        if (s[i - 1] * s[i] <= 0) md[i] = 0;
        else {
          const h0 = ts[i] - ts[i - 1], h1 = ts[i + 1] - ts[i];
          const w1 = 2 * h1 + h0, w2 = h1 + 2 * h0;
          md[i] = (w1 + w2) / (w1 / s[i - 1] + w2 / s[i]);
        }
      }
      md[0] = 0;
      md[n - 1] = 0;
      m.push(md);
    }
    return (t) => {
      if (t <= ts[0]) return dims ? vals[0].slice() : vals[0][0];
      if (t >= ts[n - 1]) return dims ? vals[n - 1].slice() : vals[n - 1][0];
      let i = 0;
      while (i < n - 2 && t > ts[i + 1]) i++;
      const h = ts[i + 1] - ts[i], u = (t - ts[i]) / h;
      const h00 = 2 * u * u * u - 3 * u * u + 1, h10 = u * u * u - 2 * u * u + u;
      const h01 = -2 * u * u * u + 3 * u * u, h11 = u * u * u - u * u;
      const out = [];
      for (let d = 0; d < D; d++) {
        out.push(h00 * vals[i][d] + h10 * h * m[d][i] + h01 * vals[i + 1][d] + h11 * h * m[d][i + 1]);
      }
      return dims ? out : out[0];
    };
  };

  /// A deterministic pseudo-random number in [0, 1) for an integer seed.
  F.rand = (seed) => {
    let h = (seed | 0) ^ 0x9e3779b9;
    h = Math.imul(h ^ (h >>> 16), 0x85ebca6b);
    h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35);
    h ^= h >>> 16;
    return (h >>> 0) / 4294967296;
  };

  // MARK: DOM

  F.el = (tag, cls, html) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    return e;
  };
  F.$ = (root, sel) => root.querySelector(sel);
  F.$$ = (root, sel) => Array.from(root.querySelectorAll(sel));

  /// Sets a style only when it changed (the capture draws thousands of frames).
  F.css = (e, prop, value) => {
    const key = '_s_' + prop;
    if (e[key] !== value) {
      e[key] = value;
      e.style.setProperty(prop, value);
    }
  };
  F.show = (e, on) => F.css(e, 'display', on ? '' : 'none');
  F.opacity = (e, o) => F.css(e, 'opacity', (Math.round(F.clamp(o) * 1000) / 1000).toString());
  F.blur = (e, px) => F.css(e, 'filter', px > 0.05 ? `blur(${px.toFixed(2)}px)` : 'none');
  F.transform = (e, s) => F.css(e, 'transform', s);
  F.text = (e, s) => {
    if (e._text !== s) {
      e._text = s;
      e.textContent = s;
    }
  };

  // MARK: Words that come in as Apple's titles do

  /// Wraps each word of `e` (text and inline children kept) in <span class="w">.
  F.words = (e) => {
    const walk = (node) => {
      for (const child of Array.from(node.childNodes)) {
        if (child.nodeType === 3) {
          const parts = child.textContent.split(/(\s+)/);
          const frag = document.createDocumentFragment();
          for (const p of parts) {
            if (!p) continue;
            if (/^\s+$/.test(p)) frag.appendChild(document.createTextNode(p));
            else {
              const s = document.createElement('span');
              s.className = 'w';
              s.textContent = p;
              frag.appendChild(s);
            }
          }
          node.replaceChild(frag, child);
        } else if (child.nodeType === 1 && !child.classList.contains('w') && !child.classList.contains('keep')) {
          walk(child);
        }
      }
    };
    walk(e);
    e._words = F.$$(e, '.w, .keep');
    return e._words;
  };

  /// Reveals the words of `e` from `start`: each rises a little out of a blur, one after the other.
  F.reveal = (e, t, start, o = {}) => {
    const words = e._words || F.words(e);
    const stagger = o.stagger ?? 0.075, dur = o.dur ?? 0.9, rise = o.rise ?? 0.32, blur = o.blur ?? 12;
    words.forEach((w, i) => {
      const k = F.seg(t, start + i * stagger, start + i * stagger + dur, F.ease.entry);
      const ko = F.seg(t, start + i * stagger, start + i * stagger + dur * 0.6, F.ease.out);
      F.opacity(w, ko);
      F.transform(w, `translateY(${((1 - k) * rise).toFixed(3)}em)`);
      F.blur(w, (1 - k) * blur);
    });
  };

  /// A block leaving: blur, fade and a slight push back.
  F.leave = (e, t, start, dur = 0.45, o = {}) => {
    const k = F.seg(t, start, start + dur, F.ease.in);
    F.opacity(e, 1 - k);
    F.blur(e, k * (o.blur ?? 10));
    if (o.transform !== false) F.transform(e, `translateY(${(-k * (o.rise ?? 0)).toFixed(2)}px) scale(${(1 - k * (o.shrink ?? 0.03)).toFixed(4)})`);
  };

  /// A number counting up, tabular: `format(v)` draws it.
  F.count = (from, to, k, digits = 0) => {
    const v = F.lerp(from, to, k);
    return digits ? v.toFixed(digits) : Math.round(v).toString();
  };

  // MARK: Scenes

  F.scenes = [];
  /// def = { id, t0, t1, build(el), update(lt, t, el) } — lt is the time since t0.
  F.scene = (def) => F.scenes.push(def);

  F.build = () => {
    const stage = document.getElementById('stage');
    F.stage = stage;
    F.scenes.sort((a, b) => (a.z ?? 0) - (b.z ?? 0));
    for (const s of F.scenes) {
      s.el = F.el('div', 'scene scene-' + s.id);
      s.el.style.display = 'none';
      s._on = false;
      stage.appendChild(s.el);
      s.build(s.el);
    }
  };

  F.render = (t) => {
    F.t = t;
    for (const s of F.scenes) {
      const on = t >= s.t0 && t < s.t1;
      if (on !== s._on) {
        s.el.style.display = on ? '' : 'none';
        s._on = on;
      }
      if (on) s.update(t - s.t0, t, s.el);
    }
    if (F.post) F.post(t);
  };

  F.duration = () => Math.max(...F.scenes.map((s) => s.t1));

  // MARK: Motion blur

  /// Moves fast enough to strobe at 60 fps declare themselves: [from, to, samples]. The capture takes that many
  /// moments inside each frame's half-open shutter (180°) and averages them, as a camera would.
  F.fast = [];
  F.fastRange = (a, b, samples) => F.fast.push([a, b, samples]);
  F.samples = (t) => F.fast.reduce((n, [a, b, s]) => (t >= a && t <= b ? Math.max(n, s) : n), 1);
})();
