// The body of an async function: what a page sees of window.browser (WebKit's WebPageNamespace in
// Safari, 8 November: runtime.connect and runtime.sendMessage), and the window's own names.
const out = { ua: navigator.userAgent, secure: isSecureContext, href: location.href };
out.windowOwnCount = Object.getOwnPropertyNames(window).length;
out.inWindow = 'browser' in window;
out.own = Object.prototype.hasOwnProperty.call(window, 'browser');
out.typeofBrowser = typeof window.browser;
out.typeofChrome = typeof window.chrome;
out.typeofSafari = typeof window.safari;
try {
  let o = window, where = null;
  while (o) { if (Object.prototype.hasOwnProperty.call(o, 'browser')) { where = o === window ? 'window' : Object.prototype.toString.call(o); break; } o = Object.getPrototypeOf(o); }
  out.definedOn = where;
  const d = where ? Object.getOwnPropertyDescriptor(where === 'window' ? window : o, 'browser') : null;
  out.descriptor = d ? { get: typeof d.get, set: typeof d.set, value: typeof d.value, enumerable: d.enumerable, configurable: d.configurable, writable: d.writable } : null;
} catch (e) { out.descriptorError = String(e); }
const b = window.browser;
if (b) {
  out.tag = Object.prototype.toString.call(b);
  out.names = Object.getOwnPropertyNames(b);
  out.protoNames = Object.getOwnPropertyNames(Object.getPrototypeOf(b) || {});
  try { const r = b.runtime; out.runtimeTag = Object.prototype.toString.call(r); out.runtimeNames = Object.getOwnPropertyNames(Object.getPrototypeOf(r) || {}).concat(Object.getOwnPropertyNames(r));
    out.sendMessage = r && r.sendMessage ? { length: r.sendMessage.length, text: Function.prototype.toString.call(r.sendMessage).slice(0, 80) } : null;
    out.connect = r && r.connect ? { length: r.connect.length, text: Function.prototype.toString.call(r.connect).slice(0, 80) } : null;
    if (r && r.sendMessage) {
      out.sendMessageResult = await new Promise((resolve) => {
        let p; try { p = r.sendMessage('lumen.probe.none', { probe: 1 }); } catch (e) { resolve({ threw: e && e.constructor && e.constructor.name, message: String(e && e.message) }); return; }
        if (!p || typeof p.then !== 'function') { resolve({ returned: typeof p }); return; }
        p.then((v) => resolve({ resolved: JSON.stringify(v) }), (e) => resolve({ rejected: e && e.constructor && e.constructor.name, message: String(e && e.message) }));
        setTimeout(() => resolve({ pending: '5 s' }), 5000);
      });
    }
  } catch (e) { out.runtimeError = String(e); }
}
return JSON.stringify(out);
