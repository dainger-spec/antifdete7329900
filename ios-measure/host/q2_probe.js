// The body of an async function run in the page (callAsyncJavaScript, page world) by q2.py.
// What a fingerprinting script would read, and what a detector would try. Returns plain JSON.
const CFG = __CFG__;
const out = { label: CFG.label };
const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); } return (h >>> 0).toString(16).padStart(8, '0'); };
const hashBytes = (d) => { let h = 0x811c9dc5; for (let i = 0; i < d.length; i++) { h ^= d[i]; h = Math.imul(h, 0x01000193); } return (h >>> 0).toString(16).padStart(8, '0'); };
const errOf = (f) => { try { f(); return null; } catch (e) { return { name: e && e.constructor && e.constructor.name, message: String(e && e.message), stack: String(e && e.stack).split('\n').slice(0, 4) }; } };
function draw(c) {
  c.width = 240; c.height = 60;
  const x = c.getContext('2d');
  x.textBaseline = 'top'; x.font = '14px Arial';
  x.fillStyle = '#f60'; x.fillRect(125, 1, 62, 20);
  x.fillStyle = '#069'; x.fillText('Lumen ✓ 😃 Cwm fjordbank glyphs vext quiz', 2, 15);
  x.fillStyle = 'rgba(102, 204, 0, 0.7)'; x.fillText('Lumen ✓ 😃', 4, 35);
  const g = x.createLinearGradient(0, 0, 240, 0); g.addColorStop(0, 'red'); g.addColorStop(1, 'blue');
  x.fillStyle = g; x.beginPath(); x.arc(200, 40, 15, 0, Math.PI * 2); x.fill();
  return c;
}

// ---- What is read: canvas, WebGL, audio, navigator, time zone, language
const c1 = draw(document.createElement('canvas'));
out.canvasReads = Array.from({ length: 5 }, () => fnv(c1.toDataURL()));
out.canvas = out.canvasReads[0];
out.canvasFresh = fnv(draw(document.createElement('canvas')).toDataURL());
out.imageData = hashBytes(c1.getContext('2d').getImageData(0, 0, 240, 60).data);
out.imageDataReads = Array.from({ length: 3 }, () => hashBytes(c1.getContext('2d').getImageData(0, 0, 240, 60).data));
out.partialAlphaPixels = (() => { const d = c1.getContext('2d').getImageData(0, 0, 240, 60).data; let n = 0; for (let i = 3; i < d.length; i += 4) if (d[i] && d[i] < 255) n++; return n; })();
out.webgl = (() => {
  try {
    const gl = document.createElement('canvas').getContext('webgl');
    if (!gl) return { absent: true };
    const ext = gl.getExtension('WEBGL_debug_renderer_info');
    return { vendor: gl.getParameter(gl.VENDOR), renderer: gl.getParameter(gl.RENDERER),
             unmaskedVendor: ext && gl.getParameter(ext.UNMASKED_VENDOR_WEBGL), unmaskedRenderer: ext && gl.getParameter(ext.UNMASKED_RENDERER_WEBGL),
             version: gl.getParameter(gl.VERSION), maxTexture: gl.getParameter(gl.MAX_TEXTURE_SIZE) };
  } catch (e) { return { error: String(e) }; }
})();
out.audio = await (async () => {
  try {
    const Ctx = window.OfflineAudioContext || window.webkitOfflineAudioContext;
    const ctx = new Ctx(1, 44100, 44100);
    const osc = ctx.createOscillator(); osc.type = 'triangle'; osc.frequency.value = 10000;
    const comp = ctx.createDynamicsCompressor();
    for (const [k, v] of [['threshold', -50], ['knee', 40], ['ratio', 12], ['attack', 0], ['release', 0.25]]) comp[k].value = v;
    osc.connect(comp); comp.connect(ctx.destination); osc.start(0);
    const buffer = await ctx.startRendering();
    const data = buffer.getChannelData(0);
    let sum = 0; for (let i = 4500; i < 5000; i++) sum += Math.abs(data[i]);
    const copy = new Float32Array(500); buffer.copyFromChannel(copy, 0, 4500);
    let sumCopy = 0; for (let i = 0; i < 500; i++) sumCopy += Math.abs(copy[i]);
    return { sum: String(sum), sumCopy: String(sumCopy), consistent: sum === sumCopy };
  } catch (e) { return { error: String(e) }; }
})();
out.navigator = { userAgent: navigator.userAgent, platform: navigator.platform, cores: navigator.hardwareConcurrency,
  maxTouchPoints: navigator.maxTouchPoints, language: navigator.language, languages: Array.from(navigator.languages || []),
  vendor: navigator.vendor, deviceMemory: typeof navigator.deviceMemory, standalone: navigator.standalone, webdriver: navigator.webdriver };
out.screen = { width: screen.width, height: screen.height, availWidth: screen.availWidth, availHeight: screen.availHeight,
  dpr: devicePixelRatio, inner: [innerWidth, innerHeight], outer: [outerWidth, outerHeight], colorDepth: screen.colorDepth };
out.timeZone = { intl: Intl.DateTimeFormat().resolvedOptions().timeZone, offset: new Date(Date.UTC(2026, 0, 15, 12)).getTimezoneOffset(),
  string: String(new Date(Date.UTC(2026, 0, 15, 12))) };
out.windowSafari = typeof window.safari;
out.windowOwn = Object.getOwnPropertyNames(window).length;
out.windowNames = Object.getOwnPropertyNames(window);
out.webkitHandlers = typeof window.webkit;

// ---- The natives check (scripts/test-shims.mjs's probeLies, CreepJS's lie detector)
const probeLies = (0, eval)(CFG.probeLies);
const targets = [
  ['HTMLCanvasElement.prototype.toDataURL', 'HTMLCanvasElement'], ['HTMLCanvasElement.prototype.toBlob', 'HTMLCanvasElement'],
  ['CanvasRenderingContext2D.prototype.getImageData', 'CanvasRenderingContext2D'],
  ['WebGLRenderingContext.prototype.getParameter', 'WebGLRenderingContext'], ['WebGL2RenderingContext.prototype.getParameter', 'WebGL2RenderingContext'],
  ['AudioBuffer.prototype.getChannelData', 'AudioBuffer'], ['AudioBuffer.prototype.copyFromChannel', 'AudioBuffer'],
  ['Object.getOwnPropertyDescriptor(Navigator.prototype, "hardwareConcurrency").get', 'Navigator', 'hardwareConcurrency'],
  ['Date.prototype.getTimezoneOffset', 'Date'], ['Date.prototype.toString', 'Date'], ['Intl.DateTimeFormat.prototype.resolvedOptions', null],
  ['Function.prototype.toString', null],
];
const frame = document.createElement('iframe');
document.body.appendChild(frame);   // about:blank, made by the page after the user script ran
const frameToString = frame.contentWindow.Function.prototype.toString;
out.lies = {};
for (const [expr, iface, name] of targets) {
  let fn; try { fn = (0, eval)(expr); } catch (e) { continue; }
  if (typeof fn !== 'function') continue;
  const Interface = iface ? window[iface] : null;
  const top = probeLies(fn, Function.prototype.toString, Interface, name || null);
  const viaFrame = probeLies(fn, frameToString, Interface, name || null);
  out.lies[expr] = { top: Array.from(top), frame: Array.from(viaFrame), text: Function.prototype.toString.call(fn).slice(0, 80),
                     frameText: frameToString.call(fn).slice(0, 80) };
}

// ---- Other realms: an about:blank frame's own APIs, a same-origin frame, workers
const fw = frame.contentWindow;
out.frameBlank = {
  canvas: (() => { try { return fnv(fw.HTMLCanvasElement.prototype.toDataURL.call(c1)); } catch (e) { return 'error ' + e.message; } })(),
  ownCanvas: (() => { try { return fnv(draw(fw.document.createElement('canvas')).toDataURL()); } catch (e) { return 'error ' + e.message; } })(),
  cores: fw.navigator.hardwareConcurrency,
  timeZone: fw.Intl.DateTimeFormat().resolvedOptions().timeZone,
  toDataURLText: fw.Function.prototype.toString.call(fw.HTMLCanvasElement.prototype.toDataURL).slice(0, 80),
};
out.frameSameOrigin = await new Promise((resolve) => {
  const f = document.createElement('iframe'); f.src = '/blank?frame=1';
  f.onload = () => { try { const w = f.contentWindow; resolve({ canvas: fnv(draw(w.document.createElement('canvas')).toDataURL()), cores: w.navigator.hardwareConcurrency,
    timeZone: w.Intl.DateTimeFormat().resolvedOptions().timeZone }); } catch (e) { resolve({ error: String(e) }); } };
  setTimeout(() => resolve({ error: 'timeout' }), 6000); document.body.appendChild(f);
});
const workerSource = `(async () => {
  const fnv = ${fnv.toString()};
  const r = { cores: navigator.hardwareConcurrency, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone, language: navigator.language };
  if (typeof OffscreenCanvas === 'function') {
    try { const c = new OffscreenCanvas(240, 60); const x = c.getContext('2d');
      x.textBaseline = 'top'; x.font = '14px Arial'; x.fillStyle = '#069'; x.fillText('Lumen \\u2713 Cwm fjordbank glyphs vext quiz', 2, 15);
      const d = x.getImageData(0, 0, 240, 60).data; let h = 0x811c9dc5; for (let i = 0; i < d.length; i++) { h ^= d[i]; h = Math.imul(h, 0x01000193); }
      r.offscreen = (h >>> 0).toString(16); } catch (e) { r.offscreen = 'error ' + e.message; }
  } else r.offscreen = 'absent';
  postMessage(r);
})();`;
const runWorker = (url) => new Promise((resolve) => {
  try { const w = new Worker(url); w.onmessage = (m) => resolve(m.data); w.onerror = (e) => resolve({ error: 'worker error ' + (e.message || '') }); }
  catch (e) { resolve({ error: String(e) }); }
  setTimeout(() => resolve({ error: 'timeout' }), 8000);
});
out.workerBlob = await runWorker(URL.createObjectURL(new Blob([workerSource], { type: 'text/javascript' })));
out.workerURL = await runWorker('/static/q2_worker.js');
out.mainOffscreen = (() => { try { const c = document.createElement('canvas'); c.width = 240; c.height = 60; const x = c.getContext('2d');
  x.textBaseline = 'top'; x.font = '14px Arial'; x.fillStyle = '#069'; x.fillText('Lumen ✓ Cwm fjordbank glyphs vext quiz', 2, 15);
  return hashBytes(x.getImageData(0, 0, 240, 60).data); } catch (e) { return 'error ' + e.message; } })();

// ---- Consistency tests a detector runs on noise
out.solidFillChanged = (() => { const c = document.createElement('canvas'); c.width = c.height = 20; const x = c.getContext('2d');
  x.fillStyle = 'rgb(10,20,30)'; x.fillRect(0, 0, 20, 20); const d = x.getImageData(0, 0, 20, 20).data; let bad = 0;
  for (let i = 0; i < d.length; i += 4) if (d[i] !== 10 || d[i + 1] !== 20 || d[i + 2] !== 30 || d[i + 3] !== 255) bad++; return bad; })();
out.knownPixelsChanged = (() => { const c = document.createElement('canvas'); c.width = c.height = 16; const x = c.getContext('2d');
  const img = x.createImageData(16, 16); for (let i = 0; i < img.data.length; i += 4) { img.data[i] = (i * 7) & 255; img.data[i + 1] = (i * 13) & 255; img.data[i + 2] = (i * 3) & 255; img.data[i + 3] = 255; }
  x.putImageData(img, 0, 0); const d = x.getImageData(0, 0, 16, 16).data; let bad = 0; for (let i = 0; i < d.length; i++) if (d[i] !== img.data[i]) bad++; return bad; })();
out.dataURLvsImageData = await (async () => { try { const img = new Image(); img.src = c1.toDataURL(); await img.decode();
  const c2 = document.createElement('canvas'); c2.width = 240; c2.height = 60; const x2 = c2.getContext('2d'); x2.drawImage(img, 0, 0);
  const a = x2.getImageData(0, 0, 240, 60).data, b = c1.getContext('2d').getImageData(0, 0, 240, 60).data; let diff = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) diff++; return diff; } catch (e) { return 'error ' + e.message; } })();

// ---- Errors a wrong call raises: message and the first frames of the stack
const ctx2d = c1.getContext('2d');
out.errors = {
  toDataURL: errOf(() => HTMLCanvasElement.prototype.toDataURL.call({})),
  getImageData: errOf(() => CanvasRenderingContext2D.prototype.getImageData.call({}, 0, 0, 1, 1)),
  getImageDataZero: errOf(() => ctx2d.getImageData(0, 0, 0, 0)),
  getParameter: errOf(() => WebGLRenderingContext.prototype.getParameter.call({}, 0)),
  getChannelData: errOf(() => AudioBuffer.prototype.getChannelData.call({}, 0)),
  cores: errOf(() => Object.getOwnPropertyDescriptor(Navigator.prototype, 'hardwareConcurrency').get.call({})),
};
out.protoShapes = Object.fromEntries(['HTMLCanvasElement', 'CanvasRenderingContext2D', 'WebGLRenderingContext', 'AudioBuffer', 'Navigator', 'Date', 'Function']
  .map((n) => [n, fnv(Object.getOwnPropertyNames(window[n].prototype).join())]));
out.navigatorOwn = Object.getOwnPropertyNames(navigator).length + Object.getOwnPropertySymbols(navigator).length;
frame.remove();
return out;
