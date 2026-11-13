#if arch(arm64)
import BrowserCore
import Foundation
import Virtualization

/// A machine as Apple's framework is told of it: the virtual Mac (its model, its identifier, its
/// firmware variables), its processors and memory, its screen, its disk, its network card, and the
/// folder it shares with the app.
enum MachineConfiguration {
    /// Devices a machine can do without. A configuration the framework refuses is tried again with
    /// fewer of them, so that a Mac or a macOS that lacks one still gets a machine.
    struct Extras {
        var microphone = true
        var sound = true
        var balloon = true

        /// Each next one with one thing less.
        static let ladder = [Extras(), Extras(microphone: false), Extras(microphone: false, sound: false),
                             Extras(microphone: false, sound: false, balloon: false)]
    }

    static func make(files: VMLibrary.MachineFiles, request: VMHelperRequest, hardwareModel: VZMacHardwareModel,
                     machineIdentifier: VZMacMachineIdentifier, auxiliaryStorage: VZMacAuxiliaryStorage,
                     network: VZNetworkDeviceAttachment?) throws -> VZVirtualMachineConfiguration {
        var refusal: Error?
        for extras in Extras.ladder {
            let configuration = try build(files: files, request: request, hardwareModel: hardwareModel,
                                          machineIdentifier: machineIdentifier, auxiliaryStorage: auxiliaryStorage,
                                          network: network, extras: extras)
            do {
                try configuration.validate()
                return configuration
            } catch {
                refusal = error
            }
        }
        throw refusal ?? CocoaError(.featureUnsupported)
    }

    private static func build(files: VMLibrary.MachineFiles, request: VMHelperRequest, hardwareModel: VZMacHardwareModel,
                              machineIdentifier: VZMacMachineIdentifier, auxiliaryStorage: VZMacAuxiliaryStorage,
                              network: VZNetworkDeviceAttachment?, extras: Extras) throws -> VZVirtualMachineConfiguration {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = auxiliaryStorage

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = min(max(request.cores, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                                     VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = min(max(UInt64(max(request.memoryBytes, 0)), VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                                       VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        // The screen of the Mac the profile is (a page reads its size): never this window's.
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: request.display.pixelsWide,
                                                               heightInPixels: request.display.pixelsHigh,
                                                               pixelsPerInch: request.display.pixelsPerInch)]
        configuration.graphicsDevices = [graphics]

        let disk = try VZDiskImageStorageDeviceAttachment(url: files.disk, readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        if let network {
            let card = VZVirtioNetworkDeviceConfiguration()
            card.attachment = network
            // The same address the network at the card's other end knows the guest by.
            if let address = VZMACAddress(string: MachineNetwork.macAddress(of: request)) { card.macAddress = address }
            configuration.networkDevices = [card]
        }

        configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        if extras.balloon { configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()] }

        if extras.sound {
            // Speakers, as every Mac has: what the guest plays is heard here. A microphone that
            // hears nothing — no source is given to it, so nothing of this Mac's is recorded — as
            // a Mac has one too.
            let sound = VZVirtioSoundDeviceConfiguration()
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            sound.streams = extras.microphone ? [output, VZVirtioSoundDeviceInputStreamConfiguration()] : [output]
            configuration.audioDevices = [sound]
        }

        // The folder the guest and the app share: the settings in, the status out (`VMGuestSettings`).
        try FileManager.default.createDirectory(at: files.share, withIntermediateDirectories: true)
        let share = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: files.share, readOnly: false))
        configuration.directorySharingDevices = [share]
        return configuration
    }
}

/// Which macOS Apple offers for a virtual machine on this Mac.
enum MachineCatalog {
    static func run() {
        VZMacOSRestoreImage.fetchLatestSupported { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    HelperIO.fail(error)
                case .success(let image):
                    guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
                        HelperIO.fail("The macOS Apple offers now cannot run in a virtual machine on this Mac. Update this Mac's macOS and try again.")
                    }
                    HelperIO.emit(VMHelperEvent(kind: .catalog, image: restoreImage(image)))
                    exit(0)
                }
            }
        }
    }

    static func restoreImage(_ image: VZMacOSRestoreImage) -> VMRestoreImage {
        let version = image.operatingSystemVersion
        let text = version.patchVersion == 0 ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return VMRestoreImage(url: image.url, version: text, build: image.buildVersion)
    }
}

/// Installs macOS from Apple's restore image into a new machine: the base every profile's machine
/// is cloned from.
final class MachineInstaller {
    private let request: VMHelperRequest
    private var machine: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var observation: NSKeyValueObservation?
    private var lastFraction = -1.0

    init(request: VMHelperRequest) {
        self.request = request
    }

    func run() {
        guard let imagePath = request.restoreImagePath, let directory = request.machineDirectory else {
            HelperIO.fail("The request names no restore image or no folder.")
        }
        let imageURL = URL(fileURLWithPath: imagePath)
        let files = VMLibrary.MachineFiles(directory: URL(fileURLWithPath: directory, isDirectory: true))
        VZMacOSRestoreImage.load(from: imageURL) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): HelperIO.fail(error)
                case .success(let image): self.install(image, from: imageURL, into: files)
                }
            }
        }
    }

    private func install(_ image: VZMacOSRestoreImage, from imageURL: URL, into files: VMLibrary.MachineFiles) {
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            HelperIO.fail("This restore image's macOS cannot run in a virtual machine on this Mac.")
        }
        do {
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            // What an installation that stopped part-way left is not a system: made again.
            for url in [files.disk, files.auxiliaryStorage, files.hardwareModel, files.machineIdentifier] {
                try? FileManager.default.removeItem(at: url)
            }
            try requirements.hardwareModel.dataRepresentation.write(to: files.hardwareModel)
            let identifier = VZMacMachineIdentifier()
            try identifier.dataRepresentation.write(to: files.machineIdentifier)
            let auxiliary = try VZMacAuxiliaryStorage(creatingStorageAt: files.auxiliaryStorage,
                                                      hardwareModel: requirements.hardwareModel, options: [])
            try Self.createDisk(at: files.disk, bytes: request.diskBytes)

            // Never less than what this macOS's installer asks for.
            var adjusted = self.request
            adjusted.cores = max(adjusted.cores, requirements.minimumSupportedCPUCount)
            adjusted.memoryBytes = max(adjusted.memoryBytes, Int64(clamping: requirements.minimumSupportedMemorySize))
            let configuration = try MachineConfiguration.make(files: files, request: adjusted, hardwareModel: requirements.hardwareModel,
                                                              machineIdentifier: identifier, auxiliaryStorage: auxiliary, network: nil)
            let machine = VZVirtualMachine(configuration: configuration)
            let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: imageURL)
            self.machine = machine
            self.installer = installer
            observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                DispatchQueue.main.async {
                    guard let self, fraction - self.lastFraction >= 0.002 || fraction >= 1 else { return }
                    self.lastFraction = fraction
                    HelperIO.emit(VMHelperEvent(kind: .progress, fraction: fraction))
                }
            }
            installer.install { result in
                DispatchQueue.main.async {
                    switch result {
                    case .failure(let error):
                        HelperIO.fail(error)
                    case .success:
                        HelperIO.emit(VMHelperEvent(kind: .installed, image: MachineCatalog.restoreImage(image)))
                        exit(0)
                    }
                }
            }
        } catch {
            HelperIO.fail(error)
        }
    }

    /// A disk of `bytes` that takes no room until the guest writes to it.
    static func createDisk(at url: URL, bytes: Int64) throws {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(bytes)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
#endif
