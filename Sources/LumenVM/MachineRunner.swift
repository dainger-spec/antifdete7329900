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
        let proxy = settings().flatMap { VMNetSystemProxy(settings: $0) }
        last = (now, proxy)
        return proxy
    }

    /// The settings have the proxy chosen by a configuration file (PAC) or found on the network
    /// (WPAD), which a machine cannot follow: its connections are then not made at all — not
    /// without the proxy either — and the log and the machine's row say why.
    static var usesConfigurationFile: Bool {
        current()?.usesConfigurationFile == true
    }

    private static func settings() -> [String: Any]? {
        CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
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

    /// `knownNames`: the names a machine woken from a saved state was given stand-in addresses
    /// for before it was put to sleep (`VMSavedState.names`) — it still holds the addresses.
    init(request: VMHelperRequest, knownNames: [VMNetKnownName] = []) throws {
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
                + (MacProxySettings.usesConfigurationFile
                    ? "; the Mac's proxy is set by a configuration file (PAC or WPAD), which a machine cannot follow: "
                        + "no connection is made until the Mac's settings name a proxy or none, or the machine has a proxy of its own"
                    : (MacProxySettings.current() == nil ? "" : ", through the proxy its network settings name")))
            direct = made
            upstream = made.upstream
        case .proxy:
            if let proxy = request.proxy, !proxy.tlsToProxy {
                switch proxy.kind {
                case .socks5: upstream = .socks5(host: proxy.host, port: proxy.port, username: proxy.username, password: proxy.password)
                case .httpConnect: upstream = .httpConnect(host: proxy.host, port: proxy.port, username: proxy.username, password: proxy.password)
                // The app gives a link's machine its relay, a SOCKS5 proxy; a link itself reaches
                // nothing from here: no way out at all.
                case .xray: upstream = .none
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
        var configuration = VMNetConfiguration(guestMAC: guestMAC, gatewayMAC: VMNetMAC(bytes: [0x02, 0x1A, 0x11, 0x00, 0x00, 0x01]),
                                               gatewayAddress: VMNetIPv4(string: "192.168.1.1")!,
                                               guestAddress: VMNetIPv4(string: "192.168.1.\(last)")!,
                                               prefixLength: 24, upstream: upstream, blockedHostSuffixes: request.blockedHosts)
        configuration.knownNames = knownNames
        // UDP (HTTP/3, WebRTC) where the app's check before this start found a way for it: the
        // proxy's own relay, or, without a proxy, this Mac's own sockets (the connector refuses
        // while the Mac's settings name a proxy). The network itself never relays UDP for an
        // HTTP proxy or none, whatever it is told.
        configuration.relaysUDP = request.relaysUDP == true
        let network = VMNetwork(configuration: configuration, frameDescriptor: descriptor)
        // Without a proxy each connection holds three descriptors of this process, not one.
        if direct != nil { network.descriptorsPerConnection = VMNetDirectConnector.descriptorsPerConnection }
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

    /// Whether a connection can be made at all right now (`VMNetDirectConnector.canConnect`), said
    /// to `done` on the main queue. Asked off the main thread: it can take seconds.
    func checkWayOut(_ done: @escaping (Bool) -> Void) {
        guard let connector else { return done(true) }
        DispatchQueue.global(qos: .utility).async {
            let works = connector.canConnect()
            DispatchQueue.main.async { done(works) }
        }
    }

    /// Where the machine's macOS connects, the host seen last first — the person's browsing, for
    /// the app's panel while the machine runs: never logged, never written down.
    func hosts() -> [VMNetHost] { network?.hosts() ?? [] }

    /// Blocks a host name, and every name under it, from now on.
    func block(_ host: String) { network?.block(host: host) }

    /// Ends the network's UDP associations, made anew at the guest's next datagrams: after this
    /// Mac slept, their proxy side may be gone (`VMNetwork.restartUDP`).
    func restartUDP() { network?.restartUDP() }

    /// Called more than once without harm: the second time there is nothing left to stop.
    func stop() {
        guard !stopped else { return }
        stopped = true
        network?.stop()
        connector?.stop()
        if descriptor >= 0 { close(descriptor) }
    }

    /// After `stop()`: the names the machine was given stand-in addresses for, to be kept beside
    /// a saved state.
    func knownNames() -> [VMNetKnownName] { network?.knownNames() ?? [] }

    private var stopped = false
}

/// The guide's scrolled content, top to bottom.
private final class GuideDocument: NSView {
    override var isFlipped: Bool { true }
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
    private var lastTroubleDetail: String?
    /// The last answer to "can a connection be made at all", and when it was asked; and whether
    /// it is being asked now.
    private var wayOut: (works: Bool, at: Date)?
    private var askingWayOut = false
    private var lastViaSystemProxy = false
    private var stopping = false
    private var finished = false
    private var machineView: VZVirtualMachineView?
    /// Instant wake is asked for and this machine can be saved (the framework says so).
    private var canKeepState = false
    /// The machine is being woken — its saved state read, then the machine resumed: until that is
    /// done it can be neither paused nor saved.
    private var waking = false
    /// A close that came while the machine was being woken: done once it is awake (`sleep`).
    private var sleepAfterWake = false
    /// This start woke the machine: its macOS is the one that was put to sleep.
    private var woken = false
    /// The app's panel of where the machine connects is open (`hosts on`).
    private var watchingHosts = false
    /// The machine's screen in the window (a profile's machine), and the cover over it while a
    /// start's settings are put in place (`StartCover`); when the machine's macOS was started.
    private var screen: MachineScreen?
    private var startCover: StartCover?
    private var startedAt = Date()
    /// Told when this Mac wakes from sleep (`macWoke`).
    private var macWakeObserver: NSObjectProtocol?
    /// Where the window was last kept (`VMWindowPlacement`), the write that is waiting for the
    /// person to let go of the window, and whether the window is full screen or on its way there
    /// or back (its frame is then this Mac's screen's, not one to go back to).
    private var keptPlacement: VMWindowPlacement?
    private var placementWrite: DispatchWorkItem?
    private var fullScreenBusy = false
    /// The highest timer and I/O precision this process can ask for (`latencyCritical`), held
    /// while the machine's window is in sight (`holdPrecision`).
    private var precision: NSObjectProtocol?
    /// Whether the machine's display sleeps while its window is out of sight, and where that
    /// stands (`VMScreenSleep`); the look at it that waits for its time; when the word was left.
    private var screenSleep: VMScreenSleep
    private var screenSleepCheck: DispatchWorkItem?
    private var screenSleepAskedAt: Date?

    init(request: VMHelperRequest) {
        self.request = request
        screenSleep = VMScreenSleep(request: request)
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
                HelperIO.fail("This machine's macOS cannot run on this Mac (its virtual Mac model is not supported here).",
                              kind: .notSupportedHere)
            }
            guard let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: files.machineIdentifier)) else {
                HelperIO.fail("This machine's identifier cannot be read.", kind: .files)
            }
            // A request the guest made before, and never took: not this start's. The same for
            // the word that says the machine was woken.
            try? FileManager.default.removeItem(at: shutdownRequestURL)
            try? FileManager.default.removeItem(at: wokeURL)
            // Nor is a word to put the display to sleep: the window opens in sight. (A machine
            // woken with its display asleep has it woken by its script once the word is gone.)
            try? FileManager.default.removeItem(at: files.screenSleep)
            // A saved state is used by this start or removed by it: never left beside a disk
            // that goes on without it.
            var (saved, refusal) = savedState()
            let network = try MachineNetwork(request: request,
                                             knownNames: saved?.names.map { VMNetKnownName(name: $0.name, address: $0.address) } ?? [])
            self.network = network
            let configuration = try MachineConfiguration.make(files: files, request: request, hardwareModel: hardwareModel,
                                                              machineIdentifier: identifier,
                                                              auxiliaryStorage: VZMacAuxiliaryStorage(url: files.auxiliaryStorage),
                                                              network: network.attachment)
            if request.keepsState == true {
                do {
                    try configuration.validateSaveRestoreSupport()
                    canKeepState = true
                } catch {
                    // This machine, as it is made on this Mac, cannot be saved: it starts and
                    // shuts down as a Mac does, and the app says so.
                    HelperIO.log("wake: this machine cannot be saved (\(Self.kind(of: error)))")
                    if saved != nil { removeSavedState() }
                    saved = nil
                    refusal = .unsupported
                }
            }
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = self
            self.machine = machine
            showWindow(for: machine)
            if saved != nil {
                // Put to sleep before its settings were in, it is covered until they are.
                putUpCover(woken: true)
                wake(machine)
            } else {
                start(machine, notWoken: refusal)
            }
            HelperIO.readCommands { [weak self] line in
                guard let self, let command = VMHelperCommand(line: line) else { return }
                switch command {
                case .stop: self.stop(asking: false)
                case .shutdown: self.shutDown(asking: false)
                case .kill: self.forceStop()
                case .hosts(let on):
                    self.watchingHosts = on
                    if on { self.reportHosts() }
                case .block(let name):
                    self.network?.block(name)
                    if self.watchingHosts {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.reportHosts() }
                    }
                case .fullScreen: self.pressGuestFullScreen()
                }
            }
            trafficTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reportTraffic() }
            // Counters for the app's row: whenever macOS has other wake-ups to go with them.
            trafficTimer?.tolerance = 0.5
            macWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                               object: nil, queue: .main) { [weak self] _ in
                self?.macWoke()
            }
        } catch {
            fail(error)
        }
    }

    /// This Mac slept with the machine open, and has woken. The machine stood still for as long —
    /// nothing in it ran — and its clock is that of the moment the Mac went to sleep until its
    /// macOS next asks for the time, which it does now and then. It is told at once, the way a
    /// machine woken from a saved state is: the word in the shared folder, on which the boot
    /// script asks for the time (tools 11), answered by this Mac's clock (docs/VM_NETWORK.md).
    /// A profile's machine only: the base's shared folder is the person's to look into.
    private func macWoke() {
        // The UDP associations through the proxy (or this Mac's own) may have died with the sleep —
        // closed by the proxy, forgotten by a router —, and one the guest keeps sending on (a call)
        // would never carry again: made anew at the guest's next datagram.
        if machine != nil, !finished {
            network?.restartUDP()
            HelperIO.log("network: this Mac woke from sleep; the UDP associations are made anew")
        }
        guard request.settingsRevision != nil, machine != nil, !finished, !stopping, !waking else { return }
        HelperIO.log("clock: this Mac woke from sleep; the machine is told to ask for the time")
        tellTheGuestItWoke()
    }

    // MARK: The machine's files

    /// A profile's machine that has no disk yet is made from the base: its disk a copy-on-write
    /// clone (no room taken until the two differ), its firmware variables a copy, and an identifier
    /// of its own — to macOS inside, and to Apple's services, another Mac than the base and than
    /// every other profile's.
    private func prepareMachine() throws {
        guard !files.isComplete else { return }
        guard let basePath = request.baseDirectory else {
            throw VMFailure(.noBase, "This machine has no disk, and no base system to make it from.")
        }
        let base = VMLibrary.MachineFiles(directory: URL(fileURLWithPath: basePath, isDirectory: true))
        guard base.isComplete else {
            throw VMFailure(.noBase, "The base system is not installed.")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: files.share, withIntermediateDirectories: true)
        // What a clone that stopped part-way left.
        let made = [files.disk, files.auxiliaryStorage, files.hardwareModel, files.machineIdentifier]
        for url in made { try? manager.removeItem(at: url) }
        let cloning = files.directory.appendingPathComponent("disk.img.cloning")
        try? manager.removeItem(at: cloning)
        do {
            if clonefile(base.disk.path, cloning.path, 0) != 0 {
                // Not a volume that clones (not APFS): a whole copy.
                try manager.copyItem(at: base.disk, to: cloning)
            }
            try manager.copyItem(at: base.auxiliaryStorage, to: files.auxiliaryStorage)
            try manager.copyItem(at: base.hardwareModel, to: files.hardwareModel)
            try manager.moveItem(at: cloning, to: files.disk)
            // Last: with it the machine is whole.
            try VZMacMachineIdentifier().dataRepresentation.write(to: files.machineIdentifier)
        } catch {
            // A copy that stopped part-way — a full disk, above all — is gigabytes of nothing: gone
            // now, not left on the full disk until the machine's next start.
            for url in [cloning] + made { try? manager.removeItem(at: url) }
            throw error
        }
    }

    // MARK: The window

    private func showWindow(for machine: VZVirtualMachine) {
        let view = VZVirtualMachineView()
        machineView = view
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        // The guest's screen stays the Mac's it is, whatever size this window has: scaled, not changed.
        view.automaticallyReconfiguresDisplay = false

        let display = request.display
        let scale: CGFloat = display.pixelsPerInch >= 150 ? 2 : 1
        let guide = request.texts["guide"].flatMap { $0.isEmpty ? nil : $0 }
        let beside: CGFloat = guide == nil ? 0 : Self.guideWidth
        var size = NSSize(width: CGFloat(display.pixelsWide) / scale, height: CGFloat(display.pixelsHigh) / scale)
        if let visible = NSScreen.main?.visibleFrame.size {
            let fit = min(1, min((visible.width * 0.92 - beside) / size.width, (visible.height * 0.92 - 28) / size.height))
            size = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        }
        size.width += beside
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = request.windowTitle
        window.contentMinSize = NSSize(width: 480 + beside, height: 480 * CGFloat(display.pixelsHigh) / CGFloat(display.pixelsWide))
        if let guide {
            // What to press on each of macOS's setup screens, beside them: people chose what made
            // a poor base (an Apple ID in every machine, FileVault) with one line to go by.
            window.contentView = Self.content(of: view, beside: guide)
        } else if let hint = request.texts["hint"], !hint.isEmpty {
            // What is left to do in this machine, said in its own window: the app's window, which
            // has the same words, is behind this one.
            window.contentView = Self.content(of: view, under: hint)
        } else {
            // A profile's machine: its screen, in a view a start's cover is put over
            // (`putUpCover`).
            window.contentAspectRatio = NSSize(width: display.pixelsWide, height: display.pixelsHigh)
            let screen = MachineScreen()
            view.translatesAutoresizingMaskIntoConstraints = false
            screen.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: screen.topAnchor),
                view.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            ])
            window.contentView = screen
            self.screen = screen
        }
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        restoreWindowPlacement(window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
        // In sight as it opens; AppKit says when that changes (`windowDidChangeOcclusionState`).
        holdPrecision(true)
        if request.fullScreen == true {
            // The profile's choice: the machine takes this Mac's whole screen, as the window's
            // green button would have it.
            window.collectionBehavior.insert(.fullScreenPrimary)
            DispatchQueue.main.async { window.toggleFullScreen(nil) }
        }
        installMenu()
        // In the Dock as the app it is part of, not as a bare executable.
        if Bundle.main.bundleURL.pathExtension == "app" {
            NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static let guideWidth: CGFloat = 320

    // MARK: Where the window was left

    /// A profile's machine opens where its window was left (`VMWindowPlacement`, a note beside
    /// its disk): on the display the person put it on, at the size they gave it — not in the
    /// middle of the main screen at every start, over the other machine's window. Where the note
    /// is none, the machine's screen has changed, or the place is no longer on a screen (a
    /// display is gone), the window stays where a new one opens.
    private func restoreWindowPlacement(_ window: NSWindow) {
        guard screen != nil, let kept = VMWindowPlacement.read(from: files.window) else { return }
        let screens = NSScreen.screens.map { display -> VMWindowPlacement.Rect in
            let visible = display.visibleFrame
            return VMWindowPlacement.Rect(x: Double(visible.origin.x), y: Double(visible.origin.y),
                                          width: Double(visible.size.width), height: Double(visible.size.height))
        }
        guard let frame = kept.restored(onScreens: screens, pixelsWide: request.display.pixelsWide,
                                        pixelsHigh: request.display.pixelsHigh) else { return }
        keptPlacement = kept
        window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
    }

    /// The window as it stands, kept for the machine's next start — not while it is full screen
    /// or minimised, when its frame is not one to go back to.
    private func keepWindowPlacement() {
        placementWrite?.cancel()
        placementWrite = nil
        guard screen != nil, !fullScreenBusy, let window, !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        let placement = VMWindowPlacement(frame: VMWindowPlacement.Rect(x: Double(frame.origin.x), y: Double(frame.origin.y),
                                                                        width: Double(frame.size.width), height: Double(frame.size.height)),
                                          pixelsWide: request.display.pixelsWide, pixelsHigh: request.display.pixelsHigh)
        guard placement != keptPlacement else { return }
        keptPlacement = placement
        try? placement.write(to: files.window)
    }

    /// The window was moved or resized: kept once the person has let go of it for a moment.
    private func windowPlacementChanged() {
        guard screen != nil, !finished else { return }
        placementWrite?.cancel()
        let write = DispatchWorkItem { [weak self] in self?.keepWindowPlacement() }
        placementWrite = write
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: write)
    }

    func windowDidMove(_ notification: Notification) { windowPlacementChanged() }
    func windowDidResize(_ notification: Notification) { windowPlacementChanged() }
    func windowWillEnterFullScreen(_ notification: Notification) { fullScreenBusy = true }
    func windowDidExitFullScreen(_ notification: Notification) { fullScreenBusy = false }
    /// Full screen that did not come about: the window is a window again.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreenBusy = false }

    // MARK: Out of sight

    /// The window came into sight or went out of it — minimised, covered by other windows, on
    /// another desktop, this Mac's screen off or locked (AppKit's occlusion state).
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window, !finished else { return }
        let seen = window.occlusionState.contains(.visible)
        holdPrecision(seen)
        if screenSleep.window(seen: seen, at: Date()) == .wake {
            leaveScreenSleepWord(false)
            HelperIO.log("screen: the window is in sight again; the machine's display is woken")
        }
        scheduleScreenSleepCheck()
    }

    /// The highest timer precision (`latencyCritical`: macOS does not gather this process's
    /// wake-ups together) while the machine's window is in sight: someone may be at the machine,
    /// and its pointer and its pages answer at once. Out of sight the helper keeps only the
    /// activity begun at its start (main.swift) — App Nap stays away, the guest runs on, and its
    /// wake-ups may be gathered with this Mac's others, which saves energy.
    private func holdPrecision(_ wanted: Bool) {
        if wanted {
            guard precision == nil else { return }
            precision = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                              reason: "A virtual machine's window is in sight")
        } else if let held = precision {
            ProcessInfo.processInfo.endActivity(held)
            precision = nil
        }
    }

    /// A look at whether the display is due to sleep (`VMScreenSleep.due`), when it is due.
    private func scheduleScreenSleepCheck() {
        screenSleepCheck?.cancel()
        screenSleepCheck = nil
        guard let due = screenSleep.due, !finished else { return }
        let work = DispatchWorkItem { [weak self] in self?.checkScreenSleep() }
        screenSleepCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(due.timeIntervalSinceNow, 0.5), execute: work)
    }

    /// The window has been out of sight long enough: the word for the guest, unless the machine is
    /// starting behind its cover (its script is at its settings), being woken or being closed.
    private func checkScreenSleep() {
        screenSleepCheck = nil
        guard !finished else { return }
        let coverUp = startCover.map { cover in MainActor.assumeIsolated { cover.isUp } } ?? false
        if screenSleep.check(at: Date(), busy: stopping || waking || coverUp) == .sleep {
            leaveScreenSleepWord(true)
            screenSleepAskedAt = Date()
            HelperIO.log("screen: the window has been out of sight for \(Int(VMScreenSleep.after)) s; the machine's display is put to sleep")
            // The script looks every two seconds, and says what came of it in the status.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.readScreenSleepAnswer() }
        }
        scheduleScreenSleepCheck()
    }

    /// The word in the shared folder (`VMGuestSettings.screenSleepFileName`): there while the
    /// display may sleep, gone when it is to be awake. The guest writes the folder too: what it left
    /// in the word's place that is not a plain file goes first, and the word is made without
    /// following a link.
    private func leaveScreenSleepWord(_ asleep: Bool) {
        let url = files.screenSleep
        guard asleep else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if !VMShareFile.isRegularFile(url) { try? FileManager.default.removeItem(at: url) }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if descriptor >= 0 { close(descriptor) }
    }

    /// What the guest said once asked: its display asleep — or left on, because the person's
    /// screen lock is on, and then it is not asked again while this machine runs. A script older
    /// than tools 14 says nothing, and its display stays as it is.
    private func readScreenSleepAnswer() {
        guard !finished, screenSleep.asked else { return }
        // Off the main thread, as a file of the guest's (`VMShareFile`).
        let url = files.status
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // The time first: a file put in place meanwhile is then taken as older, not newer, than it is.
            let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            let said = try? VMGuestStatus.read(from: url).get()
            DispatchQueue.main.async { self?.takeScreenSleepAnswer(said, written: written) }
        }
    }

    private func takeScreenSleepAnswer(_ status: VMGuestStatus?, written: Date?) {
        guard !finished, screenSleep.asked, let asked = screenSleepAskedAt else { return }
        guard let written, written >= asked, let said = status, said.screenSleep != nil else {
            HelperIO.log("screen: the guest has said nothing of its display yet (a script older than tools 14 says nothing)")
            return
        }
        if screenSleep.guestSaid(said) == .wake {
            leaveScreenSleepWord(false)
            HelperIO.log("screen: the guest left its display on: its screen lock is on, and waking the display would ask for "
                + "the password; not asked again while this machine runs" + (said.screenSleepNote.map { " (the system: \($0))" } ?? ""))
        } else if said.screenSleep == "asleep" {
            HelperIO.log("screen: the guest says its display is asleep")
        }
    }

    // MARK: The start's cover

    /// The machine's screen behind a cover until its guest says this start's settings are in
    /// (`StartCover`, `VMStartCover`): a profile's machine started anew — not the base, whose
    /// window is for its setup, and not a machine woken as it was put to sleep, unless that was
    /// before its settings were in (then its script goes on with them as it wakes).
    private func putUpCover(woken: Bool) {
        guard startCover == nil, let screen, let machineView else { return }
        var asleepWith: VMGuestStatus?
        if woken, case .success(let said) = VMGuestStatus.read(from: files.status) { asleepWith = said }
        guard VMStartCover.covers(settingsRevision: request.settingsRevision, woken: woken, asleepWith: asleepWith) else { return }
        let request = self.request, status = files.status, since = woken ? Date() : startedAt
        MainActor.assumeIsolated {
            let cover = StartCover(screen: screen, machineView: machineView, request: request, statusURL: status, startedAt: since)
            cover.onSafariOpen = { [weak self] in self?.safariOpened() }
            self.startCover = cover
        }
    }

    /// A machine shown as a browser whose guest says Safari is open: Safari is put over the
    /// machine's whole screen, then the cover goes. Safari's window is on the screen a few seconds
    /// after it was opened.
    private func safariOpened() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.finished else { return }
            self.pressGuestFullScreen()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.revealScreen() }
        }
    }

    private func revealScreen() {
        guard let startCover else { return }
        MainActor.assumeIsolated { startCover.reveal() }
    }

    /// The machine is shutting down or going to sleep: a cover that is up stays, and no longer goes.
    private func haltCover() {
        guard let startCover else { return }
        MainActor.assumeIsolated { startCover.halt() }
    }

    // MARK: Browser mode

    /// Control-Command-F, as from the machine's own keyboard: what puts the front window of its
    /// macOS full screen, or back. The events are made here and given to the machine's view, which
    /// takes a person's the same way — nothing in the guest is asked for a permission.
    private func pressGuestFullScreen() {
        guard let machineView, let window, machine != nil, !finished, !stopping else { return }
        let number = window.windowNumber
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, _ code: UInt16, _ characters: String) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: number, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)
        }
        // Key codes: 59 the left Control, 55 the left Command, 3 the letter F.
        let both: NSEvent.ModifierFlags = [.control, .command]
        if let down = event(.flagsChanged, .control, 59, "") { machineView.flagsChanged(with: down) }
        if let down = event(.flagsChanged, both, 55, "") { machineView.flagsChanged(with: down) }
        if let key = event(.keyDown, both, 3, "f") { machineView.keyDown(with: key) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let machineView = self.machineView, !self.finished else { return }
            if let key = event(.keyUp, both, 3, "f") { machineView.keyUp(with: key) }
            if let up = event(.flagsChanged, .control, 55, "") { machineView.flagsChanged(with: up) }
            if let up = event(.flagsChanged, [], 59, "") { machineView.flagsChanged(with: up) }
        }
    }

    @objc private func guestFullScreenFromMenu() { pressGuestFullScreen() }

    /// The machine's screen with a panel beside it: what to press on each of macOS's setup
    /// screens, the choices that matter marked. Lines of `guide`: "# " a title, "! " a step that
    /// matters, "> " a note, anything else a step; the steps are numbered here.
    private static func content(of view: NSView, beside guide: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 18, bottom: 20, right: 18)
        let textWidth = guideWidth - 36
        var number = 0
        for raw in guide.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let label: NSTextField
            if line.hasPrefix("# ") {
                label = NSTextField(wrappingLabelWithString: String(line.dropFirst(2)))
                label.font = .systemFont(ofSize: 15, weight: .semibold)
                label.textColor = NSColor(calibratedWhite: 0.97, alpha: 1)
            } else if line.hasPrefix("> ") {
                label = NSTextField(wrappingLabelWithString: String(line.dropFirst(2)))
                label.font = .systemFont(ofSize: 11.5)
                label.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
            } else {
                let matters = line.hasPrefix("! ")
                number += 1
                label = NSTextField(wrappingLabelWithString: "\(number). " + (matters ? String(line.dropFirst(2)) : line))
                label.font = .systemFont(ofSize: 12.5, weight: matters ? .semibold : .regular)
                label.textColor = matters ? NSColor.systemOrange : NSColor(calibratedWhite: 0.88, alpha: 1)
            }
            label.isSelectable = false
            label.preferredMaxLayoutWidth = textWidth
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
            stack.addArrangedSubview(label)
        }
        // Top to bottom, and scrolled where a small screen has no room for all of it.
        let document = GuideDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scroll)
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(panel)
        container.addSubview(view)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.topAnchor.constraint(equalTo: panel.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.widthAnchor.constraint(equalToConstant: guideWidth),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: panel.trailingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
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
        if canKeepState {
            let sleep = NSMenuItem(title: text("sleep", "Close and Keep the Machine as It Is"), action: #selector(sleepFromMenu), keyEquivalent: "")
            sleep.target = self
            menu.addItem(sleep)
        }
        let stop = NSMenuItem(title: text("stop", "Shut Down the Virtual Machine…"), action: #selector(stopFromMenu), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        menu.addItem(.separator())
        let full = NSMenuItem(title: text("guestFullScreen", "Full Screen in the Machine"), action: #selector(guestFullScreenFromMenu), keyEquivalent: "")
        full.target = self
        menu.addItem(full)
        item.submenu = menu
        main.addItem(item)
        NSApp.mainMenu = main
    }

    @objc private func stopFromMenu() { shutDown(asking: true) }
    @objc private func sleepFromMenu() { stop(asking: false) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stop(asking: true)
        return false
    }

    // MARK: Starting, and waking

    private static func kind(of error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    private var wokeURL: URL { files.share.appendingPathComponent(VMGuestSettings.wokeFileName) }

    private func removeSavedState() {
        for url in [files.state, files.stateInfo] { try? FileManager.default.removeItem(at: url) }
    }

    /// The saved state this start may wake the machine from, or why the one that was there is
    /// not used — it is then removed here.
    private func savedState() -> (state: VMSavedState?, refusal: VMWakeRefusal?) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: files.state.path) || manager.fileExists(atPath: files.stateInfo.path) else { return (nil, nil) }
        guard request.keepsState == true else {
            // Instant wake is off for this machine now: it starts as a Mac does.
            removeSavedState()
            return (nil, nil)
        }
        guard manager.fileExists(atPath: files.state.path), let info = VMSavedState.read(from: files.stateInfo) else {
            removeSavedState()
            return (nil, .stale)
        }
        if let refusal = info.refusal(stamp: request.stateStamp, disk: files.disk) {
            HelperIO.log("wake: the saved state is not used (\(refusal.rawValue))")
            removeSavedState()
            return (nil, refusal)
        }
        return (info, nil)
    }

    private func start(_ machine: VZVirtualMachine, notWoken refusal: VMWakeRefusal?) {
        startedAt = Date()
        putUpCover(woken: false)
        machine.start { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): self.fail(error)
                case .success:
                    HelperIO.emit(VMHelperEvent(kind: .started, notWoken: refusal?.rawValue))
                }
            }
        }
    }

    /// Brings the machine back as it was put to sleep. The state is removed before the machine
    /// runs again, taken or not: from that moment its disk goes on, and the state is no longer
    /// its own. A state the framework does not take is no reason not to start: the machine then
    /// starts anew, as after a Mac lost power.
    ///
    /// Closed while this goes on (`sleepAfterWake`): put to sleep again once it is awake. A state
    /// the framework did not take leaves nothing to keep, and a machine that never ran is not
    /// started only to be closed.
    private func wake(_ machine: VZVirtualMachine) {
        waking = true
        machine.restoreMachineStateFrom(url: files.state) { error in
            DispatchQueue.main.async {
                self.removeSavedState()
                if let error {
                    self.waking = false
                    HelperIO.log("wake: the saved state was not taken (\(Self.kind(of: error)))")
                    if self.sleepAfterWake { self.finish() }
                    return self.start(machine, notWoken: .failed)
                }
                machine.resume { result in
                    DispatchQueue.main.async {
                        self.waking = false
                        switch result {
                        case .failure(let error):
                            self.fail(error)
                        case .success:
                            self.woken = true
                            self.tellTheGuestItWoke()
                            HelperIO.emit(VMHelperEvent(kind: .started, woke: true))
                            if self.sleepAfterWake { self.sleep() }
                        }
                    }
                }
            }
        }
    }

    /// A word of this wake's own in the shared folder: the boot script, which went on where it
    /// was, asks for the time when it finds one (the machine's clock is that of its sleep).
    private func tellTheGuestItWoke() {
        if !VMShareFile.isRegularFile(wokeURL) { try? FileManager.default.removeItem(at: wokeURL) }
        let word = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        FileManager.default.createFile(atPath: wokeURL.path, contents: Data(word.utf8))
    }

    // MARK: Stopping

    /// Where the guest's boot script looks for a request to shut down (Resources/VMGuest).
    private var shutdownRequestURL: URL { files.share.appendingPathComponent("lumen-shutdown") }

    /// Closes the machine: put to sleep, at once and without a question, where its state is
    /// kept (instant wake) — nothing in it is lost; shut down otherwise.
    ///
    /// The window's own close (`asking`) asks once where the guest's script wrote something at
    /// its macOS's start that macOS takes only at the next one — a keyboard layout, browser mode's
    /// menu bar (`VMGuestStatus.waitsForTheNextStart`): a machine put to sleep is woken, never
    /// started, and would never have it. Shut down this once, it has it from its next start.
    /// Lock, Quit, this Mac's own shutdown and "Close and Keep" put it to sleep as always: nothing
    /// is closed in it that nobody chose to close.
    func stop(asking: Bool) {
        guard canKeepState else { return shutDown(asking: asking) }
        if asking, let window, !waking, !stopping, !finished, guestWaitsForItsNextStart() {
            let alert = NSAlert()
            alert.messageText = text("nextStartQuestion", "Shut down this machine this time?")
            alert.informativeText = text("nextStartDetail", "A keyboard layout or a menu bar setting was written in its macOS, "
                + "which takes it only when it starts — and a machine put to sleep is woken, not started. Shut down, it has it "
                + "from its next start; what is open in it is closed.")
            alert.addButton(withTitle: text("stopNow", "Shut Down"))
            alert.addButton(withTitle: text("keep", "Keep as It Is"))
            alert.addButton(withTitle: text("cancel", "Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn: self?.shutDown(asking: false)
                case .alertSecondButtonReturn: self?.sleep()
                default: break
                }
            }
            return
        }
        sleep()
    }

    /// Whether the guest's script said, at the start of the macOS running now, that something it
    /// wrote waits for the next start. For a machine started anew, a status written before this
    /// start is of a macOS that has since shut down (`VMGuestStatus.asOf`); for one woken, it is
    /// this macOS's own.
    private func guestWaitsForItsNextStart() -> Bool {
        // The time first: a file put in place meanwhile is then taken as older, not newer, than it is.
        let written = (try? FileManager.default.attributesOfItem(atPath: files.status.path))?[.modificationDate] as? Date
        guard case .success(let said) = VMGuestStatus.read(from: files.status) else { return false }
        return said.asOf(start: woken ? nil : startedAt, written: written).waitsForTheNextStart
    }

    /// How long a close that came during a wake waits for the wake to end: the app gives a machine
    /// 75 seconds on Lock and Quit (`VMCenter.stopAll`), and the save after the wake needs time too.
    static let wakePatience: TimeInterval = 45

    /// Saves the machine as it is — paused, its memory written beside its disk, then ended — for
    /// its next start to wake. What goes wrong on the way is no reason to lose what is open in
    /// it: the machine then goes on, and is shut down as a Mac is.
    ///
    /// Asked for while the machine is being woken (its window closed, Lock, Quit, this Mac's
    /// shutdown — in the seconds a wake takes), it cannot be paused yet, and what it was put to
    /// sleep with is in the state being read: it is put to sleep again once it is awake (`wake`),
    /// not shut down. A wake that has not ended in `wakePatience` is not waited for: the process
    /// ends, and a state not yet taken stays for the next start.
    private func sleep() {
        guard let machine, !finished else { exit(0) }
        guard !stopping else { return }
        if waking {
            guard !sleepAfterWake else { return }
            sleepAfterWake = true
            window?.title = request.windowTitle + " — " + text("sleeping", "saving…")
            HelperIO.log("sleep: asked for while the machine is being woken; it is put to sleep once it is awake")
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakePatience) { [weak self] in
                guard let self, self.waking, !self.stopping, !self.finished else { return }
                HelperIO.log("sleep: the wake did not end in time; the machine is ended")
                self.finish()
            }
            return
        }
        stopping = true
        haltCover()
        window?.title = request.windowTitle + " — " + text("sleeping", "saving…")
        let giveUp: (String, Error?) -> Void = { [weak self] why, error in
            HelperIO.log("sleep: the state was not saved (\(why)); the machine is shut down instead")
            guard let self, !self.finished else { return }
            // Said to the app at once: the row then says the machine is shutting down, not being
            // saved, and afterwards why it was not kept — a full disk above all.
            HelperIO.emit(VMHelperEvent(kind: .notKept, message: error.map { ($0 as NSError).localizedDescription },
                                        failure: error.flatMap { VMFailureKind.of($0) }?.rawValue))
            self.removeSavedState()
            self.canKeepState = false
            self.stopping = false
            guard machine.state == .paused, machine.canResume else { return self.shutDown(asking: false) }
            machine.resume { _ in DispatchQueue.main.async { self.shutDown(asking: false) } }
        }
        guard machine.canPause else { return giveUp("the machine cannot be paused now", nil) }
        machine.pause { result in
            DispatchQueue.main.async {
                if case .failure(let error) = result { return giveUp(Self.kind(of: error), error) }
                self.removeSavedState()
                machine.saveMachineStateTo(url: self.files.state) { error in
                    DispatchQueue.main.async {
                        if let error { return giveUp(Self.kind(of: error), error) }
                        guard machine.canStop else { self.finishAsleep() }
                        machine.stop { _ in DispatchQueue.main.async { self.finishAsleep() } }
                    }
                }
            }
        }
    }

    /// The machine has stopped with its state saved: what the state goes with is written beside
    /// it — this start's stamp, the disk as it was left, the names its network knew — and
    /// without that note the state is not kept.
    private func finishAsleep() -> Never {
        keepWindowPlacement()
        finished = true
        trafficTimer?.invalidate()
        network?.stop()
        var asleep = false
        var problem: Error?
        if let stamp = request.stateStamp, let mark = VMSavedState.mark(ofDisk: files.disk),
           FileManager.default.fileExists(atPath: files.state.path) {
            let names = (network?.knownNames() ?? []).map { VMSavedState.Name(name: $0.name, address: $0.address) }
            let info = VMSavedState(stamp: stamp, diskLength: mark.length, diskModified: mark.modified, names: names)
            do {
                try info.write(to: files.stateInfo)
                asleep = true
            } catch {
                problem = error
            }
        }
        if !asleep {
            // A state without its note is nobody's: removed — and said, so that the machine's next
            // start, an ordinary one, is not a surprise.
            removeSavedState()
            let why = problem.map { Self.kind(of: $0) } ?? "nothing to write it from"
            HelperIO.log("sleep: the saved state's note was not written (\(why)); the state is not kept")
            HelperIO.emit(VMHelperEvent(kind: .notKept, message: problem.map { ($0 as NSError).localizedDescription },
                                        failure: problem.flatMap { VMFailureKind.of($0) }?.rawValue))
        }
        try? FileManager.default.removeItem(at: shutdownRequestURL)
        screenSleepCheck?.cancel()
        try? FileManager.default.removeItem(at: files.screenSleep)
        HelperIO.emit(VMHelperEvent(kind: .stopped, asleep: asleep))
        exit(0)
    }

    /// Shuts the guest's macOS down as its own menu would — first by asking its boot script (a
    /// file in the shared folder, taken within seconds, with no question on the guest's screen),
    /// then by the power button, and after a minute by ending the machine.
    func shutDown(asking: Bool) {
        guard let machine, !finished else { exit(0) }
        guard !stopping else { return }
        if asking, let window {
            let alert = NSAlert()
            alert.messageText = text("stopQuestion", "Shut down this virtual machine?")
            alert.informativeText = text("stopDetail", "Its macOS shuts down as a Mac does; what is open in it is closed.")
            alert.addButton(withTitle: text("stopNow", "Shut Down"))
            alert.addButton(withTitle: text("cancel", "Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.shutDown(asking: false) }
            }
            return
        }
        stopping = true
        haltCover()
        window?.title = request.windowTitle + " — " + text("stopping", "shutting down…")
        // The guest writes the share too: a link left in the request's place goes, itself, first.
        if !VMShareFile.isRegularFile(shutdownRequestURL) { try? FileManager.default.removeItem(at: shutdownRequestURL) }
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

    /// Where the machine connects, for the app's panel: at most two hundred hosts, the one seen
    /// last first. Said to the app only — this is the person's browsing, and no log gets it.
    private func reportHosts() {
        guard watchingHosts, let network, !finished else { return }
        let hosts = network.hosts().prefix(200).map {
            VMHelperEvent.Host(name: $0.name, connections: $0.connections, open: $0.open, bytesUp: $0.bytesFromGuest,
                               bytesDown: $0.bytesToGuest, blocked: $0.blocked, idle: $0.idle.rounded())
        }
        HelperIO.emit(VMHelperEvent(kind: .hosts, hosts: Array(hosts)))
    }

    private func reportTraffic() {
        reportHosts()
        guard let network, let counters = network.counters() else { return }
        if let notes = network.takeNotes() { HelperIO.log("way out: " + notes) }
        // A machine without a proxy whose connections fail one after another has no way out:
        // said to the app, and in this window, with the kind of failure — not left to be guessed.
        let report = network.directReport()
        var trouble: String?
        var troubleDetail: String?
        if let report, report.failedInARow >= VMNetworkTrouble.failuresBeforeSaying, let kind = report.trouble,
           wayOutIsDown(network) {
            // Kind for kind, so that a new one is not forgotten here.
            let named: VMNetworkTrouble
            switch kind {
            case .nameNotFound: named = .nameNotFound
            case .notPublic: named = .notPublic
            case .unreachable: named = .unreachable
            case .proxyUnreachable: named = .proxyUnreachable
            case .proxyRefused: named = .proxyRefused
            case .proxyConfigurationFile: named = .proxyConfigurationFile
            }
            trouble = named.rawValue
            troubleDetail = report.detail.map { String($0.prefix(200)) }
        }
        // A machine with a proxy of its own: the proxy itself failing the guest's connections one
        // after another — gone down since the start's check, or refusing a sign-in that changed —
        // is said as such; until now the row went on saying nothing while the machine had no
        // internet. Nothing goes out past the proxy meanwhile (its network has no other way).
        if report == nil, request.network == .proxy,
           let named = VMNetworkTrouble.ofMachineProxy(failuresInARow: counters.proxyFailuresInARow,
                                                       kind: counters.proxyTrouble?.rawValue) {
            trouble = named.rawValue
        }
        let viaSystemProxy = report?.usesSystemProxy ?? false
        guard counters != lastTraffic || trouble != lastTrouble || troubleDetail != lastTroubleDetail
            || viaSystemProxy != lastViaSystemProxy else { return }
        if trouble != lastTrouble {
            HelperIO.log(trouble.map { "way out: the machine's connections are not being made (\($0))" } ?? "way out: connections are made again")
            window?.subtitle = trouble.map { text("trouble." + $0, "No internet in this machine") } ?? ""
        }
        lastTraffic = counters
        lastTrouble = trouble
        lastTroubleDetail = troubleDetail
        lastViaSystemProxy = viaSystemProxy
        // What went each way, UDP (QUIC, WebRTC) with TCP.
        HelperIO.emit(VMHelperEvent(kind: .traffic, bytesUp: counters.bytesFromGuest &+ counters.udpBytesFromGuest,
                                    bytesDown: counters.bytesToGuest &+ counters.udpBytesToGuest,
                                    connections: counters.connectionsActive, trouble: trouble, troubleDetail: troubleDetail,
                                    viaSystemProxy: report == nil ? nil : viaSystemProxy))
    }

    /// Connections are failing one after another — but is it this machine's way out, or the sites
    /// it asks for (a page's blocked trackers fail so too)? A connection to a name every Mac asks
    /// for settles it. Asked at most once in half a minute, and off this thread: until there is
    /// an answer, nothing is said.
    private func wayOutIsDown(_ network: MachineNetwork) -> Bool {
        if let wayOut, Date().timeIntervalSince(wayOut.at) < 30 { return !wayOut.works }
        guard !askingWayOut else { return wayOut.map { !$0.works } ?? false }
        askingWayOut = true
        network.checkWayOut { [weak self] works in
            guard let self else { return }
            self.askingWayOut = false
            self.wayOut = (works, Date())
            if !works { HelperIO.log("way out: a connection to a name every Mac asks for was not made either") }
            self.reportTraffic()
        }
        return wayOut.map { !$0.works } ?? false
    }

    private func finish() -> Never {
        keepWindowPlacement()
        finished = true
        trafficTimer?.invalidate()
        reportTraffic()
        network?.stop()
        try? FileManager.default.removeItem(at: shutdownRequestURL)
        screenSleepCheck?.cancel()
        try? FileManager.default.removeItem(at: files.screenSleep)
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
