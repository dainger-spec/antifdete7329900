import AppKit
import SwiftUI
import Virtualization
import VMControllerCore

enum EmbeddedVMError: LocalizedError {
    case unsupported(String)
    case alreadyRunning
    case softnet(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let why): "VM нельзя запустить в окне приложения: \(why)"
        case .alreadyRunning: "Этот профиль уже запущен (в другом окне или через tart)."
        case .softnet(let why): "Не удалось запустить сеть VM (softnet): \(why)"
        }
    }
}

/// Runs a Tart VM inside the app with Virtualization.framework, so its
/// display lives in our own window (VMDisplay) instead of Tart's. Tart still
/// owns the VM's files: we read config.json (TartVMBundle) and hold Tart's
/// run lock so `tart ip` / `tart list` see the VM as running and `tart run`
/// can't start it a second time. Network: VZ's NAT for "direct", or the
/// softnet helper — started like Tart does — for the fail-closed modes.
///
/// Needs the com.apple.security.virtualization entitlement (build-app.sh
/// signs with it); without it start() throws and the app falls back to
/// `tart run`.
@MainActor
final class EmbeddedVM: NSObject, ObservableObject, VZVirtualMachineDelegate {
    enum State: Equatable {
        case idle, starting, running, stopping
        case stopped(String?)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var virtualMachine: VZVirtualMachine?
    let bundle: TartVMBundle

    /// Diagnostic lines (softnet's output) for the app's log.
    var onLog: (@MainActor (String) -> Void)?
    /// The VM stopped by itself (guest shut down, error, softnet died); the
    /// message is nil for a clean shutdown.
    var onStopped: (@MainActor (String?) -> Void)?

    private var runLock: VMRunLock?
    private var softnet: Process?

    init(bundle: TartVMBundle) {
        self.bundle = bundle
    }

    static var isSupported: Bool { VZVirtualMachine.isSupported }

    func start(policy: NetworkPolicy, softnetPath: String?) async throws {
        guard state == .idle else { return }
        state = .starting
        do {
            // config.json was read by TartVMBundle.load; opening it again in
            // this process after locking would drop the POSIX lock.
            let lock = try VMRunLock(url: bundle.configURL)
            guard try lock.tryLock() else { throw EmbeddedVMError.alreadyRunning }
            runLock = lock
            let configuration = try makeConfiguration(policy: policy, softnetPath: softnetPath)
            try configuration.validate()
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = self
            virtualMachine = machine
            try await machine.start()
            // stop() while the VM was booting: power it off again.
            guard state == .starting else {
                if machine.canStop { try? await machine.stop() }
                throw CancellationError()
            }
            state = .running
        } catch {
            cleanUp()
            virtualMachine = nil
            state = .stopped(error.localizedDescription)
            throw error
        }
    }

    /// Asks macOS to shut down, then powers off after a few seconds (what
    /// `tart stop` does too). Safe to call more than once.
    func stop() async {
        switch state {
        case .stopped, .idle:
            cleanUp()
            return
        case .stopping:
            while state == .stopping { try? await Task.sleep(nanoseconds: 100_000_000) }
            return
        case .starting:
            // start() sees the state change and powers the VM off itself.
            state = .stopping
            finish(nil, notify: false)
            return
        case .running:
            break
        }
        state = .stopping
        if let machine = virtualMachine {
            if machine.canRequestStop { try? machine.requestStop() }
            for _ in 0..<12 where machine.state != .stopped && machine.state != .error {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if machine.state != .stopped && machine.state != .error && machine.canStop {
                try? await machine.stop()
            }
        }
        finish(nil, notify: false)
    }

    // MARK: VZVirtualMachineDelegate (called on the VM's queue: main)

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.finish(nil, notify: true) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.finish(message, notify: true) }
    }

    // MARK: Private

    private func finish(_ message: String?, notify: Bool) {
        if case .stopped = state { return }
        cleanUp()
        state = .stopped(message)
        if notify { onStopped?(message) }
    }

    private func cleanUp() {
        if let softnet, softnet.isRunning { softnet.interrupt() }
        softnet = nil
        runLock?.unlock()
        runLock = nil
    }

    private func softnetExited(_ code: Int32) {
        guard state == .running || state == .starting else { return }
        let message = "сеть VM (softnet) остановилась, код \(code)"
        onLog?(message)
        Task {
            if let machine = virtualMachine, machine.canStop { try? await machine.stop() }
            finish(message, notify: true)
        }
    }

    private func makeConfiguration(policy: NetworkPolicy, softnetPath: String?) throws -> VZVirtualMachineConfiguration {
        let config = bundle.config
        guard let hardwareData = config.hardwareModelData,
              let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData) else {
            throw EmbeddedVMError.unsupported("не читается модель оборудования VM")
        }
        guard hardwareModel.isSupported else {
            throw EmbeddedVMError.unsupported("эта версия macOS на Mac не запускает macOS из VM")
        }
        guard let identifierData = config.ecidData,
              let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
            throw EmbeddedVMError.unsupported("не читается идентификатор VM")
        }
        guard let macAddress = VZMACAddress(string: config.macAddress) else {
            throw EmbeddedVMError.unsupported("неверный MAC-адрес \(config.macAddress)")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.nvramURL)

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = min(max(config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                                     VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = min(max(config.memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                                       VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        // The view reconfigures the guest display to the window's size
        // (VMDisplay); this is only the size macOS boots with.
        let graphics = VZMacGraphicsDeviceConfiguration()
        let size = NSSize(width: config.display.width, height: config.display.height)
        if config.display.unit != "px", let screen = NSScreen.main {
            graphics.displays = [VZMacGraphicsDisplayConfiguration(for: screen, sizeInPoints: size)]
        } else {
            graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: config.display.width,
                                                                   heightInPixels: config.display.height,
                                                                   pixelsPerInch: 72)]
        }
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration(), VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration(), VZMacTrackpadConfiguration()]

        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false,
                                                          cachingMode: .automatic, synchronizationMode: .full)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.macAddress = macAddress
        if let arguments = SoftnetCommand.arguments(macAddress: config.macAddress, policy: policy) {
            guard let softnetPath else { throw EmbeddedVMError.softnet("softnet не найден") }
            network.attachment = try startSoftnet(path: softnetPath, arguments: arguments)
        } else {
            network.attachment = VZNATNetworkDeviceAttachment()
        }
        configuration.networkDevices = [network]

        // Sound out (pages play audio); no microphone.
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        configuration.audioDevices = [sound]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        return configuration
    }

    /// softnet gets the VM's end of a datagram socketpair on stdin — the CLI
    /// Tart uses (`--vm-fd 0`). It needs root: setuid, or it re-runs itself
    /// with passwordless sudo (SoftnetReadiness checked that).
    private func startSoftnet(path: String, arguments: [String]) throws -> VZFileHandleNetworkDeviceAttachment {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw EmbeddedVMError.softnet("socketpair: \(String(cString: strerror(errno)))")
        }
        for fd in fds { Self.setBuffers(fd) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            Task { @MainActor in lines.forEach { self?.onLog?("softnet: \($0)") } }
        }
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in self?.softnetExited(code) }
        }
        do {
            try process.run()
        } catch {
            close(fds[0])
            throw EmbeddedVMError.softnet(error.localizedDescription)
        }
        softnet = process
        return VZFileHandleNetworkDeviceAttachment(fileHandle: FileHandle(fileDescriptor: fds[0], closeOnDealloc: true))
    }

    /// Room for bursts of packets; receive at least twice the send size.
    private static func setBuffers(_ fd: Int32) {
        var send: Int32 = 1 << 20
        var receive: Int32 = 4 << 20
        let length = socklen_t(MemoryLayout<Int32>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send, length)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive, length)
    }
}

/// The VM's screen as a SwiftUI view. The guest display follows the view's
/// size, so macOS (and Safari, filled to the screen by the agent) resizes
/// with the window.
struct VMDisplay: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = false
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = virtualMachine
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== virtualMachine { view.virtualMachine = virtualMachine }
    }
}
