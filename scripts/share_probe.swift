// Measurement (never merged): which of the system's sharing services a page's address can be
// handed to on this Mac, and which of them — or the share picker itself — fetches the address on
// its own (a link preview), outside any proxy a profile has. The address is a canary on this
// Mac's network address (scripts/share_check.py serves it and logs every request); a request
// that arrives came from the system, not from a profile.
//
//     swiftc -o build/share-probe scripts/share_probe.swift && build/share-probe http://<address>:<port>
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let base = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "http://127.0.0.1:9/"
let application = NSApplication.shared
application.setActivationPolicy(.regular)

func nameOf(_ service: NSSharingService) -> String {
    let selector = NSSelectorFromString("name")
    guard service.responds(to: selector), let value = service.perform(selector)?.takeUnretainedValue() else { return "?" }
    return String(describing: value)
}

func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

Task { @MainActor in
    print("SHARE macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    let listed = NSSharingService.sharingServices(forItems: [URL(string: base + "list")!])
    for (index, service) in listed.enumerated() {
        let name = nameOf(service)
        print("SHARE service \(index): title \"\(service.title)\", name \(name)")
    }
    // The picker, shown over a window, as a Share button shows it: does it fetch for its header?
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    print("SHARE picker: showing")
    let picker = NSSharingServicePicker(items: [URL(string: base + "picker")!])
    picker.show(relativeTo: NSRect(x: 180, y: 140, width: 40, height: 20), of: window.contentView!, preferredEdge: .minY)
    await wait(10)
    print("SHARE picker: shown 10 s")
    window.orderOut(nil)
    await wait(2)
    // Each service performed with the address, as choosing it in the picker performs it.
    for (index, service) in listed.enumerated() {
        let name = nameOf(service)
        let item = URL(string: base + "perform/\(index)")!
        let can = service.canPerform(withItems: [item])
        print("SHARE perform \(index) (\(name)): can \(can) — start")
        if can { service.perform(withItems: [item]) }
        await wait(12)
        print("SHARE perform \(index) (\(name)): waited 12 s")
        // Close what it opened: a sheet of ours, its window.
        for other in application.windows where other.isVisible { other.orderOut(nil) }
    }
    print("SHARE done")
    exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 600) { print("SHARE timeout"); exit(1) }
application.run()
