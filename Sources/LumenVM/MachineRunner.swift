#if arch(arm64)
import AppKit
import BrowserCore
import CFNetwork
import Foundation
import Virtualization
import VMNetCore

/// The proxy this Mac's own network settings name at the moment (`VMNetSystemProxy`): where a VPN
/// or proxy tool in its "system proxy" mode writes itself. Read from the system at most every
/// three seconds: a tool switched on or off while a machine runs is followed from then on.
enum MacProxySettings {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: (at: Double, proxy: VMNetSystemProxy?)?

    static func current() -> VMNetSystemProxy? {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if let last, now - last.at < 3 { return last.proxy }
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
        let proxy = settings.flatMap { VMNetSystemProxy(settings: $0) }
        last = (now, proxy)
        return proxy
    }
}

/// A machine's network card, and what is at its other end.
///
/// The card is a socket whose other end is the app's own network (`VMNetCore`), which ends every
/// connection of the guest and carries it on. With a proxy: through the profile's proxy, and no
/// other way, so a guest whose proxy is down reaches nothing. Direct: as this process's own
/// connections (`VMNetDirectConnector`) — this Mac's connection as any app has it, through its
/// VPN and by its routes, and through the proxy its network settings name where they name one
/// (a VPN tool in "system proxy" mode). Not Apple's NAT: where the Mac runs a VPN or a proxy
/// tool, a guest behind that NAT had no internet at all (the first run on a person's Mac,
/// 13 November). Closed: the same network with no way out. Absent: no card.
final class MachineNetwork {
    /// Nil: the machine has no network card (`VMHelperRequest.Network.absent`).
    let attachment: VZNetworkDeviceAttachment?
    private let network: VMNetwork?
    private let connector: VMNetDirectConnector?
    private let descriptor: Int32

    /// The card's address when the request names none that reads: the same one for the card and
    /// for the network at its other end, which answers no other (its DHCP gives the guest its
    /// address by it).
    static let fallbackMACAddress = "02:1a:11:00:00:02"

    /// The address the machine's card has: the profile's, or the fallback.
    static func macAddress(of request: VMHelperRequest) -> String {
        guard let text = request.macAddress, VZMACAddress(string: text) != nil, VMNetMAC(string: text) != nil else {
            return fallbackMACAddress
        }
        return text
    }

    /// Each connection of the guest is a socket of this process, and a process starts with room
    /// for 256 descriptors: a browser with a few tabs open has more connections than that.
    static func raiseDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(rlim_t(8192), limit.rlim_max)
        guard limit.rlim_cur < wanted else { return }
        limit.rlim_cur = wanted
        _ = setrlimit(RLIMIT_NOFILE, &limit)
    }

    init(request: VMHelperRequest) throws {
        if request.network == .absent {
            attachment = nil
            network = nil
            connector = nil
            descriptor = -1
            return
        }
        Self.raiseDescriptorLimit()
        // The way out, before anything else is made: a connector that does not start is an
        // error the person is told, not a machine without a network.
        var upstream = VMNetUpstream.none
        var direct: VMNetDirectConnector?
        switch request.network {
        case .direct:
            let made = VMNetDirectConnector(systemProxy: { MacProxySettings.current() })
            try made.start()
            HelperIO.log("network: no proxy of the machine's own — this Mac's connection"
                + (MacProxySettings.current() == nil ? "" : ", through the proxy its network settings name"))
            direct = made
            upstream = made.upstream
        case .proxy:
            if let proxy = request.proxy, !proxy.tlsToProxy {
                switch proxy.kind {
                case .socks5: upstream = .socks5(host: proxy.host, port: proxy.port, username: proxy.username, password: proxy.password)
                case .httpConnect: upstream = .httpConnect(host: proxy.host, port: proxy.port, username: proxy.username, password: proxy.password)
                }
            }
        case .closed, .absent:
            break
        }
        connector = direct
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

        let guestMAC = VMNetMAC(string: Self.macAddress(of: request)) ?? VMNetMAC(bytes: [0x02, 0x1A, 0x11, 0x00, 0x00, 0x02])
        // The guest's address on its own little network, as a Mac has one behind a home router:
        // 192.168.1.x, x from its card's address so that it stays the same from start to start.
        let last = 2 + guestMAC.bytes.reduce(0) { ($0 &* 31 &+ Int($1)) % 200 }
        let configuration = VMNetConfiguration(guestMAC: guestMAC, gatewayMAC: VMNetMAC(bytes: [0x02, 0x1A, 0x11, 0x00, 0x00, 0x01]),
                                               gatewayAddress: VMNetIPv4(string: "192.168.1.1")!,
                                               guestAddress: VMNetIPv4(string: "192.168.1.\(last)")!,
                                               prefixLength: 24, upstream: upstream, blockedHostSuffixes: request.blockedHosts)
        let network = VMNetwork(configuration: configuration, frameDescriptor: descriptor)
        self.network = network
        network.log = { HelperIO.log("network: " + $0) }
        network.start()
    }

    /// What the machine's network carried so far; nil for a machine without a card.
    func counters() -> VMNetCounters? { network?.counters() }

    /// What the way out of a machine without a proxy has done; nil for any other machine.
    func directReport() -> VMNetDirectConnector.Report? { connector?.report() }

    /// What that way out did since this was last asked, for the log.
    func takeNotes() -> String? { connector?.takeNotes() }

    func stop() {
        network?.stop()
        connector?.stop()
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
    private var lastTrouble: String?
    private var lastViaSystemProxy = false
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
        window.contentMinSize = NSSize(width: 480, height: 480 * CGFloat(display.pixelsHigh) / CGFloat(display.pixelsWide))
        if let hint = request.texts["hint"], !hint.isEmpty {
            // What is left to do in this machine, said in its own window: the app's window, which
            // has the same words, is behind this one.
            window.contentView = Self.content(of: view, under: hint)
        } else {
            window.contentAspectRatio = NSSize(width: display.pixelsWide, height: display.pixelsHigh)
            window.contentView = view
        }
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

    /// The machine's screen with a line of words above it.
    private static func content(of view: NSView, under hint: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: hint)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        label.maximumNumberOfLines = 3
        label.isSelectable = false
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        let container = NSView()
        for subview in [bar, view] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(label)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: bar.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -9),
            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
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
        guard let network, let counters = network.counters() else { return }
        if let notes = network.takeNotes() { HelperIO.log("way out: " + notes) }
        // A machine without a proxy whose connections fail one after another has no way out:
        // said to the app, and in this window, with the kind of failure — not left to be guessed.
        let report = network.directReport()
        var trouble: String?
        if let report, report.failedInARow >= VMNetworkTrouble.failuresBeforeSaying, let kind = report.trouble {
            // Kind for kind, so that a new one is not forgotten here.
            let named: VMNetworkTrouble
            switch kind {
            case .nameNotFound: named = .nameNotFound
            case .notPublic: named = .notPublic
            case .unreachable: named = .unreachable
            case .proxyUnreachable: named = .proxyUnreachable
            case .proxyRefused: named = .proxyRefused
            }
            trouble = named.rawValue
        }
        let viaSystemProxy = report?.usesSystemProxy ?? false
        guard counters != lastTraffic || trouble != lastTrouble || viaSystemProxy != lastViaSystemProxy else { return }
        if trouble != lastTrouble {
            HelperIO.log(trouble.map { "way out: the machine's connections are not being made (\($0))" } ?? "way out: connections are made again")
            window?.subtitle = trouble.map { text("trouble." + $0, "No internet in this machine") } ?? ""
        }
        lastTraffic = counters
        lastTrouble = trouble
        lastViaSystemProxy = viaSystemProxy
        HelperIO.emit(VMHelperEvent(kind: .traffic, bytesUp: counters.bytesFromGuest, bytesDown: counters.bytesToGuest,
                                    connections: counters.connectionsActive, trouble: trouble,
                                    viaSystemProxy: report == nil ? nil : viaSystemProxy))
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
