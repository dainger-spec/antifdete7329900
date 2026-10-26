import AppKit
import BrowserCore
import SwiftUI
import WebKit

/// Downloads of one running profile. Files go to the profile's own folder,
/// `~/Downloads/PrivacyBrowser/<profile name>/`, so downloads of different profiles never mix.
///
/// It is the `WKDownloadDelegate` of every download the profile starts (not the tab), so a
/// download keeps going when its tab closes. Stopping the profile cancels unfinished downloads
/// and removes their partial files.
///
/// LIMITATION: downloaded files are ordinary files in ~/Downloads — not encrypted, and they stay
/// when the profile is deleted. In the App Sandbox this needs
/// `com.apple.security.files.downloads.read-write`.
@MainActor
final class DownloadsController: NSObject, ObservableObject {
    @MainActor
    final class Item: ObservableObject, Identifiable {
        enum State: Equatable {
            case downloading
            case finished
            case failed(String)
            case cancelled
        }

        let id = UUID()
        @Published var fileName: String
        @Published var destination: URL?
        /// nil while the size is unknown.
        @Published var fraction: Double?
        @Published var state: State = .downloading
        fileprivate weak var download: WKDownload?
        fileprivate var observation: NSKeyValueObservation?

        init(fileName: String) {
            self.fileName = fileName
        }
    }

    @Published private(set) var items: [Item] = []
    let folder: URL
    var onChange: (() -> Void)?

    init(profileName: String) {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        folder = DownloadLocation.profileFolder(base: base, profileName: profileName)
        super.init()
    }

    var activeCount: Int { items.filter { $0.state == .downloading }.count }

    /// Takes over a download a tab started.
    func adopt(_ download: WKDownload) {
        download.delegate = self
    }

    func revealInFinder(_ item: Item) {
        if let url = item.destination, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            openFolder()
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func cancel(_ item: Item) {
        item.download?.cancel { _ in }
        finish(item, state: .cancelled)
    }

    func clearCompleted() {
        items.removeAll { $0.state != .downloading }
        onChange?()
    }

    /// The profile is stopping: unfinished downloads can't continue without its data store.
    func cancelAll() {
        for item in items where item.state == .downloading { cancel(item) }
    }

    private func item(for download: WKDownload) -> Item? {
        items.first { $0.download === download }
    }

    private func finish(_ item: Item, state: Item.State) {
        guard item.state == .downloading else { return }
        item.observation?.invalidate()
        item.observation = nil
        item.state = state
        if state == .finished {
            item.fraction = 1
            Log.info("downloads", "finished")
        } else if let destination = item.destination {
            // Our own unique path for this download: a partial file there is ours to remove.
            try? FileManager.default.removeItem(at: destination)
        }
        onChange?()
    }
}

extension DownloadsController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.error("downloads", "cannot create the profile's download folder: \(Log.describe(error))")
            completionHandler(nil)
            return
        }
        let destination = DownloadLocation.uniqueFileURL(in: folder, suggestedFilename: suggestedFilename) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let item = Item(fileName: destination.lastPathComponent)
        item.destination = destination
        item.download = download
        item.observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak item] progress, _ in
            let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            Task { @MainActor in item?.fraction = fraction }
        }
        items.insert(item, at: 0)
        onChange?()
        Log.info("downloads", "started")
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let item = item(for: download) { finish(item, state: .finished) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        let message = ErrorPresenter.alert(for: error)?.message ?? L("downloads.failed")
        Log.error("downloads", "failed: \(Log.describe(error))")
        finish(item, state: .failed(message))
    }
}

/// The downloads list shown from the browser toolbar.
struct DownloadsView: View {
    @ObservedObject var controller: DownloadsController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("downloads.title")).font(.headline)
                Spacer()
                Button(L("downloads.openFolder")) { controller.openFolder() }
                    .buttonStyle(.link)
            }
            .padding(12)
            Divider()
            if controller.items.isEmpty {
                Text(L("downloads.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(controller.items) { item in
                            DownloadRow(item: item, controller: controller)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
                Divider()
                HStack {
                    Spacer()
                    Button(L("downloads.clear")) { controller.clearCompleted() }
                        .disabled(controller.items.allSatisfy { $0.state == .downloading })
                }
                .padding(10)
            }
        }
        .frame(width: 380)
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadsController.Item
    let controller: DownloadsController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .downloading:
                    if let fraction = item.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                case .finished:
                    Text(L("downloads.done")).font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                case .cancelled:
                    Text(L("downloads.cancelled")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.state == .downloading {
                Button { controller.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help(L("downloads.cancel"))
            } else if item.state == .finished {
                Button { controller.revealInFinder(item) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.borderless)
                    .help(L("downloads.reveal"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
