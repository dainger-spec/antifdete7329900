
// ---- Fingerprint: stage 1 measurement fixture (ios-measure/host/q2.py), NOT product code -------
// Appended to PrivacyScripts' shim body, so it uses that body's helpers (method, getter, define,
// the toString registry) and reaches the same realms: the page, its frames (hookChildWindows) and
// workers made from blobs (hookWorkers). patchWindow calls patchFingerprint(w, CONFIG.fingerprint).

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

// Only partly transparent pixels (the antialiased edges of text and shapes) are touched, and the
// noise is idempotent: what decides a pixel ignores the bit that is set, so noised pixels read and
// noised again come out the same (a PNG drawn back and read gives the same data).
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

function patchFingerprint(w, fp) {
  if (!fp) return;
  const seed = fpHash(String(fp.seed || ''), 7);
  const apply = Reflect.apply;
  if (fp.canvas === 'noise') {
    const C2D = w.CanvasRenderingContext2D, OC2D = w.OffscreenCanvasRenderingContext2D;
    const nativeGet2D = C2D && C2D.prototype.getImageData;
    const nativeGetOff = OC2D && OC2D.prototype.getImageData;
    for (const [Ctx, nativeGet] of [[C2D, nativeGet2D], [OC2D, nativeGetOff]]) {
      if (!Ctx || !nativeGet) continue;
      define(Ctx.prototype, 'getImageData', method('getImageData', 4, function (...args) {
        const image = apply(nativeGet, this, args);
        fpNoisePixels(image.data, seed);
        return image;
      }));
    }
    // A canvas of the same size with the noised pixels; null when it cannot be read (left native).
    const noisedCopy = (canvas) => {
      try {
        const width = canvas.width, height = canvas.height;
        if (!width || !height) return null;
        const onDocument = !!w.document && !!nativeGet2D;
        const copy = onDocument ? w.document.createElement('canvas') : new w.OffscreenCanvas(width, height);
        copy.width = width; copy.height = height;
        const context = copy.getContext('2d');
        context.drawImage(canvas, 0, 0);
        const image = apply(onDocument ? nativeGet2D : nativeGetOff, context, [0, 0, width, height]);
        fpNoisePixels(image.data, seed);
        context.putImageData(image, 0, 0);
        return copy;
      } catch (e) { return null; }
    };
    // Is it a canvas of any realm? The engine's own getter checks the receiver's type, not its
    // prototype, so a canvas of another frame passes (instanceof would not).
    const isCanvas = (Ctor, value) => {
      const d = Ctor && Object.getOwnPropertyDescriptor(Ctor.prototype, 'width');
      if (!d || !d.get) return false;
      try { apply(d.get, value, []); return true; } catch (e) { return false; }
    };
    const H = w.HTMLCanvasElement;
    if (H) {
      const nativeToDataURL = H.prototype.toDataURL, nativeToBlob = H.prototype.toBlob;
      define(H.prototype, 'toDataURL', method('toDataURL', 0, function (...args) {
        const copy = isCanvas(H, this) ? noisedCopy(this) : null;
        return apply(nativeToDataURL, copy || this, args);
      }));
      define(H.prototype, 'toBlob', method('toBlob', 1, function (...args) {
        const copy = isCanvas(H, this) ? noisedCopy(this) : null;
        return apply(nativeToBlob, copy || this, args);
      }));
    }
    const O = w.OffscreenCanvas;
    if (O && O.prototype.convertToBlob) {
      const nativeConvert = O.prototype.convertToBlob;
      define(O.prototype, 'convertToBlob', method('convertToBlob', 0, function (...args) {
        const copy = isCanvas(O, this) ? noisedCopy(this) : null;
        return apply(nativeConvert, copy || this, args);
      }));
    }
  }
  if (fp.webgl) {
    for (const G of [w.WebGLRenderingContext, w.WebGL2RenderingContext]) {
      if (!G) continue;
      const nativeParameter = G.prototype.getParameter;
      define(G.prototype, 'getParameter', method('getParameter', 1, function (...args) {
        const value = apply(nativeParameter, this, args); // the receiver and argument checks stay native
        if (args[0] === 0x9245 && fp.webgl.vendor) return fp.webgl.vendor;     // UNMASKED_VENDOR_WEBGL
        if (args[0] === 0x9246 && fp.webgl.renderer) return fp.webgl.renderer; // UNMASKED_RENDERER_WEBGL
        return value;
      }));
    }
  }
  if (fp.audio === 'noise' && w.AudioBuffer) {
    const AB = w.AudioBuffer, nativeChannel = AB.prototype.getChannelData, nativeCopy = AB.prototype.copyFromChannel;
    const noised = new WeakSet();
    const channelData = (buffer, channel) => {
      const data = apply(nativeChannel, buffer, [channel]);
      if (!noised.has(data)) {
        noised.add(data);
        for (let i = 0; i < data.length; i++) {
          if (data[i] === 0) continue;
          const h = fpMix(seed, i, channel + 1);
          if (h % 11 === 0) data[i] = data[i] * (1 + ((h & 1) ? 1 : -1) * 1e-6);
        }
      }
      return data;
    };
    define(AB.prototype, 'getChannelData', method('getChannelData', 1, function (...args) { return channelData(this, args[0]); }));
    if (nativeCopy) {
      define(AB.prototype, 'copyFromChannel', method('copyFromChannel', 2, function (...args) {
        try { channelData(this, args[1] | 0); } catch (e) {}
        return apply(nativeCopy, this, args);
      }));
    }
  }
  if (fp.cores) {
    for (const N of [w.Navigator, w.WorkerNavigator]) {
      if (!N) continue;
      const descriptor = Object.getOwnPropertyDescriptor(N.prototype, 'hardwareConcurrency');
      if (!descriptor || !descriptor.get) continue;
      const nativeCores = descriptor.get;
      Object.defineProperty(N.prototype, 'hardwareConcurrency', {
        configurable: descriptor.configurable, enumerable: descriptor.enumerable, set: descriptor.set,
        get: getter('hardwareConcurrency', function () { apply(nativeCores, this, []); return fp.cores; }),
      });
    }
  }
}
