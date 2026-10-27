import Foundation

/// The page side of password AutoFill: a user script in the isolated `PasswordAutoFill.world`, in
/// every frame. Pages cannot see it, call it, or reach its message handler (they have their own
/// JavaScript globals and prototypes; `window.webkit` exists only in this world).
///
/// It tells the app three things, each about the frame it runs in (the app takes the frame's origin
/// from WebKit, never from the script):
///   * `focus` — a login field (a login form's user name or password, or a lone user-name field
///     on the first page of a two-step sign-in) got focus or a click: the app may show the saved
///     logins for the site under it. The reply says how many there are.
///   * `submit` — a sign-in: a form with a password the user typed was submitted, or after a click
///     on its button or Return in it the form left the page (sign-ins by script). A password a page
///     script wrote is never reported: only fields the user typed into (trusted `input` events) count.
///   * `username` — the first page of a two-step sign-in was submitted (its user name is kept for
///     the password page).
/// `blur` and `moved` close the suggestions. The app calls back `fill`, `capture` and `submitted`.
enum PasswordAutoFillScript {
    static func source(handlerName: String, testHooks: Bool) -> String {
        let config = "{\"handler\":\"\(handlerName)\",\"test\":\(testHooks)}"
        return "(function (CONFIG) {\n" + body + "\n})(" + config + ");"
    }

    private static let body = #"""
'use strict';
const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[CONFIG.handler];
if (!handler || globalThis.__pbPasswords) return;

// Identifies this document to the app: a fill meant for it never lands in the next page of the frame.
const TOKEN = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, '0')).join('');
const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
const typed = new WeakSet();        // inputs the user typed or pasted into
const ids = new WeakMap();          // input → id the app refers to it by
const elements = new Map();         // id → WeakRef(input)
let nextId = 1;
let lastPointer = null;             // the last trusted press on an input
let lastTypedPassword = null;       // WeakRef to the password field typed into last
let pending = null;                 // a sign-in by click or Return, waiting for the form to leave
let suggesting = false;
let lastReport = { key: '', at: 0 };

function post(message) {
  message.token = TOKEN;
  try {
    return Promise.resolve(handler.postMessage(message)).catch(() => null);
  } catch (e) {
    return Promise.resolve(null);
  }
}

function idOf(el) {
  let id = ids.get(el);
  if (!id) {
    id = nextId++;
    ids.set(el, id);
    elements.set(id, new WeakRef(el));
  }
  return id;
}

function elementOf(id) {
  const ref = elements.get(id);
  return ref ? ref.deref() : undefined;
}

// The element an event is about, inside open shadow roots too.
function target(event) {
  const path = event.composedPath ? event.composedPath() : [];
  const t = path.length ? path[0] : event.target;
  return t instanceof Element ? t : (t && t.parentElement) || null;
}

function isInput(el) { return el instanceof HTMLInputElement; }
function autocompleteOf(el) { return (el.getAttribute('autocomplete') || '').toLowerCase(); }
function isPasswordField(el) {
  return isInput(el) && (el.type === 'password' || /\b(current|new)-password\b/.test(autocompleteOf(el)));
}
function isNewPasswordField(el) { return /\bnew-password\b/.test(autocompleteOf(el)); }
function isTextual(el) { return isInput(el) && (el.type === 'text' || el.type === 'email' || el.type === 'tel'); }
function looksLikeUsername(el) {
  return /\b(username|email)\b/.test(autocompleteOf(el)) || el.type === 'email' ||
    /user|login|e-?mail|account|ident/i.test((el.name || '') + ' ' + (el.id || ''));
}

// Only fields a person can see and use: nothing is filled into, or read from, hidden inputs.
function visible(el) {
  if (!el.isConnected || el.disabled || el.type === 'hidden') return false;
  const r = el.getBoundingClientRect();
  if (r.width < 2 || r.height < 2) return false;
  const style = getComputedStyle(el);
  return style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
}

function scopeOf(el) { return el.form || el.getRootNode(); }

function fieldsIn(scope) {
  if (scope instanceof HTMLFormElement) return Array.from(scope.elements).filter(isInput);
  return Array.from(scope.querySelectorAll ? scope.querySelectorAll('input') : []).filter((e) => !e.form);
}

// A form's password fields, its user-name field and its kind: 'login', or 'new' for sign-up and
// change-password forms (autocomplete=new-password, or two password fields and more).
function analyze(scope) {
  const inputs = fieldsIn(scope);
  const passwords = inputs.filter(isPasswordField);
  const first = passwords.find(visible) || passwords[0];
  let username = null;
  if (first) {
    const before = inputs.filter((e) => isTextual(e) && visible(e) &&
      (e.compareDocumentPosition(first) & Node.DOCUMENT_POSITION_FOLLOWING));
    username = before.filter(looksLikeUsername).pop() || before.pop() || null;
  }
  if (!username) username = inputs.find((e) => isTextual(e) && visible(e) && /\busername\b/.test(autocompleteOf(e))) || null;
  const kind = passwords.some(isNewPasswordField) || passwords.filter(visible).length >= 2 ? 'new' : 'login';
  return { inputs, passwords, username, kind };
}

// What a focused input is to AutoFill: 'password' or 'username' of a login form, a lone user name
// (first page of a two-step sign-in), or null.
function loginRole(el) {
  if (!isInput(el) || el.readOnly || el.disabled) return null;
  const form = analyze(scopeOf(el));
  if (isPasswordField(el)) return form.kind === 'login' && !isNewPasswordField(el) ? 'password' : null;
  if (!isTextual(el)) return null;
  if (form.passwords.length) return form.kind === 'login' && form.username === el ? 'username' : null;
  if (/\busername\b/.test(autocompleteOf(el))) return 'username';
  const texts = form.inputs.filter((e) => isTextual(e) && visible(e));
  return texts.length === 1 && looksLikeUsername(el) ? 'username' : null;
}

// The credentials a submission of `scope` carries. With `requireTyped`, only when the user typed
// a password in it. For a new password, its confirmation must match.
function credentialsIn(scope, requireTyped) {
  const form = analyze(scope);
  const filled = form.passwords.filter((p) => p.value);
  if (!filled.length) return null;
  if (requireTyped && !filled.some((p) => typed.has(p))) return null;
  let chosen = [filled[0]];
  if (form.kind === 'new') {
    const fresh = filled.filter(isNewPasswordField);
    chosen = fresh.length ? fresh : filled.length >= 2 ? filled.slice(1) : filled;
    if (chosen.length >= 2 && chosen[0].value !== chosen[1].value) return null;
  }
  return {
    username: form.username ? form.username.value.trim() : '',
    password: chosen[0].value,
    kind: form.kind,
    field: chosen[0],
  };
}

function report(how, credentials) {
  const key = credentials.username + '\u0000' + credentials.password;
  if (key === lastReport.key && performance.now() - lastReport.at < 3000) return;
  lastReport = { key, at: performance.now() };
  // Reported once: a later form navigation in this frame does not report it again.
  lastTypedPassword = null;
  post({ type: 'submit', how, username: credentials.username, password: credentials.password, kind: credentials.kind });
}

// The first page of a two-step sign-in: one user-name field the user typed into, no password.
function reportUsernameStep(scope) {
  const form = analyze(scope);
  // A user-name page often carries a hidden password field for the next step.
  if (form.passwords.some(visible)) return;
  const typedTexts = form.inputs.filter((e) => isTextual(e) && visible(e) && e.value && typed.has(e));
  const field = typedTexts.find((e) => /\busername\b/.test(autocompleteOf(e))) ||
    (typedTexts.length === 1 && looksLikeUsername(typedTexts[0]) ? typedTexts[0] : null);
  if (field) post({ type: 'username', username: field.value.trim() });
}

// A click on a form's button or Return in it: a sign-in by script shows as the password field
// leaving (or the address changing) soon after, or the page going away.
function arm(from) {
  const scope = scopeOf(from);
  const credentials = credentialsIn(scope, true);
  if (!credentials) {
    reportUsernameStep(scope);
    return;
  }
  const watching = pending !== null;
  pending = { credentials, field: credentials.field, href: location.href, at: performance.now() };
  if (!watching) setTimeout(watch, 250);
}

function watch() {
  if (!pending) return;
  const gone = !pending.field.isConnected || !visible(pending.field) || location.href !== pending.href;
  if (gone) {
    report('removed', pending.credentials);
    pending = null;
  } else if (performance.now() - pending.at > 5000) {
    pending = null;
  } else {
    setTimeout(watch, 250);
  }
}

// The field's rectangle in the top frame's CSS pixels (through same-origin frames), for placing
// the suggestions under it. `crossOrigin`: a frame above is another origin; the app then places it
// from the click.
function rectOf(el) {
  const r = el.getBoundingClientRect();
  let x = r.left, y = r.top, w = window, crossOrigin = false;
  try {
    while (w !== w.top) {
      const frame = w.frameElement;
      if (!frame) { crossOrigin = true; break; }
      const fr = frame.getBoundingClientRect();
      const style = w.parent.getComputedStyle(frame);
      x += fr.left + frame.clientLeft + parseFloat(style.paddingLeft || '0');
      y += fr.top + frame.clientTop + parseFloat(style.paddingTop || '0');
      w = w.parent;
    }
  } catch (e) {
    crossOrigin = true;
  }
  const vv = (crossOrigin ? window : w).visualViewport;
  return {
    x, y, width: r.width, height: r.height, crossOrigin,
    viewportX: vv ? vv.offsetLeft : 0, viewportY: vv ? vv.offsetTop : 0, scale: vv ? vv.scale : 1,
  };
}

function suggest(el, reason) {
  const role = loginRole(el);
  if (!role || !visible(el)) return;
  const pointer = lastPointer && lastPointer.el === el && performance.now() - lastPointer.at < 1500
    ? { x: lastPointer.x, y: lastPointer.y } : null;
  post({ type: 'focus', field: idOf(el), role, reason, rect: rectOf(el), pointer }).then((reply) => {
    suggesting = !!(reply && reply.count > 0);
    // WebKit's own key button in the field, where this world may show it (as Safari does).
    if (suggesting && 'autofillButtonType' in el) {
      try { el.autofillButtonType = 'credentials'; } catch (e) { /* not in this WebKit */ }
    }
  });
}

function deepActiveElement() {
  let el = document.activeElement;
  while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
  return el;
}

function setValue(el, value) {
  valueSetter.call(el, value);
  // As Safari's AutoFill: a plain bubbling `input`, then `change`.
  el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  if ('autofilled' in el) {
    try { el.autofilled = true; } catch (e) { /* not in this WebKit */ }
  }
}

function bestLoginField() {
  const all = Array.from(document.querySelectorAll('input')).filter((e) => visible(e) && loginRole(e));
  return all.find((e) => loginRole(e) === 'username') || all[0] || null;
}

addEventListener('input', (event) => {
  const el = target(event);
  if (!event.isTrusted || !isInput(el)) return;
  typed.add(el);
  if (isPasswordField(el)) lastTypedPassword = new WeakRef(el);
  // Typing closes the list (it would cover the next field; ↓ opens it again).
  moved();
}, true);

addEventListener('focusin', (event) => {
  const el = target(event);
  if (isInput(el)) suggest(el, 'focus');
}, true);

addEventListener('focusout', (event) => {
  const el = target(event);
  if (isInput(el) && ids.has(el)) post({ type: 'blur', field: idOf(el) });
}, true);

addEventListener('pointerdown', (event) => {
  const el = target(event);
  if (!event.isTrusted || !isInput(el)) return;
  lastPointer = { el, x: event.clientX, y: event.clientY, at: performance.now() };
  // A click into the field that already has focus shows the suggestions again.
  if (el === deepActiveElement()) suggest(el, 'click');
}, true);

addEventListener('keydown', (event) => {
  const el = target(event);
  if (!event.isTrusted || !isInput(el)) return;
  if (event.key === 'ArrowDown' && !event.altKey && !event.metaKey && !event.ctrlKey) suggest(el, 'key');
  if (event.key === 'Enter') arm(el);
}, true);

addEventListener('click', (event) => {
  const el = target(event);
  if (!event.isTrusted || !el) return;
  const button = el.closest('button, input[type=submit], input[type=image], input[type=button], [role=button]');
  if (button) arm(button);
}, true);

addEventListener('submit', (event) => {
  const form = target(event);
  if (!(form instanceof HTMLFormElement)) return;
  const credentials = credentialsIn(form, true);
  if (credentials) report('submit', credentials);
  else reportUsernameStep(form);
}, true);

addEventListener('pagehide', () => {
  if (pending) {
    report('pagehide', pending.credentials);
    pending = null;
  }
}, true);

const moved = () => {
  if (!suggesting) return;
  suggesting = false;
  post({ type: 'moved' });
};
addEventListener('scroll', moved, { capture: true, passive: true });
addEventListener('resize', moved, { passive: true });

globalThis.__pbPasswords = {
  // Fills a saved login into the form of input `field` (or, from the toolbar, the page's first
  // login form). Only into this document, of the origin the app checked, and visible fields.
  fill(token, field, username, password, origin) {
    if (token && token !== TOKEN) return 'stale';
    if (location.origin !== origin) return 'origin';
    const el = field ? elementOf(field) : bestLoginField();
    if (!el || !visible(el)) return 'nofield';
    const role = loginRole(el);
    const form = analyze(scopeOf(el));
    const passwordField = role === 'password' ? el
      : form.kind === 'login' ? form.passwords.find((p) => visible(p) && !isNewPasswordField(p)) || null : null;
    const usernameField = role === 'username' ? el : form.username && visible(form.username) ? form.username : null;
    if (!passwordField && !usernameField) return 'nofield';
    if (usernameField && username) setValue(usernameField, username);
    if (passwordField) setValue(passwordField, password);
    return 'filled';
  },
  // The toolbar's Save: what the page's password fields hold, typed or not.
  capture() {
    const scopes = [...Array.from(document.forms), document];
    for (const scope of scopes) {
      const credentials = credentialsIn(scope, false);
      if (credentials) return { username: credentials.username, password: credentials.password, origin: location.origin };
    }
    return null;
  },
  // A form submission the app saw as a navigation (also `form.submit()`, which fires no `submit`
  // event): the form of the password the user typed last, if it was typed.
  submitted() {
    const field = lastTypedPassword && lastTypedPassword.deref();
    lastTypedPassword = null;
    if (!field || !field.isConnected) return null;
    const credentials = credentialsIn(scopeOf(field), true);
    return credentials ? { username: credentials.username, password: credentials.password } : null;
  },
};

if (CONFIG.test) {
  // Self-test only: stands in for typing when the runner delivers no key events.
  globalThis.__pbPasswords.markTyped = (selector) => {
    const el = document.querySelector(selector);
    if (!el) return false;
    typed.add(el);
    if (isPasswordField(el)) lastTypedPassword = new WeakRef(el);
    return true;
  };
  globalThis.__pbPasswords.suggest = (selector) => {
    const el = document.querySelector(selector);
    if (el) suggest(el, 'test');
    return !!el;
  };
  globalThis.__pbPasswords.arm = (selector) => {
    const el = document.querySelector(selector);
    if (el) arm(el);
    return !!el;
  };
  // A frame the self-test cannot reach (another origin): its #user field asks for suggestions
  // once the page has loaded.
  if (/[?&]pbtestfocus=1(&|$)/.test(location.search)) {
    addEventListener('DOMContentLoaded', () => {
      const el = document.querySelector('#user');
      if (el) suggest(el, 'test');
    });
  }
}
"""#
}
