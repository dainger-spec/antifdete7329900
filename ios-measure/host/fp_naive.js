// The red side of the natives check (ios-measure/host/q2.py): the same replacements as
// fp_patch.js, written the way most fingerprint scripts are — plain assignments, no native shape,
// no toString. The natives check must catch every one of them; if it does not, it cannot tell.
(function (fp) {
  'use strict';
  const seed = fp.seed.length * 2654435761 >>> 0;
  const getImageData = CanvasRenderingContext2D.prototype.getImageData;
  const noise = (d) => { for (let i = 0; i < d.length; i += 4) if (d[i + 3] && d[i + 3] < 255 && ((i * seed) >>> 0) % 5 === 0) d[i] ^= 1; return d; };
  CanvasRenderingContext2D.prototype.getImageData = function (...a) { const im = getImageData.apply(this, a); noise(im.data); return im; };
  const toDataURL = HTMLCanvasElement.prototype.toDataURL;
  HTMLCanvasElement.prototype.toDataURL = function (...a) {
    const c = document.createElement('canvas'); c.width = this.width; c.height = this.height;
    const x = c.getContext('2d'); x.drawImage(this, 0, 0); x.putImageData(x.getImageData(0, 0, c.width, c.height), 0, 0);
    return toDataURL.apply(c, a);
  };
  const toBlob = HTMLCanvasElement.prototype.toBlob;
  HTMLCanvasElement.prototype.toBlob = function (...a) { return toBlob.apply(this, a); };
  for (const G of [WebGLRenderingContext, self.WebGL2RenderingContext].filter(Boolean)) {
    const getParameter = G.prototype.getParameter;
    G.prototype.getParameter = function (p) {
      if (p === 0x9245) return fp.webgl.vendor;
      if (p === 0x9246) return fp.webgl.renderer;
      return getParameter.call(this, p);
    };
  }
  const getChannelData = AudioBuffer.prototype.getChannelData;
  AudioBuffer.prototype.getChannelData = function (c) { const d = getChannelData.call(this, c); for (let i = 0; i < d.length; i += 97) d[i] *= 1.000001; return d; };
  const copyFromChannel = AudioBuffer.prototype.copyFromChannel;
  AudioBuffer.prototype.copyFromChannel = function (...a) { return copyFromChannel.apply(this, a); };
  Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', { get() { return fp.cores; }, configurable: true, enumerable: true });
})(__FP__);
