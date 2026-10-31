// Measurement only, never merged: the windows on screen while Safari runs a page's Web
// Authentication ceremonies — every one that comes or goes, with its owner, every 25 ms — and, 3 s
// after a ceremony begins (a line "begin create …" or "begin get …" in the trigger file, written by
// scripts/payments_check.py's page server), a picture of the screen, the Cancel button of each window
// that came since pressed through Accessibility where this process may, and Escape posted as the
// keyboard would post it. What each of those did is printed; whether Safari took them is the page's
// answer.
//
//   sheet_watch TRIGGER_FILE SECONDS PICTURES_DIR
import AppKit
import ApplicationServices
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments
let triggerPath = arguments.count > 1 ? arguments[1] : "/tmp/pb-sheet-trigger"
let seconds = arguments.count > 2 ? (Double(arguments[2]) ?? 300) : 300
let pictures = arguments.count > 3 ? arguments[3] : NSTemporaryDirectory()

func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

print("SHEET-WATCH start \(now()); this process may use Accessibility: \(AXIsProcessTrusted())")

struct Seen {
    let text: String
    let pid: pid_t
    let since: Int64
}

var known: [Int: Seen] = [:]
var linesDone = 0
var due: [(at: Int64, step: String, began: Int64)] = []

func attribute(_ element: AXUIElement, _ name: String) -> (AnyObject?, AXError) {
    var value: AnyObject?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (value, error)
}

/// The Cancel-like buttons under `element`, depth first, at most `depth` levels down.
func buttons(under element: AXUIElement, depth: Int, found: inout [(AXUIElement, String)]) {
    guard depth > 0 else { return }
    let (children, _) = attribute(element, kAXChildrenAttribute)
    for child in (children as? [AXUIElement]) ?? [] {
        let (role, _) = attribute(child, kAXRoleAttribute)
        let (title, _) = attribute(child, kAXTitleAttribute)
        let (description, _) = attribute(child, kAXDescriptionAttribute)
        if (role as? String) == (kAXButtonRole as String) {
            let label = (title as? String) ?? (description as? String) ?? ""
            found.append((child, label))
        }
        buttons(under: child, depth: depth - 1, found: &found)
    }
}

func cancelThroughAccessibility(pids: Set<pid_t>) {
    for pid in pids.sorted() {
        let application = AXUIElementCreateApplication(pid)
        let (windows, error) = attribute(application, kAXWindowsAttribute)
        guard error == .success, let list = windows as? [AXUIElement] else {
            print("SHEET-WATCH \(now()) accessibility of pid \(pid): \(error.rawValue)")
            continue
        }
        for window in list {
            let (title, _) = attribute(window, kAXTitleAttribute)
            let (subrole, _) = attribute(window, kAXSubroleAttribute)
            var found: [(AXUIElement, String)] = []
            buttons(under: window, depth: 8, found: &found)
            print("SHEET-WATCH \(now()) pid \(pid) window \"\((title as? String) ?? "")\" (\((subrole as? String) ?? "?")): buttons "
                  + found.map { "\"\($0.1)\"" }.joined(separator: ", "))
            for (button, label) in found where ["cancel", "отменить", "not now"].contains(label.lowercased()) {
                let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                print("SHEET-WATCH \(now()) pressed \"\(label)\" in pid \(pid): \(result.rawValue)")
            }
        }
    }
}

let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var current: [Int: Seen] = [:]
    for info in list {
        guard let number = info[kCGWindowNumber as String] as? Int else { continue }
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = pid_t(info[kCGWindowOwnerPID as String] as? Int ?? 0)
        let name = info[kCGWindowName as String] as? String ?? ""
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        func edge(_ key: String) -> Int { Int((bounds[key] as? Double) ?? Double(bounds[key] as? Int ?? 0)) }
        let text = "\(owner)[\(pid)] layer \(layer) at \(edge("X")),\(edge("Y")) \(edge("Width"))x\(edge("Height")) \"\(name)\""
        current[number] = known[number] ?? Seen(text: text, pid: pid, since: now())
    }
    for (number, seen) in current where known[number] == nil { print("SHEET-WATCH \(now()) + #\(number) \(seen.text)") }
    for (number, seen) in known where current[number] == nil { print("SHEET-WATCH \(now()) - #\(number) \(seen.text)") }
    known = current

    if let text = try? String(contentsOfFile: triggerPath, encoding: .utf8) {
        let lines = text.split(separator: "\n")
        while linesDone < lines.count {
            let words = lines[linesDone].split(separator: " ").map(String.init)
            linesDone += 1
            print("SHEET-WATCH \(now()) trigger: \(words.joined(separator: " "))")
            if words.count >= 2, words[0] == "begin", ["create", "get"].contains(words[1]) {
                due.append((now() + 3000, words[1], now()))
            }
        }
    }

    let ready = due.filter { $0.at <= now() }
    due.removeAll { $0.at <= now() }
    for item in ready {
        let picture = "\(pictures)/sheet-\(item.step)-\(now()).png"
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", picture]
        do {
            try capture.run()
            capture.waitUntilExit()
            print("SHEET-WATCH \(now()) picture \(picture): exit \(capture.terminationStatus)")
        } catch {
            print("SHEET-WATCH \(now()) picture: \(error)")
        }
        let newer = Set(known.values.filter { $0.since >= item.began }.map(\.pid))
        print("SHEET-WATCH \(now()) \(item.step): windows that came since it began, by pid: \(newer.sorted())")
        cancelThroughAccessibility(pids: newer)
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: down)?.post(tap: .cghidEventTap)
        }
        print("SHEET-WATCH \(now()) Escape posted for \(item.step)")
    }
    usleep(25_000)
}
print("SHEET-WATCH end \(now())")
