import AppKit
import SwiftUI

/// The app's own help (the Profiles window's Help, Help › Lumen Help, ⌘?): what the command
/// palette, scenarios and the automation API are, how each is used, and the commands to copy — in
/// the app, in the interface's language. The owner, 10 November: the scenario editor was behind a
/// menu item, and what a scenario may say was written in the repository's docs only.
enum HelpTopic: String, CaseIterable, Identifiable {
    // The order of the topic list and of the Help menu: the app, what a profile has, automation, the keys.
    case start, palette, check, codes, camera, warmUp, virtualMachines, scenarios, commands, api, webdriver, keys

    var id: String { rawValue }

    /// The topics this build has something for: the virtual machines' only where the build carries
    /// them (`VMCenter.isOffered`).
    @MainActor static var shown: [HelpTopic] {
        allCases.filter { $0 != .virtualMachines || VMCenter.isOffered }
    }

    var title: String { L("help.topic.\(rawValue)") }

    var symbol: String {
        switch self {
        case .start: return "sparkles"
        case .palette: return "magnifyingglass"
        case .scenarios: return "play.rectangle"
        case .commands: return "chevron.left.forwardslash.chevron.right"
        case .api: return "terminal"
        case .webdriver: return "link"
        case .camera: return "camera"
        case .warmUp: return "flame"
        case .virtualMachines: return "macwindow.on.rectangle"
        case .codes: return "lock.rotation"
        case .check: return "checkmark.shield"
        case .keys: return "keyboard"
        }
    }
}

/// One piece of a help page. Every text is a key of the strings tables under `help.`; what is code
/// or keys is the same in every language and written here.
enum HelpBlock {
    case heading(String)
    case paragraph(String)
    /// Set apart: what the plan allows, what a token gives.
    case note(String)
    case steps([String])
    case points([String])
    /// To copy: its own text is a key too (a comment in it is in the interface's language).
    case code(String)
    case commands([(code: String, about: String)])
    case shortcuts([(keys: String, about: String)])
}

enum HelpContent {
    static func blocks(_ topic: HelpTopic) -> [HelpBlock] {
        switch topic {
        case .start:
            return [
                .paragraph("start.intro"),
                .heading("start.first"),
                .steps(["start.step.new", "start.step.launch", "start.step.proxies", "start.step.lock"]),
                .heading("start.where"),
                .points(["start.where.palette", "start.where.check", "start.where.codes", "start.where.scenarios", "start.where.api",
                         "start.where.more", "start.where.settings"]),
            ]
        case .palette:
            return [
                .paragraph("palette.intro"),
                .heading("palette.finds"),
                .points(["palette.finds.profiles", "palette.finds.actions", "palette.finds.settings", "palette.finds.report"]),
                .heading("palette.keys"),
                .shortcuts([("↑ ↓", "palette.key.choose"), ("↵", "palette.key.run"), ("esc", "palette.key.close")]),
            ]
        case .scenarios:
            return [
                .paragraph("scenarios.intro"),
                .note("scenarios.plan"),
                .heading("scenarios.how"),
                .steps(["scenarios.step.open", "scenarios.step.new", "scenarios.step.write", "scenarios.step.run", "scenarios.step.log"]),
                .heading("scenarios.example"),
                .code("scenarios.example.code"),
                .heading("scenarios.record"),
                .paragraph("scenarios.record.text"),
                .points(["scenarios.record.selectors", "scenarios.record.password", "scenarios.record.limits"]),
                .heading("scenarios.schedule"),
                .paragraph("scenarios.schedule.text"),
                .note("scenarios.schedule.running"),
                .heading("scenarios.know"),
                .points(["scenarios.know.window", "scenarios.know.await", "scenarios.know.errors", "scenarios.know.typed",
                         "scenarios.know.kept"]),
            ]
        case .commands:
            return [
                .paragraph("commands.intro"),
                .heading("commands.navigation"),
                .commands([
                    ("await page.goto(url)", "commands.goto"),
                    ("await page.back()\nawait page.forward()\nawait page.reload()", "commands.history"),
                    ("await page.waitForLoadState('load')", "commands.loadState"),
                ]),
                .heading("commands.waiting"),
                .commands([
                    ("await page.waitFor(selector)", "commands.waitFor"),
                    ("await sleep(1500)", "commands.sleep"),
                ]),
                .heading("commands.acting"),
                .commands([
                    ("await page.click(selector)", "commands.click"),
                    ("await page.dblclick(selector)", "commands.dblclick"),
                    ("await page.hover(selector)", "commands.hover"),
                    ("await page.type(selector, text)", "commands.type"),
                    ("await page.press('Enter')", "commands.press"),
                    ("await page.scroll(600)", "commands.scroll"),
                ]),
                .heading("commands.reading"),
                .commands([
                    ("await page.textContent(selector)\nawait page.innerText(selector)", "commands.text"),
                    ("await page.inputValue(selector)", "commands.inputValue"),
                    ("await page.getAttribute(selector, name)", "commands.getAttribute"),
                    ("await page.count(selector)", "commands.count"),
                    ("await page.isVisible(selector)", "commands.isVisible"),
                    ("await page.url()\nawait page.title()", "commands.url"),
                    ("await page.evaluate(() => document.title)", "commands.evaluate"),
                    ("await page.screenshot()", "commands.screenshot"),
                ]),
                .heading("commands.script"),
                .commands([
                    ("log('…', value)", "commands.log"),
                    ("params", "commands.params"),
                ]),
            ]
        case .api:
            return [
                .paragraph("api.intro"),
                .note("api.plan"),
                .heading("api.on"),
                .steps(["api.step.open", "api.step.enable", "api.step.token", "api.step.unlocked"]),
                .heading("api.try"),
                .code("api.try.code"),
                .heading("api.requests"),
                .commands([
                    ("GET /v1/profiles", "api.request.list"),
                    ("GET /v1/profiles/{profile}", "api.request.one"),
                    ("POST /v1/profiles/{profile}/start", "api.request.start"),
                    ("POST /v1/profiles/{profile}/stop", "api.request.stop"),
                    ("POST /v1/profiles/{profile}/open", "api.request.open"),
                    ("GET /v1/profiles/{profile}/cookies", "api.request.cookies"),
                    ("POST /v1/profiles/{profile}/cookies", "api.request.importCookies"),
                    ("POST /v1/profiles/{profile}/scenario", "api.request.scenario"),
                    ("GET /v1/profiles/{profile}/scenario", "api.request.scenarioState"),
                    ("POST /v1/profiles/{profile}/scenario/stop", "api.request.scenarioStop"),
                ]),
                .heading("api.scenario"),
                .code("api.scenario.code"),
                .heading("api.webdriver"),
                .paragraph("api.webdriver.see"),
                .heading("api.errors"),
                .paragraph("api.errors.text"),
                .note("api.token"),
            ]
        case .webdriver:
            return [
                .paragraph("api.webdriver.text"),
                .note("webdriver.plan"),
                .heading("webdriver.connect"),
                .steps(["api.webdriver.step.on", "api.webdriver.step.copy", "api.webdriver.step.script"]),
                .heading("webdriver.example"),
                .code("api.webdriver.code"),
                .heading("webdriver.know"),
                .points(["api.webdriver.session", "api.webdriver.human", "api.webdriver.scripts", "api.webdriver.limits",
                         "api.webdriver.playwright"]),
                .note("api.token"),
            ]
        case .camera:
            return [
                .paragraph("camera.intro"),
                .note("camera.plan"),
                .heading("camera.turnOn"),
                .steps(["camera.step.edit", "camera.step.mode", "camera.step.source", "camera.step.tune", "camera.step.save"]),
                .heading("camera.sources"),
                .points(["camera.source.color", "camera.source.bars", "camera.source.image", "camera.source.video"]),
                .heading("camera.tuning"),
                .points(["camera.tune.resolution", "camera.tune.label", "camera.tune.audio", "camera.tune.mirror", "camera.tune.screen"]),
                .heading("camera.know"),
                .note("camera.secure"),
                .points(["camera.know.system", "camera.know.systemInstall", "camera.know.safari", "camera.know.detect",
                         "camera.know.permission", "camera.know.size"]),
            ]
        case .warmUp:
            return [
                .paragraph("warmUp.intro"),
                .heading("warmUp.start"),
                .steps(["warmUp.step.open", "warmUp.step.choose", "warmUp.step.depth", "warmUp.step.start"]),
                .heading("warmUp.how"),
                .points(["warmUp.how.pages", "warmUp.how.search", "warmUp.how.links", "warmUp.how.consent"]),
                .heading("warmUp.several"),
                .points(["warmUp.several.queue", "warmUp.several.schedule", "warmUp.several.last"]),
                .heading("warmUp.know"),
                .points(["warmUp.know.stop", "warmUp.know.limits", "warmUp.know.local"]),
            ]
        case .virtualMachines:
            return [
                .paragraph("vm.intro"),
                .note("vm.plan"),
                .heading("vm.add"),
                .steps(["vm.step.open", "vm.step.download", "vm.step.setup", "vm.step.tools", "vm.step.create"]),
                .heading("vm.what"),
                .points(["vm.what.system", "vm.what.proxy", "vm.what.locale", "vm.what.screen"]),
                .heading("vm.costs"),
                .points(["vm.costs.disk", "vm.costs.memory", "vm.costs.limit", "vm.costs.start"]),
                .heading("vm.know"),
                .note("vm.know.disks"),
                .points(["vm.know.udp", "vm.know.updates", "vm.know.base", "vm.know.license", "vm.know.local"]),
            ]
        case .check:
            return [
                .paragraph("check.intro"),
                .heading("check.run"),
                .steps(["check.step.open", "check.step.press", "check.step.read", "check.step.fix"]),
                .heading("check.what"),
                .points(["check.what.proxy", "check.what.timeZone", "check.what.language", "check.what.geolocation",
                         "check.what.webRTC", "check.what.dns", "check.what.engine", "check.what.window"]),
                .note("check.geolocation.engine"),
                .heading("check.know"),
                .note("check.local"),
                .points(["check.know.restart", "check.know.unknown", "check.know.dns", "check.know.signals"]),
            ]
        case .codes:
            return [
                .paragraph("codes.intro"),
                .heading("codes.add"),
                .steps(["codes.step.site", "codes.step.open", "codes.step.secret", "codes.step.save"]),
                .heading("codes.use"),
                .points(["codes.use.copy", "codes.use.fill", "codes.use.only"]),
                .heading("codes.know"),
                .note("codes.backup"),
                .points(["codes.know.screen", "codes.know.kinds", "codes.know.clock", "codes.know.older"]),
            ]
        case .keys:
            return [
                .heading("keys.app"),
                .shortcuts([("⌘K", "keys.palette"), ("⌘N", "keys.newProfile"), ("⇧⌘E", "keys.scenarios"), ("⌘,", "keys.settings"),
                            ("⌘?", "keys.help")]),
                .heading("keys.window"),
                .paragraph("keys.window.note"),
                .shortcuts([("⌘T", "keys.newTab"), ("⇧⌘T", "keys.reopenTab"), ("⌘L", "keys.address"), ("⌘R", "keys.reload"),
                            ("⌘[  ⌘]", "keys.backForward"), ("⌃⇥  ⌃⇧⇥", "keys.tabs"), ("⌘1 … ⌘9", "keys.tabNumber"),
                            ("⌘D", "keys.bookmark"), ("⌥⌘B", "keys.bookmarks"), ("⌘Y", "keys.history"), ("⌃⌘V", "keys.pasteAsTyped")]),
                .heading("keys.scenarioEditor"),
                .shortcuts([("⌘S", "keys.saveScenario"), ("⌘R", "keys.runScenario")]),
            ]
        }
    }

    /// A key of the strings tables for a block's text.
    static func text(_ name: String) -> String { L("help.\(name)") }
}

/// The Help window: the topics on the left, the chosen one's page on the right.
struct HelpView: View {
    @Binding var topic: HelpTopic

    var body: some View {
        HStack(spacing: 0) {
            topics
                .frame(width: 230)
                .background(Theme.sidebar)
            Rectangle().fill(Theme.divider).frame(width: 1)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface)
        }
        .frame(minWidth: 860, minHeight: 560)
        .environment(\.colorScheme, .dark)
    }

    private var topics: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("help.title"))
                .font(.lumenSection)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                // Below the title bar's band, where the window's traffic lights are.
                .padding(.top, 38)
                .padding(.bottom, 10)
            ForEach(HelpTopic.shown) { item in
                Button { topic = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(topic == item ? Theme.textPrimary : Theme.textTertiary)
                            .frame(width: 18)
                        Text(item.title)
                            .font(.lumenBody)
                            .foregroundStyle(topic == item ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(topic == item ? Theme.rowSelected : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(topic == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    /// The topic's title stays above the page: the scroll view starts below the title bar's band
    /// (one that reaches under it gets macOS 26's edge effect, `ProfilesScreen.inspectorTop`).
    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(topic.title)
                .font(.lumenHeading)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 32)
                .padding(.top, 40)
                .padding(.bottom, 16)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(HelpContent.blocks(topic).enumerated()), id: \.offset) { _, block in
                        HelpBlockView(block: block)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Another topic starts at its top.
            .id(topic)
        }
    }
}

private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .heading(let name): heading(HelpContent.text(name))
        case .paragraph(let name): prose(HelpContent.text(name))
        case .note(let name): note(HelpContent.text(name))
        case .steps(let names): lines(names, numbered: true)
        case .points(let names): lines(names, numbered: false)
        case .code(let name): HelpCode(code: HelpContent.text(name))
        case .commands(let rows): commands(rows)
        case .shortcuts(let rows): shortcuts(rows)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.lumenSheetTitle)
            .foregroundStyle(Theme.textPrimary)
            .padding(.top, 10)
            .accessibilityAddTraits(.isHeader)
    }

    private func prose(_ text: String, color: Color = Theme.textSecondary) -> some View {
        Text(text)
            .font(.lumenBody)
            .foregroundStyle(color)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        return prose(text, color: Theme.textPrimary)
            .padding(12)
            .background(shape.fill(Theme.card))
            .overlay(shape.strokeBorder(Theme.divider, lineWidth: 1))
    }

    /// Steps by their numbers, or points by a dot.
    private func lines(_ names: [String], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: numbered ? "\(index + 1)" : "•")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                        .frame(width: 16, alignment: .trailing)
                    prose(HelpContent.text(name))
                }
            }
        }
    }

    /// What to write, and beside it what it does.
    private func commands(_ rows: [(code: String, about: String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(verbatim: row.code)
                        .font(.lumenMono)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 310, alignment: .leading)
                    prose(HelpContent.text(row.about))
                }
                .padding(.vertical, 9)
            }
        }
    }

    private func shortcuts(_ rows: [(keys: String, about: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .center, spacing: 14) {
                    KeyCap(keys: row.keys)
                        .frame(width: 110, alignment: .leading)
                    prose(HelpContent.text(row.about))
                }
            }
        }
    }
}

/// Code to copy: in a fixed-width font, selectable, with Copy at its corner.
private struct HelpCode: View {
    let code: String
    @State private var copied = false

    var body: some View {
        Text(verbatim: code)
            .font(.lumenMono)
            .foregroundStyle(Theme.textPrimary)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 14)
            .padding(.trailing, 96)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Button(copied ? L("help.copied") : L("help.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
                .buttonStyle(.lumenGhost)
                .padding(6)
            }
    }
}
