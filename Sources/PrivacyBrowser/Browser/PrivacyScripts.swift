import BrowserCore
import Foundation
import WebKit

/// JavaScript shims for settings WebKit has no native per-web-view API for: time zone,
/// geolocation, WebRTC, and — for mobile generations only — the navigator and screen values of
/// the declared device. Best-effort and detectable; not engine-level.
///
/// What is deliberately NOT touched, because a fingerprinting test looks exactly for it:
///   * canvas, WebGL, audio and font rendering: noise makes two readings differ ("Canvas:
///     Spoofed", "Fingerprinting Resistance: Detected"), and the engine underneath is this Mac's
///     WebKit either way;
///   * navigator.plugins / mimeTypes: the HTML spec's fixed list of five PDF viewers ("PDF
///     Viewer", "Chrome PDF Viewer", "Chromium PDF Viewer", "Microsoft Edge PDF Viewer",
///     "WebKit built-in PDF") is what every real Safari reports, on the Mac and on iOS;
///   * navigator.language(s): it must match the Accept-Language header, which only WebKit sets
///     (see `WebContentLanguage`); WebKit exposes a single language, as Safari does;
///   * navigator.deviceMemory: Safari does not implement it, so defining it marks a fake.
/// A macOS profile overrides no navigator or screen value at all: it runs on the very engine and
/// hardware it declares, and native values agree with everything else a page can measure
/// (CSS media queries, window sizes), which a fixed screen size would not.
///
/// What is replaced is replaced the way the engine defines it: accessors on the prototypes,
/// strict methods with only `length` and `name`, the native receiver checks, and a
/// `Function.prototype.toString` that prints them as native code — also when a page asks the
/// toString of a fresh iframe (one registry per page, shared by every same-origin frame). The
/// time zone shim covers the local constructor forms, `Date.parse`, the setters and
/// sub-minute historical offsets, so Date is consistent with itself, not only with `Intl`.
/// Web Workers are out of reach of a user script: their `Date`/`Intl` keep the host zone.
enum PrivacyScripts {
    struct ShimConfiguration: Encodable {
        var timeZone: String?
        var geolocation: Geolocation
        var webRTC: String
        /// Mobile generations only; nil for macOS (see above).
        var device: Device?
        /// macOS generation: Safari the app exposes `window.safari` (`pushNotification`), a
        /// WKWebView does not; a page that checks it is told the same as by Safari.
        var safariObject: Bool

        struct Geolocation: Encodable {
            var mode: String
            var latitude: Double?
            var longitude: Double?
            var accuracy: Double?
        }

        /// What the declared device's Safari reports where it differs from this Mac.
        struct Device: Encodable {
            var platform: String
            var maxTouchPoints: Int
            /// WebKit reports 4 below 8 cores (every iPhone) and 8 from 8 cores on.
            var hardwareConcurrency: Int
            var screenWidth: Int
            var screenHeight: Int
            var devicePixelRatio: Double
        }
    }

    static func shimConfiguration(for configuration: ProfileConfiguration) -> ShimConfiguration {
        let geolocation: ShimConfiguration.Geolocation
        switch configuration.geolocation {
        case .deny:
            geolocation = .init(mode: "deny")
        case let .fixed(latitude, longitude, accuracy):
            geolocation = .init(mode: "fixed", latitude: latitude, longitude: longitude, accuracy: accuracy)
        }
        let device: ShimConfiguration.Device?
        switch configuration.deviceGeneration.platform {
        case .macOS:
            device = nil
        case .iOS:
            device = .init(platform: "iPhone", maxTouchPoints: 5, hardwareConcurrency: 4,
                           screenWidth: 390, screenHeight: 844, devicePixelRatio: 3)
        case .iPadOS:
            // The generation's UA is iPad Safari's mobile one ("iPad; CPU OS …"), which reports "iPad".
            device = .init(platform: "iPad", maxTouchPoints: 5, hardwareConcurrency: 8,
                           screenWidth: 820, screenHeight: 1180, devicePixelRatio: 2)
        }
        return ShimConfiguration(timeZone: configuration.timeZoneIdentifier, geolocation: geolocation,
                                 webRTC: configuration.webRTCPolicy.rawValue, device: device,
                                 safariObject: configuration.deviceGeneration.platform == .macOS)
    }

    /// The declared device's screen in points for a mobile generation (the browser window is
    /// sized to it, so inner sizes never exceed the screen the page is told about); nil for macOS.
    static func deviceScreenSize(for configuration: ProfileConfiguration) -> CGSize? {
        guard let device = shimConfiguration(for: configuration).device else { return nil }
        return CGSize(width: device.screenWidth, height: device.screenHeight)
    }

    static func makeUserContentController(for configuration: ProfileConfiguration) -> WKUserContentController {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: source(for: configuration),
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false,
                                              in: .page))
        return controller
    }

    static func source(for configuration: ProfileConfiguration) -> String {
        let json = (try? String(data: JSONEncoder().encode(shimConfiguration(for: configuration)), encoding: .utf8)) ?? "{}"
        return "(function (CONFIG) {\n" + shimBody + "\n})(" + json + ");"
    }

    static let shimBody = #"""
'use strict';
const patched = new WeakSet();
// Shared by every same-origin frame of the page: the frame above answers with its registry when
// its (patched) Function.prototype.toString is called with this key as `this`.
const REGISTRY_KEY = Symbol.for('wk.shim.registry');
const registry = acquireRegistry();
// How this engine prints a native function; the name is substituted per function.
const NATIVE_TEMPLATE = Function.prototype.toString.call(Array.prototype.push).replace('push', '%NAME%');

function acquireRegistry() {
  let w = window;
  try {
    while (w.parent && w.parent !== w) {
      w = w.parent;
      const shared = w.Function.prototype.toString.call(REGISTRY_KEY); // native: TypeError
      if (shared) return shared;
    }
  } catch (e) {}
  return new WeakMap();
}

function patchWindow(w) {
  if (!w || patched.has(w)) return;
  patched.add(w);
  try { patchToString(w); } catch (e) {}
  if (CONFIG.device) { try { patchDevice(w, CONFIG.device); } catch (e) {} }
  if (CONFIG.safariObject) { try { patchSafariObject(w); } catch (e) {} }
  if (CONFIG.timeZone) { try { patchTimeZone(w, CONFIG.timeZone); } catch (e) {} }
  try { patchGeolocation(w, CONFIG.geolocation || { mode: 'deny' }); } catch (e) {}
  try { patchWebRTC(w, CONFIG.webRTC || 'disabled'); } catch (e) {}
  try { hookChildWindows(w); } catch (e) {}
}

// ---- Functions that look native -------------------------------------------------------------
// Every replacement is a strict method or accessor: own properties `length` and `name` only, no
// `prototype`, not constructible, `caller`/`arguments` throw. Its text is registered so that
// Function.prototype.toString (patched per realm, one registry per page) prints it as native.

// Native functions list `length` before `name`; a method made with a computed key does not.
function orderOwnProperties(fn) {
  const length = Object.getOwnPropertyDescriptor(fn, 'length');
  const name = Object.getOwnPropertyDescriptor(fn, 'name');
  delete fn.length;
  delete fn.name;
  Object.defineProperty(fn, 'length', length);
  Object.defineProperty(fn, 'name', name);
  return fn;
}

function asNative(fn) {
  orderOwnProperties(fn);
  // The engine prints an accessor without its "get " / "set " prefix.
  registry.set(fn, NATIVE_TEMPLATE.replace('%NAME%', fn.name.replace(/^[gs]et /, '')));
  return fn;
}

// A constructor shaped like a native one: `target` does the work (its new.target is the real
// one), the bound function in front of it has no `prototype` of its own, so the own properties
// can be laid out as the engine lays them out: statics, length, name, prototype.
function constructor(name, length, target, statics, prototype) {
  const fn = Function.prototype.bind.call(target, null);
  delete fn.length;
  delete fn.name;
  for (const key of Object.keys(statics)) define(fn, key, statics[key]);
  Object.defineProperty(fn, 'length', { value: length, writable: false, enumerable: false, configurable: true });
  Object.defineProperty(fn, 'name', { value: name, writable: false, enumerable: false, configurable: true });
  Object.defineProperty(fn, 'prototype', { value: prototype, writable: false, enumerable: false, configurable: false });
  registry.set(fn, NATIVE_TEMPLATE.replace('%NAME%', name));
  return fn;
}

function method(name, length, impl) {
  const fn = { [name](...args) { return impl.apply(this, args); } }[name];
  Object.defineProperty(fn, 'length', { value: length });
  return asNative(fn);
}

function getter(name, impl) {
  return asNative(Object.getOwnPropertyDescriptor({ get [name]() { return impl.call(this); } }, name).get);
}

function patchToString(w) {
  const proto = w.Function.prototype;
  const native = proto.toString;
  const toString = orderOwnProperties({ toString() {
    if (this === REGISTRY_KEY) return registry;
    const text = registry.get(this);
    return text !== undefined ? text : native.call(this);
  } }.toString);
  registry.set(toString, native.call(native));
  Object.defineProperty(proto, 'toString', { value: toString, writable: true, enumerable: false, configurable: true });
}

// Replaces a property keeping its enumerability (window.open is enumerable, prototype methods are not).
function define(target, name, value) {
  const existing = Object.getOwnPropertyDescriptor(target, name);
  Object.defineProperty(target, name, { value: value, writable: true, configurable: true,
                                        enumerable: existing ? !!existing.enumerable : false });
}

// ---- Device (mobile generations) -------------------------------------------------------------
// The declared device's navigator and screen values as accessors where the engine defines them:
// on the prototypes for navigator and screen (no own property appears on the instances), on the
// window itself for its own attributes. Each calls the native accessor first, so a wrong receiver
// (Navigator.prototype.platform) throws the engine's TypeError. Rendering is left alone.
function patchDevice(w, device) {
  const nav = w.navigator;
  if (nav) {
    overrideGetter(w, nav, 'platform', device.platform);
    overrideGetter(w, nav, 'maxTouchPoints', device.maxTouchPoints);
    overrideGetter(w, nav, 'hardwareConcurrency', device.hardwareConcurrency);
    overrideGetter(w, nav, 'standalone', false); // iOS Safari only: false in a browser tab
  }
  const s = w.screen;
  if (s) {
    overrideGetter(w, s, 'width', device.screenWidth);
    overrideGetter(w, s, 'height', device.screenHeight);
    overrideGetter(w, s, 'availWidth', device.screenWidth); // iOS has no menu bar or Dock
    overrideGetter(w, s, 'availHeight', device.screenHeight);
  }
  overrideGetter(w, w, 'devicePixelRatio', device.devicePixelRatio);
  // On iOS the window is the screen; inner sizes stay what the web view really is.
  overrideGetter(w, w, 'outerWidth', device.screenWidth);
  overrideGetter(w, w, 'outerHeight', device.screenHeight);
}

function overrideGetter(w, obj, name, value) {
  let holder = obj;
  while (holder && !Object.prototype.hasOwnProperty.call(holder, name)) holder = Object.getPrototypeOf(holder);
  if (!holder || holder === Object.prototype) {
    // Not defined by this engine (navigator.standalone on the Mac): on the prototype, like iOS.
    const proto = Object.getPrototypeOf(obj);
    holder = proto && proto !== Object.prototype ? proto : obj;
  }
  const native = Object.getOwnPropertyDescriptor(holder, name);
  const Interface = holder === obj ? null : holder.constructor;
  const get = getter(name, function () {
    if (native && native.get) native.get.call(this); // enforces the receiver like the engine
    else if (Interface && !(this instanceof Interface)) {
      throw new w.TypeError('The ' + Interface.name + '.' + name + ' getter can only be used on instances of ' + Interface.name);
    }
    return value;
  });
  Object.defineProperty(holder, name, { get: get, set: native ? native.set : undefined,
                                        enumerable: native ? native.enumerable : true, configurable: true });
}

// ---- Time zone --------------------------------------------------------------------------------
// Date and Intl behave as if the system zone were TZ: local getters and setters, the local
// constructor forms, Date.parse of strings without an offset, toString's zone name, and the
// default time zone of Intl.DateTimeFormat and toLocale*String. Offsets keep sub-minute
// precision (pre-1900 "LMT" offsets have seconds), as the engine's own do.
function patchTimeZone(w, TZ) {
  const NativeDate = w.Date;
  const proto = NativeDate.prototype;
  const NativeDTF = w.Intl.DateTimeFormat;
  const nativeGetTime = proto.getTime;
  const nativeSetTime = proto.setTime;
  const nativeParse = NativeDate.parse;
  const nativeLocal = ['getFullYear', 'getMonth', 'getDate', 'getHours', 'getMinutes', 'getSeconds', 'getMilliseconds']
    .map((name) => proto[name]);

  const partsFormatter = new NativeDTF('en-US', {
    timeZone: TZ, hourCycle: 'h23', era: 'short',
    year: 'numeric', month: 'numeric', day: 'numeric',
    hour: 'numeric', minute: 'numeric', second: 'numeric'
  });
  // The page's default locale, as the native Date#toString names the zone.
  const nameFormatter = new NativeDTF(undefined, { timeZone: TZ, timeZoneName: 'long' });
  const offsetCache = new Map();

  // Minutes west of UTC at instant t (fractional before standard time), as getTimezoneOffset.
  function offsetFor(t) {
    const bucket = Math.floor(t / 900000);
    if (offsetCache.has(bucket)) return offsetCache.get(bucket);
    const p = {};
    for (const part of partsFormatter.formatToParts(new NativeDate(t))) p[part.type] = part.value;
    let year = +p.year;
    if (p.era === 'BC' || p.era === 'B') year = 1 - year;
    const wallAsUTC = new NativeDate(0);
    wallAsUTC.setUTCFullYear(year, +p.month - 1, +p.day);
    wallAsUTC.setUTCHours(+p.hour % 24, +p.minute, +p.second, 0);
    const truncated = t - (((t % 1000) + 1000) % 1000);
    const offset = (truncated - nativeGetTime.call(wallAsUTC)) / 60000;
    if (offsetCache.size > 512) offsetCache.clear();
    offsetCache.set(bucket, offset);
    return offset;
  }
  // Wall-clock time in TZ, expressed as a UTC timestamp, and back.
  const toWall = (t) => t - offsetFor(t) * 60000;
  function fromWall(wallMs) {
    let t = wallMs + offsetFor(wallMs) * 60000;
    t = wallMs + offsetFor(t) * 60000; // second pass settles instants near a transition
    return t;
  }
  // A string the engine parsed as host-local time: the wall clock it meant, read back with the
  // engine's own local getters (they and its parser agree to the millisecond, even for the
  // pre-standard-time offsets with seconds).
  function hostToWall(tHost) {
    const date = new NativeDate(tHost);
    const [year, month, day, hours, minutes, seconds, ms] = nativeLocal.map((getter) => getter.call(date));
    const wall = new NativeDate(0);
    wall.setUTCFullYear(year, month, day);
    wall.setUTCHours(hours, minutes, seconds, ms);
    return nativeGetTime.call(wall);
  }
  // Strings with their own offset (Z, +01:00, GMT+0100, UTC, EST…) or date-only ISO forms (UTC per spec).
  const absolute = /^\d{4}(-\d{2}){0,2}$|(?:Z|[+-]\d{2}:?\d{2}|\b(?:UTC?|GMT|[ECMP][SD]T)\b)(?:\s*\(.*\))?\s*$/i;

  function parse(text) {
    const tHost = nativeParse.call(NativeDate, text);
    if (isNaN(tHost) || absolute.test(String(text).trim())) return tHost;
    return fromWall(hostToWall(tHost));
  }

  function construct(target, args) {
    if (args.length === 0) return Reflect.construct(NativeDate, [], target);
    if (args.length === 1) {
      let value = args[0];
      if (typeof value === 'object' && value !== null && !(value instanceof NativeDate)) {
        value = value[Symbol.toPrimitive] ? value[Symbol.toPrimitive]('default') : value.valueOf();
        if (typeof value === 'object') value = String(value);
      }
      if (typeof value === 'string') return Reflect.construct(NativeDate, [parse(value)], target);
      return Reflect.construct(NativeDate, [value], target);
    }
    const numbers = args.map(Number);
    let year = numbers[0];
    if (!isNaN(year)) { const whole = Math.trunc(year); if (whole >= 0 && whole <= 99) year = 1900 + whole; }
    const wall = NativeDate.UTC(year, numbers[1], numbers.length > 2 ? numbers[2] : 1, numbers[3] || 0,
                                numbers[4] || 0, numbers[5] || 0, numbers[6] || 0);
    return Reflect.construct(NativeDate, [isNaN(wall) ? NaN : fromWall(wall)], target);
  }
  const target = function (...args) {
    if (new.target === undefined) return String(new DateShim());
    return construct(new.target, args);
  };
  target.prototype = proto; // what `new DateShim()` constructs with (new.target is then `target`)
  const DateShim = constructor('Date', 7, target, { parse: method('parse', 1, parse), UTC: NativeDate.UTC, now: NativeDate.now }, proto);
  define(proto, 'constructor', DateShim);
  define(w, 'Date', DateShim);

  const utcGetters = {
    FullYear: proto.getUTCFullYear, Month: proto.getUTCMonth, Date: proto.getUTCDate,
    Day: proto.getUTCDay, Hours: proto.getUTCHours, Minutes: proto.getUTCMinutes,
    Seconds: proto.getUTCSeconds, Milliseconds: proto.getUTCMilliseconds
  };
  for (const name of Object.keys(utcGetters)) {
    const utcGetter = utcGetters[name];
    define(proto, 'get' + name, method('get' + name, 0, function () {
      const t = nativeGetTime.call(this);
      return isNaN(t) ? NaN : utcGetter.call(new NativeDate(toWall(t)));
    }));
  }
  define(proto, 'getYear', method('getYear', 0, function () {
    const t = nativeGetTime.call(this);
    return isNaN(t) ? NaN : new NativeDate(toWall(t)).getUTCFullYear() - 1900;
  }));
  define(proto, 'getTimezoneOffset', method('getTimezoneOffset', 0, function () {
    const t = nativeGetTime.call(this);
    return isNaN(t) ? NaN : offsetFor(t);
  }));

  const utcSetters = {
    FullYear: [proto.setUTCFullYear, 3], Month: [proto.setUTCMonth, 2], Date: [proto.setUTCDate, 1],
    Hours: [proto.setUTCHours, 4], Minutes: [proto.setUTCMinutes, 3], Seconds: [proto.setUTCSeconds, 2],
    Milliseconds: [proto.setUTCMilliseconds, 1]
  };
  for (const name of Object.keys(utcSetters)) {
    const [utcSetter, length] = utcSetters[name];
    define(proto, 'set' + name, method('set' + name, length, function (...args) {
      const t = nativeGetTime.call(this);
      // Only setFullYear works on an invalid date (from +0); the others leave it invalid.
      if (isNaN(t) && name !== 'FullYear') return nativeSetTime.call(this, NaN);
      const wallDate = new NativeDate(toWall(isNaN(t) ? 0 : t));
      const wall = utcSetter.apply(wallDate, args);
      return nativeSetTime.call(this, isNaN(wall) ? NaN : fromWall(wall));
    }));
  }
  define(proto, 'setYear', method('setYear', 1, function (year) {
    let y = Number(year);
    if (isNaN(y)) return nativeSetTime.call(this, NaN);
    const whole = Math.trunc(y);
    if (whole >= 0 && whole <= 99) y = 1900 + whole;
    return proto.setFullYear.call(this, y);
  }));

  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const pad = (n, l) => String(n).padStart(l || 2, '0');
  const yearString = (y) => (y < 0 ? '-' + pad(-y, 6) : pad(y, 4));
  function zoneSuffix(t) {
    const minutesEast = -offsetFor(t);
    const a = Math.abs(Math.trunc(minutesEast));
    const namePart = nameFormatter.formatToParts(new NativeDate(t)).find((p) => p.type === 'timeZoneName');
    return 'GMT' + (minutesEast >= 0 ? '+' : '-') + pad(Math.floor(a / 60)) + pad(a % 60) +
      ' (' + (namePart ? namePart.value : TZ) + ')';
  }
  const wall = (date) => { const t = nativeGetTime.call(date); return isNaN(t) ? null : new NativeDate(toWall(t)); };
  function datePart(s) {
    return days[s.getUTCDay()] + ' ' + months[s.getUTCMonth()] + ' ' + pad(s.getUTCDate()) + ' ' + yearString(s.getUTCFullYear());
  }
  function timePart(s, t) {
    return pad(s.getUTCHours()) + ':' + pad(s.getUTCMinutes()) + ':' + pad(s.getUTCSeconds()) + ' ' + zoneSuffix(t);
  }
  define(proto, 'toString', method('toString', 0, function () {
    const s = wall(this);
    return s === null ? 'Invalid Date' : datePart(s) + ' ' + timePart(s, nativeGetTime.call(this));
  }));
  define(proto, 'toDateString', method('toDateString', 0, function () {
    const s = wall(this);
    return s === null ? 'Invalid Date' : datePart(s);
  }));
  define(proto, 'toTimeString', method('toTimeString', 0, function () {
    const s = wall(this);
    return s === null ? 'Invalid Date' : timePart(s, nativeGetTime.call(this));
  }));

  const withZone = (options) => {
    const o = Object.assign({}, options);
    if (o.timeZone === undefined) o.timeZone = TZ;
    return o;
  };
  for (const name of ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString']) {
    const original = proto[name];
    define(proto, name, method(name, 0, function (locales, options) { return original.call(this, locales, withZone(options)); }));
  }

  const dtfTarget = function (locales, options) {
    return Reflect.construct(NativeDTF, [locales, withZone(options)], new.target === undefined ? dtfTarget : new.target);
  };
  dtfTarget.prototype = NativeDTF.prototype; // instanceof goes through the bound target
  const DateTimeFormat = constructor('DateTimeFormat', 0, dtfTarget, { supportedLocalesOf: NativeDTF.supportedLocalesOf }, NativeDTF.prototype);
  define(NativeDTF.prototype, 'constructor', DateTimeFormat);
  define(w.Intl, 'DateTimeFormat', DateTimeFormat);
}

// ---- Safari the app -----------------------------------------------------------------------------
// Safari exposes window.safari, a plain object holding a SafariRemoteNotification (website push
// permission API); a page that looks for it to recognise Safari finds what Safari would give it.
function patchSafariObject(w) {
  if ('safari' in w) return;
  const proto = {};
  Object.defineProperty(proto, Symbol.toStringTag, { value: 'SafariRemoteNotification', writable: false, enumerable: false, configurable: true });
  define(proto, 'permission', method('permission', 1, function () { return { deviceToken: null, permission: 'default' }; }));
  define(proto, 'requestPermission', method('requestPermission', 4, function (websiteURL, websitePushID, userInfo, callback) {
    if (typeof callback === 'function') w.setTimeout(() => callback({ deviceToken: null, permission: 'denied' }), 0);
  }));
  const safari = {};
  Object.defineProperty(safari, 'pushNotification', { value: Object.create(proto), writable: true, enumerable: true, configurable: true });
  Object.defineProperty(w, 'safari', { value: safari, writable: true, enumerable: true, configurable: true });
}

// ---- Geolocation ------------------------------------------------------------------------------
function patchGeolocation(w, geo) {
  const nav = w.navigator;
  if (!nav || !nav.geolocation) return;
  const GeoProto = Object.getPrototypeOf(nav.geolocation);
  const DENIED = { code: 1, message: 'User denied Geolocation', PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 };
  if (w.GeolocationPositionError) Object.setPrototypeOf(DENIED, w.GeolocationPositionError.prototype);

  function position() {
    const coords = Object.create(w.GeolocationCoordinates ? w.GeolocationCoordinates.prototype : Object.prototype);
    const values = { latitude: geo.latitude, longitude: geo.longitude, accuracy: geo.accuracy,
                     altitude: null, altitudeAccuracy: null, heading: null, speed: null };
    for (const k of Object.keys(values)) Object.defineProperty(coords, k, { value: values[k], enumerable: true });
    const pos = Object.create(w.GeolocationPosition ? w.GeolocationPosition.prototype : Object.prototype);
    Object.defineProperty(pos, 'coords', { value: coords, enumerable: true });
    Object.defineProperty(pos, 'timestamp', { value: Date.now(), enumerable: true });
    return pos;
  }
  function respond(success, error) {
    w.setTimeout(() => {
      if (geo.mode === 'fixed') { if (typeof success === 'function') success(position()); }
      else if (typeof error === 'function') error(DENIED);
    }, 0);
  }
  let nextWatch = 1;
  const Geolocation = w.Geolocation;
  const checkReceiver = (receiver, name) => {
    if (Geolocation && !(receiver instanceof Geolocation)) throw new w.TypeError('Can only call Geolocation.' + name + ' on instances of Geolocation');
  };
  define(GeoProto, 'getCurrentPosition', method('getCurrentPosition', 1, function (success, error) {
    checkReceiver(this, 'getCurrentPosition');
    respond(success, error);
  }));
  define(GeoProto, 'watchPosition', method('watchPosition', 1, function (success, error) {
    checkReceiver(this, 'watchPosition');
    respond(success, error);
    return nextWatch++;
  }));
  define(GeoProto, 'clearWatch', method('clearWatch', 1, function () { checkReceiver(this, 'clearWatch'); }));

  if (nav.permissions && nav.permissions.query) {
    const PermProto = Object.getPrototypeOf(nav.permissions);
    const originalQuery = PermProto.query;
    define(PermProto, 'query', method('query', 1, function (descriptor) {
      if (descriptor && descriptor.name === 'geolocation') {
        const status = Object.create(w.PermissionStatus ? w.PermissionStatus.prototype : Object.prototype);
        Object.defineProperty(status, 'state', { value: geo.mode === 'fixed' ? 'granted' : 'denied', enumerable: true });
        Object.defineProperty(status, 'name', { value: 'geolocation', enumerable: true });
        status.onchange = null;
        return Promise.resolve(status);
      }
      return originalQuery.apply(this, arguments);
    }));
  }
}

// ---- WebRTC -----------------------------------------------------------------------------------
function patchWebRTC(w, policy) {
  if (policy === 'unrestricted') return;
  const names = ['RTCPeerConnection', 'webkitRTCPeerConnection'];
  if (policy === 'disabled') {
    // Removed outright, as in an engine built without WebRTC: no trace of a property remains.
    for (const name of names.concat(['RTCDataChannel', 'RTCIceCandidate', 'RTCSessionDescription',
                                     'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver'])) {
      try { delete w[name]; } catch (e) {}
      if (Object.prototype.hasOwnProperty.call(w, name)) {
        try { Object.defineProperty(w, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
      }
    }
    return;
  }
  const Native = w.RTCPeerConnection;
  if (!Native) return;
  const forceRelay = (config) => Object.assign({}, config, { iceTransportPolicy: 'relay' });
  const rtcTarget = function (config, ...rest) {
    return Reflect.construct(Native, [forceRelay(config), ...rest], new.target === undefined ? rtcTarget : new.target);
  };
  rtcTarget.prototype = Native.prototype; // instanceof goes through the bound target
  const statics = Native.generateCertificate ? { generateCertificate: Native.generateCertificate } : {};
  const RTCPeerConnection = constructor('RTCPeerConnection', 0, rtcTarget, statics, Native.prototype);
  const nativeSetConfiguration = Native.prototype.setConfiguration;
  if (nativeSetConfiguration) {
    define(Native.prototype, 'setConfiguration', method('setConfiguration', 0, function (config) {
      return nativeSetConfiguration.call(this, forceRelay(config));
    }));
  }
  define(Native.prototype, 'constructor', RTCPeerConnection);
  for (const name of names) {
    try { Object.defineProperty(w, name, { value: RTCPeerConnection, writable: true, enumerable: false, configurable: true }); } catch (e) {}
  }
}

// ---- Child windows ----------------------------------------------------------------------------
// This script runs in every same-origin frame; the accessors are patched for a window reached
// before its own copy ran (contentWindow of a frame created a moment ago, a popup).
function hookChildWindows(w) {
  const hook = (Ctor, prop, toWindow) => {
    if (!Ctor) return;
    const descriptor = Object.getOwnPropertyDescriptor(Ctor.prototype, prop);
    if (!descriptor || !descriptor.get) return;
    Object.defineProperty(Ctor.prototype, prop, {
      configurable: true, enumerable: descriptor.enumerable, set: descriptor.set,
      get: getter(prop, function () {
        const value = descriptor.get.call(this);
        try { patchWindow(toWindow(value)); } catch (e) {}
        return value;
      })
    });
  };
  hook(w.HTMLIFrameElement, 'contentWindow', (v) => v);
  hook(w.HTMLIFrameElement, 'contentDocument', (v) => v && v.defaultView);
  hook(w.HTMLFrameElement, 'contentWindow', (v) => v);
  hook(w.HTMLObjectElement, 'contentWindow', (v) => v);
  const nativeOpen = w.open;
  if (nativeOpen) {
    define(w, 'open', method('open', 0, function (...args) {
      const opened = nativeOpen.apply(this, args);
      try { patchWindow(opened); } catch (e) {}
      return opened;
    }));
  }
}

patchWindow(window);
"""#
}
