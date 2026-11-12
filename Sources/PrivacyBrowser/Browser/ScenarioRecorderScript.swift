/// The page's side of a scenario's recording (`ScenarioRecorder`): in a world of its own, in the
/// main frame, it watches what a person does — clicks, what a field ends up holding, Enter — and
/// says each as a step with a selector that should still find the element tomorrow. Nothing is
/// watched until the app says a recording is on; a password's text is never sent.
enum ScenarioRecorderScript {
    /// `handlerName`: the message handler of the recorder's world.
    static func source(handlerName: String) -> String {
        "const HANDLER = \"\(handlerName)\";\n" + body
    }

    private static let body = #"""
(() => {
  if (globalThis.__pbRecorder) { return; }
  const handlers = window.webkit && window.webkit.messageHandlers;
  const handler = handlers && handlers[HANDLER];
  if (!handler || window.top !== window) { return; }

  let on = false;
  // The field being typed into, and what it held when its typing was last said.
  let dirty = null;
  const said = new WeakMap();
  // What a field held when the person came to it: typing into text that was there replaces it
  // on a replay only if the scenario selects it first.
  const held = new WeakMap();
  let enterAt = 0;

  const post = (message) => {
    try { return Promise.resolve(handler.postMessage(message)); } catch (e) { return Promise.resolve(null); }
  };
  globalThis.__pbRecorder = { set(value) { on = !!value; if (!on) { dirty = null; } } };
  post({ type: 'hello', url: location.href }).then((reply) => { on = !!(reply && reply.recording); }, () => {});

  // The element an event is about, inside open shadow roots too.
  const targetOf = (event) => {
    const path = event.composedPath ? event.composedPath() : [];
    const t = path.length ? path[0] : event.target;
    return t instanceof Element ? t : (t && t.parentElement) || null;
  };

  const attr = (value) => String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  const count = (selector) => { try { return document.querySelectorAll(selector).length; } catch (e) { return 0; } };
  // An id a framework made for this load only (":r1:", "ember123", a long run of digits or hex)
  // finds nothing tomorrow.
  const stable = (id) => id.length <= 48 && !/[:.\s]/.test(id) && !/\d{4,}/.test(id) && !/^[0-9a-f]{12,}$/i.test(id)
    && !/^(ember|react|radix|headlessui|mui|rc|ng|vue)[-_]?\d/i.test(id);

  // As the driver finds `text=`: the smallest elements whose text holds it.
  const textMatches = (wanted) => {
    const all = Array.from(document.querySelectorAll('body *')).filter((e) =>
      (e.innerText || '').replace(/\s+/g, ' ').trim().toLowerCase().includes(wanted));
    return all.filter((e) => !all.some((other) => other !== e && e.contains(other)));
  };

  const TEST_IDS = ['data-testid', 'data-test-id', 'data-test', 'data-qa', 'data-cy'];

  function byAttributes(el) {
    const tag = el.tagName.toLowerCase();
    if (el.id && stable(el.id)) {
      const selector = '#' + CSS.escape(el.id);
      if (count(selector) === 1) { return selector; }
    }
    for (const name of TEST_IDS) {
      const value = el.getAttribute(name);
      if (value && count(`[${name}="${attr(value)}"]`) === 1) { return `[${name}="${attr(value)}"]`; }
    }
    for (const name of ['name', 'aria-label', 'placeholder', 'title']) {
      const value = el.getAttribute(name);
      if (value && value.length <= 60 && count(`${tag}[${name}="${attr(value)}"]`) === 1) { return `${tag}[${name}="${attr(value)}"]`; }
    }
    return null;
  }

  // From the nearest ancestor that can be named, down by position among siblings of its kind.
  function byPath(el) {
    const parts = [];
    let node = el;
    while (node && node !== document.body && node.nodeType === 1 && parts.length < 6) {
      const named = node === el ? null : byAttributes(node);
      if (named) { return named + ' > ' + parts.join(' > '); }
      const tag = node.tagName.toLowerCase();
      const same = node.parentElement ? Array.from(node.parentElement.children).filter((c) => c.tagName === node.tagName) : [node];
      parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(node) + 1})` : tag);
      node = node.parentElement;
    }
    return (node === document.body ? 'body > ' : '') + parts.join(' > ');
  }

  function selectorOf(el) {
    const named = byAttributes(el);
    if (named) { return named; }
    const tag = el.tagName.toLowerCase();
    if (tag === 'a' || tag === 'button' || el.getAttribute('role') === 'button' || tag === 'summary' || tag === 'label') {
      const text = (el.innerText || '').replace(/\s+/g, ' ').trim();
      if (text && text.length <= 40 && !/["\n]/.test(text)) {
        const found = textMatches(text.toLowerCase());
        if (found.length === 1 && (found[0] === el || el.contains(found[0]))) { return 'text=' + text; }
      }
    }
    return byPath(el);
  }

  const isField = (el) => (el instanceof HTMLInputElement
    && !/^(checkbox|radio|button|submit|reset|file|image|range|color|hidden)$/.test(el.type)) || el instanceof HTMLTextAreaElement;

  // What a click is on: the link, button or control around the pixel that was hit.
  const CLICKABLE = 'a[href], button, input, select, textarea, label, summary, [role="button"], [role="link"], [role="tab"], [role="menuitem"], [role="checkbox"], [onclick]';
  const clicked = (el) => el.closest(CLICKABLE) || el;

  function flush() {
    const field = dirty;
    dirty = null;
    if (!field || !field.isConnected) { return; }
    const secret = field instanceof HTMLInputElement && field.type === 'password';
    const value = secret ? '' : field.value;
    if (!secret && said.get(field) === value) { return; }
    said.set(field, value);
    post({ type: 'fill', selector: selectorOf(field), value, secret, replaces: !!held.get(field) });
  }

  addEventListener('focusin', (event) => {
    const el = targetOf(event);
    if (on && el && isField(el)) { held.set(el, el.value !== ''); }
  }, true);

  addEventListener('input', (event) => {
    if (!on || !event.isTrusted) { return; }
    const el = targetOf(event);
    if (el && isField(el)) {
      if (dirty && dirty !== el) { flush(); }
      dirty = el;
    }
  }, true);

  addEventListener('change', (event) => {
    if (!on || !event.isTrusted) { return; }
    const el = targetOf(event);
    if (!el) { return; }
    if (el instanceof HTMLSelectElement) {
      const option = el.selectedOptions[0];
      post({ type: 'note', value: 'select ' + selectorOf(el) + ': ' + (option ? option.label : '') });
    } else if (el === dirty) {
      flush();
    }
  }, true);

  addEventListener('focusout', () => { if (on) { flush(); } }, true);

  addEventListener('keydown', (event) => {
    if (!on || !event.isTrusted || event.key !== 'Enter' || event.isComposing) { return; }
    const el = targetOf(event);
    if (el && (isField(el) && !(el instanceof HTMLTextAreaElement))) {
      flush();
      enterAt = performance.now();
      post({ type: 'press', value: 'Enter' });
    }
  }, true);

  addEventListener('click', (event) => {
    if (!on || !event.isTrusted) { return; }
    const hit = targetOf(event);
    if (!hit) { return; }
    const el = clicked(hit);
    // A click into a field to type there says nothing by itself: the typing names the field.
    if (isField(el)) { return; }
    // Enter in a form's field "clicks" its button for the form (no pointer in it): the Enter is
    // the step, and a replay that clicked as well would send the form twice.
    if (event.detail === 0 && performance.now() - enterAt < 400) { return; }
    flush();
    // A label's click is followed by its control's own: one of the two is enough.
    if (el instanceof HTMLLabelElement && el.control && event.detail !== 0) { return; }
    post({ type: 'click', selector: selectorOf(el) });
  }, true);

  addEventListener('pagehide', () => { if (on) { flush(); } }, true);
})();
"""#
}
