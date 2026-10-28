import BrowserCore
import Foundation
import WebKit

/// JavaScript shims for settings WebKit has no native per-web-view API for: time zone,
/// geolocation (a fixed position; a denial is WebKit's own, `GeolocationPermission`), WebRTC, and —
/// for mobile generations only — the navigator and screen values of the declared device.
/// Best-effort and detectable; not engine-level.
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
/// A user script never runs in a worker; workers created from a blob of the page (how
/// fingerprinting scripts create theirs) start with this script (`hookWorkers`), workers loaded
/// from a URL and service workers keep the host's zone. Where WebKit allows it the time zone is
/// not the shim's at all: the profile's process pool runs every page and worker in it
/// (`ProfileProcessPool`), and the shim, seeing the engine report the zone, replaces nothing.
enum PrivacyScripts {
    struct ShimConfiguration: Encodable {
        var timeZone: String?
        /// The profile's process pool runs in `timeZone` (`BrowserSession.timeZoneByEngine`): each
        /// realm checks that its engine reports the zone, and only where it does not is the shim
        /// installed.
        var engineTimeZone = false
        var geolocation: Geolocation
        /// "disabled", "relayOnly", "unrestricted", or "tunnel" (with `webRTCRelay`).
        var webRTC: String
        /// The packet tunnel's TURN relay for this launch (`ProfileConfiguration.webRTCRouting`).
        var webRTCRelay: Relay?
        /// Mobile generations only; nil for macOS (see above).
        var device: Device?
        /// macOS generation: Safari the app exposes `window.safari` (`pushNotification`), a
        /// WKWebView does not; a page that checks it is told the same as by Safari.
        var safariObject: Bool
        /// The per-origin storage quota Safari reports (`safariStorageQuota`), before rounding.
        var storageQuota: Double?

        struct Relay: Encodable {
            var urls: [String]
            var username: String
            var credential: String
        }

        struct Geolocation: Encodable {
            /// "engine" (WebKit denies it, BrowserTab answers the state) or "fixed"; "deny" is the
            /// shim's own denial (its tests).
            var mode: String
            var latitude: Double?
            var longitude: Double?
            var accuracy: Double?
        }

        /// What the declared device's Safari reports where it differs from this Mac.
        struct Device: Encodable {
            /// nil: the Mac's own ("MacIntel"), which an iPad showing desktop websites reports too.
            var platform: String?
            var maxTouchPoints: Int
            /// WebKit reports 4 below 8 cores (every iPhone) and 8 from 8 cores on.
            var hardwareConcurrency: Int
            var screenWidth: Int
            var screenHeight: Int
            var devicePixelRatio: Double
        }
    }

    static func shimConfiguration(for configuration: ProfileConfiguration, timeZoneByEngine: Bool = false,
                                  storageQuotaByEngine: Bool = false) -> ShimConfiguration {
        let webRTC: String
        var relay: ShimConfiguration.Relay?
        switch configuration.webRTCRouting {
        case .off: webRTC = WebRTCPolicy.disabled.rawValue
        case let .native(policy): webRTC = policy.rawValue
        case let .relay(tunnel):
            webRTC = "tunnel"
            relay = .init(urls: tunnel.urls, username: tunnel.username, credential: tunnel.credential)
        }
        let geolocation: ShimConfiguration.Geolocation
        switch configuration.geolocation {
        case .deny:
            // WebKit denies it and reports the state itself (BrowserTab, GeolocationPermission).
            geolocation = .init(mode: "engine")
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
            // iPad Safari shows desktop websites by default: the Mac's UA and platform, with the
            // iPad's touch points and screen (how a page tells an iPad from a Mac).
            device = .init(platform: nil, maxTouchPoints: 5, hardwareConcurrency: 8,
                           screenWidth: 820, screenHeight: 1180, devicePixelRatio: 2)
        }
        return ShimConfiguration(timeZone: configuration.timeZoneIdentifier, engineTimeZone: timeZoneByEngine, geolocation: geolocation,
                                 webRTC: webRTC, webRTCRelay: relay, device: device,
                                 safariObject: configuration.deviceGeneration.platform == .macOS,
                                 // The data store reports Safari's quota itself: nothing to replace.
                                 storageQuota: storageQuotaByEngine ? nil : safariStorageQuota(for: configuration.deviceGeneration.platform))
    }

    /// navigator.storage.estimate().quota in Safari, before WebKit rounds it up: a browser's origin
    /// quota ratio (0.6) times WebKit's *standard* volume capacity — 128 GB on a Mac, 64 GB on
    /// iOS — which WebKit reports instead of the real disk size, so it is the same on every
    /// device (`WebsiteDataStore::defaultStandardVolumeCapacity`). An app that is not a browser
    /// reports a fixed 1000 MiB instead.
    static func safariStorageQuota(for platform: DeviceGeneration.Platform) -> Double {
        let gigabyte = 1024.0 * 1024.0 * 1024.0
        return 0.6 * (platform == .macOS ? 128 : 64) * gigabyte
    }

    /// The declared device's screen in points for a mobile generation (the browser window is
    /// sized to it, so inner sizes never exceed the screen the page is told about); nil for macOS.
    static func deviceScreenSize(for configuration: ProfileConfiguration) -> CGSize? {
        guard let device = shimConfiguration(for: configuration).device else { return nil }
        return CGSize(width: device.screenWidth, height: device.screenHeight)
    }

    static func makeUserContentController(for configuration: ProfileConfiguration, timeZoneByEngine: Bool = false,
                                          storageQuotaByEngine: Bool = false) -> WKUserContentController {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: source(for: configuration, timeZoneByEngine: timeZoneByEngine,
                                                             storageQuotaByEngine: storageQuotaByEngine),
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false,
                                              in: .page))
        return controller
    }

    static func source(for configuration: ProfileConfiguration, timeZoneByEngine: Bool = false, storageQuotaByEngine: Bool = false) -> String {
        let json = (try? String(data: JSONEncoder().encode(shimConfiguration(for: configuration, timeZoneByEngine: timeZoneByEngine,
                                                                             storageQuotaByEngine: storageQuotaByEngine)),
                                encoding: .utf8)) ?? "{}"
        return "(function install(CONFIG) {\n" + shimBody + "\n})(" + json + ");"
    }

    static let shimBody = #"""
'use strict';
const patched = new WeakSet();
// The same script runs in a worker created from a blob (see hookWorkers), where there is no window.
const IS_WORKER = typeof WorkerGlobalScope === 'function' && self instanceof WorkerGlobalScope;
// This whole script, read before Function.prototype.toString is replaced: what hookWorkers runs
// first in a worker. `install` is the name PrivacyScripts.source gives the wrapping function.
const SOURCE = typeof install === 'function' ? Function.prototype.toString.call(install) : null;
// Shared by every same-origin frame of the page: the frame above answers with its registry when
// its (patched) Function.prototype.toString is called with this key as `this`.
const REGISTRY_KEY = Symbol.for('wk.shim.registry');
const registry = acquireRegistry();
// How this engine prints a native function; the name is substituted per function.
const NATIVE_TEMPLATE = Function.prototype.toString.call(Array.prototype.push).replace('push', '%NAME%');

function acquireRegistry() {
  if (IS_WORKER) return new WeakMap();
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
  // With the profile's process pool in its zone, Date and Intl are the engine's own; a realm whose
  // engine does not report the zone (a process the override did not reach) gets the shim. Workers
  // made from a blob start with this script when they need anything of it: the zone (the engine's
  // is process-wide, so a realm in it has workers in it), the device's values or the quota.
  const zoneShim = !!CONFIG.timeZone && !(CONFIG.engineTimeZone && engineReportsZone(w, CONFIG.timeZone));
  if (zoneShim) { try { patchTimeZone(w, CONFIG.timeZone); } catch (e) {} }
  if (zoneShim || CONFIG.device || CONFIG.storageQuota) { try { hookWorkers(w); } catch (e) {} }
  if (CONFIG.storageQuota) { try { patchStorageQuota(w, CONFIG.storageQuota); } catch (e) {} }
  if (IS_WORKER) return; // no window, geolocation, WebRTC or frames in a worker
  if (CONFIG.safariObject) { try { patchSafariObject(w); } catch (e) {} }
  // 'engine': WebKit denies geolocation and reports the permission's state (GeolocationPermission).
  const geo = CONFIG.geolocation || { mode: 'deny' };
  if (geo.mode !== 'engine') { try { patchGeolocation(w, geo); } catch (e) {} }
  try { patchWebRTC(w, CONFIG.webRTC || 'disabled', CONFIG.webRTCRelay); } catch (e) {}
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
// can be laid out as the engine lays them out — for a built-in (Date): statics, length, name,
// prototype; for a DOM interface (`native` given): length, name, prototype, statics, and the
// interface it inherits from (EventTarget) as its [[Prototype]].
function constructor(name, length, target, statics, prototype, native) {
  const fn = Function.prototype.bind.call(target, null);
  delete fn.length;
  delete fn.name;
  const defineStatics = () => { for (const key of Object.keys(statics)) define(fn, key, statics[key]); };
  if (!native) defineStatics();
  Object.defineProperty(fn, 'length', { value: length, writable: false, enumerable: false, configurable: true });
  Object.defineProperty(fn, 'name', { value: name, writable: false, enumerable: false, configurable: true });
  Object.defineProperty(fn, 'prototype', { value: prototype, writable: false, enumerable: false, configurable: false });
  if (native) {
    defineStatics();
    Object.setPrototypeOf(fn, Object.getPrototypeOf(native));
  }
  registry.set(fn, NATIVE_TEMPLATE.replace('%NAME%', name));
  return fn;
}

function method(name, length, impl) {
  const fn = { [name](...args) { return ReflectApply(impl, this, args); } }[name];
  Object.defineProperty(fn, 'length', { value: length });
  return asNative(fn);
}

function getter(name, impl) {
  return asNative(Object.getOwnPropertyDescriptor({ get [name]() { return ReflectApply(impl, this, []); } }, name).get);
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
  if (IS_WORKER) {
    // WorkerNavigator has platform and hardwareConcurrency, nothing else of the device.
    if (nav && 'platform' in nav && device.platform) overrideGetter(w, nav, 'platform', device.platform);
    if (nav && 'hardwareConcurrency' in nav) overrideGetter(w, nav, 'hardwareConcurrency', device.hardwareConcurrency);
    return;
  }
  if (nav) {
    if (device.platform) overrideGetter(w, nav, 'platform', device.platform);
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
  for (const name of ['screenX', 'screenY', 'screenLeft', 'screenTop']) {
    if (name in w) overrideGetter(w, w, name, 0);
  }
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
// Whether this realm's engine already runs in TZ: its default zone is the one Intl names for TZ,
// or, for a link (Asia/Calcutta, which the engine names by its primary Asia/Kolkata; GMT, which it
// names UTC), a zone whose wall clock is the same over the zone's history.
const ZONE_PROBES = [-2208988800000, -880000000000, 0, 631152000000, 1262304000000, 1705320000000, 1721044800000];
function engineReportsZone(w, TZ) {
  try {
    const DTF = w.Intl.DateTimeFormat;
    if (new DTF().resolvedOptions().timeZone === new DTF(undefined, { timeZone: TZ }).resolvedOptions().timeZone) return true;
    const options = { era: 'short', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric',
                      second: 'numeric', hourCycle: 'h23' };
    const engine = new DTF('en-US', options);
    options.timeZone = TZ;
    const wanted = new DTF('en-US', options);
    for (let i = 0; i < ZONE_PROBES.length; i++) {
      if (engine.format(ZONE_PROBES[i]) !== wanted.format(ZONE_PROBES[i])) return false;
    }
    return true;
  } catch (e) { return false; }
}

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

// ---- Storage quota ------------------------------------------------------------------------------
// Safari, a browser to WebKit, reports 60 % of a standard volume (128 GB on a Mac) per origin;
// WebKit gives any other app a fixed 1000 MiB (a tenth of either to a third-party frame) — also the
// small quota private-mode detectors look for. estimate() reports Safari's figure, rounded up as
// WebKit rounds it; usage stays the engine's. Any other quota (a WebKit that already treats the
// app as a browser) is left alone.
function patchStorageQuota(w, quota) {
  const Manager = w.StorageManager;
  const estimate = Manager && Manager.prototype.estimate;
  if (typeof estimate !== 'function') return;
  const APP_QUOTA = 1048576000;
  define(Manager.prototype, 'estimate', method('estimate', 0, function () {
    return estimate.apply(this, arguments).then((result) => {
      if (result && typeof result.quota === 'number' && result.quota <= APP_QUOTA) {
        result.quota = Math.ceil(result.quota * (quota / APP_QUOTA));
      }
      return result;
    });
  }));
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
// As WebKit answers a page whose user said no (deny) or allowed this position (fixed): an error or a
// position after the request, and permissions.query reporting 'prompt' until the page has asked
// (WebKit's Geolocation::hasBeenRequested), then 'denied' / 'granted'. Every object handed out is
// an instance of the real interface with no own properties; its values come from the prototype
// getters (and toJSON), which answer the engine's own way for every other receiver. The
// PermissionStatus is the engine's own, only its state is answered here.
function patchGeolocation(w, geo) {
  const nav = w.navigator;
  if (!nav || !nav.geolocation) return;
  const GeoProto = Object.getPrototypeOf(nav.geolocation);
  const fixed = geo.mode === 'fixed';
  // Fake instances are bare Object.create(prototype) objects (no own properties). Their values live
  // here and are served by prototype getters; a real instance falls through to the native getter.
  const data = new WeakMap();
  let requested = false; // WebKit: Geolocation::hasBeenRequested() -> permissions.query reports 'prompt' until then
  const statuses = [];   // WeakRefs of PermissionStatus objects we handed out

  function serve(proto, names, extra) {
    if (!proto) return;
    for (const key of names) {
      const native = Object.getOwnPropertyDescriptor(proto, key);
      if (!native || !native.get) continue;
      const get = getter(key, function () {
        const d = data.get(this);
        return d !== undefined ? d[key] : native.get.call(this); // wrong receiver: the engine's own TypeError
      });
      Object.defineProperty(proto, key, { get: get, set: native.set, enumerable: native.enumerable, configurable: native.configurable });
    }
    if (extra) extra(proto);
  }
  function serveToJSON(proto, build) {
    if (!proto) return;
    const native = Object.getOwnPropertyDescriptor(proto, 'toJSON');
    if (!native || typeof native.value !== 'function') return;
    define(proto, 'toJSON', method('toJSON', 0, function () {
      const d = data.get(this);
      return d !== undefined ? build(d) : native.value.call(this);
    }));
  }
  const fake = (Ctor, values) => {
    const o = Object.create(Ctor ? Ctor.prototype : Object.prototype);
    data.set(o, values);
    return o;
  };
  const CoordsProto = w.GeolocationCoordinates && w.GeolocationCoordinates.prototype;
  const PosProto = w.GeolocationPosition && w.GeolocationPosition.prototype;
  const ErrProto = w.GeolocationPositionError && w.GeolocationPositionError.prototype;
  const StatusProto = w.PermissionStatus && w.PermissionStatus.prototype;
  const COORD_KEYS = ['latitude', 'longitude', 'altitude', 'accuracy', 'altitudeAccuracy', 'heading', 'speed'];
  const coordsJSON = (d) => {
    const out = {};
    for (const k of COORD_KEYS) out[k] = d[k];
    if (CoordsProto && Object.getOwnPropertyDescriptor(CoordsProto, 'floorLevel')) out.floorLevel = null;
    return out;
  };
  serve(CoordsProto, COORD_KEYS.concat('floorLevel'));
  serveToJSON(CoordsProto, coordsJSON);
  serve(PosProto, ['coords', 'timestamp']);
  serveToJSON(PosProto, (d) => ({ coords: d.coords, timestamp: d.timestamp }));
  serve(ErrProto, ['code', 'message']);

  function position() {
    const coords = fake(w.GeolocationCoordinates, { latitude: geo.latitude, longitude: geo.longitude, accuracy: geo.accuracy,
      altitude: null, altitudeAccuracy: null, heading: null, speed: null, floorLevel: null });
    return fake(w.GeolocationPosition, { coords: coords, timestamp: w.Date.now() });
  }
  const denied = () => fake(w.GeolocationPositionError, { code: 1, message: 'User denied Geolocation' });

  function currentState() { return !requested ? 'prompt' : (fixed ? 'granted' : 'denied'); }
  function markRequested() {
    if (requested) return;
    requested = true;
    w.setTimeout(() => {
      for (const ref of statuses) {
        const s = ref.deref();
        if (s) { try { s.dispatchEvent(new w.Event('change')); } catch (e) {} }
      }
    }, 0);
  }
  if (StatusProto) {
    const states = new WeakSet();
    const native = Object.getOwnPropertyDescriptor(StatusProto, 'state');
    if (native && native.get) {
      statuses.states = states;
      Object.defineProperty(StatusProto, 'state', {
        get: getter('state', function () {
          const v = native.get.call(this); // receiver check
          return states.has(this) ? currentState() : v;
        }), set: native.set, enumerable: native.enumerable, configurable: native.configurable });
      statuses.track = (s) => { states.add(s); statuses.push(new w.WeakRef(s)); };
    }
  }

  function respond(success, error) {
    markRequested();
    w.setTimeout(() => {
      if (fixed) success(position());
      else if (typeof error === 'function') error(denied());
    }, 0);
  }
  const check = (receiver, name, args) => {
    if (w.Geolocation && !(receiver instanceof w.Geolocation)) throw new w.TypeError('Can only call Geolocation.' + name + ' on instances of Geolocation');
    if (args.length < 1) throw new w.TypeError('Not enough arguments');
    if (typeof args[0] !== 'function') throw new w.TypeError("Argument 1 ('successCallback') to Geolocation." + name + ' must be a function');
    if (args[1] != null && typeof args[1] !== 'function') throw new w.TypeError("Argument 2 ('errorCallback') to Geolocation." + name + ' must be a function');
  };
  let nextWatch = 1;
  define(GeoProto, 'getCurrentPosition', method('getCurrentPosition', 1, function (success, error) {
    check(this, 'getCurrentPosition', arguments);
    respond(success, error);
  }));
  define(GeoProto, 'watchPosition', method('watchPosition', 1, function (success, error) {
    check(this, 'watchPosition', arguments);
    respond(success, error);
    return nextWatch++;
  }));
  define(GeoProto, 'clearWatch', method('clearWatch', 1, function (id) {
    if (w.Geolocation && !(this instanceof w.Geolocation)) throw new w.TypeError('Can only call Geolocation.clearWatch on instances of Geolocation');
    if (arguments.length < 1) throw new w.TypeError('Not enough arguments');
  }));

  if (nav.permissions && nav.permissions.query && statuses.track) {
    const PermProto = Object.getPrototypeOf(nav.permissions);
    const originalQuery = PermProto.query;
    define(PermProto, 'query', method('query', 1, function (descriptor) {
      const result = originalQuery.apply(this, arguments); // real PermissionStatus, real errors
      let isGeo = false;
      try { isGeo = descriptor != null && String(descriptor.name) === 'geolocation'; } catch (e) {}
      if (!isGeo) return result;
      return result.then((s) => { statuses.track(s); return s; });
    }));
  }
}

// ---- WebRTC -----------------------------------------------------------------------------------
// With relay-only routing the engine's WebRTC is on, and this script alone keeps a page on the
// relay. Whatever runs when the page calls a peer connection API uses only built-ins captured
// here, before any page script ran, and gives the engine null-prototype objects with own data
// properties: replacing Reflect, Function.prototype.call/apply, Object.assign, Array.prototype
// methods or iterators, or putting accessors on Object.prototype, changes nothing the engine
// reads. The native constructor and methods never reach a function the page can replace.
const ReflectApply = Reflect.apply;
const ReflectConstruct = Reflect.construct;
const ObjectCreate = Object.create;
const ObjectDefineProperty = Object.defineProperty;
const ObjectGetOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
const SymbolIterator = Symbol.iterator;
const WeakMapGet = WeakMap.prototype.get;
const WeakMapSet = WeakMap.prototype.set;
const PromiseThen = Promise.prototype.then;
const RegExpExec = RegExp.prototype.exec;
const StringSlice = String.prototype.slice;
const StringToLowerCase = String.prototype.toLowerCase;
const StringLastIndexOf = String.prototype.lastIndexOf;
const StringIndexOf = String.prototype.indexOf;
const call = (fn, self, ...args) => ReflectApply(fn, self, args);

// An iterable the engine converts as a WebIDL sequence, iterated by closures of this script.
function sequenceOf(items) {
  const list = ObjectCreate(null);
  ObjectDefineProperty(list, SymbolIterator, { value: function () {
    let index = 0;
    const iterator = ObjectCreate(null);
    iterator.next = function () {
      const result = ObjectCreate(null);
      result.done = index >= items.length;
      result.value = result.done ? undefined : items[index++];
      return result;
    };
    return iterator;
  } });
  return list;
}

// RTCConfiguration members, in the order WebIDL reads them (lexicographic).
const RTC_MEMBERS = ['bundlePolicy', 'certificates', 'iceCandidatePoolSize', 'iceServers', 'iceTransportPolicy',
                     'rtcpMuxPolicy', 'targetLatency'];

function patchWebRTC(w, policy, relay) {
  if (policy === 'unrestricted') return;
  const names = ['RTCPeerConnection', 'webkitRTCPeerConnection'];
  if (policy === 'disabled') {
    // The engine has WebRTC switched off already (BrowserSession); where it could not be, every
    // RTC interface is removed, as in an engine built without WebRTC: no property remains.
    for (const name of Object.getOwnPropertyNames(w).filter((n) => /^(webkit)?RTC[A-Z]/.test(n))) {
      try { delete w[name]; } catch (e) {}
      if (Object.prototype.hasOwnProperty.call(w, name)) {
        try { Object.defineProperty(w, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
      }
    }
    return;
  }
  const Native = w.RTCPeerConnection;
  if (!Native) return;
  const nativeProto = Native.prototype;
  const nativeGetConfiguration = nativeProto.getConfiguration;
  const nativeSetConfiguration = nativeProto.setConfiguration;
  const nativeClose = nativeProto.close;
  // 'tunnel': the packet tunnel's TURN relay is the only ICE server, so every candidate is a
  // relay through the profile's proxy. The page keeps seeing its own configuration.
  const viaTunnel = policy === 'tunnel' && relay ? relay : null;
  const relayServers = [];
  if (viaTunnel) {
    for (let i = 0; i < viaTunnel.urls.length; i++) {
      relayServers[i] = { urls: String(viaTunnel.urls[i]), username: String(viaTunnel.username), credential: String(viaTunnel.credential) };
    }
  }
  const relayList = () => {
    const servers = [];
    for (let i = 0; i < relayServers.length; i++) {
      const server = ObjectCreate(null);
      server.urls = relayServers[i].urls;
      server.username = relayServers[i].username;
      server.credential = relayServers[i].credential;
      servers[i] = server;
    }
    return sequenceOf(servers);
  };
  // The page's configuration, each member read once, in the engine's order.
  const read = (config) => {
    const record = ObjectCreate(null);
    if (config === undefined || config === null) return record;
    for (let i = 0; i < RTC_MEMBERS.length; i++) {
      const value = config[RTC_MEMBERS[i]];
      if (value !== undefined) record[RTC_MEMBERS[i]] = value;
    }
    return record;
  };
  const isObject = (value) => value !== null && (typeof value === 'object' || typeof value === 'function');
  // What the engine gets: relay-only; in the tunnel the relay as the only ICE server. Of the
  // page's members only those that do not choose where packets go.
  const engineConfig = (record) => {
    const next = ObjectCreate(null);
    for (let i = 0; i < RTC_MEMBERS.length; i++) {
      const key = RTC_MEMBERS[i];
      if (key !== 'iceServers' && key !== 'iceTransportPolicy' && record[key] !== undefined) next[key] = record[key];
    }
    if (viaTunnel) next.iceServers = relayList();
    else if (record.iceServers !== undefined) next.iceServers = record.iceServers;
    next.iceTransportPolicy = 'relay';
    return next;
  };
  // The page's own servers and policy as the engine would hold them: a closed peer connection
  // made from them validates them (the engine's own errors for a bad one) and reports them. It
  // gets no candidate pool, so it gathers nothing, and nothing the page could not already name.
  const pageView = new WeakMap();
  const snapshot = (config) => {
    let shadowConfig = config;
    if (config === undefined || config === null || isObject(config)) {
      const record = read(config);
      shadowConfig = ObjectCreate(null);
      for (let i = 0; i < RTC_MEMBERS.length; i++) {
        const key = RTC_MEMBERS[i];
        if (key !== 'iceCandidatePoolSize' && record[key] !== undefined) shadowConfig[key] = record[key];
      }
      const shadow = ReflectConstruct(Native, [shadowConfig]);
      const view = call(nativeGetConfiguration, shadow);
      call(nativeClose, shadow);
      return { record, view: { iceServers: view.iceServers, iceTransportPolicy: view.iceTransportPolicy } };
    }
    // Not a dictionary: the engine throws its TypeError.
    const shadow = ReflectConstruct(Native, [shadowConfig]);
    call(nativeClose, shadow);
    return { record: read(undefined), view: null };
  };
  // The latest connection's view, for stats asked of a sender or receiver (they do not say
  // which connection they belong to; a page's connections normally share one configuration).
  let latestView = null;
  const rtcTarget = function (config) {
    let record, view = null;
    if (viaTunnel) {
      const checked = snapshot(config);
      record = checked.record;
      view = checked.view;
    } else {
      record = isObject(config) || config === undefined || config === null ? read(config) : null;
    }
    const target = new.target === undefined ? rtcTarget : new.target;
    // A non-dictionary argument goes to the engine as given, which throws its TypeError.
    const pc = ReflectConstruct(Native, [record ? engineConfig(record) : config], target);
    if (view) { call(WeakMapSet, pageView, pc, view); latestView = view; }
    return pc;
  };
  rtcTarget.prototype = nativeProto; // instanceof goes through the bound target
  const statics = Native.generateCertificate ? { generateCertificate: Native.generateCertificate } : {};
  const RTCPeerConnection = constructor('RTCPeerConnection', 0, rtcTarget, statics, nativeProto, Native);
  if (nativeSetConfiguration) {
    define(nativeProto, 'setConfiguration', method('setConfiguration', 0, function (config) {
      const checked = viaTunnel && call(WeakMapGet, pageView, this) ? snapshot(config) : null;
      const record = checked ? checked.record : (isObject(config) || config === undefined || config === null ? read(config) : null);
      const result = call(nativeSetConfiguration, this, record ? engineConfig(record) : config);
      if (checked && checked.view) { call(WeakMapSet, pageView, this, checked.view); latestView = checked.view; }
      return result;
    }));
  }
  if (viaTunnel && nativeGetConfiguration) {
    const copyServers = (servers) => {
      const copies = [];
      for (let i = 0; i < servers.length; i++) {
        const copy = {};
        const keys = Object.keys(servers[i]);
        for (let k = 0; k < keys.length; k++) {
          const value = servers[i][keys[k]];
          copy[keys[k]] = Array.isArray(value) ? value.slice() : value;
        }
        copies[i] = copy;
      }
      return copies;
    };
    define(nativeProto, 'getConfiguration', method('getConfiguration', 0, function () {
      const result = call(nativeGetConfiguration, this); // the engine's receiver check
      const view = call(WeakMapGet, pageView, this);
      if (view) {
        ObjectDefineProperty(result, 'iceServers', { value: copyServers(view.iceServers), writable: true, enumerable: true, configurable: true });
        ObjectDefineProperty(result, 'iceTransportPolicy', { value: view.iceTransportPolicy, writable: true, enumerable: true, configurable: true });
      }
      return result;
    }));
  }
  // Where libwebrtc names the server a candidate came from — an ICE event's url, a candidate's
  // url in getStats() — it names the relay ('turn:192.0.2.10:3478?transport=udp'). The page is
  // shown its own server instead, in libwebrtc's form, or nothing when it configured none.
  if (viaTunnel) {
    const relayHosts = [];
    for (let i = 0; i < relayServers.length; i++) {
      const parts = iceURLParts(relayServers[i].urls);
      if (parts) relayHosts[relayHosts.length] = parts.host;
    }
    const isRelayURL = (url) => {
      const parts = typeof url === 'string' ? iceURLParts(url) : null;
      if (!parts) return false;
      for (let i = 0; i < relayHosts.length; i++) if (relayHosts[i] === parts.host) return true;
      return false;
    };
    const pageURL = (view, turn) => {
      const urls = [];
      const servers = (view && view.iceServers) || [];
      for (let i = 0; i < servers.length; i++) {
        const value = servers[i].urls;
        if (typeof value === 'string') urls[urls.length] = value;
        else for (let k = 0; k < value.length; k++) urls[urls.length] = value[k];
      }
      // A relay candidate came from a TURN server; a Binding answer from a STUN server, or from a
      // TURN server over UDP, which libwebrtc asks as a STUN server too.
      const ordered = [];
      for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < urls.length; i++) {
          const parts = iceURLParts(urls[i]);
          if (!parts || !parts.host) continue;
          const isTurn = parts.scheme === 'turn' || parts.scheme === 'turns';
          if (turn ? isTurn && pass === 0 : (pass === 0 ? !isTurn : parts.scheme === 'turn')) ordered[ordered.length] = parts;
        }
      }
      if (ordered.length === 0) return null;
      const parts = ordered[0];
      const secure = parts.scheme === 'stuns' || parts.scheme === 'turns';
      const port = parts.port || (secure ? '5349' : '3478');
      if (!turn) return 'stun:' + parts.host + ':' + port;
      const host = call(StringIndexOf, parts.host, ':') >= 0 ? '[' + parts.host + ']' : parts.host;
      return parts.scheme + ':' + host + ':' + port + '?transport=' + (parts.transport || (secure ? 'tcp' : 'udp'));
    };
    const maskURL = (url, view) => {
      const parts = iceURLParts(url);
      return pageURL(view, parts.scheme === 'turn' || parts.scheme === 'turns');
    };

    const IceEvent = w.RTCPeerConnectionIceEvent;
    const urlAccessor = IceEvent && ObjectGetOwnPropertyDescriptor(IceEvent.prototype, 'url');
    const targetAccessor = w.Event && ObjectGetOwnPropertyDescriptor(w.Event.prototype, 'target');
    if (urlAccessor && urlAccessor.get) {
      const nativeURL = urlAccessor.get;
      const nativeTarget = targetAccessor && targetAccessor.get;
      ObjectDefineProperty(IceEvent.prototype, 'url', {
        configurable: true, enumerable: urlAccessor.enumerable, set: urlAccessor.set,
        get: getter('url', function () {
          const value = call(nativeURL, this);
          if (!isRelayURL(value)) return value;
          const target = nativeTarget ? call(nativeTarget, this) : this.target;
          return maskURL(value, isObject(target) ? call(WeakMapGet, pageView, target) : undefined);
        })
      });
    }
    // Stats entries are the report's own objects: masked in place, a later get() reads the same.
    const Report = w.RTCStatsReport;
    const reportForEach = Report && Report.prototype.forEach;
    const sanitize = (report, view) => {
      try {
        call(reportForEach, report, (entry) => {
          if (!isObject(entry) || !isRelayURL(entry.url)) return;
          const url = maskURL(entry.url, view);
          if (url === null) delete entry.url; else entry.url = url;
        });
      } catch (e) {}
      return report;
    };
    const statsOwners = [nativeProto, w.RTCRtpSender && w.RTCRtpSender.prototype, w.RTCRtpReceiver && w.RTCRtpReceiver.prototype];
    for (const proto of statsOwners) {
      const nativeGetStats = proto && proto.getStats;
      if (typeof nativeGetStats !== 'function' || typeof reportForEach !== 'function') continue;
      define(proto, 'getStats', method('getStats', 0, function () {
        const view = call(WeakMapGet, pageView, this) || latestView;
        const result = ReflectApply(nativeGetStats, this, arguments); // the engine's receiver check and errors
        try { return call(PromiseThen, result, (report) => sanitize(report, view)); } catch (e) { return result; }
      }));
    }
  }
  define(nativeProto, 'constructor', RTCPeerConnection);
  // Only the names this engine has (Safari 26 has no webkitRTCPeerConnection any more).
  for (const name of names) {
    if (!Object.prototype.hasOwnProperty.call(w, name)) continue;
    try { Object.defineProperty(w, name, { value: RTCPeerConnection, writable: true, enumerable: false, configurable: true }); } catch (e) {}
  }
}

// 'turn:host:port?transport=udp', 'stun:[v6]:port', or libwebrtc's 'stun:v6:port' (its STUN urls
// carry IPv6 without brackets) → scheme, host (lowercase, no brackets), port, transport.
function iceURLParts(url) {
  if (typeof url !== 'string') return null;
  const match = call(RegExpExec, /^(stuns?|turns?):([^?]*)(?:\?(.*))?$/i, url);
  if (!match) return null;
  const rest = match[2];
  let host = rest, port = '';
  const bracketed = call(RegExpExec, /^\[([^\]]*)\](?::(\d*))?$/, rest);
  if (bracketed) {
    host = bracketed[1];
    port = bracketed[2] || '';
  } else {
    const colon = call(StringLastIndexOf, rest, ':');
    if (colon >= 0 && call(RegExpExec, /^\d+$/, call(StringSlice, rest, colon + 1))) {
      host = call(StringSlice, rest, 0, colon);
      port = call(StringSlice, rest, colon + 1);
    }
  }
  const transport = call(RegExpExec, /(?:^|&)transport=([^&]*)/i, match[3] || '');
  return { scheme: call(StringToLowerCase, match[1]), host: call(StringToLowerCase, host), port,
           transport: transport ? call(StringToLowerCase, transport[1]) : '' };
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

// ---- Workers ----------------------------------------------------------------------------------
// A user script never runs in a worker, so a worker's Date/Intl would show the Mac's own zone (and
// its navigator the Mac's values) next to the page's. Workers made from a blob this realm created —
// how fingerprinting scripts make theirs — start with this script: the engine gets a blob of [the
// page's directives, this script, the rest of the page's blob], so the worker keeps a blob:
// location, its own relative URLs, its CSP and its strict mode. The script goes in as code on one
// line, so the page's code keeps its line numbers, and never through eval: a CSP without
// 'unsafe-eval', or one requiring Trusted Types, would block that and report it to the site. Where
// the directives end comes from the strings the page made its Blob of, not from reading the blob
// back, which connect-src would block and report. Left alone: workers loaded from a URL (rewriting
// them would change their location and how their relative URLs resolve), service workers (out of
// reach), a TrustedScriptURL (only a policy of the page's can make one; a string in its place would
// be a violation) and any URL while the page has a default Trusted Types policy (which would be
// shown another URL than the page's). What runs when the page calls these uses only built-ins
// captured here, before any page script ran.
const FunctionCall = Function.prototype.call;
const charCodeAt = FunctionCall.bind(String.prototype.charCodeAt);
const ObjectGetPrototypeOf = Object.getPrototypeOf;
const NativeMap = Map;
const MapGet = Map.prototype.get;
const MapSet = Map.prototype.set;
const MapHas = Map.prototype.has;
const MapDelete = Map.prototype.delete;
const NativeWeakMap = WeakMap;
// This realm's configuration as a worker's copy of the script receives it (JSON, which can hold
// U+2028/U+2029; written as escapes, they cannot count as line breaks).
const CONFIG_JSON = JSON.stringify(CONFIG).replace(/[\u2028\u2029]/g, (c) => (c === '\u2028' ? '\\u2028' : '\\u2029'));

// This script as one line of code: comments dropped, each run of white space, line breaks and
// comments one space — a semicolon where a line break ends a return, break, continue, throw or
// yield or comes before ++ or --, as the engine reads those — and a line break in a template
// literal written \n. Null for anything else this script does not contain; no worker is rewritten
// then. The shim tests run the result under V8 and JavaScriptCore.
const WORD = /[A-Za-z_$][\w$]*/y;
const NUMBER = /(?:0[xXbBoO][\da-fA-F_]+|(?:\d[\d_]*\.?[\d_]*|\.\d[\d_]*)(?:[eE][+-]?\d[\d_]*)?)n?/y;
const QUOTED = /'(?:[^'\\\n\r\u2028\u2029]|\\[^\n\r\u2028\u2029])*'|"(?:[^"\\\n\r\u2028\u2029]|\\[^\n\r\u2028\u2029])*"/y;
const REGEX_LITERAL = /\/(?:[^/\\[\n\r\u2028\u2029]|\\[^\n\r\u2028\u2029]|\[(?:[^\]\\\n\r\u2028\u2029]|\\[^\n\r\u2028\u2029])*\])+\/[A-Za-z]*/y;
const TEMPLATE_TEXT = /(?:[^`\\$\n\r\u2028\u2029]|\\[^\n\r\u2028\u2029]|\$(?!\{))*/y;
// Words after which a / starts a regular expression; after any other word or value it divides.
const BEFORE_EXPRESSION = { __proto__: null, return: 1, typeof: 1, instanceof: 1, in: 1, of: 1, new: 1, delete: 1,
                            void: 1, throw: 1, case: 1, do: 1, else: 1, yield: 1, await: 1 };
// Words no line break may follow: one ends the statement.
const ENDED_BY_LINE_BREAK = { __proto__: null, return: 1, break: 1, continue: 1, throw: 1, yield: 1 };
let oneLineSource; // undefined until a worker needs it; null if this script could not be put on one line

function oneLine(source) {
  const n = source.length;
  const isBreak = (c) => c === 10 || c === 13 || c === 0x2028 || c === 0x2029;
  const scan = (re) => {
    re.lastIndex = i;
    const match = call(RegExpExec, re, source);
    return match === null ? null : match[0];
  };
  // A template literal's text from i: true at its end, false at a ${ (resumed by its }).
  const template = () => {
    for (;;) {
      const text = scan(TEMPLATE_TEXT);
      out += text;
      i += text.length;
      const c = charCodeAt(source, i);
      if (c === 96) { out += '`'; i++; return true; }
      if (c === 36) { out += '${'; i += 2; resume[open++] = depth; return false; }
      if (c !== 10) return null; // \r, U+2028/U+2029, a line continuation, or no end
      out += '\\n';
      i++;
    }
  };
  let out = '', i = 0, depth = 0, open = 0;
  const resume = ObjectCreate(null); // the brace depth of each open template literal's ${
  let space = false, lineBreak = false;
  let last = '', property = false, value = false; // the last token, whether it was a .name, whether it ends a value
  while (i < n) {
    const c = charCodeAt(source, i);
    const d = charCodeAt(source, i + 1);
    if (isBreak(c)) { space = lineBreak = true; i++; continue; }
    if (c === 32 || c === 9 || c === 11 || c === 12 || c === 0xA0 || c === 0xFEFF) { space = true; i++; continue; }
    if (c === 47 && d === 47) {
      while (i < n && !isBreak(charCodeAt(source, i))) i++;
      space = true;
      continue;
    }
    if (c === 47 && d === 42) {
      const end = call(StringIndexOf, source, '*/', i + 2);
      if (end < 0) return null;
      for (let k = i + 2; k < end; k++) if (isBreak(charCodeAt(source, k))) lineBreak = true;
      i = end + 2;
      space = true;
      continue;
    }
    // HTML-like comments (<!--, and --> at a line's start) end where a line does: never joined.
    if ((c === 60 && call(StringSlice, source, i, i + 4) === '<!--') || (c === 45 && d === 45 && charCodeAt(source, i + 2) === 62)) return null;
    if (space && out !== '') {
      const ended = (ENDED_BY_LINE_BREAK[last] === 1 && !property) || ((c === 43 || c === 45) && d === c && value);
      out += lineBreak && ended ? ';' : ' ';
    }
    space = lineBreak = false;
    if ((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95 || c === 36) {
      const word = scan(WORD);
      property = last === '.';
      value = property || BEFORE_EXPRESSION[word] !== 1;
      last = word;
      out += word;
      i += word.length;
      continue;
    }
    property = false;
    if ((c >= 48 && c <= 57) || (c === 46 && d >= 48 && d <= 57)) {
      const number = scan(NUMBER);
      out += number;
      i += number.length;
      last = '';
      value = true;
      continue;
    }
    if (c === 39 || c === 34) {
      const string = scan(QUOTED);
      if (string === null) return null;
      out += string;
      i += string.length;
      last = '';
      value = true;
      continue;
    }
    if (c === 96 || (c === 125 && open > 0 && resume[open - 1] === depth)) {
      if (c === 125) open--;
      out += c === 96 ? '`' : '}';
      i++;
      const ended = template();
      if (ended === null) return null;
      last = '';
      value = ended;
      continue;
    }
    if (c === 47) {
      if (!value) {
        if (last === '}') return null; // a block's end or an object literal's: not known here
        const regex = scan(REGEX_LITERAL);
        if (regex === null) return null;
        out += regex;
        i += regex.length;
        last = '';
        value = true;
        continue;
      }
    } else if (c === 43 || c === 45) {
      if (d === c) { out += c === 43 ? '++' : '--'; i += 2; last = ''; continue; } // a value stays one
    } else if (c === 123) {
      depth++;
    } else if (c === 125) {
      depth--;
    } else if (c > 126 || c < 33 || c === 35 || c === 64 || c === 92) {
      return null; // non-ASCII, private names, decorators, escapes
    }
    out += call(StringSlice, source, i, i + 1);
    i++;
    last = call(StringSlice, out, out.length - 1);
    value = c === 41 || c === 93; // ) ]
  }
  return depth === 0 && open === 0 ? out : null;
}

// Where this script goes in a blob made of `parts` (what the page gave new Blob): after the
// directives at its start and the comments before them, given as their UTF-8 length — when a line
// break ends them, on their line, so the next line keeps its columns too — and after a semicolon
// unless they end with one (a directive the text ends with would otherwise be called). Null when
// the strings at the start do not show where the directives end.
const PROLOGUE = /^(?:(?:\s|\/\*[\s\S]*?\*\/|\/\/[^\n]*(?:\n|$))*(?:'[^'\\\n]*'|"[^"\\\n]*")[ \t]*(?:;|\r?\n|$))*/;
// What surely follows the directives: past white space and comments, a character no directive or
// comment starts with.
const AFTER_PROLOGUE = /^(?:\s|\/\*[\s\S]*?\*\/|\/\/[^\n]*\n)*[^\s'"/]/;
const LINE_END = /\r?\n$/;
const ENDS_STATEMENT = /;\s*$/;
const HEAD_LIMIT = 65536;

function prologueOf(parts) {
  let head = '', whole = true;
  for (let k = 0; k < parts.length; k++) {
    const part = parts[k];
    if (typeof part !== 'string') { whole = false; break; }
    if (head.length + part.length > HEAD_LIMIT) {
      head += call(StringSlice, part, 0, HEAD_LIMIT - head.length);
      whole = false;
      break;
    }
    head += part;
  }
  let prologue = call(RegExpExec, PROLOGUE, head)[0];
  if (!whole && call(RegExpExec, AFTER_PROLOGUE, call(StringSlice, head, prologue.length)) === null) return null;
  const lineEnd = call(RegExpExec, LINE_END, prologue);
  if (lineEnd !== null) prologue = call(StringSlice, prologue, 0, lineEnd.index);
  const where = ObjectCreate(null);
  where.bytes = utf8Length(prologue);
  where.semicolon = where.bytes > 0 && call(RegExpExec, ENDS_STATEMENT, prologue) === null;
  return where;
}

// The length of `text` in UTF-8, as the engine encodes a Blob's strings (a lone surrogate as U+FFFD).
function utf8Length(text) {
  let bytes = 0;
  for (let k = 0; k < text.length; k++) {
    const c = charCodeAt(text, k);
    if (c < 0x80) bytes += 1;
    else if (c < 0x800) bytes += 2;
    else if (c >= 0xD800 && c <= 0xDBFF && (charCodeAt(text, k + 1) & 0xFC00) === 0xDC00) { bytes += 4; k++; }
    else bytes += 3;
  }
  return bytes;
}

// The page's iterable as the engine iterates a WebIDL sequence — its @@iterator called once, `next`
// read once, `done` and then `value` read from each result, `return` on an error — with each value
// also kept in `parts` (a null-prototype list).
function forwarding(iterable, iterate, parts) {
  const sequence = ObjectCreate(null);
  ObjectDefineProperty(sequence, SymbolIterator, { value: function () {
    const iterator = ReflectApply(iterate, iterable, []);
    if (iterator === null || (typeof iterator !== 'object' && typeof iterator !== 'function')) return iterator;
    const next = iterator.next;
    const forward = ObjectCreate(null);
    if (typeof next !== 'function') { forward.next = next; return forward; } // the engine's TypeError
    forward.next = function () {
      const result = ReflectApply(next, iterator, []);
      if (result === null || (typeof result !== 'object' && typeof result !== 'function')) return result;
      const step = ObjectCreate(null);
      step.done = !!result.done;
      if (!step.done) parts[parts.length++] = step.value = result.value;
      return step;
    };
    forward.return = function () {
      const close = iterator.return;
      return close === undefined || close === null ? undefined : ReflectApply(close, iterator, []);
    };
    return forward;
  } });
  return sequence;
}

function hookWorkers(w) {
  const URLClass = w.URL;
  const NativeBlob = w.Blob;
  const nativeCreate = URLClass && URLClass.createObjectURL;
  const nativeRevoke = URLClass && URLClass.revokeObjectURL;
  if (!SOURCE || typeof nativeCreate !== 'function' || typeof nativeRevoke !== 'function' || typeof NativeBlob !== 'function') return;
  const blobProto = NativeBlob.prototype;
  const blobSize = (ObjectGetOwnPropertyDescriptor(blobProto, 'size') || {}).get;
  const blobType = (ObjectGetOwnPropertyDescriptor(blobProto, 'type') || {}).get;
  const blobSlice = blobProto.slice;
  if (typeof blobSize !== 'function' || typeof blobType !== 'function' || typeof blobSlice !== 'function') return;
  const trustedTypes = w.trustedTypes;
  const factory = trustedTypes ? ObjectGetPrototypeOf(trustedTypes) : null;
  const isScriptURL = factory && factory.isScriptURL;
  const defaultPolicy = factory && (ObjectGetOwnPropertyDescriptor(factory, 'defaultPolicy') || {}).get;
  const prologues = new NativeWeakMap(); // a Blob the page made from parts → where this script goes in it
  const blobs = new NativeMap();         // a blob: URL this realm made → its Blob, until revoked
  const replacements = new NativeMap();  // that URL → the URL of a blob with this script in front

  const blobTarget = function (...args) {
    if (new.target === undefined) return ReflectApply(NativeBlob, this, args); // the engine's own TypeError
    let parts = null;
    const value = args[0];
    if (args.length > 0 && value !== null && (typeof value === 'object' || typeof value === 'function')) {
      const iterate = value[SymbolIterator]; // read once, as the engine reads it
      if (typeof iterate === 'function') {
        parts = ObjectCreate(null);
        parts.length = 0;
        args[0] = forwarding(value, iterate, parts);
      } else {
        args[0] = ObjectCreate(null); // the engine's own TypeError, without reading the page's again
      }
    }
    const blob = ReflectConstruct(NativeBlob, args, new.target);
    if (parts !== null) {
      try {
        const where = prologueOf(parts);
        if (where !== null) call(WeakMapSet, prologues, blob, where);
      } catch (e) {}
    }
    return blob;
  };
  blobTarget.prototype = blobProto; // what `new` constructs with (new.target is the target)
  const WrappedBlob = constructor('Blob', NativeBlob.length, blobTarget, {}, blobProto, NativeBlob);
  define(blobProto, 'constructor', WrappedBlob);
  define(w, 'Blob', WrappedBlob);
  // File inherits from Blob: its [[Prototype]] is the interface object a page sees.
  if (typeof w.File === 'function' && ObjectGetPrototypeOf(w.File) === NativeBlob) Object.setPrototypeOf(w.File, WrappedBlob);

  define(URLClass, 'createObjectURL', method('createObjectURL', 1, function (object) {
    const url = ReflectApply(nativeCreate, this, arguments);
    try {
      call(blobSize, object); // a Blob (or File), not a MediaSource
      call(MapSet, blobs, url, object);
    } catch (e) {}
    return url;
  }));
  define(URLClass, 'revokeObjectURL', method('revokeObjectURL', 1, function (url) {
    if (arguments.length === 0) return ReflectApply(nativeRevoke, this, arguments); // the engine's own TypeError
    const key = `${url}`; // converted once, as the engine converts it
    const result = ReflectApply(nativeRevoke, this, [key]);
    // The blob behind this script goes with it; its URL stays the one for `key`, so a worker made
    // from `key` now fails as the engine's would (a running shared worker is still found by it).
    try {
      call(MapDelete, blobs, key);
      if (call(MapHas, replacements, key)) call(nativeRevoke, URLClass, call(MapGet, replacements, key));
    } catch (e) {}
    return result;
  }));

  // The same replacement for the same URL: a SharedWorker is found again by its URL.
  function replacementFor(key) {
    if (call(MapHas, replacements, key)) return call(MapGet, replacements, key);
    const blob = call(MapGet, blobs, key);
    if (blob === undefined) return null;
    if (oneLineSource === undefined) oneLineSource = oneLine(SOURCE);
    if (oneLineSource === null) return null;
    const bootstrap = '(' + oneLineSource + ')(' + CONFIG_JSON + ');';
    // A blob not made from strings (fetched, a File) gets this script first.
    const where = call(WeakMapGet, prologues, blob);
    const items = where === undefined || where.bytes === 0 ? [bootstrap, blob]
      : [call(blobSlice, blob, 0, where.bytes), where.semicolon ? ';' : '', bootstrap, call(blobSlice, blob, where.bytes)];
    const options = ObjectCreate(null);
    options.type = call(blobType, blob) || 'text/javascript';
    const replacement = call(nativeCreate, URLClass, new NativeBlob(sequenceOf(items), options));
    call(MapSet, replacements, key, replacement);
    return replacement;
  }
  for (const name of ['Worker', 'SharedWorker']) {
    const Native = w[name];
    if (typeof Native !== 'function') continue;
    const workerTarget = function (...args) {
      if (new.target === undefined) return ReflectApply(Native, this, args); // the engine's own TypeError
      if (args.length > 0 && !(typeof isScriptURL === 'function' && call(isScriptURL, trustedTypes, args[0]))) {
        const key = `${args[0]}`; // converted once, as the engine converts it
        args[0] = key;
        try {
          if (!(typeof defaultPolicy === 'function' && call(defaultPolicy, trustedTypes) !== null)) {
            const replacement = replacementFor(key);
            if (replacement !== null) args[0] = replacement;
          }
        } catch (e) {} // the page's own URL, then
      }
      return ReflectConstruct(Native, args, new.target);
    };
    workerTarget.prototype = Native.prototype; // what `new` constructs with (new.target is the target)
    const Wrapped = constructor(name, Native.length, workerTarget, {}, Native.prototype, Native);
    define(Native.prototype, 'constructor', Wrapped);
    define(w, name, Wrapped);
  }
}

patchWindow(IS_WORKER ? self : window);
"""#
}
