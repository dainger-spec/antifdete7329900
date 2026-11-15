import Foundation

/// A ready scenario a person fills in instead of writing (docs/AUTOMATION.md, "Templates"): a
/// real script of the scenario's own commands, whose settings are the `const` lines at its head
/// (`ScenarioSettings`) and whose comments name its steps (`ScenarioSteps`). What differs from
/// profile to profile — a login, a password — is read as `params.<name>`: the profile's own
/// values (`ScenarioValues`), never written into the scenario.
///
/// The words (`{{key}}` in a script: a step's name, a setting's label, a result) are the
/// interface's, put in when a scenario is made from the template.
public struct ScenarioTemplate: Equatable, Sendable, Identifiable {
    public enum Group: String, CaseIterable, Sendable { case signIn, activity, forms, data }

    /// How a setting is asked for in the form.
    public enum Field: Equatable, Sendable {
        /// An address: http or https.
        case address
        case text
        /// What finds an element: CSS, or `text=…`; may be left as it is ("found on the page").
        case selector
        case number(ClosedRange<Int>)
        /// Lines of text, one a line.
        case lines
        case choice([String])
    }

    public struct Parameter: Equatable, Sendable {
        /// The `const` of the script's head.
        public var name: String
        public var field: Field
        /// The form shows it only when "name them myself" is chosen: its value works as it is.
        public var isAdvanced = false
        /// May be left empty.
        public var isOptional = false
    }

    public var id: String
    public var group: Group
    /// An SF Symbol's name.
    public var symbol: String
    public var parameters: [Parameter]
    /// The profile's values the script reads (`params.<name>`).
    public var takes: [String]
    public var script: String

    /// The keys of the interface's words: `scenarios.template.<id>.title`, `.text`, `.asks`.
    public var titleKey: String { "scenarios.template.\(id).title" }
    public var textKey: String { "scenarios.template.\(id).text" }
    public var asksKey: String { "scenarios.template.\(id).asks" }
    /// A word of a script: `scenarios.template.word.<key>`.
    public static func wordKey(_ key: String) -> String { "scenarios.template.word.\(key)" }

    /// The `{{key}}` of the script, in order, each once.
    public var words: [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([A-Za-z0-9_.]+)\}\}"#) else { return [] }
        let text = script as NSString
        var seen = Set<String>(), found: [String] = []
        for match in regex.matches(in: script, range: NSRange(location: 0, length: text.length)) {
            let key = text.substring(with: match.range(at: 1))
            if seen.insert(key).inserted { found.append(key) }
        }
        return found
    }

    /// The scenario's text: the script with its words (`word`: a key's text in the interface's
    /// language, on one line) and the settings the form gave. A word inside a quoted text is
    /// written so that it stays one.
    public func source(settings: [String: ScenarioSettings.Value] = [:], word: (String) -> String) -> String {
        var text = ""
        for line in ScenarioSteps.lines(of: script) {
            // In code a word is a text's inside: its quotes and backslashes escaped. In a comment, as it is.
            var out = line
            for key in words where out.contains("{{\(key)}}") {
                let plain = word(key).split(whereSeparator: \.isNewline).joined(separator: " ")
                while let range = out.range(of: "{{\(key)}}") {
                    // After the line's code: `ScenarioSteps.split` knows a `//` inside a quoted text.
                    let inComment = out.distance(from: out.startIndex, to: range.lowerBound) >= ScenarioSteps.split(out).code.count
                    out.replaceSubrange(range, with: inComment ? plain : String(ScenarioRecording.quoted(plain).dropFirst().dropLast()))
                }
            }
            text += out
        }
        for (name, value) in settings { text = ScenarioSettings.setting(name, to: value, in: text) }
        return text
    }

    public static func template(_ id: String) -> ScenarioTemplate? { all.first { $0.id == id } }

    // MARK: The templates

    public static let all: [ScenarioTemplate] = [
        ScenarioTemplate(id: "signin", group: .signIn, symbol: "key", parameters: [
            Parameter(name: "LOGIN_URL", field: .address),
            Parameter(name: "LOGIN_FIELD", field: .selector, isAdvanced: true),
            Parameter(name: "PASSWORD_FIELD", field: .selector, isAdvanced: true),
            Parameter(name: "SUBMIT_BUTTON", field: .selector, isOptional: true),
            Parameter(name: "SIGNED_IN", field: .selector, isOptional: true),
        ], takes: ["login", "password"], script: #"""
// {{signin.name}}
const LOGIN_URL = 'https://'; // {{label.loginURL}}
const LOGIN_FIELD = 'input[type="email"], input[autocomplete="username"], input[name*="login" i], input[name*="user" i], input[name*="mail" i]'; // {{label.loginField}}
const PASSWORD_FIELD = 'input[type="password"]'; // {{label.passwordField}}
const SUBMIT_BUTTON = ''; // {{label.submitButton}}
const SIGNED_IN = ''; // {{label.signedIn}}

// {{step.openSignIn}}
await page.goto(LOGIN_URL);
// {{step.typeLogin}}
await page.type(LOGIN_FIELD, params.login || '');
// {{step.typePassword}}
await page.type(PASSWORD_FIELD, params.password || '');
// {{step.sendForm}}
if (SUBMIT_BUTTON) { await page.click(SUBMIT_BUTTON); } else { await page.press('Enter'); }
// {{step.waitSignedIn}}
if (SIGNED_IN) { await page.waitFor(SIGNED_IN, { timeout: 30000 }); } else { await page.waitForLoadState(); }
// {{step.result}}
return '{{result.signedIn}}';
"""#),
        ScenarioTemplate(id: "signedin", group: .signIn, symbol: "person.crop.circle.badge.checkmark", parameters: [
            Parameter(name: "PAGE_URL", field: .address),
            Parameter(name: "SIGNED_IN", field: .selector),
        ], takes: [], script: #"""
// {{signedin.name}}
const PAGE_URL = 'https://'; // {{label.pageURL}}
const SIGNED_IN = ''; // {{label.onlySignedIn}}

// {{step.openPage}}
await page.goto(PAGE_URL);
// {{step.lookSignedIn}}
await sleep(1500);
// {{step.result}}
return (await page.isVisible(SIGNED_IN)) ? '{{result.signedIn}}' : '{{result.notSignedIn}}';
"""#),
        ScenarioTemplate(id: "opens", group: .signIn, symbol: "checkmark.shield", parameters: [
            Parameter(name: "PAGE_URL", field: .address),
            Parameter(name: "MUST_SHOW", field: .selector, isOptional: true),
            Parameter(name: "BLOCK_TEXT", field: .text, isOptional: true),
        ], takes: [], script: #"""
// {{opens.name}}
const PAGE_URL = 'https://'; // {{label.pageURL}}
const MUST_SHOW = ''; // {{label.mustShow}}
const BLOCK_TEXT = ''; // {{label.blockText}}

// {{step.openPage}}
await page.goto(PAGE_URL);
// {{step.lookBlocked}}
if (BLOCK_TEXT && (await page.count('text=' + BLOCK_TEXT)) > 0) { return '{{result.blocked}}'; }
// {{step.lookShown}}
if (MUST_SHOW) { await page.waitFor(MUST_SHOW, { timeout: 15000 }); }
// {{step.result}}
return await page.title();
"""#),
        ScenarioTemplate(id: "feed", group: .activity, symbol: "arrow.down.doc", parameters: [
            Parameter(name: "PAGE_URL", field: .address),
            Parameter(name: "SCREENS", field: .number(1...200)),
            Parameter(name: "PAUSE_FROM", field: .number(0...600)),
            Parameter(name: "PAUSE_TO", field: .number(0...600)),
        ], takes: [], script: #"""
// {{feed.name}}
const PAGE_URL = 'https://'; // {{label.pageURL}}
const SCREENS = 5; // {{label.screens}}
const PAUSE_FROM = 2; // {{label.pauseFrom}}
const PAUSE_TO = 6; // {{label.pauseTo}}

// {{step.openPage}}
await page.goto(PAGE_URL);
// {{step.scrollAndRead}}
for (let i = 0; i < SCREENS; i++) {
  await page.scroll(500 + Math.round(Math.random() * 300));
  await sleep((PAUSE_FROM + Math.random() * Math.max(0, PAUSE_TO - PAUSE_FROM)) * 1000);
}
// {{step.result}}
return SCREENS;
"""#),
        ScenarioTemplate(id: "search", group: .activity, symbol: "magnifyingglass", parameters: [
            Parameter(name: "ENGINE", field: .choice(["https://www.google.com/search?q=", "https://www.bing.com/search?q=", "https://duckduckgo.com/?q=", "https://yandex.ru/search/?text="])),
            Parameter(name: "QUERIES", field: .lines),
            Parameter(name: "RESULT_LINKS", field: .selector, isAdvanced: true),
            Parameter(name: "OPEN_RESULTS", field: .number(0...10)),
            Parameter(name: "READ_SECONDS", field: .number(1...600)),
        ], takes: ["query"], script: #"""
// {{search.name}}
const ENGINE = 'https://www.google.com/search?q='; // {{label.engine}}
const QUERIES = []; // {{label.queries}}
const RESULT_LINKS = 'a h3'; // {{label.resultLinks}}
const OPEN_RESULTS = 2; // {{label.openResults}}
const READ_SECONDS = 20; // {{label.readSeconds}}

// {{step.chooseQuery}}
const query = params.query || QUERIES[Math.floor(Math.random() * QUERIES.length)] || '';
// {{step.openSearch}}
await page.goto(ENGINE + encodeURIComponent(query));
// {{step.openResults}}
const opened = []; for (let i = 0; i < OPEN_RESULTS; i++) {
  const links = await page.count(RESULT_LINKS);
  if (links === 0) { break; }
  const link = await page.evaluate((arg) => { const all = document.querySelectorAll(arg.selector); const one = all[Math.min(arg.index, all.length - 1)]; const a = one.closest('a') || one; const href = a.getAttribute('href'); return href ? 'a[href="' + CSS.escape(href) + '"]' : ''; }, { selector: RESULT_LINKS, index: i });
  if (!link) { break; }
  await page.click(link);
  await page.waitForLoadState();
  opened.push(await page.url());
  await page.scroll(600);
  await sleep(READ_SECONDS * 1000);
  await page.back();
}
// {{step.result}}
return opened;
"""#),
        ScenarioTemplate(id: "pages", group: .activity, symbol: "list.bullet", parameters: [
            Parameter(name: "PAGES", field: .lines),
            Parameter(name: "STAY_SECONDS", field: .number(1...600)),
            Parameter(name: "SCROLLS", field: .number(0...50)),
        ], takes: [], script: #"""
// {{pages.name}}
const PAGES = []; // {{label.pages}}
const STAY_SECONDS = 15; // {{label.staySeconds}}
const SCROLLS = 3; // {{label.scrolls}}

// {{step.goThroughPages}}
let opened = 0; for (const address of PAGES) {
  try {
    await page.goto(address);
    opened += 1;
    for (let i = 0; i < SCROLLS; i++) {
      await page.scroll(400 + Math.round(Math.random() * 400));
      await sleep(STAY_SECONDS * 1000 / (SCROLLS + 1));
    }
    await sleep(STAY_SECONDS * 1000 / (SCROLLS + 1));
  } catch (error) {
    if (String(error && error.message) === 'stopped') { throw error; }
    log(address + ': ' + (error && error.message));
  }
}
// {{step.result}}
return opened;
"""#),
        ScenarioTemplate(id: "form", group: .forms, symbol: "square.and.pencil", parameters: [
            Parameter(name: "PAGE_URL", field: .address),
            Parameter(name: "FIELDS", field: .lines),
            Parameter(name: "SUBMIT_BUTTON", field: .selector, isOptional: true),
            Parameter(name: "DONE_SIGN", field: .selector, isOptional: true),
        ], takes: [], script: #"""
// {{form.name}}
const PAGE_URL = 'https://'; // {{label.pageURL}}
const FIELDS = []; // {{label.fields}}
const SUBMIT_BUTTON = ''; // {{label.submitButton}}
const DONE_SIGN = ''; // {{label.doneSign}}

// {{step.openPage}}
await page.goto(PAGE_URL);
// {{step.fillFields}}
for (const line of FIELDS) {
  const at = line.indexOf(' = ');
  if (at < 0) { continue; }
  const text = line.slice(at + 3);
  const value = text.startsWith('params.') ? String(params[text.slice(7)] || '') : text;
  await page.type(line.slice(0, at), value);
}
// {{step.sendForm}}
if (SUBMIT_BUTTON) { await page.click(SUBMIT_BUTTON); } else { await page.press('Enter'); }
// {{step.waitDone}}
if (DONE_SIGN) { await page.waitFor(DONE_SIGN, { timeout: 30000 }); } else { await page.waitForLoadState(); }
// {{step.result}}
return '{{result.sent}}';
"""#),
        ScenarioTemplate(id: "post", group: .forms, symbol: "paperplane", parameters: [
            Parameter(name: "PAGE_URL", field: .address),
            Parameter(name: "TEXT_FIELD", field: .selector),
            Parameter(name: "TEXT", field: .text, isOptional: true),
            Parameter(name: "SEND_BUTTON", field: .selector),
            Parameter(name: "DONE_SIGN", field: .selector, isOptional: true),
        ], takes: ["text"], script: #"""
// {{post.name}}
const PAGE_URL = 'https://'; // {{label.pageURL}}
const TEXT_FIELD = ''; // {{label.textField}}
const TEXT = ''; // {{label.text}}
const SEND_BUTTON = ''; // {{label.sendButton}}
const DONE_SIGN = ''; // {{label.doneSign}}

// {{step.openPage}}
await page.goto(PAGE_URL);
// {{step.typeText}}
await page.type(TEXT_FIELD, params.text || TEXT);
// {{step.pauseBeforeSend}}
await sleep(1200);
// {{step.pressSend}}
await page.click(SEND_BUTTON);
// {{step.waitDone}}
if (DONE_SIGN) { await page.waitFor(DONE_SIGN, { timeout: 30000 }); } else { await sleep(2000); }
// {{step.result}}
return '{{result.sent}}';
"""#),
        ScenarioTemplate(id: "cookie", group: .forms, symbol: "checkmark.rectangle", parameters: [
            Parameter(name: "PAGE_URL", field: .address, isOptional: true),
            Parameter(name: "BUTTONS", field: .lines),
        ], takes: [], script: #"""
// {{cookie.name}}
const PAGE_URL = ''; // {{label.pageURLOrCurrent}}
const BUTTONS = ['Accept all', 'Accept All', 'Allow all', 'I agree', 'Agree', 'Got it', 'Принять все', 'Принять', 'Согласен', 'Alle akzeptieren', 'Tout accepter', 'Aceptar todo']; // {{label.cookieButtons}}

// {{step.openPage}}
if (PAGE_URL) { await page.goto(PAGE_URL); }
// {{step.waitBanner}}
await sleep(1500);
// {{step.pressConsent}}
for (const words of BUTTONS) {
  if (await page.isVisible('text=' + words)) {
    await page.click('text=' + words);
    return words;
  }
}
// {{step.result}}
return '{{result.noBanner}}';
"""#),
        ScenarioTemplate(id: "collect", group: .data, symbol: "tablecells", parameters: [
            Parameter(name: "PAGE_URL", field: .address),
            Parameter(name: "WHAT", field: .lines),
        ], takes: [], script: #"""
// {{collect.name}}
const PAGE_URL = 'https://'; // {{label.pageURL}}
const WHAT = []; // {{label.what}}

// {{step.openPage}}
await page.goto(PAGE_URL);
// {{step.readValues}}
const found = {}; for (const line of WHAT) {
  const at = line.indexOf(' = ');
  if (at < 0) { continue; }
  const selector = line.slice(at + 3);
  found[line.slice(0, at)] = (await page.count(selector)) > 0 ? String(await page.innerText(selector) || '').trim() : '';
}
// {{step.result}}
return found;
"""#),
        ScenarioTemplate(id: "list", group: .data, symbol: "text.alignleft", parameters: [
            Parameter(name: "PAGE_URL", field: .address),
            Parameter(name: "ITEMS", field: .selector),
            Parameter(name: "AT_MOST", field: .number(1...1000)),
        ], takes: [], script: #"""
// {{list.name}}
const PAGE_URL = 'https://'; // {{label.pageURL}}
const ITEMS = ''; // {{label.items}}
const AT_MOST = 50; // {{label.atMost}}

// {{step.openPage}}
await page.goto(PAGE_URL);
// {{step.waitItems}}
await page.waitFor(ITEMS, { timeout: 15000 });
// {{step.readItems}}
const items = await page.evaluate((arg) => Array.from(document.querySelectorAll(arg.selector)).slice(0, arg.most).map((e) => (e.innerText || e.textContent || '').trim()), { selector: ITEMS, most: AT_MOST });
// {{step.result}}
return items;
"""#),
        ScenarioTemplate(id: "screens", group: .activity, symbol: "hand.tap", parameters: [
            Parameter(name: "PAGE_URL", field: .address),
            Parameter(name: "CLICK_LINKS", field: .selector),
            Parameter(name: "TIMES", field: .number(1...50)),
            Parameter(name: "READ_SECONDS", field: .number(1...600)),
        ], takes: [], script: #"""
// {{screens.name}}
const PAGE_URL = 'https://'; // {{label.pageURL}}
const CLICK_LINKS = 'a'; // {{label.clickLinks}}
const TIMES = 3; // {{label.times}}
const READ_SECONDS = 15; // {{label.readSeconds}}

// {{step.openPage}}
await page.goto(PAGE_URL);
// {{step.openAndRead}}
let visited = 0; for (let i = 0; i < TIMES; i++) {
  const links = await page.count(CLICK_LINKS);
  if (links === 0) { break; }
  const pick = Math.floor(Math.random() * Math.min(links, 12));
  const link = await page.evaluate((arg) => { const one = document.querySelectorAll(arg.selector)[arg.index]; const a = one.closest('a') || one; const href = a.getAttribute('href'); return href ? 'a[href="' + CSS.escape(href) + '"]' : ''; }, { selector: CLICK_LINKS, index: pick });
  if (!link) { break; }
  await page.click(link);
  await page.waitForLoadState();
  visited += 1;
  await page.scroll(500);
  await sleep(READ_SECONDS * 1000);
  await page.back();
}
// {{step.result}}
return visited;
"""#),
    ]
}
