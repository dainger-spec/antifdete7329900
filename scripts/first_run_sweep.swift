// The app's first run as a new tester has it, with real input (CI's sweep, .github/workflows/sweep.yml):
//
//   swiftc -O -o build/first-run-sweep scripts/first_run_sweep.swift
//   build/first-run-sweep build/unsandboxed/Lumen.app build/sweep/first-run
//
// Starts the app as a person opens it — no vault, no preferences of its own (scripts/sweep_state.sh
// removes them first) — and goes on through what it shows, screen by screen: the welcome, the master
// password's setup (typed key by key, its "written down" box ticked, Return), the account's screens,
// the empty profile list, a first profile made and opened. At every screen it keeps a picture of the
// screen and the window's accessibility tree, and says what it did there. It acts only with the
// window server's own events (clicks at an element's place, keys), finding elements through the
// accessibility API as VoiceOver does. What went wrong is for scripts/sweep.py's companion lines:
// the app's exceptions are in its log, a crash in DiagnosticReports. Prints FIRST-RUN lines; exit 0
// when it got to a profile's window, 1 when it stopped before.
import AppKit
import ApplicationServices
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: first-run-sweep <Lumen.app> <out folder>")
    exit(2)
}
let appPath = arguments[1]
let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let password = "Sweep-tea-hillside-2026!"

func say(_ text: String) { print("FIRST-RUN \(text)") }
func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

say("accessibility trusted: \(AXIsProcessTrusted())")

// MARK: Real input

let source = CGEventSource(stateID: .hidSystemState)

func click(_ point: CGPoint) {
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.post(tap: .cghidEventTap)
        pause(0.06)
    }
}

func key(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
        event.flags = flags
        if let text {
            var units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        }
        event.post(tap: .cghidEventTap)
        pause(0.03)
    }
    pause(0.04)
}

func type(_ text: String) {
    for character in text { key(0, text: String(character)) }
}

// MARK: The accessibility tree

struct Node {
    let element: AXUIElement
    let role: String
    let subrole: String
    let title: String
    let label: String
    let identifier: String
    let value: String
    let enabled: Bool
    let frame: CGRect
    let depth: Int

    var name: String { [title, label, identifier].first { !$0.isEmpty } ?? "" }
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func frame(of element: AXUIElement) -> CGRect {
    var point = CGPoint.zero
    var size = CGSize.zero
    if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
    }
    if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
        AXValueGetValue(value as! AXValue, .cgSize, &size)
    }
    return CGRect(origin: point, size: size)
}

func nodes(under root: AXUIElement) -> [Node] {
    var found: [Node] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard depth < 45, found.count < 1500 else { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        let secure = subrole == (kAXSecureTextFieldSubrole as String)
        let value = secure ? "" : (attribute(element, kAXValueAttribute).map { String(describing: $0) } ?? "")
        found.append(Node(element: element, role: role, subrole: subrole,
                          title: attribute(element, kAXTitleAttribute) as? String ?? "",
                          label: attribute(element, kAXDescriptionAttribute) as? String ?? "",
                          identifier: attribute(element, kAXIdentifierAttribute) as? String ?? "",
                          value: String(value.prefix(80)),
                          enabled: (attribute(element, kAXEnabledAttribute) as? Bool) ?? true,
                          frame: frame(of: element), depth: depth))
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1) }
    }
    walk(root, 0)
    return found
}

func describe(_ list: [Node]) -> String {
    list.map { node in
        String(repeating: "  ", count: node.depth) + "\(node.role)\(node.subrole.isEmpty ? "" : "/" + node.subrole) "
            + "'\(node.title)' '\(node.label)' id=\(node.identifier) value='\(node.value)' "
            + "\(node.enabled ? "" : "(off) ")\(Int(node.frame.minX)),\(Int(node.frame.minY)) \(Int(node.frame.width))×\(Int(node.frame.height))"
    }.joined(separator: "\n")
}

// MARK: The app

let process = Process()
process.executableURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/MacOS/Lumen")
let outputPath = out.appendingPathComponent("app-output.txt").path
FileManager.default.createFile(atPath: outputPath, contents: nil)
if let log = FileHandle(forWritingAtPath: outputPath) {
    process.standardOutput = log
    process.standardError = log
}
do {
    try process.run()
} catch {
    say("the app did not start: \(error)")
    exit(1)
}
let pid = process.processIdentifier
say("the app started: \(pid)")
let app = AXUIElementCreateApplication(pid)
pause(4)

/// Buttons a step may press, in the order it prefers them, by the words on them (English and Russian).
let preferred = ["Get started", "Начать", "Continue", "Продолжить", "Create Vault", "Создать хранилище", "Later", "Позже",
                 "Not now", "Не сейчас", "Skip", "Пропустить", "New Profile", "Новый профиль", "Create Profile", "Создать профиль",
                 "Create", "Создать", "Save", "Сохранить", "Open", "Открыть", "Launch", "Запустить", "OK", "Done", "Готово"]
var pressed: [String: Int] = [:]
var reachedProfile = false
var typedOn: Set<String> = []

for step in 1...16 {
    guard process.isRunning else {
        say("step \(step): the app is no longer running (status \(process.terminationStatus))")
        break
    }
    let shot = out.appendingPathComponent(String(format: "step-%02d.png", step)).path
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", shot]
    try? capture.run()
    capture.waitUntilExit()

    let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let titles = windows.map { attribute($0, kAXTitleAttribute) as? String ?? "" }
    let all = windows.flatMap { nodes(under: $0) }
    try? describe(all).write(to: out.appendingPathComponent(String(format: "step-%02d.txt", step)), atomically: true, encoding: .utf8)
    // A profile's window is another process's: the app's own windows are the manager's.
    let profiles = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(path: appPath)?.bundleIdentifier ?? "")
        .filter { $0.processIdentifier != pid }
    say("step \(step): windows \(titles); \(all.count) elements; other processes of the app \(profiles.count)")
    if !profiles.isEmpty, step > 2 {
        reachedProfile = true
        say("step \(step): a profile's process runs (\(profiles.map(\.processIdentifier)))")
        break
    }
    NSRunningApplication(processIdentifier: pid)?.activate()
    pause(0.5)

    let secure = all.filter { $0.subrole == (kAXSecureTextFieldSubrole as String) && $0.enabled && $0.frame.width > 0 }
    let fields = all.filter { $0.role == (kAXTextFieldRole as String) && $0.subrole != (kAXSecureTextFieldSubrole as String) && $0.enabled && $0.frame.width > 0 }
    let signature = titles.joined() + "|" + secure.map(\.name).joined() + fields.map(\.name).joined()
    if !secure.isEmpty, !typedOn.contains(signature) {
        typedOn.insert(signature)
        // An account's screen asks an address too: one that goes nowhere.
        for field in fields where field.value.isEmpty {
            click(field.center)
            type(field.name.lowercased().contains("mail") || field.name.lowercased().contains("почт") ? "tester@example.invalid" : "Sweep")
        }
        for field in secure {
            click(field.center)
            key(0, flags: .maskCommand)  // ⌘A
            type(password)
        }
        for box in all where box.role == (kAXCheckBoxRole as String) && box.enabled && box.value == "0" {
            click(box.center)
        }
        pause(0.5)
        key(36)  // Return
        say("step \(step): typed into \(secure.count) password field(s) and \(fields.count) field(s), ticked the boxes, Return")
        pause(5)
        continue
    }
    let buttons = all.filter { $0.role == (kAXButtonRole as String) && $0.enabled && $0.frame.width > 0 && !$0.name.isEmpty }
    var chosen: Node?
    for word in preferred {
        if let button = buttons.first(where: { $0.name.localizedCaseInsensitiveContains(word) && (pressed[$0.name] ?? 0) < 2 }) {
            chosen = button
            break
        }
    }
    if let chosen {
        pressed[chosen.name, default: 0] += 1
        click(chosen.center)
        say("step \(step): clicked '\(chosen.name)'")
        pause(4)
        continue
    }
    if !fields.isEmpty, !typedOn.contains(signature) {
        typedOn.insert(signature)
        click(fields[0].center)
        type("Sweep first profile")
        key(36)
        say("step \(step): typed a name into '\(fields[0].name)', Return")
        pause(4)
        continue
    }
    // Nothing to press by name: the default action (Return), once, then ⌘N for a new profile.
    if (pressed["⏎"] ?? 0) < 1 {
        pressed["⏎", default: 0] += 1
        key(36)
        say("step \(step): Return (no button to press by name: \(buttons.map(\.name).prefix(12)))")
    } else if (pressed["⌘N"] ?? 0) < 1 {
        pressed["⌘N", default: 0] += 1
        key(45, flags: .maskCommand)
        say("step \(step): ⌘N")
    } else {
        say("step \(step): nothing more to do here; the buttons: \(buttons.map(\.name).prefix(20))")
        break
    }
    pause(4)
}

let alive = process.isRunning
say("the app is \(alive ? "running" : "gone (status \(process.terminationStatus))"); a profile's window reached: \(reachedProfile)")
if alive {
    process.terminate()
    pause(5)
}
for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(path: appPath)?.bundleIdentifier ?? "") {
    other.forceTerminate()
}
exit(reachedProfile && alive ? 0 : 1)
