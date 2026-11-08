// The proposed replacement for fpNoisePixels (fingerprint.js), exactly as it would be pasted.
function fpMix(seed, index, value) {
  let h = (Math.imul((seed ^ index) >>> 0, 2654435761) ^ Math.imul(value | 0, 40503)) >>> 0;
  h ^= h >>> 15; h = Math.imul(h, 2246822507) >>> 0; h ^= h >>> 13; h = Math.imul(h, 3266489909) >>> 0; h ^= h >>> 16;
  return h >>> 0;
}
// WebKit on Apple platforms keeps a 2D canvas premultiplied and converts with Accelerate
// (PixelBufferConversion.cpp -> vImagePremultiplyData / vImageUnpremultiplyData_RGBA8888):
const fpPremul = (v, a) => ((v * a + 127) / 255) | 0;
const fpUnpremul = (p, a) => ((Math.min(p, a) * 255 + (a >> 1)) / a) | 0;

// Only partly transparent pixels are touched, and only their coverage: the seed and the pixel's
// alpha without its low bit decide whether that bit is set; the colour is then stored at the new
// alpha the way the engine stores it. So every value is one getImageData can return, the PNG keeps
// it exactly, noising it again changes nothing, black stays black, and the same pixel gets the same
// noise wherever it is read from (a sub-rectangle, a copy drawn elsewhere).
function fpNoisePixels(data, seed) {
  for (let i = 0; i < data.length; i += 4) {
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
if (typeof module !== 'undefined') module.exports = { fpNoisePixels, fpPremul, fpUnpremul };
