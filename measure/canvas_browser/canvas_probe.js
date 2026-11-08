// The body of an async function run in the page (callAsyncJavaScript, page world). CFG: {table}.
// What the iOS stand q2 reads (its draw() and dataURLvsImageData, ios-measure/host/q2_probe.js on
// claude/ios-app-measure), the bytes for the raw PNG comparison, and the detectors of
// ios-measure/canvas-alpha/README.md that a page can run (D4 sub-rectangle, D5 put/get, D7 shifted
// copy, D10 black and white text). Returns a JSON string.
const W = 240, H = 60;
const CTX = CFG.soft ? { willReadFrequently: true } : undefined;
function draw(c) {
  c.width = 240; c.height = 60;
  const x = c.getContext('2d', CTX);
  x.textBaseline = 'top'; x.font = '14px Arial';
  x.fillStyle = '#f60'; x.fillRect(125, 1, 62, 20);
  x.fillStyle = '#069'; x.fillText('Lumen ✓ 😃 Cwm fjordbank glyphs vext quiz', 2, 15);
  x.fillStyle = 'rgba(102, 204, 0, 0.7)'; x.fillText('Lumen ✓ 😃', 4, 35);
  const g = x.createLinearGradient(0, 0, 240, 0); g.addColorStop(0, 'red'); g.addColorStop(1, 'blue');
  x.fillStyle = g; x.beginPath(); x.arc(200, 40, 15, 0, Math.PI * 2); x.fill();
  return c;
}
const b64 = (d) => { const u = new Uint8Array(d.buffer, d.byteOffset, d.byteLength); let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s); };
const hash = (d) => { let h = 0x811c9dc5; for (let i = 0; i < d.length; i++) { h ^= d[i]; h = Math.imul(h, 0x01000193); } return (h >>> 0).toString(16).padStart(8, '0'); };
const out = { step: 'start' };
const step = (name) => { out.step = name; };
try {
step('draw');
const c1 = draw(document.createElement('canvas'));
const x1 = c1.getContext('2d', CTX);
step('getImageData');
const r1 = x1.getImageData(0, 0, W, H).data;
out.hash = hash(r1);
out.stable = hash(x1.getImageData(0, 0, W, H).data) === out.hash;
out.semi = (() => { let n = 0; for (let i = 3; i < r1.length; i += 4) if (r1[i] && r1[i] < 255) n++; return n; })();
// q2's dataURLvsImageData, as it is there.
step('D1');
out.D1 = await (async () => { try { const img = new Image(); img.src = c1.toDataURL(); await img.decode();
  const c2 = document.createElement('canvas'); c2.width = 240; c2.height = 60; const x2 = c2.getContext('2d', CTX); x2.drawImage(img, 0, 0);
  const a = x2.getImageData(0, 0, 240, 60).data, b = c1.getContext('2d', CTX).getImageData(0, 0, 240, 60).data; let diff = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) diff++; return diff; } catch (e) { return 'error ' + e.message; } })();
step('toDataURL');
out.png = c1.toDataURL();
step('b64');
out.read = b64(r1);
step('D4');
// D4: a sub-rectangle against the same place of the full read.
out.D4 = (() => { const sx = 10, sy = 5, sw = 100, sh = 40; const s = x1.getImageData(sx, sy, sw, sh).data; let d = 0;
  for (let y = 0; y < sh; y++) for (let x = 0; x < sw; x++) for (let k = 0; k < 4; k++) if (s[(y * sw + x) * 4 + k] !== r1[((sy + y) * W + sx + x) * 4 + k]) d++; return d; })();
step('D5');
// D5: what was read, put into a fresh canvas and read again.
out.D5 = (() => { const c = document.createElement('canvas'); c.width = W; c.height = H; const x = c.getContext('2d', CTX);
  const img = x.createImageData(W, H); img.data.set(r1); x.putImageData(img, 0, 0); const d = x.getImageData(0, 0, W, H).data; let n = 0;
  for (let i = 0; i < d.length; i++) if (d[i] !== r1[i]) n++; return n; })();
step('D7');
// D7: the canvas drawn into another at (3, 2), read where it landed.
out.D7 = (() => { const c = document.createElement('canvas'); c.width = W + 3; c.height = H + 2; const x = c.getContext('2d', CTX); x.drawImage(c1, 3, 2);
  const d = x.getImageData(3, 2, W, H).data; let n = 0; for (let i = 0; i < d.length; i++) if (d[i] !== r1[i]) n++; return n; })();
step('D10');
// D10: black and white text on a transparent canvas stay black and white.
out.D10 = (() => { const c = document.createElement('canvas'); c.width = W; c.height = H; const x = c.getContext('2d', CTX);
  x.textBaseline = 'top'; x.font = '14px Arial'; x.fillStyle = '#000'; x.fillText('Lumen Cwm fjordbank glyphs vext quiz', 2, 10);
  x.fillStyle = '#fff'; x.fillText('Lumen Cwm fjordbank glyphs vext quiz', 2, 35);
  const d = x.getImageData(0, 0, W, H).data; let n = 0;
  for (let i = 0; i < d.length; i += 4) { if (!d[i + 3]) continue; const r = d[i], g = d[i + 1], b = d[i + 2];
    if (!((r === 0 && g === 0 && b === 0) || (r === 255 && g === 255 && b === 255))) n++; } return n; })();
// The engine's own put/get of every (value, alpha): R = value, G = (7·value + alpha) & 255, B = 255 − value.
step('table');
if (CFG.table) {
  const c = document.createElement('canvas'); c.width = 256; c.height = 256; const x = c.getContext('2d', CTX);
  const img = x.createImageData(256, 256);
  for (let a = 0; a < 256; a++) for (let v = 0; v < 256; v++) { const i = (a * 256 + v) * 4; img.data[i] = v; img.data[i + 1] = (7 * v + a) & 255; img.data[i + 2] = 255 - v; img.data[i + 3] = a; }
  x.putImageData(img, 0, 0);
  out.table = b64(x.getImageData(0, 0, 256, 256).data);
}
step('done');
} catch (e) { out.error = (e && e.name) + ': ' + (e && e.message) + ' at step ' + out.step; out.stack = String(e && e.stack).slice(0, 400); }
return JSON.stringify(out);
