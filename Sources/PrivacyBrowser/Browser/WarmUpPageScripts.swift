import Foundation

/// What the warm-up robot runs in a page, in its own content world (`WarmUpRobot.world`): reads
/// only — a page's measure, the marks of a check or a block, its links, a cookie banner's button.
/// Kept apart from the robot so that they can be run on a DOM outside the app
/// (`scripts/test-shims.mjs`, between the `"""#` marks below). Each is the body of an async
/// function, as `callAsyncJavaScript` takes it; its arguments are named in its comment.
enum WarmUpPageScripts {
    /// → `[textLength, pageHeight, viewportHeight]`: the text of the page's main part (the whole
    /// body where it names none) and its height, for how long it is read and how far scrolled.
    static let measure = #"""
        const main = document.querySelector('main, article, [role="main"]') || document.body;
        const text = main ? (main.innerText || '') : '';
        const height = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
        return [text.length, height, window.innerHeight];
        """#

    /// `marks`: `[{name, selector}]` (`WarmUpBlockPage.marks`). → JSON of `WarmUpPageSignals`.
    static let signals = #"""
        const found = [];
        for (const m of marks) { try { if (document.querySelector(m.selector)) found.push(m.name); } catch (e) {} }
        const visible = (e) => { const r = e.getBoundingClientRect(); return r.width > 1 && r.height > 1; };
        const pass = Array.from(document.querySelectorAll('input[type="password"]')).some(visible);
        const card = Array.from(document.querySelectorAll('input[autocomplete^="cc-"], input[name*="cardnumber" i], input[name*="card-number" i], input[name*="card_number" i]')).some(visible);
        const text = document.body ? (document.body.innerText || '').length : 0;
        return JSON.stringify({url: location.href, title: document.title || '', textLength: text, marks: found, hasPasswordField: pass, hasCardField: card});
        """#

    /// → JSON `{links: [{index, link, content, chrome}], width, height}`: the links in view that the
    /// pointer could reach (the link itself is what is under its middle), and where each is on the
    /// page — its main part, or its navigation, header, footer or side column.
    static let links = #"""
        const out = [];
        const width = window.innerWidth, height = window.innerHeight;
        const anchors = document.querySelectorAll('a[href]');
        for (let index = 0; index < anchors.length && out.length < 300; index++) {
          const a = anchors[index];
          if (typeof a.href !== 'string') continue;
          const r = a.getBoundingClientRect();
          if (r.width < 1 || r.height < 1 || r.bottom <= 0 || r.top >= height || r.right <= 0 || r.left >= width) continue;
          const style = getComputedStyle(a);
          if (style.visibility !== 'visible' || style.pointerEvents === 'none') continue;
          // Hidden by an ancestor too (opacity is not inherited; a link no one can see is a trap).
          if (a.checkVisibility ? !a.checkVisibility({opacityProperty: true, visibilityProperty: true})
                                : (() => { for (let e = a; e; e = e.parentElement) if (Number(getComputedStyle(e).opacity) < 0.1) return true; return false; })()) continue;
          const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          if (!top || (top !== a && !a.contains(top))) continue;
          const text = (a.innerText || a.getAttribute('aria-label') || a.title || '').replace(/\s+/g, ' ').trim().slice(0, 120);
          // The window it opens in: its own target, else the page's <base target>.
          const target = a.hasAttribute('target') ? a.target : ((document.querySelector('base[target]') || {}).target || '');
          const chrome = !!a.closest('nav, header, footer, aside, [role="navigation"], [role="banner"], [role="contentinfo"]');
          const content = !chrome && !!a.closest('main, article, [role="main"], h1, h2, h3');
          out.push({index, content, chrome, link: {href: a.href, text, target, download: a.hasAttribute('download'),
                                                  x: r.left, y: r.top, width: r.width, height: r.height}});
        }
        return JSON.stringify({links: out, width, height});
        """#

    /// `tools`: `[{name, accept: [selector], reject: [selector]}]`, `want`: "accept" or "reject",
    /// `words`: the texts a banner's own button may bear, `containers`: what its box's id or class
    /// must speak of (`WarmUpConsent`). → JSON `{tool, x, y, width, height}` of the button in view,
    /// kept as `globalThis.warmUpConsent` for the press that follows, or null. A banner of no known
    /// tool is answered only by the strict rule: a fixed or sticky box about cookies, a button
    /// whose whole text is one of `words`, no form with fields around it.
    static let consent = #"""
        const roots = [document];
        const uc = document.querySelector('#usercentrics-root');
        if (uc && uc.shadowRoot) roots.push(uc.shadowRoot);
        const shown = (b) => {
          const r = b.getBoundingClientRect();
          if (r.width < 1 || r.height < 1 || r.bottom <= 0 || r.top >= window.innerHeight || r.right <= 0 || r.left >= window.innerWidth) return null;
          return r;
        };
        const mark = (b, r, tool) => { globalThis.warmUpConsent = b; return JSON.stringify({tool, x: r.left, y: r.top, width: r.width, height: r.height}); };
        for (const root of roots) {
          for (const tool of tools) {
            for (const selector of (want === 'reject' ? tool.reject : tool.accept)) {
              let b = null;
              try { b = root.querySelector(selector); } catch (e) {}
              const r = b && shown(b);
              if (r) return mark(b, r, tool.name);
            }
          }
        }
        if (want !== 'accept') return null;
        const buttons = document.querySelectorAll('button, [role="button"], input[type="button"]');
        for (let i = 0; i < buttons.length && i < 400; i++) {
          const b = buttons[i];
          const text = (b.innerText || b.value || '').replace(/\s+/g, ' ').trim().toLowerCase();
          if (!text || text.length > 40 || !words.includes(text)) continue;
          const r = shown(b);
          if (!r) continue;
          let named = false, fixed = false;
          for (let e = b.parentElement; e && e !== document.body && e !== document.documentElement; e = e.parentElement) {
            const name = ((e.id || '') + ' ' + (typeof e.className === 'string' ? e.className : '')).toLowerCase();
            if (containers.some((w) => name.includes(w))) named = true;
            const position = getComputedStyle(e).position;
            if (position === 'fixed' || position === 'sticky') fixed = true;
          }
          if (!named || !fixed) continue;
          const form = b.closest('form');
          if (form && form.querySelector('input:not([type="hidden"]):not([type="checkbox"]):not([type="button"]):not([type="submit"]), textarea, select')) continue;
          return mark(b, r, 'generic');
        }
        return null;
        """#
}
