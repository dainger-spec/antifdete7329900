
// ---- Lumen for iPhone: a session's canvas, WebGL and audio, and its language ------------------
// Appended to PrivacyScripts' shim body (Sources/PrivacyBrowser/Browser/PrivacyScripts.swift), so it
// uses that body's helpers (method, getter, define, the shared toString registry) and reaches the
// same realms: the page, its frames (hookChildWindows) and workers made from blobs (hookWorkers).
// What was measured on the iOS 27.2 simulator (claude/ios-app-measure, runs 42422628437 and
// 42423975642): replacements pass the natives check (test-shims.mjs's probeLies) in the window and
// through an about:blank frame; a realm is patched once (the registry says when it already is);
// errors the engine raises are re-raised from a tail call, so their stacks match the engine's.
// Each of canvas, webgl, audio is 'off', 'real' (nothing is touched) or 'noise'.
//
// What a replacement does when a page calls it goes, as in the body above, through what this script
// took before any page script ran — never through a function a page can put in another's place:
// the engine's canvas, context and ImageData methods and accessors are taken when the window is
// patched (patchFingerprint) and called through ReflectApply; the arithmetic is operators, not
// Math's methods; a typed array is walked by its indices, not its length getter or fill. A page
// that counts the calls of createElement, getContext, drawImage, putImageData, a canvas's width,
// an ImageData's data, Math.imul or WeakSet.prototype.has sees none during a toDataURL, toBlob,
// getImageData, readPixels or getChannelData, as in Safari, whose natives call no script; and one
// that makes them throw still gets the noised canvas, not the real one beside it. (Until 16
// November the copy was made through the page's createElement, getContext, drawImage and
// putImageData, and a page that broke one got the canvas without the noise.) Functions only, no
// constants: the window is patched before this part's own lines run (build-shim.py puts it after
// the body's last line).

function fpHash(text, salt) {
  let h = (2166136261 ^ salt) >>> 0;
  for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = fpImul(h, 16777619); }
  return h >>> 0;
}

// Math.imul by operators: the low 32 bits of the product, as a signed integer. Each partial product
// is an exact integer below 2^53, and `&`, `<<`, `|` take it modulo 2^32.
function fpImul(a, b) {
  a |= 0; b |= 0;
  return ((a & 0xffff) * b + ((((a >>> 16) * b) & 0xffff) << 16)) | 0;
}

function fpMix(seed, index, value) {
  let h = (fpImul((seed ^ index) >>> 0, 2654435761) ^ fpImul(value | 0, 40503)) >>> 0;
  h ^= h >>> 15; h = fpImul(h, 2246822507) >>> 0; h ^= h >>> 13; h = fpImul(h, 3266489909) >>> 0; h ^= h >>> 16;
  return h >>> 0;
}

// Every element of a typed array set to 0, by its indices (an index past the end reads undefined
// without asking the prototype).
function fpZero(data) {
  for (let i = 0; data[i] !== undefined; i++) data[i] = 0;
  return data;
}

// A prototype's method (part: null) or accessor half ('get', 'set') as the engine has it now; null if none.
function fpOwn(proto, name, part) {
  if (!proto) return null;
  const descriptor = ObjectGetOwnPropertyDescriptor(proto, name);
  if (!descriptor) return null;
  const value = part ? descriptor[part] : descriptor.value;
  return typeof value === 'function' ? value : null;
}

// WebKit on Apple platforms keeps a 2D canvas premultiplied and converts with Accelerate
// (PixelBufferConversion.cpp: vImagePremultiplyData / vImageUnpremultiplyData_RGBA8888).
// Measured (claude/measure-canvas-browser, run 42520097316): the engine's own put/get of all
// 65,536 (value, alpha) pairs gives exactly these, macOS 26.7.2 and 27.0.1; on macOS 26.7.2 the
// PNG drawn back differed from getImageData in 15–26 bytes with the noise before (its own bytes
// in 95–129), in 0 with this one, as with none.
function fpPremul(v, a) { return ((v * a + 127) / 255) | 0; }
function fpUnpremul(p, a) { return (((p < a ? p : a) * 255 + (a >> 1)) / a) | 0; }

// Only partly transparent pixels (antialiased edges of text and shapes) are touched, and only their
// coverage: the seed and the pixel's alpha without its low bit decide whether that bit is set; the
// colour is then what the canvas would hold at the new alpha, as the engine rounds it. So every
// value is one getImageData can return, the PNG made from it reads back the same (a flipped colour
// bit at partial alpha did not survive premultiplication: 18 bytes apart on the owner's iPhone,
// ios-measure/canvas-alpha on claude/ios-app-measure), noising again changes nothing, black and
// white stay black and white, and a pixel's noise does not depend on where it is read from.
// Solid fills and opaque patterns stay exact.
function fpNoisePixels(data, seed) {
  for (let i = 0; data[i + 3] !== undefined; i += 4) {
    const a = data[i + 3];
    if (a === 0 || a === 255) continue;
    const h = fpMix(seed, 0, a >> 1);
    if (h % 5 !== 0) continue;
    const b = (a & 0xfe) | ((h >>> 16) & 1);
    if (b === a || b === 0 || b === 255) continue;
    for (let k = i; k < i + 3; k++) data[k] = fpUnpremul(fpPremul(data[k], b), b);
    data[i + 3] = b;
  }
  return data;
}

// The noise before 8 November, kept only for the fault canvasNoiseLowBit (the red run): a colour's
// low bit flipped at its place, which a premultiplied canvas cannot hold at partial alpha.
function fpNoisePixelsLowBit(data, seed) {
  for (let i = 0; data[i + 3] !== undefined; i += 4) {
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
  for (let i = 0; data[i + 3] !== undefined; i += 4) {
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
  const ours = (fn) => typeof fn === 'function' && ReflectApply(WeakMapGet, registry, [fn]) !== undefined;
  const seed = fpHash(NativeString(fp.seed || ''), 7);
  const apply = ReflectApply;
  const H = w.HTMLCanvasElement, O = w.OffscreenCanvas;
  const C2D = w.CanvasRenderingContext2D, OC2D = w.OffscreenCanvasRenderingContext2D;
  // The engine's own parts of a kind of canvas and of its 2D context, taken now — before this
  // function replaces any of them, and before any script of the page (see the top of this part).
  const partsOf = (Canvas, Context) => {
    if (!Canvas) return null;
    const canvas = Canvas.prototype, context = Context ? Context.prototype : null;
    return {
      Canvas: Canvas,
      width: fpOwn(canvas, 'width', 'get'), setWidth: fpOwn(canvas, 'width', 'set'),
      height: fpOwn(canvas, 'height', 'get'), setHeight: fpOwn(canvas, 'height', 'set'),
      getContext: fpOwn(canvas, 'getContext'),
      drawImage: fpOwn(context, 'drawImage'), putImageData: fpOwn(context, 'putImageData'),
      getImageData: fpOwn(context, 'getImageData'),
    };
  };
  const onPage = partsOf(H, C2D), offscreen = partsOf(O, OC2D);
  const createElement = fpOwn(w.Document ? w.Document.prototype : null, 'createElement');
  const imageDataOf = fpOwn(w.ImageData ? w.ImageData.prototype : null, 'data', 'get');
  const pixelsOf = (image) => (imageDataOf ? apply(imageDataOf, image, []) : image.data);

  // The engine's own receiver check: a canvas of any realm passes (instanceof would not).
  const isCanvas = (parts, value) => {
    if (!parts || !parts.width) return false;
    try { apply(parts.width, value, []); return true; } catch (e) { return false; }
  };
  // A canvas of the same kind and size holding `fill(data)` of the source's pixels; null if
  // unreadable. A page's canvas is copied into a canvas of its document (`document` is the window's
  // own, which no page can replace), an OffscreenCanvas into a new OffscreenCanvas.
  const copyOf = (canvas, fill, parts) => {
    try {
      const width = apply(parts.width, canvas, []), height = apply(parts.height, canvas, []);
      if (!width || !height) return null;
      const copy = parts === onPage ? apply(createElement, w.document, ['canvas']) : new parts.Canvas(width, height);
      apply(parts.setWidth, copy, [width]);
      apply(parts.setHeight, copy, [height]);
      const context = apply(parts.getContext, copy, ['2d']);
      if (fill) {
        apply(parts.drawImage, context, [canvas, 0, 0]);
        const image = apply(parts.getImageData, context, [0, 0, width, height]);
        fill(pixelsOf(image));
        apply(parts.putImageData, context, [image, 0, 0]);
      }
      return copy;
    } catch (e) { return null; }
  };
  const noisePixels = fp.lowBit ? fpNoisePixelsLowBit : fpNoisePixels;
  const unstable = !!fp.unstable;
  const noiseFill = (data) => noisePixels(data, unstable ? (seed ^ Math.floor(Math.random() * 0xffffffff)) >>> 0 : seed);

  // Canvas: what a page reads back of a 2D canvas.
  if (fp.canvas === 'noise' || fp.canvas === 'off') {
    const fill = fp.canvas === 'noise' ? noiseFill : null;   // off: an empty canvas of the same size
    const kinds = [onPage, offscreen];
    for (let k = 0; k < kinds.length; k++) {
      const parts = kinds[k];
      const Ctx = parts === onPage ? C2D : OC2D, nativeGet = parts && parts.getImageData;
      if (!Ctx || !nativeGet || ours(nativeGet)) continue;
      define(Ctx.prototype, 'getImageData', method('getImageData', 4, function (...args) {
        let image;
        try { image = apply(nativeGet, this, args); } catch (e) { return apply(nativeGet, this, args); } // rethrown by the engine, from a tail call
        const data = pixelsOf(image);
        if (fill) fill(data); else fpZero(data);
        return image;
      }));
    }
    if (H && onPage && !ours(H.prototype.toDataURL)) {
      const nativeToDataURL = H.prototype.toDataURL, nativeToBlob = H.prototype.toBlob;
      define(H.prototype, 'toDataURL', method('toDataURL', 0, function (...args) {
        const copy = isCanvas(onPage, this) ? copyOf(this, fill, onPage) : null;
        return apply(nativeToDataURL, copy || this, args);
      }));
      define(H.prototype, 'toBlob', method('toBlob', 1, function (...args) {
        const copy = isCanvas(onPage, this) ? copyOf(this, fill, onPage) : null;
        return apply(nativeToBlob, copy || this, args);
      }));
    }
    if (O && offscreen && O.prototype.convertToBlob && !ours(O.prototype.convertToBlob)) {
      const nativeConvert = O.prototype.convertToBlob;
      define(O.prototype, 'convertToBlob', method('convertToBlob', 0, function (...args) {
        const copy = isCanvas(offscreen, this) ? copyOf(this, fill, offscreen) : null;
        return apply(nativeConvert, copy || this, args);
      }));
    }
  }

  // WebGL: off — no WebGL context at all, as on a device without it; noise — readPixels.
  if (fp.webgl === 'off') {
    const kinds = [onPage, offscreen];
    for (let k = 0; k < kinds.length; k++) {
      const parts = kinds[k];
      if (!parts || !parts.getContext || ours(parts.getContext)) continue;
      const nativeContext = parts.getContext;
      define(parts.Canvas.prototype, 'getContext', method('getContext', 1, function (...args) {
        const kind = NativeString(args[0]);
        if (isCanvas(parts, this) && (kind === 'webgl' || kind === 'webgl2' || kind === 'experimental-webgl')) return null;
        return apply(nativeContext, this, args);   // anything else, wrong receivers included: the engine's own answer
      }));
    }
  } else if (fp.webgl === 'noise') {
    const kinds = [w.WebGLRenderingContext, w.WebGL2RenderingContext];
    for (let k = 0; k < kinds.length; k++) {
      const G = kinds[k];
      if (!G || ours(G.prototype.readPixels)) continue;
      const nativeRead = G.prototype.readPixels;
      define(G.prototype, 'readPixels', method('readPixels', 7, function (...args) {
        try { apply(nativeRead, this, args); } catch (e) { return apply(nativeRead, this, args); }
        // An ArrayBufferView the engine wrote into (it threw otherwise): bytes, noised.
        const target = args[6];
        if (target && target.BYTES_PER_ELEMENT === 1) fpNoiseGL(target, seed);
        return undefined;
      }));
    }
  }

  // Audio: what a page reads back of a rendered buffer.
  if ((fp.audio === 'noise' || fp.audio === 'off') && w.AudioBuffer && !ours(w.AudioBuffer.prototype.getChannelData)) {
    const AB = w.AudioBuffer, nativeChannel = AB.prototype.getChannelData, nativeCopy = AB.prototype.copyFromChannel;
    const done = new NativeWeakSet();
    const off = fp.audio === 'off';
    const channelData = (buffer, channel) => {
      const data = apply(nativeChannel, buffer, [channel]);
      if (!apply(WeakSetHas, done, [data])) {
        apply(WeakSetAdd, done, [data]);
        if (off) fpZero(data);
        else for (let i = 0; data[i] !== undefined; i++) {
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
        const descriptor = ObjectGetOwnPropertyDescriptor(N.prototype, name);
        if (!descriptor || !descriptor.get || ours(descriptor.get)) continue;
        const nativeGetter = descriptor.get;
        ObjectDefineProperty(N.prototype, name, {
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
