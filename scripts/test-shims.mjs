// Tests the JavaScript privacy shims embedded in PrivacyScripts.swift under Node.js
// (V8 + full ICU). This checks the shim logic; it does not prove behaviour inside
// WebKit/JavaScriptCore — run the in-browser checks in docs/ISOLATION_AND_LIMITATIONS.md for that.
//
//   TZ=America/New_York node scripts/test-shims.mjs
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const swift = readFileSync(new URL('../Sources/PrivacyBrowser/Browser/PrivacyScripts.swift', import.meta.url), 'utf8');
const body = swift.split('static let shimBody = #"""')[1].split('"""#')[0];

function makeWindow(config, extras = {}) {
  const context = vm.createContext({});
  vm.runInContext(`
    var window = globalThis;
    class Geolocation { getCurrentPosition() { throw new Error('native called'); } watchPosition() {} clearWatch() {} }
    class Permissions { query(d) { return Promise.resolve({ state: 'prompt', name: d.name }); } }
    var navigator = { geolocation: new Geolocation(), permissions: new Permissions() };
    var setTimeout = (f) => Promise.resolve().then(f);
    // Browsers expose these as configurable properties of window (not lexical bindings).
    globalThis.RTCPeerConnection = class RTCPeerConnection { constructor(c) { this.config = c; } setConfiguration(c) { this.config = c; } };
    globalThis.webkitRTCPeerConnection = globalThis.RTCPeerConnection;
    globalThis.RTCDataChannel = function () {};
    var open = () => null;
  `, context);
  Object.assign(context, extras);
  vm.runInContext(`(function (CONFIG) {\n${body}\n})(${JSON.stringify(config)});`, context);
  return context;
}

const run = (w, code) => vm.runInContext(code, w);
let failures = 0;
function test(name, fn) {
  Promise.resolve().then(fn).then(
    () => console.log(`ok   ${name}`),
    (e) => { failures++; console.log(`FAIL ${name}\n     ${e.message}`); });
}

const base = { geolocation: { mode: 'deny' }, webRTC: 'disabled' };

for (const [zone, iso, offset, hour] of [
  ['Asia/Tokyo', '2024-01-15T12:00:00Z', -540, 21],
  ['Europe/Berlin', '2024-01-15T12:00:00Z', -60, 13],
  ['Europe/Berlin', '2024-07-15T12:00:00Z', -120, 14],
  ['America/Los_Angeles', '2024-03-10T09:59:59Z', 480, 1],   // just before DST start
  ['America/Los_Angeles', '2024-03-10T10:00:00Z', 420, 3],   // just after
  ['Australia/Lord_Howe', '2024-10-06T15:30:00Z', -660, 2],  // 30-minute DST shift
  ['Asia/Kolkata', '2024-01-15T00:00:00Z', -330, 5],
  ['UTC', '2024-01-15T12:00:00Z', 0, 12],
]) {
  test(`time zone ${zone} @ ${iso}`, () => {
    const w = makeWindow({ ...base, timeZone: zone });
    assert.equal(run(w, `new Date('${iso}').getTimezoneOffset()`), offset);
    assert.equal(run(w, `new Date('${iso}').getHours()`), hour);
    // Compare against ICU's canonical name (e.g. Asia/Kolkata → Asia/Calcutta in some ICU builds).
    assert.equal(run(w, `Intl.DateTimeFormat().resolvedOptions().timeZone`), new Intl.DateTimeFormat('en', { timeZone: zone }).resolvedOptions().timeZone);
    const expectedLocal = new Intl.DateTimeFormat('en-US', { timeZone: zone, dateStyle: 'full', timeStyle: 'long' }).format(new Date(iso));
    assert.equal(run(w, `new Date('${iso}').toLocaleString('en-US', { dateStyle: 'full', timeStyle: 'long' })`), expectedLocal);
    const s = run(w, `new Date('${iso}').toString()`);
    const minutesEast = -offset;
    const sign = minutesEast >= 0 ? '+' : '-';
    const hh = String(Math.floor(Math.abs(minutesEast) / 60)).padStart(2, '0');
    const mm = String(Math.abs(minutesEast) % 60).padStart(2, '0');
    assert.match(s, new RegExp(` ${String(hour).padStart(2, '0')}:\\d\\d:\\d\\d GMT\\${sign}${hh}${mm} \\(`));
  });
}

test('date components agree with Intl for random instants', () => {
  const w = makeWindow({ ...base, timeZone: 'America/Sao_Paulo' });
  const fmt = new Intl.DateTimeFormat('en-US', { timeZone: 'America/Sao_Paulo', hourCycle: 'h23',
    year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', weekday: 'short' });
  for (let i = 0; i < 500; i++) {
    const t = Math.floor(Math.random() * 2e12);
    const p = Object.fromEntries(fmt.formatToParts(new Date(t)).map((x) => [x.type, x.value]));
    const got = run(w, `(() => { const d = new Date(${t}); return [d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getHours(), d.getMinutes(), d.getDay()]; })()`);
    const day = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(p.weekday);
    assert.deepEqual(Array.from(got), [+p.year, +p.month, +p.day, +p.hour, +p.minute, day], `t=${t}`);
  }
});

test('invalid dates stay invalid', () => {
  const w = makeWindow({ ...base, timeZone: 'Asia/Tokyo' });
  assert.equal(run(w, `new Date(NaN).toString()`), 'Invalid Date');
  assert.ok(Number.isNaN(run(w, `new Date(NaN).getHours()`)));
  assert.ok(Number.isNaN(run(w, `new Date(NaN).getTimezoneOffset()`)));
});

test('explicit timeZone option is respected', () => {
  const w = makeWindow({ ...base, timeZone: 'Asia/Tokyo' });
  assert.equal(run(w, `new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', hour: 'numeric', hourCycle: 'h23' }).format(new Date('2024-01-01T05:00:00Z'))`), '05');
  assert.equal(run(w, `new Intl.DateTimeFormat() instanceof Intl.DateTimeFormat`), true);
  assert.equal(run(w, `Intl.DateTimeFormat().resolvedOptions().timeZone`), 'Asia/Tokyo');
});

test('no time zone configured → untouched', () => {
  const w = makeWindow({ ...base });
  assert.equal(run(w, `new Date('2024-01-15T12:00:00Z').getTimezoneOffset()`), new Date('2024-01-15T12:00:00Z').getTimezoneOffset());
});

test('geolocation deny', async () => {
  const w = makeWindow(base);
  const result = await run(w, `new Promise((res) => navigator.geolocation.getCurrentPosition(() => res('success'), (e) => res(e.code)))`);
  assert.equal(result, 1);
  assert.equal((await run(w, `navigator.permissions.query({ name: 'geolocation' })`)).state, 'denied');
  assert.equal((await run(w, `navigator.permissions.query({ name: 'camera' })`)).state, 'prompt');
});

test('geolocation fixed', async () => {
  const w = makeWindow({ ...base, geolocation: { mode: 'fixed', latitude: 48.8566, longitude: 2.3522, accuracy: 25 } });
  const coords = await run(w, `new Promise((res) => navigator.geolocation.getCurrentPosition((p) => res([p.coords.latitude, p.coords.longitude, p.coords.accuracy])))`);
  assert.deepEqual(Array.from(coords), [48.8566, 2.3522, 25]);
});

test('WebRTC disabled', () => {
  const w = makeWindow(base);
  assert.equal(run(w, `typeof RTCPeerConnection`), 'undefined');
  assert.equal(run(w, `typeof webkitRTCPeerConnection`), 'undefined');
  assert.equal(run(w, `RTCPeerConnection = function(){}; typeof RTCPeerConnection`), 'undefined');
});

test('WebRTC relayOnly', () => {
  const w = makeWindow({ ...base, webRTC: 'relayOnly' });
  assert.equal(run(w, `new RTCPeerConnection({ iceServers: [], iceTransportPolicy: 'all' }).config.iceTransportPolicy`), 'relay');
  assert.equal(run(w, `new RTCPeerConnection().config.iceTransportPolicy`), 'relay');
  assert.equal(run(w, `(() => { const p = new RTCPeerConnection(); p.setConfiguration({ iceTransportPolicy: 'all' }); return p.config.iceTransportPolicy; })()`), 'relay');
  assert.equal(run(w, `new webkitRTCPeerConnection({}).config.iceTransportPolicy`), 'relay');
  assert.equal(run(w, `new RTCPeerConnection() instanceof RTCPeerConnection`), true);
});

test('WebRTC unrestricted', () => {
  const w = makeWindow({ ...base, webRTC: 'unrestricted' });
  assert.equal(run(w, `new RTCPeerConnection({ iceTransportPolicy: 'all' }).config.iceTransportPolicy`), 'all');
});

// ---------------------------------------------------------------- device shim
// Minimal stand-ins for the DOM objects the device shim touches.
function deviceExtras() {
  const ctx2d = { getImageData() { return { data: new Uint8ClampedArray([10, 20, 30, 255, 0, 0, 0, 0]) }; } };
  class HTMLCanvasElement { getContext(type) { return type === '2d' ? ctx2d : null; } }
  class WebGLRenderingContext { getParameter(p) { return `native:${p}`; } }
  class PointerEvent { get pointerType() { return 'mouse'; } }
  return {
    screen: { width: 2560, height: 1440, availWidth: 2560, availHeight: 1415 },
    HTMLCanvasElement, WebGLRenderingContext, PointerEvent,
  };
}
const iphone = { platform: 'iPhone', hardwareConcurrency: 6, maxTouchPoints: 5, screenWidth: 393, screenHeight: 852, devicePixelRatio: 3 };

test('device shim: iOS generation declares the model', () => {
  const w = makeWindow({ ...base, isIOS: true, device: iphone }, deviceExtras());
  assert.equal(run(w, `navigator.platform`), 'iPhone');
  assert.equal(run(w, `navigator.hardwareConcurrency`), 6);
  assert.equal(run(w, `navigator.maxTouchPoints`), 5);
  assert.deepEqual(Array.from(run(w, `[screen.width, screen.height, screen.availWidth, screen.availHeight, devicePixelRatio]`)), [393, 852, 393, 852, 3]);
  // Safari has neither of these; the shim must not invent them.
  assert.equal(run(w, `'deviceMemory' in navigator`), false);
  assert.equal(run(w, `'connection' in navigator`), false);
  // navigator.language(s) stay native (Accept-Language can't be changed to match).
  assert.equal(run(w, `'languages' in navigator`), false);
});

// Reads a 2x2 image through the shim: two opaque pixels, one transparent, one opaque.
function readCanvas(seed, repeats = 1) {
  const extras = deviceExtras();
  const source = [10, 20, 30, 255, 40, 50, 60, 255, 0, 0, 0, 0, 70, 80, 90, 255];
  extras.HTMLCanvasElement = class { getContext() { return this.ctx || (this.ctx = { getImageData() { return { width: 2, height: 2, data: new Uint8ClampedArray(source) }; } }); } };
  const w = makeWindow({ ...base, isIOS: true, device: iphone, canvasSeed: seed }, extras);
  return Array.from(run(w, `(() => { const c = new HTMLCanvasElement(); for (let i = 0; i < ${repeats}; i++) c.getContext('2d'); return Array.from(c.getContext('2d').getImageData(0, 0, 2, 2).data); })()`));
}

test('device shim: canvas noise is per-profile, deterministic, low-bit only, wrapped once', () => {
  const source = [10, 20, 30, 255, 40, 50, 60, 255, 0, 0, 0, 0, 70, 80, 90, 255];
  const a = readCanvas(0x1234abcd, 3);
  assert.deepEqual(a, readCanvas(0x1234abcd, 1), 'same seed → same bytes; repeated getContext does not stack noise');
  a.forEach((v, i) => assert.ok(Math.abs(v - source[i]) <= 1, `byte ${i} changed by more than 1`));
  assert.deepEqual(a.slice(8, 12), [0, 0, 0, 0], 'transparent pixels untouched');
  assert.deepEqual([a[3], a[7], a[15]], [255, 255, 255], 'alpha untouched');
  // Different profiles must not read back identical bytes (try a few seeds; any two colliding
  // on all 9 noised bits of this tiny image would be a 1/512 coincidence, not a design flaw).
  const seeds = [1, 2, 3, 0xdeadbeef, 0x7fffffff].map((s) => readCanvas(s).join(','));
  assert.ok(new Set(seeds).size >= 4, 'seeds produce distinct read-backs');
});

test('device shim: WebGL strings overridden, ontouchstart declared, pointerType left alone', () => {
  const w = makeWindow({ ...base, isIOS: true, device: iphone, canvasSeed: 7 }, deviceExtras());
  assert.equal(run(w, `new HTMLCanvasElement().getContext('webgl')`), null);
  assert.equal(run(w, `new WebGLRenderingContext().getParameter(0x9245)`), 'Apple Inc.');
  assert.equal(run(w, `new WebGLRenderingContext().getParameter(0x9246)`), 'Apple GPU');
  assert.equal(run(w, `new WebGLRenderingContext().getParameter(1)`), 'native:1');
  assert.equal(run(w, `'ontouchstart' in window && window.ontouchstart === null`), true);
  assert.equal(run(w, `new PointerEvent().pointerType`), 'mouse', 'real mouse input keeps reporting mouse');
});

test('device shim: macOS generation leaves everything native', () => {
  const w = makeWindow({ ...base, isIOS: false }, deviceExtras());
  assert.equal(run(w, `'platform' in navigator`), false);
  assert.equal(run(w, `screen.width`), 2560);
  assert.equal(run(w, `typeof devicePixelRatio`), 'undefined');
  const px = run(w, `Array.from(new HTMLCanvasElement().getContext('2d').getImageData().data)`);
  assert.deepEqual(Array.from(px), [10, 20, 30, 255, 0, 0, 0, 0]);
  assert.equal(run(w, `new WebGLRenderingContext().getParameter(0x9245)`), 'native:37445');
  assert.equal(run(w, `'ontouchstart' in window`), false);
});

process.on('beforeExit', () => {
  if (failures) { console.log(`${failures} failure(s)`); process.exitCode = 1; }
  else console.log('all shim tests passed');
});
