// Tests the JavaScript privacy shims embedded in PrivacyScripts.swift under Node.js
// (V8 + full ICU). This checks the shim logic; it does not prove behaviour inside
// WebKit/JavaScriptCore — the self-test's "surface" checks do that against real WebKit.
// At its end: the scenario recorder's page side (ScenarioRecorderScript.swift) on a stub DOM.
//
//   TZ=America/New_York node scripts/test-shims.mjs
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

// The engine's own zone, whatever the environment says: the script replaces Date only where the
// engine is not in the profile's zone already, so the tests' zones must not be the engine's by
// chance. (Node and Bun both follow process.env.TZ as it changes; `inZone` below uses that to ask
// the engine itself what it answers in a zone.)
const HOME_ZONE = 'America/New_York';
process.env.TZ = HOME_ZONE;

const swift = readFileSync(new URL('../Sources/PrivacyBrowser/Browser/PrivacyScripts.swift', import.meta.url), 'utf8');
const body = swift.split('static let shimBody = #"""')[1].split('"""#')[0];

// What the engine knows of its own objects whatever their realm: a WebIDL receiver check accepts a
// platform object of the right interface from any frame (WebKit: jsDynamicCast), not only one of the
// function's own realm. Shared by every window made here, for the interfaces whose checks a test
// calls across frames (RTCPeerConnection, MediaDevices).
const engineObjects = new WeakSet();
// The engine's event listeners: one list per target, whatever realm registered or dispatches, and
// nothing a page can read (the DOM has no way to list a target's listeners).
const engineListeners = new WeakMap();
// What PrivacyScripts.shimConfiguration makes at random for each launch (`channel`): the type of
// the event by which the windows of a page find their family. A test may give its own, or none.
const CHANNEL = 'c7d1f0a2-test-channel';

// A realm shaped like a WebKit window: navigator and screen values are accessors on the
// prototypes that reject other receivers; window attributes are own accessors. `openerContext`
// is the window that opened this one (window.opener), for a window that has no parent. Without a
// configuration (null) the window is the engine's alone: the script is not installed in it.
function makeWindow(config, parentContext, prelude, openerContext) {
  const context = vm.createContext({});
  if (config !== null && !('channel' in config)) config = { ...config, channel: CHANNEL };
  // Taken by the realm's code and the prelude, and gone before the shim installs.
  Object.defineProperty(context, '__engineObjects', { value: engineObjects, configurable: true });
  Object.defineProperty(context, '__engineListeners', { value: engineListeners, configurable: true });
  vm.runInContext(`
    var window = globalThis;
    // Event targets, as far as the script's family channel reaches them: a WindowProxy and its
    // Window are one target, and an event is handed to the listeners of its type.
    {
      const listeners = globalThis.__engineListeners, callListener = Reflect.apply; // the engine's own call
      const targetOf = (t) => (t !== null && typeof t === 'object' && t.window ? t.window : t);
      globalThis.EventTarget = class EventTarget {
        addEventListener(type, listener) {
          const target = targetOf(this);
          if (!listeners.has(target)) listeners.set(target, []);
          listeners.get(target).push([String(type), listener]);
        }
        dispatchEvent(event) {
          for (const [type, listener] of listeners.get(targetOf(this)) || []) if (type === event.type) callListener(listener, this, [event]);
          return true;
        }
      };
    }
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
  if (openerContext) context.opener = openerContext;
  // What a test adds to the realm before the shim installs (the camera's devices, below).
  if (prelude) vm.runInContext(prelude, context);
  vm.runInContext('delete globalThis.__engineObjects; delete globalThis.__engineListeners;', context);
  if (config !== null) vm.runInContext(`(function install(CONFIG) {\n${body}\n})(${JSON.stringify(config)});`, context);
  return context;
}
// A window as the engine makes it, without the script: what a replacement is compared with.
const engineWindow = (prelude) => makeWindow(null, null, prelude);

const run = (w, code) => vm.runInContext(code, w);
// What the engine itself answers in `zone`: `ask` is given a window without the script, made and
// asked while the process is in that zone — synchronously, so that no other test runs meanwhile.
function inZone(zone, ask) {
  process.env.TZ = zone;
  try { return ask(engineWindow()); } finally { process.env.TZ = HOME_ZONE; }
}
// Bun runs JavaScriptCore, Safari's engine; Node runs V8.
const JSC = typeof Bun !== 'undefined';
let failures = 0;
function test(name, fn) {
  Promise.resolve().then(fn).then(
    () => console.log(`ok   ${name}`),
    (e) => { failures++; console.log(`FAIL ${name}\n     ${e.message}`); });
}
const nativeText = (name) => run(engineWindow(), 'Function.prototype.toString.call(Array.prototype.push)').replace('push', name);

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

test('pre-standard-time offsets: the local time keeps the seconds, getTimezoneOffset says whole minutes, as the engine does', () => {
  // Europe/Berlin local mean time: +00:53:28. Both engines keep the seconds in the local time and
  // drop them from getTimezoneOffset (measured: -53 in JavaScriptCore and in V8; until 15
  // November the replacement said -53.4666…, a number no engine gives).
  const w = makeWindow({ ...base, timeZone: 'Europe/Berlin' });
  assert.equal(run(w, `new Date('1113-07-01T12:00:00Z').getTimezoneOffset()`), -53);
  assert.equal(inZone('Europe/Berlin', (plain) => run(plain, `new Date('1113-07-01T12:00:00Z').getTimezoneOffset()`)), -53);
  // CreepJS: the local-parsed and the ISO-parsed date differ by the zone's offset, seconds and all.
  const measured = run(w, `(+new Date('7/1/1113') - +new Date('1113-07-01')) / 60000`);
  assert.ok(Math.abs(measured - (-53 - 28 / 60)) < 1e-6, `measured ${measured}`);
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

// ---- Time zone: the replacement against the engine itself --------------------------------------
// Where Date must be replaced (the engine in another zone), what a page reads must be what the
// engine itself answers in the profile's zone. So the engine is asked: the same expressions in a
// window without the script while the process is in the zone, and in a window with the script for
// that zone while the process is elsewhere — in V8 and in JavaScriptCore, each against itself.
const asText = (code) => `(() => { try { const r = (${code}); return typeof r === 'string' ? r : String(r); } catch (e) { return 'throws ' + e.constructor.name; } })()`;
const DAY = 86400000, RANGE = 8.64e15;
function dateQuestions(zone) {
  const questions = [];
  // The zone's name in Date#toString is compared too, but for two things. Lord Howe's years on
  // Sydney's time (to 1981) are named by today's zone in the engines and by that time's in a
  // formatter, which is where the replacement has its names from. And V8 — not JavaScriptCore,
  // Safari's engine — calls a zone's time daylight time at the range's far years (measured:
  // "Pacific Daylight Time" for the year -271821, "Samoa Daylight Time" for 274493).
  const nameOf = (question, t) => ((zone === 'Australia/Lord_Howe' && !(t >= 4e11)) || (!JSC && !(t >= -8e15 && t <= 8e15))
    ? `${question}.replace(/ \\(.*/, '')` : question);
  const instants = [0, 1, -1, 1705320000000, 1721044800000, 951782400000, 1710064799000, 1710064800000, 1728142200000, 1730624400000,
                    -2208988800000, -6847804800000, -62198755200000, -62167219200001, 253402300799999, 253402300800000, NaN,
                    RANGE, RANGE - 1, RANGE - 5 * 3600000, RANGE - 3 * DAY, -RANGE, -RANGE + 1, -RANGE + 5 * 3600000, -RANGE + 3 * DAY];
  for (const t of instants) {
    const d = `new Date(${t})`;
    // Within two days of the range's ends the engines themselves disagree on what a setter or a
    // local date gives (measured: JavaScriptCore NaN where V8 has an instant, and the reverse);
    // what a Date there says of itself they agree on, and so must the replacement.
    const atAnEnd = Math.abs(t) > RANGE - 2 * DAY;
    for (const getter of ['getFullYear', 'getMonth', 'getDate', 'getDay', 'getHours', 'getMinutes', 'getSeconds', 'getMilliseconds', 'getYear',
                          'getTimezoneOffset', 'toDateString', 'toISOString', 'valueOf'])
      questions.push(`${d}.${getter}()`);
    questions.push(nameOf(`${d}.toString()`, t), nameOf(`${d}.toTimeString()`, t));
    questions.push(`${d}.toLocaleString('en-US')`, `${d}.toLocaleDateString('en-GB', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })`,
                   `${d}.toLocaleTimeString('en-US', { timeZoneName: 'short' })`, `new Intl.DateTimeFormat('en-US', { dateStyle: 'full', timeStyle: 'long' }).format(${d})`);
    if (atAnEnd) continue;
    for (const [setter, args] of [['setHours', '0'], ['setHours', '25, 61, 61, 1001'], ['setMinutes', '-1'], ['setSeconds', '30, 5'], ['setMilliseconds', '999'],
                                  ['setDate', '31'], ['setDate', '0'], ['setMonth', '1, 29'], ['setMonth', '13'], ['setFullYear', '2024'], ['setFullYear', '2023, 1, 29'],
                                  ['setFullYear', '99'], ['setFullYear', '275000'], ['setFullYear', '-271000'], ['setYear', '99'], ['setYear', '2001'], ['setHours', ''],
                                  ['setFullYear', ''], ['setHours', 'NaN'], ['setYear', 'NaN'], ['setYear', ''], ['setHours', 'Infinity'], ['setMinutes', '1e12']])
      questions.push(`(() => { const d = ${d}; const r = d.${setter}(${args}); return [r, d.getTime(), d.getHours(), d.getDate()].join('|'); })()`);
  }
  for (const args of ['2024, 0, 15, 12', '2024, 0', '99, 0, 1', '0, 0, 1', '-1, 0, 1', '100, 0, 1', '2024, 2, 10, 2, 30', '2024, 10, 3, 1, 30', '2024, 2, 31, 2, 30', '2024, 9, 6, 2, 15',
                      '275760, 8, 10', '-271821, 3, 23', '2024, NaN', '2024, 0, 1, NaN', '2024, 0, 1, 0, NaN', '2024, 0, 1, 0, 0, 0, NaN', '2024, undefined', '2024, 0, undefined',
                      '2024, 0, 1, undefined', '2024, null', 'NaN, 0', 'Infinity, 0', '2024, 0, 1, 0, 0, 0, 0, 5', '2024.9, 0.9, 1.9, 1.9, 1.9, 1.9, 1.9', '"2024", "0"', '2020n, 1',
                      '2020, 1n', 'true, false', '1e9, 0', '-1e9, 0', '2024, 0, 1e10', '2024, 1e10', '1970, 0, 1, 0, 0, 0, 8.6e15', '1970, 0, 1, 0, 0, 0, -8.6e15', '2024, -1, 0, -1, -1, -1, -1'])
    questions.push(`new Date(${args}).getTime()`, nameOf(`new Date(${args}).toString()`, /^(\d{4}|"2024")/.test(args) && !/e\d/.test(args) ? Date.UTC(parseInt(args.replace('"', ''), 10), 0) : NaN));
  for (const text of ['2024-01-15T12:00:00', '2024-01-15T12:00:00.123', '2024-01-15T12:00', '2024-01-15', '2024-01', '2024', '2024-01-15T12:00:00Z', '2024-01-15T12:00:00+05:30',
                      'January 15, 2024 12:00:00', '1/15/2024', '15 Jan 2024 12:00 UTC', 'Mon Jan 15 2024 12:00:00 GMT+0100 (CET)', 'Jan 15 2024', '2024-03-10T02:30:00',
                      '2024-11-03T01:30:00', '2024-03-31T02:30:00', '2024-10-06T02:15:00', '1113-07-01T00:00:00', '7/1/1113', '+275760-09-13T00:00:00.000Z', '-271821-04-20T00:00:00.000Z',
                      '  2024-01-15T12:00:00  ', '', 'garbage', '2024-02-30', 'Thu, 01 Jan 1970 00:00:00 GMT', '1970-01-01T00:00:00', '12/31/1969', '2024-01-15 12:00:00',
                      '2024-01-15T12:00:00 EST', 'Jan 1 2000 10:00 PST', '2000', '1/1/99'])
    questions.push(`Date.parse(${JSON.stringify(text)})`, `new Date(${JSON.stringify(text)}).getTime()`);
  questions.push(
    // What the one argument of `new Date(value)` is made of, and how often it is asked.
    `new Date({ valueOf() { return 5; } }).getTime()`, `new Date({ toString() { return '2024-01-15T12:00:00'; }, valueOf() { return {}; } }).getTime()`,
    `new Date({ [Symbol.toPrimitive](hint) { return hint; } }).getTime()`, `new Date({ [Symbol.toPrimitive]() { return '2024-01-15T12:00:00'; } }).getTime()`,
    `new Date(new Date(1234.5)).getTime()`, `new Date(Object.create(null)).getTime()`, `new Date({ [Symbol.toPrimitive]: 5 }).getTime()`, `new Date(Symbol()).getTime()`,
    `new Date(5n).getTime()`, `new Date(true).getTime()`, `new Date(null).getTime()`, `new Date(undefined).getTime()`, `new Date('').getTime()`, `new Date([]).getTime()`,
    `new Date([2024]).getTime()`, `new Date({}).getTime()`, `new Date(new String('2024-01-15T12:00:00')).getTime()`, `new Date(new Number(7)).getTime()`,
    `(() => { let n = 0; const o = { toString() { n++; return '2024-01-15T12:00:00'; } }; Date.parse(o); return n; })()`,
    `(() => { let n = 0; const o = { toString() { n++; return '2024-01-15T12:00:00'; } }; new Date(o); return n; })()`,
    `(() => { const log = []; const o = (n) => ({ valueOf() { log.push(n); return n; } }); new Date(o(2020), o(1), o(2), o(3), o(4), o(5), o(6), o(7), o(8)); return log.join(); })()`,
    `(() => { const log = []; const o = (n) => ({ valueOf() { log.push(n); return n; } }); new Date(NaN).setHours(o(1), o(2), o(3), o(4), o(5)); return log.join(); })()`,
    `(() => { const log = []; const o = (n) => ({ valueOf() { log.push(n); return n; } }); new Date(0).setHours(o(1), o(2), o(3), o(4), o(5)); return log.join(); })()`,
    `(() => { const log = []; const o = (n) => ({ valueOf() { log.push(n); return n; } }); new Date(0).setFullYear(o(1), o(2), o(3), o(4)); return log.join(); })()`,
    `Date.parse(Symbol())`, `Date.parse()`, `Date.parse(undefined)`, `Date.parse(null)`, `Date.parse(2024)`, `typeof Date()`, `Date(0) === Date()`, `Date.length`, `Date.UTC(2024, 0)`,
    `Date() === new Date().toString()`, `Date.prototype.constructor === Date`, `new Date(2024, 0, 15) instanceof Date`,
    // The options of a formatter: what the engine makes of them, and what it asks the page's object.
    `new Intl.DateTimeFormat('en', null).resolvedOptions().timeZone`, `new Date(0).toLocaleString('en', null)`, `new Date(0).toLocaleDateString('en', null)`,
    `new Intl.DateTimeFormat('en', Object.create({ timeZone: 'UTC' })).resolvedOptions().timeZone`, `new Intl.DateTimeFormat('en', 5).resolvedOptions().timeZone`,
    `new Intl.DateTimeFormat('en', 'x').resolvedOptions().timeZone`, `new Intl.DateTimeFormat('en', { timeZone: undefined }).resolvedOptions().timeZone`,
    `new Intl.DateTimeFormat('en', { timeZone: 'Asia/Kolkata' }).resolvedOptions().timeZone`, `new Intl.DateTimeFormat('en', { timeZone: 'bogus' }).resolvedOptions().timeZone`,
    `new Intl.DateTimeFormat('en', { timeZone: null }).resolvedOptions().timeZone`, `new Intl.DateTimeFormat().resolvedOptions().timeZone`,
    `(() => { const log = []; const o = new Proxy({}, { get(t, k, r) { log.push(String(k) + (r === o ? '' : '!')); return undefined; }, has() { log.push('has'); return false; },
        ownKeys() { log.push('ownKeys'); return []; }, getOwnPropertyDescriptor() { log.push('descriptor'); return undefined; }, getPrototypeOf() { log.push('prototype'); return null; } });
        new Intl.DateTimeFormat('en', o); return log.join(); })()`,
    `(() => { const log = []; const o = new Proxy({}, { get(t, k, r) { log.push(String(k) + (r === o ? '' : '!')); return undefined; }, has() { log.push('has'); return false; },
        ownKeys() { log.push('ownKeys'); return []; }, getOwnPropertyDescriptor() { log.push('descriptor'); return undefined; } });
        new Date(0).toLocaleString('en', o); new Date(0).toLocaleTimeString('en', o); return log.join(); })()`,
    `(() => { const log = []; const o = { get timeZone() { log.push('zone' + (this === o)); return 'UTC'; }, get hour() { log.push('hour' + (this === o)); return '2-digit'; } };
        const f = new Intl.DateTimeFormat('en', o); return log.join() + f.resolvedOptions().timeZone; })()`,
    `(() => { const log = []; const o = { get timeZone() { log.push('zone'); return undefined; } }; return new Intl.DateTimeFormat('en', o).resolvedOptions().timeZone + log.join(); })()`,
    `new Intl.DateTimeFormat('en-US', Object.freeze({ hour: 'numeric' })).format(new Date(1705320000000))`,
    `(() => { class F extends Intl.DateTimeFormat {} return new F('en-US', { hour: 'numeric' }).format(new Date(1705320000000)) + (new F() instanceof F) + (new F() instanceof Intl.DateTimeFormat); })()`,
    `Intl.DateTimeFormat('en-US', { hour: 'numeric' }).format(new Date(1705320000000))`, `Intl.DateTimeFormat.supportedLocalesOf('en-US').join()`,
    `Intl.DateTimeFormat().formatToParts(new Date(0)).length`, `new Intl.DateTimeFormat('en-US', { timeZoneName: 'long' }).format(new Date(1705320000000))`,
    // Subclasses, Reflect, conversions.
    `(() => { class D extends Date { constructor(...a) { super(...a); } } const d = new D(2024, 0, 15, 12); return [d.getTime(), d instanceof D, d.getHours()].join('|'); })()`,
    `Reflect.construct(Date, [2024, 0, 15, 12]).getTime()`, `Object.prototype.toString.call(Reflect.construct(Date, [], Object))`, `JSON.stringify(new Date(1705320000000))`,
    `new Date(1705320000000) - new Date(2024, 0, 15)`, `String(new Date(1705320000000))`, `new Date(1705320000000) + ''`, `new Date(1705320000000).toUTCString()`,
    `new Date(2024, 0, 15, 12)[Symbol.toPrimitive]('number')`, `new Date(1705320000000)[Symbol.toPrimitive]('default')`,
    // The wrong receiver: the engine's own error.
    `Date.prototype.getHours.call({})`, `Date.prototype.setHours.call({}, 1)`, `Date.prototype.toString.call({})`, `Date.prototype.getTimezoneOffset.call(null)`,
    `Date.prototype.toLocaleString.call({})`, `Date.prototype.setYear.call({}, 1)`, `Date.prototype.getYear.call(new Proxy(new Date(), {}))`, `Date.prototype.toDateString.call(Date.prototype)`);
  return questions;
}
for (const zone of ['Asia/Tokyo', 'Europe/Berlin', 'America/Los_Angeles', 'Australia/Lord_Howe', 'Asia/Kolkata', 'UTC', 'Pacific/Kiritimati', 'America/St_Johns', 'Asia/Kathmandu', 'Pacific/Apia']) {
  test(`Date and Intl.DateTimeFormat for ${zone} answer what the engine itself answers there`, () => {
    const questions = dateQuestions(zone);
    const engine = inZone(zone, (plain) => questions.map((q) => run(plain, asText(q))));
    const w = makeWindow({ ...base, timeZone: zone });
    assert.equal(run(w, `Date.prototype.getHours.toString().includes('[native code]') && Date.name`), 'Date');
    const differing = [];
    questions.forEach((q, i) => { const got = run(w, asText(q)); if (got !== engine[i]) differing.push(`${q}\n       the engine: ${engine[i]}\n       the script: ${got}`); });
    assert.equal(differing.length, 0, `${differing.length} of ${questions.length} differ:\n     ${differing.slice(0, 8).join('\n     ')}`);
  });
}

test('a page that replaces built-ins and watches them sees no more calls with the replacement Date than with the engine\'s', () => {
  // What a hand-written Date would go through: Function.prototype.call, isNaN, Map, the formatter's
  // own methods, array iteration, string padding, Object.assign, Reflect.construct, Math.
  const places = [['Function.prototype', 'call'], ['Function.prototype', 'apply'], ['Function.prototype', 'bind'], ['window', 'isNaN'], ['window', 'String'], ['window', 'Number'],
                  ['Map.prototype', 'get'], ['Map.prototype', 'set'], ['Map.prototype', 'has'], ['Intl.DateTimeFormat.prototype', 'formatToParts'],
                  ['Intl.DateTimeFormat.prototype', 'resolvedOptions'], ['Array.prototype', 'map'], ['Array.prototype', 'find'], ['Array.prototype', Symbol.iterator.toString()],
                  ['String.prototype', 'padStart'], ['String.prototype', 'trim'], ['String.prototype', 'replace'], ['Object', 'assign'], ['Object', 'keys'], ['Reflect', 'construct'],
                  ['Reflect', 'apply'], ['Reflect', 'get'], ['Math', 'floor'], ['Math', 'trunc'], ['Math', 'abs'], ['RegExp.prototype', 'exec'], ['RegExp.prototype', 'test'],
                  ['Date', 'UTC'], ['Date', 'now'], ['Date.prototype', 'getTime'], ['Date.prototype', 'setTime'], ['Date.prototype', 'getUTCHours'], ['Date.prototype', 'setUTCHours'],
                  ['Date.prototype', 'setUTCFullYear'], ['Date.prototype', 'getUTCFullYear'], ['WeakMap.prototype', 'get']].filter(([, key]) => !String(key).startsWith('Symbol'));
  const use = `(() => { spied.length = 0;
    const d = new Date(2024, 0, 15, 12, 30); d.getHours(); d.getDay(); d.getTimezoneOffset(); d.setHours(3); d.setFullYear(2020, 1, 29); d.setYear(99);
    new Date('2024-01-15T12:00:00'); Date.parse('1/15/2024'); new Date(d); new Date(); new Date(0).toDateString(); new Date(-1).toTimeString();
    new Date(1705320000000).toLocaleString('en-US'); new Date(1705320000000).toLocaleDateString('en-US', { year: 'numeric' });
    new Intl.DateTimeFormat('en-US', { hour: 'numeric' }).format(d); Intl.DateTimeFormat('en-US');
    return spied.join(); })()`;
  const plain = engineWindow();
  spyOn(plain, places);
  const expected = run(plain, use);
  const w = makeWindow({ ...base, timeZone: 'Asia/Tokyo' });
  spyOn(w, places);
  assert.equal(run(w, use), expected);
  // And the replacement works with them replaced: the page's functions are not what it runs on.
  assert.equal(run(w, `new Date(2024, 0, 15, 12).toISOString()`), '2024-01-15T03:00:00.000Z');
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
  // No way in for a page: the key the registry was once handed out for (until 15 November) gets
  // the engine's TypeError, as any symbol does.
  assert.throws(() => run(w, 'Function.prototype.toString.call(Symbol.for("wk.shim.registry"))'), (e) => e.name === 'TypeError');
});

// ---- What a page can ask the script (the probes of an anti-bot script) -----------------------
// The same question put to a window with the script and to one without it: the answers must be
// the same, whatever is asked.
const sameAsEngine = (w, plain, code, what) => {
  const answer = (window) => { try { return String(run(window, code)); } catch (e) { return `throws ${e.name}: ${e.message}`; } };
  assert.equal(answer(w), answer(plain), what || code);
};
// Spies on built-ins a page can replace (`[object expression, key]` each): every call is noted in
// the window's `spied` and passed on. The spies themselves call through functions taken before.
const spyOn = (w, places) => {
  w.spied = [];
  run(w, `(() => { const apply = Reflect.apply, construct = Reflect.construct, note = Array.prototype.push;
    for (const [expr, key] of ${JSON.stringify(places)}) {
      const o = (0, eval)(expr), f = o[key];
      if (typeof f !== 'function') continue;
      o[key] = function (...a) { apply(note, spied, [expr + '.' + key]); return new.target ? construct(f, a, new.target) : apply(f, this, a); };
    } })()`);
  run(w, 'spied.length = 0');
};

test('Function.prototype.toString answers every receiver as the engine does — no key hands a page the registry', () => {
  const w = makeWindow(everything), plain = engineWindow();
  for (const receiver of [`Symbol.for('wk.shim.registry')`, `Symbol.for(${JSON.stringify(CHANNEL)})`, `Symbol('x')`, 'undefined', 'null', '1', '"s"', '{}', '[]',
                          'new Proxy(function f() {}, {})', 'new Proxy({}, {})', 'function () {}.bind(null)', 'class A { m() {} }', '(a, b) => a + b',
                          'Object.create(Function.prototype)', 'Array.prototype.push', 'async function* g() {}']) {
    sameAsEngine(w, plain, `Function.prototype.toString.call(${receiver})`);
  }
  // Nothing of the family is a property of anything a page reaches.
  sameAsEngine(w, plain, `[window, Function.prototype, Function.prototype.toString, Date, Date.prototype.getHours, Event.prototype, EventTarget.prototype]
    .map((o) => Object.getOwnPropertySymbols(o).length).join()`);
  assert.equal(run(w, `Object.getOwnPropertyNames(Function.prototype.toString).join()`), 'length,name');
});

test('the windows of a page — frames, a nested frame, a window it opened — print each other\'s replacements as native, both ways', () => {
  const top = makeWindow(everything);
  const frame = makeWindow(everything, top);
  const nested = makeWindow(everything, frame);
  const popup = makeWindow(everything, null, null, top);
  const windows = { top, frame, nested, popup };
  for (const [printer, w] of Object.entries(windows)) {
    for (const [owner, other] of Object.entries(windows)) {
      w.other = other;
      assert.equal(run(w, `Function.prototype.toString.call(other.Date.prototype.getHours)`), nativeText('getHours'), `${printer} prints ${owner}'s getHours`);
      assert.equal(run(w, `Function.prototype.toString.call(other.Date)`), nativeText('Date'), `${printer} prints ${owner}'s Date`);
      assert.equal(run(w, `Function.prototype.toString.call(other.Function.prototype.toString)`), nativeText('toString'), `${printer} prints ${owner}'s toString`);
      assert.equal(run(w, `Function.prototype.toString.call(Object.getOwnPropertyDescriptor(other.PermissionStatus.prototype, 'state').get)`), nativeText('state'));
    }
  }
  // Until 15 November a window that was no frame of the other printed its replacements' source.
  top.other = popup;
  assert.doesNotMatch(run(top, `other.Function.prototype.toString.call(Date.prototype.getHours)`), /ReflectApply|=>|impl/);
});

test('a frame is patched once: reached by the page through contentWindow after its own copy of the script ran, its functions are the ones it had', () => {
  // The usual order in WebKit: the frame's copy runs when its document starts, the page reaches
  // the frame afterwards. Until 15 November each copy kept its own list of the windows it had
  // been through, so the page's copy went through the frame again: a second Date over the first,
  // and functions a page had in hand no longer the frame's (window[0].Date !== the one before).
  const iframe = `globalThis.HTMLIFrameElement = class HTMLIFrameElement { get contentWindow() { return globalThis.__frame || null; } };`;
  const top = makeWindow(everything, null, iframe);
  const frame = makeWindow(everything, top, iframe);
  top.__frame = vm.runInContext('globalThis', frame); // the frame's window itself, as contentWindow gives it
  run(frame, `globalThis.__had = [Date, Date.prototype.getHours, Function.prototype.toString, Intl.DateTimeFormat, navigator.geolocation.getCurrentPosition, window.open];`);
  assert.equal(run(top, `Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'contentWindow').get.toString()`), nativeText('contentWindow'));
  assert.equal(run(top, `new HTMLIFrameElement().contentWindow === __frame`), true);
  assert.equal(run(frame, `[Date, Date.prototype.getHours, Function.prototype.toString, Intl.DateTimeFormat, navigator.geolocation.getCurrentPosition, window.open]
    .map((f, i) => f === __had[i]).join()`), 'true,true,true,true,true,true');
  // A window reached before any copy ran in it (none ever does here) is given what the page has.
  const bare = engineWindow();
  top.__frame = vm.runInContext('globalThis', bare);
  run(top, `new HTMLIFrameElement().contentWindow`);
  assert.equal(run(bare, `Date.toString() + new Date(Date.UTC(2024, 0, 15, 12)).getHours()`), nativeText('Date') + '13');
});

test('a window that is nobody\'s frame and nobody\'s popup, and a launch without a channel, are families of their own: their own replacements print as native', () => {
  for (const config of [everything, { ...everything, channel: null }, { ...everything, channel: '' }]) {
    const top = makeWindow(config), frame = makeWindow(config, top);
    for (const w of [top, frame]) {
      assert.equal(run(w, `Date.prototype.getHours.toString() + Function.prototype.toString.call(Date)`), nativeText('getHours') + nativeText('Date'));
      assert.throws(() => run(w, 'Function.prototype.toString.call(Symbol.for("wk.shim.registry"))'), (e) => e.name === 'TypeError');
    }
  }
  // Another launch (another profile, or this one started again) has another channel: a window of
  // it under this page is not let into the family, and prints its own.
  const top = makeWindow(everything), foreign = makeWindow({ ...everything, channel: 'another-launch' }, top);
  assert.equal(run(foreign, `Date.prototype.getHours.toString()`), nativeText('getHours'));
});

test('a page that replaces built-ins and watches them sees no call from the script: when a frame starts, when it opens a window, when a function is printed', () => {
  const top = makeWindow(everything);
  // What the script's family, registry and toString could have gone through.
  const places = [['Function.prototype', 'toString'], ['Function.prototype', 'call'], ['Function.prototype', 'apply'], ['Function.prototype', 'bind'],
                  ['WeakMap.prototype', 'get'], ['WeakMap.prototype', 'set'], ['WeakMap.prototype', 'has'], ['WeakSet.prototype', 'has'], ['WeakSet.prototype', 'add'],
                  ['EventTarget.prototype', 'dispatchEvent'], ['EventTarget.prototype', 'addEventListener'], ['Reflect', 'apply'], ['Reflect', 'get'],
                  ['Object', 'defineProperty'], ['Object', 'getOwnPropertyDescriptor'], ['String.prototype', 'replace'], ['Symbol', 'for'], ['window', 'Event']];
  spyOn(top, places);
  const frame = makeWindow(everything, top);
  const popup = makeWindow(everything, null, null, top);
  assert.deepEqual(Array.from(top.spied), [], 'a frame and a popup started');
  // The frame is of the family all the same.
  top.frame = frame; top.popup = popup;
  top.nativeToString = vm.runInContext('Function.prototype.toString', frame);
  assert.equal(run(top, `nativeToString.call(Date.prototype.getHours)`), nativeText('getHours'));
  // Printing: the page's own spies see what the page itself calls, and nothing more than in a
  // window without the script.
  const plain = engineWindow();
  spyOn(plain, places.filter(([, key]) => key !== 'toString'));
  const printing = `(() => { spied.length = 0; const f = Date.prototype.getHours; f.toString(); String(f); f + ''; Date.toString(); (function () {}).toString(); return spied.join(); })()`;
  top.spied.length = 0;
  run(top, `Function.prototype.toString = nativeToString;`); // the frame's toString, which the page did not replace
  assert.equal(run(top, printing), run(plain, printing));
});

// ---- Nothing is replaced that the engine already answers ------------------------------------
// A profile in a process of its own gives WebKit's processes its time zone, a persistent store
// answers Safari's quota itself, and the engine answers geolocation and has WebRTC off: such a
// profile's page must hold the engine's own functions, every one — not copies that print alike.
// `inEngineZone` makes a window while the engine is in `zone`, as WebKit is in a profile's process.
function inEngineZone(zone, make) {
  process.env.TZ = zone;
  try { return make(); } finally { process.env.TZ = HOME_ZONE; }
}
// Every own property of what the script may touch — its value, getter and setter by identity, and
// its attributes — taken before the script runs (the prelude) and compared after it.
const takeProperties = `globalThis.__take = () => {
  const out = new Map();
  const holders = { window: globalThis, 'Function.prototype': Function.prototype, Date, 'Date.prototype': Date.prototype, Intl,
    'Intl.DateTimeFormat': Intl.DateTimeFormat, 'Intl.DateTimeFormat.prototype': Intl.DateTimeFormat.prototype, URL, 'Worker.prototype': Worker.prototype,
    'StorageManager.prototype': StorageManager.prototype, 'Navigator.prototype': Navigator.prototype, 'Screen.prototype': Screen.prototype,
    'Geolocation.prototype': Geolocation.prototype, 'Permissions.prototype': Permissions.prototype, 'PermissionStatus.prototype': PermissionStatus.prototype,
    'EventTarget.prototype': EventTarget.prototype, 'Promise.prototype': Promise.prototype };
  for (const [name, holder] of Object.entries(holders)) {
    for (const key of Reflect.ownKeys(holder)) {
      if (String(key).startsWith('__')) continue;
      const d = Object.getOwnPropertyDescriptor(holder, key);
      out.set(name + '.' + String(key), [d.value, d.get, d.set, d.enumerable, d.configurable, d.writable]);
    }
  }
  return out;
};
// The engine with WebRTC off has no RTC interface at all.
for (const name of Object.getOwnPropertyNames(globalThis)) if (/^(webkit)?RTC[A-Z]/.test(name)) delete globalThis[name];
globalThis.__before = __take();`;
const replacedProperties = (w) => Array.from(run(w, `(() => { const after = __take(), changed = [];
  for (const [key, was] of __before) { const now = after.get(key); if (!now || was.some((v, i) => !Object.is(v, now[i]))) changed.push(key); }
  for (const key of after.keys()) if (!__before.has(key)) changed.push('+' + key);
  return changed.sort(); })()`));
// A profile as the released build runs it by default: its own process (the engine in its zone,
// geolocation the engine's), a persistent store (no quota to say), WebRTC off in the engine.
const ownProcess = { geolocation: { mode: 'native' }, webRTC: 'disabled', timeZone: 'Asia/Tokyo', safariObject: false };

test('a profile whose engine already answers as the profile: the script replaces nothing — every function is the engine\'s own, in the page, a frame and a popup', () => {
  inEngineZone('Asia/Tokyo', () => {
    const top = makeWindow(ownProcess, null, takeProperties);
    const frame = makeWindow(ownProcess, top, takeProperties);
    const popup = makeWindow(ownProcess, null, takeProperties, top);
    for (const [name, w] of Object.entries({ top, frame, popup })) {
      assert.deepEqual(replacedProperties(w), [], name);
      // The zone a page reads is the profile's, from the engine itself.
      assert.equal(run(w, `Intl.DateTimeFormat().resolvedOptions().timeZone + ' ' + new Date(Date.UTC(2024, 0, 15, 12)).getHours()`), 'Asia/Tokyo 21');
    }
    // No worker is given a script in front of its own either.
    assert.equal(run(top, `(() => { const url = URL.createObjectURL(new Blob(['postMessage(1)'])); return new Worker(url).url === url; })()`), true);
  });
});

test('the engine is in the profile\'s zone when it says the zone\'s name as the profile does, or as it would itself say the profile\'s', () => {
  // The process is given the profile's zone by its name (TZ), and the engine may say it under the
  // name it holds as canonical (V8: Asia/Calcutta for Asia/Kolkata; JavaScriptCore keeps the name).
  const engineName = inZone('Asia/Kolkata', (plain) => run(plain, `Intl.DateTimeFormat().resolvedOptions().timeZone`));
  for (const named of ['Asia/Kolkata', engineName]) {
    inEngineZone('Asia/Kolkata', () => {
      const w = makeWindow({ ...ownProcess, timeZone: named }, null, takeProperties);
      assert.deepEqual(replacedProperties(w), [], named);
      assert.equal(run(w, `Intl.DateTimeFormat().resolvedOptions().timeZone`), engineName);
    });
  }
  // A zone that is another, however near: replaced (Kathmandu is a quarter of an hour from Kolkata).
  inEngineZone('Asia/Kolkata', () => {
    assert.ok(replacedProperties(makeWindow({ ...ownProcess, timeZone: 'Asia/Kathmandu' }, null, takeProperties)).includes('window.Date'));
  });
});

test('only what a setting needs is replaced: another zone brings Date, an ephemeral store the quota, Safari\'s object its two functions — and toString only with them', () => {
  const replaced = (config, zone) => inEngineZone(zone, () => replacedProperties(makeWindow(config, null, takeProperties)));
  // The engine elsewhere than the profile (a profile inside the app's process): Date and Intl.DateTimeFormat.
  const elsewhere = replaced(ownProcess, 'Europe/Berlin');
  for (const key of ['window.Date', 'Date.prototype.getHours', 'Date.prototype.constructor', 'Intl.DateTimeFormat', 'Function.prototype.toString', 'window.open', 'window.Worker', 'URL.createObjectURL'])
    assert.ok(elsewhere.includes(key), `${key} in ${elsewhere}`);
  assert.ok(!elsewhere.includes('StorageManager.prototype.estimate'));
  // An ephemeral profile: the quota, and the workers that must answer it too; no Date.
  assert.deepEqual(replaced({ ...ownProcess, storageQuota: 0.6 * 128 * 2 ** 30 }, 'Asia/Tokyo'),
                   ['Function.prototype.toString', 'StorageManager.prototype.estimate', 'URL.createObjectURL', 'Worker.prototype.constructor', 'window.Worker', 'window.open']);
  // Safari up to 27.1: window.safari; its functions print as native, so toString is the script's.
  assert.deepEqual(replaced({ ...ownProcess, safariObject: true }, 'Asia/Tokyo'), ['+window.safari', 'Function.prototype.toString', 'window.open']);
  // A fixed place answered by the script (a profile inside the app's process).
  const place = replaced({ ...ownProcess, geolocation: { mode: 'fixed', latitude: 1, longitude: 2, accuracy: 3 } }, 'Asia/Tokyo');
  assert.ok(place.includes('Geolocation.prototype.getCurrentPosition') && !place.includes('window.Date') && !place.includes('window.Worker'), String(place));
});

test('a family\'s first replacement, wherever it is made, gives every window of the family a toString that prints it as native', () => {
  // The page and its first frame replace nothing; a second frame is reached before its own copy
  // ran and patched by... nothing here: so a window of the family that does replace (a frame given
  // a place to answer, as a window with other interfaces could be) must not print as source in the
  // windows that replaced nothing before it.
  inEngineZone('Asia/Tokyo', () => {
    const top = makeWindow(ownProcess, null, takeProperties);
    const quiet = makeWindow(ownProcess, top, takeProperties);
    assert.deepEqual(replacedProperties(top).concat(replacedProperties(quiet)), []);
    const busy = makeWindow({ ...ownProcess, safariObject: true }, top, takeProperties);
    for (const w of [top, quiet, busy]) {
      w.busy = busy;
      assert.equal(run(w, `Function.prototype.toString.call(busy.safari.pushNotification.permission)`), nativeText('permission'));
      assert.equal(run(w, `Function.prototype.toString.call(Function.prototype.toString)`), nativeText('toString'));
    }
  });
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

test('the script a blob worker starts with runs in a worker: the profile\'s zone, quota and platform there, printed as the engine prints its own', async () => {
  // A worker's realm, as far as the script reaches it: no window, a WorkerGlobalScope, a navigator
  // with the engine's platform and storage.
  const worker = vm.createContext({});
  vm.runInContext(`var self = globalThis;
    globalThis.WorkerGlobalScope = class WorkerGlobalScope { static [Symbol.hasInstance](o) { return o === globalThis; } };
    globalThis.StorageManager = class StorageManager { estimate() { return Promise.resolve({ quota: 1048576000, usage: 7 }); } };
    globalThis.WorkerNavigator = class WorkerNavigator { get platform() { if (!(this instanceof WorkerNavigator)) throw new TypeError('illegal invocation'); return 'MacIntel'; } };
    var navigator = Object.assign(Object.create(WorkerNavigator.prototype), { storage: new StorageManager() });`, worker);
  worker.Function = vm.runInContext('Function', worker);
  const phone = { platform: 'iPhone', width: 402, height: 874, maxTouchPoints: 5 };
  const page = makeWindow({ ...base, timeZone: 'Asia/Tokyo', storageQuota: 0.6 * 128 * 2 ** 30, phone });
  const url = run(page, `new Worker(URL.createObjectURL(new Blob(['postMessage(1)']))).url`);
  const bootstrap = run(page, `__engine.blobs.get(${JSON.stringify(url)}).parts[0]`);
  assert.doesNotMatch(bootstrap, new RegExp(CHANNEL), 'the family\'s channel is not a worker\'s to read');
  vm.runInContext(bootstrap, worker);
  assert.equal(run(worker, `[new Date(Date.UTC(2024, 0, 15, 12)).getHours(), Intl.DateTimeFormat().resolvedOptions().timeZone, navigator.platform].join()`), '21,Asia/Tokyo,iPhone');
  assert.equal(await run(worker, `navigator.storage.estimate().then((e) => e.quota)`), 82463372084);
  assert.equal(run(worker, `[Date, Date.prototype.getHours, navigator.storage.estimate, Function.prototype.toString].map((f) => Function.prototype.toString.call(f)).join()`),
               ['Date', 'getHours', 'estimate', 'toString'].map(nativeText).join());
  assert.throws(() => run(worker, 'Function.prototype.toString.call(Symbol.for("wk.shim.registry"))'), (e) => e.name === 'TypeError');
});

test('storage quota: Safari\'s instead of the app default', async () => {
  // WebKit: ceil(0.6 × 128 GB) for a browser's top-level origin on any Mac.
  const w = makeWindow({ ...base, storageQuota: 0.6 * 128 * 2 ** 30 });
  assert.equal(await run(w, `navigator.storage.estimate().then((e) => [e.quota, e.usage].join())`), '82463372084,1234');
  const plain = makeWindow(base);
  assert.equal(await run(plain, `navigator.storage.estimate().then((e) => e.quota)`), 1048576000);
});

test('storage quota: the page is handed the engine\'s own promise, and a page that watches Promise sees nothing of the script', async () => {
  // The engine's estimate, as the script finds it: the promises it makes are kept where only the
  // engine (this test) reads them, and it can be told to refuse.
  const engineEstimate = `{ const native = StorageManager.prototype.estimate; __engine.promises = [];
    StorageManager.prototype.estimate = function estimate() {
      const promise = __engine.refuses ? Promise.reject(new TypeError('refused')) : Reflect.apply(native, this, arguments);
      __engine.promises.push(promise);
      return promise;
    }; }`;
  const w = makeWindow({ ...base, storageQuota: 0.6 * 128 * 2 ** 30 }, null, engineEstimate);
  const plain = engineWindow(engineEstimate);
  // The very promise the engine made, with nothing left on it; the figure in the engine's own object.
  assert.equal(run(w, `(() => { const p = navigator.storage.estimate(); return [p === __engine.promises[0], Object.getOwnPropertyNames(p).length, p.constructor === Promise].join(); })()`), 'true,0,true');
  assert.equal(await run(w, `navigator.storage.estimate().then((e) => JSON.stringify(Object.getOwnPropertyDescriptors(e)))`),
               (await run(plain, `navigator.storage.estimate().then((e) => JSON.stringify(Object.getOwnPropertyDescriptors(e)))`)).replace('1048576000', '82463372084'));
  // A page that replaced what a wrapper would go through, and asks who reads a promise's constructor.
  const watch = `(async () => {
    Object.defineProperty(Promise.prototype, 'constructor', { get() { spied.push('constructor'); return Promise; }, configurable: true });
    spied.length = 0;
    const estimate = await navigator.storage.estimate();
    await navigator.storage.estimate().then((e) => e.quota);
    return spied.join() + ' / ' + typeof estimate.quota;
  })()`;
  const places = [['Promise.prototype', 'then'], ['Promise.prototype', 'catch'], ['Promise.prototype', 'finally'], ['Promise', 'resolve'], ['Math', 'ceil'],
                  ['Function.prototype', 'call'], ['Function.prototype', 'apply'], ['Reflect', 'apply'], ['Object', 'defineProperty'], ['Object', 'getOwnPropertyDescriptor']];
  spyOn(w, places);
  spyOn(plain, places);
  assert.equal(await run(w, watch), await run(plain, watch));
  // The engine's refusal is the page's to catch: the same rejected promise, and no rejection of
  // the script's own left unhandled (which would end this test run).
  for (const window of [w, plain]) {
    run(window, `__engine.refuses = true; __engine.promises.length = 0`);
    assert.equal(await run(window, `(() => { const p = navigator.storage.estimate(); return p.then(() => 'no', (e) => [p === __engine.promises[0], e.message].join()); })()`), 'true,refused');
  }
  await new Promise((resolve) => setTimeout(resolve, 10));
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

// A choice in a list (a <select>): the recorder says the choice itself as a step — never the click
// on the list, which a replay would make into the system's menu and leave open — and the driver
// makes that choice again (PageDriver.chooseOptions), with `input` and `change` for the page.
test('recorder: a choice in a list is a step with the option\'s value; the click on the list is not one', async () => {
  const w = await recorderWindow();
  const steps = JSON.parse(run(w, `
    const list = new HTMLSelectElement({ id: 'country' }, 'Germany');
    list.selectedOptions = [{ value: 'DE', label: '  Germany\\n (DE) ' }];
    elements.push(list);
    fire('click', list);
    fire('change', list);
    const several = new HTMLSelectElement({ id: 'tags' }, 'One');
    several.multiple = true;
    several.selectedOptions = [{ value: '1', label: 'One' }, { value: '2', label: 'Two' }];
    elements.push(several);
    fire('change', several);
    const button = new Element('button', { id: 'go' });
    elements.push(button);
    fire('click', button);
    JSON.stringify(posted.filter((m) => m.type !== 'hello'))`));
  assert.deepEqual(steps, [
    { type: 'select', selector: '#country', value: 'DE', label: 'Germany (DE)' },
    { type: 'note', value: 'select #tags: One, Two' },
    { type: 'click', selector: '#go' },
  ]);
});

const driverChooseOptions = driverSwift.split('static let chooseOptions = """')[1].split('"""')[0].replace(/\\\\/g, '\\');

function listWindow() {
  const context = vm.createContext({});
  vm.runInContext(`
    var events = [];
    class Event { constructor(type, init) { this.type = type; this.bubbles = !!(init && init.bubbles); } }
    class HTMLLabelElement { constructor(control) { this.control = control; this.nodeName = 'LABEL'; } }
    class Option {
      constructor(list, value, label, disabled) { this.list = list; this.value = value; this.label = label; this.disabled = !!disabled; this.chosen = false; }
      get selected() { return this.chosen; }
      // As a list of one does: choosing an option lets the others go.
      set selected(on) { if (on && !this.list.multiple) { for (const o of this.list.options) o.chosen = false; } this.chosen = !!on; }
    }
    class HTMLSelectElement {
      constructor(options, multiple) {
        this.nodeName = 'SELECT'; this.multiple = !!multiple; this.disabled = false;
        this.options = options.map(([value, label, disabled]) => new Option(this, value, label, disabled));
        if (!multiple) this.options[0].chosen = true;
      }
      dispatchEvent(event) { events.push(event.type + (event.bubbles ? '' : ' (not bubbling)')); return true; }
      get chosen() { return this.options.filter((o) => o.selected).map((o) => o.value); }
    }
    var country = new HTMLSelectElement([['', 'Choose a country'], ['DE', 'Germany'], ['FR', ' France '], ['XX', 'Nowhere', true], ['Germany', 'A value named Germany']]);
    var tags = new HTMLSelectElement([['1', 'One'], ['2', 'Two'], ['3', 'Three']], true);
    var named = { '#country': country, '#tags': tags, 'label[for=country]': new HTMLLabelElement(country), '#button': { nodeName: 'BUTTON' } };
    var document = { querySelectorAll: (selector) => named[selector] ? [named[selector]] : [] };
    var choose = (selector, wanted) => { events.length = 0; return (function () {\n${driverFindAll}\n${driverChooseOptions}\n})(); };
  `.replace('(function () {', '(function (selector, wanted) {').replace('})(); };', '})(selector, wanted); };'), context);
  return context;
}

test('driver: selectOption chooses by value, then by label, by {label}, {value} and {index}; says what it cannot choose', () => {
  const w = listWindow();
  const choose = (selector, wanted) => JSON.parse(run(w, `JSON.stringify([choose(${JSON.stringify(selector)}, ${JSON.stringify(wanted)}), events, country.chosen, tags.chosen])`));
  assert.deepEqual(choose('#country', ['DE']), [{ values: ['DE'] }, ['input', 'change'], ['DE'], []]);
  // The same choice again changes nothing, and tells the page nothing.
  assert.deepEqual(choose('#country', ['DE']), [{ values: ['DE'] }, [], ['DE'], []]);
  // A value comes before a label of the same words; a label is taken without the spaces around it.
  assert.deepEqual(choose('#country', ['Germany'])[0], { values: ['Germany'] });
  assert.deepEqual(choose('#country', ['France'])[0], { values: ['FR'] });
  assert.deepEqual(choose('#country', [{ label: 'Germany' }])[0], { values: ['DE'] });
  assert.deepEqual(choose('#country', [{ value: 'FR' }])[0], { values: ['FR'] });
  assert.deepEqual(choose('#country', [{ index: 1 }])[0], { values: ['DE'] });
  // A label of the list is the list.
  assert.deepEqual(choose('label[for=country]', ['FR']).slice(0, 3), [{ values: ['FR'] }, ['input', 'change'], ['FR']]);
  // What cannot be chosen is said, and nothing is changed.
  assert.deepEqual(choose('#country', ['Spain']), [{ problem: 'noOption', about: '"Spain"' }, [], ['FR'], []]);
  assert.deepEqual(choose('#country', ['XX'])[0], { problem: 'optionDisabled', about: '"XX"' });
  assert.deepEqual(choose('#country', ['DE', 'FR'])[0], { problem: 'several' });
  assert.deepEqual(choose('#button', ['x'])[0], { problem: 'notList', about: 'button' });
  assert.deepEqual(choose('#nothing', ['x'])[0], { problem: 'missing' });
  // A list that takes several: these, in place of what was chosen.
  assert.deepEqual(choose('#tags', ['1', 'Three']), [{ values: ['1', '3'] }, ['input', 'change'], ['FR'], ['1', '3']]);
  assert.deepEqual(choose('#tags', [{ index: 1 }]), [{ values: ['2'] }, ['input', 'change'], ['FR'], ['2']]);
  run(w, 'country.disabled = true');
  assert.deepEqual(choose('#country', ['DE'])[0], { problem: 'disabled' });
});

// A scenario's errors name its line, and what it returns is its result (ScenarioRunner.lineSupport,
// the prelude's own text): a command's failure is made by the app outside any call of the script,
// so only the place the command was called from knows the line. Under Bun this is JavaScriptCore,
// the engine scenarios run in.
const runnerSwift = readFileSync(new URL('../Sources/PrivacyBrowser/Browser/ScenarioRunner.swift', import.meta.url), 'utf8');
const lineSupport = runnerSwift.split('static let lineSupport = #"""')[1].split('"""#')[0];

function scenarioContext() {
  const context = vm.createContext({ later: (fn) => setTimeout(fn, 1) });
  vm.runInContext(`
    var ended = null;
    var __ended = (ok, message) => { ended = { ok, message }; };
    // As the app answers a command: later, from outside the script — or at once, by throwing.
    var __command = (name, args) => {
      if (name === 'flood') { throw new Error('1000 page commands are waiting to run'); }
      if (name === 'gone') { throw new Error('stopped'); }
      return new Promise((resolve, reject) => later(() => name === 'click' ? reject(new Error('no element matches ' + args[0])) : resolve(args[0])));
    };
  `, context);
  vm.runInContext(lineSupport + `
    const page = {};
    for (const name of ['goto', 'click', 'flood', 'gone']) page[name] = (...args) => __at(__line(), () => __command(name, args));
  `, context);
  return context;
}

async function scenario(source) {
  const context = scenarioContext();
  // As ScenarioRunner.run wraps a scenario: its first line is line 1 of scenario.js.
  vm.runInContext('(async () => {' + source + '\n})().then((value) => __ended(true, __result(value)), (e) => __ended(false, __failure(e)));',
                  context, { filename: 'scenario.js' });
  for (let i = 0; i < 200 && run(context, 'ended === null'); i++) await new Promise((resolve) => setTimeout(resolve, 5));
  const ended = JSON.parse(run(context, 'JSON.stringify(ended)'));
  return { ok: ended.ok, first: ended.message.split('\n')[0], message: ended.message };
}

test('scenario: a command that fails, and a mistake of the script, name the line of the scenario', async () => {
  assert.equal((await scenario("await page.goto('a');\nawait page.goto('b');\nawait page.click('#next');\n")).first,
               'Error: no element matches #next (line 3)');
  // Called in a function of the script: the line of the call that failed, not of the function's use.
  assert.equal((await scenario("await page.goto('a');\n\nconst open = async () => {\n  await page.click('#in-function');\n};\nawait open();")).first,
               'Error: no element matches #in-function (line 4)');
  // Caught and thrown again: named once.
  assert.equal((await scenario("try {\n  await page.click('#a');\n} catch (e) {\n  throw e;\n}")).first, 'Error: no element matches #a (line 2)');
  // The script's own mistake.
  const mistake = await scenario("await page.goto('a');\nconst nothing = undefined;\nnothing.field;\n");
  assert.equal(mistake.ok, false);
  assert.match(mistake.first, /^TypeError: .* \(line 3\)$/);
  assert.equal((await scenario("await page.goto('a');\nthrow new Error('not signed in');")).first, 'Error: not signed in (line 2)');
  // Thrown at once by the call (too many commands waiting): the line too. "stopped" stays as it is.
  assert.equal((await scenario("await page.goto('a');\npage.flood();")).first, 'Error: 1000 page commands are waiting to run (line 2)');
  assert.equal((await scenario("await page.goto('a');\npage.gone();")).first, 'Error: stopped');
  // What is not an error has no line to name.
  assert.equal((await scenario("throw 'only text';")).first, 'only text');
  // The script that catches reads the line from the error.
  const caught = await scenario("let e;\ntry { await page.click('#a'); } catch (x) { e = x; }\nreturn [e.message, e.scenarioLine];");
  assert.deepEqual(JSON.parse(caught.message), ['no element matches #a (line 2)', 2]);
});

test('scenario: what the script returns is the run\'s result, as JSON; nothing returned is no result', async () => {
  assert.deepEqual(await scenario("await page.goto('a');\nreturn { title: 'Orders', items: [1, 2], none: null };"),
                   { ok: true, first: '{"title":"Orders","items":[1,2],"none":null}', message: '{"title":"Orders","items":[1,2],"none":null}' });
  assert.equal((await scenario("await page.goto('a');")).message, '');
  assert.equal((await scenario('return "text";')).message, '"text"');
  assert.equal((await scenario('return 0;')).message, '0');
  // What JSON cannot say: a function is nothing, a BigInt its digits.
  assert.equal((await scenario('return () => 1;')).message, '');
  assert.equal((await scenario('return 10n;')).message, '"10"');
});

// The scenario templates (ScenarioTemplates.swift): each script is real JavaScript of the scenario's
// own commands. Run here against a page that records what it is asked: a script that does not
// parse, calls a command there is none of, or leaves its work undone fails.
const templatesSwift = readFileSync(new URL('../Sources/BrowserCore/Automation/ScenarioTemplates.swift', import.meta.url), 'utf8');
const templateScripts = Object.fromEntries(templatesSwift.split('ScenarioTemplate(id: "').slice(1).map((part) =>
  [part.split('"')[0], part.split('script: #"""\n')[1].split('"""#')[0]]));
const PAGE_COMMANDS = ['goto', 'back', 'forward', 'reload', 'waitForLoadState', 'waitFor', 'waitForURL', 'click', 'dblclick', 'hover', 'selectOption',
  'type', 'press', 'scroll', 'textContent', 'innerText', 'inputValue', 'getAttribute', 'count', 'isVisible', 'url', 'title', 'screenshot', 'pause', 'evaluate'];

async function runTemplate(id, settings, { params = {}, answers = {} } = {}) {
  let source = templateScripts[id].replace(/\{\{([A-Za-z0-9_.]+)\}\}/g, (_, key) => key);
  for (const [name, value] of Object.entries(settings)) {
    const line = new RegExp('^const ' + name + ' = .+?;( // .*)?$', 'm');
    assert.ok(line.test(source), `${id}: no setting ${name}`);
    source = source.replace(line, (_, label) => `const ${name} = ${JSON.stringify(value)};${label || ''}`);
  }
  const calls = [];
  const page = {};
  for (const name of PAGE_COMMANDS) {
    page[name] = async (...args) => {
      calls.push([name, ...args.filter((a) => typeof a !== 'function')]);
      const answer = answers[name];
      return typeof answer === 'function' ? answer(...args) : answer;
    };
  }
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  const run = new AsyncFunction('page', 'params', 'log', 'sleep', source);
  const result = await run(page, params, () => {}, async (ms) => { calls.push(['sleep', ms]); });
  return { result, calls, names: calls.map((c) => c[0]) };
}

test('scenario templates: every one is there, parses, and names only commands a scenario has', async () => {
  assert.deepEqual(Object.keys(templateScripts).sort(), ['collect', 'cookie', 'feed', 'form', 'list', 'opens', 'pages', 'post', 'screens', 'search', 'signedin', 'signin']);
  for (const [id, script] of Object.entries(templateScripts)) {
    const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
    assert.doesNotThrow(() => new AsyncFunction('page', 'params', 'log', 'sleep', script), `${id} parses`);
    for (const [, name] of script.matchAll(/\bpage\.([A-Za-z]+)\(/g)) assert.ok(PAGE_COMMANDS.includes(name), `${id}: page.${name}`);
    // Nothing a page could find: a template never writes into the page.
    assert.ok(!/setAttribute|innerHTML|\.value\s*=|dispatchEvent|world: 'page'/.test(script), `${id} writes nothing into the page`);
    // Its settings are single lines the form can read, each with what it is.
    const head = script.split('\n\n')[0].split('\n').slice(1);
    for (const line of head) assert.match(line, /^const [A-Z][A-Z0-9_]* = .+; \/\/ \{\{label\.[A-Za-z]+\}\}$/, `${id}: ${line}`);
  }
});

test('scenario templates: sign in types the profile\'s own login and password, then waits for the sign', async () => {
  const run = await runTemplate('signin', { LOGIN_URL: 'https://shop.example/login', SIGNED_IN: 'text=My orders' }, { params: { login: 'alice', password: 's3cret' } });
  assert.deepEqual(run.calls[0], ['goto', 'https://shop.example/login']);
  assert.deepEqual(run.calls[1].slice(2), ['alice']);
  assert.deepEqual(run.calls[2], ['type', 'input[type="password"]', 's3cret']);
  assert.deepEqual(run.calls[3], ['press', 'Enter']);
  assert.deepEqual(run.calls[4], ['waitFor', 'text=My orders', { timeout: 30000 }]);
  assert.equal(run.result, 'result.signedIn');
  // With a button named, the button; without a sign, the page's load.
  const button = await runTemplate('signin', { LOGIN_URL: 'https://shop.example/login', SUBMIT_BUTTON: 'text=Sign in' });
  assert.deepEqual(button.names, ['goto', 'type', 'type', 'click', 'waitForLoadState']);
  assert.deepEqual(button.calls[1].slice(2), [''], 'a profile without a login types nothing');
});

test('scenario templates: the checks say what they found', async () => {
  const a = { PAGE_URL: 'https://shop.example/account', SIGNED_IN: 'text=Sign out' };
  assert.equal((await runTemplate('signedin', a, { answers: { isVisible: true } })).result, 'result.signedIn');
  assert.equal((await runTemplate('signedin', a, { answers: { isVisible: false } })).result, 'result.notSignedIn');
  const o = { PAGE_URL: 'https://shop.example/', BLOCK_TEXT: 'Access denied', MUST_SHOW: 'h1' };
  assert.equal((await runTemplate('opens', o, { answers: { count: 1 } })).result, 'result.blocked');
  const open = await runTemplate('opens', o, { answers: { count: 0, title: 'Shop' } });
  assert.equal(open.result, 'Shop');
  assert.deepEqual(open.calls.find((c) => c[0] === 'waitFor'), ['waitFor', 'h1', { timeout: 15000 }]);
});

test('scenario templates: activity — a feed is scrolled so many screens, pages are gone through, results are opened', async () => {
  const feed = await runTemplate('feed', { PAGE_URL: 'https://news.example/', SCREENS: 4, PAUSE_FROM: 1, PAUSE_TO: 2 });
  assert.equal(feed.names.filter((n) => n === 'scroll').length, 4);
  assert.ok(feed.calls.filter((c) => c[0] === 'sleep').every((c) => c[1] >= 1000 && c[1] <= 2000));
  assert.equal(feed.result, 4);
  const pages = await runTemplate('pages', { PAGES: ['https://a.example/', 'https://b.example/'], STAY_SECONDS: 4, SCROLLS: 1 },
    { answers: { goto: (url) => { if (url.includes('b.')) throw new Error('navigation failed'); } } });
  assert.equal(pages.result, 1, 'a page that does not open is said and passed by');
  await assert.rejects(runTemplate('pages', { PAGES: ['https://a.example/'] }, { answers: { goto: () => { throw new Error('stopped'); } } }), /stopped/, 'Stop still stops');
  const search = await runTemplate('search', { QUERIES: ['red shoes'], OPEN_RESULTS: 2, READ_SECONDS: 1 },
    { answers: { count: 5, evaluate: 'a[href="https\\:\\/\\/r\\.example\\/"]', url: 'https://r.example/' } });
  assert.deepEqual(search.calls[0], ['goto', 'https://www.google.com/search?q=red%20shoes']);
  assert.equal(search.names.filter((n) => n === 'click').length, 2);
  assert.deepEqual(search.result, ['https://r.example/', 'https://r.example/']);
  assert.equal((await runTemplate('search', { QUERIES: ['x'] }, { params: { query: 'own words' }, answers: { count: 0 } })).calls[0][1], 'https://www.google.com/search?q=own%20words');
  const screens = await runTemplate('screens', { PAGE_URL: 'https://shop.example/', TIMES: 2, READ_SECONDS: 1 }, { answers: { count: 3, evaluate: 'a[href="x"]' } });
  assert.equal(screens.result, 2);
});

test('scenario templates: forms and data', async () => {
  const form = await runTemplate('form', { PAGE_URL: 'https://shop.example/contact', FIELDS: ['#name = Alice', '#mail = params.email', 'no equals'], DONE_SIGN: 'text=Thank you' }, { params: { email: 'a@example.com' } });
  assert.deepEqual(form.calls.filter((c) => c[0] === 'type'), [['type', '#name', 'Alice'], ['type', '#mail', 'a@example.com']]);
  assert.equal(form.result, 'result.sent');
  const post = await runTemplate('post', { PAGE_URL: 'https://forum.example/new', TEXT_FIELD: 'textarea', TEXT: 'hello', SEND_BUTTON: 'text=Post' }, { params: { text: 'mine' } });
  assert.deepEqual(post.calls.find((c) => c[0] === 'type'), ['type', 'textarea', 'mine'], 'the profile\'s own text first');
  const cookie = await runTemplate('cookie', { PAGE_URL: 'https://news.example/' }, { answers: { isVisible: (s) => s === 'text=I agree' } });
  assert.equal(cookie.result, 'I agree');
  assert.deepEqual(cookie.calls.at(-1), ['click', 'text=I agree']);
  assert.equal((await runTemplate('cookie', {}, { answers: { isVisible: false } })).result, 'result.noBanner');
  const collect = await runTemplate('collect', { PAGE_URL: 'https://shop.example/account', WHAT: ['balance = .balance', 'orders = #orders'] },
    { answers: { count: (s) => (s === '.balance' ? 1 : 0), innerText: ' 12.50 ' } });
  assert.deepEqual(collect.result, { balance: '12.50', orders: '' });
  const list = await runTemplate('list', { PAGE_URL: 'https://shop.example/', ITEMS: '.product h2', AT_MOST: 3 }, { answers: { evaluate: ['a', 'b'] } });
  assert.deepEqual(list.result, ['a', 'b']);
  assert.deepEqual(list.calls.find((c) => c[0] === 'evaluate')[1], { selector: '.product h2', most: 3 });
});

process.on('beforeExit', () => {
  if (failures) { console.log(`${failures} failure(s)`); process.exitCode = 1; }
  else console.log(`all shim tests passed (${JSC ? 'JavaScriptCore, Bun ' + Bun.version : 'V8, Node ' + process.version})`);
});
