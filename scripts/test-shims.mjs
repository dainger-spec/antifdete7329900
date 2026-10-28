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

// SHIM_FORM=worker runs every test on the shim as a worker's blob gets it: one line of code, made
// by the shim itself (oneLine in PrivacyScripts.swift) from its own text.
const FORM = process.env.SHIM_FORM === 'worker' ? 'worker' : 'page';

// Blobs, blob: URLs, workers and Trusted Types as WebKit has them, as far as the worker hook uses
// them. A Blob converts its parts as a WebIDL sequence (through their @@iterator, `next` read once,
// `return` on an error), holds UTF-8 bytes (a string of char codes 0-255) and slices them; a worker
// records the script it would run; with Trusted Types enforced (engine.tt.enforced) a string URL
// goes through the default policy or is a violation. Like the engine's C++, none of it calls a
// built-in a page can replace.
const ENGINE_WORKERS = String.raw`(() => {
  const engine = globalThis.__engine;
  const reflectApply = Reflect.apply, NativeTypeError = TypeError, NativeString = String, objectCreate = Object.create, defineProperty = Object.defineProperty;
  const uncurry = (f) => (self, ...args) => reflectApply(f, self, args);
  const weakHas = uncurry(WeakMap.prototype.has), weakGet = uncurry(WeakMap.prototype.get), weakSet = uncurry(WeakMap.prototype.set);
  const mapGet = uncurry(Map.prototype.get), mapSet = uncurry(Map.prototype.set), mapDelete = uncurry(Map.prototype.delete), mapHas = uncurry(Map.prototype.has);
  const slice = uncurry(String.prototype.slice), lower = uncurry(String.prototype.toLowerCase), wellFormed = uncurry(String.prototype.toWellFormed);
  const fromCharCode = String.fromCharCode, nativeEncode = encodeURIComponent, nativeDecode = decodeURIComponent, nativeEscape = escape, nativeUnescape = unescape;
  const append = (list, value) => { defineProperty(list, list.length, { __proto__: null, value, writable: true, enumerable: true, configurable: true }); };
  const toText = (v) => { if (typeof v === 'symbol') throw new NativeTypeError('Cannot convert a symbol to a string'); return NativeString(v); };
  const encode = (s) => nativeUnescape(nativeEncode(wellFormed(s)));
  const decode = (b) => nativeDecode(nativeEscape(b));
  const bytesOf = (view) => { let out = ''; for (let k = 0; k < view.length; k++) out += fromCharCode(view[k]); return out; };
  const blobs = new WeakMap();
  const sequenceOf = (value) => {
    if (value === undefined) return '';
    if (value === null || (typeof value !== 'object' && typeof value !== 'function')) throw new NativeTypeError('Value is not a sequence');
    const method = value[Symbol.iterator];
    if (typeof method !== 'function') throw new NativeTypeError('Value is not a sequence');
    const iterator = reflectApply(method, value, []);
    if (iterator === null || (typeof iterator !== 'object' && typeof iterator !== 'function')) throw new NativeTypeError('Iterator is not an object');
    const next = iterator.next;
    let bytes = '';
    for (;;) {
      const result = reflectApply(next, iterator, []);
      if (result === null || (typeof result !== 'object' && typeof result !== 'function')) throw new NativeTypeError('Iterator result is not an object');
      if (result.done) return bytes;
      const item = result.value;
      try {
        bytes += weakHas(blobs, item) ? weakGet(blobs, item).bytes
          : item instanceof ArrayBuffer ? bytesOf(new Uint8Array(item))
          : ArrayBuffer.isView(item) ? bytesOf(new Uint8Array(item.buffer, item.byteOffset, item.byteLength))
          : encode(toText(item));
      } catch (e) {
        const close = iterator.return;
        if (close !== undefined && close !== null) { try { reflectApply(close, iterator, []); } catch (ignored) {} }
        throw e;
      }
    }
  };
  const data = (blob) => { if (!weakHas(blobs, blob)) throw new NativeTypeError('The Blob.size getter can only be used on instances of Blob'); return weakGet(blobs, blob); };
  const Blob = class Blob {
    constructor(...args) {
      const bytes = sequenceOf(args[0]);
      let type = '';
      const options = args[1];
      if (options !== undefined && options !== null) {
        if (typeof options !== 'object' && typeof options !== 'function') throw new NativeTypeError('Type error');
        options.endings; // read before type: WebIDL dictionary members in order
        if (options.type !== undefined) type = lower(toText(options.type));
      }
      weakSet(blobs, this, { bytes, type });
    }
    get size() { return data(this).bytes.length; }
    get type() { return data(this).type; }
    slice(...args) {
      const d = data(this), size = d.bytes.length;
      const at = (v, fallback) => v === undefined ? fallback : v < 0 ? Math.max(size + Math.trunc(v), 0) : Math.min(Math.trunc(v), size);
      const start = at(args[0], 0), end = at(args[1], size);
      const piece = objectCreate(Blob.prototype);
      weakSet(blobs, piece, { bytes: slice(d.bytes, start, Math.max(start, end)), type: args[2] === undefined ? '' : lower(toText(args[2])) });
      return piece;
    }
  };
  const File = class File extends Blob { constructor(...args) { super(args[0], args[2]); } };
  const urls = new Map();
  let serial = 0;
  const URL = class URL {
    static createObjectURL(...args) {
      if (args.length === 0) throw new NativeTypeError('Not enough arguments');
      if (!weakHas(blobs, args[0])) throw new NativeTypeError('Argument 1 is not a Blob or a MediaSource');
      const url = 'blob:https://page.test/' + (++serial);
      mapSet(urls, url, args[0]);
      return url;
    }
    static revokeObjectURL(...args) {
      if (args.length === 0) throw new NativeTypeError('Not enough arguments');
      mapDelete(urls, toText(args[0]));
    }
  };
  Object.defineProperty(URL.createObjectURL, 'length', { value: 1 });
  Object.defineProperty(URL.revokeObjectURL, 'length', { value: 1 });
  const trusted = new WeakMap(), policies = new WeakMap();
  let defaultPolicy = null;
  const TrustedScriptURL = class TrustedScriptURL { toString() { return weakGet(trusted, this); } };
  const TrustedTypePolicy = class TrustedTypePolicy {
    createScriptURL(input, ...rest) {
      const rules = weakGet(policies, this);
      const made = objectCreate(TrustedScriptURL.prototype);
      weakSet(trusted, made, toText(reflectApply(rules.createScriptURL, rules, [toText(input), rest[0], rest[1]])));
      return made;
    }
  };
  const TrustedTypePolicyFactory = class TrustedTypePolicyFactory {
    createPolicy(name, rules) {
      const policy = objectCreate(TrustedTypePolicy.prototype);
      weakSet(policies, policy, rules);
      if (name === 'default') defaultPolicy = policy;
      return policy;
    }
    isScriptURL(value) { return weakHas(trusted, value); }
    get defaultPolicy() { return defaultPolicy; }
  };
  engine.tt = { enforced: false, violations: [] };
  const compliant = (value, sink) => {
    if (weakHas(trusted, value)) return weakGet(trusted, value);
    const text = toText(value);
    if (!engine.tt.enforced) return text;
    if (defaultPolicy !== null) {
      const rules = weakGet(policies, defaultPolicy);
      const made = reflectApply(rules.createScriptURL, rules, [text, 'TrustedScriptURL', sink]);
      if (made !== undefined && made !== null) return toText(made);
    }
    append(engine.tt.violations, sink + '|' + text);
    throw new NativeTypeError('This assignment requires a TrustedScriptURL');
  };
  engine.workers = [];
  const workerClass = (kind) => ({ [kind]: class {
    constructor(...args) {
      if (args.length === 0) throw new NativeTypeError('Not enough arguments');
      const url = compliant(args[0], kind + ' constructor');
      const blob = mapGet(urls, url);
      append(engine.workers, { kind, raw: args[0], url, options: args[1], script: blob ? decode(weakGet(blobs, blob).bytes) : null });
    }
  } })[kind];
  engine.urls = { has: (url) => mapHas(urls, url) };
  const expose = { Blob, File, URL, Worker: workerClass('Worker'), SharedWorker: workerClass('SharedWorker'),
                   TrustedScriptURL, TrustedTypePolicy, TrustedTypePolicyFactory, trustedTypes: objectCreate(TrustedTypePolicyFactory.prototype) };
  for (const name of Object.keys(expose)) Object.defineProperty(globalThis, name, { value: expose[name], writable: true, configurable: true });
})();`;

// A realm shaped like a WebKit window: navigator and screen values are accessors on the
// prototypes that reject other receivers; window attributes are own accessors.
function makeWindow(config, parentContext, form = FORM) {
  const context = vm.createContext({});
  vm.runInContext(`
    var window = globalThis;
    const illegal = (o, C) => { if (!(o instanceof C)) throw new TypeError('illegal invocation'); };
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
    const engine = { instances: [] };
    Object.defineProperty(globalThis, '__engine', { value: engine });
    globalThis.RTCPeerConnection = class RTCPeerConnection {
      constructor(c) {
        this.config = convert(c); this.closed = false; this.gathered = this.config.iceCandidatePoolSize > 0;
        engine.instances.push(this);
      }
      setConfiguration(c) { illegal(this, RTCPeerConnection); this.config = convert(c); }
      getConfiguration() {
        illegal(this, RTCPeerConnection);
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
      close() { illegal(this, RTCPeerConnection); this.closed = true; }
      // As WebKit: a promise of a new maplike report each call, its entries plain objects.
      getStats() { illegal(this, RTCPeerConnection); return Promise.resolve(report(this.stats)); }
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
    engine.methods = Object.getOwnPropertyNames(engine.Native.prototype).map((name) => engine.Native.prototype[name]);
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
  vm.runInContext(ENGINE_WORKERS, context);
  vm.runInContext(form === 'worker' ? `(${oneLineInstall()})(${JSON.stringify(config)});`
                                    : `(function install(CONFIG) {\n${body}\n})(${JSON.stringify(config)});`, context);
  return context;
}

// The shim as one line, `function install(CONFIG) {…}`: what a page's shim puts in front of a
// worker's blob (a worker made in a page with the shim in its page form), without the configuration.
let oneLineText = null;
function oneLineInstall() {
  if (oneLineText === null) {
    const config = { geolocation: { mode: 'deny' }, webRTC: 'disabled', timeZone: 'UTC' };
    const w = makeWindow(config, undefined, 'page');
    const script = vm.runInContext("new Worker(URL.createObjectURL(new Blob(['0']))); __engine.workers[0].script", w);
    const tail = `)(${JSON.stringify(config)});0`;
    assert.ok(script.startsWith('(function install(CONFIG) {') && script.endsWith(tail), 'worker bootstrap: ' + String(script).slice(0, 80));
    oneLineText = script.slice(1, script.length - tail.length);
  }
  return oneLineText;
}

// A realm shaped like a WebKit worker (WorkerGlobalScope, WorkerNavigator, postMessage), with a
// window's Blob, URL and Worker (nested workers), running `script` as a worker runs its blob.
// codeGeneration false: no eval or Function from strings, as under a CSP without 'unsafe-eval' (V8).
function runWorker(script, { codeGeneration = true } = {}) {
  const context = vm.createContext({}, codeGeneration ? {} : { codeGeneration: { strings: false } });
  vm.runInContext(String.raw`
    globalThis.WorkerGlobalScope = class WorkerGlobalScope { static [Symbol.hasInstance](o) { return o === globalThis; } };
    var self = globalThis;
    const illegal = (o, C) => { if (!(o instanceof C)) throw new TypeError('illegal invocation'); };
    class WorkerNavigator { get platform() { illegal(this, WorkerNavigator); return 'MacIntel'; }
                            get hardwareConcurrency() { illegal(this, WorkerNavigator); return 8; } }
    class StorageManager { estimate() { illegal(this, StorageManager); return Promise.resolve({ quota: 1048576000, usage: 0 }); } }
    globalThis.StorageManager = StorageManager;
    // WebKit exposes RTCDataChannel to workers (Exposed=(Window,Worker)), RTCPeerConnection not.
    Object.defineProperty(globalThis, 'RTCDataChannel', { value: function RTCDataChannel() {}, writable: true, configurable: true });
    var navigator = Object.create(WorkerNavigator.prototype);
    Object.defineProperty(navigator, 'storage', { value: new StorageManager() });
    var messages = [];
    var postMessage = (m) => { messages.push(m); };
    Object.defineProperty(globalThis, '__engine', { value: {} });
  `, context);
  vm.runInContext(ENGINE_WORKERS, context);
  context.Function = vm.runInContext('Function', context);
  let error = null;
  try { vm.runInContext(script, context, { filename: 'blob:worker' }); } catch (e) { error = e; }
  const line = error ? Number((/blob:worker:(\d+)/.exec(String(error.stack)) || [])[1]) : null;
  return { context, error, line, messages: () => Array.from(vm.runInContext('messages', context)) };
}

const run = (w, code) => vm.runInContext(code, w);
// Bun runs JavaScriptCore, Safari's engine; Node runs V8.
const JSC = typeof Bun !== 'undefined';
let failures = 0;
function test(name, fn) {
  Promise.resolve().then(fn).then(
    () => console.log(`ok   ${name}`),
    (e) => { failures++; console.log(`FAIL ${name}\n     ${e.message}`); if (process.env.SHIM_DEBUG) console.log(e.stack); });
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

// ---- Time zone: an engine that already runs in the zone ---------------------------------------
// The profile's process pool can set the zone in the engine (ProfileProcessPool): Date and Intl
// then stay the engine's own, and a realm whose engine reports another zone still gets the shim.
const SHAPE = "[Object.getOwnPropertyNames(Date).join(), Object.getOwnPropertyNames(Intl.DateTimeFormat).join()].join('|')";
test('time zone: an engine already in the profile zone keeps its own Date and Intl', () => {
  const host = new Intl.DateTimeFormat().resolvedOptions().timeZone;
  const w = makeWindow({ ...base, timeZone: host, engineTimeZone: true });
  assert.equal(run(w, SHAPE), vm.runInContext(SHAPE, vm.createContext({})));
  assert.equal(run(w, 'Intl.DateTimeFormat().resolvedOptions().timeZone'), host);
});
test('time zone: an engine in the zone a link names (US/Eastern) keeps its own Date and Intl', () => {
  // The harness runs with TZ=America/New_York; US/Eastern is a link to it.
  const host = new Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (host !== 'America/New_York') return;
  const w = makeWindow({ ...base, timeZone: 'US/Eastern', engineTimeZone: true });
  assert.equal(run(w, SHAPE), vm.runInContext(SHAPE, vm.createContext({})));
});
test('time zone: a realm whose engine reports another zone still gets the shim', () => {
  const w = makeWindow({ ...base, timeZone: 'Asia/Tokyo', engineTimeZone: true });
  assert.notEqual(run(w, SHAPE), vm.runInContext(SHAPE, vm.createContext({})));
  assert.equal(run(w, `new Date('2024-01-15T12:00:00Z').getTimezoneOffset()`), -540);
  assert.equal(run(w, 'Intl.DateTimeFormat().resolvedOptions().timeZone'), 'Asia/Tokyo');
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
const everything = { geolocation: { mode: 'fixed', latitude: 1, longitude: 2, accuracy: 3 }, webRTC: 'relayOnly', timeZone: 'Europe/Berlin', device: iPhone, storageQuota: 0.6 * 128 * 2 ** 30 };
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
  ['Object.getOwnPropertyDescriptor(PermissionStatus.prototype, "state").get', 'PermissionStatus', 'state'],
  ['StorageManager.prototype.estimate', 'StorageManager'],
  ['Object.getOwnPropertyDescriptor(GeolocationCoordinates.prototype, "latitude").get', 'GeolocationCoordinates', 'latitude'],
  ['Object.getOwnPropertyDescriptor(GeolocationPositionError.prototype, "code").get', 'GeolocationPositionError', 'code'],
  ['GeolocationPosition.prototype.toJSON', 'GeolocationPosition'],
  ['RTCPeerConnection.prototype.setConfiguration', 'RTCPeerConnection'], ['window.open'],
  ['URL.createObjectURL'], ['URL.revokeObjectURL'],
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

test('iPad profile: the Mac platform (desktop websites), the iPad touch points and screen', () => {
  const iPad = { maxTouchPoints: 5, hardwareConcurrency: 8, screenWidth: 820, screenHeight: 1180, devicePixelRatio: 2 };
  const w = makeWindow({ ...base, device: iPad });
  assert.equal(run(w, surface), JSON.stringify(['MacIntel', 5, 8, 'en-US', ['en-US'], 'undefined', 820, 1180, 820, 1180, 2, 820, 1180]));
  // navigator.platform is not replaced at all: still the harness's own getter.
  assert.equal(run(w, `Object.getOwnPropertyDescriptor(Navigator.prototype, 'platform').get.toString().includes("illegal(this, Navigator)")`), true);
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

test('storage quota: Safari\'s instead of the app default', async () => {
  // WebKit: ceil(0.6 × 128 GB) for a browser's top-level origin on any Mac.
  const w = makeWindow({ ...base, storageQuota: 0.6 * 128 * 2 ** 30 });
  assert.equal(await run(w, `navigator.storage.estimate().then((e) => [e.quota, e.usage].join())`), '82463372084,1234');
  const plain = makeWindow(base);
  assert.equal(await run(plain, `navigator.storage.estimate().then((e) => e.quota)`), 1048576000);
  // A store with Safari's quota in WebKit (SafariStorageQuota): no storageQuota, estimate() untouched.
  assert.match(run(plain, `Function.prototype.toString.call(StorageManager.prototype.estimate)`), /illegal/);
});

test('geolocation answered by the engine: geolocation and permissions are the engine\'s own', () => {
  // WebKit denies the request and reports the state (BrowserTab, GeolocationPermission): no wrapper.
  const w = makeWindow({ ...base, geolocation: { mode: 'engine' } });
  for (const expr of ['Geolocation.prototype.getCurrentPosition', 'Geolocation.prototype.watchPosition', 'Permissions.prototype.query',
                      'Object.getOwnPropertyDescriptor(PermissionStatus.prototype, "state").get',
                      'Object.getOwnPropertyDescriptor(GeolocationPositionError.prototype, "code").get']) {
    assert.ok(!run(w, `Function.prototype.toString.call(${expr})`).includes('[native code]'), expr);
  }
  assert.ok(run(makeWindow(base), 'Function.prototype.toString.call(Geolocation.prototype.getCurrentPosition)').includes('[native code]'));
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

test('WebRTC disabled where the engine kept it: workers made from a blob lose its interfaces too', () => {
  // A macOS profile with zone and quota in the engine needs nothing else in a worker; with WebRTC
  // left on by the engine its workers still get the shim, for RTCDataChannel.
  const w = makeWindow({ geolocation: { mode: 'engine' }, webRTC: 'disabled' });
  assert.equal(run(w, 'typeof RTCPeerConnection'), 'undefined');
  const worker = blobWorker(w, JSON.stringify(["postMessage([typeof RTCDataChannel, typeof RTCPeerConnection].join())"]));
  assert.deepEqual(runWorker(worker.script).messages(), ['undefined,undefined']);
  assert.deepEqual(runWorker("postMessage([typeof RTCDataChannel, typeof RTCPeerConnection].join())").messages(), ['function,undefined']);
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

// ---- Workers made from a blob ------------------------------------------------------------------
// The page's blob reaches the engine as [its directives, the shim on one line, the rest]: no eval
// (blocked and reported under a CSP without 'unsafe-eval'), nothing read back (connect-src), and
// the page's strict mode and line numbers kept — each script is also run as the engine runs the
// page's own blob, for comparison.
const ZONE_REPORT = "postMessage([Intl.DateTimeFormat().resolvedOptions().timeZone, new Date(Date.UTC(2024, 0, 15, 12)).getTimezoneOffset(), (function () { return this === undefined; })()].join())";
const tokyo = { ...base, timeZone: 'Asia/Tokyo' };
const LINE_BREAKS = new RegExp('\\r\\n|[\\n\\r' + String.fromCharCode(0x2028, 0x2029) + ']');
const lineCount = (text) => text.split(LINE_BREAKS).length;
// What the page's next worker is made with, for Blob parts given as an expression in the page.
function blobWorker(w, parts, kind = 'Worker') {
  const index = run(w, '__engine.workers.length');
  run(w, `new ${kind}(URL.createObjectURL(new Blob(${parts}, { type: 'text/javascript' })))`);
  return run(w, `__engine.workers[${index}]`);
}

test('workers: the shim goes into a blob worker as one line of code, without eval', () => {
  const w = makeWindow(tokyo);
  const code = "'use strict'\n" + ZONE_REPORT;
  const worker = blobWorker(w, JSON.stringify([code]));
  assert.equal(lineCount(worker.script), lineCount(code));
  assert.ok(!/\beval\s*\(/.test(worker.script), 'no eval');
  // As under a CSP without 'unsafe-eval' (V8 can forbid code from strings in a realm).
  const worker2 = runWorker(worker.script, { codeGeneration: false });
  assert.equal(worker2.error, null);
  assert.deepEqual(worker2.messages(), ['Asia/Tokyo,-540,true']);
});

test('workers: the page\'s directives stay first; its lines and strict mode are its own', () => {
  const w = makeWindow(tokyo);
  const strict = "postMessage(String((function () { return this === undefined; })()))";
  const cases = [
    ["'use strict'\n" + strict],
    ['"use strict";' + strict],
    ["/* licence\n */\n// comment\n'use strict';\r\n" + strict],
    ["'use strict' + 1;\n" + strict], // no directive: sloppy, as the engine runs it
    ["'use str", "ict';\n", strict],  // the directive across parts
    ['\n\n' + strict],
    [strict],
    ["'use strict'\n\nthrow new Error('x')"],
    ["\n\nthrow new Error('x')"],
    ["'use strict'"],                // nothing but a directive, with no ; or line break after it
    ["'use strict'  "],
  ];
  for (const parts of cases) {
    const own = runWorker(parts.join(''));
    const worker = blobWorker(w, JSON.stringify(parts));
    const hooked = runWorker(worker.script);
    assert.deepEqual([hooked.messages(), hooked.line], [own.messages(), own.line], JSON.stringify(parts));
    assert.equal(lineCount(worker.script), lineCount(parts.join('')), JSON.stringify(parts));
  }
});

test('workers: a blob not made from strings gets the shim first', () => {
  const w = makeWindow(tokyo);
  const worker = blobWorker(w, `[new Uint8Array([${Array.from(ZONE_REPORT, (c) => c.charCodeAt(0)).join()}])]`);
  assert.ok(worker.script.startsWith('(function install(CONFIG)'));
  assert.deepEqual(runWorker(worker.script).messages(), ['Asia/Tokyo,-540,false']);
});

test('workers: the configuration goes in without a line break', () => {
  const w = makeWindow({ ...tokyo, note: 'a' + String.fromCharCode(0x2028, 0x2029) });
  const worker = blobWorker(w, JSON.stringify([ZONE_REPORT]));
  assert.equal(lineCount(worker.script), 1);
  assert.deepEqual(runWorker(worker.script).messages(), ['Asia/Tokyo,-540,false']);
});

test('workers: a blob worker\'s own blob workers get the same shim', () => {
  const w = makeWindow(tokyo);
  const code = 'new Worker(URL.createObjectURL(new Blob([' + JSON.stringify(ZONE_REPORT) + '])));';
  const outer = blobWorker(w, JSON.stringify([code]));
  const realm = runWorker(outer.script);
  assert.equal(realm.error, null);
  const inner = vm.runInContext('__engine.workers[0].script', realm.context);
  assert.equal(inner.slice(0, -ZONE_REPORT.length), outer.script.slice(0, -code.length));
  assert.deepEqual(runWorker(inner).messages(), ['Asia/Tokyo,-540,false']);
});

test('workers: the URL is converted once, as the engine converts it', () => {
  const w = makeWindow(tokyo);
  assert.equal(run(w, `(() => {
    const url = URL.createObjectURL(new Blob(['1']));
    let calls = 0;
    new Worker({ toString() { calls++; return url; } });
    let error = '';
    try { new Worker(Symbol()); } catch (e) { error = e.constructor.name; }
    return [calls, __engine.workers[0].script.startsWith('(function install'), error].join();
  })()`), '1,true,TypeError');
});

test('workers: a TrustedScriptURL, or any URL under a default policy, reaches the engine as given', () => {
  const w = makeWindow(tokyo);
  assert.equal(run(w, `(() => {
    const policy = trustedTypes.createPolicy('page', { createScriptURL: (u) => u });
    const url = URL.createObjectURL(new Blob(['1']));
    const trusted = policy.createScriptURL(url);
    new Worker(trusted);
    const first = __engine.workers[0];
    __engine.tt.enforced = true;
    const seen = [];
    trustedTypes.createPolicy('default', { createScriptURL: (u) => { seen.push(u); return u; } });
    const url2 = URL.createObjectURL(new Blob(['2']));
    new Worker(url2);
    const second = __engine.workers[1];
    return [first.raw === trusted, first.script, seen.join() === url2, second.url === url2, second.script, __engine.tt.violations.length].join();
  })()`), 'true,1,true,true,2,0');
});

test('workers: a revoked URL fails as the engine\'s would', () => {
  const w = makeWindow(tokyo);
  assert.equal(run(w, `(() => {
    const url = URL.createObjectURL(new Blob(['1']));
    new Worker(url);
    const replacement = __engine.workers[0].url;
    URL.revokeObjectURL(url);
    new Worker(url);
    const again = __engine.workers[1];
    const other = URL.createObjectURL(new Blob(['2']));
    URL.revokeObjectURL(other);
    new Worker(other);
    return [replacement !== url, __engine.urls.has(replacement), again.url === replacement, again.script, __engine.workers[2].url === other, __engine.workers[2].script].join();
  })()`), 'true,false,true,,true,');
});

test('workers: a shared worker is made from the same blob for the same URL', () => {
  const w = makeWindow(tokyo);
  assert.equal(run(w, `(() => {
    const url = URL.createObjectURL(new Blob(['onconnect = () => {};']));
    new SharedWorker(url, 'a');
    new SharedWorker(url, 'a');
    return [__engine.workers[0].url === __engine.workers[1].url, __engine.workers[0].url !== url, __engine.workers[1].options].join();
  })()`), 'true,true,a');
});

test('workers: built-ins a page replaced are not what the worker hook calls', () => {
  const made = (tamper) => {
    const w = makeWindow(tokyo);
    if (tamper) {
      run(w, `(() => {
        const boom = function () { throw new Error('page code ran'); };
        const define = Object.defineProperty;
        const replace = [[String.prototype, ['charCodeAt', 'slice', 'indexOf', 'replace', 'toLowerCase', 'toString']], [RegExp.prototype, ['exec', 'test']],
          [Map.prototype, ['get', 'set', 'has', 'delete', 'forEach']], [WeakMap.prototype, ['get', 'set', 'has']], [Reflect, ['construct', 'apply']],
          [Function.prototype, ['call', 'apply', 'bind']], [JSON, ['stringify', 'parse']], [Object, ['create', 'defineProperty', 'getPrototypeOf', 'getOwnPropertyDescriptor']],
          [Array.prototype, ['push', 'slice', 'join']]];
        for (let i = 0; i < replace.length; i++) for (let k = 0; k < replace[i][1].length; k++) replace[i][0][replace[i][1][k]] = boom;
        // The engine reads a page's own options object (type, endings) through these, as it should;
        // setting them, or reading the iterator members, on an object of the hook's would be the hook.
        for (const name of ['type', 'endings']) define(Object.prototype, name, { __proto__: null, get() {}, set: boom, configurable: true });
        for (const name of ['next', 'done', 'value', 'return']) define(Object.prototype, name, { __proto__: null, get: boom, set: boom, configurable: true });
        globalThis.String = boom;
      })()`);
    }
    return blobWorker(w, "['\\'use strict\\';\\n" + ZONE_REPORT.replace(/'/g, "\\'") + "']");
  };
  const clean = made(false), tampered = made(true);
  assert.equal(tampered.script, clean.script);
  assert.deepEqual(runWorker(tampered.script).messages(), ['Asia/Tokyo,-540,true']);
});

test('Blob keeps the engine\'s shape, and File still inherits from it', () => {
  const shape = `[Blob.name, Blob.length, Object.getOwnPropertyNames(Blob).join(), Object.getPrototypeOf(File) === Blob,
    Blob.prototype.constructor === Blob, new Blob(['ab']) instanceof Blob, new Blob(['ab']).size, new File(['a'], 'f') instanceof Blob,
    (() => { class B extends Blob {} const b = new B(['xyz']); return b instanceof B && b.size === 3 && b.constructor === B; })(),
    (() => { try { Blob(); } catch (e) { return e.constructor.name; } })(),
    (() => { try { new Blob(5); } catch (e) { return e.message; } })(),
    (() => { try { new Blob({}); } catch (e) { return e.message; } })(),
    Object.getOwnPropertyDescriptor(window, 'Blob').enumerable, Object.getOwnPropertyDescriptor(Blob, 'prototype').writable].join('|')`;
  const w = makeWindow(tokyo);
  assert.equal(run(w, shape), run(makeWindow(base), shape));
  assert.equal(run(w, 'Function.prototype.toString.call(Blob)'), nativeText('Blob'));
  assert.equal(run(w, 'Function.prototype.toString.call(Worker)'), nativeText('Worker'));
  assert.equal(run(w, 'Object.getOwnPropertyNames(Worker).join()'), run(makeWindow(base), 'Object.getOwnPropertyNames(Worker).join()'));
});

test('Blob reads the page\'s parts as the engine reads them', () => {
  const probe = `(() => {
    const log = [];
    const parts = ['a', { toString() { log.push('toString'); return 'b'; } }];
    const proxy = new Proxy(parts, { get(t, k, r) { log.push('get ' + String(k)); return Reflect.get(t, k, r); } });
    const b1 = new Blob(proxy);
    let i = 0;
    const iterable = { get [Symbol.iterator]() { log.push('@@iterator'); return function () {
      return { get next() { log.push('next'); return () => ({ get done() { log.push('done'); return i >= 2; }, get value() { log.push('value'); return 'v' + i++; } }); },
               get return() { log.push('return'); return () => { log.push('closed'); return {}; }; } };
    }; } };
    const b2 = new Blob(iterable);
    const failing = { *[Symbol.iterator]() { try { yield 'x'; yield { toString() { throw new Error('part'); } }; yield 'never'; } finally { log.push('finally'); } } };
    let error = '';
    try { new Blob(failing); } catch (e) { error = e.message; }
    return [log.join(), b1.size, b2.size, error].join('|');
  })()`;
  assert.equal(run(makeWindow(tokyo), probe), run(makeWindow(base), probe));
});

process.on('beforeExit', () => {
  if (failures) { console.log(`${failures} failure(s)`); process.exitCode = 1; }
  else console.log(`all shim tests passed (${JSC ? 'JavaScriptCore, Bun ' + Bun.version : 'V8, Node ' + process.version})`);
});
