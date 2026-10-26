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
    class Navigator { get language() { return 'en-US'; } get languages() { return ['en-US']; } }
    var navigator = Object.assign(new Navigator(), { geolocation: new Geolocation(), permissions: new Permissions() });
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

test('locale: navigator.language(s) follow the profile, only the primary language', () => {
  const w = makeWindow({ ...base, locale: 'de-DE' });
  assert.equal(run(w, `navigator.language`), 'de-DE');
  assert.deepEqual(Array.from(run(w, `navigator.languages`)), ['de-DE']);
  assert.equal(run(w, `Object.isFrozen(navigator.languages)`), true);
  // Patched on the prototype, like the native accessor; no own property on the instance.
  assert.equal(run(w, `Object.prototype.hasOwnProperty.call(navigator, 'language')`), false);
});

test('locale: Intl defaults and toLocale*String', () => {
  const w = makeWindow({ ...base, locale: 'de-DE' });
  assert.equal(run(w, `Intl.DateTimeFormat().resolvedOptions().locale`), 'de-DE');
  assert.equal(run(w, `new Intl.NumberFormat().format(1234567.891)`), new Intl.NumberFormat('de-DE').format(1234567.891));
  assert.equal(run(w, `(1234.5).toLocaleString()`), (1234.5).toLocaleString('de-DE'));
  assert.equal(run(w, `new Date(Date.UTC(2024, 0, 15, 12)).toLocaleDateString(undefined, { timeZone: 'UTC' })`),
               new Date(Date.UTC(2024, 0, 15, 12)).toLocaleDateString('de-DE', { timeZone: 'UTC' }));
  assert.equal(run(w, `new Intl.PluralRules().resolvedOptions().locale`), new Intl.PluralRules('de-DE').resolvedOptions().locale);
  assert.equal(run(w, `'a'.localeCompare('ä')`), 'a'.localeCompare('ä', 'de-DE'));
  // Explicit locales still win.
  assert.equal(run(w, `new Intl.NumberFormat('en-US').format(1234.5)`), '1,234.5');
  assert.equal(run(w, `new Intl.NumberFormat() instanceof Intl.NumberFormat`), true);
  assert.equal(run(w, `Intl.NumberFormat.name + Intl.NumberFormat.length`), 'NumberFormat0');
});

test('locale: constructors that require new still throw without it', () => {
  const w = makeWindow({ ...base, locale: 'fr-FR' });
  assert.throws(() => run(w, `Intl.PluralRules()`), (e) => e.name === 'TypeError'); // error from the vm realm
  assert.equal(run(w, `Intl.Collator().resolvedOptions().locale`), new Intl.Collator('fr-FR').resolvedOptions().locale);
});

test('locale and time zone together', () => {
  const w = makeWindow({ ...base, timeZone: 'Asia/Tokyo', locale: 'ja-JP' });
  const opts = { dateStyle: 'medium', timeStyle: 'short' };
  assert.equal(run(w, `new Date('2024-01-15T12:00:00Z').toLocaleString(undefined, ${JSON.stringify(opts)})`),
               new Date('2024-01-15T12:00:00Z').toLocaleString('ja-JP', { ...opts, timeZone: 'Asia/Tokyo' }));
  const resolved = run(w, `Intl.DateTimeFormat().resolvedOptions()`);
  assert.equal(resolved.locale, 'ja-JP');
  assert.equal(resolved.timeZone, 'Asia/Tokyo');
});

test('no locale configured → untouched', () => {
  const w = makeWindow({ ...base });
  assert.equal(run(w, `navigator.language`), 'en-US');
  assert.equal(run(w, `Intl.NumberFormat`), run(w, `Intl.NumberFormat`));
  assert.equal(run(w, `Intl.NumberFormat.toString().includes('native code')`), true);
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

process.on('beforeExit', () => {
  if (failures) { console.log(`${failures} failure(s)`); process.exitCode = 1; }
  else console.log('all shim tests passed');
});
