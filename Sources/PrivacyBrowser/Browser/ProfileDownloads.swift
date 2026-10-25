import AppKit
import BrowserCore
import os
import WebKit

/// Downloads of one running profile, kept in the profile's encrypted `DownloadVault`.
///
/// Every `WKDownload` of the profile is handed to this object (it outlives the tab that started
/// it). WebKit writes the file to `downloads/.incoming/<id>/` inside the profile directory; when
/// it finishes, the file is encrypted into the store and the plaintext is deleted. Downloads still
/// in progress when the profile stops are cancelled: their data store has to be released before
/// the profile can be sealed.
///
/// PLATFORM LIMITATION: `WKDownload` writes plaintext to a file URL; there is no streaming API to
/// encrypt on the fly. "Open" decrypts a temporary copy (deleted when the profile stops) for the
/// app that opens it, which may keep its own copies.
@MainActor
final class ProfileDownloads: NSObject, ObservableObject {
    struct Active: Identifiable, Equatable {
        let id: UUID
        var filename: String
        var fraction: Double
    }

    @Published private(set) var entries: [DownloadEntry] = []
    @Published private(set) var active: [Active] = []
    var onError: ((String) -> Void)?

    let vault: DownloadVault

    private final class Tracking {
        let id = UUID()
        let download: WKDownload
        var staged: URL?
        var filename = ""
        var sourceURL: URL?
        var mimeType: String?
        var observation: NSKeyValueObservation?

        init(download: WKDownload) { self.download = download }
    }

    private var tracking: [ObjectIdentifier: Tracking] = [:]
    private var imports: [UUID: Task<Void, Never>] = [:]
    private var openedCopies: [URL] = []
    private var isShutDown = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileDownloads")

    init(vault: DownloadVault) {
        self.vault = vault
        super.init()
        entries = vault.list()
    }

    // MARK: WebKit downloads

    /// Takes over a download WebKit created for one of the profile's tabs.
    func adopt(_ download: WKDownload) {
        guard !isShutDown else {
            download.cancel { _ in }
            return
        }
        let state = Tracking(download: download)
        state.sourceURL = download.originalRequest?.url
        tracking[ObjectIdentifier(download)] = state
        download.delegate = self
        let id = state.id
        state.observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async { self?.updateProgress(id, fraction) }
        }
    }

    private func updateProgress(_ id: UUID, _ fraction: Double) {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return }
        active[index].fraction = fraction
    }

    private func finishTracking(_ download: WKDownload) -> Tracking? {
        guard let state = tracking.removeValue(forKey: ObjectIdentifier(download)) else { return nil }
        state.observation?.invalidate()
        state.observation = nil
        return state
    }

    // MARK: Store actions

    /// Decrypts a temporary copy and opens it with the default app.
    func open(_ entry: DownloadEntry) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-open-\(UUID().uuidString)", isDirectory: true)
        openedCopies.append(folder)
        let vault = vault
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    let url = folder.appendingPathComponent(entry.filename)
                    try vault.export(entry.id, to: url)
                    return url
                }
            }.value
            switch result {
            case .success(let url):
                if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            case .failure(let error):
                self.report(String(format: L("downloads.error.open"), error.localizedDescription))
            }
        }
    }

    /// Decrypts a copy to a location the user picks.
    func saveCopy(_ entry: DownloadEntry, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.filename
        panel.canCreateDirectories = true
        let vault = vault
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let result = await Task.detached(priority: .userInitiated) { Result { try vault.export(entry.id, to: url) } }.value
                if case .failure(let error) = result {
                    self?.report(String(format: L("downloads.error.save"), error.localizedDescription))
                }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) } else { completion(panel.runModal()) }
    }

    func remove(_ entry: DownloadEntry) {
        do {
            try vault.remove(entry.id)
        } catch {
            report(error.localizedDescription)
        }
        entries = vault.list()
    }

    // MARK: Shutdown

    /// Cancels downloads in progress, refuses new ones and deletes their partial files.
    func shutDown() {
        guard !isShutDown else { return }
        isShutDown = true
        for state in tracking.values {
            state.observation?.invalidate()
            state.download.delegate = nil
            state.download.cancel { _ in }
            if let staged = state.staged { vault.discardIncoming(staged) }
        }
        tracking.removeAll()
        active.removeAll()
    }

    /// Waits until finished downloads have been encrypted, then deletes temporary opened copies.
    func finishPending() async {
        while let pending = imports.first {
            await pending.value.value
            imports.removeValue(forKey: pending.key)
        }
        for folder in openedCopies { try? FileManager.default.removeItem(at: folder) }
        openedCopies.removeAll()
    }

    private func report(_ message: String) {
        log.error("\(message, privacy: .public)")
        onError?(message)
    }
}

// MARK: - WKDownloadDelegate

extension ProfileDownloads: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard !isShutDown, let state = tracking[ObjectIdentifier(download)] else {
            completionHandler(nil)
            return
        }
        do {
            let url = try vault.makeIncomingURL(suggestedFilename: suggestedFilename)
            state.staged = url
            state.filename = url.lastPathComponent
            state.mimeType = response.mimeType
            if state.sourceURL == nil { state.sourceURL = response.url }
            active.append(Active(id: state.id, filename: state.filename, fraction: 0))
            completionHandler(url)
        } catch {
            _ = finishTracking(download)
            report(String(format: L("download.failed"), error.localizedDescription))
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let state = finishTracking(download), let staged = state.staged else { return }
        let vault = vault
        let id = state.id
        let filename = state.filename, sourceURL = state.sourceURL, mimeType = state.mimeType
        imports[id] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try vault.importFile(at: staged, filename: filename, sourceURL: sourceURL, mimeType: mimeType) }
            }.value
            guard let self else { return }
            self.imports.removeValue(forKey: id)
            self.active.removeAll { $0.id == id }
            self.entries = vault.list()
            if case .failure(let error) = result {
                vault.discardIncoming(staged)
                self.report(String(format: L("downloads.error.encrypt"), error.localizedDescription))
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let state = finishTracking(download) else { return }
        if let staged = state.staged { vault.discardIncoming(staged) }
        active.removeAll { $0.id == state.id }
        let nsError = error as NSError
        if !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            report(String(format: L("download.failed"), error.localizedDescription))
        }
    }
}
