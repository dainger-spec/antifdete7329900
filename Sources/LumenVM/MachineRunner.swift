#if arch(arm64)
import AppKit
import BrowserCore
import Foundation
import Virtualization
import VMNetCore

/// A machine's network card, and what is at its other end.
///
/// Direct: Apple's NAT — this Mac's own connection. With a proxy: the card is a socket whose other
/// end is the app's own network (`VMNetCore`), which carries every connection of the guest through
/// the profile's proxy and has no other way out, so a guest whose proxy is down reaches nothing.
/// Closed: the same network with no way out at all.
final class MachineNetwork {
    let attachment: VZNetworkDeviceAttachment
    private let network: VMNetwork?
    private let descriptor: Int32

    init(request: VMHelperRequest) throws {
        if request.network == .direct {
            attachment = VZNATNetworkDeviceAttachment()
            network = nil
            descriptor = -1
            return
        }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for end in pair {
            // Room for a burst of frames each way: a full buffer is a lost frame, which TCP then
            // has to send again.
            var receive: Int32 = 4 << 20, send: Int32 = 1 << 20
            setsockopt(end, SOL_SOCKET, SO_RCVBUF, &receive, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(end, SOL_SOCKET, SO_SNDBUF, &send, socklen_t(MemoryLayout<Int32>.size))
        }
        attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: FileHandle(fileDescriptor: pair[0], closeOnDealloc: true))
        descriptor = pair[1]

        let guestMAC = request.macAddress.flatMap(VMNetMAC.init(string:)) ?? VMNetMAC(bytes: [0x02, 0x1A, 0x11, 0x00, 0x00, 0x02])
        // The guest's address on its own little network, as a Mac has one behind a home router:
        // 192.168.1.x, x from its card's address so that it stays the same from start to start.
        let last = 2 + guestMAC.bytes.reduce(0) { ($0 &* 31 &+ Int($1)) % 200 }
        var upstream = VMNetUpstream.none
        if request.network == .proxy, let proxy = request.proxy, !proxy.tlsToProxy {
            switch proxy.kind {
            case .socks5: upstream = .socks5(host: proxy.host, port: proxy.port, username: proxy.username, password: proxy.password)
            case .httpConnect: upstream = .httpConnect(host: proxy.host, port: proxy.port, username: proxy.username, password: proxy.password)
            }
        }
        let configuration = VMNetConfiguration(guestMAC: guestMAC, gatewayMAC: VMNetMAC(bytes: [0x02, 0x1A, 0x11, 0x00, 0x00, 0x01]),
                                               gatewayAddress: VMNetIPv4(string: "192.168.1.1")!,
                                               guestAddress: VMNetIPv4(string: "192.168.1.\(last)")!,
                                               prefixLength: 24, upstream: upstream, blockedHostSuffixes: request.blockedHosts)
        let network = VMNetwork(configuration: configuration, frameDescriptor: descriptor)
        self.network = network
        network.start()
    }

    /// What went through the proxy so far; nil for a direct machine (Apple's NAT does not say).
    func counters() -> VMNetCounters? { network?.counters() }

    func stop() {
        network?.stop()
        if descriptor >= 0 { close(descriptor) }
    }
}

/// Runs a profile's machine (or the base, while it is being set up) in a window, until its macOS
/// has shut down.
final class MachineRunner: NSObject, VZVirtualMachineDelegate, NSWindowDelegate {
    private let request: VMHelperRequest
    private var files: VMLibrary.MachineFiles!
    private var machine: VZVirtualMachine?
    private var network: MachineNetwork?
    private var window: NSWindow?
    private var trafficTimer: Timer?
    private var lastTraffic: VMNetCounters?
    private var stopping = false
    private var finished = false

    init(request: VMHelperRequest) {
        self.request = request
    }

    var isRunning: Bool { machine != nil && !finished }

    private func text(_ key: String, _ fallback: String) -> String { request.texts[key] ?? fallback }

    func run() {
        guard let directory = request.machineDirectory else { HelperIO.fail("The request names no machine.") }
        files = VMLibrary.MachineFiles(directory: URL(fileURLWithPath: directory, isDirectory: true))
        do {
            try prepareMachine()
            guard let hardwareModel = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: files.hardwareModel)),
                  hardwareModel.isSupported else {
                HelperIO.fail("This machine's macOS cannot run on this Mac (its virtual Mac model is not supported here).")
            }
            guard let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: files.machineIdentifier)) else {
                HelperIO.fail("This machine's identifier cannot be read.")
            }
            // A request the guest made before, and never took: not this start's.
            try? FileManager.default.removeItem(at: shutdownRequestURL)
            let network = try MachineNetwork(request: request)
            self.network = network
            let configuration = try MachineConfiguration.make(files: files, request: request, hardwareModel: hardwareModel,
                                                              machineIdentifier: identifier,
                                                              auxiliaryStorage: VZMacAuxiliaryStorage(url: files.auxiliaryStorage),
                                                              network: network.attachment)
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = self
            self.machine = machine
            showWindow(for: machine)
            machine.start { result in
                DispatchQueue.main.async {
                    switch result {
                    case .failure(let error): self.fail(error)
                    case .success: HelperIO.emit(VMHelperEvent(kind: .started))
                    }
                }
            }
            HelperIO.readCommands { [weak self] command in
                switch command {
                case "stop": self?.stop(asking: false)
                case "kill": self?.forceStop()
                default: break
                }
            }
            trafficTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reportTraffic() }
        } catch {
            fail(error)
        }
    }

    // MARK: The machine's files

    /// A profile's machine that has no disk yet is made from the base: its disk a copy-on-write
    /// clone (no room taken until the two differ), its firmware variables a copy, and an identifier
    /// of its own — to macOS inside, and to Apple's services, another Mac than the base and than
    /// every other profile's.
    private func prepareMachine() throws {
        guard !files.isComplete else { return }
        guard let basePath = request.baseDirectory else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "This machine has no disk, and no base system to make it from."])
        }
        let base = VMLibrary.MachineFiles(directory: URL(fileURLWithPath: basePath, isDirectory: true))
        guard base.isComplete else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The base system is not installed."])
        }
        let manager = FileManager.default
        try manager.createDirectory(at: files.share, withIntermediateDirectories: true)
        // What a clone that stopped part-way left.
        for url in [files.disk, files.auxiliaryStorage, files.hardwareModel, files.machineIdentifier] { try? manager.removeItem(at: url) }
        let cloning = files.directory.appendingPathComponent("disk.img.cloning")
        try? manager.removeItem(at: cloning)
        if clonefile(base.disk.path, cloning.path, 0) != 0 {
            // Not a volume that clones (not APFS): a whole copy.
            try manager.copyItem(at: base.disk, to: cloning)
        }
        try manager.copyItem(at: base.auxiliaryStorage, to: files.auxiliaryStorage)
        try manager.copyItem(at: base.hardwareModel, to: files.hardwareModel)
        try manager.moveItem(at: cloning, to: files.disk)
        // Last: with it the machine is whole.
        try VZMacMachineIdentifier().dataRepresentation.write(to: files.machineIdentifier)
    }

    // MARK: The window

    private func showWindow(for machine: VZVirtualMachine) {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        // The guest's screen stays the Mac's it is, whatever size this window has: scaled, not changed.
        view.automaticallyReconfiguresDisplay = false

        let display = request.display
        let scale: CGFloat = display.pixelsPerInch >= 150 ? 2 : 1
        var size = NSSize(width: CGFloat(display.pixelsWide) / scale, height: CGFloat(display.pixelsHigh) / scale)
        if let visible = NSScreen.main?.visibleFrame.size {
            let fit = min(1, min(visible.width * 0.92 / size.width, (visible.height * 0.92 - 28) / size.height))
            size = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = request.windowTitle
        window.contentAspectRatio = NSSize(width: display.pixelsWide, height: display.pixelsHigh)
        window.contentMinSize = NSSize(width: 480, height: 480 * CGFloat(display.pixelsHigh) / CGFloat(display.pixelsWide))
        window.contentView = view
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
        installMenu()
        // In the Dock as the app it is part of, not as a bare executable.
        if Bundle.main.bundleURL.pathExtension == "app" {
            NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The app menu's one command: the keys themselves go to the guest (⌘Q quits an app in it).
    private func installMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        let menu = NSMenu()
        let stop = NSMenuItem(title: text("stop", "Shut Down the Virtual Machine…"), action: #selector(stopFromMenu), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        item.submenu = menu
        main.addItem(item)
        NSApp.mainMenu = main
    }

    @objc private func stopFromMenu() { stop(asking: true) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stop(asking: true)
        return false
    }

    // MARK: Stopping

    /// Where the guest's boot script looks for a request to shut down (Resources/VMGuest).
    private var shutdownRequestURL: URL { files.share.appendingPathComponent("lumen-shutdown") }

    /// Shuts the guest's macOS down as its own menu would — first by asking its boot script (a
    /// file in the shared folder, taken within seconds, with no question on the guest's screen),
    /// then by the power button, and after a minute by ending the machine.
    func stop(asking: Bool) {
        guard let machine, !finished else { exit(0) }
        guard !stopping else { return }
        if asking, let window {
            let alert = NSAlert()
            alert.messageText = text("stopQuestion", "Shut down this virtual machine?")
            alert.informativeText = text("stopDetail", "Its macOS shuts down as a Mac does; what is open in it is closed.")
            alert.addButton(withTitle: text("stopNow", "Shut Down"))
            alert.addButton(withTitle: text("cancel", "Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.stop(asking: false) }
            }
            return
        }
        stopping = true
        window?.title = request.windowTitle + " — " + text("stopping", "shutting down…")
        FileManager.default.createFile(atPath: shutdownRequestURL.path, contents: Data())
        // The boot script looks every two seconds and gives Safari up to ten to quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.finished, machine.canRequestStop else { return }
            try? machine.requestStop()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.forceStop() }
    }

    func forceStop() {
        guard let machine, !finished else { exit(0) }
        guard machine.canStop else { finish() }
        machine.stop { [weak self] _ in
            DispatchQueue.main.async { self?.finish() }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        finish()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fail(error)
    }

    private func reportTraffic() {
        guard let counters = network?.counters(), counters != lastTraffic else { return }
        lastTraffic = counters
        HelperIO.emit(VMHelperEvent(kind: .traffic, bytesUp: counters.bytesFromGuest, bytesDown: counters.bytesToGuest,
                                    connections: counters.connectionsActive))
    }

    private func finish() -> Never {
        finished = true
        trafficTimer?.invalidate()
        reportTraffic()
        network?.stop()
        try? FileManager.default.removeItem(at: shutdownRequestURL)
        HelperIO.emit(VMHelperEvent(kind: .stopped))
        exit(0)
    }

    private func fail(_ error: Error) -> Never {
        finished = true
        network?.stop()
        HelperIO.fail(error)
    }
}
#endif
