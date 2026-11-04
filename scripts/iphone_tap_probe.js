// What a tap brings a page on a real iPhone — the reference for the input check (claude/measure-touch,
// never merged). Safari on the iPhone, connected to a Mac by cable: on the iPhone, Settings › Apps ›
// Safari › Advanced › Web Inspector on; on the Mac, Safari › Settings › Advanced › "Show features
// for web developers", then Develop › <the iPhone> › <the page>. In that console:
//
//   1. paste STEP 1 below and press Return ("ready" is printed);
//   2. on the iPhone, tap the element once (one tap per element; several elements in a row are fine);
//   3. paste STEP 2 and press Return: the result is copied to the clipboard ("copied" is printed);
//      paste it into a text file and send it.
//
// It reads only the page's input events and which input listeners the tapped elements and their
// ancestors have: no cookies, no storage, no text typed. Only the page's address without its query.

// ---- STEP 1 ----
(() => {
  const TYPES = ["touchstart", "touchend", "touchmove", "touchcancel", "pointerdown", "pointerup", "pointercancel",
                 "mousedown", "mouseup", "click", "dblclick", "contextmenu", "gesturestart", "gestureend", "focusin",
                 "pointerover", "mouseover", "pointermove", "mousemove"];
  const describe = (t) => {
    try {
      if (t === window) return "window";
      if (t === document) return "document";
      if (!t || t.nodeType !== 1) return String(t && t.nodeName);
      let s = t.tagName.toLowerCase();
      if (t.id) s += "#" + String(t.id).slice(0, 30);
      const c = (typeof t.className === "string" ? t.className : "").trim().split(/\s+/).filter(Boolean).slice(0, 2).join(".");
      if (c) s += "." + c.slice(0, 40);
      return s;
    } catch (e) { return "?"; }
  };
  const R = window.__pbTap = {
    taps: [], describe,
    environment: { userAgent: navigator.userAgent, maxTouchPoints: navigator.maxTouchPoints, ontouchstart: "ontouchstart" in window,
                   TouchEvent: typeof window.TouchEvent, pointerCoarse: matchMedia("(pointer: coarse)").matches,
                   hoverNone: matchMedia("(hover: none)").matches, innerWidth, innerHeight, devicePixelRatio }
  };
  let current = null, moves = 0;
  for (const type of TYPES) {
    window.addEventListener(type, (e) => {
      if (type === "touchstart" || (!current && (type === "pointerdown" || type === "mousedown"))) {
        current = { t0: performance.now(), events: [], target: e.target, before: location.host + location.pathname };
        R.taps.push(current);
        moves = 0;
      }
      if (!current) return;
      if ((type === "pointermove" || type === "mousemove") && ++moves > 2) return;
      const r = { type: e.type, trusted: e.isTrusted, t: Math.round(performance.now() - current.t0), target: describe(e.target) };
      if (e.pointerType !== undefined) r.pointerType = e.pointerType;
      if (e.touches !== undefined) r.touches = e.touches.length;
      current.events.push(r);
      setTimeout(() => { r.prevented = e.defaultPrevented; }, 0);
    }, { capture: true, passive: true });
  }
  console.log("ready: tap the element on the iPhone, then paste STEP 2");
})();

// ---- STEP 2 ----
copy(JSON.stringify({
  environment: __pbTap.environment, page: location.host + location.pathname,
  taps: __pbTap.taps.map((tap) => {
    const chain = [];
    for (let n = tap.target; n; n = n.parentNode) {
      let found = {};
      try { found = getEventListeners(n); } catch (e) {}
      const types = Object.keys(found).filter((k) => /touch|pointer|mouse|click|gesture/.test(k));
      if (types.length) chain.push({ on: __pbTap.describe(n), types });
    }
    return { target: __pbTap.describe(tap.target), events: tap.events, listening: chain, before: tap.before,
             after: location.host + location.pathname };
  })
}, null, 1)); "copied"
