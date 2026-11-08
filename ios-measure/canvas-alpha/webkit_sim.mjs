// An emulated 2D canvas with WebKit-on-Cocoa conversions: premultiplied store; getImageData =
// vImageUnpremultiplyData; putImageData = vImagePremultiplyData. PNG encode (ImageIO) and decode
// are ASSUMED to use the same rounding (consistent with the measured 0 bytes with the noise off).
import fs from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { makeLab } = require('./lab.js');
const premul = (u, a) => ((u * a + 127) / 255) | 0;
const unpremul = (p, a) => (a === 0 ? 0 : ((Math.min(p, a) * 255 + (a >> 1)) / a) | 0);
class Canvas { constructor(w, h) { this.width = w; this.height = h; this.store = new Uint8ClampedArray(w * h * 4); } }
const ImageDataLike = (w, h, data) => ({ width: w, height: h, data: data || new Uint8ClampedArray(w * h * 4) });
const engine = {
  create: (w, h) => new Canvas(w, h),
  get(c, sx, sy, sw, sh) {
    const img = ImageDataLike(sw, sh);
    for (let y = 0; y < sh; y++) for (let x = 0; x < sw; x++) {
      const X = sx + x, Y = sy + y; if (X < 0 || Y < 0 || X >= c.width || Y >= c.height) continue;
      const s = (Y * c.width + X) * 4, d = (y * sw + x) * 4, a = c.store[s + 3];
      for (let k = 0; k < 3; k++) img.data[d + k] = a === 255 ? c.store[s + k] : unpremul(c.store[s + k], a);
      img.data[d + 3] = a;
    }
    return img;
  },
  put(c, img, dx, dy) {
    for (let y = 0; y < img.height; y++) for (let x = 0; x < img.width; x++) {
      const X = dx + x, Y = dy + y; if (X < 0 || Y < 0 || X >= c.width || Y >= c.height) continue;
      const s = (y * img.width + x) * 4, d = (Y * c.width + X) * 4, a = img.data[s + 3];
      for (let k = 0; k < 3; k++) c.store[d + k] = a === 255 ? img.data[s + k] : premul(img.data[s + k], a);
      c.store[d + 3] = a;
    }
  },
  draw(dst, src, dx, dy) {   // onto an empty canvas: source-over = copy of the premultiplied pixels
    const st = src.store;
    for (let y = 0; y < src.height; y++) for (let x = 0; x < src.width; x++) {
      const X = dx + x, Y = dy + y; if (X < 0 || Y < 0 || X >= dst.width || Y >= dst.height) continue;
      const s = (y * src.width + x) * 4, d = (Y * dst.width + X) * 4;
      for (let k = 0; k < 4; k++) dst.store[d + k] = st[s + k];
    }
  },
  encode(c) { const raw = engine.get(c, 0, 0, c.width, c.height).data; return { png: true, w: c.width, h: c.height, raw: new Uint8ClampedArray(raw), key: Buffer.from(raw).toString('base64') }; },
  async decode(png) { const c = new Canvas(png.w, png.h); engine.put(c, ImageDataLike(png.w, png.h, png.raw), 0, 0); return c; },
  imageData: (w, h) => ImageDataLike(w, h),
  // a canvas with the same coverage (alpha) as `src`, filled with an opaque colour (CG-like: p = c*a/255 rounded)
  withCoverage(src, col) { const c = new Canvas(src.width, src.height); for (let i = 0; i < src.store.length; i += 4) { const a = src.store[i + 3]; for (let k = 0; k < 3; k++) c.store[i + k] = premul(col[k], a); c.store[i + 3] = a; } return c; },
};
// encode returns an object; make "encode twice" comparable by string
const origEncode = engine.encode; engine.encode = (c) => { const o = origEncode(c); o.toString = () => o.key; return o; };
const rt = new Uint8Array(65536); for (let a = 0; a < 256; a++) for (let v = 0; v < 256; v++) rt[a * 256 + v] = a === 0 ? 0 : a === 255 ? v : unpremul(premul(v, a), a);
const lab = makeLab(engine, rt);

// A realistic premultiplied store: the probe drawing rendered by Chromium, premultiplied with vImage's rounding.
const U = JSON.parse(fs.readFileSync(new URL('./chrome_U.json', import.meta.url)));
const c1 = new Canvas(240, 60);
for (let i = 0; i < U.length; i += 4) { const a = U[i + 3]; for (let k = 0; k < 3; k++) c1.store[i + k] = a === 255 ? U[i + k] : premul(U[i + k], a); c1.store[i + 3] = a; }

const fixEncodeTwice = (r) => r;
const names = process.argv.slice(2);
const offRead = (await lab.detect(lab.makeShim('off', 's1'), c1)).read;
const rows = [];
for (const name of names) for (const seed of ['s1', 's2']) {
  const shim = lab.makeShim(name, seed);
  const r = await lab.detect(shim, c1);
  r.D3_encodeTwice = String(shim.encode(c1)) === String(r.png) ? 0 : 1;
  let d2 = 0; for (let i = 0; i < r.read.length; i++) if (r.png.raw[i] !== r.read[i]) d2++;
  rows.push({ run: name + '/' + seed, hash: r.readHash, changedVsOff: lab.diff(r.read, offRead), D1_probe: r.D1_probe, D2_rawPNG: d2, D3: r.D3_readTwice + r.D3_encodeTwice, D4_subrect: r.D4_subrect, D5_putRead: r.D5_putRead, D6_unrep: r.D6_unrepresentable, D7_translate: r.D7_translate, D8_knownSemi: r.D8_knownSemi, D9_opaque: r.D9_opaque, D10_colour: r.D10_colourConstancy });
}
console.table(rows);
export { engine, lab, c1, Canvas, premul, unpremul };
