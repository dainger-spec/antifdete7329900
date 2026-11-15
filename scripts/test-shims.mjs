// Tests the JavaScript privacy shims embedded in PrivacyScripts.swift under Node.js
// (V8 + full ICU). This checks the shim logic; it does not prove behaviour inside
// WebKit/JavaScriptCore — the self-test's "surface" checks do that against real WebKit.
// At its end: the scenario recorder's page side (ScenarioRecorderScript.swift) on a stub DOM.
//
//   TZ=America/New_York node scripts/test-shims.mjs
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const swift = readFileSync(new URL('../Sources/PrivacyBrowser/Browser/PrivacyScripts.swift', import.meta.url), 'utf8');
const body = swift.split('static let shimBody = #"""')[1].split('"""#')[0];

// What the engine knows of its own objects whatever their realm: a WebIDL receiver check accepts a
// platform object of the right interface from any frame (WebKit: jsDynamicCast), not only one of the
// function's own realm. Shared by every window made here, for the interfaces whose checks a test
// calls across frames (RTCPeerConnection, MediaDevices).
const engineObjects = new WeakSet();

// A realm shaped like a WebKit window: navigator and screen values are accessors on the
// prototypes that reject other receivers; window attributes are own accessors.
function makeWindow(config, parentContext, prelude) {
  const context = vm.createContext({});
  // Taken by the realm's code and the prelude, and gone before the shim installs.
  Object.defineProperty(context, '__engineObjects', { value: engineObjects, configurable: true });
  vm.runInContext(`
    var window = globalThis;
    const illegal = (o, C) => { if (!(o instanceof C)) throw new TypeError('illegal invocation'); };
    const engineObjects = globalThis.__engineObjects;
    const branded = (o) => { if (!engineObjects.has(o)) throw new TypeError('illegal invocation'); };
    class Geolocation { getCurrentPosition() { illegal(this, Geolocation); throw new Error('native called'); } watchPosition() { illegal(this, Geolocation); } clearWatch() { illegal(this, Geolocation); } }
    // As WebKit shapes them: values behind prototype getters that reject other receivers.
    const slots = new WeakMap();
    const iface = (name, keys) => {
      const C = { [name]: class { constructor() { throw new TypeError('Illegal constructor'); } } }[name];
      for (const k of keys) Object.defineProperty(C.prototype, k, { get() { illegal(this, C); return slots.get(this)[k]; }, enumerable: true, configurable: true });
      return C;
    };
    const make = (C, values) => { const o = Object.create(C.prototype); slots.set(o, values); return o; };
    globalThis.GeolocationCoordinates = iface('GeolocationCoordinates', ['latitude', 'longitude', 'altitude', 'accuracy', 'altitudeAccuracy', 'heading', 'speed']);
    GeolocationCoordinates.prototype.toJSON = function toJSON() { illegal(this, GeolocationCoordinates); return {}; };
    globalThis.GeolocationPosition = iface('GeolocationPosition', ['coords', 'timestamp']);
    GeolocationPosition.prototype.toJSON = function toJSON() { illegal(this, GeolocationPosition); return {}; };
    globalThis.GeolocationPositionError = iface('GeolocationPositionError', ['code', 'message']);
    globalThis.PermissionStatus = iface('PermissionStatus', ['state', 'name']);
    PermissionStatus.prototype.dispatchEvent = function dispatchEvent() { return true; };
    class Permissions { query(d) { illegal(this, Permissions); return Promise.resolve(make(PermissionStatus, { state: 'prompt', name: d.name })); } }
    class StorageManager { estimate() { illegal(this, StorageManager); return Promise.resolve({ quota: 1048576000, usage: 1234 }); } }
    globalThis.StorageManager = StorageManager;
    globalThis.Geolocation = Geolocation; globalThis.Permissions = Permissions;
    globalThis.Event = class Event { constructor(type) { this.type = type; } };
    globalThis.WeakRef = WeakRef;
    // Blob workers, as far as hookWorkers reaches them: a Blob, URL.createObjectURL and a Worker
    // that keeps the URL it was given.
    // The parts are converted as a WebIDL sequence (through their @@iterator), and each URL's Blob is
    // kept where only the engine (a test) reads it.
    globalThis.Blob = class Blob { constructor(parts, options) { this.parts = []; for (const part of parts) this.parts.push(part); this.type = (options && options.type) || ''; } };
    let blobCount = 0;
    globalThis.URL = class URL { static createObjectURL(blob) { const url = 'blob:test/' + (++blobCount); engine.blobs.set(url, blob); return url; } };
    globalThis.Worker = class Worker { constructor(url) { this.url = String(url); } };
    class Navigator {
      get platform() { illegal(this, Navigator); return 'MacIntel'; } get maxTouchPoints() { illegal(this, Navigator); return 0; }
      get hardwareConcurrency() { illegal(this, Navigator); return 8; }
      get language() { illegal(this, Navigator); return 'en-US'; } get languages() { illegal(this, Navigator); return ['en-US']; }
    }
    var navigator = Object.assign(Object.create(Navigator.prototype), { geolocation: new Geolocation(), permissions: new Permissions(), storage: new StorageManager() });
    class Screen { get width() { illegal(this, Screen); return 1728; } get height() { illegal(this, Screen); return 1117; }
                   get availWidth() { illegal(this, Screen); return 1728; } get availHeight() { illegal(this, Screen); return 1079; } }
    var screen = new Screen();
    Object.defineProperty(globalThis, 'devicePixelRatio', { get() { return 2; }, set(v) {}, enumerable: true, configurable: true });
    Object.defineProperty(globalThis, 'outerWidth', { get() { return 1200; }, set(v) {}, enumerable: true, configurable: true });
    Object.defineProperty(globalThis, 'outerHeight', { get() { return 820; }, set(v) {}, enumerable: true, configurable: true });
    var setTimeout = (f) => Promise.resolve().then(f);
    // As WebKit: the configuration is converted as a WebIDL dictionary (members read with [[Get]] in
    // lexicographic order, sequences through their @@iterator), iceServers are validated (TypeError
    // without urls, SyntaxError for a URL that is not stun/turn) and reported back by
    // getConfiguration() as fresh objects. The engine's own built-ins are captured, as C++ is not
    // affected by what a page replaces.
    const NativeTypeError = TypeError, NativeSyntaxError = SyntaxError, nativeTest = RegExp.prototype.test;
    const NativeString = String, NativeNumber = Number, reflectApply = Reflect.apply, objectCreate = Object.create;
    // Engine-side values are null-prototype records: what a page puts on Object.prototype cannot touch them.
    const record = () => objectCreate(null);
    // A WebIDL sequence: whatever @@iterator the value has (the page's own, for a page's array).
    const sequence = (value) => { const items = []; for (const item of value) items[items.length] = item; return items; };
    const MEMBERS = ['bundlePolicy', 'certificates', 'iceCandidatePoolSize', 'iceServers', 'iceTransportPolicy', 'rtcpMuxPolicy'];
    const convertServer = (server) => {
      const urls = server.urls, credential = server.credential, username = server.username;
      if (urls === undefined) throw new NativeTypeError('Member RTCIceServer.urls is required');
      const list = typeof urls === 'string' ? [urls] : sequence(urls);
      for (let i = 0; i < list.length; i++) {
        if (!reflectApply(nativeTest, /^(stun|stuns|turn|turns):/, [NativeString(list[i])])) throw new NativeSyntaxError('Bad URL');
      }
      const converted = record();
      converted.urls = typeof urls === 'string' ? urls : list;
      if (username !== undefined) converted.username = NativeString(username);
      if (credential !== undefined) converted.credential = NativeString(credential);
      return converted;
    };
    const convert = (c) => {
      const out = record();
      if (c === undefined || c === null) return out;
      if (typeof c !== 'object' && typeof c !== 'function') throw new NativeTypeError('Type error');
      for (let m = 0; m < MEMBERS.length; m++) {
        const key = MEMBERS[m];
        const value = c[key];
        if (value === undefined) continue;
        if (key === 'iceServers') {
          const servers = sequence(value);
          const converted = [];
          for (let i = 0; i < servers.length; i++) converted[i] = convertServer(servers[i]);
          out.iceServers = converted;
        } else if (key === 'iceCandidatePoolSize') {
          const n = NativeNumber(value);
          if (!(n >= 0 && n <= 255)) throw new NativeTypeError('Value is outside the octet range');
          out[key] = n;
        } else {
          out[key] = key === 'certificates' ? sequence(value) : NativeString(value);
        }
      }
      return out;
    };
    globalThis.RTCStatsReport = class RTCStatsReport extends Map {};
    // What only the engine knows: every peer connection it made (a test reads it; pages never get it).
    const engine = { instances: [], added: [], resolved: [], blobs: new Map() };
    // As libwebrtc: a candidate's address that is a name (not IPv4, not IPv6) is resolved by this Mac.
    const resolveNamed = (line) => {
      const m = reflectApply(RegExp.prototype.exec, /^(?:a=)?candidate:\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s+(\\S+)/i, [line]);
      if (m && !reflectApply(nativeTest, /^[\\d.]+$|:/, [m[1]])) engine.resolved.push(m[1]);
    };
    Object.defineProperty(globalThis, '__engine', { value: engine });
    globalThis.RTCPeerConnection = class RTCPeerConnection {
      constructor(c) {
        this.config = convert(c); this.closed = false; this.gathered = this.config.iceCandidatePoolSize > 0;
        engineObjects.add(this);
        engine.instances.push(this);
      }
      setConfiguration(c) { branded(this); this.config = convert(c); }
      getConfiguration() {
        branded(this);
        const c = this.config, servers = [];
        for (let i = 0; c.iceServers && i < c.iceServers.length; i++) {
          const s = c.iceServers[i], copy = {};
          Object.defineProperty(copy, 'urls', { value: typeof s.urls === 'string' ? s.urls : [...s.urls], enumerable: true, writable: true, configurable: true });
          if (s.username !== undefined) Object.defineProperty(copy, 'username', { value: s.username, enumerable: true, writable: true, configurable: true });
          if (s.credential !== undefined) Object.defineProperty(copy, 'credential', { value: s.credential, enumerable: true, writable: true, configurable: true });
          servers[i] = copy;
        }
        const result = {};
        const own = (k, v) => Object.defineProperty(result, k, { value: v, enumerable: true, writable: true, configurable: true });
        own('bundlePolicy', 'balanced'); own('certificates', []); own('iceServers', servers);
        own('iceTransportPolicy', c.iceTransportPolicy || 'all'); own('rtcpMuxPolicy', 'require');
        return result;
      }
      close() { branded(this); this.closed = true; }
      get signalingState() { branded(this); return this.closed ? 'closed' : 'stable'; }
      get remoteDescription() { branded(this); return this.remote || null; }
      addIceCandidate(c) {
        branded(this);
        const invalid = () => { const e = new Error('InvalidStateError'); e.name = 'InvalidStateError'; return Promise.reject(e); };
        if (this.closed || !this.remote) return invalid();
        const line = c === undefined || c === null || c.candidate === undefined ? '' : NativeString(c.candidate);
        engine.added.push(line);
        resolveNamed(line);
        return Promise.resolve();
      }
      setRemoteDescription(d) {
        branded(this);
        const sdp = NativeString(d.sdp), type = NativeString(d.type);
        this.remote = { sdp, type };
        for (const line of sdp.split('\\n')) resolveNamed(line.trim());
        return Promise.resolve();
      }
      // As WebKit: a promise of a new maplike report each call, its entries plain objects.
      getStats() { branded(this); return Promise.resolve(report(this.stats)); }
    };
    const report = (stats) => new RTCStatsReport((stats || []).map(([id, entry]) => [id, Object.assign({}, entry)]));
    globalThis.RTCRtpSender = class RTCRtpSender {
      getStats() { illegal(this, RTCRtpSender); return Promise.resolve(report(this.stats)); }
    };
    globalThis.RTCPeerConnectionIceEvent = class RTCPeerConnectionIceEvent {
      constructor(type, init) { this.type = type; this._url = init.url; this.target = init.target; }
      get url() { illegal(this, RTCPeerConnectionIceEvent); return this._url; }
    };
    globalThis.webkitRTCPeerConnection = globalThis.RTCPeerConnection;
    engine.Native = globalThis.RTCPeerConnection;
    engine.methods = Object.getOwnPropertyNames(engine.Native.prototype).map((name) => {
      const d = Object.getOwnPropertyDescriptor(engine.Native.prototype, name);
      return d.value || d.get;
    });
    globalThis.RTCDataChannel = function () {};
    globalThis.RTCIceTransport = function () {};
    Object.defineProperty(globalThis, 'open', { value: function open() { if (this !== globalThis) throw new TypeError('illegal invocation'); return null; },
                                                writable: true, enumerable: true, configurable: true });
    class HTMLCanvasElement { getContext() { return null; } toDataURL() { return 'data:'; } }
    class AudioContext { createAnalyser() { return {}; } }
  `, context);
  // Browsers expose the realm's constructors on the window; a vm sandbox does not by itself.
  context.Function = vm.runInContext('Function', context);
  context.parent = parentContext || context;
  context.top = parentContext ? parentContext.top : context;
  // What a test adds to the realm before the shim installs (the camera's devices, below).
  if (prelude) vm.runInContext(prelude, context);
  vm.runInContext('delete globalThis.__engineObjects;', context);
  vm.runInContext(`(function install(CONFIG) {\n${body}\n})(${JSON.stringify(config)});`, context);
  return context;
}

const run = (w, code) => vm.runInContext(code, w);
// Bun runs JavaScriptCore, Safari's engine; Node runs V8.
const JSC = typeof Bun !== 'undefined';
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
  // One function made in the window and called with each instant, not a source of its own for
  // each: Bun 1.2.23's vm.runInContext returns, for about 6 in 100 000 sources it has not run, the
  // result of another it has — `(() => ${t})()` alone, no shim in the window (CI run 717; Bun 1.4.4
  // and Node: 0 in 100 000).
  const components = run(w, `(t) => { const d = new Date(t); return [d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getHours(), d.getMinutes(), d.getDay()]; }`);
  for (let i = 0; i < 500; i++) {
    const t = Math.floor(Math.random() * 2e12);
    const p = Object.fromEntries(fmt.formatToParts(new Date(t)).map((x) => [x.type, x.value]));
    const got = components(t);
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
const everything = { geolocation: { mode: 'fixed', latitude: 1, longitude: 2, accuracy: 3 }, webRTC: 'relayOnly', timeZone: 'Europe/Berlin', safariObject: true, storageQuota: 0.6 * 128 * 2 ** 30 };
const wrappers = [
  ['Function.prototype.toString'], ['Date.prototype.getTimezoneOffset', 'Date'], ['Date.prototype.getHours', 'Date'],
  ['Date.prototype.setHours', 'Date'], ['Date.prototype.setFullYear', 'Date'], ['Date.prototype.toString', 'Date'],
  ['Date.prototype.toDateString', 'Date'], ['Date.prototype.toLocaleString', 'Date'], ['Date.prototype.getYear', 'Date'], ['Date.parse'],
  ['Object.getPrototypeOf(navigator.geolocation).getCurrentPosition', 'Geolocation'],
  ['Object.getPrototypeOf(navigator.geolocation).watchPosition', 'Geolocation'],
  ['Object.getPrototypeOf(navigator.permissions).query', 'Permissions'],
  ['Object.getOwnPropertyDescriptor(PermissionStatus.prototype, "state").get', 'PermissionStatus', 'state'],
  ['StorageManager.prototype.estimate', 'StorageManager'],
  ['Object.getOwnPropertyDescriptor(GeolocationCoordinates.prototype, "latitude").get', 'GeolocationCoordinates', 'latitude'],
  ['Object.getOwnPropertyDescriptor(GeolocationPositionError.prototype, "code").get', 'GeolocationPositionError', 'code'],
  ['GeolocationPosition.prototype.toJSON', 'GeolocationPosition'],
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
  // JavaScriptCore lists a script function's length and name first whatever the order they were
  // defined in, so there the closest a replacement gets is length, name, statics, prototype.
  const order = (statics) => (JSC ? ['length', 'name', ...statics, 'prototype'] : [...statics, 'length', 'name', 'prototype']).join();
  assert.equal(run(w, 'Object.getOwnPropertyNames(Date).join()'), order(['parse', 'UTC', 'now']));
  assert.equal(run(w, 'Object.getOwnPropertyNames(Intl.DateTimeFormat).join()'), order(['supportedLocalesOf']));
  assert.equal(run(w, 'Object.getOwnPropertyNames(Date.prototype.getHours).join()'), 'length,name');
  assert.equal(run(w, 'Object.getOwnPropertyNames(Function.prototype.toString).join()'), 'length,name');
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
  assert.equal(run(w, 'Object.getOwnPropertyNames(navigator).sort().join()'), 'geolocation,permissions,storage');
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

test('a profile without the full phone disguise replaces no navigator, screen or window value', () => {
  // A Mac profile, the iPad view, and an iPhone view that leaves no script's trace (engineOnly):
  // the script has no phone to give, and touches none of the touch points, the platform or the screen.
  const w = makeWindow(everything);
  assert.equal(run(w, surface), JSON.stringify(['MacIntel', 0, 8, 'en-US', ['en-US'], 'undefined', 1728, 1117, 1728, 1079, 2, 1200, 820]));
  assert.equal(run(w, `'orientation' in window`), false);
});

const phone = { platform: 'iPhone', width: 402, height: 874, maxTouchPoints: 5 };
test('an iPhone view with the full disguise: the phone in the navigator, the screen and the window, through accessors as the engine makes them', () => {
  const w = makeWindow({ ...everything, safariObject: false, phone });
  // The pixel density is WebKit's own (PhoneEngine), not the script's: the realm's 2 stays.
  assert.equal(run(w, surface), JSON.stringify(['iPhone', 5, 8, 'en-US', ['en-US'], 'undefined', 402, 874, 402, 874, 2, 402, 874]));
  for (const [proto, name] of [['Navigator.prototype', 'platform'], ['Navigator.prototype', 'maxTouchPoints'], ['Screen.prototype', 'width'],
                               ['Screen.prototype', 'availHeight']]) {
    assert.equal(run(w, `Object.getOwnPropertyDescriptor(${proto}, '${name}').get.toString()`), nativeText(name), `${proto}.${name}`);
    assert.equal(run(w, `Object.getOwnPropertyNames(Object.getOwnPropertyDescriptor(${proto}, '${name}').get).join()`), 'length,name');
  }
  // The engine's receiver check is kept: the wrong receiver throws the engine's error.
  assert.equal(run(w, `try { Object.getOwnPropertyDescriptor(Navigator.prototype, 'maxTouchPoints').get.call({}); 'no error' } catch (e) { e.message }`),
               'illegal invocation');
  assert.equal(run(w, `Object.getOwnPropertyDescriptor(window, 'outerWidth').get.toString()`), nativeText('outerWidth'));
  // Held upright, as iOS says: window.orientation 0, with its event handler.
  assert.equal(run(w, `[window.orientation, 'onorientationchange' in window, Object.getOwnPropertyDescriptor(window, 'orientation').get.toString()].join('|')`),
               `0|true|${nativeText('orientation')}`);
});

test('no rendering patches: canvas, audio and fonts stay native', () => {
  for (const config of [base, everything]) {
    const w = makeWindow(config);
    assert.equal(run(w, `HTMLCanvasElement.prototype.getContext.toString().includes('return null')`), true);
    assert.equal(run(w, `AudioContext.prototype.createAnalyser.toString().includes('return {}')`), true);
  }
  assert.doesNotMatch(body, /getImageData|createAnalyser|document\.fonts|deviceMemory/);
});

test('window.safari, as Safari on the Mac exposes it', () => {
  const w = makeWindow({ ...base, safariObject: true });
  assert.equal(run(w, `typeof safari + '|' + Object.prototype.toString.call(safari) + '|' + Object.getOwnPropertyNames(safari).join()`), 'object|[object Object]|pushNotification');
  assert.equal(run(w, `String(safari.pushNotification)`), '[object SafariRemoteNotification]');
  assert.equal(run(w, `safari.pushNotification.permission('web.example').permission`), 'default');
  assert.equal(run(w, `safari.pushNotification.permission.toString()`), nativeText('permission'));
  // Without the setting (a configuration from before it was always on), none.
  assert.equal(run(makeWindow(base), `'safari' in window`), false);
});

// ---- Geolocation, WebRTC ---------------------------------------------------------------------
test('geolocation deny: prompt until asked, then a real-looking denial', async () => {
  const w = makeWindow(base);
  // WebKit: 'prompt' until the page has called getCurrentPosition/watchPosition (hasBeenRequested).
  assert.equal(await run(w, `navigator.permissions.query({ name: 'geolocation' }).then((s) => s.state)`), 'prompt');
  const error = await run(w, `new Promise((res) => navigator.geolocation.getCurrentPosition(() => res('success'), (e) => res(e)))`);
  assert.equal(run(w, 'GeolocationPositionError.prototype').isPrototypeOf(error), true);
  w.error = error;
  assert.equal(run(w, `[error.code, error.message, Object.getOwnPropertyNames(error).length].join()`), '1,User denied Geolocation,0');
  assert.equal(await run(w, `navigator.permissions.query({ name: 'geolocation' }).then((s) => [s.state, s instanceof PermissionStatus, Object.getOwnPropertyNames(s).length].join())`), 'denied,true,0');
  assert.equal(await run(w, `navigator.permissions.query({ name: 'camera' }).then((s) => s.state)`), 'prompt');
  // Not a function: the engine's argument error, before any callback.
  assert.throws(() => run(w, `navigator.geolocation.getCurrentPosition(1)`), (e) => e.name === 'TypeError');
  // Receivers that are not ours still get the native getter's TypeError.
  assert.throws(() => run(w, `Object.getOwnPropertyDescriptor(GeolocationPositionError.prototype, 'code').get.call({})`), (e) => e.name === 'TypeError');
});

test('workers made from a blob are hooked whenever a substitution reaches them, and only then', () => {
  // The worker runs the shim (its URL is replaced by one whose script starts with it) exactly when
  // the page has something a worker would otherwise answer differently.
  const hooked = (config) => run(makeWindow(config), `(() => { const url = URL.createObjectURL(new Blob(['postMessage(1)'])); return new Worker(url).url !== url; })()`);
  assert.equal(hooked(base), false, 'no substitution: no hook');
  assert.equal(hooked({ ...base, storageQuota: 0.6 * 128 * 2 ** 30 }), true, 'the storage quota alone, this Mac\'s time zone');
  assert.equal(hooked({ ...base, timeZone: 'Asia/Tokyo' }), true, 'a time zone');
  assert.equal(hooked({ ...base, phone: { platform: 'iPhone', width: 402, height: 874, maxTouchPoints: 5 } }), true, 'an iPhone');
  // The iOS app always sends a fingerprint: only a mode that changes something, or a language, counts.
  const real = { seed: 's', canvas: 'real', webgl: 'real', audio: 'real', language: null, unstable: false, naive: false };
  assert.equal(hooked({ ...base, fingerprint: real }), false, 'the iOS app\'s fingerprint with everything real');
  assert.equal(hooked({ ...base, fingerprint: { ...real, canvas: 'noise' } }), true, 'canvas noise, this device\'s time zone');
  assert.equal(hooked({ ...base, fingerprint: { ...real, webgl: 'off' } }), true, 'WebGL off');
  assert.equal(hooked({ ...base, fingerprint: { ...real, audio: 'noise' } }), true, 'audio noise');
  assert.equal(hooked({ ...base, fingerprint: { ...real, language: 'de-DE' } }), true, 'a language');
});

// What a blob worker starts with: this script and the part of CONFIG a worker reads — never the
// camera's media (copied into every frame's script, tens of MB with a video) nor the WebRTC relay's
// credentials (a worker can read its own script back; a page that put its own Blob in place would be
// handed it). Read where only the engine sees it: the Blob behind the worker's URL.
test('a blob worker gets only what a worker uses: never the camera\'s media, never the relay\'s credentials', () => {
  const relay = { urls: ['turn:127.0.0.1:50000?transport=udp'], username: 'relay-user-7', credential: 'relay-secret-7' };
  const video = 'data:video/mp4;base64,' + 'QUJD'.repeat(32) + 'VIDEO-MEDIA';
  const config = { ...base, timeZone: 'Europe/Berlin', storageQuota: 0.6 * 128 * 2 ** 30, webRTC: 'tunnel', webRTCRelay: relay,
                   camera: { ...noCamera.camera, mode: 'substitute', source: 'video', videoURL: video },
                   systemCamera: { sentinel: 'Lumen Camera', usedHere: false, label: 'FaceTime HD Camera' } };
  const w = makeWindow(config);
  const scriptOf = (url) => run(w, `__engine.blobs.get(${JSON.stringify(url)}).parts.filter((p) => typeof p === 'string').join('')`);
  const url = run(w, `new Worker(URL.createObjectURL(new Blob(['postMessage(1)']))).url`);
  const script = scriptOf(url);
  for (const secret of ['relay-user-7', 'relay-secret-7', 'turn:127.0.0.1', 'VIDEO-MEDIA', 'Lumen Camera']) {
    assert.ok(!script.includes(secret), `the worker's script carries ${secret}`);
  }
  // The page's own Blob, put in place before its worker starts, is not handed the script; the
  // worker is still made of it.
  run(w, `var handed = []; var PageBlob = Blob; window.Blob = class Blob extends PageBlob { constructor(parts, o) { super(parts, o); handed.push(this.parts.join('')); } };`);
  const second = run(w, `new Worker(URL.createObjectURL(new PageBlob(['postMessage(2)']))).url`);
  assert.equal(run(w, `handed.length`), 0, 'the page\'s Blob was handed the worker\'s script');
  assert.ok(scriptOf(second).startsWith('try { (0, eval)('), 'the worker made of the page\'s blob starts with the script');
  // What it does carry: the shim, run with the worker's part of CONFIG.
  const evaluated = JSON.parse(/^try \{ \(0, eval\)\((.*)\); \} catch \(e\) \{\}/s.exec(script)[1]);
  assert.ok(evaluated.startsWith('(function install(CONFIG) {'));
  const workerConfig = JSON.parse(evaluated.slice(evaluated.lastIndexOf('})(') + 3, -2));
  assert.deepEqual(workerConfig, { timeZone: 'Europe/Berlin', storageQuota: config.storageQuota });
  // The iOS app's fingerprint and an iPhone's platform go too: a worker answers them.
  const phone = { platform: 'iPhone', width: 402, height: 874, maxTouchPoints: 5 };
  const fingerprint = { seed: 's', canvas: 'noise', webgl: 'real', audio: 'real', language: null, unstable: false, naive: false };
  const ios = makeWindow({ ...base, phone, fingerprint });
  const iosURL = run(ios, `new Worker(URL.createObjectURL(new Blob(['postMessage(1)']))).url`);
  const iosScript = JSON.parse(/^try \{ \(0, eval\)\((.*)\); \} catch \(e\) \{\}/s.exec(run(ios, `__engine.blobs.get(${JSON.stringify(iosURL)}).parts.join('')`))[1]);
  assert.deepEqual(JSON.parse(iosScript.slice(iosScript.lastIndexOf('})(') + 3, -2)), { phone, fingerprint });
});

test('storage quota: Safari\'s instead of the app default', async () => {
  // WebKit: ceil(0.6 × 128 GB) for a browser's top-level origin on any Mac.
  const w = makeWindow({ ...base, storageQuota: 0.6 * 128 * 2 ** 30 });
  assert.equal(await run(w, `navigator.storage.estimate().then((e) => [e.quota, e.usage].join())`), '82463372084,1234');
  const plain = makeWindow(base);
  assert.equal(await run(plain, `navigator.storage.estimate().then((e) => e.quota)`), 1048576000);
});

test('geolocation native: the engine answers, the page meets its own Geolocation untouched', () => {
  const keep = 'globalThis.__original = Object.getOwnPropertyDescriptor(Geolocation.prototype, "getCurrentPosition").value;';
  const same = `String(Object.getOwnPropertyDescriptor(Geolocation.prototype, 'getCurrentPosition').value === __original)`;
  assert.equal(run(makeWindow({ webRTC: 'disabled', geolocation: { mode: 'native' } }, null, keep), same), 'true');
  // The control: with 'deny' the script does replace it.
  assert.equal(run(makeWindow(base, null, keep), same), 'false');
});

test('geolocation fixed: position objects without own properties', async () => {
  const w = makeWindow({ ...base, geolocation: { mode: 'fixed', latitude: 48.8566, longitude: 2.3522, accuracy: 25 } });
  w.position = await run(w, `new Promise((res) => navigator.geolocation.getCurrentPosition((p) => res(p)))`);
  assert.equal(run(w, `[position.coords.latitude, position.coords.longitude, position.coords.accuracy, position.coords.altitude].join()`), '48.8566,2.3522,25,');
  assert.equal(run(w, `Object.getOwnPropertyNames(position).length + Object.getOwnPropertyNames(position.coords).length`), 0);
  assert.equal(run(w, `position instanceof GeolocationPosition && position.coords instanceof GeolocationCoordinates`), true);
  assert.equal(run(w, `JSON.stringify(position.toJSON().coords.latitude)`), '48.8566');
  assert.equal(await run(w, `navigator.permissions.query({ name: 'geolocation' }).then((s) => s.state)`), 'granted');
});

test('WebRTC disabled: removed without a trace', () => {
  const w = makeWindow(base);
  assert.equal(run(w, `typeof RTCPeerConnection`), 'undefined');
  assert.equal(run(w, `typeof webkitRTCPeerConnection`), 'undefined');
  assert.equal(run(w, `'RTCPeerConnection' in window`), false);
  // Every RTC interface, not only the constructors a page would call first.
  assert.equal(run(w, `Object.getOwnPropertyNames(window).filter((n) => /^(webkit)?RTC/.test(n)).join()`), '');
});

test('WebRTC relayOnly', () => {
  const w = makeWindow({ ...base, webRTC: 'relayOnly' });
  assert.equal(run(w, `new RTCPeerConnection({ iceServers: [], iceTransportPolicy: 'all' }).config.iceTransportPolicy`), 'relay');
  assert.equal(run(w, `new RTCPeerConnection().config.iceTransportPolicy`), 'relay');
  assert.equal(run(w, `(() => { const p = new RTCPeerConnection(); p.setConfiguration({ iceTransportPolicy: 'all' }); return p.config.iceTransportPolicy; })()`), 'relay');
  assert.equal(run(w, `new webkitRTCPeerConnection({}).config.iceTransportPolicy`), 'relay');
  assert.equal(run(w, `new RTCPeerConnection() instanceof RTCPeerConnection`), true);
});

test('WebRTC through the tunnel: the relay is the only ICE server, the page sees its own configuration', () => {
  const relay = { urls: ['turn:192.0.2.10:3478?transport=udp', 'turn:[fd6b:3a1c:94e2:1::a]:3478?transport=udp'], username: 'u1', credential: 'c1' };
  const w = makeWindow({ ...base, webRTC: 'tunnel', webRTCRelay: relay });
  run(w, `var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.example:3478' }], iceTransportPolicy: 'all' })`);
  // What the engine got: relay-only through the tunnel's TURN server.
  assert.equal(run(w, `JSON.stringify(pc.config)`), JSON.stringify({ iceServers: relay.urls.map((urls) => ({ urls, username: 'u1', credential: 'c1' })), iceTransportPolicy: 'relay' }));
  // What the page reads back: its own servers and policy, fresh objects each time.
  assert.equal(run(w, `JSON.stringify(pc.getConfiguration().iceServers)`), JSON.stringify([{ urls: 'stun:stun.example:3478' }]));
  assert.equal(run(w, `pc.getConfiguration().iceTransportPolicy`), 'all');
  assert.equal(run(w, `pc.getConfiguration().iceServers !== pc.getConfiguration().iceServers`), true);
  assert.equal(run(w, `pc.getConfiguration().bundlePolicy`), 'balanced');
  run(w, `pc.setConfiguration({ iceServers: [{ urls: ['turn:turn.example:3478'], username: 'a', credential: 'b' }] })`);
  assert.equal(run(w, `pc.config.iceServers[0].username`), 'u1');
  assert.equal(run(w, `pc.getConfiguration().iceServers[0].urls[0]`), 'turn:turn.example:3478');
  // The engine's own validation of the page's configuration still applies.
  assert.throws(() => run(w, `new RTCPeerConnection({ iceServers: [{ urls: 'http://bad' }] })`), (e) => e.name === 'SyntaxError');
  assert.throws(() => run(w, `new RTCPeerConnection({ iceServers: [{}] })`), (e) => e.name === 'TypeError');
  assert.throws(() => run(w, `RTCPeerConnection.prototype.getConfiguration.call({})`), (e) => e.name === 'TypeError');
  // An ICE event names the page's TURN server, not the relay; others pass through.
  assert.equal(run(w, `new RTCPeerConnectionIceEvent('icecandidate', { url: '${relay.urls[0]}', target: pc }).url`), 'turn:turn.example:3478?transport=udp');
  assert.equal(run(w, `new RTCPeerConnectionIceEvent('icecandidate', { url: null, target: pc }).url`), null);
  run(w, `var plain = new RTCPeerConnection({ iceServers: [{ urls: 'stun:s.example' }] })`);
  assert.equal(run(w, `new RTCPeerConnectionIceEvent('icecandidate', { url: '${relay.urls[0]}', target: plain }).url`), null);
  // libwebrtc's form of the page's server: default port, transport, IPv6 in brackets.
  run(w, `var v6 = new RTCPeerConnection({ iceServers: [{ urls: ['stun:[2001:db8::7]', 'turn:[2001:DB8::8]'], username: 'a', credential: 'b' }] })`);
  assert.equal(run(w, `new RTCPeerConnectionIceEvent('icecandidate', { url: '${relay.urls[1]}', target: v6 }).url`), 'turn:[2001:db8::8]:3478?transport=udp');
  assert.equal(run(w, `new RTCPeerConnectionIceEvent('icecandidate', { url: 'turn:turn.other:3478?transport=udp', target: v6 }).url`), 'turn:turn.other:3478?transport=udp');
  // Native-looking functions.
  assert.equal(run(w, `RTCPeerConnection.prototype.getConfiguration.toString()`), nativeText('getConfiguration'));
  assert.equal(run(w, `RTCPeerConnection.prototype.getStats.toString()`), nativeText('getStats'));
  assert.equal(run(w, `Object.getOwnPropertyDescriptor(RTCPeerConnectionIceEvent.prototype, 'url').get.toString()`), nativeText('url'));
});

test('WebRTC through the tunnel: getStats() names the page\'s servers, never the relay', async () => {
  const relay = { urls: ['turn:192.0.2.10:3478?transport=udp', 'turn:[fd6b:3a1c:94e2:1::a]:3478?transport=udp'], username: 'u1', credential: 'c1' };
  const w = makeWindow({ ...base, webRTC: 'tunnel', webRTCRelay: relay });
  run(w, `var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.example' }] });
          pc.stats = [['R', { type: 'local-candidate', candidateType: 'relay', address: '203.0.113.9', url: 'turn:192.0.2.10:3478?transport=udp' }],
                      ['S', { type: 'local-candidate', candidateType: 'srflx', address: '203.0.113.9', url: 'stun:192.0.2.10:3478' }],
                      ['S6', { type: 'local-candidate', candidateType: 'srflx', url: 'stun:fd6b:3a1c:94e2:1::a:3478' }],
                      ['H', { type: 'local-candidate', candidateType: 'host', address: '', url: 'stun:stun.example:3478' }],
                      ['P', { type: 'candidate-pair', state: 'succeeded' }]];`);
  const read = async (expr) => JSON.parse(await run(w, `(${expr}).then((report) => JSON.stringify([...report.values()]))`));
  const [r, s, s6, h, p] = await read('pc.getStats()');
  assert.equal(r.url, undefined, 'a relay candidate when the page configured no TURN server');
  assert.equal(r.address, '203.0.113.9', 'the proxy egress stays');
  assert.equal(s.url, 'stun:stun.example:3478');
  assert.equal(s6.url, 'stun:stun.example:3478');
  assert.equal(h.url, 'stun:stun.example:3478');
  assert.deepEqual(p, { type: 'candidate-pair', state: 'succeeded' });
  run(w, `pc.setConfiguration({ iceServers: [{ urls: 'turn:turn.example?transport=tcp', username: 'a', credential: 'b' }] })`);
  const [r2, s2] = await read('pc.getStats()');
  assert.equal(r2.url, 'turn:turn.example:3478?transport=tcp');
  assert.equal(s2.url, 'stun:turn.example:3478', 'a TURN server is asked as a STUN server too');
  // A sender's stats: the latest connection's servers.
  run(w, `var sender = new RTCRtpSender(); sender.stats = [['R', { type: 'local-candidate', url: '${relay.urls[1]}' }]];`);
  assert.equal((await read('sender.getStats()'))[0].url, 'turn:turn.example:3478?transport=tcp');
  // The engine's receiver check still applies.
  assert.throws(() => run(w, `RTCPeerConnection.prototype.getStats.call({})`), (e) => e.name === 'TypeError');
});

// A hostile page replaces the built-ins the shim could call when a peer connection is made, or puts
// accessors on Object.prototype that a configuration object would inherit. The engine must still
// get only the relay, relay-only; the native constructor and methods must never reach the page.
test('WebRTC through the tunnel: a page that tampers with built-ins still gets only the relay', () => {
  const relay = { urls: ['turn:192.0.2.10:3478?transport=udp', 'turn:[fd6b:3a1c:94e2:1::a]:3478?transport=udp'], username: 'u1', credential: 'c1' };
  const attacker = `[{ urls: 'stun:attacker.example:3478' }]`;
  const attacks = {
    'accessors on Object.prototype': `
      Object.defineProperty(Object.prototype, 'iceServers', { get() { return ${attacker}; }, set() {}, configurable: true });
      Object.defineProperty(Object.prototype, 'iceTransportPolicy', { get() { return 'all'; }, set() {}, configurable: true });
      Object.defineProperty(Object.prototype, 'urls', { get() { return 'stun:attacker.example:3478'; }, set() {}, configurable: true });`,
    'Reflect': `
      const construct = Reflect.construct, apply = Reflect.apply;
      Reflect.construct = function (T, args, nt) { (window.__seen = window.__seen || []).push(T); return construct(T, [{ iceServers: ${attacker}, iceTransportPolicy: 'all' }], nt); };
      Reflect.apply = function (f, t, a) { (window.__seen = window.__seen || []).push(f); return apply(f, t, a); };`,
    'Function.prototype.call and apply': `
      const apply = Reflect.apply;
      Function.prototype.call = function (t, ...a) { (window.__seen = window.__seen || []).push(this); return apply(this, t, a); };
      Function.prototype.apply = function (t, a) { (window.__seen = window.__seen || []).push(this); return apply(this, t, a || []); };`,
    'Object.assign, Array.prototype.slice and the array iterator': `
      Object.assign = function (target) { target.iceServers = ${attacker}; target.iceTransportPolicy = 'all'; return target; };
      Array.prototype.slice = function () { return ['stun:attacker.example:3478']; };
      Array.prototype[Symbol.iterator] = function* () { yield { urls: 'stun:attacker.example:3478' }; };`,
    'Object.create and Object.defineProperty': `
      Object.create = function () { return { iceServers: ${attacker}, iceTransportPolicy: 'all' }; };
      const define = Object.defineProperty;
      Object.defineProperty = function (o, k, d) { (window.__seen = window.__seen || []).push(d && d.value); return define(o, k, d); };`,
    'WeakMap and Promise methods': `
      WeakMap.prototype.get = function (k) { (window.__seen = window.__seen || []).push(k); return undefined; };
      WeakMap.prototype.set = function (k, v) { (window.__seen = window.__seen || []).push(v); return this; };
      Promise.prototype.then = function (f) { (window.__seen = window.__seen || []).push(f); return this; };`,
  };
  for (const [name, attack] of Object.entries(attacks)) {
    const w = makeWindow({ ...base, webRTC: 'tunnel', webRTCRelay: relay });
    run(w, attack);
    try { run(w, `window.pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.example:3478' }], iceTransportPolicy: 'all', iceCandidatePoolSize: 4 })`); } catch (e) {}
    try { run(w, `pc.setConfiguration({ iceServers: [{ urls: 'stun:stun.example:3478' }], iceTransportPolicy: 'all' })`); } catch (e) {}
    try { run(w, `class Sub extends RTCPeerConnection {}; window.sub = new Sub({ iceServers: [{ urls: 'stun:stun.example:3478' }], iceTransportPolicy: 'all' })`); } catch (e) {}
    try { run(w, `pc.getConfiguration(); pc.getStats()`); } catch (e) {}
    const report = JSON.parse(run(w, `JSON.stringify({
      live: __engine.instances.filter((pc) => !pc.closed).map((pc) => pc.config),
      gatheredOutsideRelay: __engine.instances.filter((pc) => pc.gathered && pc.config.iceTransportPolicy !== 'relay').length,
      nativeSeen: (window.__seen || []).some((f) => f === __engine.Native || __engine.methods.includes(f)),
    })`));
    assert.ok(report.live.length >= 1, `${name}: a peer connection was made`);
    for (const config of report.live) {
      assert.equal(config.iceTransportPolicy, 'relay', `${name}: relay-only`);
      assert.deepEqual(config.iceServers.map((s) => s.urls), relay.urls, `${name}: the relay is the only ICE server`);
    }
    assert.equal(report.gatheredOutsideRelay, 0, `${name}: nothing gathered outside the relay`);
    assert.equal(report.nativeSeen, false, `${name}: the native constructor and methods stay out of the page's reach`);
  }
});

test('WebRTC through the tunnel: a remote candidate named by a host name never reaches the resolver', async () => {
  const relay = { urls: ['turn:127.0.0.1:50000?transport=udp'], username: 'u1', credential: 'c1' };
  const w = makeWindow({ ...base, webRTC: 'tunnel', webRTCRelay: relay });
  const engine = () => JSON.parse(run(w, `JSON.stringify({ added: __engine.added, resolved: __engine.resolved, sdp: pc.remoteDescription && pc.remoteDescription.sdp })`));
  run(w, `var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.example' }] })`);
  // Before a remote description the engine refuses, as it would: nothing is resolved either way.
  await assert.rejects(run(w, `pc.addIceCandidate({ candidate: 'candidate:1 1 udp 2122260223 early.example 9 typ host', sdpMid: '0' })`),
                       (e) => e.name === 'InvalidStateError');
  const sdp = ['v=0', 'a=candidate:1 1 udp 2122260223 192.0.2.44 50000 typ host',
               'a=candidate:2 1 udp 2122260223 2001:db8::44 50001 typ host',
               'a=candidate:3 1 udp 2122260223 4c1a2b3c-aaaa-bbbb-cccc-0123456789ab.local 50002 typ host',
               'a=candidate:4 1 tcp 1518280447 peer-run7.leak.example 9 typ host tcptype active',
               'a=candidate:5 1 udp 1686052607 203.0.113.9 3478 typ srflx raddr 0.0.0.0 rport 0', ''].join('\r\n');
  await run(w, `pc.setRemoteDescription({ type: 'offer', sdp: ${JSON.stringify(sdp)} })`);
  let state = engine();
  assert.deepEqual(state.resolved, [], 'no name in the remote SDP reached the resolver');
  assert.ok(state.sdp.includes('192.0.2.44') && state.sdp.includes('2001:db8::44') && state.sdp.includes('203.0.113.9'), 'addresses stay');
  assert.ok(!state.sdp.includes('.local') && !state.sdp.includes('leak.example'), 'named candidates are gone');
  // Trickled candidates: addresses go to the engine, names do not, and the page is told success.
  await run(w, `pc.addIceCandidate({ candidate: 'candidate:6 1 udp 2122260223 198.51.100.7 50003 typ host', sdpMid: '0' })`);
  await run(w, `pc.addIceCandidate({ candidate: 'candidate:7 1 udp 2122260223 another.local 50004 typ host', sdpMid: '0' })`);
  await run(w, `pc.addIceCandidate(new (class { get candidate() { return 'candidate:8 1 udp 2122260223 name.leak.example 9 typ host'; } })())`);
  state = engine();
  assert.deepEqual(state.added, ['candidate:6 1 udp 2122260223 198.51.100.7 50003 typ host']);
  assert.deepEqual(state.resolved, []);
  // A getter or a toString that answers differently each time: the engine gets what was checked.
  await run(w, `var n = 0; pc.addIceCandidate({ get candidate() { return n++ ? 'candidate:9 1 udp 1 flip.leak.example 9 typ host' : 'candidate:9 1 udp 1 192.0.2.9 9 typ host'; }, sdpMid: '0' })`);
  await run(w, `var m = 0; pc.addIceCandidate({ candidate: { toString() { return m++ ? 'candidate:10 1 udp 1 192.0.2.10 9 typ host' : 'candidate:10 1 udp 1 tostring.leak.example 9 typ host'; } }, sdpMid: '0' })`);
  state = engine();
  assert.deepEqual(state.added.slice(1), ['candidate:9 1 udp 1 192.0.2.9 9 typ host'], 'the value read once, its text made once');
  assert.deepEqual(state.resolved, []);
  // The legacy success callback is called for a dropped one too.
  assert.equal(await run(w, `new Promise((resolve) => pc.addIceCandidate({ candidate: 'candidate:11 1 udp 1 cb.leak.example 9 typ host', sdpMid: '0' }, () => resolve('called')))`), 'called');
  // The engine's receiver check, and the end of candidates, as ever.
  assert.throws(() => run(w, `RTCPeerConnection.prototype.addIceCandidate.call({}, { candidate: 'candidate:1 1 udp 1 x.example 9 typ host' })`), (e) => e.name === 'TypeError');
  await run(w, `pc.addIceCandidate(null)`);
  assert.deepEqual(engine().resolved, []);
  assert.equal(run(w, `RTCPeerConnection.prototype.addIceCandidate.toString()`), nativeText('addIceCandidate'));
  assert.equal(run(w, `RTCPeerConnection.prototype.setRemoteDescription.toString()`), nativeText('setRemoteDescription'));
});

// The engine keeps the relay, with its credentials, as the configuration of every connection the
// shim makes; a frame's getConfiguration called on another frame's connection (WebIDL takes one of
// any frame) does not know the page's view of it, and must not show the relay instead.
test('WebRTC through the tunnel: another frame\'s getConfiguration never shows the relay', () => {
  const relay = { urls: ['turn:127.0.0.1:50000?transport=udp'], username: 'relay-user-7', credential: 'relay-secret-7' };
  const config = { ...base, webRTC: 'tunnel', webRTCRelay: relay };
  const top = makeWindow(config);
  const frame = makeWindow(config, top);
  top.__frameGetConfiguration = run(frame, 'RTCPeerConnection.prototype.getConfiguration');
  top.__framePC = run(frame, `new RTCPeerConnection({ iceServers: [{ urls: 'stun:frame.example:3478' }] })`);
  const seen = [
    run(top, `JSON.stringify(__frameGetConfiguration.call(new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.example.com:3478' }] })))`),
    run(top, `JSON.stringify(RTCPeerConnection.prototype.getConfiguration.call(__framePC))`),
  ];
  for (const text of seen) {
    for (const secret of ['relay-user-7', 'relay-secret-7', '127.0.0.1']) assert.ok(!text.includes(secret), `${secret} in ${text}`);
  }
  // Each frame's own connections still read the page's own servers.
  assert.equal(run(top, `JSON.stringify(new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.example.com:3478' }] }).getConfiguration().iceServers)`),
               JSON.stringify([{ urls: 'stun:stun.example.com:3478' }]));
  assert.equal(run(frame, `JSON.stringify(__engine.instances.length && new RTCPeerConnection({ iceServers: [{ urls: 'stun:frame.example:3478' }] }).getConfiguration().iceServers)`),
               JSON.stringify([{ urls: 'stun:frame.example:3478' }]));
  // And the engine still has the relay for them all.
  assert.equal(run(top, `__engine.instances.filter((pc) => !pc.closed).every((pc) => pc.config.iceServers[0].credential === 'relay-secret-7')`), true);
});

test('WebRTC through the tunnel: the validating connection never gathers', () => {
  const relay = { urls: ['turn:192.0.2.10:3478?transport=udp'], username: 'u1', credential: 'c1' };
  const w = makeWindow({ ...base, webRTC: 'tunnel', webRTCRelay: relay });
  run(w, `new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.example:3478' }], iceTransportPolicy: 'all', iceCandidatePoolSize: 8 })`);
  const instances = JSON.parse(run(w, `JSON.stringify(__engine.instances.map((pc) => ({ closed: pc.closed, gathered: pc.gathered, policy: pc.config.iceTransportPolicy })))`));
  assert.deepEqual(instances, [{ closed: true, gathered: false, policy: 'all' }, { closed: false, gathered: true, policy: 'relay' }]);
  // A bad pool size is the engine's error, from the real construction.
  assert.throws(() => run(w, `new RTCPeerConnection({ iceCandidatePoolSize: 300 })`), (e) => e.name === 'TypeError');
  // A non-dictionary is the engine's TypeError too.
  assert.throws(() => run(w, `new RTCPeerConnection(5)`), (e) => e.name === 'TypeError');
});

test('WebRTC unrestricted', () => {
  const w = makeWindow({ ...base, webRTC: 'unrestricted' });
  assert.equal(run(w, `new RTCPeerConnection({ iceTransportPolicy: 'all' }).config.iceTransportPolicy`), 'all');
});

// ---- System camera (patchSystemCamera) ---------------------------------------------------------
// The engine's media devices as WebKit shapes them: MediaDeviceInfo values behind prototype getters
// that reject other receivers; before the page holds the camera permission one unnamed placeholder
// per kind (Media Capture and Streams, "device information exposure"), after it every device with
// its id and label. getUserMedia reads a deviceId as the engine does: given bare (a string or a
// list) or as { ideal } it is the basic set's ideal — that device when there is one, else the Mac's
// default camera; as { exact } it is required — that device, or OverconstrainedError before any
// prompt. With nothing asked it is a TypeError, as in the engine. Every call and stop is recorded. Its
// receiver check takes a MediaDevices of any frame, as WebKit's does, and it reads a request as
// WebIDL converts it: each member once, null or any object asking for the device. `canvas`: a
// document whose canvas gives a stream, for the drawn camera (`patchCamera`).
const cameraPrelude = ({ granted = false, micGranted = false, defaultCamera = 'real-cam', withVirtual = true, deny = false,
                        virtualFails = false, canvas = false } = {}) => `(() => {
  const reject = (o, C) => { if (!(o instanceof C)) throw new TypeError('illegal invocation'); };
  const engineObjects = globalThis.__engineObjects;
  const branded = (o) => { if (!engineObjects.has(o)) throw new TypeError('illegal invocation'); };
  const askedFor = (v) => v === null || (v !== undefined && (typeof v === 'object' || typeof v === 'function' || !!v));
  // The engine's DOMException (a bare vm realm has none).
  if (typeof globalThis.DOMException !== 'function') {
    globalThis.DOMException = class DOMException extends Error { constructor(message, name) { super(message); this.name = name || 'Error'; } };
  }
  const info = new WeakMap();
  class MediaDeviceInfo { constructor() { throw new TypeError('Illegal constructor'); } }
  for (const k of ['deviceId', 'kind', 'groupId', 'label']) {
    Object.defineProperty(MediaDeviceInfo.prototype, k, { get() { reject(this, MediaDeviceInfo); return info.get(this)[k]; }, enumerable: true, configurable: true });
  }
  MediaDeviceInfo.prototype.toJSON = function toJSON() { reject(this, MediaDeviceInfo); const v = info.get(this); return { deviceId: v.deviceId, kind: v.kind, groupId: v.groupId, label: v.label }; };
  class InputDeviceInfo extends MediaDeviceInfo {}
  // A placeholder (no permission yet, an empty id) has no device behind it: no capabilities.
  InputDeviceInfo.prototype.getCapabilities = function getCapabilities() {
    reject(this, InputDeviceInfo); const v = info.get(this); return v.deviceId ? { deviceId: v.deviceId, groupId: v.groupId } : {};
  };
  globalThis.MediaDeviceInfo = MediaDeviceInfo; globalThis.InputDeviceInfo = InputDeviceInfo;
  const device = (id, label, kind) => { const d = Object.create(InputDeviceInfo.prototype); info.set(d, { deviceId: id, kind, groupId: id ? 'g-' + id : '', label }); return d; };
  // granted: the camera permission (and with it the microphone's); micGranted: the microphone's alone.
  const camera = { granted: ${granted}, micGranted: ${micGranted}, calls: [], opened: [], stopped: [] };
  globalThis.__camera = camera;
  const devices = [{ id: 'real-cam', label: 'Камера (MacBook Air)', kind: 'videoinput' }];
  if (${withVirtual}) devices.push({ id: 'lumen-cam', label: 'Lumen Camera', kind: 'videoinput' });
  devices.push({ id: 'mic', label: 'MacBook Air Microphone', kind: 'audioinput' });
  class MediaStreamTrack {
    constructor(kind, deviceId) { this.kind = kind; this.deviceId = deviceId; this.readyState = 'live'; }
    getSettings() { return { deviceId: this.deviceId }; }
    stop() { if (this.readyState === 'live') { this.readyState = 'ended'; camera.stopped.push(this.deviceId); } }
  }
  // As WebKit: a track's label is an accessor on the prototype, its device's name.
  Object.defineProperty(MediaStreamTrack.prototype, 'label', {
    get() { reject(this, MediaStreamTrack); const d = devices.find((x) => x.id === this.deviceId); return d ? d.label : ''; },
    enumerable: true, configurable: true });
  globalThis.MediaStreamTrack = MediaStreamTrack;
  class MediaStream {
    constructor(tracks) { this.tracks = tracks || []; }
    getTracks() { return this.tracks.slice(); }
    getVideoTracks() { return this.tracks.filter((t) => t.kind === 'video'); }
    getAudioTracks() { return this.tracks.filter((t) => t.kind === 'audio'); }
  }
  globalThis.MediaStream = MediaStream;
  class MediaDevices {
    get ondevicechange() { branded(this); return null; }
    enumerateDevices() {
      branded(this);
      // Per kind: a kind the page holds no permission for is one unnamed placeholder.
      const out = [];
      for (const kind of ['videoinput', 'audioinput']) {
        const held = kind === 'videoinput' ? camera.granted : (camera.granted || camera.micGranted);
        if (held) { for (const d of devices) if (d.kind === kind) out.push(device(d.id, d.label, kind)); }
        else out.push(device('', '', kind));
      }
      return Promise.resolve(out);
    }
    getUserMedia(constraints) {
      branded(this);
      camera.calls.push(constraints === undefined ? null : JSON.parse(JSON.stringify(constraints)));
      const audio = constraints === undefined || constraints === null ? undefined : constraints.audio;
      const video = constraints === undefined || constraints === null ? undefined : constraints.video;
      if (!askedFor(video) && !askedFor(audio)) return Promise.reject(new TypeError('At least one of audio and video must be requested'));
      let id = '${defaultCamera}';
      if (askedFor(video)) {
        const exists = (x) => typeof x === 'string' && devices.some((d) => d.kind === 'videoinput' && d.id === x);
        const ids = (v) => typeof v === 'string' ? [v] : (v !== null && typeof v === 'object' && typeof v[Symbol.iterator] === 'function') ? [...v] : [];
        const pin = video !== null && typeof video === 'object' ? video.deviceId : undefined;
        if (typeof pin === 'string' || (pin !== null && typeof pin === 'object' && typeof pin[Symbol.iterator] === 'function')) {
          id = ids(pin).find(exists) || id;
        } else if (pin !== null && typeof pin === 'object') {
          const exact = pin.exact, ideal = pin.ideal;
          // An exact list that names nothing is taken for no constraint at all (the riskier reading).
          if (exact !== undefined && ids(exact).length) {
            const match = ids(exact).find(exists);
            if (!match) { const e = new Error('Overconstrained'); e.name = 'OverconstrainedError'; return Promise.reject(e); }
            id = match;
          } else if (ideal !== undefined) id = ids(ideal).find(exists) || id;
        }
      }
      if (${deny}) { const e = new Error('The request is not allowed'); e.name = 'NotAllowedError'; return Promise.reject(e); }
      if (askedFor(video)) camera.granted = true; else camera.micGranted = true;
      const tracks = [];
      if (askedFor(video)) {
        if (${virtualFails} && id === 'lumen-cam') { const e = new Error('Could not start video source'); e.name = 'NotReadableError'; return Promise.reject(e); }
        camera.opened.push(id);
        tracks.push(new MediaStreamTrack('video', id));
      }
      if (askedFor(audio)) tracks.push(new MediaStreamTrack('audio', 'mic'));
      return Promise.resolve(new MediaStream(tracks));
    }
  }
  globalThis.MediaDevices = MediaDevices;
  navigator.mediaDevices = Object.create(MediaDevices.prototype);
  engineObjects.add(navigator.mediaDevices);
  if (${canvas}) {
    // What the drawn camera draws on: a canvas whose stream has one video track (its frames are not modelled).
    globalThis.document = { createElement: () => ({ width: 0, height: 0, getContext: () => ({}),
                                                    captureStream: () => new MediaStream([new MediaStreamTrack('video', 'drawn')]) }) };
    globalThis.requestAnimationFrame = () => 1;
    globalThis.cancelAnimationFrame = () => {};
  }
})();`;

const systemCamera = (usedHere) => ({ ...base, systemCamera: { sentinel: 'Lumen Camera', usedHere, label: 'FaceTime HD Camera' } });
const cameraState = (w) => JSON.parse(run(w, `JSON.stringify(__camera)`));
const listed = (w) => run(w, `navigator.mediaDevices.enumerateDevices().then((l) => JSON.stringify(l.map((d) => [d.kind, d.deviceId, d.label])))`).then(JSON.parse);
const openedBy = (w, constraints) => run(w, `navigator.mediaDevices.getUserMedia(${JSON.stringify(constraints)}).then((s) => JSON.stringify(s.getTracks().map((t) => [t.kind, t.deviceId, t.readyState])))`).then(JSON.parse);

test('system camera, with the permission: the page lists only the virtual camera, under the profile\'s name, and opens it', async () => {
  const w = makeWindow(systemCamera(true), null, cameraPrelude({ granted: true }));
  assert.deepEqual(await listed(w), [['videoinput', 'lumen-cam', 'FaceTime HD Camera'], ['audioinput', 'mic', 'MacBook Air Microphone']]);
  assert.deepEqual(await openedBy(w, { video: true }), [['video', 'lumen-cam', 'live']]);
  const state = cameraState(w);
  assert.deepEqual(state.opened, ['lumen-cam']);   // the Mac's camera never opened
  assert.deepEqual(state.stopped, []);
});

test('system camera, first visit: before the permission the page sees one unnamed camera, as in Safari', async () => {
  const w = makeWindow(systemCamera(true), null, cameraPrelude());
  assert.deepEqual(await listed(w), [['videoinput', '', ''], ['audioinput', '', '']]);
});

test('system camera, first visit: the page\'s own call asks, the real camera is dropped unseen, the virtual one is returned', async () => {
  const w = makeWindow(systemCamera(true), null, cameraPrelude());
  assert.deepEqual(await openedBy(w, { video: { width: 1280 }, audio: true }), [['video', 'lumen-cam', 'live'], ['audio', 'mic', 'live']]);
  const state = cameraState(w);
  // The first call carried the page's constraints (never an empty getUserMedia()), the second
  // pinned the sentinel and kept everything else the page asked for.
  assert.deepEqual(state.calls, [{ video: { width: 1280 }, audio: true }, { video: { width: 1280, deviceId: { exact: 'lumen-cam' } }, audio: true }]);
  assert.deepEqual(state.opened, ['real-cam', 'lumen-cam']);
  assert.deepEqual(state.stopped, ['real-cam', 'mic']);   // the first stream, all of it, before the page had it
});

test('system camera, first visit: when the Mac\'s default already is the virtual camera, nothing is opened twice', async () => {
  const w = makeWindow(systemCamera(true), null, cameraPrelude({ defaultCamera: 'lumen-cam' }));
  assert.deepEqual(await openedBy(w, { video: true }), [['video', 'lumen-cam', 'live']]);
  const state = cameraState(w);
  assert.equal(state.calls.length, 1);
  assert.deepEqual(state.stopped, []);
});

test('system camera, first visit: no virtual device after the grant → NotFoundError, the real stream stopped unseen', async () => {
  const w = makeWindow(systemCamera(true), null, cameraPrelude({ withVirtual: false }));
  await assert.rejects(run(w, `navigator.mediaDevices.getUserMedia({ video: true })`), (e) => e.name === 'NotFoundError');
  const state = cameraState(w);
  assert.deepEqual(state.calls, [{ video: true }]);   // the page's own constraints, to ask
  assert.deepEqual(state.stopped, ['real-cam']);      // and what it opened is closed again
});

test('system camera: a page that holds only the microphone permission still gets the virtual camera, asked for as on a first visit', async () => {
  const w = makeWindow(systemCamera(true), null, cameraPrelude({ micGranted: true }));
  // Its microphones are named, its cameras not yet: that is no sign the virtual camera is missing.
  assert.deepEqual(await listed(w), [['videoinput', '', ''], ['audioinput', 'mic', 'MacBook Air Microphone']]);
  assert.deepEqual(await openedBy(w, { video: true }), [['video', 'lumen-cam', 'live']]);
  const state = cameraState(w);
  assert.deepEqual(state.calls, [{ video: true }, { video: { deviceId: { exact: 'lumen-cam' } } }]);
  assert.deepEqual(state.stopped, ['real-cam']);
});

test('system camera, with the permission but no virtual device: NotFoundError, and the real camera is not even opened', async () => {
  const w = makeWindow(systemCamera(true), null, cameraPrelude({ granted: true, withVirtual: false }));
  await assert.rejects(run(w, `navigator.mediaDevices.getUserMedia({ video: true, audio: true })`), (e) => e.name === 'NotFoundError');
  const state = cameraState(w);
  assert.deepEqual(state.calls, []);
  assert.deepEqual(state.opened, []);
  // And the list agrees: no camera at all, as the call said.
  assert.deepEqual(await listed(w), [['audioinput', 'mic', 'MacBook Air Microphone']]);
});

test('system camera, first visit: a virtual camera that will not open → its error, never the real camera', async () => {
  const w = makeWindow(systemCamera(true), null, cameraPrelude({ virtualFails: true }));
  await assert.rejects(run(w, `navigator.mediaDevices.getUserMedia({ video: true })`), (e) => e.name === 'NotReadableError');
  const state = cameraState(w);
  assert.deepEqual(state.opened, ['real-cam']);
  assert.deepEqual(state.stopped, ['real-cam']);
});

test('system camera: a denial, a call without video and a pinned device are the engine\'s own', async () => {
  const denied = makeWindow(systemCamera(true), null, cameraPrelude({ deny: true }));
  await assert.rejects(run(denied, `navigator.mediaDevices.getUserMedia({ video: true })`), (e) => e.name === 'NotAllowedError');
  const w = makeWindow(systemCamera(true), null, cameraPrelude({ granted: true }));
  assert.deepEqual(await openedBy(w, { audio: true }), [['audio', 'mic', 'live']]);
  assert.deepEqual(await openedBy(w, { video: { deviceId: { exact: 'real-cam' } } }), [['video', 'real-cam', 'live']]);
  await assert.rejects(run(w, `navigator.mediaDevices.getUserMedia()`), (e) => e.name === 'TypeError');
});

test('system camera: a request is read once, as the engine reads it — a getter that changes its answer never opens the Mac\'s camera', async () => {
  for (const granted of [true, false]) {
    const w = makeWindow(systemCamera(true), null, cameraPrelude({ granted }));
    // No video the first time it is read, a video after: the engine is handed what was read, which asks for nothing.
    await assert.rejects(run(w, `(() => { let n = 0; return navigator.mediaDevices.getUserMedia({ get video() { return n++ > 0; } }); })()`),
                         (e) => e.name === 'TypeError', `granted ${granted}`);
    assert.deepEqual(cameraState(w).opened, [], `granted ${granted}: a getter that changes its answer`);
    // WebIDL: video null asks for the camera: the virtual one.
    assert.deepEqual(await openedBy(w, { video: null }), [['video', 'lumen-cam', 'live']], `granted ${granted}: video null`);
    const state = cameraState(w);
    assert.equal(state.opened.filter((id) => id === 'real-cam').length, state.stopped.filter((id) => id === 'real-cam').length,
                 `granted ${granted}: a real camera opened was stopped unseen`);
  }
});

// A request's outcome: its tracks, or the name of its error; and whether every Mac camera opened was
// stopped before the page held it.
const outcomeOf = (w, expr) => run(w, `navigator.mediaDevices.getUserMedia(${expr}).then((s) => JSON.stringify(s.getTracks().map((t) => [t.kind, t.deviceId, t.readyState])), (e) => e.name)`);
const realStoppedUnseen = (w) => {
  const state = cameraState(w);
  return state.opened.filter((id) => id === 'real-cam').length === state.stopped.filter((id) => id === 'real-cam').length;
};

test('system camera: only an exact pin is the engine\'s — a bare deviceId, a list, { ideal } or an empty exact gets the virtual camera', async () => {
  const virtual = JSON.stringify([['video', 'lumen-cam', 'live']]);
  for (const granted of [true, false]) {
    for (const [name, expr, expected] of [
      ['video: true', `{ video: true }`, virtual],
      // WebIDL: a bare string is the basic set's ideal, which the engine meets with its default camera.
      ['a bare id nothing has', `{ video: { deviceId: 'anything' } }`, virtual],
      // A bare id of the Mac's camera (one a site saved before): an ideal too, never a pin.
      ['a bare id of the Mac\'s camera', `{ video: { deviceId: 'real-cam' } }`, virtual],
      ['a list', `{ video: { deviceId: ['anything', 'real-cam'] } }`, virtual],
      ['{ ideal }', `{ video: { deviceId: { ideal: 'anything' } } }`, virtual],
      ['{ exact: \'\' }', `{ video: { deviceId: { exact: '' } } }`, virtual],
      ['{ exact: [] }', `{ video: { deviceId: { exact: [] } } }`, virtual],
      // An exact id is the engine's: one nothing has is its OverconstrainedError, before anything opens.
      ['{ exact } of nothing', `{ video: { deviceId: { exact: 'unknown' } } }`, 'OverconstrainedError'],
      ['{ exact: [ids] } of nothing', `{ video: { deviceId: { exact: ['unknown', 'other'] } } }`, 'OverconstrainedError'],
    ]) {
      const w = makeWindow(systemCamera(true), null, cameraPrelude({ granted }));
      assert.equal(await outcomeOf(w, expr), expected, `granted ${granted}: ${name}`);
      assert.ok(realStoppedUnseen(w), `granted ${granted}: ${name}: ${JSON.stringify(cameraState(w))}`);
      if (expected === 'OverconstrainedError') assert.deepEqual(cameraState(w).opened, [], `granted ${granted}: ${name}`);
    }
  }
});

test('system camera: a deviceId is read once and handed on as read — a getter that pins for the shim and not for the engine never opens the Mac\'s camera', async () => {
  for (const granted of [true, false]) {
    for (const [name, expr] of [
      // { exact } for the first reads, nothing after: the engine would have opened its default camera.
      ['deviceId', `(() => { let r = 0; return { video: { get deviceId() { r++; return r <= 2 ? { exact: 'zzz' } : undefined; } } }; })()`],
      ['deviceId.exact', `(() => { let r = 0; return { video: { deviceId: { get exact() { r++; return r <= 2 ? 'zzz' : undefined; } } } }; })()`],
      // A list whose own iterator gives an id to whoever reads it first, nothing after.
      ['exact: an iterable', `(() => { let r = 0; return { video: { deviceId: { exact: { [Symbol.iterator]() { r++; return (r <= 1 ? ['zzz'] : [])[Symbol.iterator](); } } } } }; })()`],
    ]) {
      const w = makeWindow(systemCamera(true), null, cameraPrelude({ granted }));
      const outcome = await outcomeOf(w, expr);
      assert.ok(outcome === 'OverconstrainedError' || outcome === JSON.stringify([['video', 'lumen-cam', 'live']]), `granted ${granted}: ${name}: ${outcome}`);
      assert.ok(realStoppedUnseen(w), `granted ${granted}: ${name}: ${JSON.stringify(cameraState(w))}`);
    }
    // Arrays a page replaced the iterator of: the engine is handed the ids that were read.
    const w = makeWindow(systemCamera(true), null, cameraPrelude({ granted }));
    run(w, `var arrayIterator = Array.prototype[Symbol.iterator]; Array.prototype[Symbol.iterator] = function () { return arrayIterator.call([]); };`);
    const outcome = await outcomeOf(w, `{ video: { deviceId: { exact: ['zzz'] } } }`);
    run(w, `Array.prototype[Symbol.iterator] = arrayIterator;`);
    assert.equal(outcome, 'OverconstrainedError', `granted ${granted}: a page's array iterator`);
    assert.deepEqual(cameraState(w).opened, [], `granted ${granted}: a page's array iterator`);
  }
});

test('system camera: what a page puts in the engine\'s place never decides where a request goes, nor gets what the engine opened', async () => {
  const virtual = JSON.stringify([['video', 'lumen-cam', 'live']]);
  for (const granted of [true, false]) {
    // Every camera's label answers the virtual camera's name: the Mac's camera, listed first, would be taken for it.
    const w = makeWindow(systemCamera(true), null, cameraPrelude({ granted }));
    run(w, `Object.defineProperty(MediaDeviceInfo.prototype, 'label', { get() { return 'Lumen Camera'; }, configurable: true });
            Object.defineProperty(MediaDeviceInfo.prototype, 'kind', { get() { return 'videoinput'; }, configurable: true });`);
    assert.equal(await outcomeOf(w, `{ video: true }`), virtual, `granted ${granted}: a label getter`);
    assert.ok(realStoppedUnseen(w), `granted ${granted}: a label getter`);
    // Nor is the Mac's camera listed for it: its id is what would let a page pin it.
    const ids = await run(w, `navigator.mediaDevices.enumerateDevices().then((l) => JSON.stringify(l.map((d) => JSON.stringify(d))))`).then(JSON.parse);
    assert.ok(!ids.some((d) => d.includes('real-cam')), `granted ${granted}: listed ${ids}`);

    // Every label empty: as before the permission, so nothing is dropped from the list.
    const blank = makeWindow(systemCamera(true), null, cameraPrelude({ granted: true }));
    run(blank, `Object.defineProperty(MediaDeviceInfo.prototype, 'label', { get() { return ''; }, configurable: true });`);
    const blankIds = await run(blank, `navigator.mediaDevices.enumerateDevices().then((l) => JSON.stringify(l.map((d) => JSON.stringify(d))))`).then(JSON.parse);
    assert.ok(!blankIds.some((d) => d.includes('real-cam')), `an empty label getter: listed ${blankIds}`);

    // The stream the engine opened at the first grant, asked to a page's methods or then.
    const s = makeWindow(systemCamera(true), null, cameraPrelude({ granted }));
    run(s, `var seen = [];
            var nativeThen = Promise.prototype.then;
            for (const name of ['getTracks', 'getVideoTracks']) {
              const f = MediaStream.prototype[name];
              MediaStream.prototype[name] = function () { seen.push(this); return f.apply(this, arguments); };
            }
            for (const name of ['getSettings', 'stop']) {
              const f = MediaStreamTrack.prototype[name];
              MediaStreamTrack.prototype[name] = function () { seen.push(this); return f.apply(this, arguments); };
            }
            Promise.prototype.then = function (a, b) { seen.push(this); return nativeThen.call(this, a, b); };
            Object.defineProperty(Promise.prototype, 'constructor', { get() { seen.push(this); return Promise; }, configurable: true });`);
    const outcome = await outcomeOf(s, `{ video: true }`);
    run(s, `Promise.prototype.then = nativeThen; delete Promise.prototype.constructor; Promise.prototype.constructor = Promise;`);
    assert.equal(outcome, virtual, `granted ${granted}: replaced methods`);
    // Whatever a page's code was handed holds none of the Mac's camera: no stream, track or promise of it.
    const reached = await run(s, `Promise.all(seen.map((x) => (x && typeof x.then === 'function' && !(x instanceof MediaStream))
                                    ? Promise.prototype.then.call(x, (v) => v, () => null) : x))
                                  .then((all) => JSON.stringify(all.map((x) => x instanceof MediaStream ? x.getTracks().map((t) => t.deviceId)
                                                                          : x instanceof MediaStreamTrack ? [x.deviceId]
                                                                          : Array.isArray(x) ? x.map((d) => { try { return d.deviceId; } catch (e) { return '?'; } }) : [])))`)
      .then(JSON.parse);
    assert.ok(!reached.flat().includes('real-cam'), `granted ${granted}: a page's code was handed ${JSON.stringify(reached)}`);
  }
});

test('system camera: the track a page holds names the virtual camera with the profile\'s name, never "Lumen Camera"', async () => {
  const labels = (w, constraints) => run(w, `navigator.mediaDevices.getUserMedia(${JSON.stringify(constraints)}).then((s) => JSON.stringify(s.getTracks().map((t) => t.label)))`).then(JSON.parse);
  const w = makeWindow(systemCamera(true), null, cameraPrelude({ granted: true }));
  assert.deepEqual(await labels(w, { video: true, audio: true }), ['FaceTime HD Camera', 'MacBook Air Microphone']);
  // The first visit's track too: the one returned is the virtual camera, under the profile's name.
  assert.deepEqual(await labels(makeWindow(systemCamera(true), null, cameraPrelude()), { video: true }), ['FaceTime HD Camera']);
  // A real camera a page pins keeps its own name; so does every camera in a profile not using it.
  assert.deepEqual(await labels(w, { video: { deviceId: { exact: 'real-cam' } } }), ['Камера (MacBook Air)']);
  assert.deepEqual(await labels(makeWindow(systemCamera(false), null, cameraPrelude({ granted: true })), { video: true }), ['Камера (MacBook Air)']);
  // The accessor stays the engine's shape.
  assert.equal(run(w, `Object.getOwnPropertyNames(Object.getOwnPropertyDescriptor(MediaStreamTrack.prototype, 'label').get).join()`), 'length,name');
  assert.match(run(w, `Function.prototype.toString.call(Object.getOwnPropertyDescriptor(MediaStreamTrack.prototype, 'label').get)`), /\[native code\]/);
});

// "No camera" — the drawing shim's block mode, which a substitution through a system camera that is
// not on also falls back to (PrivacyScripts.cameraScript): as a Mac with every camera unplugged.
const noCamera = { ...base, camera: { mode: 'block', source: 'color', width: 1280, height: 720, frameRate: 30, fit: 'cover', mirror: false,
                                      label: '', color: '#1E2130', audio: 'real', screenShare: false, secret: 'lumen' } };

test('"No camera": none listed before the permission or after, a camera request is NotFoundError, the microphone is left alone', async () => {
  assert.deepEqual(await listed(makeWindow(noCamera, null, cameraPrelude())), [['audioinput', '', '']]);
  const w = makeWindow(noCamera, null, cameraPrelude({ granted: true }));
  assert.deepEqual(await listed(w), [['audioinput', 'mic', 'MacBook Air Microphone']]);
  await assert.rejects(run(w, `navigator.mediaDevices.getUserMedia({ video: true, audio: true })`), (e) => e.name === 'NotFoundError');
  assert.deepEqual(cameraState(w).opened, []);   // no camera opened for it
  assert.deepEqual(await openedBy(w, { audio: true }), [['audio', 'mic', 'live']]);
});

// The drawn camera ("Substitute", delivered by the shim) and "No camera": no request reaches the
// Mac's camera, whatever object it is made on, whichever frame's function makes it, and however its
// members answer. The engine's receiver check takes a MediaDevices of any frame (WebIDL), so a frame's
// function called on another frame's object (or the other way round) is a request the engine serves.
const drawnCamera = { ...base, camera: { ...noCamera.camera, mode: 'substitute' } };
const cameraCalls = [
  // This frame's function, a frame's MediaDevices.
  ['this function, a frame\'s object', `MediaDevices.prototype.getUserMedia.call(__frameDevices, { video: true })`],
  // A frame's function — the "clean function from an iframe" — on this frame's own object.
  ['a frame\'s function, this object', `__frameGetUserMedia.call(navigator.mediaDevices, { video: true })`],
  // WebIDL: a member that is null asks for the device, as an object does.
  ['video: null', `navigator.mediaDevices.getUserMedia({ video: null })`],
];
const cameraOpened = (...windows) => windows.flatMap((w) => cameraState(w).opened);

test('drawn camera and "No camera": another frame\'s MediaDevices or getUserMedia never reaches the Mac\'s camera', async () => {
  for (const [mode, config] of [['block', noCamera], ['substitute', drawnCamera]]) {
    const top = makeWindow(config, null, cameraPrelude({ granted: true, canvas: true }));
    const frame = makeWindow(config, top, cameraPrelude({ granted: true, canvas: true }));
    top.__frameDevices = run(frame, 'navigator.mediaDevices');
    top.__frameGetUserMedia = run(frame, 'MediaDevices.prototype.getUserMedia');
    for (const [name, call] of cameraCalls) {
      const outcome = await run(top, call).then((stream) => stream.getTracks().map((t) => t.deviceId).join(), (e) => e.name);
      assert.equal(outcome, mode === 'block' ? 'NotFoundError' : 'drawn', `${mode}, ${name}`);
      assert.deepEqual(cameraOpened(top, frame), [], `${mode}, ${name}: the Mac's camera was opened`);
    }
    // What is no MediaDevices at all still gets the engine's TypeError, and opens nothing.
    await assert.rejects(async () => run(top, `MediaDevices.prototype.getUserMedia.call({}, { video: true })`), (e) => e.name === 'TypeError');
    assert.deepEqual(cameraOpened(top, frame), [], `${mode}: no MediaDevices`);
    // The list, asked of either object through either function, has no real camera in it: only the
    // drawn one, or none.
    top.__frameEnumerate = run(frame, 'MediaDevices.prototype.enumerateDevices');
    for (const call of [`MediaDevices.prototype.enumerateDevices.call(__frameDevices)`, `__frameEnumerate.call(navigator.mediaDevices)`]) {
      const cameras = await run(top, `${call}.then((l) => JSON.stringify(l.filter((d) => d.kind === 'videoinput').map((d) => d.deviceId)))`).then(JSON.parse);
      assert.equal(cameras.length, mode === 'block' ? 0 : 1, `${mode}, ${call}: ${JSON.stringify(cameras)}`);
      assert.ok(!cameras.includes('real-cam'), `${mode}, ${call}: ${JSON.stringify(cameras)}`);
    }
  }
});

test('drawn camera and "No camera": a request that answers the engine otherwise than the shim never reaches the Mac\'s camera', async () => {
  for (const [mode, config] of [['block', noCamera], ['substitute', drawnCamera]]) {
    const w = makeWindow(config, null, cameraPrelude({ granted: true, canvas: true }));
    // No video the first time it is read, a video after: the engine is never handed the page's object.
    await assert.rejects(run(w, `(() => { let n = 0; return navigator.mediaDevices.getUserMedia({ get video() { return n++ > 0; } }); })()`),
                         (e) => e.name === 'TypeError', mode);
    assert.deepEqual(cameraOpened(w), [], `${mode}: a getter that changes its answer`);
    // The microphone's request ("real" audio) is the shim's own object: what a page puts on
    // Object.prototype is no member of it.
    run(w, `var reads = 0; Object.defineProperty(Object.prototype, 'video', { get() { return reads++ > 0; }, configurable: true });`);
    const audioOnly = await run(w, `navigator.mediaDevices.getUserMedia({ audio: true }).then((s) => s.getTracks().map((t) => t.kind).join(), (e) => e.name)`);
    run(w, `delete Object.prototype.video;`);
    assert.equal(audioOnly, 'audio', mode);
    assert.deepEqual(cameraOpened(w), [], `${mode}: a video member on Object.prototype`);
  }
});

test('drawn camera: before the camera is granted its entry is Safari\'s placeholder — no name, no ids — after it, ids of the profile\'s own', async () => {
  const profile = (secret) => ({ ...base, camera: { ...drawnCamera.camera, secret, label: 'FaceTime HD Camera' } });
  const entry = (w) => run(w, `navigator.mediaDevices.enumerateDevices().then((l) => {
    const d = l.filter((x) => x.kind === 'videoinput')[0];
    return JSON.stringify({ deviceId: d.deviceId, groupId: d.groupId, label: d.label, json: d.toJSON(), caps: d.getCapabilities() });
  })`).then(JSON.parse);
  // Two copies of a profile, one secret (as before each copy got its own): a page that holds no
  // permission reads nothing that links them — as in Safari, an empty id, group and name.
  const placeholder = { deviceId: '', groupId: '', label: '', json: { deviceId: '', kind: 'videoinput', groupId: '', label: '' }, caps: {} };
  for (const granted of [false, true]) {
    const w = makeWindow(profile('secret-one'), null, cameraPrelude({ granted, canvas: true }));
    assert.deepEqual(await entry(w), placeholder, `the engine's permission ${granted}, not asked here yet`);
  }
  // Once the camera is granted: the profile's own per-origin ids and its name.
  const granted = async (secret) => {
    const w = makeWindow(profile(secret), null, cameraPrelude({ canvas: true }));
    await run(w, `navigator.mediaDevices.getUserMedia({ video: true })`);
    return entry(w);
  };
  const one = await granted('secret-one'), again = await granted('secret-one'), other = await granted('secret-two');
  assert.match(one.deviceId, /^[0-9a-f]{64}$/);
  assert.match(one.groupId, /^[0-9a-f]{64}$/);
  assert.equal(one.label, 'FaceTime HD Camera');
  assert.deepEqual(one.json, { deviceId: one.deviceId, kind: 'videoinput', groupId: one.groupId, label: 'FaceTime HD Camera' });
  assert.equal(one.caps.deviceId, one.deviceId);
  assert.deepEqual([again.deviceId, again.groupId], [one.deviceId, one.groupId], 'stable for one profile');
  assert.notEqual(other.deviceId, one.deviceId, 'another profile (another secret), another camera');
  assert.notEqual(other.groupId, one.groupId);
});

test('system camera installed, not this profile\'s: the virtual device is hidden, the Mac\'s camera stays as it is', async () => {
  const w = makeWindow(systemCamera(false), null, cameraPrelude({ granted: true }));
  assert.deepEqual(await listed(w), [['videoinput', 'real-cam', 'Камера (MacBook Air)'], ['audioinput', 'mic', 'MacBook Air Microphone']]);
  assert.deepEqual(await openedBy(w, { video: true }), [['video', 'real-cam', 'live']]);
});

// The scenario recorder's page side (ScenarioRecorderScript.swift): what it says of a field a person
// typed into. A secret — a password field, even one turned into text while focused, and what
// autocomplete names a password, a one-time code or a card's — is said as one, without its text.
const recorderSwift = readFileSync(new URL('../Sources/PrivacyBrowser/Browser/ScenarioRecorderScript.swift', import.meta.url), 'utf8');
const recorderBody = recorderSwift.split('private static let body = #"""')[1].split('"""#')[0];

async function recorderWindow() {
  const context = vm.createContext({});
  vm.runInContext(`
    var window = globalThis;
    window.top = window;
    var posted = [];
    var elements = [];
    const listeners = {};
    var addEventListener = (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); };
    var fire = (type, target, extra) => {
      const event = Object.assign({ type, target, isTrusted: true, isComposing: false, detail: 1, composedPath: () => [target] }, extra || {});
      for (const fn of listeners[type] || []) fn(event);
    };
    class Element {
      constructor(tag, attrs) { this.tagName = tag.toUpperCase(); this.attrs = Object.assign({}, attrs); this.isConnected = true; this.parentElement = null; this.nodeType = 1; }
      getAttribute(name) { return name in this.attrs ? String(this.attrs[name]) : null; }
      get id() { return this.attrs.id || ''; }
      closest() { return null; }
    }
    class HTMLInputElement extends Element { constructor(attrs) { super('input', attrs); this.type = this.attrs.type || 'text'; this.value = ''; } }
    class HTMLTextAreaElement extends Element { constructor(attrs) { super('textarea', attrs); this.value = ''; } }
    class HTMLSelectElement extends Element { constructor(attrs, label) { super('select', attrs); this.selectedOptions = [{ label }]; } }
    class HTMLLabelElement extends Element {}
    Object.assign(globalThis, { Element, HTMLInputElement, HTMLTextAreaElement, HTMLSelectElement, HTMLLabelElement });
    var CSS = { escape: (text) => text };
    var document = { querySelectorAll: (selector) => elements.filter((e) => '#' + e.id === selector), body: {}, documentElement: {} };
    var location = { href: 'https://example.com/login' };
    var performance = { now: () => 0 };
    window.webkit = { messageHandlers: { rec: { postMessage: (message) => { posted.push(message); return { recording: true }; } } } };
    var typeInto = (attrs, text, change) => {
      const el = new HTMLInputElement(attrs);
      elements.push(el);
      fire('focusin', el);
      if (change) change(el);
      el.value = text;
      fire('input', el);
      fire('focusout', el);
      return posted.filter((m) => m.type === 'fill').pop();
    };
  `, context);
  vm.runInContext('const HANDLER = "rec";\n' + recorderBody, context);
  await new Promise((resolve) => setImmediate(resolve));   // the hello's reply: recording
  return context;
}

test('recorder: a password field, or one shown as text while focused, is said as a secret without its text', async () => {
  const w = await recorderWindow();
  assert.deepEqual(JSON.parse(run(w, `JSON.stringify(typeInto({ id: 'pw', type: 'password' }, 'hunter2'))`)),
                   { type: 'fill', selector: '#pw', value: '', secret: true, replaces: false });
  // "Show password": the field is a text field by the time it is typed into and left.
  const shown = JSON.parse(run(w, `JSON.stringify(typeInto({ id: 'pw2', type: 'password' }, 'hunter2', (el) => { el.type = 'text'; }))`));
  assert.equal(shown.secret, true);
  assert.equal(shown.value, '');
});

test('recorder: autocomplete passwords, one-time codes and card fields are secrets; an e-mail is not', async () => {
  const w = await recorderWindow();
  for (const [id, attrs] of [['np', { autocomplete: 'new-password' }], ['cp', { autocomplete: 'section-login current-password' }],
                             ['otp', { autocomplete: 'one-time-code', inputmode: 'numeric' }], ['cc', { autocomplete: 'billing cc-number' }],
                             ['csc', { autocomplete: 'CC-CSC' }]]) {
    const said = JSON.parse(run(w, `JSON.stringify(typeInto(${JSON.stringify({ id, ...attrs })}, '424242'))`));
    assert.equal(said.secret, true, id);
    assert.equal(said.value, '', id);
  }
  const email = JSON.parse(run(w, `JSON.stringify(typeInto({ id: 'mail', autocomplete: 'email' }, 'name@example.com'))`));
  assert.deepEqual([email.secret, email.value], [false, 'name@example.com']);
  // A card's month chosen in a list: which list, not which month.
  const note = run(w, `const s = new HTMLSelectElement({ id: 'exp', autocomplete: 'cc-exp-month' }, '07'); elements.push(s); fire('change', s);
                       posted.filter((m) => m.type === 'note').pop().value`);
  assert.equal(note, 'select #exp: •••');
});

// A web component's own elements (an open shadow root): the recorder names them through their
// host (`host >>> inner`), and the driver's find (PageDriver.findAll) looks there — not at a
// look-alike in the page itself. A stub DOM with shadow roots and the few selectors these use.
const driverSwift = readFileSync(new URL('../Sources/PrivacyBrowser/Browser/PageDriver.swift', import.meta.url), 'utf8');
const driverFindAll = driverSwift.split('private static let findAll = """')[1].split('"""')[0].replace(/\\\\/g, '\\');

async function shadowWindow() {
  const context = vm.createContext({});
  vm.runInContext(`
    var window = globalThis;
    window.top = window;
    var posted = [];
    const listeners = {};
    var addEventListener = (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); };
    // An event as a window's capture listener sees it: retargeted to the outermost host, its
    // composed path from the element itself out.
    var fire = (type, path, extra) => {
      const event = Object.assign({ type, target: path.find((n) => n.getRootNode && n.getRootNode() === document) || path[0],
                                    isTrusted: true, isComposing: false, detail: 1, composedPath: () => path }, extra || {});
      for (const fn of listeners[type] || []) fn(event);
    };
    var pathOf = (el) => { const path = []; for (let n = el; n; n = n.parentNode || n.host) path.push(n); return path.concat([window]); };
    class Node {
      constructor() { this.parentNode = null; this.children = []; }
      append(...kids) { for (const k of kids) { k.parentNode = this; this.children.push(k); } return this; }
      getRootNode() { let n = this; while (n.parentNode) n = n.parentNode; return n; }
      contains(other) { for (let n = other; n; n = n.parentNode) { if (n === this) return true; } return false; }
      querySelectorAll(selector) {
        const out = [];
        const walk = (n) => { for (const c of n.children) { if (matches(c, selector)) out.push(c); walk(c); } };
        walk(this);
        return out;
      }
      elementFromPoint() { return this.hit || null; }
    }
    class Element extends Node {
      constructor(tag, attrs, text) { super(); this.tagName = tag.toUpperCase(); this.attrs = Object.assign({}, attrs); this.ownText = text || ''; this.isConnected = true; this.nodeType = 1; this.shadowRoot = null; }
      get parentElement() { return this.parentNode instanceof Element ? this.parentNode : null; }
      getAttribute(name) { return name in this.attrs ? String(this.attrs[name]) : null; }
      get id() { return this.attrs.id || ''; }
      get innerText() { return [this.ownText, ...this.children.map((c) => c.innerText)].filter(Boolean).join(' '); }
      closest() { return null; }
      attachShadow() { this.shadowRoot = new ShadowRoot(this); return this.shadowRoot; }
    }
    class ShadowRoot extends Node { constructor(host) { super(); this.host = host; this.nodeType = 11; this.activeElement = null; } }
    class HTMLInputElement extends Element { constructor(attrs) { super('input', attrs); this.type = this.attrs.type || 'text'; this.value = ''; } }
    class HTMLTextAreaElement extends Element {}
    class HTMLSelectElement extends Element {}
    class HTMLLabelElement extends Element {}
    Object.assign(globalThis, { Node, Element, ShadowRoot, HTMLInputElement, HTMLTextAreaElement, HTMLSelectElement, HTMLLabelElement });
    // "*", "body *", and compounds (tag, #id, [name="value"], :nth-of-type(n)) joined by " > ".
    var matches = (el, selector) => {
      if (selector === '*') return true;
      if (selector === 'body *') return el !== document.body && document.body.contains(el);
      const compounds = selector.split(' > ');
      let node = el;
      for (let i = compounds.length - 1; i >= 0; i--) {
        if (!node || !(node instanceof Element)) return false;
        const m = /^([a-z-]+)?(?:#([\\w-]+))?(?:\\[([\\w-]+)="([^"]*)"\\])?(?::nth-of-type\\((\\d+)\\))?$/.exec(compounds[i]);
        if (!m) throw new SyntaxError('stub: ' + compounds[i]);
        if (m[1] && node.tagName.toLowerCase() !== m[1]) return false;
        if (m[2] && node.id !== m[2]) return false;
        if (m[3] && node.getAttribute(m[3]) !== m[4]) return false;
        if (m[5]) {
          const same = node.parentNode.children.filter((c) => c.tagName === node.tagName);
          if (same.indexOf(node) + 1 !== Number(m[5])) return false;
        }
        node = node.parentNode;
      }
      return true;
    };
    var document = new Node();
    document.nodeType = 9;
    document.documentElement = new Element('html');
    document.body = new Element('body');
    document.append(document.documentElement);
    document.documentElement.append(document.body);
    var CSS = { escape: (text) => text };
    var location = { href: 'https://example.com/login' };
    var performance = { now: () => 0 };
    window.webkit = { messageHandlers: { rec: { postMessage: (message) => { posted.push(message); return { recording: true }; } } } };

    // A newsletter form in the page itself, and a login box whose form is its own (open shadow root).
    var footerEmail = new HTMLInputElement({ name: 'email' });
    var subscribe = new Element('button', {}, 'Subscribe');
    document.body.append(new Element('form').append(footerEmail, new Element('div').append(subscribe)));
    var loginBox = new Element('login-box');
    document.body.append(loginBox);
    var email = new HTMLInputElement({ name: 'email' });
    var proceed = new Element('button', {}, 'Continue');
    loginBox.attachShadow().append(new Element('form').append(email, new Element('div').append(proceed)));
  `, context);
  vm.runInContext('const HANDLER = "rec";\n' + recorderBody, context);
  vm.runInContext('globalThis.driver = (() => {\n' + driverFindAll + '\nreturn { find, at, holds, focused };\n})();', context);
  await new Promise((resolve) => setImmediate(resolve));   // the hello's reply: recording
  return context;
}

test('recorder and driver: a field and a button in an open shadow root are named through their host and found there', async () => {
  const w = await shadowWindow();
  run(w, `fire('focusin', pathOf(email)); email.value = 'me@example.com'; fire('input', pathOf(email)); fire('focusout', pathOf(email));
          fire('click', pathOf(proceed));`);
  const steps = JSON.parse(run(w, 'JSON.stringify(posted.filter((m) => m.type !== "hello"))'));
  assert.deepEqual(steps.map((m) => [m.type, m.selector]),
                   [['fill', 'body > login-box >>> input[name="email"]'], ['click', 'body > login-box >>> text=Continue']]);
  // The replay finds the component's own elements, not the newsletter's of the same shape.
  assert.equal(run(w, `driver.find(${JSON.stringify(steps[0].selector)})[0] === email`), true);
  assert.equal(run(w, `driver.find(${JSON.stringify(steps[1].selector)})[0] === proceed`), true);
  assert.equal(run(w, `driver.find('input[name="email"]').length === 1 && driver.find('input[name="email"]')[0] === footerEmail`), true,
               'a selector of the page itself still finds only the page\'s own');
  assert.equal(run(w, `driver.find('text=Continue').length`), 0, 'nor does a text of the page itself look into components');
  // Where the pointer lands: the button inside the box, not the box that hides it from the page.
  assert.equal(run(w, `document.hit = loginBox; loginBox.shadowRoot.hit = proceed; driver.at(5, 5) === proceed`), true);
  assert.equal(run(w, `driver.holds(proceed, driver.at(5, 5)) && driver.holds(loginBox, proceed) && !driver.holds(subscribe, proceed)`), true);
  assert.equal(run(w, `document.activeElement = loginBox; loginBox.shadowRoot.activeElement = email; driver.focused() === email`), true);
});

process.on('beforeExit', () => {
  if (failures) { console.log(`${failures} failure(s)`); process.exitCode = 1; }
  else console.log(`all shim tests passed (${JSC ? 'JavaScriptCore, Bun ' + Bun.version : 'V8, Node ' + process.version})`);
});
