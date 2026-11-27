import AppKit
import BrowserCore
import Foundation

/// `Lumen --scenario-safari-check` (CI): a scenario's run in a profile's own process, where the
/// window is Safari's — from the manager's side, as the scenario editor's Run does it.
///
/// A new profile in a temporary vault, held to the self-test proxy (`PB_SELFTEST_HTTP_PROXY_PORT`,
/// which serves the page), is started without a window, as Run starts a stopped profile, and asked
/// to run a scenario on the automation form: go to it, click its button, type into its field, read
/// both back, and take what the page itself recorded of the click. It passes when the run finished
/// in a window of Safari's (its log's first line), the button counted one click, the field holds
/// what was typed, and the page saw a trusted click on the button inside the button's own box —
/// where a press lands when the viewport's place in Safari's web view is found right
/// (`PageDriver.measureViewport`; docs/PAGE_INPUT.md). Exit 0 then; 1, with what was found, when
/// not. scripts/scenario_safari_check.sh starts the proxy and runs it.
@MainActor
enum ScenarioSafariCheck {
    private static let tag = "SCENARIO-SAFARI"

    private final class Seen {
        var hostsChrome: Bool?
        var exited: Int32?
    }

    /// What the run does, and the line of its log this side reads.
    private static let script = """
        await page.goto(params.base + 'form');
        await page.waitFor('#late');
        await page.click('#button');
        await page.type('#field', 'Hello Ж🙂');
        await page.selectOption('#choice', 'b');
        await page.click('button.confirm');
        await page.click('label[for=updates]');
        const box = await page.evaluate(() => {
          const r = document.getElementById('button').getBoundingClientRect();
          return [r.left, r.top, r.right, r.bottom];
        });
        const taken = JSON.parse(await page.evaluate(() => window.__take(), null, {world: 'page'}));
        const click = taken.events.filter((e) => e.type === 'click')[0] || null;
        const result = {clicked: await page.textContent('#clicked'), value: await page.inputValue('#field'), box, click,
          inner: await page.evaluate(() => [innerWidth, innerHeight])};
        log('RESULT ' + JSON.stringify(result));
        await page.type('#remount', 'abc');
        await page.press('Enter');
        await page.type('input[aria-label="Contact"]', 'abcd');
        if (await page.inputValue('.contact-field input') !== 'abcd') throw Error('field replacement lost a character');
        await page.type('#notes', 'A\\tB\\nC');
        await page.press('Meta+Enter');
        await page.press('Enter');
        // Stop while the caret is still in the editor: no blur event finishes this edit.
        await page.type('#editor', 'Saved at stop');
        await page.evaluate(() => { localStorage.setItem('changeControls', '1'); });
        """

    private static let documentTransitions = """
        await page.evaluate(() => {
          const fixture = document.createElement('div');
          fixture.innerHTML = '<article hidden><h2><span>Hidden</span></h2></article><section><h2><span>Visible</span></h2></section>';
          fixture.querySelector('section span').onclick = () => { document.body.dataset.headingClicks = '1'; };
          document.body.prepend(fixture);
        });
        await page.click('article > h2 > span', {timeout:1500});
        if (!await page.evaluate(() => document.body.dataset.headingClicks === '1')) throw Error('the visible heading was missed');
        await page.evaluate(() => {
          const box = document.createElement('div'); box.className = 'draft-field';
          const draft = document.createElement('input'); draft.id = 'draft'; box.append(draft); document.body.prepend(box);
          draft.addEventListener('input', () => setTimeout(() => { draft.value = ''; }, 25), {once:true});
          draft.dataset.keys = '';
          draft.addEventListener('keydown', e => { if (e.key.length === 1) draft.dataset.keys += e.key; });
        });
        await page.type('#draft', 'abcd', {delay:180});
        if (await page.inputValue('#draft') !== 'abcd' || await page.getAttribute('#draft', 'data-keys') !== 'abcd')
          throw Error('initialization cleared part of the edit or replayed its keys twice');
        await page.evaluate(() => {
          const draft = document.querySelector('#draft'); draft.value = '';
          draft.oninput = () => setTimeout(() => { draft.value = ''; }, 20);
        });
        let resetAgain = false;
        try { await page.type('#draft', 'xy', {delay:180}); }
        catch (e) { resetAgain = String(e).includes('typing target changed'); }
        if (!resetAgain) throw Error('a repeatedly cleared field reported success');
        await page.evaluate(() => { setTimeout(() => location.replace('form'), 300); });
        await page.type('#field', 'new');
        if (await page.inputValue('#field') !== 'new') throw Error('field opened during the click missed the typing');
        await page.evaluate(() => {
          document.querySelector('#field').addEventListener('input', () => location.replace('two'), {once:true});
        });
        let interrupted = false;
        try { await page.type('#field', 'abc', {delay:500}); }
        catch (e) { interrupted = String(e).includes('typing target lost focus'); }
        if (!interrupted || await page.textContent('#heading') !== 'Page two')
          throw Error('typing continued into another document');
        await page.evaluate(() => { setTimeout(() => location.replace('http://other.selftest.invalid/pb-automation/form'), 300); });
        let otherOrigin = false;
        try { await page.type('#field', 'abc'); }
        catch (e) { otherOrigin = String(e).includes('typing target lost focus'); }
        if (!otherOrigin || await page.inputValue('#field') !== '')
          throw Error('a different origin inherited a pending edit');
        log('DOCUMENTS finished');
        """

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // A process of its own per profile, with Safari's window: what this check is about.
        setenv("PB_PROFILE_PROCESS", "1", 1)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            print("\(tag) FAIL the check did not finish in 5 minutes")
            exit(1)
        }
        Task { @MainActor in exit(await run()) }
        application.run()
    }

    private static func run() async -> Int32 {
        guard !AppEnvironment.isSandboxed else {
            print("\(tag) FAIL the sandboxed build runs no process per profile")
            return 1
        }
        guard let port = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            print("\(tag) FAIL PB_SELFTEST_HTTP_PROXY_PORT is not set: scripts/selftest_proxy.py serves the page")
            return 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-scenario-safari-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository: ProfileRepository
        let profile: ProfileSummary
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "scenario-safari", iterations: 10_000))
            profile = try repository.create(name: "Scenario in Safari", configuration: ProfileConfiguration(
                proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: port), matchProxyLocation: false))
        } catch {
            print("\(tag) FAIL could not make a profile: \(error)")
            return 1
        }
        print("\(tag) INFO macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version)")

        let seen = Seen()
        let manager = ProfileManager(repository: repository)
        manager.onProfileRunning = { _, hosts in seen.hostsChrome = hosts }
        manager.onChildExited = { _, status in seen.exited = status }
        manager.onError = { message in print("\(tag) INFO the manager was told: \(message)") }

        // As Run starts a stopped profile: with no window of its own.
        do {
            try await manager.launch(profile.id, openingWindow: false)
        } catch {
            print("\(tag) FAIL the profile did not start: \(error)")
            return 1
        }
        let started = Date()
        while seen.hostsChrome == nil, seen.exited == nil, Date().timeIntervalSince(started) < 90 {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        var problems: [String] = []
        var recording = ScenarioRecording()
        manager.onRecorded = { _, event in
            switch event {
            case let .loaded(address): _ = recording.loaded(address)
            case let .acted(step): _ = recording.acted(step)
            }
        }
        if seen.hostsChrome != true {
            problems.append("the profile's process does not host Safari's chrome ("
                + (seen.hostsChrome == nil ? "no answer, exit \(seen.exited.map { "\($0)" } ?? "none")" : "this app's own window") + ")")
        } else if !manager.startRecording(profile.id) {
            problems.append("the recorder did not start")
        } else if !manager.runScenario(profile.id, name: "Scenario in Safari", source: script,
                                       parametersJSON: "{\"base\": \"http://automation.selftest.invalid/pb-automation/\"}") {
            problems.append("the run was not started")
        } else {
            let began = Date()
            while manager.scenarioRuns[profile.id]?.isRunning == true, seen.exited == nil, Date().timeIntervalSince(began) < 150 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let run = manager.scenarioRuns[profile.id]
            let texts = run?.lines.map(\.text) ?? []
            for text in texts { print("\(tag) LOG \(text.prefix(700))") }
            problems += findings(outcome: run?.outcome, texts: texts)
            await manager.stopRecording(profile.id)
            let replay = recording.steps.map { ScenarioRecording.line(for: $0, passwordNote: "") }.joined(separator: "\n")
            print("\(tag) RECORDED \(replay)")
            let verify = """
                if (!await page.evaluate(() => document.querySelector('.confirm').previousElementSibling?.textContent === 'Confirm choice later'))
                  throw Error('replay did not load the changed page');
                if (await page.innerText('#editor') !== 'Saved at stop') throw Error('last editor input was lost');
                if (await page.inputValue('#remount') !== 'abc' || await page.inputValue('#notes') !== 'A\\tB\\nC')
                  throw Error('the replacement field or multiline text differs from the recording');
                if (await page.inputValue('.contact-field input') !== 'abcd') throw Error('replay missed the relabelled field');
                await page.type('input[aria-label="Contact"]', '!');
                if (await page.inputValue('.contact-field input') !== 'abcd!') throw Error('saved label missed the mounted field');
                if (!await page.evaluate(() => {
                  const form = document.querySelector('#editForm');
                  return form.dataset.submits === '1' && form.dataset.shortcuts === '1' && form.dataset.messages === '1';
                })) throw Error('Enter or its shortcut ran the wrong number of times');
                await page.evaluate(() => {
                  const form = document.querySelector('#editForm');
                  const redirect = document.createElement('input'), neighbor = document.createElement('input');
                  redirect.id = 'redirect'; neighbor.id = 'neighbor'; form.append(redirect, neighbor);
                  redirect.oninput = () => neighbor.focus();
                });
                let focusLost = false;
                try { await page.type('#redirect', 'abc'); }
                catch (e) { focusLost = String(e).includes('typing target lost focus'); }
                if (!focusLost || await page.inputValue('#redirect') !== 'a' || await page.inputValue('#neighbor') !== '')
                  throw Error('typing continued after focus moved');
                await page.evaluate(() => {
                  const field = document.querySelector('#redirect');
                  field.value = '14'; field.focus(); field.setSelectionRange(1, 1);
                  field.oninput = () => { const next = field.cloneNode(); next.value = field.value; field.replaceWith(next); };
                });
                await page.type('#redirect', '23');
                if (await page.inputValue('#redirect') !== '1234') throw Error('replacement moved the caret to the end');
                await page.evaluate(() => {
                  const field = document.querySelector('#redirect'); field.value = '';
                  field.oninput = () => { const next = field.cloneNode(); next.value = ''; field.replaceWith(next); next.focus(); };
                });
                let reset = false;
                try { await page.type('#redirect', 'abc'); } catch (e) { reset = String(e).includes('typing target changed'); }
                if (!reset || await page.inputValue('#redirect') !== '') throw Error('suffix entered a reset field');
                await page.evaluate(() => document.querySelector('#neighbor').readOnly = true);
                let readOnly = false;
                try { await page.type('#neighbor', 'x'); }
                catch (e) { readOnly = String(e).includes('is read-only'); }
                if (!readOnly || await page.inputValue('#neighbor') !== '') throw Error('read-only field accepted typing');
                await page.evaluate(() => {
                  const field = document.querySelector('#neighbor');
                  field.readOnly = false; field.placeholder = 'Example';
                });
                await page.type('#neighbor:placeholder-shown', 'abc');
                if (await page.inputValue('#neighbor') !== 'abc') throw Error('typing stopped when the placeholder disappeared');
                await page.selectOption('#choice', 'b');
                await page.click('#inside');
                const state = await page.evaluate(() => [document.querySelector('#clicked').dataset.n,
                  document.querySelector('#field').value, document.querySelector('#chosen').textContent,
                  document.querySelector('.confirm').dataset.clicked, document.querySelector('#updates').checked,
                  document.querySelector('#inside').dataset.clicked]);
                log('REPLAY ' + JSON.stringify(state));
                // Selectors emitted by 0.1.24 must work in saved scenarios too.
                await page.click('#updates');
                await page.click('text=Confirm choice');
                if (await page.evaluate(() => document.querySelector('#updates').checked)) throw Error('checkbox stayed on');
                await page.click('#field');
                await page.press('Meta+a');
                await page.press('Backspace');
                if (await page.inputValue('#field') !== '') throw Error('selection was not cleared');
                if (await page.evaluate(() => !!document.body.dataset.wrong)) throw Error('wrong button clicked');
                await page.evaluate(() => {
                  const copy = document.querySelector('.confirm').cloneNode(true);
                  copy.removeAttribute('id');
                  copy.onclick = () => { document.body.dataset.wrong = 'yes'; };
                  document.querySelector('.confirm').before(copy);
                });
                let ambiguous = false;
                try { await page.click('control={"selector":"button","text":"Confirm choice"}', {timeout: 500}); }
                catch (e) { ambiguous = String(e).includes('multiple controls match'); }
                if (!ambiguous || await page.evaluate(() => !!document.body.dataset.wrong)) throw Error('ambiguous click');
                let disabled = false;
                try { await page.click('#armed span', {timeout: 500}); }
                catch (e) { disabled = String(e).includes('is disabled'); }
                if (!disabled) throw Error('disabled button reported success');
                await page.evaluate(() => { setTimeout(() => document.querySelector('#armed').disabled = false, 800); });
                await page.click('#armed');
                if (!await page.evaluate(() => document.querySelector('#armed').dataset.clicked === 'yes')) throw Error('enabled button missed');
                let refusedOption = false;
                try { await page.selectOption('#choice', 'c'); }
                catch (e) { refusedOption = String(e).includes('is disabled'); }
                if (!refusedOption || await page.inputValue('#choice') !== 'b') throw Error('disabled group changed selection');
                await page.click('#edge');
                await page.evaluate(() => { setTimeout(() => document.querySelector('#transient').remove(), 800); });
                await page.click('#delayed');
                if (!await page.evaluate(() => ['edge','delayed'].every(id => document.getElementById(id).dataset.hit === '1')))
                  throw Error('partially or temporarily covered target missed');
                await page.evaluate(() => {
                  const spacer = document.createElement('div'), button = document.createElement('button');
                  spacer.id = 'loading-content'; button.id = 'shifted-button'; button.textContent = 'Continue';
                  button.onclick = () => { button.dataset.hit = String(Number(button.dataset.hit || 0) + 1); };
                  const cover = document.createElement('div'); cover.id = 'loading-cover';
                  cover.style.cssText = 'position:fixed;inset:0;background:silver;z-index:9000';
                  document.documentElement.style.overflowAnchor = 'none';
                  document.body.prepend(spacer, button, cover);
                  spacer.style.height = '160px'; window.scrollTo(0, 0);
                });
                let blocked = false;
                try { await page.click('#shifted-button', {timeout:500}); }
                catch (e) { blocked = String(e).includes('covered by #loading-cover'); }
                if (!blocked) throw Error('clicked through a visible cover');
                await page.evaluate(() => setTimeout(() => {
                  document.querySelector('#loading-content').style.height = (innerHeight * 2) + 'px';
                  document.querySelector('#loading-cover').remove();
                }, 800));
                await page.click('#shifted-button', {timeout:8000});
                if (await page.getAttribute('#shifted-button', 'data-hit') !== '1')
                  throw Error('target moved below the viewport and was not clicked exactly once');
                await page.click('#next');
                await page.waitForLoadState();
                if (await page.textContent('#heading') !== 'Page two') throw Error('link did not navigate');
                """
            let checks = [("Replay", replay + "\n" + verify, #"REPLAY ["1","Hello Ж🙂","b","yes",true,"yes"]"#),
                          ("Document transitions", documentTransitions, "DOCUMENTS finished")]
            for (name, source, expected) in checks {
                guard problems.isEmpty else { break }
                guard manager.runScenario(profile.id, name: name, source: source) else {
                    problems.append("\(name) did not start")
                    break
                }
                let deadline = Date().addingTimeInterval(100)
                while manager.scenarioRuns[profile.id]?.isRunning == true, seen.exited == nil, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                let checked = manager.scenarioRuns[profile.id]
                let lines = checked?.lines.map(\.text) ?? []
                if checked?.outcome != .finished || !lines.contains(expected) {
                    let state = checked?.isRunning == true ? "timed out" : "failed"
                    problems.append("\(name) \(state): " + lines.suffix(5).joined(separator: " / "))
                } else {
                    print("\(tag) LOG \(name) passed")
                }
            }
            if let exited = seen.exited { problems.append("the profile's process ended during the run (status \(exited))") }
        }
        if manager.isRunning(profile.id) { try? await manager.stop(profile.id) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if problems.isEmpty {
            print("\(tag) PASS a scenario ran in a window of Safari's: its click landed on the button, trusted, and its typing is in the field")
            return 0
        }
        print("\(tag) FAIL " + problems.joined(separator: "; "))
        return 1
    }

    /// What the run's end and log say against what a run in Safari's window must leave.
    private static func findings(outcome: ScenarioRunner.Outcome?, texts: [String]) -> [String] {
        var problems: [String] = []
        if outcome != .finished { problems.append("the run ended \(outcome.map { String(describing: $0) } ?? "not at all")") }
        if texts.first != "window: Safari's" { problems.append("the run's window was \(texts.first ?? "not said")") }
        guard let line = texts.first(where: { $0.hasPrefix("RESULT ") }),
              let result = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(7).utf8))) as? [String: Any] else {
            problems.append("the run's log has no result")
            return problems
        }
        let clicked = result["clicked"] as? String ?? "nothing"
        if clicked != "clicked 1" { problems.append("the button's count says \(clicked)") }
        let value = result["value"] as? String ?? "nothing"
        if value != "Hello Ж🙂" { problems.append("the field holds \(value)") }
        let box = (result["box"] as? [NSNumber])?.map(\.doubleValue) ?? []
        guard let click = result["click"] as? [String: Any], box.count == 4,
              let x = (click["clientX"] as? NSNumber)?.doubleValue, let y = (click["clientY"] as? NSNumber)?.doubleValue else {
            problems.append("the page recorded no click")
            return problems
        }
        if !(x >= box[0] && x <= box[2] && y >= box[1] && y <= box[3]) {
            problems.append("the click was at \(x), \(y), outside the button's box \(box)")
        }
        if click["trusted"] as? Bool != true { problems.append("the click was not a trusted event") }
        if click["target"] as? String != "button" { problems.append("the click's target was \(click["target"] ?? "none")") }
        return problems
    }
}
