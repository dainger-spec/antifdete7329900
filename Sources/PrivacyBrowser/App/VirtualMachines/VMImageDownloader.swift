import BrowserCore
import Foundation

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

        var errorDescription: String? {
            let words: String
            switch reason {
            case .refused: words = L("vm.download.error.refused")
            case .incomplete: words = L("vm.download.error.incomplete")
            case .notFetchable: words = L("vm.download.error.notFetchable")
            case .keepsChanging: words = L("vm.download.error.keepsChanging")
            case .noRoom: words = L("vm.download.error.noRoom")
            case .network: words = L("vm.download.error.network")
            case .other: words = L("vm.download.error.other")
            }
            let said = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return said.isEmpty ? words : words + "\n" + String(format: L("vm.row.trouble.detail"), said)
        }
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
