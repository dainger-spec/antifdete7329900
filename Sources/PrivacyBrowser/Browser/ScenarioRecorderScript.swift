/// The page's side of a scenario's recording (`ScenarioRecorder`): in a world of its own, in the
/// main frame, it watches what a person does — clicks, what a field ends up holding, a choice in
/// a list, Enter — and says each as a step with a selector that should still find the element
/// tomorrow. Nothing is
/// watched until the app says a recording is on; a secret's text — a password, a one-time code, a
/// card's — is never sent (`isSecret`).
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
  // A trusted edit marks one field dirty until its value is emitted.
  let dirty = null;
  // What a field held when the person came to it: typing into text that was there replaces it
  // on a replay only if the scenario selects it first.
  const held = new WeakMap();
  let recordedEnter = null;
  let editorEnter = null;
  let forwardedControl = null;

  const post = (message) => {
    try { return Promise.resolve(handler.postMessage(message)); } catch (e) { return Promise.resolve(null); }
  };
  let generation = 0;
  globalThis.__pbRecorder = { set(value) {
    generation++;
    const finalKey = on && !value ? finishEditorEnter() : null;
    const finalEdit = on && !value ? flush() : null;
    on = !!value;
    return finalEdit || finalKey;
  } };
  // `late`: the app put the script into a page that was open already (`ScenarioRecorder.start`) —
  // the page did not load just now.
  function hello(late) {
    const current = ++generation;
    return post({type: 'hello', url: location.href, late}).then(reply => {
      if (generation === current) on = !!(reply && reply.recording);
    }, () => {});
  }
  hello(globalThis.__pbRecorderLate === true);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { if (on) { finishEditorEnter(); flush(); } } else { hello(true); }
  });

  // The element an event is about, inside open shadow roots too.
  const targetOf = (event) => {
    const path = event.composedPath ? event.composedPath() : [];
    const t = path.length ? path[0] : event.target;
    return t instanceof Element ? t : (t && t.parentElement) || null;
  };

  const attr = (value) => String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  // Where an element is looked for: the document, or the open shadow root it is in (a web
  // component's own elements, which no selector of the document reaches). A selector is unique,
  // and a text is found, in that scope alone; a replay looks there through the host's selector
  // (`host >>> inner`).
  let scope = document;
  const count = (selector) => { try { return scope.querySelectorAll(selector).length; } catch (e) { return 0; } };
  // An id a framework made for this load only (":r1:", "ember123", a long run of digits or hex)
  // finds nothing tomorrow.
  const stable = (id) => id.length <= 48 && !/[:.\s]/.test(id) && !/\d{4,}/.test(id) && !/^[0-9a-f]{12,}$/i.test(id)
    && !/^bn-formItem-/i.test(id)
    && !/^(ember|react|radix|headlessui|mui|rc|ng|vue)[-_]?\d/i.test(id);

  const TEST_IDS = ['data-testid', 'data-test-id', 'data-test', 'data-qa', 'data-cy'];
  \#(ScenarioFieldLocator.script)

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
    for (const name of ['name', 'aria-label', 'placeholder', 'title', 'for']) {
      const value = el.getAttribute(name);
      if (name === 'for' && value && !stable(value)) { continue; }
      if (value && value.length <= 60 && count(`${tag}[${name}="${attr(value)}"]`) === 1) { return `${tag}[${name}="${attr(value)}"]`; }
    }
    return null;
  }

  // From the nearest ancestor that can be named, down by position among siblings of its kind.
  // Six steps up at most with no such ancestor — and further while those steps are also the way
  // to another element (two cards of one shape): a replay takes the first that a selector finds.
  function byPath(el) {
    const parts = [];
    let node = el;
    while (node && node !== document.body && node.nodeType === 1 && (parts.length < 6 || count(parts.join(' > ')) !== 1)) {
      const named = node === el ? null : byAttributes(node);
      if (named) { return named + ' > ' + parts.join(' > '); }
      const tag = node.tagName.toLowerCase();
      if (node !== el && /^h[1-6]$/.test(tag) && count(tag) === 1) return tag + ' > ' + parts.join(' > ');
      // At the top of a shadow root its siblings are the root's children.
      const parent = node.parentElement || (node.parentNode && node.parentNode.nodeType === 11 ? node.parentNode : null);
      const same = parent ? Array.from(parent.children).filter((c) => c.tagName === node.tagName) : [node];
      parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(node) + 1})` : tag);
      node = node.parentElement;
    }
    return (node === document.body ? 'body > ' : '') + parts.join(' > ');
  }

  // `el`'s selector in the scope it is in; a host's never by its text, which a `>>>` would cut.
  function selectorIn(el, isHost) {
    const named = byAttributes(el);
    if (named && (isHost || named.startsWith('#'))) { return named; }
    const tag = el.tagName.toLowerCase();
    // A field component can keep its name while replacing its input and floating label.
    // Prefer a uniquely named wrapper to a placeholder, never to a stable ID or form name.
    if (!isHost && named && /^(input|textarea)\[(aria-label|placeholder)=/.test(named) && !isSecret(el)) {
      const component = fieldComponent(el);
      if (component) return component;
    }
    if (!isHost && el.matches('a[href],button,summary,label,[role="button"],[role="link"],[role="tab"],[role="menuitem"]')) {
      const text = (el.innerText || '').replace(/\s+/g, ' ').trim();
      if (named || (text && text.length <= 120)) {
        const role = el.getAttribute('role');
        const control = { selector: named || (role ? tag + '[role="' + attr(role) + '"]' : tag) };
        if (text && text.length <= 120) control.text = text.normalize('NFC');
        for (let parent = el.parentElement; parent && parent !== document.body; parent = parent.parentElement) {
          const within = byAttributes(parent);
          if (within) { control.within = within; break; }
        }
        return 'control=' + JSON.stringify(control);
      }
    }
    return named || byPath(el);
  }

  // Inside an open shadow root: the host's selector, `>>>`, then `el`'s in that root — the way the
  // driver's find goes (PageDriver.findAll), one root after another for components in components.
  function selectorOf(el, isHost) {
    const root = typeof el.getRootNode === 'function' ? el.getRootNode() : document;
    const inShadow = typeof ShadowRoot !== 'undefined' && root instanceof ShadowRoot && !!root.host;
    const outer = inShadow ? selectorOf(root.host, true) + ' >>> ' : '';
    scope = inShadow ? root : document;
    try { return outer + selectorIn(el, isHost); } finally { scope = document; }
  }

  const isNativeField = (el) => (el instanceof HTMLInputElement
    && !/^(checkbox|radio|button|submit|reset|file|image|range|color|hidden)$/.test(el.type)) || el instanceof HTMLTextAreaElement;

  function fieldOf(el) {
    if (!el || isNativeField(el)) return el;
    if (!el.isContentEditable || el.matches('input,select,button')) return null;
    while (el.parentElement && el.parentElement.isContentEditable) el = el.parentElement;
    return el.hasAttribute('contenteditable') ? el : null;
  }
  function fieldText(field) {
    if (isNativeField(field)) return field.value;
    // WebKit leaves a placeholder break in an emptied editing host.
    if (field.childNodes.length === 1 && field.firstChild.nodeName === 'BR') return '';
    return field.innerText;
  }

  // A field whose text is a secret, said as one (its text never sent; the scenario's
  // params.password in its place): a password field, or one that was a password field while the
  // person was in it — a "show password" button makes it a text field —, and a field whose
  // autocomplete says a password, a one-time code (inputmode="numeric" ones included) or a
  // card's number, name, date or code (cc-…). Once a secret, a field stays one for this page.
  const secrets = new WeakSet();
  const SECRET_AUTOCOMPLETE = /^(current-password|new-password|one-time-code|cc-.*)$/;
  const markSecret = (el) => {
    if (el instanceof HTMLInputElement && String(el.type).toLowerCase() === 'password') { secrets.add(el); }
  };
  const isSecret = (el) => {
    if (!el || typeof el.getAttribute !== 'function') { return false; }
    markSecret(el);
    if (secrets.has(el)) { return true; }
    const tokens = String(el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
    if (tokens.some((token) => SECRET_AUTOCOMPLETE.test(token))) { secrets.add(el); return true; }
    return false;
  };

  // What a click is on: the link, button or control around the pixel that was hit.
  const CLICKABLE = 'a[href], button, input, select, textarea, label, summary, [role="button"], [role="link"], [role="tab"], [role="menuitem"], [role="checkbox"], [onclick]';
  const clicked = (el) => el.closest(CLICKABLE) || el;

  function flush() {
    const edit = dirty;
    dirty = null;
    if (!edit) return;
    const secret = isSecret(edit.field) || edit.secret;
    return post({type: 'fill', selector: edit.selector, value: secret ? '' : edit.value,
                 secret, replaces: edit.replaces});
  }

  addEventListener('focusin', (event) => {
    const el = fieldOf(targetOf(event));
    if (el) {
      // Marked whether or not a recording is on: one may begin while the person is in the field.
      isSecret(el);
      if (on) { held.set(el, fieldText(el) !== ''); }
    }
  }, true);

  // Recording can begin after focus, or while a page has reset a still-focused field.
  addEventListener('beforeinput', (event) => {
    const field = fieldOf(targetOf(event));
    if (on && event.isTrusted && field && field !== dirty?.field) {
      held.set(field, fieldText(field) !== '');
    }
  }, true);

  addEventListener('input', (event) => {
    if (!on || !event.isTrusted) { return; }
    const el = fieldOf(targetOf(event));
    if (el) {
      // The recorded shortcut itself will produce this edit on replay.
      if (recordedEnter?.field === el && ['insertLineBreak','insertParagraph'].includes(event.inputType)) return;
      if (dirty && dirty.field !== el) flush();
      const secret = isSecret(el);
      // A framework may reset or replace the node immediately after this trusted event.
      dirty = {field: el, selector: dirty?.selector ?? selectorOf(el),
               replaces: !!held.get(el), secret, value: secret ? '' : fieldText(el)};
    }
  }, true);

  addEventListener('change', (event) => {
    if (!on || !event.isTrusted) { return; }
    const el = targetOf(event);
    if (!el) { return; }
    if (el instanceof HTMLSelectElement) {
      // The typing in a field before it is over.
      flush();
      const words = (text) => String(text).replace(/\s+/g, ' ').trim().slice(0, 80);
      const chosen = Array.from(el.selectedOptions || []);
      // A card's month or year chosen in a list is the card's too: which list, not which choice.
      if (isSecret(el)) {
        post({ type: 'note', value: 'select ' + selectorOf(el) + ': •••' });
      } else if (el.multiple || chosen.length !== 1) {
        // A list that takes several: what it holds now is said, not replayed — which of them
        // this choice added is not known here.
        post({ type: 'note', value: 'select ' + selectorOf(el) + ': ' + chosen.map((o) => words(o.label)).join(', ') });
      } else {
        // The choice itself is the step: page.selectOption(selector, value) on a replay.
        post({ type: 'select', selector: selectorOf(el), value: String(chosen[0].value), label: words(chosen[0].label) });
      }
    } else if (el === dirty?.field) {
      flush();
    }
  }, true);

  addEventListener('focusout', () => { if (on) { flush(); } }, true);
  // A window left for another — the Scenarios window, to stop the recording — may give its field
  // a blur and no focusout: the typing is over then too.
  addEventListener('blur', () => { if (on) { flush(); } }, true);

  function writeEnter(key) {
    flush();
    if (key.focusSelector) post({type: 'click', selector: key.focusSelector});
    return post({type: 'press', value: key.value});
  }

  // In a multiline editor, Enter usually inserts a newline captured by input. A chat
  // editor can cancel the native edit to send instead. Inspect the event after dispatch.
  function finishEditorEnter() {
    const key = editorEnter;
    editorEnter = null;
    if (key?.event.defaultPrevented) return writeEnter(key);
  }

  addEventListener('keydown', (event) => {
    if (!event.isTrusted) return;
    finishEditorEnter();
    recordedEnter = null;
    if (!on || event.key !== 'Enter' || event.isComposing) return;
    const el = fieldOf(targetOf(event));
    if (!el) return;
    const keys = [event.ctrlKey && 'Control', event.altKey && 'Alt', event.shiftKey && 'Shift', event.metaKey && 'Meta', 'Enter'];
    const key = {event, focusSelector: dirty?.field === el ? null : selectorOf(el), value: keys.filter(Boolean).join('+')};
    if (el instanceof HTMLInputElement || el.getAttribute('aria-multiline') === 'false' || event.ctrlKey || event.metaKey) {
      recordedEnter = {field: el, form: el.form};
      writeEnter(key);
    } else {
      editorEnter = key;
      setTimeout(() => { if (editorEnter === key) finishEditorEnter(); }, 0);
    }
  }, true);

  addEventListener('keyup', (event) => {
    if (!recordedEnter || !event.isTrusted || event.key !== 'Enter') return;
    const ended = recordedEnter;
    setTimeout(() => { if (recordedEnter === ended) recordedEnter = null; }, 0);
  }, true);

  addEventListener('click', (event) => {
    if (!on || !event.isTrusted) { return; }
    finishEditorEnter();
    const hit = targetOf(event);
    if (!hit) { return; }
    const el = clicked(hit);
    // A click into a field to type there says nothing by itself: the typing names the field.
    if (fieldOf(hit)) { return; }
    // Nor does a click on a list: it opens the system's menu, where a replay's click would wait
    // for a choice nobody makes. The choice is the step (`change`).
    if (el.tagName === 'SELECT' || el.tagName === 'OPTION') { flush(); return; }
    // Enter in a form's field "clicks" its button for the form (no pointer in it): the Enter is
    // the step, and a replay that clicked as well would send the form twice.
    if (event.detail === 0 && recordedEnter?.form && el.form === recordedEnter.form &&
        (el.type === 'submit' || el.type === 'image')) { return; }
    flush();
    // A click on the page itself, beside everything in it, names nothing a replay could find.
    if (el === document.body || el === document.documentElement) { return; }
    // Replay the visible label. Its forwarded click can be on a hidden checkbox.
    if (el === forwardedControl) { forwardedControl = null; return; }
    if (el instanceof HTMLLabelElement && el.control) {
      forwardedControl = el.control;
      setTimeout(() => { forwardedControl = null; }, 0);
    }
    post({ type: 'click', selector: selectorOf(el) });
  }, true);

  addEventListener('pagehide', () => { if (on) { finishEditorEnter(); flush(); } }, true);
})();
"""#
}
