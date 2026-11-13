/// The page's side of the WebDriver's commands (`WebDriverExecutor`): what is asked of the page
/// itself — finding elements, reading them, running a client's script — as bodies run in the
/// driver's own world (`PageDriver.world`), which the page cannot see.
///
/// Elements are known to a client by ids made here and kept for the document's life: an id of
/// another document's element is a stale reference, as the protocol says. Every body returns its
/// value as JSON text; a failure is an error whose message begins `PBWD:<the protocol's code>:`.
enum WebDriverScripts {
    /// With each body: the element store, and values to and from the protocol's JSON.
    static let prelude = #"""
const KEY = 'element-6066-11e4-a52e-4f735466cecf';
const S = globalThis.__pbwd || (globalThis.__pbwd = {
  doc: (globalThis.crypto && crypto.randomUUID) ? crypto.randomUUID() : String(Math.random()).slice(2),
  next: 1, byId: new Map(), ids: new WeakMap(),
});
const fail = (code, message) => { throw new Error('PBWD:' + code + ':' + message); };
const idOf = (el) => {
  let id = S.ids.get(el);
  if (!id) {
    id = S.doc + '-' + (S.next++);
    S.ids.set(el, id);
    S.byId.set(id, new WeakRef(el));
  }
  return id;
};
const get = (id) => {
  const ref = S.byId.get(id);
  const el = ref && ref.deref();
  if (!el || !el.isConnected) { fail('stale element reference', 'the element is not in the page any more'); }
  return el;
};
const ser = (value, depth) => {
  depth = depth || 0;
  if (value === undefined || value === null) { return null; }
  if (typeof value === 'function' || typeof value === 'symbol') { return null; }
  if (typeof value === 'bigint') { return String(value); }
  if (typeof value !== 'object') { return value; }
  if (value instanceof Element) { return { [KEY]: idOf(value) }; }
  if (value instanceof Node || value === window) { return null; }
  if (depth > 20) { return null; }
  if (typeof value.toJSON === 'function') { return ser(value.toJSON(), depth + 1); }
  if (Array.isArray(value) || value instanceof NodeList || value instanceof HTMLCollection
      || (typeof value.length === 'number' && typeof value.item === 'function')) {
    return Array.from(value, (item) => ser(item, depth + 1));
  }
  const out = {};
  for (const key of Object.keys(value)) { out[key] = ser(value[key], depth + 1); }
  return out;
};
const de = (value) => {
  if (Array.isArray(value)) { return value.map(de); }
  if (value && typeof value === 'object') {
    if (typeof value[KEY] === 'string') { return get(value[KEY]); }
    const out = {};
    for (const key of Object.keys(value)) { out[key] = de(value[key]); }
    return out;
  }
  return value;
};
const shown = (el) => {
  const r = el.getBoundingClientRect();
  if (r.width <= 0 || r.height <= 0) { return false; }
  const style = getComputedStyle(el);
  return style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
};
const setValue = (el, value) => {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
    : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
  el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
};
"""#

    /// `using`, `value`, `root` (an element's id, or ''): the elements found, as references.
    static let find = #"""
const root = root_ ? get(root_) : document;
let found = [];
try {
  switch (using) {
    case 'css selector': found = Array.from(root.querySelectorAll(value)); break;
    case 'tag name': found = Array.from(root.getElementsByTagName(value)); break;
    case 'xpath': {
      const result = document.evaluate(value, root, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      for (let i = 0; i < result.snapshotLength; i += 1) {
        const node = result.snapshotItem(i);
        if (!(node instanceof Element)) { fail('invalid selector', 'the XPath selects something that is not an element'); }
        found.push(node);
      }
      break;
    }
    case 'link text':
    case 'partial link text': {
      const wanted = value.trim();
      found = Array.from(root.querySelectorAll('a')).filter((a) => {
        const text = (a.innerText || '').trim();
        return using === 'link text' ? text === wanted : text.includes(wanted);
      });
      break;
    }
    default: fail('invalid argument', 'there is no locator strategy "' + using + '"');
  }
} catch (error) {
  if (String(error && error.message).startsWith('PBWD:')) { throw error; }
  fail('invalid selector', String(error && error.message));
}
return JSON.stringify(found.map((el) => ({ [KEY]: idOf(el) })));
"""#

    /// `id`: where to click the element — the middle of its first box, brought into view — or
    /// that it is an option, chosen here (a list's menu is the system's, not the page's).
    static let clickTarget = #"""
const el = get(id);
if (el instanceof HTMLOptionElement) {
  const select = el.closest('select');
  if (!select || select.disabled || el.disabled) { fail('element not interactable', 'the option cannot be chosen'); }
  if (select.multiple) { el.selected = !el.selected; } else { el.selected = true; }
  select.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
  select.dispatchEvent(new Event('change', { bubbles: true }));
  return JSON.stringify({ option: true });
}
let box = el.getClientRects()[0] || el.getBoundingClientRect();
const inView = (r) => r.top >= 0 && r.left >= 0 && r.bottom <= innerHeight && r.right <= innerWidth;
if (!inView(box)) {
  el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
  box = el.getClientRects()[0] || el.getBoundingClientRect();
}
if (!shown(el) || box.width <= 0 || box.height <= 0) { fail('element not interactable', 'the element is not shown'); }
const x = Math.min(Math.max(box.left + box.width / 2, 0), innerWidth - 1);
const y = Math.min(Math.max(box.top + box.height / 2, 0), innerHeight - 1);
const hit = document.elementFromPoint(x, y);
if (hit !== el && !el.contains(hit)) {
  const what = hit ? '<' + hit.tagName.toLowerCase() + (hit.id ? ' id="' + hit.id + '"' : '') + '>' : 'nothing';
  fail('element click intercepted', 'the click would land on ' + what + ', which covers the element');
}
return JSON.stringify({ x, y });
"""#

    /// `id`: the element focused, for keys. False when it cannot take them.
    static let focus = #"""
const el = get(id);
if (el instanceof HTMLInputElement && el.type === 'file') { fail('unsupported operation', 'a file cannot be chosen through the driver'); }
if (!shown(el)) { fail('element not interactable', 'the element is not shown'); }
if (document.activeElement !== el) { el.focus(); }
if (document.activeElement !== el) { fail('element not interactable', 'the element cannot take the keyboard'); }
if (typeof el.setSelectionRange === 'function' && typeof el.value === 'string') {
  try { el.setSelectionRange(el.value.length, el.value.length); } catch (error) { /* not a text field */ }
}
return 'true';
"""#

    /// `text`: put in at the caret as typed text is, for what the keyboard's layout has no key for.
    static let insertText = #"""
return JSON.stringify(document.execCommand('insertText', false, text));
"""#

    static let clear = #"""
const el = get(id);
if (el.disabled || el.readOnly) { fail('invalid element state', 'the element cannot be changed'); }
el.focus();
if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
  if (el.value !== '') { setValue(el, ''); }
} else if (el.isContentEditable) {
  el.textContent = '';
  el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
} else {
  fail('invalid element state', 'the element is not one that holds text');
}
return 'null';
"""#

    /// `id`, `what`, `name`: something read of an element.
    static let read = #"""
const el = get(id);
const BOOLEAN = ['async', 'autofocus', 'autoplay', 'checked', 'controls', 'default', 'defer', 'disabled', 'hidden', 'loop',
  'multiple', 'muted', 'novalidate', 'open', 'readonly', 'required', 'reversed', 'selected'];
switch (what) {
  case 'text': return JSON.stringify(el.innerText === undefined ? el.textContent : el.innerText);
  case 'tagName': return JSON.stringify(el.tagName.toLowerCase());
  case 'attribute': {
    const value = el.getAttribute(name);
    return JSON.stringify(value === null ? null : BOOLEAN.includes(name.toLowerCase()) ? 'true' : value);
  }
  case 'property': return JSON.stringify(ser(el[name]));
  case 'css': return JSON.stringify(getComputedStyle(el).getPropertyValue(name));
  case 'rect': {
    const r = el.getBoundingClientRect();
    return JSON.stringify({ x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height });
  }
  case 'viewRect': {
    const r = el.getBoundingClientRect();
    return JSON.stringify({ x: r.left, y: r.top, width: r.width, height: r.height, viewWidth: innerWidth, viewHeight: innerHeight });
  }
  case 'enabled': return JSON.stringify(!el.disabled && !el.closest('fieldset[disabled]'));
  case 'selected':
    return JSON.stringify(el instanceof HTMLOptionElement ? el.selected
      : (el instanceof HTMLInputElement && (el.type === 'checkbox' || el.type === 'radio')) ? el.checked : false);
  case 'displayed': return JSON.stringify(shown(el));
  default: fail('unknown command', what);
}
"""#

    static let active = #"""
const el = document.activeElement;
if (!el) { fail('no such element', 'nothing has the keyboard'); }
return JSON.stringify({ [KEY]: idOf(el) });
"""#

    static let source = #"""
return JSON.stringify(document.documentElement ? document.documentElement.outerHTML : '');
"""#

    /// A client's script, run with its arguments and its result made the protocol's JSON. The
    /// script is part of the body's own text, not built at run time: a page's rule against
    /// evaluating text does not stop it. `async`: the script's last argument is the function it
    /// calls with its result.
    static func execute(_ script: String, async: Bool) -> String {
        let call = async
            ? "await new Promise((resolve) => { (function () {\n\(script)\n}).apply(window, __args.concat([resolve])); })"
            : "await (function () {\n\(script)\n}).apply(window, __args)"
        return "const __args = de(JSON.parse(args));\nconst __result = \(call);\nreturn JSON.stringify(ser(__result));"
    }
}
