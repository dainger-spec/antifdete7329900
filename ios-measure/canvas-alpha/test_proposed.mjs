import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { fpNoisePixels, fpPremul, fpUnpremul } = require('./proposed.js');
const { engine, lab, c1 } = await import('./webkit_sim.mjs');
const rt = (v, a) => fpUnpremul(fpPremul(v, a), a);
// 1. exhaustive: every representable input (u at alpha a), several seeds: output representable, idempotent
let bad = 0, changed = 0, n = 0;
for (const seed of [1, 2, 0xdeadbeef, 12345]) for (let a = 1; a < 255; a++) for (let p = 0; p <= a; p++) {
  const u = fpUnpremul(p, a); const d = new Uint8ClampedArray([u, 255 - u, fpUnpremul(a - p, a), a]);
  d[1] = rt(d[1], a);
  const once = fpNoisePixels(new Uint8ClampedArray(d), seed), twice = fpNoisePixels(new Uint8ClampedArray(once), seed);
  n++; if (once.some((x, k) => x !== d[k])) changed++;
  for (let k = 0; k < 3; k++) if (once[3] !== 0 && rt(once[k], once[3]) !== once[k]) bad++;
  if (twice.some((x, k) => x !== once[k])) bad++;
}
console.log(`exhaustive: ${n} pixels, ${changed} changed, ${bad} unrepresentable or not idempotent`);
// 2. black and white pixels stay black and white
let bw = 0; for (const seed of [1, 2, 3]) for (let a = 1; a < 255; a++) for (const v of [0, 255]) { const o = fpNoisePixels(new Uint8ClampedArray([v, v, v, a]), seed); if (o[0] !== v || o[1] !== v || o[2] !== v) bw++; }
console.log('black/white pixels whose colour changed:', bw);
// 3. the detectors, on the emulated WebKit canvas, with this exact code
lab.variants.proposed = { noise: (data, seed) => fpNoisePixels(data, seed), opts: {} };
const off = (await lab.detect(lab.makeShim('off', 's1'), c1)).read;
for (const seed of ['s1', 's2']) {
  const shim = lab.makeShim('proposed', seed); const r = await lab.detect(shim, c1);
  let d2 = 0; for (let i = 0; i < r.read.length; i++) if (r.png.raw[i] !== r.read[i]) d2++;
  console.log(seed, { hash: r.readHash, changedVsOff: lab.diff(r.read, off), D1_probe: r.D1_probe, D2_rawPNG: d2, D3: r.D3_readTwice, D4_subrect: r.D4_subrect, D5_putRead: r.D5_putRead, D6_unrep: r.D6_unrepresentable, D7_translate: r.D7_translate, D8_knownSemi: r.D8_knownSemi, D9_opaque: r.D9_opaque, D10_colour: r.D10_colourConstancy });
}
// 4. how is the seed derived in the shim? fpHash(String(fp.seed),7): makeShim does the same.
