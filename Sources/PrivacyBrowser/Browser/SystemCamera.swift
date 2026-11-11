import AppKit
import AVFoundation
import BrowserCore
import Foundation
import os
import SystemExtensions

/// The app's side of the system virtual camera (the CMIO Camera Extension; docs/CAMERA.md). It
/// installs and switches the extension on through `OSSystemExtensionManager` (as `NetworkGuard`
/// does the content filter), learns from macOS where it stands (`refresh`) and replaces a copy an
/// earlier version of the app installed, remembers in the shared app group whether it is active,
/// and writes the active profile's render settings there for the app's feed to draw
/// (`SystemCameraFeed`, which hands the frames to the extension's sink). Only the app's
/// own process reaches the app group: a profile's own process is told at its start whether the
/// device is there (`activeForLaunch`, `ProfileProcess.systemCameraActiveForThisProcess`) and gates
/// the global device by it (`PrivacyScripts.patchSystemCamera`).
///
/// The extension and the app group are present only in a signed build that embedded the extension
/// (`CAM=1 scripts/build-app.sh`); without them this does nothing and `isActive` is false.
@MainActor
final class SystemCamera: NSObject, ObservableObject {
    static let shared = SystemCamera()

    /// Where the installed extension stands.
    enum State: Equatable {
        /// This build did not embed the camera extension.
        case notInBuild
        case notInstalled
        case installing
        case awaitingApproval
        case active
        /// macOS finishes installing it at the next restart.
        case restartNeeded
        case failed(String)
    }

    /// What stopped the last attempt, said in words for the settings page.
    enum Problem: Equatable {
        case reboot
        case location
        case signing
        case authorization
        case policy
        case other(String)
    }

    @Published private(set) var state: State
    @Published private(set) var problem: Problem?
    /// macOS lists the camera device itself right now (`isDevicePresent`). Installed and on, yet not
    /// listed, it waits for a restart (a replaced copy) — the editor says so.
    @Published private(set) var devicePresent = false
    /// This app is not allowed the camera, so its feed cannot write into the device's sink
    /// (`SystemCameraFeed`): a page would get the fallback test pattern. Read again at `refresh`.
    @Published private(set) var cameraAccessDenied = false

    /// The extension's bundle identifier, from the app's Info.plist (`CAM=1 scripts/build-app.sh`).
    let extensionIdentifier: String?
    /// The shared app group both the app and the extension are entitled to; nil without the extension.
    let appGroup: String?

    private let log = Logger(subsystem: "PrivacyBrowser", category: "SystemCamera")
    /// The install, replacement or removal under way; its answers are told apart from a properties
    /// request's by identity — macOS finishes a properties request as `.completed` too, which must
    /// not read as an install.
    private var pendingRequest: OSSystemExtensionRequest?
    /// `pendingRequest` installs (true) or removes (false) the extension.
    private var pendingIsActivation = false
    /// `pendingRequest` replaces a copy that runs (the app was updated): the camera stays on meanwhile.
    private var pendingIsReplacement = false
    /// An outdated copy was asked to be replaced in this run — once: one that fails keeps the copy
    /// that works.
    private var replacementAsked = false
    /// The question to macOS under way (`refresh`), answered in `foundProperties`.
    private var propertiesRequest: OSSystemExtensionRequest?
    private var observers: [NSObjectProtocol] = []

    /// Info.plist keys `CAM=1 scripts/build-app.sh` writes on the app.
    static let extensionKey = "PBCameraExtensionBundleIdentifier"
    static let appGroupKey = "PBCameraAppGroup"
    /// The flag in the shared defaults: the extension is installed and on.
    static let activeDefaultsKey = "PBCameraExtensionActive"
    static let configFileName = "camera.json"

    override init() {
        extensionIdentifier = Bundle.main.object(forInfoDictionaryKey: Self.extensionKey) as? String
        appGroup = Bundle.main.object(forInfoDictionaryKey: Self.appGroupKey) as? String
        state = extensionIdentifier == nil ? .notInBuild : .notInstalled
        super.init()
        guard extensionIdentifier != nil else { return }
        // What the shared flag last recorded, until macOS answers — so an installed camera does not
        // read as missing every time the app starts (the editor only learned it from an install's
        // answer before, 0.1.7).
        if isActive { state = .active }
        devicePresent = Self.isDevicePresent()
        // Back from System Settings, where the person switches it on or off: asked again.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // The device comes and goes with the extension (an install, a replacement, a restart); the
        // frames the app feeds it go to the device there is now.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.devicePresent = SystemCamera.isDevicePresent() }
                SystemCameraFeed.shared.reconnect()
            })
        }
        DispatchQueue.main.async { self.refresh() }
    }

    /// Asks macOS where the extension stands (no prompts), as `NetworkGuard.refresh` does for the
    /// guard, and records it: the editor's state, and the shared flag a profile's launch reads. Not
    /// while an install is under way — its own answers settle that.
    func refresh() {
        cameraAccessDenied = Self.isCameraAccessDenied()
        guard let identifier = extensionIdentifier, pendingRequest == nil else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        propertiesRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// What macOS knows of this app's camera extension (every copy of it: an enabled one, one waiting
    /// for the person's approval, an earlier one waiting to be removed).
    private func extensionProperties(_ properties: [OSSystemExtensionProperties]) {
        devicePresent = Self.isDevicePresent()
        let enabled = properties.filter { $0.isEnabled && !$0.isUninstalling }
        if !enabled.isEmpty {
            setActiveFlag(true)
            problem = nil
            state = .active
            // macOS replaces an installed extension only on an activation request: a copy that is not
            // this app's own version (the app was updated) is replaced now, without a new approval —
            // as the network guard is (`NetworkGuard.extensionProperties`). Without it the camera an
            // earlier version installed would draw on after every update.
            if !replacementAsked, let bundled = bundledExtensionVersion, !enabled.contains(where: { $0.bundleVersion == bundled }) {
                replacementAsked = true
                log.notice("the installed camera is not this app's version \(bundled, privacy: .public): replacing it")
                submitActivation(replacing: true)
            }
        } else if properties.contains(where: \.isAwaitingUserApproval) {
            setActiveFlag(false)
            state = .awaitingApproval
        } else if properties.contains(where: \.isUninstalling) {
            // Only an earlier copy, waiting to be removed at the next restart: until then a new one
            // does not install (the owner's Mac, 11 November).
            setActiveFlag(false)
            problem = .reboot
            state = .restartNeeded
        } else {
            setActiveFlag(false)
            state = .notInstalled
        }
    }

    /// The extension is installed and switched on, as the shared flag records.
    var isActive: Bool {
        guard extensionIdentifier != nil else { return false }
        return Self.sharedDefaults(appGroup)?.bool(forKey: Self.activeDefaultsKey) ?? false
    }

    /// Whether macOS lists the virtual camera device right now — the device list itself (no camera
    /// permission, no capture, as `HostCamera` reads it), not what the extension's install says.
    static func isDevicePresent() -> Bool {
        let name = CameraSubstitution.systemDeviceName
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        return discovery.devices.contains { $0.localizedName == name || $0.modelID == name }
    }

    /// The person said no to this app's camera access (or a policy did).
    static func isCameraAccessDenied() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    /// What a profile is told at its launch about the system camera (`PrivacyScripts.cameraScript`,
    /// `systemCameraScript`). One that uses it: whether the device is on this Mac now — without it
    /// the profile gets no camera at once, and a site's first visit never opens the real one to look.
    /// Any other profile: whenever the device may be there — listed now, or this build carries the
    /// extension, which may be installed while the profile runs — so that it hides it; a build
    /// without the extension hides a device another copy of the app installed, as it is the Mac's.
    func activeForLaunch(usesSystemCamera: Bool) -> Bool {
        let present = Self.isDevicePresent()
        if extensionIdentifier != nil { devicePresent = present }
        return usesSystemCamera ? present : (present || extensionIdentifier != nil)
    }

    /// The shared defaults for the app group, or nil without one.
    static func sharedDefaults(_ appGroup: String?) -> UserDefaults? {
        guard let appGroup else { return nil }
        return UserDefaults(suiteName: appGroup)
    }

    /// Asks macOS to install the extension (its prompt, then a switch in System Settings). Asked
    /// again while one waits, the newer request is the one answered for (the older one's answers are
    /// told apart by identity in the delegate).
    func install() {
        guard extensionIdentifier != nil else { return }
        problem = nil
        state = .installing
        submitActivation(replacing: false)
    }

    private func submitActivation(replacing: Bool) {
        guard let identifier = extensionIdentifier else { return }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        pendingIsActivation = true
        pendingIsReplacement = replacing
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Switches the extension off and forgets it.
    func deactivate() {
        guard let identifier = extensionIdentifier else { return }
        problem = nil
        setActiveFlag(false)
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        pendingIsActivation = false
        pendingIsReplacement = false
        OSSystemExtensionManager.shared.submitRequest(request)
        state = .notInstalled
    }

    func openSystemSettings() {
        SystemOpen.openSystemSettingsForExtensions()
    }

    /// CFBundleVersion of the camera inside this app (a new one per build, scripts/build-app.sh).
    private var bundledExtensionVersion: String? {
        guard let identifier = extensionIdentifier else { return nil }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(identifier).systemextension")
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static let imageFileName = "camera-image.bin"

    private static func videoFileName(for type: String?) -> String {
        switch type {
        case "video/quicktime": return "camera-video.mov"
        case "video/mp4", "video/mpeg": return "camera-video.mp4"
        default: return "camera-video.mp4"
        }
    }

    /// Writes what the camera should show for `camera` to the shared app group — the render
    /// settings, and the image's or the video's bytes. The app's own feed reads them there and draws
    /// the frames (`SystemCameraFeed`; the extension itself cannot read the person's app group). The
    /// device is one and global, so the last profile to launch with the system camera sets what it
    /// shows.
    func writeRenderConfig(for camera: CameraSubstitution) {
        guard let appGroup,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        var config: [String: Any] = [
            "source": camera.systemCameraSource, "color": camera.colorHex,
            "width": camera.width, "height": camera.height, "frameRate": camera.frameRate,
            "fit": camera.fit.rawValue, "mirror": camera.mirror,
        ]
        if camera.crop.enabled {
            config["crop"] = ["enabled": true, "x": camera.crop.x, "y": camera.crop.y,
                              "width": camera.crop.width, "height": camera.crop.height]
        }
        if !camera.filters.isIdentity {
            let f = camera.filters
            config["filters"] = ["brightness": f.brightness, "contrast": f.contrast, "saturation": f.saturation,
                                 "blur": f.blur, "hueRotate": f.hueRotate, "sepia": f.sepia, "invert": f.invert,
                                 "opacity": f.opacity, "grayscale": f.grayscale]
        }
        let imageURL = container.appendingPathComponent(Self.imageFileName)
        let videoName = Self.videoFileName(for: camera.videoType)
        let videoURL = container.appendingPathComponent(videoName)
        if camera.source == .video, camera.videoData != nil {
            let p = camera.playback
            config["videoFile"] = videoName
            config["playback"] = ["loop": p.loop, "paused": p.paused, "rate": p.rate,
                                  "startOffset": p.startOffset, "endOffset": p.endOffset]
        }
        do {
            try JSONSerialization.data(withJSONObject: config).write(to: container.appendingPathComponent(Self.configFileName), options: .atomic)
            // Keep only the file the current source needs; drop a stale one of the other kind.
            if camera.source == .image, let image = camera.imageData {
                try image.write(to: imageURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: imageURL)
            }
            if camera.source == .video, let video = camera.videoData {
                try video.write(to: videoURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: videoURL)
            }
        } catch {
            log.error("could not write the camera config: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func setActiveFlag(_ active: Bool) {
        Self.sharedDefaults(appGroup)?.set(active, forKey: Self.activeDefaultsKey)
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension SystemCamera: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // The app's own extension replaces an older copy (an update): allowed once, for this team.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            guard request === pendingRequest else { return }
            state = .awaitingApproval
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            // Only the install, replacement or removal under way decides anything here: a properties
            // request finishes as `.completed` too, its answer already given in `foundProperties`.
            guard request === pendingRequest else {
                if request === propertiesRequest { propertiesRequest = nil }
                return
            }
            let activation = pendingIsActivation
            let replacement = pendingIsReplacement
            pendingRequest = nil
            pendingIsActivation = false
            pendingIsReplacement = false
            // A removal finished: the flag was cleared when it was asked (`deactivate`).
            guard activation else { return }
            switch result {
            case .completed:
                setActiveFlag(true)
                problem = nil
                state = .active
                devicePresent = Self.isDevicePresent()
            case .willCompleteAfterReboot:
                // A replacement whose earlier copy still runs: the camera works until the restart.
                if replacement, Self.isDevicePresent() {
                    log.notice("the camera's new version runs after a restart; the earlier one runs until then")
                    devicePresent = true
                    return
                }
                problem = .reboot
                state = .restartNeeded
            @unknown default:
                if replacement { return }
                state = .failed("\(result.rawValue)")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        MainActor.assumeIsolated {
            guard request === propertiesRequest else { return }
            propertiesRequest = nil
            // An install or removal asked for meanwhile settles it with its own answers.
            guard pendingRequest == nil else { return }
            extensionProperties(properties)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            log.error("camera extension request failed: \(error.localizedDescription, privacy: .private)")
            let code = (error as? OSSystemExtensionError)?.code
            if request === propertiesRequest {
                propertiesRequest = nil
                // As for the guard (`NetworkGuard`): a properties request that fails — an extension
                // never installed — means it is not; a cancelled one answers nothing.
                guard pendingRequest == nil, code != .requestCanceled else { return }
                setActiveFlag(false)
                state = .notInstalled
                return
            }
            guard request === pendingRequest else { return }
            let activation = pendingIsActivation
            let replacement = pendingIsReplacement
            pendingRequest = nil
            pendingIsActivation = false
            pendingIsReplacement = false
            // A replacement that failed keeps the copy that runs (logged above), and a removal that
            // failed leaves the extension where it was: macOS is asked.
            if replacement { return }
            guard activation else {
                refresh()
                return
            }
            switch code {
            case .requestCanceled?: break
            case .unsupportedParentBundleLocation?: problem = .location
            case .missingEntitlement?, .codeSignatureInvalid?, .validationFailed?, .extensionNotFound?, .extensionMissingIdentifier?:
                problem = .signing
            case .authorizationRequired?: problem = .authorization
            case .forbiddenBySystemPolicy?: problem = .policy
            default: problem = .other(error.localizedDescription)
            }
            state = .notInstalled
            // An earlier copy may still be on, or wait for a restart: macOS says which, and the reason
            // above stays unless it is on.
            refresh()
        }
    }
}
