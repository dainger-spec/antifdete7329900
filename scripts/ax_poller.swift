// An accessibility client that acts as the apps reading the focused field at every key press do —
// keyboard-layout switchers, grammar checkers, text expanders, password managers: while it runs,
// every 40 ms, it reads every attribute of the focused element of each running profile process
// (LumenProfile) and of that element's parent, and every parameterized attribute with the
// selected range, the whole text and an index. It counts the reads and the errors by code, and
// says once a few seconds what it saw. The address bar check runs beside it (address-bar probe):
// an exception of Safari's code under such a read reaches AppKit's run loop while the last event
// is the key press, which is when the profile's window put its notice up.
//
//   swiftc -O scripts/ax_poller.swift -o build/ax_poller && build/ax_poller <seconds>
//
// Prints AX-POLLER lines. Needs the accessibility permission (it says whether it has it).
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "600") ?? 600
print("AX-POLLER trusted for accessibility: \(AXIsProcessTrusted())")

var reads = 0
var errors: [Int32: Int] = [:]
var focusedSeen: Set<String> = []

func profilePIDs() -> [pid_t] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "LumenProfile"]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
}

func note(_ error: AXError) {
    guard error != .success, error != .noValue, error != .attributeUnsupported, error != .parameterizedAttributeUnsupported else { return }
    errors[error.rawValue, default: 0] += 1
}

func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
    reads += 1
    note(error)
    return error == .success ? result : nil
}

func readAll(_ element: AXUIElement) {
    var names: CFArray?
    note(AXUIElementCopyAttributeNames(element, &names))
    for name in (names as? [String]) ?? [] { _ = value(element, name) }
    var parameterized: CFArray?
    note(AXUIElementCopyParameterizedAttributeNames(element, &parameterized))
    let count = (value(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue ?? 0
    var ranges: [AXValue] = []
    if let selected = value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(selected) == AXValueGetTypeID() {
        ranges.append(selected as! AXValue)
    }
    var whole = CFRange(location: 0, length: count)
    if let range = AXValueCreate(.cfRange, &whole) { ranges.append(range) }
    for name in (parameterized as? [String]) ?? [] {
        var parameters: [CFTypeRef] = []
        if name.hasSuffix("ForRange") { parameters = ranges }
        if name.hasSuffix("ForIndex") || name.hasSuffix("ForLine") { parameters = [NSNumber(value: 0), NSNumber(value: max(count - 1, 0))] }
        for parameter in parameters {
            var result: CFTypeRef?
            reads += 1
            note(AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result))
        }
    }
}

let start = Date()
var lastSaid = Date()
var pids: [pid_t] = []
var pidsRead = Date.distantPast
while Date().timeIntervalSince(start) < seconds {
    if Date().timeIntervalSince(pidsRead) > 1 {
        pids = profilePIDs()
        pidsRead = Date()
    }
    for pid in pids {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let focused = value(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { continue }
        let element = focused as! AXUIElement
        if let role = value(element, kAXRoleAttribute) as? String, focusedSeen.insert("\(pid) \(role)").inserted {
            print("AX-POLLER the focused element of \(pid): \(role)")
        }
        readAll(element)
        if let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
            readAll(parent as! AXUIElement)
        }
    }
    if Date().timeIntervalSince(lastSaid) > 5 {
        lastSaid = Date()
        print("AX-POLLER \(reads) reads, profile processes \(pids), errors by code \(errors)")
    }
    usleep(40_000)
}
print("AX-POLLER done: \(reads) reads, errors by code \(errors)")
