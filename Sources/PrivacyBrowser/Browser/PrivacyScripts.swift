import BrowserCore
import Foundation
import WebKit

/// JavaScript shims for settings WebKit has no native per-web-view API for:
/// time zone, geolocation, and WebRTC.
///
/// PLATFORM LIMITATION — these are approximations, not engine-level enforcement:
///   * Injected as a `WKUserScript` at document start into every frame (`forMainFrameOnly: false`)
///     in the `.page` content world, i.e. they modify the objects the page sees.
///   * Not applied inside Web Workers, Shared Workers, or Service Workers: WebKit does not
///     inject user scripts there. Worker code sees the host time zone and has `Intl`/`Date`
///     unpatched (workers have no geolocation or RTCPeerConnection, so those are unaffected).
///   * A page can detect the patches (e.g. `Function.prototype.toString` on patched functions,
///     timing, or property descriptors). They reduce what passive scripts learn; they do not
///     hide the fact that a shim exists.
///   * Child browsing contexts that the page reaches via `contentWindow`/`contentDocument`
///     or `window.open` are patched synchronously on access. Access paths that bypass those
///     getters (e.g. `window.frames[0]`, `window[0]`) can reach an unpatched about:blank frame
///     before WebKit injects scripts into it.
///   * The HTTP `Accept-Language` header and `navigator.language` follow the system language;
///     WKWebView has no public per-view override.
enum PrivacyScripts {
    struct ShimConfiguration: Encodable {
        var timeZone: String?
        var geolocation: Geolocation
        var webRTC: String

        struct Geolocation: Encodable {
            var mode: String // "deny" | "fixed"
            var latitude: Double?
            var longitude: Double?
            var accuracy: Double?
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
        return ShimConfiguration(timeZone: configuration.timeZoneIdentifier, geolocation: geolocation,
                                 webRTC: configuration.webRTCPolicy.rawValue)
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
        // JSON is a subset of JS, so the encoded configuration is a safe literal: no string
        // concatenation of user-provided values into code.
        let json = (try? String(data: JSONEncoder().encode(shimConfiguration(for: configuration)), encoding: .utf8)) ?? "{}"
        return "(function (CONFIG) {\n" + shimBody + "\n})(" + json + ");"
    }

    // BEGIN SHIM (extracted by scripts/test-shims.sh for testing under Node)
    static let shimBody = #"""
'use strict';
const patched = new WeakSet();

function patchWindow(w) {
  if (!w || patched.has(w)) return;
  patched.add(w);
  if (CONFIG.timeZone) { try { patchTimeZone(w, CONFIG.timeZone); } catch (e) {} }
  try { patchGeolocation(w, CONFIG.geolocation || { mode: 'deny' }); } catch (e) {}
  try { patchWebRTC(w, CONFIG.webRTC || 'disabled'); } catch (e) {}
  try { hookChildWindows(w); } catch (e) {}
}

// ---------------------------------------------------------------- time zone
// Covers: Intl.DateTimeFormat default zone (and everything built on it), Date local-time
// getters, getTimezoneOffset, toString/toDateString/toTimeString, toLocale*String.
// Not covered: Date constructed from local components (new Date(y, m, d)), Date.parse of
// strings without an offset, and local setters (setHours, …) — these still use the host zone.
function patchTimeZone(w, TZ) {
  const NativeDate = w.Date;
  const proto = NativeDate.prototype;
  const NativeDTF = w.Intl.DateTimeFormat;
  const nativeGetTime = proto.getTime;

  const partsFormatter = new NativeDTF('en-US', {
    timeZone: TZ, hourCycle: 'h23', era: 'short',
    year: 'numeric', month: 'numeric', day: 'numeric',
    hour: 'numeric', minute: 'numeric', second: 'numeric'
  });
  const nameFormatter = new NativeDTF('en-US', { timeZone: TZ, timeZoneName: 'long' });
  const offsetCache = new Map();

  // Minutes such that UTC = local + offset (same sign convention as getTimezoneOffset).
  function offsetFor(t) {
    const bucket = Math.floor(t / 900000); // DST transitions fall on 15-minute boundaries
    if (offsetCache.has(bucket)) return offsetCache.get(bucket);
    const p = {};
    for (const part of partsFormatter.formatToParts(new NativeDate(t))) p[part.type] = part.value;
    let year = +p.year;
    if (p.era === 'BC' || p.era === 'B') year = 1 - year;
    const wallAsUTC = new NativeDate(0);
    wallAsUTC.setUTCFullYear(year, +p.month - 1, +p.day);
    wallAsUTC.setUTCHours(+p.hour % 24, +p.minute, +p.second, 0);
    const truncated = t - (((t % 1000) + 1000) % 1000);
    const offset = Math.round((truncated - nativeGetTime.call(wallAsUTC)) / 60000);
    if (offsetCache.size > 512) offsetCache.clear();
    offsetCache.set(bucket, offset);
    return offset;
  }

  function wall(date) {
    const t = nativeGetTime.call(date);
    return isNaN(t) ? null : new NativeDate(t - offsetFor(t) * 60000);
  }

  const utcGetters = {
    FullYear: proto.getUTCFullYear, Month: proto.getUTCMonth, Date: proto.getUTCDate,
    Day: proto.getUTCDay, Hours: proto.getUTCHours, Minutes: proto.getUTCMinutes,
    Seconds: proto.getUTCSeconds, Milliseconds: proto.getUTCMilliseconds
  };
  for (const name of Object.keys(utcGetters)) {
    const utcGetter = utcGetters[name];
    define(proto, 'get' + name, function () {
      const shifted = wall(this);
      return shifted === null ? NaN : utcGetter.call(shifted);
    });
  }
  define(proto, 'getTimezoneOffset', function () {
    const t = nativeGetTime.call(this);
    return isNaN(t) ? NaN : offsetFor(t);
  });

  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const pad = (n, l) => String(n).padStart(l || 2, '0');
  const yearString = (y) => (y < 0 ? '-' + pad(-y, 6) : pad(y, 4));
  function zoneSuffix(t) {
    const minutesEast = -offsetFor(t);
    const a = Math.abs(minutesEast);
    const namePart = nameFormatter.formatToParts(new NativeDate(t)).find((p) => p.type === 'timeZoneName');
    return 'GMT' + (minutesEast >= 0 ? '+' : '-') + pad(Math.floor(a / 60)) + pad(a % 60) +
      ' (' + (namePart ? namePart.value : TZ) + ')';
  }
  function datePart(s) {
    return days[s.getUTCDay()] + ' ' + months[s.getUTCMonth()] + ' ' + pad(s.getUTCDate()) + ' ' + yearString(s.getUTCFullYear());
  }
  function timePart(s, t) {
    return pad(s.getUTCHours()) + ':' + pad(s.getUTCMinutes()) + ':' + pad(s.getUTCSeconds()) + ' ' + zoneSuffix(t);
  }
  define(proto, 'toString', function () {
    const s = wall(this);
    return s === null ? 'Invalid Date' : datePart(s) + ' ' + timePart(s, nativeGetTime.call(this));
  });
  define(proto, 'toDateString', function () {
    const s = wall(this);
    return s === null ? 'Invalid Date' : datePart(s);
  });
  define(proto, 'toTimeString', function () {
    const s = wall(this);
    return s === null ? 'Invalid Date' : timePart(s, nativeGetTime.call(this));
  });

  const withZone = (options) => {
    const o = Object.assign({}, options);
    if (o.timeZone === undefined) o.timeZone = TZ;
    return o;
  };
  for (const name of ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString']) {
    const original = proto[name];
    define(proto, name, function (locales, options) { return original.call(this, locales, withZone(options)); });
  }

  function DateTimeFormat(locales, options) {
    return Reflect.construct(NativeDTF, [locales, withZone(options)], new.target || DateTimeFormat);
  }
  DateTimeFormat.prototype = NativeDTF.prototype;
  define(DateTimeFormat, 'supportedLocalesOf', NativeDTF.supportedLocalesOf);
  define(NativeDTF.prototype, 'constructor', DateTimeFormat);
  define(w.Intl, 'DateTimeFormat', DateTimeFormat);
}

// -------------------------------------------------------------- geolocation
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
  define(GeoProto, 'getCurrentPosition', function (success, error) { respond(success, error); });
  define(GeoProto, 'watchPosition', function (success, error) { respond(success, error); return nextWatch++; });
  define(GeoProto, 'clearWatch', function () {});

  if (nav.permissions && nav.permissions.query) {
    const PermProto = Object.getPrototypeOf(nav.permissions);
    const originalQuery = PermProto.query;
    define(PermProto, 'query', function (descriptor) {
      if (descriptor && descriptor.name === 'geolocation') {
        const status = Object.create(w.PermissionStatus ? w.PermissionStatus.prototype : Object.prototype);
        Object.defineProperty(status, 'state', { value: geo.mode === 'fixed' ? 'granted' : 'denied', enumerable: true });
        Object.defineProperty(status, 'name', { value: 'geolocation', enumerable: true });
        status.onchange = null;
        return Promise.resolve(status);
      }
      return originalQuery.apply(this, arguments);
    });
  }
}

// ------------------------------------------------------------------- WebRTC
function patchWebRTC(w, policy) {
  if (policy === 'unrestricted') return;
  const names = ['RTCPeerConnection', 'webkitRTCPeerConnection'];
  if (policy === 'disabled') {
    for (const name of names.concat(['RTCDataChannel', 'RTCIceCandidate', 'RTCSessionDescription',
                                     'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver'])) {
      try { delete w[name]; } catch (e) {}
      try { Object.defineProperty(w, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
    }
    return;
  }
  // relayOnly: no host / server-reflexive candidates are gathered.
  const Native = w.RTCPeerConnection;
  if (!Native) return;
  const forceRelay = (config) => Object.assign({}, config, { iceTransportPolicy: 'relay' });
  function RTCPeerConnection(config, ...rest) {
    return Reflect.construct(Native, [forceRelay(config), ...rest], new.target || RTCPeerConnection);
  }
  RTCPeerConnection.prototype = Native.prototype;
  if (Native.generateCertificate) define(RTCPeerConnection, 'generateCertificate', Native.generateCertificate);
  const nativeSetConfiguration = Native.prototype.setConfiguration;
  if (nativeSetConfiguration) {
    define(Native.prototype, 'setConfiguration', function (config) { return nativeSetConfiguration.call(this, forceRelay(config)); });
  }
  define(Native.prototype, 'constructor', RTCPeerConnection);
  for (const name of names) {
    try { Object.defineProperty(w, name, { value: RTCPeerConnection, writable: false, configurable: false }); } catch (e) {}
  }
}

// ----------------------------------------------------------- child windows
function hookChildWindows(w) {
  const hook = (Ctor, prop, toWindow) => {
    if (!Ctor) return;
    const descriptor = Object.getOwnPropertyDescriptor(Ctor.prototype, prop);
    if (!descriptor || !descriptor.get) return;
    Object.defineProperty(Ctor.prototype, prop, {
      configurable: true, enumerable: descriptor.enumerable,
      get: function () {
        const value = descriptor.get.call(this);
        try { patchWindow(toWindow(value)); } catch (e) {} // cross-origin: inaccessible, and gets its own injection
        return value;
      }
    });
  };
  hook(w.HTMLIFrameElement, 'contentWindow', (v) => v);
  hook(w.HTMLIFrameElement, 'contentDocument', (v) => v && v.defaultView);
  hook(w.HTMLFrameElement, 'contentWindow', (v) => v);
  hook(w.HTMLObjectElement, 'contentWindow', (v) => v);
  const nativeOpen = w.open;
  if (nativeOpen) {
    define(w, 'open', function () {
      const opened = nativeOpen.apply(this, arguments);
      try { patchWindow(opened); } catch (e) {}
      return opened;
    });
  }
}

function define(target, name, value) {
  Object.defineProperty(target, name, { value: value, writable: true, configurable: true, enumerable: false });
}

patchWindow(window);
"""#
    // END SHIM
}
