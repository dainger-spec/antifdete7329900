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
    // Like WebKit on a Mac: navigator and screen values are getters on the prototypes.
    class Navigator {
      get platform() { return 'MacIntel'; } get maxTouchPoints() { return 0; } get hardwareConcurrency() { return 8; }
      get language() { return 'en-US'; } get languages() { return ['en-US']; }
    }
    var navigator = Object.assign(Object.create(Navigator.prototype), { geolocation: new Geolocation(), permissions: new Permissions() });
    class Screen { get width() { return 1728; } get height() { return 1117; } get availWidth() { return 1728; } get availHeight() { return 1079; } }
    var screen = new Screen();
    Object.defineProperty(globalThis, 'devicePixelRatio', { get() { return 2; }, set(v) {}, enumerable: true, configurable: true });
    class HTMLCanvasElement { getContext() { return null; } toDataURL() { return 'data:'; } }
    class AudioContext { createAnalyser() { return {}; } }
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

const iPhone = { platform: 'iPhone', maxTouchPoints: 5, hardwareConcurrency: 4, screenWidth: 390, screenHeight: 844, devicePixelRatio: 3 };
const surface = `JSON.stringify([navigator.platform, navigator.maxTouchPoints, navigator.hardwareConcurrency, navigator.language,
  Array.from(navigator.languages), typeof navigator.deviceMemory, screen.width, screen.height, screen.availWidth, screen.availHeight,
  devicePixelRatio])`;

test('macOS profile: navigator and screen keep their native values', () => {
  const w = makeWindow(base);
  assert.equal(run(w, surface), JSON.stringify(['MacIntel', 0, 8, 'en-US', ['en-US'], 'undefined', 1728, 1117, 1728, 1079, 2]));
  assert.deepEqual(Array.from(run(w, `Object.getOwnPropertyNames(navigator)`)).sort(), ['geolocation', 'permissions']);
  assert.deepEqual(Array.from(run(w, `Object.getOwnPropertyNames(screen)`)), []);
});

test('iPhone profile: device values, as getters on the prototypes', () => {
  const w = makeWindow({ ...base, device: iPhone });
  assert.equal(run(w, surface), JSON.stringify(['iPhone', 5, 4, 'en-US', ['en-US'], 'undefined', 390, 844, 390, 844, 3]));
  assert.equal(run(w, `navigator.standalone`), false);
  // No own properties appear; the getters look like native ones.
  assert.deepEqual(Array.from(run(w, `Object.getOwnPropertyNames(navigator)`)).sort(), ['geolocation', 'permissions']);
  assert.deepEqual(Array.from(run(w, `Object.getOwnPropertyNames(screen)`)), []);
  assert.equal(run(w, `Object.getOwnPropertyDescriptor(Navigator.prototype, 'platform').get.name`), 'get platform');
  const enumerable = `Object.getOwnPropertyDescriptor(Navigator.prototype, 'platform').enumerable`;
  assert.equal(run(w, enumerable), run(makeWindow(base), enumerable)); // as the engine defines it
  assert.equal(run(w, `Object.getOwnPropertyDescriptor(Screen.prototype, 'width').get.name`), 'get width');
  assert.equal(run(w, `typeof Object.getOwnPropertyDescriptor(window, 'devicePixelRatio').get`), 'function');
});

test('no rendering patches: canvas, audio and fonts stay native', () => {
  for (const config of [base, { ...base, device: iPhone }]) {
    const w = makeWindow(config);
    assert.equal(run(w, `HTMLCanvasElement.prototype.getContext.toString().includes('return null')`), true);
    assert.equal(run(w, `HTMLCanvasElement.prototype.toDataURL.toString().includes("'data:'")`), true);
    assert.equal(run(w, `AudioContext.prototype.createAnalyser.toString().includes('return {}')`), true);
  }
  assert.doesNotMatch(body, /getImageData|createAnalyser|document\.fonts|deviceMemory\s*['",]/);
});

process.on('beforeExit', () => {
  if (failures) { console.log(`${failures} failure(s)`); process.exitCode = 1; }
  else console.log('all shim tests passed');
});
