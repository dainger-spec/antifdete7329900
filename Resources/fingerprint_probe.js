// Fingerprint surface probe: what fingerprinting pages (deviceinfo.me, pixelscan, CreepJS) read.
// Run as a function body (WebDriver execute/sync, WKWebView callAsyncJavaScript); returns JSON.
//
// The self-test runs it in a plain WKWebView, in a macOS profile and in an iPhone profile; the
// CI step scripts/safari_reference.py runs the same probe in the Mac's real Safari and compares.
// Keep it synchronous (WebDriver execute/sync).
const result = {};
const safe = (key, fn) => { try { result[key] = fn(); } catch (e) { result[key] = 'error: ' + (e && e.message); } };
const type = (expr) => { try { return typeof expr(); } catch (e) { return 'error'; } };
const nativeText = (f) => { try { return Function.prototype.toString.call(f); } catch (e) { return 'error: ' + (e && e.message); } };
const isNative = (f) => typeof f === 'function' && nativeText(f).includes('[native code]');

// Identity
safe('ua', () => navigator.userAgent);
safe('appVersion', () => navigator.appVersion);
safe('vendor', () => navigator.vendor);
safe('platform', () => navigator.platform);
safe('language', () => navigator.language);
safe('languages', () => Array.from(navigator.languages).join(','));
safe('hardwareConcurrency', () => navigator.hardwareConcurrency);
safe('deviceMemory', () => typeof navigator.deviceMemory);
safe('maxTouchPoints', () => navigator.maxTouchPoints);
safe('pdfViewerEnabled', () => String(navigator.pdfViewerEnabled));
safe('plugins', () => Array.from(navigator.plugins, (p) => p.name).join('|'));
safe('mimeTypes', () => Array.from(navigator.mimeTypes, (m) => m.type).join('|'));
safe('webdriver', () => String(navigator.webdriver));
safe('standalone', () => typeof navigator.standalone === 'undefined' ? 'undefined' : String(navigator.standalone));
safe('doNotTrack', () => typeof navigator.doNotTrack);
safe('cookieEnabled', () => navigator.cookieEnabled);
safe('ownNavigator', () => Object.getOwnPropertyNames(navigator).join(','));
safe('ownScreen', () => Object.getOwnPropertyNames(screen).join(','));
safe('navigatorProtoCount', () => Object.getOwnPropertyNames(Navigator.prototype).length);

// Screen and window
safe('screen', () => [screen.width, screen.height, screen.availWidth, screen.availHeight, devicePixelRatio].join('x'));
safe('colorDepth', () => screen.colorDepth + '/' + screen.pixelDepth);
safe('orientation', () => screen.orientation ? screen.orientation.type : 'none');
safe('innerSize', () => innerWidth + 'x' + innerHeight);
safe('outerSize', () => outerWidth + 'x' + outerHeight);
safe('pointer', () => [matchMedia('(pointer: fine)').matches, matchMedia('(hover: hover)').matches, matchMedia('(any-pointer: coarse)').matches].join(','));
safe('touch', () => ['ontouchstart' in window, typeof TouchEvent, typeof Touch].join(','));

// Time and locale
safe('timeZone', () => Intl.DateTimeFormat().resolvedOptions().timeZone);
safe('tzOffset', () => new Date(Date.UTC(2024, 0, 15, 12)).getTimezoneOffset() + '/' + new Date(Date.UTC(2024, 6, 15, 12)).getTimezoneOffset());
safe('intlLocale', () => { const o = Intl.DateTimeFormat().resolvedOptions(); return [o.locale, o.calendar, o.numberingSystem].join(','); });
safe('dateString', () => new Date(Date.UTC(2024, 0, 15, 12)).toString());

// Canvas (deviceinfo.me's test: 6x6, five greys)
safe('canvas', () => {
  const canvas = document.createElement('canvas');
  canvas.width = 6; canvas.height = 6;
  const ctx = canvas.getContext('2d');
  const greys = ['#000000', '#404040', '#808080', '#BFBFBF', '#FFFFFF'];
  for (let y = 0; y < 5; y++) for (let x = 0; x < 5; x++) { ctx.fillStyle = greys[x]; ctx.fillRect(x, y, 1, 1); }
  const pixels = new Uint32Array(ctx.getImageData(0, 0, 6, 6).data.buffer);
  const url = canvas.toDataURL();
  return { colors: new Set(Array.from(pixels, (p) => p & 0xFFFFFF)).size, urlLength: url.length, url: url };
});
safe('canvasText', () => {
  const canvas = document.createElement('canvas');
  canvas.width = 240; canvas.height = 40;
  const ctx = canvas.getContext('2d');
  ctx.textBaseline = 'alphabetic';
  ctx.font = '14px Arial';
  ctx.fillStyle = '#f60'; ctx.fillRect(100, 1, 62, 20);
  ctx.fillStyle = '#069'; ctx.fillText('Cwm fjordbank glyphs vext quiz, 😃', 2, 15);
  ctx.fillStyle = 'rgba(102, 204, 0, 0.7)'; ctx.fillText('Cwm fjordbank glyphs vext quiz, 😃', 4, 17);
  const url = canvas.toDataURL();
  let hash = 0;
  for (let i = 0; i < url.length; i++) hash = (hash * 31 + url.charCodeAt(i)) | 0;
  return url.length + ':' + hash;
});

// WebGL
safe('webgl', () => {
  const canvas = document.createElement('canvas');
  const gl = canvas.getContext('webgl2') || canvas.getContext('webgl');
  if (!gl) return 'none';
  const info = gl.getExtension('WEBGL_debug_renderer_info');
  return {
    kind: gl instanceof WebGL2RenderingContext ? 'webgl2' : 'webgl',
    vendor: gl.getParameter(gl.VENDOR),
    renderer: gl.getParameter(gl.RENDERER),
    unmaskedVendor: info ? gl.getParameter(info.UNMASKED_VENDOR_WEBGL) : 'n/a',
    unmaskedRenderer: info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : 'n/a',
    version: gl.getParameter(gl.VERSION),
    shadingLanguage: gl.getParameter(gl.SHADING_LANGUAGE_VERSION),
    extensions: (gl.getSupportedExtensions() || []).slice().sort().join(','),
    limits: [gl.MAX_TEXTURE_SIZE, gl.MAX_VERTEX_ATTRIBS, gl.MAX_VARYING_VECTORS, gl.MAX_FRAGMENT_UNIFORM_VECTORS,
             gl.MAX_RENDERBUFFER_SIZE, gl.MAX_COMBINED_TEXTURE_IMAGE_UNITS, gl.MAX_CUBE_MAP_TEXTURE_SIZE]
      .map((p) => gl.getParameter(p)).join(','),
    viewport: Array.from(gl.getParameter(gl.MAX_VIEWPORT_DIMS)).join('x'),
    lineWidth: Array.from(gl.getParameter(gl.ALIASED_LINE_WIDTH_RANGE)).join('-'),
  };
});

// Audio
safe('audio', () => {
  const AC = window.AudioContext || window.webkitAudioContext;
  if (!AC) return 'none';
  const ctx = new AC();
  const r = [ctx.sampleRate, ctx.destination.maxChannelCount, ctx.destination.channelCount, ctx.state].join(',');
  ctx.close();
  return r;
});

// Fonts (text metrics of common families; the same Mac gives the same widths)
safe('fonts', () => {
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');
  return ['Arial', 'Helvetica Neue', 'Times', 'Courier', 'Menlo', 'Monaco', 'Georgia', 'Verdana', 'Avenir', 'Futura',
          'Gill Sans', 'Palatino', 'Optima', 'Baskerville', 'San Francisco', 'Comic Sans MS', 'Segoe UI', 'Roboto',
          'Noto Sans', 'Ubuntu', '-apple-system', 'system-ui']
    .map((f) => { ctx.font = '20px "' + f + '", monospace'; return Math.round(ctx.measureText('mmmmmmmmmmlli').width * 100) / 100; })
    .join(',');
});

// Feature presence
safe('features', () => {
  const names = ['ApplePaySession', 'PaymentRequest', 'PublicKeyCredential', 'navigator.credentials', 'navigator.share',
    'navigator.gpu', 'navigator.storage', 'navigator.serviceWorker', 'navigator.mediaDevices', 'navigator.getBattery',
    'navigator.bluetooth', 'navigator.usb', 'navigator.connection', 'navigator.requestMIDIAccess', 'navigator.locks',
    'navigator.permissions', 'navigator.clipboard', 'navigator.wakeLock', 'navigator.contacts', 'navigator.xr',
    'navigator.getUserMedia', 'navigator.mediaSession', 'navigator.scheduling', 'navigator.ink',
    'OffscreenCanvas', 'SharedArrayBuffer', 'Atomics', 'WebTransport', 'WebSocketStream', 'VideoEncoder', 'VideoDecoder',
    'AudioEncoder', 'ImageDecoder', 'MediaRecorder', 'MediaSource', 'ManagedMediaSource', 'RTCPeerConnection',
    'webkitRTCPeerConnection', 'RTCDataChannel', 'webkitSpeechRecognition', 'SpeechRecognition', 'speechSynthesis',
    'Notification', 'PushManager', 'BroadcastChannel', 'CookieStore', 'FileSystemHandle', 'FileSystemWritableFileStream',
    'showOpenFilePicker', 'DeviceMotionEvent', 'DeviceOrientationEvent', 'Gamepad', 'ScreenOrientation', 'WebGL2RenderingContext',
    'GPU', 'GPUDevice', 'HTMLModelElement', 'HTMLPortalElement', 'Highlight', 'CSSTypedOM', 'CSS.registerProperty',
    'CSS.paintWorklet', 'CSS.highlights', 'ViewTransition', 'document.startViewTransition', 'document.pictureInPictureEnabled',
    'document.fullscreenEnabled', 'document.webkitFullscreenEnabled', 'document.requestStorageAccess', 'document.hasStorageAccess',
    'document.featurePolicy', 'document.fonts', 'Intl.Segmenter', 'Intl.DurationFormat', 'Intl.DisplayNames', 'Intl.ListFormat',
    'Temporal', 'WebAssembly', 'WebAssembly.Memory', 'structuredClone', 'scheduler', 'requestIdleCallback', 'queueMicrotask',
    'ResizeObserver', 'IntersectionObserver', 'PerformanceObserver', 'performance.memory', 'performance.measureUserAgentSpecificMemory',
    'crossOriginIsolated', 'isSecureContext', 'TrustedTypes', 'trustedTypes', 'chrome', 'safari', 'webkit', 'opr', 'external',
    'openDatabase', 'webkitResolveLocalFileSystemURL', 'webkitRequestFileSystem', 'StorageManager', 'webkitStorageInfo',
    'CanvasCaptureMediaStreamTrack', 'ImageCapture', 'MediaStreamTrackGenerator', 'EyeDropper', 'LaunchQueue', 'Sanitizer',
    'AbsoluteOrientationSensor', 'Accelerometer', 'AmbientLightSensor', 'NDEFReader', 'HID', 'Serial', 'Keyboard', 'IdleDetector',
    'ContactsManager', 'BarcodeDetector', 'FaceDetector', 'TextDetector', 'ReportingObserver', 'NavigationPreloadManager',
    'navigation', 'Navigation', 'PerformanceLongAnimationFrameTiming', 'ContentVisibilityAutoStateChangeEvent', 'CSSMathValue',
    'HTMLDialogElement', 'HTMLSlotElement', 'customElements', 'SpeechGrammarList', 'webkitSpeechGrammarList', 'webkitURL',
    'webkitMediaStream', 'webkitAudioContext', 'webkitOfflineAudioContext', 'webkitConvertPointFromNodeToPage',
    'webkitCancelAnimationFrame', 'webkitIndexedDB', 'webkitMatchMedia', 'onwebkitmouseforcewillbegin', 'onwebkittransitionend',
    'DOMPoint', 'PictureInPictureEvent', 'HTMLVideoElement.prototype.webkitSupportsPresentationMode',
    'HTMLVideoElement.prototype.requestPictureInPicture', 'HTMLMediaElement.prototype.webkitShowPlaybackTargetPicker',
    'HTMLMediaElement.prototype.webkitWirelessVideoPlaybackDisabled', 'navigator.pdfViewerEnabled', 'navigator.hardwareConcurrency',
    'navigator.deviceMemory', 'navigator.standalone', 'navigator.doNotTrack', 'navigator.globalPrivacyControl',
    'navigator.userAgentData', 'navigator.keyboard', 'navigator.virtualKeyboard', 'navigator.windowControlsOverlay',
    'navigator.login', 'navigator.hid', 'navigator.serial', 'navigator.presentation', 'navigator.webkitTemporaryStorage',
    'navigator.webkitPersistentStorage', 'navigator.getGamepads', 'navigator.vibrate', 'navigator.sendBeacon',
    'navigator.requestMediaKeySystemAccess', 'navigator.registerProtocolHandler', 'navigator.canShare',
    'navigator.setAppBadge', 'navigator.geolocation', 'navigator.deprecatedRunInsecureContent', 'Date.prototype.toTemporalInstant',
    'Array.prototype.group', 'Object.groupBy', 'Promise.withResolvers', 'Set.prototype.union', 'Iterator', 'Float16Array',
    'RegExp.escape', 'Error.isError', 'Math.sumPrecise', 'Uint8Array.fromBase64', 'JSON.rawJSON', 'ShadowRealm',
    'Intl.Locale.prototype.getTextInfo', 'Intl.RelativeTimeFormat', 'AggregateError', 'WeakRef', 'FinalizationRegistry',
    'CompressionStream', 'DecompressionStream', 'TextDecoderStream', 'ReadableStream.prototype.values', 'AbortSignal.any',
    'AbortSignal.timeout', 'Request.prototype.duplex', 'Response.json', 'URL.canParse', 'URL.parse', 'URLPattern',
    'CSS.supports', 'CSSContainerRule', 'CSSLayerBlockRule', 'CSSScopeRule', 'CSSStartingStyleRule', 'CSSNestedDeclarations',
    'CSSPositionTryRule', 'CSSFontFeatureValuesRule', 'CSSViewTransitionRule', 'AnchorPositioning', 'HTMLElement.prototype.popover',
    'HTMLElement.prototype.inert', 'HTMLElement.prototype.hidePopover', 'Element.prototype.checkVisibility',
    'Element.prototype.scrollIntoViewIfNeeded', 'Element.prototype.webkitRequestFullscreen', 'Element.prototype.computedStyleMap',
    'Document.prototype.caretRangeFromPoint', 'Document.prototype.caretPositionFromPoint', 'Document.prototype.exitPictureInPicture',
    'Document.prototype.webkitExitFullscreen', 'window.webkitRequestAnimationFrame', 'window.webkitSpeechGrammar',
    'window.onbeforeinstallprompt', 'window.ontouchstart', 'window.onpointerrawupdate', 'window.oncontextlost',
    'window.onwebkitplaybacktargetavailabilitychanged', 'window.ongesturestart', 'window.onsearch', 'window.onwebkitanimationstart',
    'window.onbeforexrselect', 'window.ondeviceorientationabsolute', 'window.onbeforetoggle', 'window.onscrollend',
    'window.onpageswap', 'window.onpagereveal', 'window.oncommand', 'window.onselectionchange', 'window.onsecuritypolicyviolation',
    'window.onwebkitmouseforcedown', 'window.captureEvents', 'window.releaseEvents', 'window.find', 'window.showModalDialog',
    'window.webkitStorageInfo', 'window.webkitNotifications', 'window.applicationCache', 'window.styleMedia', 'window.MediaMetadata',
    'window.Credential', 'window.PasswordCredential', 'window.FederatedCredential', 'window.IdentityCredential',
    'window.Scheduler', 'window.TaskController', 'window.DelegatedInkTrailPresenter', 'window.FileSystemObserver',
    'window.WebSocketError', 'window.NavigateEvent', 'window.CloseWatcher', 'window.HTMLFencedFrameElement', 'window.Fence',
    'window.SharedStorage', 'window.sharedStorage', 'window.PrivateAggregation', 'window.PaymentManager', 'window.PaymentInstruments',
    'window.MerchantValidationEvent', 'window.ApplePayError', 'window.ApplePaySetup', 'window.ApplePayPaymentMethod',
    'window.MediaKeys', 'window.WebKitMediaKeys', 'window.SourceBuffer', 'window.WebKitPlaybackTargetAvailabilityEvent',
    'window.WebKitMediaKeyMessageEvent', 'window.webkitMediaStream', 'window.webkitRTCPeerConnection', 'window.RTCRtpScriptTransform',
    'window.RTCEncodedVideoFrame', 'window.SpeechSynthesisUtterance', 'window.webkitSpeechRecognitionEvent',
    'window.webkitSpeechRecognitionError', 'window.WebKitAnimationEvent', 'window.WebKitTransitionEvent', 'window.WebKitCSSMatrix',
    'window.WebKitPoint', 'window.webkitAudioPannerNode', 'window.webkitOfflineAudioContext', 'window.WebKitMutationObserver',
    'window.webkitMediaKeys', 'window.OverconstrainedError', 'window.OverflowEvent', 'window.MouseScrollEvent',
    'window.WebKitNamespace', 'window.DataCue', 'window.VTTCue', 'window.TextTrackCue', 'window.VTTRegion', 'window.WebKitDataCue',
    'window.AudioTrackList', 'window.VideoTrackList', 'window.WebGLContextEvent', 'window.WebGLRenderingContext', 'window.WebGPUDevice',
    'window.ImageBitmapRenderingContext', 'window.OffscreenCanvasRenderingContext2D', 'window.CanvasFilter', 'window.ImageData',
    'window.Path2D', 'window.TextMetrics', 'window.FontFace', 'window.FontFaceSet', 'window.FontData', 'window.queryLocalFonts',
    'window.WritableStreamDefaultController', 'window.ByteLengthQueuingStrategy', 'window.MIDIAccess', 'window.MIDIInput',
    'window.XRSystem', 'window.XRSession', 'window.XRWebGLLayer', 'window.ModelElement', 'window.HTMLAttachmentElement',
    'window.PerformanceEventTiming', 'window.LargestContentfulPaint', 'window.LayoutShift', 'window.PerformanceElementTiming',
    'window.PerformancePaintTiming', 'window.PerformanceNavigationTiming', 'window.PerformanceServerTiming',
    'window.PerformanceResourceTiming.prototype.renderBlockingStatus', 'window.PerformanceResourceTiming.prototype.deliveryType',
    'window.PerformanceResourceTiming.prototype.responseStatus', 'window.PerformanceResourceTiming.prototype.firstInterimResponseStart',
    'window.Performance.prototype.interactionCount', 'window.Performance.prototype.eventCounts', 'window.Performance.prototype.memory',
    'window.CSSImageValue', 'window.CSSKeywordValue', 'window.CSSNumericValue', 'window.CSSStyleValue', 'window.CSSTransformValue',
    'window.CSSUnparsedValue', 'window.CSSPerspective', 'window.CSSColorValue', 'window.CSSColor', 'window.CSSRGB', 'window.CSSHSL',
    'window.StylePropertyMap', 'window.StylePropertyMapReadOnly', 'window.CSSAnimation', 'window.CSSTransition', 'window.ScrollTimeline',
    'window.ViewTimeline', 'window.CSSCounterStyleRule', 'window.CSSPropertyRule', 'window.CSSFontPaletteValuesRule',
    'window.CSSMarginRule', 'window.CSSPageDescriptors', 'window.HTMLSelectedContentElement', 'window.CustomizableSelect',
    'window.Invoker', 'window.CommandEvent', 'window.ToggleEvent', 'window.ContentVisibilityAutoStateChangeEvent',
    'window.SnapEvent', 'window.ScrollTimeline', 'window.WebKitCSSMatrix', 'window.DOMMatrix', 'window.DOMQuad', 'window.DOMRect'];
  const out = {};
  for (const name of names) {
    out[name] = type(() => {
      const parts = name.split('.');
      let obj = window;
      for (const part of parts) {
        if (obj === undefined || obj === null) return undefined;
        obj = obj[part];
      }
      return obj;
    });
  }
  return out;
});

// Safari-only surface (Safari the app injects window.safari; a WKWebView app does not)
safe('safari', () => typeof window.safari === 'undefined' ? 'undefined'
  : Object.prototype.toString.call(window.safari) + '|' + Object.getOwnPropertyNames(window.safari).join(',')
    + '|' + (window.safari.pushNotification ? String(window.safari.pushNotification) : 'no pushNotification'));
safe('webkitObject', () => typeof window.webkit);
safe('windowOwnCount', () => Object.getOwnPropertyNames(window).length);

// Native-looking functions (CreepJS "lies"): toString, name, length, own property names
safe('natives', () => {
  const out = {};
  const fns = {
    'Date.prototype.getTimezoneOffset': Date.prototype.getTimezoneOffset,
    'Date.prototype.getHours': Date.prototype.getHours,
    'Date.prototype.toString': Date.prototype.toString,
    'Date.prototype.toLocaleString': Date.prototype.toLocaleString,
    'Date': Date,
    'Intl.DateTimeFormat': Intl.DateTimeFormat,
    'Intl.DateTimeFormat.prototype.resolvedOptions': Intl.DateTimeFormat.prototype.resolvedOptions,
    'Function.prototype.toString': Function.prototype.toString,
    'navigator.geolocation.getCurrentPosition': navigator.geolocation && Object.getPrototypeOf(navigator.geolocation).getCurrentPosition,
    'Permissions.prototype.query': window.Permissions && Permissions.prototype.query,
    'RTCPeerConnection': window.RTCPeerConnection,
    'HTMLIFrameElement.contentWindow getter': Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'contentWindow').get,
    'window.open': window.open,
    'Navigator.platform getter': Object.getOwnPropertyDescriptor(Navigator.prototype, 'platform').get,
    'Navigator.hardwareConcurrency getter': Object.getOwnPropertyDescriptor(Navigator.prototype, 'hardwareConcurrency').get,
    'Navigator.maxTouchPoints getter': Object.getOwnPropertyDescriptor(Navigator.prototype, 'maxTouchPoints').get,
    'Screen.width getter': Object.getOwnPropertyDescriptor(Screen.prototype, 'width').get,
    'window.devicePixelRatio getter': Object.getOwnPropertyDescriptor(window, 'devicePixelRatio').get,
    'window.outerWidth getter': Object.getOwnPropertyDescriptor(window, 'outerWidth').get,
    'HTMLCanvasElement.prototype.toDataURL': HTMLCanvasElement.prototype.toDataURL,
    'CanvasRenderingContext2D.prototype.getImageData': CanvasRenderingContext2D.prototype.getImageData,
    'WebGLRenderingContext.prototype.getParameter': WebGLRenderingContext.prototype.getParameter,
    'AudioContext.prototype.createAnalyser': window.AudioContext && AudioContext.prototype.createAnalyser,
  };
  // How this engine prints a native function, taken from one that is certainly native.
  const template = nativeText(Array.prototype.push).replace('push', '%NAME%');
  for (const [name, f] of Object.entries(fns)) {
    if (typeof f !== 'function') { out[name] = 'absent'; continue; }
    const text = nativeText(f);
    const expected = template.replace('%NAME%', f.name);
    out[name] = [text === expected ? 'native-text' : 'TEXT:' + text.slice(0, 60),
                 'len=' + f.length,
                 'own=' + Object.getOwnPropertyNames(f).join('+'),
                 'proto=' + (Object.getPrototypeOf(f) === Function.prototype)].join(' ');
  }
  return out;
});
safe('errorStack', () => { try { null.x; } catch (e) { return String(e.stack).split('\n').length + ':' + String(e.message); } });

return result;
