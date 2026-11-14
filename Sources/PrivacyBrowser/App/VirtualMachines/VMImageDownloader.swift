import BrowserCore
import Foundation

/// Fetches Apple's restore image — the macOS a virtual machine is installed from — from Apple's
/// own servers into the machines' library, so that none of it is in the app's download. The work
/// is `VMImageFetch` (BrowserCore): several connections at once, chunk by chunk, each chunk under
/// `If-Range`, and what was fetched kept for a download that was paused or cut off. This is the
/// app's side of it: its failures in the person's language.
final class VMImageDownloader: @unchecked Sendable {
    typealias Progress = VMImageFetch.Progress

    enum Failure: LocalizedError {
        case refused(Int)
        case incomplete
        case notFetchable
        case keepsChanging

        var errorDescription: String? {
            switch self {
            case .refused(let status): return String(format: L("vm.download.error.refused"), status)
            case .incomplete: return L("vm.download.error.incomplete")
            case .notFetchable: return L("vm.download.error.notFetchable")
            case .keepsChanging: return L("vm.download.error.keepsChanging")
            }
        }

        init?(_ failure: VMImageFetch.Failure) {
            switch failure {
            case .refused(let status): self = .refused(status)
            case .incomplete: self = .incomplete
            case .notFetchable: self = .notFetchable
            case .keepsChanging: self = .keepsChanging
            }
        }
    }

    private let fetch: VMImageFetch

    init(library: VMLibrary, image: VMRestoreImage, onProgress: @escaping @Sendable (Progress) -> Void,
         onFinish: @escaping @Sendable (Result<Void, Error>) -> Void) {
        fetch = VMImageFetch(library: library, image: image, onProgress: onProgress, onFinish: { result in
            onFinish(result.mapError { error -> Error in
                if let failure = error as? VMImageFetch.Failure, let said = Failure(failure) { return said }
                return error
            })
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
