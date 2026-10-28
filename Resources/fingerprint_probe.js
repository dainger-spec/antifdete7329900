// Fingerprint surface probe: what fingerprinting pages (deviceinfo.me, pixelscan, CreepJS) read.
// Run as a function body (WebDriver execute/sync, WKWebView callAsyncJavaScript); returns JSON.
//
// The self-test runs it in a plain WKWebView, in a macOS profile and in an iPhone profile; the
// CI step scripts/safari_reference.py runs the same probe in the Mac's real Safari and compares.
// Everything up to "Behaviour" is synchronous; the behaviour checks at the end are not, so the
// probe returns a promise (callAsyncJavaScript, WebDriver execute/async and the device page
// await it).
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
// The touch interfaces' shape where they exist: WebKit builds them only for iOS with Apple's internal
// SDK (ENABLE_TOUCH_EVENTS, ENABLE_IOS_TOUCH_EVENTS in WTF's PlatformEnableCocoa.h), partly from
// sources Apple does not publish, so only a device shows what a profile lacks.
safe('touchShape', () => {
  const holders = { window, 'Window.prototype': Window.prototype, 'Document.prototype': Document.prototype,
                    'Element.prototype': Element.prototype, 'HTMLElement.prototype': HTMLElement.prototype };
  const where = (name) => Object.keys(holders)
    .filter((holder) => Object.prototype.hasOwnProperty.call(holders[holder], name)).join('+') || 'none';
  const shape = (name) => {
    const f = window[name];
    if (typeof f !== 'function') return typeof f;
    const chain = [];
    for (let p = Object.getPrototypeOf(f.prototype); p && p !== Object.prototype; p = Object.getPrototypeOf(p)) {
      chain.push(p.constructor ? p.constructor.name : '?');
    }
    return ['len=' + f.length, 'chain=' + chain.join('>'), 'own=' + Object.getOwnPropertyNames(f.prototype).join('+')].join(' ');
  };
  const attempt = (fn) => {
    try { const v = fn(); return 'ok:' + Object.prototype.toString.call(v); } catch (e) { return 'throws:' + e.name + ': ' + e.message; }
  };
  return {
    handlers: ['ontouchstart', 'ontouchmove', 'ontouchend', 'ontouchcancel', 'ongesturestart', 'ongesturechange', 'ongestureend']
      .map((name) => name + ':' + where(name)).join(','),
    TouchEvent: shape('TouchEvent'), Touch: shape('Touch'), TouchList: shape('TouchList'), GestureEvent: shape('GestureEvent'),
    createEvent: attempt(() => document.createEvent('TouchEvent')),
    construct: attempt(() => new TouchEvent('touchstart')),
    touchObject: attempt(() => new Touch({ identifier: 1, target: document.documentElement })),
    motionPermission: [window.DeviceMotionEvent, window.DeviceOrientationEvent]
      .map((f) => (f ? typeof f.requestPermission : 'absent')).join(','),
  };
});

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

// Codecs: what the media stack answers for the types fingerprinting scripts ask about (the
// synchronous APIs; MediaCapabilities and WebCodecs answer asynchronously). 'p' probably, 'm' maybe,
// '-' no; y/n for the isTypeSupported calls; a dot where the API is absent.
safe('codecs', () => {
  const types = [
    ['h264', 'video/mp4; codecs="avc1.42E01E"'], ['h264high', 'video/mp4; codecs="avc1.640028"'],
    ['hevc', 'video/mp4; codecs="hvc1.1.6.L93.B0"'], ['hev1', 'video/mp4; codecs="hev1.1.6.L93.B0"'],
    ['av1', 'video/mp4; codecs="av01.0.05M.08"'], ['dolbyVision', 'video/mp4; codecs="dvh1.05.06"'],
    ['vp8', 'video/webm; codecs="vp8"'], ['vp9', 'video/webm; codecs="vp9"'], ['vp9mp4', 'video/mp4; codecs="vp09.00.10.08"'],
    ['av1webm', 'video/webm; codecs="av01.0.05M.08"'], ['theora', 'video/ogg; codecs="theora"'],
    ['hls', 'application/vnd.apple.mpegurl'], ['quicktime', 'video/quicktime'], ['matroska', 'video/x-matroska'],
    ['aac', 'audio/mp4; codecs="mp4a.40.2"'], ['heaac', 'audio/mp4; codecs="mp4a.40.5"'], ['ac3', 'audio/mp4; codecs="ac-3"'],
    ['eac3', 'audio/mp4; codecs="ec-3"'], ['opusmp4', 'audio/mp4; codecs="opus"'], ['flacmp4', 'audio/mp4; codecs="flac"'],
    ['alac', 'audio/mp4; codecs="alac"'], ['mp3', 'audio/mpeg'], ['opuswebm', 'audio/webm; codecs="opus"'],
    ['vorbis', 'audio/webm; codecs="vorbis"'], ['opusogg', 'audio/ogg; codecs="opus"'], ['flac', 'audio/flac'],
    ['wav', 'audio/wav'], ['caf', 'audio/x-caf'],
  ];
  const video = document.createElement('video');
  const play = (type) => ({ probably: 'p', maybe: 'm', '': '-' })[video.canPlayType(type)] || '?';
  const supported = (api, type) => {
    if (!api || typeof api.isTypeSupported !== 'function') return '.';
    try { return api.isTypeSupported(type) ? 'y' : 'n'; } catch (e) { return 'e'; }
  };
  const recorder = ['video/mp4', 'video/mp4; codecs="avc1,mp4a"', 'video/webm', 'video/webm; codecs="vp8,opus"',
                    'audio/mp4', 'audio/webm; codecs="opus"'];
  return {
    canPlay: types.map(([name, type]) => name + ':' + play(type)).join(','),
    mediaSource: types.map(([name, type]) => name + ':' + supported(window.MediaSource, type)).join(','),
    managedMediaSource: types.map(([name, type]) => name + ':' + supported(window.ManagedMediaSource, type)).join(','),
    mediaRecorder: recorder.map((type) => type + ':' + supported(window.MediaRecorder, type)).join(','),
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
// Which families a page finds, the way font-detection scripts tell (text in the family measures
// unlike a generic family alone): first ones a Mac has and an iPhone only offers for download, then
// ones both have. And which family each generic one is (the candidates of the same width).
safe('fontFamilies', () => {
  const ctx = document.createElement('canvas').getContext('2d');
  const width = (font) => { ctx.font = '20px ' + font; return ctx.measureText('mmmmmmmmmmlli wWQ@').width; };
  const generics = ['monospace', 'serif', 'sans-serif'];
  const fallback = Object.fromEntries(generics.map((g) => [g, width(g)]));
  const present = (family) => generics.some((g) => width('"' + family + '", ' + g) !== fallback[g]);
  const families = ['Monaco', 'Comic Sans MS', 'Arial Unicode MS', 'Tahoma', 'Lucida Grande', 'Geneva', 'Andale Mono',
    'Apple Chancery', 'Arial Black', 'Arial Narrow', 'Webdings', 'Wingdings', 'Microsoft Sans Serif', 'Century Gothic',
    'Garamond', 'Skia', 'Herculanum', 'PT Sans', 'Songti SC', 'AppleMyungjo', 'Times',
    'Helvetica', 'Helvetica Neue', 'Arial', 'Times New Roman', 'Courier', 'Courier New', 'Menlo', 'Georgia', 'Verdana',
    'Trebuchet MS', 'Futura', 'Gill Sans', 'Palatino', 'Optima', 'Baskerville', 'Avenir', 'Avenir Next', 'Didot',
    'Copperplate', 'Papyrus', 'Zapfino', 'Snell Roundhand', 'Marker Felt', 'Chalkboard SE', 'Impact', 'Rockwell',
    'Charter', 'Iowan Old Style', 'Seravek', 'PingFang SC', 'Hiragino Sans', 'Apple SD Gothic Neo', 'Apple Color Emoji'];
  const candidates = ['Times', 'Times New Roman', 'Helvetica', 'Courier', 'Courier New', 'Apple Chancery',
    'Snell Roundhand', 'Papyrus', 'Comic Sans MS', 'Impact'];
  return {
    present: families.map((family) => family + ':' + (present(family) ? 'y' : 'n')).join(','),
    generics: [...generics, 'cursive', 'fantasy'].map((g) => g + '=' + (candidates
      .filter((family) => present(family) && width('"' + family + '"') === width(g)).join('|') || '?')).join(','),
  };
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
safe('safariShape', () => {
  if (typeof window.safari === 'undefined') return 'undefined';
  const d = Object.getOwnPropertyDescriptor(window, 'safari');
  const push = window.safari.pushNotification;
  const proto = push ? Object.getPrototypeOf(push) : null;
  return [d ? ['w', d.writable, 'e', d.enumerable, 'c', d.configurable].join('') : 'inherited',
          proto ? Object.getOwnPropertyNames(proto).join('+') : 'no-proto',
          proto ? String(Object.getPrototypeOf(proto) === Object.prototype) : '-',
          push ? Object.getOwnPropertyNames(push).join('+') : '-',
          push && typeof push.permission === 'function' ? JSON.stringify(push.permission('web.example.test')) : '-'].join('|');
});
safe('webkitObject', () => typeof window.webkit);
safe('windowOwnCount', () => Object.getOwnPropertyNames(window).length);
// Which globals exist (sorted: the order depends on what the page touched first). Two engines'
// lists differ by what each has; scripts/device_reference.py --compare prints the difference.
safe('windowNames', () => Object.getOwnPropertyNames(window).sort().join(','));

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

// Behaviour: what a page finds by trying rather than by looking, where Safari and a WKWebView app
// differ even when every object is the same: autoplay without a gesture, pop-ups, the permission
// states, storage, media devices, Apple Pay and Push, display media queries. Nothing here asks for
// a permission, shows a dialog or registers anything. Each check has a time limit ("timeout");
// globalThis.__probeStep, when the page defines it, hears each check's name before it runs and
// its duration and value after (scripts/device_reference.py shows them).
const BEHAVIOR_TIMEOUT = 3000;
// 0.5 s, 16 x 16, H.264 and AAC (an audio track: autoplay treats it as media with sound).
const TINY_MP4 = 'data:video/mp4;base64,AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAXdbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAfQAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwAAAnJ0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAfQAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAH0AAAAAAABAAAAAAHqbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAFABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABlW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAVVzdGJsAAAAuXN0c2QAAAAAAAAAAQAAAKlhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFUxhdmM2MC4zMS4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAAL2F2Y0MBQsAK/+EAFmdCwArZHsBEAAADAAQAAAMAUDxImSABAAZoy4BlLIAAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAAqgAAAKoAAAAAYc3R0cwAAAAAAAAABAAAABQAABAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNjAAAAAAAAAAEAAAABAAAAAQAAAAEAAAAoc3RzegAAAAAAAAAAAAAABQAAAoMAAAAJAAAACgAAAAkAAAAJAAAAJHN0Y28AAAAAAAAABQAABqAAAAppAAALVQAADDYAAA0LAAAClXRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAIAAAAAAAAB9AAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAfQAAAQAAAEAAAAAAg1tZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAAFYiAAAvEVXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAAAAAAAAAAAAAAAFNvdW5kSGFuZGxlcgAAAAG4bWluZgAAABBzbWhkAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAF8c3RibAAAAH5zdHNkAAAAAAAAAAEAAABubXA0YQAAAAAAAAABAAAAAAAAAAAAAQAQAAAAAFYiAAAAAAA2ZXNkcwAAAAADgICAJQACAASAgIAXQBUAAAAAAEqSAABKkgWAgIAFE4hW5QAGgICAAQIAAAAUYnRydAAAAAAAAEqSAABKkgAAACBzdHRzAAAAAAAAAAIAAAALAAAEAAAAAAEAAAMRAAAANHN0c2MAAAAAAAAAAwAAAAEAAAABAAAAAQAAAAIAAAADAAAAAQAAAAMAAAACAAAAAQAAAERzdHN6AAAAAAAAAAAAAAAMAAAAkwAAAIMAAABnAAAAXAAAAIwAAABXAAAAhgAAAFEAAAB8AAAAUAAAAF8AAABaAAAAKHN0Y28AAAAAAAAABgAABg0AAAkjAAAKcgAAC18AAAw/AAANFAAAABpzZ3BkAQAAAHJvbGwAAAACAAAAAf//AAAAHHNiZ3AAAAAAcm9sbAAAAAEAAAAMAAAAAQAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjAuMTYuMTAwAAAACGZyZWUAAAfIbWRhdN4CAExhdmM2MC4zMS4xMDIAAliiVFIi/td1nPv+u/xKePjealTVJCwxWJxWJxWJ491U0ZVMa1Xa1ZbFibNxnj8NvulVGrClClTtirMlWZJ9bKVRlUZXGSgYG/o39GBgYGBgYGBgYGBjZsGBkSIGBgYGBkSKWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWXgAAAnEGBf//bdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjQgcjMxMDggMzFlMTlmOSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjMgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTI1MCBrZXlpbnRfbWluPTEwIHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj01MS4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAACmWIhA3yYoAAgR4BEpLaynNkubJc2S5f/0//v8dXL17//1v/f664u9fn/+r/8/fri9a/j/+r/9vjrWp0Hb2kwyDAwMDAzolT1+pivYTi2BGRjEaiKjXFR9IqPpFR9N3EqDfTXxiMs5uNT8kb0pgJtRGZFGyKN6KN6IPRRAPMiijDzIDXQmKnnnnnn+XNwAEe8RkQUqst9sni/t8/49rnTUtNVLtpK1AdLY4zI7u7uIM1VJabfXizWSZrITP/HwZPv7kPj4bHv7wjJ8Zhn9yD/wYO+8If+Gw77wj4+Mwz++gH+MwT76A/kzBfvoD/wYJ0aAj44cAA6jEQ9lJ5nVTvE+f/7Nf/P8la1l86yRe2syQXipEiRI6zYHOgb4QP6sg7OODgZ7v06WaXosXnMXnLgzSxEQS6lBYpQoyfPsc9ulHoBsl8RgMy2S88hQqCkL7vPwAAAAVBmjgb6gE+MQAsaysJGsSAoJ//+36zjN//3t/+f/W++MjvWjLkkulAA433CiwuXi1wSD6ICnLNEjlkB8oNLQGWeVQYk+GFgw8e9IYeweDNvDih7ylwDAx7zpT2FcdmNnnEjhvXqXOcL6RIEYoeULHARzCpBUuNU8xbymXGd28UyKe1jtGJNdg2Q/tQHlojDnnAAPAxETIxs1k93e5/+H2/6/83bWdYzju5XPUrm7EQNGjVLLL/Q5/K/36PiYItWrVq1NXWsOquOvirNw/OlUq4U5VnnvKQuzNMM5mnmhXE12P3DXMBW2ngAAAABkGaVAZ6gAE+MQAkWzMQlsSAsJ//436aP/7P2/9v+W+OYqSKs6qEA+OiiheqtqNc5c2rqxHQCz1qFeSg4I0rSUVIKBRIz0UUGooMZawuRM0EDRhQytcrKGvXoUAAx+SS+JHbZFbDWwVqWRgAmjAirkw2FPOkPqH0rzpUicnZyEGupQjCEqnpptOwQ7dPAPAxCsLEk+034+f/7X6f+//7uIb6rvzTnp31M9fAI0o+SPl8vkd+MwMPl8vlsq2cQhA2FlCIbptR/p3QUr6FAIlPjqUuruKriwrtr2VUJau3AAAABUGaYDPUAT4xAChrKhhQomIgn//mfKtc//xev/n/O9Nyb4yCS5Kqw5pLdE65c0RiW5SvocmCUpkGmFDa+elTmqTmiQm601D0ZWudnDtSzx1dZyqsthmkwH9uArUTPDoLVDWoykyAQOSqokld7klQUf5KF1rSNU5Wapbz7jCOrc/pvADsMQqi1vr33XPj5//tfP/8P/WpWl0q6qPXsePjA9XzHPPPOc6ow3OeedSlTnO0N51RroroXz0pTQUxXWpQTtdEpvUtFVxGUV+WijeFrceAAAAABUGagC/UATIxC+NRVMz/X5/++uNS4kkkXJLSDu6e7Dsvqv6ks33dRV49Pdh2X1bd90emvGvuwkwqvqvjuj0141pwkvqvquju6sa8emTCS+q/ftj09WNcWHdh2X1Xx3R6erGvuw4BTDEL41F1Wc+/P89au5JFyRJJJIGmKb5ufmgOmH/Lcachbh5+aCbc+6+040yFuHnmgm3PuvtONMU3CaaCZL7qGnFMhbhNNBM6+txpxpkLfNBNAd191xpxTOA=';
const behavior = async () => {
  const out = {};
  const hook = typeof globalThis.__probeStep === 'function' ? globalThis.__probeStep : null;
  const tell = (...args) => { if (hook) { try { hook(...args); } catch (e) { /* the page's own problem */ } } };
  const sleep = (ms, value) => new Promise((resolve) => setTimeout(() => resolve(value), ms));
  const check = async (key, run) => {
    tell(key);
    const started = Date.now();
    let timer;
    try {
      out[key] = await Promise.race([Promise.resolve().then(run),
        new Promise((resolve) => { timer = setTimeout(() => resolve('timeout'), BEHAVIOR_TIMEOUT); })]);
    } catch (e) {
      out[key] = 'error: ' + ((e && e.name) || String(e));
    } finally {
      clearTimeout(timer);
      tell(key, Date.now() - started, out[key]);
    }
  };

  // Autoplay: play() without a gesture, muted and with sound; AudioContext.resume() likewise.
  const play = (muted) => async () => {
    const video = document.createElement('video');
    video.muted = muted;
    video.defaultMuted = muted;
    video.playsInline = true;
    video.src = TINY_MP4;
    try {
      await video.play();
      return 'resolved';
    } catch (e) {
      return 'rejected: ' + e.name;
    } finally {
      video.pause();
      video.removeAttribute('src');
      video.load();
    }
  };
  await check('autoplayMuted', play(true));
  await check('autoplaySound', play(false));
  await check('audioContextResume', async () => {
    const Context = window.AudioContext || window.webkitAudioContext;
    if (!Context) return 'absent';
    const context = new Context();
    const before = context.state;
    try {
      const answer = await Promise.race([context.resume().then(() => 'resolved', (e) => 'rejected: ' + e.name), sleep(1500, 'pending')]);
      return before + '>' + answer + '>' + context.state;
    } finally {
      context.close().catch(() => {});
    }
  });

  // Pop-ups: window.open without a gesture (a window is closed at once).
  await check('windowOpen', () => {
    const opened = window.open('about:blank', '_blank', 'width=120,height=120');
    if (!opened) return 'null';
    try { opened.close(); } catch (e) { /* closed already */ }
    return 'window';
  });

  // Permission states, without asking.
  await check('notificationPermission', () => (typeof Notification === 'undefined' ? 'absent' : Notification.permission));
  const permissions = [['notifications', { name: 'notifications' }], ['geolocation', { name: 'geolocation' }],
    ['camera', { name: 'camera' }], ['microphone', { name: 'microphone' }],
    ['persistentStorage', { name: 'persistent-storage' }], ['push', { name: 'push', userVisibleOnly: true }]];
  for (const [key, descriptor] of permissions) {
    await check('permission.' + key, async () => {
      if (!navigator.permissions || !navigator.permissions.query) return 'absent';
      try {
        return (await navigator.permissions.query(descriptor)).state;
      } catch (e) {
        return 'rejected: ' + e.name;
      }
    });
  }

  // Storage.
  await check('storagePersisted', async () => (navigator.storage && navigator.storage.persisted
    ? String(await navigator.storage.persisted()) : 'absent'));
  await check('storageEstimate', async () => {
    if (!navigator.storage || !navigator.storage.estimate) return 'absent';
    const estimate = await navigator.storage.estimate();
    // The quota follows the disk; in GB, and only whether something is stored.
    return 'quota ' + (estimate.quota === undefined ? '?' : (estimate.quota / 1e9).toFixed(1) + ' GB')
      + ', usage ' + (estimate.usage ? '>0' : '0');
  });
  await check('hasStorageAccess', async () => (document.hasStorageAccess
    ? String(await document.hasStorageAccess()) : 'absent'));

  // Media devices, without a permission: how many of each kind, and whether labels show.
  await check('mediaDevices', async () => {
    if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return 'absent';
    const devices = await navigator.mediaDevices.enumerateDevices();
    const kinds = {};
    for (const device of devices) kinds[device.kind] = (kinds[device.kind] || 0) + 1;
    return (Object.keys(kinds).sort().map((kind) => kind + ':' + kinds[kind]).join(',') || 'none')
      + (devices.some((device) => device.label) ? ' (labels)' : ' (no labels)')
      + (devices.some((device) => device.deviceId) ? ' (ids)' : ' (no ids)');
  });

  // Apple Pay and Web Push, where they exist: only what answers without a dialog.
  await check('applePayCanMakePayments', () => {
    if (typeof ApplePaySession === 'undefined') return 'absent';
    try { return String(ApplePaySession.canMakePayments()); } catch (e) { return 'throws: ' + e.name; }
  });
  await check('applePayVersions', () => {
    if (typeof ApplePaySession === 'undefined') return 'absent';
    const versions = [];
    for (let version = 3; version <= 14; version++) {
      try { if (ApplePaySession.supportsVersion(version)) versions.push(version); } catch (e) { return 'throws: ' + e.name; }
    }
    return versions.join(',') || 'none';
  });
  await check('pushContentEncodings', () => (typeof PushManager === 'undefined' ? 'absent'
    : String(PushManager.supportedContentEncodings)));

  // Display media queries.
  const query = (feature, values) => values.filter((value) => matchMedia('(' + feature + ': ' + value + ')').matches).join('|') || 'none';
  await check('media.displayMode', () => query('display-mode', ['standalone', 'fullscreen', 'minimal-ui', 'browser']));
  await check('media.reducedMotion', () => query('prefers-reduced-motion', ['reduce', 'no-preference']));
  await check('media.contrast', () => query('prefers-contrast', ['more', 'less', 'custom', 'no-preference']));
  await check('media.invertedColors', () => query('inverted-colors', ['inverted', 'none']));
  return out;
};

return behavior().then((answers) => { result.behavior = answers; return result; },
                       (e) => { result.behavior = { error: String(e) }; return result; });
