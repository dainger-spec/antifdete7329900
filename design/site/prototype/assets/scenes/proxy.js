// Home scene "proxy" (tools/templates/pages/home/proxy.mjs): the camera. The window is laid out where it ends
// (under the headline); this script only moves and scales it, and lifts the line over it, with the scroll:
//   0    – 0.48  a held close-up on the window's top edge: the chip, the address field and the white page fill the
//                 screen (the page runs off the bottom) while the page loads, the proxy drops and the light goes out;
//   0.48 – 0.66  the camera draws back to the whole window under the headline (scale 1, no shift).
// The close-up is measured, not guessed: of the scales that let the page run off the bottom, it takes the least
// one (and the least sideways shift) at which nothing is cut to a sliver — the traffic lights wholly in or wholly
// out, every small control wholly in or out, the chip, the address and the place where the bar stops wholly in,
// the page's form whole; only the long address field may run off a side. It also says when Safari's error may
// come up: at 0.49, or later if close up it would not fit the screen (--px-err).
// Everything else (the bar, the light, the error, the captions) is CSS on --t and --p. Nothing moves by itself:
// the transforms are set on scroll frames only, and only when they change.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  if (!api.scenesOn) return;
  const el = document.querySelector('.sc-proxy');
  if (!el) return;
  const pin = el.querySelector('.scene-pin');
  const top = el.querySelector('.px-top');
  const cam = el.querySelector('.px-cam');
  const PULL = [0.48, 0.66];
  let L = null, lastP = 0, lastCam = '', lastTop = '';

  const pullAt = (p) => api.easeInOut(api.clamp01((p - PULL[0]) / (PULL[1] - PULL[0])));

  function measure() {
    cam.style.transform = ''; top.style.transform = ''; lastCam = lastTop = '';
    const vw = document.documentElement.clientWidth, vh = window.innerHeight;
    const header = document.querySelector('.site-header');
    const hh = header ? header.offsetHeight : 64;
    const W = cam.offsetWidth, H = cam.offsetHeight;
    if (!W || !H) return null;
    const pr = pin.getBoundingClientRect(), cr = cam.getBoundingClientRect();
    const camTop = cr.top - pr.top, camLeft = cr.left - pr.left;
    const st = Array.from(top.querySelectorAll('.px-status')).map((n) => n.getBoundingClientRect());
    const sTop = Math.min(...st.map((r) => r.top)) - pr.top, sH = Math.max(...st.map((r) => r.height));
    const phone = vw < 600;
    const gapA = phone ? 22 : 40, gapB = phone ? 22 : 34;
    const yTop0 = hh + gapA + sH + gapB;                 // the window's top edge in the close-up, at its highest
    const yTopMax = hh + (vh - hh) * 0.34;               // … and at its lowest
    // The parts that must not be cut badly, in the window's own (unscaled) coordinates.
    const span = (sel) => Array.from(cam.querySelectorAll(sel)).filter((n) => n.offsetWidth).map((n) => {
      const r = n.getBoundingClientRect(); return [r.left - cr.left, r.right - cr.left];
    });
    const lights = span('.pxw-lights')[0];
    const caps = span('.pxw-side, .pxw-hist, .pxw-tools, .pxw-rl, .pxs-ico');
    const whole = span('.pxw-prof, .pxw-url, .pxs-form, .pxs-logo');
    const addr = span('.pxw-addr')[0];
    const stop = parseFloat(getComputedStyle(el).getPropertyValue('--px-stop')) || 0.62;   // where the bar stops (proxy.css)
    const stopX = addr ? addr[0] + (addr[1] - addr[0]) * stop : W / 2;

    // Is this framing clean? x0 = the window's left edge on screen, s = scale.
    const ok = (s, x0) => {
      const X = (x) => x0 + s * x;
      if (lights && !(X(lights[1]) <= -2 || X(lights[0]) >= 24)) return false;
      for (const [a, b] of whole) if (X(a) < 20 || X(b) > vw - 20) return false;
      if (X(stopX) > vw - 40) return false;
      for (const [a, b] of caps) {                                          // small: wholly out, or wholly in
        const A = X(a), B = X(b);
        if (!(B <= 0 || A >= vw || (A >= 14 && B <= vw - 14))) return false;
      }
      if (addr) {                                                           // long: may run off one side
        const A = X(addr[0]), B = X(addr[1]), w = B - A;
        const inside = A >= 14 && B <= vw - 14;
        const offLeft = A < 0 && B <= vw - 14 && B >= 0.55 * w, offRight = B > vw && A >= 14 && vw - A >= 0.55 * w;
        if (!inside && !offLeft && !offRight) return false;
      }
      return true;
    };
    // The least sideways shift that frames scale s cleanly, or undefined.
    const shift = (s) => {
      const centred = (vw - s * W) / 2;
      for (let d = 0; d <= vw * 0.22; d += 1) { const x0 = [centred - d, centred + d].find((x) => ok(s, x)); if (x0 !== undefined) return { x0, d }; }
      return undefined;
    };
    // The page should run off the bottom: the least clean scale that does it (cost: scale, then shift).
    const bleed = (y) => (vh + 60 - y) / H, min = phone ? 1.5 : 1.7, hi = phone ? 2.1 : 3.6;
    const lo = Math.max(min, bleed(yTop0));
    let best = null;
    for (let s = lo; s <= hi + 1e-9 && !(best && s * 400 >= best.cost); s += 0.005) {
      const f = shift(s);
      if (f && !(best && s * 400 + f.d >= best.cost)) best = { s, x0: f.x0, yTop: yTop0, cost: s * 400 + f.d };
    }
    // None is clean (a short or narrow screen, a short line): the window may sit lower, which lets a smaller
    // scale run it off the bottom — as little lower as will do.
    for (let s = lo - 0.005; !best && s >= Math.max(min, bleed(yTopMax)); s -= 0.005) {
      const f = shift(s);
      if (f) best = { s, x0: f.x0, yTop: vh + 60 - s * H };
    }
    // Still none: rather show the whole window, its foot clear of the bottom by a deliberate margin, than cut the
    // chip or the address — the largest clean scale that does it.
    for (let s = Math.min(lo, (vh - 48 - yTop0) / H); !best && s >= 1.2; s -= 0.005) {
      const f = shift(s);
      if (f) best = { s, x0: f.x0, yTop: yTop0 };
    }
    if (!best) best = { s: lo, x0: (vw - lo * W) / 2, yTop: yTop0 };
    // The line sits in the middle of the dark band between the header and the window.
    const lift = hh + (best.yTop - hh - sH) / 2 - sTop;
    const M = { s0: best.s, tx0: best.x0 - camLeft, ty0: best.yTop - camTop, lift };
    // Safari's error comes up at 0.49 — or later, as the camera draws back, if close up it would not fit.
    const errW = Math.max(...Array.from(cam.querySelectorAll('.pxw-err > *')).map((n) => n.offsetWidth));
    let errAt = 0.49;
    while (errAt < PULL[1] && (M.s0 + (1 - M.s0) * pullAt(errAt)) * errW > vw - 48) errAt += 0.005;
    el.style.setProperty('--px-err', errAt.toFixed(3));
    return M;
  }

  function frame(p) {
    if (!L) L = measure();
    if (!L) return;
    const a = pullAt(p), k = 1 - a, s = L.s0 + (1 - L.s0) * a;
    const c = `translate(${(L.tx0 * k).toFixed(2)}px, ${(L.ty0 * k).toFixed(2)}px) scale(${s.toFixed(4)})`;
    const t = `translate(0px, ${(L.lift * k).toFixed(2)}px)`;
    if (c !== lastCam) cam.style.transform = lastCam = c;
    if (t !== lastTop) top.style.transform = lastTop = t;
  }

  api.onScene('proxy', (p) => { lastP = p; frame(p); });
  const remeasure = () => { L = null; frame(lastP); };
  let rt = 0;
  window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(remeasure, 80); });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(remeasure);
});
