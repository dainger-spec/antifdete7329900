import BrowserCore
import Foundation
import WebKit

/// JavaScript shims for settings WebKit has no native per-web-view API for.
/// Now includes aggressive navigator / screen / canvas / WebGL spoofing for iOS-like profiles
/// to approximate the iStealth marketing claims as far as public APIs allow.
///
/// PLATFORM LIMITATION — still approximations:
///   * Not in workers. Detectable via toString, descriptors, inconsistencies with TLS/GPU.
///   * Canvas/WebGL overrides are best-effort and can be fingerprinted as spoofed.
///   * True engine-level iOS WebKit is impossible without private frameworks.
enum PrivacyScripts {
    struct ShimConfiguration: Encodable {
        var timeZone: String?
        var geolocation: Geolocation
        var webRTC: String
        var platform: String
        var vendor: String
        var hardwareConcurrency: Int
        var deviceMemory: Double
        var maxTouchPoints: Int
        var languages: [String]
        var screenWidth: Int
        var screenHeight: Int
        var devicePixelRatio: Double
        var isIOS: Bool

        struct Geolocation: Encodable {
            var mode: String
            var latitude: Double?
            var longitude: Double?
            var accuracy: Double?
        }
    }

    static func shimConfiguration(for configuration: ProfileConfiguration) -> ShimConfiguration {
        let gen = configuration.deviceGeneration
        let isIOS = gen.platform == .iOS || gen.platform == .iPadOS
        let geolocation: ShimConfiguration.Geolocation
        switch configuration.geolocation {
        case .deny:
            geolocation = .init(mode: "deny")
        case let .fixed(latitude, longitude, accuracy):
            geolocation = .init(mode: "fixed", latitude: latitude, longitude: longitude, accuracy: accuracy)
        }
        return ShimConfiguration(
            timeZone: configuration.timeZoneIdentifier,
            geolocation: geolocation,
            webRTC: configuration.webRTCPolicy.rawValue,
            platform: isIOS ? "iPhone" : "MacIntel",
            vendor: "Apple Computer, Inc.",
            hardwareConcurrency: isIOS ? 6 : 8,
            deviceMemory: isIOS ? 4 : 8,
            maxTouchPoints: isIOS ? 5 : 0,
            languages: ["en-US", "en"],
            screenWidth: isIOS ? 390 : 1440,
            screenHeight: isIOS ? 844 : 900,
            devicePixelRatio: isIOS ? 3 : 2,
            isIOS: isIOS
        )
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

function patchWindow(w) {
  if (!w || patched.has(w)) return;
  patched.add(w);
  try { patchNavigator(w); } catch (e) {}
  try { patchScreen(w); } catch (e) {}
  if (CONFIG.isIOS) { try { patchCanvasWebGL(w); } catch (e) {} }
  if (CONFIG.timeZone) { try { patchTimeZone(w, CONFIG.timeZone); } catch (e) {} }
  try { patchGeolocation(w, CONFIG.geolocation || { mode: 'deny' }); } catch (e) {}
  try { patchWebRTC(w, CONFIG.webRTC || 'disabled'); } catch (e) {}
  try { hookChildWindows(w); } catch (e) {}
}

function patchNavigator(w) {
  const nav = w.navigator;
  if (!nav) return;
  const define = (obj, prop, val) => Object.defineProperty(obj, prop, { value: val, writable: false, configurable: false });
  define(nav, 'platform', CONFIG.platform);
  define(nav, 'vendor', CONFIG.vendor);
  define(nav, 'hardwareConcurrency', CONFIG.hardwareConcurrency);
  define(nav, 'deviceMemory', CONFIG.deviceMemory);
  define(nav, 'maxTouchPoints', CONFIG.maxTouchPoints);
  define(nav, 'languages', Object.freeze(CONFIG.languages.slice()));
  define(nav, 'language', CONFIG.languages[0]);
  if (CONFIG.isIOS) {
    define(nav, 'standalone', false);
    try { delete w.ontouchstart; } catch (e) {}
  }
}

function patchScreen(w) {
  const s = w.screen;
  if (!s) return;
  Object.defineProperty(s, 'width', { value: CONFIG.screenWidth, writable: false });
  Object.defineProperty(s, 'height', { value: CONFIG.screenHeight, writable: false });
  Object.defineProperty(s, 'availWidth', { value: CONFIG.screenWidth, writable: false });
  Object.defineProperty(s, 'availHeight', { value: CONFIG.screenHeight, writable: false });
  Object.defineProperty(w, 'devicePixelRatio', { value: CONFIG.devicePixelRatio, writable: false });
}

function patchCanvasWebGL(w) {
  // Best-effort noise / fixed values to reduce Mac GPU fingerprint. Highly detectable.
  const proto = w.HTMLCanvasElement && w.HTMLCanvasElement.prototype;
  if (proto && proto.getContext) {
    const orig = proto.getContext;
    proto.getContext = function (type, attrs) {
      const ctx = orig.apply(this, arguments);
      if (type === '2d' && ctx) {
        const origToData = ctx.getImageData;
        ctx.getImageData = function () {
          const data = origToData.apply(this, arguments);
          // Tiny noise
          for (let i = 0; i < data.data.length; i += 4) data.data[i] ^= 1;
          return data;
        };
      }
      return ctx;
    };
  }
  // WebGL vendor/renderer spoof attempt
  if (w.WebGLRenderingContext) {
    const getParam = w.WebGLRenderingContext.prototype.getParameter;
    w.WebGLRenderingContext.prototype.getParameter = function (p) {
      if (p === 37445) return 'Apple Inc.'; // UNMASKED_VENDOR_WEBGL
      if (p === 37446) return 'Apple GPU'; // UNMASKED_RENDERER_WEBGL
      return getParam.apply(this, arguments);
    };
  }
}

// ... (existing patchTimeZone, patchGeolocation, patchWebRTC, hookChildWindows, define remain the same)
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

function hookChildWindows(w) {
  const hook = (Ctor, prop, toWindow) => {
    if (!Ctor) return;
    const descriptor = Object.getOwnPropertyDescriptor(Ctor.prototype, prop);
    if (!descriptor || !descriptor.get) return;
    Object.defineProperty(Ctor.prototype, prop, {
      configurable: true, enumerable: descriptor.enumerable,
      get: function () {
        const value = descriptor.get.call(this);
        try { patchWindow(toWindow(value)); } catch (e) {}
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
}
