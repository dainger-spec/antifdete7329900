
// ---- Lumen for iPhone: a session's canvas, WebGL and audio, and its language ------------------
// Appended to PrivacyScripts' shim body (Sources/PrivacyBrowser/Browser/PrivacyScripts.swift), so it
// uses that body's helpers (method, getter, define, the shared toString registry) and reaches the
// same realms: the page, its frames (hookChildWindows) and workers made from blobs (hookWorkers).
// What was measured on the iOS 27.2 simulator (claude/ios-app-measure, runs 42422628437 and
// 42423975642): replacements pass the natives check (test-shims.mjs's probeLies) in the window and
// through an about:blank frame; a realm is patched once (the registry says when it already is);
// errors the engine raises are re-raised from a tail call, so their stacks match the engine's.
// Each of canvas, webgl, audio is 'off', 'real' (nothing is touched) or 'noise'.

function fpHash(text, salt) {
  let h = (2166136261 ^ salt) >>> 0;
  for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

function fpMix(seed, index, value) {
  let h = (Math.imul((seed ^ index) >>> 0, 2654435761) ^ Math.imul(value | 0, 40503)) >>> 0;
  h ^= h >>> 15; h = Math.imul(h, 2246822507) >>> 0; h ^= h >>> 13; h = Math.imul(h, 3266489909) >>> 0; h ^= h >>> 16;
  return h >>> 0;
}

// Only partly transparent pixels (antialiased edges of text and shapes) are touched, and the noise
// is idempotent: what decides a pixel ignores the bit that is set. Solid fills and opaque patterns
// stay exact (measured: 0 bytes changed).
function fpNoisePixels(data, seed) {
  for (let i = 0; i < data.length; i += 4) {
    const a = data[i + 3];
    if (a === 0 || a === 255) continue;
    const base = (data[i] & 0xfe) | ((data[i + 1] & 0xfe) << 8) | ((data[i + 2] & 0xfe) << 16) | (a << 24);
    const h = fpMix(seed, i >> 2, base);
    if (h % 5 !== 0) continue;
    const channel = i + ((h >>> 8) % 3);
    data[channel] = (data[channel] & 0xfe) | ((h >>> 16) & 1);
  }
  return data;
}

// WebGL's framebuffer is mostly opaque: one pixel in seven gets its low bit set from the seed,
// again ignoring that bit to decide.
function fpNoiseGL(data, seed) {
  for (let i = 0; i + 3 < data.length; i += 4) {
    if (data[i + 3] === 0) continue;
    const base = (data[i] & 0xfe) | ((data[i + 1] & 0xfe) << 8) | ((data[i + 2] & 0xfe) << 16);
    const h = fpMix(seed, i >> 2, base);
    if (h % 7 !== 0) continue;
    const channel = i + ((h >>> 8) % 3);
    data[channel] = (data[channel] & 0xfe) | ((h >>> 16) & 1);
  }
  return data;
}

function patchFingerprint(w, fp) {
  if (!fp) return;
  // A frame is reached twice: by its own user script and by its parent's hookChildWindows. The
  // registry is shared by the page's frames, so a function already in it is a wrapper of ours, and
  // that place is not wrapped again (each place checked on its own: which ones are patched depends
  // on the session's modes).
  const ours = (fn) => typeof fn === 'function' && registry.has(fn);
  const seed = fpHash(String(fp.seed || ''), 7);
  const apply = Reflect.apply;
  const H = w.HTMLCanvasElement, O = w.OffscreenCanvas;
  const C2D = w.CanvasRenderingContext2D, OC2D = w.OffscreenCanvasRenderingContext2D;
  const nativeGet2D = C2D && C2D.prototype.getImageData;
  const nativeGetOff = OC2D && OC2D.prototype.getImageData;

  // The engine's own receiver check: a canvas of any realm passes (instanceof would not).
  const isCanvas = (Ctor, value) => {
    const d = Ctor && Object.getOwnPropertyDescriptor(Ctor.prototype, 'width');
    if (!d || !d.get) return false;
    try { apply(d.get, value, []); return true; } catch (e) { return false; }
  };
  // A canvas of the same size holding `fill(data)` of the source's pixels; null if unreadable.
  const copyOf = (canvas, fill) => {
    try {
      const width = canvas.width, height = canvas.height;
      if (!width || !height) return null;
      const onDocument = !!w.document && !!nativeGet2D;
      const copy = onDocument ? w.document.createElement('canvas') : new O(width, height);
      copy.width = width; copy.height = height;
      const context = copy.getContext('2d');
      if (fill) {
        context.drawImage(canvas, 0, 0);
        const image = apply(onDocument ? nativeGet2D : nativeGetOff, context, [0, 0, width, height]);
        fill(image.data);
        context.putImageData(image, 0, 0);
      }
      return copy;
    } catch (e) { return null; }
  };
  const noiseFill = (data) => fpNoisePixels(data, fp.unstable ? (seed ^ Math.floor(Math.random() * 0xffffffff)) >>> 0 : seed);

  // Canvas: what a page reads back of a 2D canvas.
  if (fp.canvas === 'noise' || fp.canvas === 'off') {
    const fill = fp.canvas === 'noise' ? noiseFill : null;   // off: an empty canvas of the same size
    for (const [Ctx, nativeGet] of [[C2D, nativeGet2D], [OC2D, nativeGetOff]]) {
      if (!Ctx || !nativeGet || ours(nativeGet)) continue;
      define(Ctx.prototype, 'getImageData', method('getImageData', 4, function (...args) {
        let image;
        try { image = apply(nativeGet, this, args); } catch (e) { return apply(nativeGet, this, args); } // rethrown by the engine, from a tail call
        if (fill) fill(image.data); else image.data.fill(0);
        return image;
      }));
    }
    if (H && !ours(H.prototype.toDataURL)) {
      const nativeToDataURL = H.prototype.toDataURL, nativeToBlob = H.prototype.toBlob;
      define(H.prototype, 'toDataURL', method('toDataURL', 0, function (...args) {
        const copy = isCanvas(H, this) ? copyOf(this, fill) : null;
        return apply(nativeToDataURL, copy || this, args);
      }));
      define(H.prototype, 'toBlob', method('toBlob', 1, function (...args) {
        const copy = isCanvas(H, this) ? copyOf(this, fill) : null;
        return apply(nativeToBlob, copy || this, args);
      }));
    }
    if (O && O.prototype.convertToBlob && !ours(O.prototype.convertToBlob)) {
      const nativeConvert = O.prototype.convertToBlob;
      define(O.prototype, 'convertToBlob', method('convertToBlob', 0, function (...args) {
        const copy = isCanvas(O, this) ? copyOf(this, fill) : null;
        return apply(nativeConvert, copy || this, args);
      }));
    }
  }

  // WebGL: off — no WebGL context at all, as on a device without it; noise — readPixels.
  if (fp.webgl === 'off') {
    for (const Canvas of [H, O]) {
      if (!Canvas || ours(Canvas.prototype.getContext)) continue;
      const nativeContext = Canvas.prototype.getContext;
      define(Canvas.prototype, 'getContext', method('getContext', 1, function (...args) {
        const kind = String(args[0]);
        if (isCanvas(Canvas, this) && (kind === 'webgl' || kind === 'webgl2' || kind === 'experimental-webgl')) return null;
        return apply(nativeContext, this, args);   // anything else, wrong receivers included: the engine's own answer
      }));
    }
  } else if (fp.webgl === 'noise') {
    for (const G of [w.WebGLRenderingContext, w.WebGL2RenderingContext]) {
      if (!G || ours(G.prototype.readPixels)) continue;
      const nativeRead = G.prototype.readPixels;
      define(G.prototype, 'readPixels', method('readPixels', 7, function (...args) {
        try { apply(nativeRead, this, args); } catch (e) { return apply(nativeRead, this, args); }
        const target = args[6];
        if (target && target.BYTES_PER_ELEMENT === 1 && typeof target.length === 'number') fpNoiseGL(target, seed);
        return undefined;
      }));
    }
  }

  // Audio: what a page reads back of a rendered buffer.
  if ((fp.audio === 'noise' || fp.audio === 'off') && w.AudioBuffer && !ours(w.AudioBuffer.prototype.getChannelData)) {
    const AB = w.AudioBuffer, nativeChannel = AB.prototype.getChannelData, nativeCopy = AB.prototype.copyFromChannel;
    const done = new WeakSet();
    const channelData = (buffer, channel) => {
      const data = apply(nativeChannel, buffer, [channel]);
      if (!done.has(data)) {
        done.add(data);
        if (fp.audio === 'off') data.fill(0);
        else for (let i = 0; i < data.length; i++) {
          if (data[i] === 0) continue;
          const h = fpMix(seed, i, channel + 1);
          if (h % 11 === 0) data[i] = data[i] * (1 + ((h & 1) ? 1 : -1) * 1e-6);
        }
      }
      return data;
    };
    define(AB.prototype, 'getChannelData', method('getChannelData', 1, function (...args) {
      try { apply(nativeChannel, this, args); } catch (e) { return apply(nativeChannel, this, args); }
      return channelData(this, args[0]);
    }));
    if (nativeCopy) {
      define(AB.prototype, 'copyFromChannel', method('copyFromChannel', 2, function (...args) {
        try { channelData(this, args[1] | 0); } catch (e) {}
        return apply(nativeCopy, this, args);
      }));
    }
  }

  // A planted fault (DEBUG builds only): one replacement made plainly, which the natives check must catch.
  if (fp.naive && H) {
    const plain = H.prototype.toDataURL;
    H.prototype.toDataURL = function (...args) { return plain.apply(this, args); };
  }

  // Language: navigator.language(s). WebKit sends its own Accept-Language (one per app process,
  // measured: AppleLanguages changed at run time does not reach a new web view), so a page that
  // compares the two sees them differ — the setting says so.
  if (fp.language) {
    const languages = Object.freeze([fp.language]);
    for (const N of [w.Navigator, w.WorkerNavigator]) {
      if (!N) continue;
      for (const [name, value] of [['language', fp.language], ['languages', languages]]) {
        const descriptor = Object.getOwnPropertyDescriptor(N.prototype, name);
        if (!descriptor || !descriptor.get || ours(descriptor.get)) continue;
        const nativeGetter = descriptor.get;
        Object.defineProperty(N.prototype, name, {
          configurable: descriptor.configurable, enumerable: descriptor.enumerable, set: descriptor.set,
          get: getter(name, function () {
            try { apply(nativeGetter, this, []); } catch (e) { return apply(nativeGetter, this, []); }
            return value;
          }),
        });
      }
    }
  }
}
