// Tests the JavaScript privacy shims embedded in PrivacyScripts.swift under Node.js
// (V8 + full ICU). This checks the shim logic; it does not prove behaviour inside
// WebKit/JavaScriptCore — the self-test's "surface" checks do that against real WebKit.
//
//   TZ=America/New_York node scripts/test-shims.mjs
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const swift = readFileSync(new URL('../Sources/PrivacyBrowser/Browser/PrivacyScripts.swift', import.meta.url), 'utf8');
const body = swift.split('static let shimBody = #"""')[1].split('"""#')[0];

// A realm shaped like a WebKit window: navigator and screen values are accessors on the
// prototypes that reject other receivers; window attributes are own accessors.
function makeWindow(config, parentContext) {
  const context = vm.createContext({});
  vm.runInContext(`
    var window = globalThis;
    const illegal = (o, C) => { if (!(o instanceof C)) throw new TypeError('illegal invocation'); };
    class Geolocation { getCurrentPosition() { illegal(this, Geolocation); throw new Error('native called'); } watchPosition() { illegal(this, Geolocation); } clearWatch() { illegal(this, Geolocation); } }
    class Permissions { query(d) { illegal(this, Permissions); return Promise.resolve({ state: 'prompt', name: d.name }); } }
    globalThis.Geolocation = Geolocation; globalThis.Permissions = Permissions;
    class Navigator {
      get platform() { illegal(this, Navigator); return 'MacIntel'; } get maxTouchPoints() { illegal(this, Navigator); return 0; }
      get hardwareConcurrency() { illegal(this, Navigator); return 8; }
      get language() { illegal(this, Navigator); return 'en-US'; } get languages() { illegal(this, Navigator); return ['en-US']; }
    }
    var navigator = Object.assign(Object.create(Navigator.prototype), { geolocation: new Geolocation(), permissions: new Permissions() });
    class Screen { get width() { illegal(this, Screen); return 1728; } get height() { illegal(this, Screen); return 1117; }
                   get availWidth() { illegal(this, Screen); return 1728; } get availHeight() { illegal(this, Screen); return 1079; } }
    var screen = new Screen();
    Object.defineProperty(globalThis, 'devicePixelRatio', { get() { return 2; }, set(v) {}, enumerable: true, configurable: true });
    Object.defineProperty(globalThis, 'outerWidth', { get() { return 1200; }, set(v) {}, enumerable: true, configurable: true });
    Object.defineProperty(globalThis, 'outerHeight', { get() { return 820; }, set(v) {}, enumerable: true, configurable: true });
    var setTimeout = (f) => Promise.resolve().then(f);
    globalThis.RTCPeerConnection = class RTCPeerConnection { constructor(c) { this.config = c; } setConfiguration(c) { illegal(this, RTCPeerConnection); this.config = c; } };
    globalThis.webkitRTCPeerConnection = globalThis.RTCPeerConnection;
    globalThis.RTCDataChannel = function () {};
    Object.defineProperty(globalThis, 'open', { value: function open() { if (this !== globalThis) throw new TypeError('illegal invocation'); return null; },
                                                writable: true, enumerable: true, configurable: true });
    class HTMLCanvasElement { getContext() { return null; } toDataURL() { return 'data:'; } }
    class AudioContext { createAnalyser() { return {}; } }
  `, context);
  // Browsers expose the realm's constructors on the window; a vm sandbox does not by itself.
  context.Function = vm.runInContext('Function', context);
  context.parent = parentContext || context;
  context.top = parentContext ? parentContext.top : context;
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
const nativeText = (name) => run(makeWindow({ geolocation: { mode: 'deny' }, webRTC: 'unrestricted' }),
                                 'Function.prototype.toString.call(Array.prototype.push)').replace('push', name);

const base = { geolocation: { mode: 'deny' }, webRTC: 'disabled' };

// ---- Time zone: values -------------------------------------------------------------------------
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
    assert.equal(run(w, `Intl.DateTimeFormat().resolvedOptions().timeZone`), new Intl.DateTimeFormat('en', { timeZone: zone }).resolvedOptions().timeZone);
    const expectedLocal = new Intl.DateTimeFormat('en-US', { timeZone: zone, dateStyle: 'full', timeStyle: 'long' }).format(new Date(iso));
    assert.equal(run(w, `new Date('${iso}').toLocaleString('en-US', { dateStyle: 'full', timeStyle: 'long' })`), expectedLocal);
    const s = run(w, `new Date('${iso}').toString()`);
    const minutesEast = -offset;
    const sign = minutesEast >= 0 ? '+' : '-';
    const hh = String(Math.floor(Math.abs(minutesEast) / 60)).padStart(2, '0');
    const mm = String(Math.abs(minutesEast) % 60).padStart(2, '0');
    assert.match(s, new RegExp(` ${String(hour).padStart(2, '0')}:\\d\\d:\\d\\d GMT\\${sign}${hh}${mm} \\(`));
    // Parsing toString's output gives the same instant back (CreepJS: Date.parse(new Date()) round trip).
    assert.equal(run(w, `(() => { const d = new Date('${iso}'); return +new Date(Date.parse(String(d))) === Math.floor(+d / 1000) * 1000; })()`), true);
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

test('local constructor, Date.parse and setters work in the profile zone', () => {
  const w = makeWindow({ ...base, timeZone: 'Asia/Tokyo' });
  // new Date(y, m, d, h) means Tokyo wall time: 2024-01-15 12:00 JST = 03:00Z.
  assert.equal(run(w, `new Date(2024, 0, 15, 12).toISOString()`), '2024-01-15T03:00:00.000Z');
  assert.equal(run(w, `new Date(2024, 0, 15, 12).getHours()`), 12);
  assert.equal(run(w, `new Date(99, 0, 1).getFullYear()`), 1999);
  assert.equal(run(w, `new Date(2024, 0).getDate()`), 1);
  assert.ok(Number.isNaN(run(w, `+new Date(2024, NaN)`)));
  // Strings without an offset are local; with one, absolute; ISO date-only is UTC.
  assert.equal(run(w, `new Date('2024-01-15T12:00:00').toISOString()`), '2024-01-15T03:00:00.000Z');
  assert.equal(run(w, `new Date('January 15, 2024 12:00:00').toISOString()`), '2024-01-15T03:00:00.000Z');
  assert.equal(run(w, `Date.parse('1/15/2024')`), Date.UTC(2024, 0, 14, 15));
  assert.equal(run(w, `new Date('2024-01-15T12:00:00Z').toISOString()`), '2024-01-15T12:00:00.000Z');
  assert.equal(run(w, `new Date('2024-01-15T12:00:00+01:00').toISOString()`), '2024-01-15T11:00:00.000Z');
  assert.equal(run(w, `new Date('Mon Jan 15 2024 12:00:00 GMT+0100 (Central European Standard Time)').toISOString()`), '2024-01-15T11:00:00.000Z');
  assert.equal(run(w, `new Date('2024-01-15').toISOString()`), '2024-01-15T00:00:00.000Z');
  assert.equal(run(w, `new Date('15 Jan 2024 12:00 UTC').toISOString()`), '2024-01-15T12:00:00.000Z');
  // Setters change the Tokyo wall clock.
  assert.equal(run(w, `(() => { const d = new Date('2024-01-15T03:00:00Z'); d.setHours(0); return d.toISOString(); })()`), '2024-01-14T15:00:00.000Z');
  assert.equal(run(w, `(() => { const d = new Date('2024-01-15T03:00:00Z'); d.setDate(1); return d.getDate() + '/' + d.getHours(); })()`), '1/12');
  assert.equal(run(w, `(() => { const d = new Date('2024-01-15T03:00:00Z'); d.setFullYear(2020, 5, 30); return d.toISOString(); })()`), '2020-06-30T03:00:00.000Z');
  assert.equal(run(w, `(() => { const d = new Date('2024-01-15T03:00:00Z'); d.setMinutes(30, 15, 500); return d.toISOString(); })()`), '2024-01-15T03:30:15.500Z');
  assert.equal(run(w, `(() => { const d = new Date(NaN); d.setHours(1); return String(d); })()`), 'Invalid Date');
  assert.equal(run(w, `(() => { const d = new Date(NaN); d.setFullYear(2024); return d.getFullYear(); })()`), 2024);
  assert.equal(run(w, `(() => { const d = new Date('2024-01-15T03:00:00Z'); d.setYear(99); return d.getFullYear() + '/' + d.getYear(); })()`), '1999/99');
  // Round trips CreepJS runs: setHours(x) → getHours() == x; new Date('07/01/1970') is midnight.
  assert.equal(run(w, `(() => { const d = new Date(); d.setHours(7); d.setMinutes(8); d.setSeconds(9); return [d.getHours(), d.getMinutes(), d.getSeconds()].join(); })()`), '7,8,9');
  assert.equal(run(w, `(() => { const d = new Date('07/01/1970'); return [d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds()].join(); })()`), '0,0,0,0');
  assert.equal(run(w, `new Date(1e25).toString()`), 'Invalid Date');
  assert.equal(run(w, `(() => { const d = new Date(); return +d === d.getTime() && d.getTime() === d.valueOf(); })()`), true);
});

test('pre-standard-time offsets keep seconds, as the engine does', () => {
  // Europe/Berlin local mean time: +00:53:28 → the offset is not a whole number of minutes.
  const w = makeWindow({ ...base, timeZone: 'Europe/Berlin' });
  const offset = run(w, `new Date('1113-07-01T12:00:00Z').getTimezoneOffset()`);
  assert.ok(Math.abs(offset - (-53 - 28 / 60)) < 1e-6, `offset ${offset}`);
  // CreepJS: the local-parsed and the ISO-parsed date differ by exactly the zone's offset.
  const measured = run(w, `(+new Date('7/1/1113') - +new Date('1113-07-01')) / 60000`);
  assert.ok(Math.abs(measured - offset) < 1e-6, `measured ${measured} vs ${offset}`);
  assert.equal(new Date('1113-07-01T00:00:00Z').getTime(), run(w, `+new Date('1113-07-01')`));
});

test('invalid dates stay invalid', () => {
  const w = makeWindow({ ...base, timeZone: 'Asia/Tokyo' });
  assert.equal(run(w, `new Date(NaN).toString()`), 'Invalid Date');
  assert.ok(Number.isNaN(run(w, `new Date(NaN).getHours()`)));
  assert.ok(Number.isNaN(run(w, `new Date(NaN).getTimezoneOffset()`)));
  assert.ok(Number.isNaN(run(w, `Date.parse('not a date')`)));
});

test('explicit timeZone option is respected', () => {
  const w = makeWindow({ ...base, timeZone: 'Asia/Tokyo' });
  assert.equal(run(w, `new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', hour: 'numeric', hourCycle: 'h23' }).format(new Date('2024-01-01T05:00:00Z'))`), '05');
  assert.equal(run(w, `new Intl.DateTimeFormat() instanceof Intl.DateTimeFormat`), true);
  assert.equal(run(w, `Intl.DateTimeFormat().resolvedOptions().timeZone`), 'Asia/Tokyo');
  assert.equal(run(w, `Intl.DateTimeFormat.prototype.constructor === Intl.DateTimeFormat`), true);
});

test('no time zone configured → Date untouched', () => {
  const w = makeWindow({ ...base });
  assert.equal(run(w, `new Date('2024-01-15T12:00:00Z').getTimezoneOffset()`), new Date('2024-01-15T12:00:00Z').getTimezoneOffset());
  assert.equal(run(w, `Date.toString()`), nativeText('Date'));
});

// ---- Looks native (what CreepJS inspects) --------------------------------------------------
// Each wrapper: `length` and `name` only, no prototype, not constructible, caller/arguments throw,
// prints as native code — also through the Function.prototype.toString of another frame.
const probeLies = `
(function (apiFunction, scopeToString, Interface, name) {
  const lies = [];
  const known = (n) => ['function ' + n + '() { [native code] }', 'function get ' + n + '() { [native code] }',
    'function ' + n + '() {\\n    [native code]\\n}', 'function get ' + n + '() {\\n    [native code]\\n}'];
  const nameOnly = apiFunction.name.replace(/get\\s/, '');
  const isTypeError = (f) => { try { f(); return false; } catch (e) { return e instanceof TypeError || e.constructor.name === 'TypeError'; } };
  if (Interface && name) {
    if (!isTypeError(() => Interface.prototype[name])) lies.push('failed illegal error');
    if (/^(screen|navigator)$/i.test(Interface.name) && Object.getOwnPropertyDescriptor(Interface === Navigator ? navigator : screen, name) !== undefined) lies.push('failed undefined properties');
  }
  if (Interface && !isTypeError(() => { apiFunction.call(Interface.prototype); })) lies.push('failed call interface error');
  if (!isTypeError(() => { new apiFunction(); })) lies.push('failed new instance error');
  if (!isTypeError(() => { const p = Object.getPrototypeOf(apiFunction); try { Object.setPrototypeOf(apiFunction, null).toString(); } finally { Object.setPrototypeOf(apiFunction, p); } })) lies.push('failed null conversion error');
  if (!known(nameOnly).includes(scopeToString.call(apiFunction))) lies.push('failed toString: ' + scopeToString.call(apiFunction));
  if (!known('toString').includes(scopeToString.call(apiFunction.toString))) lies.push('failed toString of toString');
  if ('prototype' in apiFunction) lies.push('failed "prototype" in function');
  for (const k of ['arguments', 'caller', 'prototype', 'toString']) if (Object.getOwnPropertyDescriptor(apiFunction, k) !== undefined) lies.push('failed descriptor ' + k);
  if (Object.getOwnPropertyNames(apiFunction).sort().toString() !== 'length,name') lies.push('failed own property names: ' + Object.getOwnPropertyNames(apiFunction));
  if (Reflect.ownKeys(apiFunction).sort().toString() !== 'length,name') lies.push('failed own keys');
  if (!isTypeError(() => { Object.create(apiFunction).toString(); })) lies.push('failed object toString error');
  if (!isTypeError(() => { Object.create(new Proxy(apiFunction, {})).toString(); })) lies.push('failed proxy object toString error');
  if (!isTypeError(() => { apiFunction.arguments; apiFunction.caller; })) lies.push('failed at incompatible proxy error');
  if (!isTypeError(() => { apiFunction.toString.arguments; apiFunction.toString.caller; })) lies.push('failed at toString incompatible proxy error');
  if (!isTypeError(() => { Object.setPrototypeOf(apiFunction, Object.create(apiFunction)).toString(); })) lies.push('failed at too much recursion error');
  try { Reflect.setPrototypeOf(apiFunction, Object.create(apiFunction)); ('x' in apiFunction); throw new TypeError(); } catch (e) { if (!(e instanceof TypeError)) lies.push('failed at reflect set proto'); }
  return lies;
})`;
const iPhone = { platform: 'iPhone', maxTouchPoints: 5, hardwareConcurrency: 4, screenWidth: 390, screenHeight: 844, devicePixelRatio: 3 };
const everything = { geolocation: { mode: 'fixed', latitude: 1, longitude: 2, accuracy: 3 }, webRTC: 'relayOnly', timeZone: 'Europe/Berlin', device: iPhone };
const wrappers = [
  ['Function.prototype.toString'], ['Date.prototype.getTimezoneOffset', 'Date'], ['Date.prototype.getHours', 'Date'],
  ['Date.prototype.setHours', 'Date'], ['Date.prototype.setFullYear', 'Date'], ['Date.prototype.toString', 'Date'],
  ['Date.prototype.toDateString', 'Date'], ['Date.prototype.toLocaleString', 'Date'], ['Date.prototype.getYear', 'Date'], ['Date.parse'],
  ['Object.getOwnPropertyDescriptor(Navigator.prototype, "platform").get', 'Navigator', 'platform'],
  ['Object.getOwnPropertyDescriptor(Navigator.prototype, "hardwareConcurrency").get', 'Navigator', 'hardwareConcurrency'],
  ['Object.getOwnPropertyDescriptor(Navigator.prototype, "maxTouchPoints").get', 'Navigator', 'maxTouchPoints'],
  ['Object.getOwnPropertyDescriptor(Navigator.prototype, "standalone").get', 'Navigator', 'standalone'],
  ['Object.getOwnPropertyDescriptor(Screen.prototype, "width").get', 'Screen', 'width'],
  ['Object.getOwnPropertyDescriptor(Screen.prototype, "availHeight").get', 'Screen', 'availHeight'],
  ['Object.getOwnPropertyDescriptor(window, "devicePixelRatio").get'], ['Object.getOwnPropertyDescriptor(window, "outerHeight").get'],
  ['Object.getPrototypeOf(navigator.geolocation).getCurrentPosition', 'Geolocation'],
  ['Object.getPrototypeOf(navigator.geolocation).watchPosition', 'Geolocation'],
  ['Object.getPrototypeOf(navigator.permissions).query', 'Permissions'],
  ['RTCPeerConnection.prototype.setConfiguration', 'RTCPeerConnection'], ['window.open'],
];
test('wrappers look native, from the window and from a frame', () => {
  const top = makeWindow(everything);
  const frame = makeWindow(everything, top);
  top.frameToString = vm.runInContext('Function.prototype.toString', frame);
  for (const scope of ['Function.prototype.toString', 'frameToString']) {
    for (const [expr, iface, name] of wrappers) {
      const lies = run(top, `${probeLies}(${expr}, ${scope}, ${iface || 'null'}, ${name ? JSON.stringify(name) : 'null'})`);
      assert.deepEqual(Array.from(lies), [], `${expr} via ${scope}`);
    }
  }
  // A frame's own wrappers print as native through the top's toString too.
  assert.equal(run(top, `Function.prototype.toString.call(frameToString)`), nativeText('toString'));
  assert.equal(run(frame, `Function.prototype.toString.call(top.Date)`), nativeText('Date'));
});

test('constructor-shaped wrappers keep the native shape', () => {
  const w = makeWindow(everything);
  assert.equal(run(w, 'Date.toString()'), nativeText('Date'));
  assert.equal(run(w, 'Date.length + Date.name'), '7Date');
  // Own properties in the engine's own order (Safari: statics, then length, name, prototype).
  assert.equal(run(w, 'Object.getOwnPropertyNames(Date).join()'), 'parse,UTC,now,length,name,prototype');
  assert.equal(run(w, 'Object.getOwnPropertyNames(Intl.DateTimeFormat).join()'), 'supportedLocalesOf,length,name,prototype');
  assert.equal(run(w, 'Object.getOwnPropertyNames(Date.prototype.getHours).join()'), 'length,name');
  assert.equal(run(w, 'Object.getOwnPropertyNames(Object.getOwnPropertyDescriptor(Screen.prototype, "width").get).join()'), 'length,name');
  assert.equal(run(w, 'Object.getPrototypeOf(Date) === Function.prototype && typeof Date === "function"'), true);
  assert.equal(run(w, 'Object.getOwnPropertyDescriptor(Date, "prototype").writable'), false);
  assert.equal(run(w, 'Date.prototype.constructor === Date && new Date() instanceof Date && Object.getPrototypeOf(new Date()) === Date.prototype'), true);
  assert.equal(run(w, 'class D extends Date {}; new D(2024, 0, 1) instanceof D && new D(2024, 0, 1).getFullYear() === 2024'), true);
  assert.equal(run(w, 'new Date() == Date()'), true);
  assert.equal(run(w, 'Intl.DateTimeFormat.toString()'), nativeText('DateTimeFormat'));
  assert.equal(run(w, 'Intl.DateTimeFormat.name + Intl.DateTimeFormat.length'), 'DateTimeFormat0');
  assert.equal(run(w, 'new Intl.DateTimeFormat("en-US", { timeZone: "UTC" }).resolvedOptions().timeZone'), 'UTC');
  assert.equal(run(w, 'class F extends Intl.DateTimeFormat {}; new F() instanceof F && new F().resolvedOptions().timeZone === "Europe/Berlin"'), true);
  assert.equal(run(w, 'RTCPeerConnection.toString()'), nativeText('RTCPeerConnection'));
  assert.equal(run(w, 'RTCPeerConnection.name + RTCPeerConnection.length'), 'RTCPeerConnection0');
  assert.equal(run(w, 'new RTCPeerConnection() instanceof RTCPeerConnection && RTCPeerConnection.prototype.constructor === RTCPeerConnection'), true);
});

test('nothing is left on the window and instances', () => {
  const w = makeWindow(everything);
  assert.equal(run(w, 'Object.getOwnPropertyNames(navigator).sort().join()'), 'geolocation,permissions');
  assert.equal(run(w, 'Object.getOwnPropertyNames(screen).join()'), '');
  assert.equal(run(w, 'Object.getOwnPropertySymbols(window).length'), 0);
  assert.equal(run(w, 'Object.getOwnPropertyDescriptor(window, "open").enumerable'), true);
  assert.equal(run(w, 'Object.getOwnPropertyDescriptor(window, "Date").enumerable'), false);
  // Calling toString with the registry key from a page is the only way in; it is not a property.
  assert.equal(run(w, 'typeof Function.prototype.toString.call(Symbol.for("wk.shim.registry"))'), 'object');
});

// ---- Device values ---------------------------------------------------------------------------
const surface = `JSON.stringify([navigator.platform, navigator.maxTouchPoints, navigator.hardwareConcurrency, navigator.language,
  Array.from(navigator.languages), typeof navigator.deviceMemory, screen.width, screen.height, screen.availWidth, screen.availHeight,
  devicePixelRatio, outerWidth, outerHeight])`;

test('macOS profile: navigator, screen and window keep their native values', () => {
  const w = makeWindow(base);
  assert.equal(run(w, surface), JSON.stringify(['MacIntel', 0, 8, 'en-US', ['en-US'], 'undefined', 1728, 1117, 1728, 1079, 2, 1200, 820]));
  // Untouched: still the harness's own getter.
  assert.equal(run(w, `Object.getOwnPropertyDescriptor(Navigator.prototype, 'platform').get.toString().includes("illegal(this, Navigator)")`), true);
});

test('iPhone profile: device values, as getters on the prototypes', () => {
  const w = makeWindow({ ...base, device: iPhone });
  assert.equal(run(w, surface), JSON.stringify(['iPhone', 5, 4, 'en-US', ['en-US'], 'undefined', 390, 844, 390, 844, 3, 390, 844]));
  assert.equal(run(w, `navigator.standalone`), false);
  // Printed as JavaScriptCore prints a DOM accessor: without the "get " prefix.
  assert.equal(run(w, `Object.getOwnPropertyDescriptor(Navigator.prototype, 'platform').get.toString()`), nativeText('platform'));
  assert.equal(run(w, `Object.getOwnPropertyDescriptor(Navigator.prototype, 'platform').get.name`), 'get platform');
  assert.throws(() => run(w, `Navigator.prototype.standalone`), (e) => e.name === 'TypeError');
  assert.throws(() => run(w, `Screen.prototype.width`), (e) => e.name === 'TypeError');
});

test('no rendering patches: canvas, audio and fonts stay native', () => {
  for (const config of [base, { ...base, device: iPhone }]) {
    const w = makeWindow(config);
    assert.equal(run(w, `HTMLCanvasElement.prototype.getContext.toString().includes('return null')`), true);
    assert.equal(run(w, `AudioContext.prototype.createAnalyser.toString().includes('return {}')`), true);
  }
  assert.doesNotMatch(body, /getImageData|createAnalyser|document\.fonts|deviceMemory/);
});

test('window.safari for the macOS generation only', () => {
  const w = makeWindow({ ...base, safariObject: true });
  assert.equal(run(w, `typeof safari + '|' + Object.prototype.toString.call(safari) + '|' + Object.getOwnPropertyNames(safari).join()`), 'object|[object Object]|pushNotification');
  assert.equal(run(w, `String(safari.pushNotification)`), '[object SafariRemoteNotification]');
  assert.equal(run(w, `safari.pushNotification.permission('web.example').permission`), 'default');
  assert.equal(run(w, `safari.pushNotification.permission.toString()`), nativeText('permission'));
  const mobile = makeWindow({ ...base, device: iPhone });
  assert.equal(run(mobile, `'safari' in window`), false);
});

// ---- Geolocation, WebRTC ---------------------------------------------------------------------
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

test('WebRTC disabled: removed without a trace', () => {
  const w = makeWindow(base);
  assert.equal(run(w, `typeof RTCPeerConnection`), 'undefined');
  assert.equal(run(w, `typeof webkitRTCPeerConnection`), 'undefined');
  assert.equal(run(w, `'RTCPeerConnection' in window`), false);
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
