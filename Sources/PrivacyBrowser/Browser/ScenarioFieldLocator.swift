/// A field wrapper shared by the recorder and the driver when a page replaces a native input.
enum ScenarioFieldLocator {
    static let script = #"""
    function fieldComponent(el) {
      const tag = el?.localName;
      if (tag !== 'textarea' && (tag !== 'input' || !['text','email','tel','url','search'].includes(el.type))) return null;
      if (/password|one-time-code|cc-/.test(el.autocomplete || '')) return null;
      const parent = el.parentElement;
      for (const token of parent?.classList || []) {
        if (!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*-(?:input|field)$/.test(token)) continue;
        const within = parent.localName + '.' + CSS.escape(token);
        if (el.getRootNode().querySelectorAll(within).length !== 1 ||
            parent.querySelectorAll('input,textarea,select,[contenteditable]').length !== 1) continue;
        const selector = tag === 'textarea' ? tag : el.type === 'text'
          ? 'input:not([type]),input[type="text" i]' : 'input[type="' + el.type + '" i]';
        return 'control=' + JSON.stringify({selector, within});
      }
      return null;
    }
    """#
}
