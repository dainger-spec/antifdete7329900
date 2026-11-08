// The canvas noise's properties, over every pixel a canvas can hold at partial alpha (node
// ios/shim/test-fingerprint.mjs; ios/scripts/ci.sh runs it). By the engine's rounding (fpPremul,
// fpUnpremul — measured against WebKit's own put/get, claude/measure-canvas-browser): every value
// fpNoisePixels returns is one getImageData can return, so the canvas's PNG reads back the same;
// noising twice is noising once; black and white stay so. The noise before 8 November
// (fpNoisePixelsLowBit, the fault canvasNoiseLowBit) must fail the first — the check's control.
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('./fingerprint.js', import.meta.url), 'utf8');
const realm = {};
vm.runInNewContext(source + '\nObject.assign(out, { fpNoisePixels, fpNoisePixelsLowBit, fpPremul, fpUnpremul });', { out: realm });
const { fpPremul, fpUnpremul } = realm;
const held = (v, a) => fpUnpremul(fpPremul(v, a), a) === v;

function audit(noise) {
  let pixels = 0, changed = 0, unheld = 0, notIdempotent = 0, blackWhite = 0;
  for (const seed of [1, 2, 0xdeadbeef, 12345]) {
    for (let a = 1; a < 255; a++) for (let p = 0; p <= a; p++) {
      const v = fpUnpremul(p, a);
      const pixel = new Uint8ClampedArray([v, fpUnpremul(a - p, a), fpUnpremul((p * 7) % (a + 1), a), a]);
      const once = noise(new Uint8ClampedArray(pixel), seed);
      const twice = noise(new Uint8ClampedArray(once), seed);
      pixels++;
      if (once.some((x, k) => x !== pixel[k])) changed++;
      if (once[3] && [0, 1, 2].some((k) => !held(once[k], once[3]))) unheld++;
      if (twice.some((x, k) => x !== once[k])) notIdempotent++;
    }
    for (let a = 1; a < 255; a++) for (const v of [0, 255]) {
      const o = noise(new Uint8ClampedArray([v, v, v, a]), seed);
      if (o[0] !== v || o[1] !== v || o[2] !== v) blackWhite++;
    }
  }
  return { pixels, changed, unheld, notIdempotent, blackWhite };
}

const now = audit(realm.fpNoisePixels), before = audit(realm.fpNoisePixelsLowBit);
console.log('fpNoisePixels:', JSON.stringify(now));
console.log('fpNoisePixelsLowBit (control):', JSON.stringify(before));
const failures = [];
if (now.changed === 0) failures.push('the noise changes nothing');
if (now.unheld) failures.push(`${now.unheld} values a canvas cannot hold`);
if (now.notIdempotent) failures.push(`${now.notIdempotent} pixels change when noised again`);
if (now.blackWhite) failures.push(`${now.blackWhite} black or white pixels lose their colour`);
if (!before.unheld) failures.push('the control (the old noise) shows no value a canvas cannot hold: the check sees nothing');
if (failures.length) { console.log('FAIL ' + failures.join('; ')); process.exit(1); }
console.log('canvas noise: every value one a canvas can hold, idempotent, black and white kept; the old noise fails as it must');
