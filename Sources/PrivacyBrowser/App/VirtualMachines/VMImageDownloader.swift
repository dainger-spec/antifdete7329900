import BrowserCore
import Foundation
import os

/// Fetches Apple's restore image — the macOS a virtual machine is installed from — from Apple's
/// own servers into the machines' library, so that none of it is in the app's download. The work
/// is `VMImageFetch` (BrowserCore): several connections at once, chunk by chunk, each chunk under
/// `If-Range`, and what was fetched kept for a download that was paused or cut off. This is the
/// app's side of it: its failures in the person's language.
final class VMImageDownloader: @unchecked Sendable {
    typealias Progress = VMImageFetch.Progress

    /// A download that stopped, said in the person's language with what to do (`VMDownloadFailure`):
    /// a full disk, the network, Apple's refusal — with the system's own words, or the server's
    /// status, under them as a technical detail, never as the whole of what is said.
    struct Failure: LocalizedError {
        let reason: VMDownloadFailure
        /// The system's words, or the server's status; nil for the download's own failures.
        let detail: String?

        init(_ error: Error) {
            reason = VMDownloadFailure.of(error)
            switch reason {
            case .refused(let status): detail = "HTTP \(status)"
            case .incomplete, .notFetchable, .keepsChanging: detail = nil
            case .noRoom, .network, .other: detail = (error as NSError).localizedDescription
            }
        }

        /// What the setup says: a short line and what to do. The system's words, or the server's
        /// status, go to the log, never to the screen.
        var problem: VMProblem {
            let key: String
            switch reason {
            case .refused: key = "vm.download.error.refused"
            case .incomplete: key = "vm.download.error.incomplete"
            case .notFetchable: key = "vm.download.error.notFetchable"
            case .keepsChanging: key = "vm.download.error.keepsChanging"
            case .noRoom: key = "vm.download.error.noRoom"
            case .network: key = "vm.download.error.network"
            case .other: key = "vm.download.error.other"
            }
            if let detail, !detail.isEmpty {
                Logger(subsystem: "PrivacyBrowser", category: "VirtualMachines")
                    .error("The download of macOS stopped: \(detail, privacy: .private)")
            }
            if case .noRoom = reason { return .keyed(key, action: .storage) }
            return .keyed(key)
        }

        var errorDescription: String? { problem.text }
    }

    private let fetch: VMImageFetch

    init(library: VMLibrary, image: VMRestoreImage, onProgress: @escaping @Sendable (Progress) -> Void,
         onFinish: @escaping @Sendable (Result<Void, Error>) -> Void) {
        fetch = VMImageFetch(library: library, image: image, onProgress: onProgress, onFinish: { result in
            onFinish(result.mapError { error -> Error in Failure(error) })
        })
    }

    func start() {
        fetch.start()
    }

    /// Stops the download; what was fetched stays for the next start.
    func pause() {
        fetch.pause()
    }
}
