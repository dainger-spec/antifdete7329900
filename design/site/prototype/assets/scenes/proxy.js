// Home scene "proxy" (tools/templates/pages/home/proxy.mjs): the camera. The window is laid out where it ends
// (under the headline); this script only moves and scales it with the scroll:
//   0    – 0.22  from close on the toolbar (the window wider than the screen) back to the middle of the screen;
//   0.22 – 0.5   it holds there while the page loads, the proxy drops and the page's light goes out;
//   0.5  – 0.62  it settles into its place under the headline (scale 1, no shift).
// Everything else (the progress bar, the light, the error, the captions) is CSS on --t. Nothing moves by itself:
// the transform is set on scroll frames only.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  if (!api.scenesOn) return;
  const el = document.querySelector('.sc-proxy');
  if (!el) return;
  const pin = el.querySelector('.scene-pin');
  const stage = el.querySelector('.px-stage');
  const cam = el.querySelector('.px-cam');
  let L = null, lastP = 0;

  function measure() {
    const vw = window.innerWidth, vh = window.innerHeight;
    const hh = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--header-h')) || 64;
    const top = stage.getBoundingClientRect().top - pin.getBoundingClientRect().top;   // the window's place in the pin
    const W = cam.offsetWidth, H = cam.offsetHeight;
    if (!W || !H) return null;
    const phone = vw < 600;
    // Close: the toolbar just under the header, the window a little wider than the screen.
    // (A phone has no room to go closer: the window starts a little larger, in the middle of the screen.)
    const mid = (s) => hh + (vh - hh - s * H) / 2 - top;
    const s0 = phone ? 1.1 : Math.max(1.2, Math.min(1.56, (vw * 1.04) / W));
    const y0 = phone ? mid(s0) : hh + 30 - top;
    // The middle: as large as fits between the header and the bottom.
    const s1 = Math.max(1, Math.min(phone ? 1.03 : 1.24, (vh - hh - (phone ? 56 : 80)) / H, (vw * (phone ? 1.05 : 0.94)) / W));
    const y1 = mid(s1);
    return { s0, y0, s1, y1 };
  }

  function frame(p) {
    if (!L) L = measure();
    if (!L) return;
    const a = api.easeInOut(api.clamp01(p / 0.22));
    const b = api.easeInOut(api.clamp01((p - 0.5) / 0.12));
    let s = L.s0 + (L.s1 - L.s0) * a, y = L.y0 + (L.y1 - L.y0) * a;
    s += (1 - s) * b; y += (0 - y) * b;
    cam.style.transform = `translate(0px, ${y.toFixed(2)}px) scale(${s.toFixed(4)})`;
  }

  api.onScene('proxy', (p) => { lastP = p; frame(p); });
  let rt = 0;
  window.addEventListener('resize', () => {
    clearTimeout(rt);
    rt = setTimeout(() => { cam.style.transform = ''; L = null; frame(lastP); }, 80);
  });
});
