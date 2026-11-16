// The page shim as the app gives it to a session's pages (node ios/shim/test-page-shim.mjs, or bun;
// ios/scripts/ci.sh runs it): ios/Lumen/Resources/page-shim.js wrapped as PageSettings.script wraps
// it, with a configuration of PageSettings.ShimConfig's shape, in realms shaped like WebKit's windows
// (a stand-in DOM: methods and accessors on the prototypes, as WebKit has them, and an engine whose
// own work no page sees). What is checked is what a page can learn by calling what the engine lets
// it call — each against the same page without the shim, which is what Safari answers:
//   - nothing hands a page the shim's registry (Function.prototype.toString with a well-known symbol
//     throws its TypeError), and printing a function calls nothing the page can replace;
//   - a page and its frame are one family when the runtime gives a channel (PageSettings.makeChannel):
//     each window's Function.prototype.toString prints the other's replacements as native. Without
//     one each window is a family of its own, which the same check tells (the control);
//   - the canvas and audio noise (ios/shim/fingerprint.js) calls none of the DOM methods and built-ins
//     a page can replace while toDataURL, toBlob, convertToBlob, getImageData, getChannelData or
//     copyFromChannel runs, and a page that makes them throw still gets the noised canvas.
// The Mac's own body is tested in full by scripts/test-shims.mjs; this is the iPhone's build of it.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

// The engine's zone, whatever the environment says: the shim replaces Date only where the engine is
// not in the session's zone already (node and bun follow process.env.TZ as it changes).
process.env.TZ = 'America/New_York';

const body = fs.readFileSync(new URL('../Lumen/Resources/page-shim.js', import.meta.url), 'utf8');
// PageSettings.script: "(function install(CONFIG) {\n" + body + "\n})(" + json + ");"
const wrapped = (config) => '(function install(CONFIG) {\n' + body + '\n})(' + JSON.stringify(config) + ');';

// PageSettings.config of a new session (Models.swift: canvas, WebGL and audio with noise) behind a
// proxy in Tokyo, with its runtime's channel (makeChannel: a UUID, lowercased). JSONEncoder leaves
// out what is nil (storageQuota).
const CHANNEL = '3f0c9a52-7d1e-4b8a-9c61-2e5f0b7a4d19';
const session = {
  timeZone: 'Asia/Tokyo', geolocation: { mode: 'deny' }, webRTC: 'disabled', safariObject: false,
  fingerprint: { seed: '8d0e6b1c-5a7f-4e21-b3c9-0f4a2d6e8b17', canvas: 'noise', webgl: 'noise', audio: 'noise',
                 language: 'ja-JP', unstable: false, naive: false, lowBit: false },
  channel: CHANNEL,
};
const allReal = { ...session, timeZone: null, fingerprint: { ...session.fingerprint, canvas: 'real', webgl: 'real', audio: 'real', language: null } };

// What the engine keeps to itself, whatever the realm: the event listeners of each target (a page
// cannot list them), and whether engine code is running — a page's replacement of a built-in counts
// its calls only from script, never from inside the engine (in WebKit natives call no script).
const engine = { listeners: new WeakMap(), depth: 0 };

// The stand-in DOM of one window, run in its realm before the shim.
const DOM = String.raw`
(() => {
  const engine = globalThis.__engine;
  delete globalThis.__engine;
  const R = Reflect.apply, defineProperty = Object.defineProperty, ownDescriptor = Object.getOwnPropertyDescriptor;
  const ownKeys = Reflect.ownKeys, create = Object.create, NativeTypeError = TypeError, NativeString = String;
  const imul = Math.imul, min = Math.min, sin = Math.sin; // the engine's C++, which no page reaches
  // An engine function: what runs inside it is the engine's.
  const native = (fn) => function (...args) { engine.depth++; try { return R(fn, this, args); } finally { engine.depth--; } };
  const nativeMembers = (C) => {
    for (const key of ownKeys(C.prototype)) {
      if (key === 'constructor') continue;
      const d = ownDescriptor(C.prototype, key);
      if (d.get) d.get = native(d.get);
      if (d.set) d.set = native(d.set);
      if (typeof d.value === 'function') d.value = native(d.value);
      defineProperty(C.prototype, key, d);
    }
    return C;
  };
  const expose = (C) => defineProperty(globalThis, C.name, { value: nativeMembers(C), writable: true, configurable: true });
  const slot = (map, o) => { const s = map.get(o); if (!s) throw new NativeTypeError('Illegal invocation'); return s; };

  // Events, as far as the shim's family reaches them: a window and its proxy are one target, and an
  // event is handed to the listeners of its type.
  const targetOf = (t) => (t !== null && typeof t === 'object' && t.window ? t.window : t);
  class EventTarget {
    addEventListener(type, listener) {
      const target = targetOf(this);
      if (!engine.listeners.has(target)) engine.listeners.set(target, []);
      engine.listeners.get(target).push([NativeString(type), listener]);
    }
    dispatchEvent(event) {
      for (const [type, listener] of engine.listeners.get(targetOf(this)) || []) if (type === event.type) R(listener, this, [event]);
      return true;
    }
  }
  class Event { constructor(type) { defineProperty(this, 'type', { value: NativeString(type), enumerable: true }); } }
  expose(EventTarget);
  globalThis.Event = Event;

  // Canvases (a page's and an OffscreenCanvas) and their 2D contexts, over one pixel store.
  const canvases = new WeakMap(), contexts = new WeakMap(), images = new WeakMap(), buffers = new WeakMap();
  // Each kind's own receiver check (a page's canvas is no OffscreenCanvas, and the other way round).
  const pageCanvases = new WeakSet(), offscreens = new WeakSet();
  const branded = (set, o) => { if (!set.has(o)) throw new NativeTypeError('Illegal invocation'); return o; };
  const newCanvas = (proto, width, height) => {
    const c = create(proto);
    canvases.set(c, { width, height, px: new Uint8ClampedArray(width * height * 4), context: null });
    pageCanvases.add(c);
    return c;
  };
  const digest = (px) => { let h = 2166136261; for (let i = 0; i < px.length; i++) h = imul(h ^ px[i], 16777619) >>> 0; return h.toString(16); };
  const sized = (s) => { s.px = new Uint8ClampedArray(s.width * s.height * 4); };
  class Node extends EventTarget {}
  class Element extends Node {}
  class HTMLElement extends Element {}
  class ImageData {
    get data() { return slot(images, this).data; }
    get width() { return slot(images, this).width; }
    get height() { return slot(images, this).height; }
  }
  const newImage = (width, height, data) => { const i = create(ImageData.prototype); images.set(i, { width, height, data }); return i; };
  const contextMembers = {
    getImageData(x, y, width, height) {
      const c = slot(canvases, slot(contexts, this));
      if (x !== 0 || y !== 0 || width !== c.width || height !== c.height) throw new Error('the stand-in reads whole canvases only');
      return newImage(width, height, c.px.slice());
    },
    putImageData(image, x, y) { slot(canvases, slot(contexts, this)).px.set(slot(images, image).data); },
    drawImage(source, x, y) {
      const c = slot(canvases, slot(contexts, this)), s = slot(canvases, source);
      c.px.set(s.px.subarray(0, min(s.px.length, c.px.length)));
    },
    // Text's antialiased edges: every alpha but 0 and 255.
    fillText(text, x, y) {
      const c = slot(canvases, slot(contexts, this));
      for (let i = 0; i < c.px.length; i += 4) { c.px[i] = 40; c.px[i + 1] = 90; c.px[i + 2] = 200; c.px[i + 3] = 1 + ((i >> 2) % 254); }
    },
  };
  class CanvasRenderingContext2D {}
  class OffscreenCanvasRenderingContext2D {}
  for (const C of [CanvasRenderingContext2D, OffscreenCanvasRenderingContext2D]) {
    for (const key of ownKeys(contextMembers)) defineProperty(C.prototype, key, { value: contextMembers[key], writable: true, configurable: true });
  }
  const canvasMembers = (Context) => ({
    get width() { return slot(canvases, this).width; },
    set width(v) { const s = slot(canvases, this); s.width = v >>> 0; sized(s); },
    get height() { return slot(canvases, this).height; },
    set height(v) { const s = slot(canvases, this); s.height = v >>> 0; sized(s); },
    getContext(kind) {
      const s = slot(canvases, this);
      if (NativeString(kind) !== '2d') return null;
      if (!s.context) { s.context = create(Context.prototype); contexts.set(s.context, this); }
      return s.context;
    },
  });
  class HTMLCanvasElement extends HTMLElement {
    toDataURL() { return 'data:image/png;digest=' + digest(slot(canvases, branded(pageCanvases, this)).px); }
    toBlob(callback) { R(callback, undefined, ['blob;digest=' + digest(slot(canvases, branded(pageCanvases, this)).px)]); }
  }
  class OffscreenCanvas {
    constructor(width, height) {
      engine.depth++;
      try {
        canvases.set(this, { width: width >>> 0, height: height >>> 0, px: new Uint8ClampedArray((width >>> 0) * (height >>> 0) * 4), context: null });
        offscreens.add(this);
      } finally { engine.depth--; }
    }
    // A promise-returning operation rejects a wrong receiver rather than throw (WebIDL).
    convertToBlob() {
      try { return Promise.resolve('blob;digest=' + digest(slot(canvases, branded(offscreens, this)).px)); }
      catch (e) { return Promise.reject(e); }
    }
  }
  for (const [C, Context] of [[HTMLCanvasElement, CanvasRenderingContext2D], [OffscreenCanvas, OffscreenCanvasRenderingContext2D]]) {
    const members = canvasMembers(Context);
    for (const key of ownKeys(members)) defineProperty(C.prototype, key, ownDescriptor(members, key));
  }
  // A rendered AudioBuffer (as OfflineAudioContext gives one): its channels' data, the same array each time.
  class AudioBuffer {
    constructor(options) {
      const data = new Float32Array(options.length);
      for (let i = 0; i < data.length; i++) data[i] = sin(i / 7) * 0.5;
      buffers.set(this, [data]);
    }
    getChannelData(channel) { const d = slot(buffers, this)[channel]; if (!d) throw new RangeError('Index out of range'); return d; }
    copyFromChannel(destination, channel) { const d = slot(buffers, this)[channel]; destination.set(d.subarray(0, destination.length)); }
  }
  class Document extends Node {
    createElement(tag) { return NativeString(tag).toLowerCase() === 'canvas' ? newCanvas(HTMLCanvasElement.prototype, 300, 150) : create(HTMLElement.prototype); }
  }
  for (const C of [Node, Element, HTMLElement, ImageData, CanvasRenderingContext2D, OffscreenCanvasRenderingContext2D,
                   HTMLCanvasElement, OffscreenCanvas, AudioBuffer, Document]) expose(C);
  // A window's document is [LegacyUnforgeable]: an own accessor no page can replace.
  const document = create(Document.prototype);
  defineProperty(globalThis, 'document', { get: native(() => document), enumerable: true, configurable: false });
  // For the tests' spies only (the shim does not look): whether the engine is running.
  defineProperty(globalThis, '__engineRunning', { value: () => engine.depth > 0 });
})();
`;

// A window: its realm, its stand-in DOM, its parent (a frame's) — and the shim, unless config is null.
function makeWindow(config, parentWindow) {
  const context = vm.createContext({});
  context.__engine = engine;
  vm.runInContext('var window = globalThis; var self = globalThis;', context);
  const window = vm.runInContext('globalThis', context);
  // As WebKit: a top window is its own parent; a frame's parent is the window above it.
  Object.defineProperty(window, 'parent', { value: parentWindow || window, enumerable: true, configurable: true });
  Object.defineProperty(window, 'opener', { value: null, writable: true, enumerable: true, configurable: true });
  vm.runInContext(DOM, context);
  if (config !== null) vm.runInContext(wrapped(config), context);
  return { context, window, run: (code) => vm.runInContext(code, context) };
}

// A page's spies: each named built-in replaced by a function that notes, when script (not the engine)
// calls it, and then does what it did. Installed after the page took what it needs; R is the page's.
const SPIES = String.raw`
  const R = Reflect.apply, defineProperty = Object.defineProperty, ownDescriptor = Object.getOwnPropertyDescriptor, getProto = Object.getPrototypeOf;
  const seen = [];
  const spy = (label, original) => {
    const f = function (...args) { if (!__engineRunning()) seen[seen.length] = label; return R(original, this, args); };
    return f;
  };
  const spyOn = (holder, key, label) => {
    const d = ownDescriptor(holder, key);
    if (!d) return;
    if (d.get) d.get = spy(label + ' (get)', d.get);
    if (d.set) d.set = spy(label + ' (set)', d.set);
    if (typeof d.value === 'function') d.value = spy(label, d.value);
    defineProperty(holder, key, d);
  };
  const spyAll = (list) => { for (let i = 0; i < list.length; i++) spyOn(list[i][0], list[i][1], list[i][2]); };
`;

const results = [];
function test(name, fn) {
  try { fn(); results.push(['ok', name]); } catch (e) { results.push(['FAIL', name, e]); }
}

// ---- The registry -------------------------------------------------------------------------------

const REGISTRY_PROBE = String.raw`(() => {
  try { const r = Function.prototype.toString.call(Symbol.for('wk.shim.registry')); return 'returned ' + Object.prototype.toString.call(r); }
  catch (e) { return 'threw ' + e.constructor.name; }
})()`;

test('a page asking Function.prototype.toString for the registry gets the engine\'s TypeError, as without the shim', () => {
  const safari = makeWindow(null).run(REGISTRY_PROBE);
  assert.equal(safari, 'threw TypeError');
  for (const config of [session, allReal]) assert.equal(makeWindow(config).run(REGISTRY_PROBE), safari, JSON.stringify(config.fingerprint));
});

test('printing a function, its own or a replacement, calls nothing a page can replace', () => {
  const page = String.raw`(() => {
    ${SPIES}
    const toString = Function.prototype.toString, own = function own() {};
    spyAll([[WeakMap.prototype, 'get', 'WeakMap.get'], [WeakMap.prototype, 'has', 'WeakMap.has'],
            [Function.prototype, 'call', 'Function.call'], [Function.prototype, 'apply', 'Function.apply'],
            [Reflect, 'apply', 'Reflect.apply'], [Object, 'getOwnPropertyDescriptor', 'Object.getOwnPropertyDescriptor']]);
    const printed = [R(toString, own, []), R(toString, Date, []), R(toString, toString, [])];
    return JSON.stringify({ seen, printed: printed.slice(1) });
  })()`;
  const safari = JSON.parse(makeWindow(null).run(page));
  assert.deepEqual(safari.seen, []);
  const shimmed = JSON.parse(makeWindow(session).run(page));
  assert.deepEqual(shimmed.seen, [], 'the page saw the shim call its replacements');
  assert.deepEqual(shimmed.printed, ['function Date() { [native code] }', 'function toString() { [native code] }']);
});

// ---- One family: a page and its frame ------------------------------------------------------------

const NATIVE_DATE = 'function Date() { [native code] }';
const printedBy = (printer, target) => printer.run('Function.prototype.toString.call(__other.Date)');

test('with the runtime\'s channel a page and its frame are one family: each prints the other\'s replaced Date as native', () => {
  const page = makeWindow(session);
  const frame = makeWindow(session, page.window);
  page.context.__other = frame.window;
  frame.context.__other = page.window;
  assert.notEqual(page.run('Date'), frame.run('Date'), 'each window has its own Date');
  assert.equal(page.run('Function.prototype.toString.call(Date)'), NATIVE_DATE);
  assert.equal(printedBy(frame, page), NATIVE_DATE, 'the frame prints its parent\'s Date');
  assert.equal(printedBy(page, frame), NATIVE_DATE, 'the page prints its frame\'s Date');
  assert.equal(frame.run(REGISTRY_PROBE), 'threw TypeError');
});

test('without a channel (the control) a frame is a family of its own and prints its parent\'s Date as no engine would', () => {
  for (const channel of ['', undefined]) {
    const config = { ...session, channel };
    const page = makeWindow(config);
    const frame = makeWindow(config, page.window);
    frame.context.__other = page.window;
    assert.equal(frame.run('Function.prototype.toString.call(Date)'), NATIVE_DATE, 'its own Date prints as native');
    assert.notEqual(printedBy(frame, page), NATIVE_DATE, `channel ${JSON.stringify(channel)}: the check would not see a broken family`);
  }
});

test('a window of another channel (another session, or a launch before) is not let into the family', () => {
  const page = makeWindow(session);
  const frame = makeWindow({ ...session, channel: 'another-runtime' }, page.window);
  frame.context.__other = page.window;
  assert.notEqual(printedBy(frame, page), NATIVE_DATE);
});

// ---- The canvas and audio noise ----------------------------------------------------------------

// The page draws, then counts what is called while it reads its canvas and audio back.
const READ_BACK = String.raw`(() => {
  const canvas = document.createElement('canvas');
  canvas.width = 32; canvas.height = 8;
  const context = canvas.getContext('2d');
  context.fillText('Lumen', 0, 0);
  const offscreen = new OffscreenCanvas(32, 8);
  offscreen.getContext('2d').fillText('Lumen', 0, 0);
  const buffer = new AudioBuffer({ length: 4096, numberOfChannels: 1, sampleRate: 44100 });
  ${SPIES}
  const TypedArray = getProto(Uint8Array.prototype), ArrayIterator = getProto([][Symbol.iterator]());
  spyAll([
    [Document.prototype, 'createElement', 'createElement'],
    [HTMLCanvasElement.prototype, 'getContext', 'getContext'], [HTMLCanvasElement.prototype, 'width', 'canvas.width'],
    [HTMLCanvasElement.prototype, 'height', 'canvas.height'],
    [OffscreenCanvas.prototype, 'getContext', 'OffscreenCanvas.getContext'], [OffscreenCanvas.prototype, 'width', 'OffscreenCanvas.width'],
    [OffscreenCanvas.prototype, 'height', 'OffscreenCanvas.height'],
    [CanvasRenderingContext2D.prototype, 'drawImage', 'drawImage'], [CanvasRenderingContext2D.prototype, 'putImageData', 'putImageData'],
    [OffscreenCanvasRenderingContext2D.prototype, 'drawImage', 'offscreen drawImage'],
    [OffscreenCanvasRenderingContext2D.prototype, 'putImageData', 'offscreen putImageData'],
    [ImageData.prototype, 'data', 'ImageData.data'],
    [TypedArray, 'length', 'TypedArray.length'], [TypedArray, 'fill', 'TypedArray.fill'], [TypedArray, 'set', 'TypedArray.set'],
    [Math, 'imul', 'Math.imul'], [Math, 'min', 'Math.min'], [Math, 'floor', 'Math.floor'], [Math, 'random', 'Math.random'],
    [WeakSet.prototype, 'has', 'WeakSet.has'], [WeakSet.prototype, 'add', 'WeakSet.add'],
    [WeakMap.prototype, 'get', 'WeakMap.get'], [WeakMap.prototype, 'has', 'WeakMap.has'],
    [Function.prototype, 'call', 'Function.call'], [Function.prototype, 'apply', 'Function.apply'], [Reflect, 'apply', 'Reflect.apply'],
    [Object, 'getOwnPropertyDescriptor', 'Object.getOwnPropertyDescriptor'], [Object, 'defineProperty', 'Object.defineProperty'],
    [Array.prototype, Symbol.iterator, 'Array[Symbol.iterator]'], [ArrayIterator, 'next', 'ArrayIterator.next'],
    [globalThis, 'String', 'String'],
  ]);
  const read = {};
  read.dataURL = canvas.toDataURL();
  canvas.toBlob((blob) => { read.blob = blob; });
  context.getImageData(0, 0, 32, 8);
  offscreen.convertToBlob();
  const samples = buffer.getChannelData(0);
  const copied = new Float32Array(4096);
  buffer.copyFromChannel(copied, 0);
  read.seen = seen;
  // As text: the page's own arrays iterate with its spied iterator.
  return JSON.stringify(read);
})()`;

test('reading a canvas or a buffer back calls nothing a page can replace, as without the shim', () => {
  const safari = JSON.parse(makeWindow(null).run(READ_BACK));
  assert.deepEqual(safari.seen, [], 'the stand-in itself calls a spy: the check would see nothing');
  for (const mode of ['noise', 'off']) {
    const config = { ...session, fingerprint: { ...session.fingerprint, canvas: mode, audio: mode, webgl: mode } };
    const shimmed = JSON.parse(makeWindow(config).run(READ_BACK));
    assert.deepEqual(shimmed.seen, [], `${mode}: the page saw the shim call ${[...new Set(shimmed.seen)].join(', ')}`);
    assert.notEqual(shimmed.dataURL, safari.dataURL, `${mode}: toDataURL is not the canvas as drawn`);
  }
});

// The same canvas read back: normally, then with each method the copy needs made to throw.
const BROKEN = String.raw`(() => {
  const canvas = document.createElement('canvas');
  canvas.width = 32; canvas.height = 8;
  canvas.getContext('2d').fillText('Lumen', 0, 0);
  const R = Reflect.apply, defineProperty = Object.defineProperty, ownDescriptor = Object.getOwnPropertyDescriptor;
  const normal = canvas.toDataURL();
  const breakIt = (holder, key) => {
    const d = ownDescriptor(holder, key);
    const fail = function () { throw new Error('broken by the page'); };
    if (d.get) d.get = fail; else d.value = fail;
    defineProperty(holder, key, d);
  };
  breakIt(Document.prototype, 'createElement');
  breakIt(HTMLCanvasElement.prototype, 'getContext');
  breakIt(CanvasRenderingContext2D.prototype, 'drawImage');
  breakIt(CanvasRenderingContext2D.prototype, 'putImageData');
  breakIt(ImageData.prototype, 'data');
  breakIt(Math, 'imul');
  return JSON.stringify({ normal, broken: canvas.toDataURL() });
})()`;

test('a page that breaks createElement, getContext, drawImage, putImageData or ImageData.data still gets the noised canvas', () => {
  const safari = JSON.parse(makeWindow(null).run(BROKEN));
  const shimmed = JSON.parse(makeWindow(session).run(BROKEN));
  assert.notEqual(shimmed.normal, safari.normal, 'the canvas is noised');
  assert.equal(shimmed.broken, shimmed.normal, 'with its methods broken the page read the canvas without the noise');
});

test('the audio noise reaches the samples, once, whichever way they are read', () => {
  const read = (config) => makeWindow(config).run(String.raw`(() => {
    const buffer = new AudioBuffer({ length: 4096, numberOfChannels: 1, sampleRate: 44100 });
    const first = Array.from(buffer.getChannelData(0)), again = Array.from(buffer.getChannelData(0));
    const copied = new Float32Array(4096);
    const other = new AudioBuffer({ length: 4096, numberOfChannels: 1, sampleRate: 44100 });
    other.copyFromChannel(copied, 0);
    return JSON.stringify({ first, again, copied: Array.from(copied) });
  })()`);
  const safari = JSON.parse(read(null)), shimmed = JSON.parse(read(session));
  const changed = shimmed.first.filter((v, i) => v !== safari.first[i]).length;
  assert.ok(changed > 0, 'no sample changed');
  assert.deepEqual(shimmed.again, shimmed.first, 'a second read noised the samples again');
  assert.deepEqual(shimmed.copied, shimmed.first, 'copyFromChannel gives what getChannelData gives');
});

// An OffscreenCanvas is copied into an OffscreenCanvas: convertToBlob gives the noised picture. (Until
// 16 November its copy was a page's canvas, which OffscreenCanvas's convertToBlob refuses: the page's
// promise was rejected wherever the noise was on.)
{
  const blobOf = (config) => makeWindow(config).run(String.raw`(() => {
    const offscreen = new OffscreenCanvas(32, 8);
    offscreen.getContext('2d').fillText('Lumen', 0, 0);
    return offscreen.convertToBlob().then((blob) => 'resolved ' + blob, (e) => 'rejected ' + e.name);
  })()`);
  const [safari, noised] = await Promise.all([blobOf(null), blobOf(session)]);
  test('an OffscreenCanvas\'s convertToBlob resolves, with the noise', () => {
    assert.match(safari, /^resolved /);
    assert.match(noised, /^resolved /);
    assert.notEqual(noised, safari);
  });
}

// ---- End --------------------------------------------------------------------------------------------

let failed = 0;
for (const [status, name, error] of results) {
  console.log(`${status} ${name}`);
  if (error) { failed++; console.log('   ', String(error && error.stack || error).split('\n').slice(0, 6).join('\n    ')); }
}
if (failed) { console.log(`page shim: ${failed} of ${results.length} failed`); process.exit(1); }
console.log(`page shim: all ${results.length} checks pass`);
