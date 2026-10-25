import AppKit
import BrowserCore
import SwiftUI

/// Which pane the library window shows; changed from outside (⌘Y vs. "Show All Bookmarks").
@MainActor
final class LibraryNavigation: ObservableObject {
    @Published var section: LibraryView.Section = .bookmarks
}

/// Per-profile bookmarks and history. Only available while the profile runs (the data is
/// decrypted only then).
struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case bookmarks = "Bookmarks"
        case history = "History"
        var id: String { rawValue }
    }

    @ObservedObject var library: ProfileLibrary
    @ObservedObject var navigation: LibraryNavigation
    let open: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $navigation.section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(10)
            Divider()
            switch navigation.section {
            case .bookmarks: BookmarksPane(library: library, open: open)
            case .history: HistoryPane(library: library, open: open)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

// MARK: - Bookmarks

private struct BookmarkGroup: Identifiable {
    var id: String
    var title: String
    var items: [Bookmark]
}

private struct BookmarksPane: View {
    @ObservedObject var library: ProfileLibrary
    let open: (URL) -> Void
    @State private var selection: UUID?
    @State private var editing: BookmarkEditor.Target?

    private var groups: [BookmarkGroup] {
        var result: [BookmarkGroup] = []
        for bookmark in library.bookmarks { // already ordered: top level first, then folders
            let key = bookmark.folder ?? ""
            if result.last?.id == key {
                result[result.count - 1].items.append(bookmark)
            } else {
                result.append(BookmarkGroup(id: key, title: bookmark.folder ?? "Favorites", items: [bookmark]))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(groups) { group in
                    SwiftUI.Section(group.title) {
                        ForEach(group.items) { bookmark in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.title).lineLimit(1)
                                Text(bookmark.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .tag(bookmark.id)
                        }
                        .onMove { source, destination in move(in: group, from: source, to: destination) }
                    }
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let bookmark = bookmark(id) {
                    Button("Open in New Tab") { openBookmark(bookmark) }
                    Button("Edit…") { editing = .existing(bookmark) }
                    Divider()
                    Button("Delete", role: .destructive) { library.removeBookmark(id: id) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let bookmark = bookmark(id) { openBookmark(bookmark) }
            }
            .overlay {
                if library.bookmarks.isEmpty {
                    Text("No bookmarks. Use ☆ in the toolbar or ⌘D to bookmark a page.")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button { editing = .new } label: { Label("Add", systemImage: "plus") }
                Button("Edit…") { if let bookmark = selection.flatMap(bookmark) { editing = .existing(bookmark) } }
                    .disabled(selection == nil)
                Button("Delete", role: .destructive) { if let selection { library.removeBookmark(id: selection) } }
                    .disabled(selection == nil)
                Spacer()
                Text("Drag to reorder within a folder").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .sheet(item: $editing) { target in
            BookmarkEditor(target: target, folders: library.bookmarkFolders) { title, url, folder in
                switch target {
                case .new:
                    library.addBookmark(title: title, url: url, folder: folder)
                case .existing(var bookmark):
                    bookmark.title = title
                    bookmark.url = url.absoluteString
                    bookmark.folder = folder
                    library.updateBookmark(bookmark)
                }
            }
        }
    }

    private func bookmark(_ id: UUID) -> Bookmark? {
        library.bookmarks.first { $0.id == id }
    }

    private func openBookmark(_ bookmark: Bookmark) {
        if let url = URL(string: bookmark.url) { open(url) }
    }

    /// SwiftUI reports the destination as an index in the list *before* removal.
    private func move(in group: BookmarkGroup, from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let target = destination > from ? destination - 1 : destination
        library.moveBookmark(id: group.items[from].id, toIndex: target)
    }
}

private struct BookmarkEditor: View {
    enum Target: Identifiable {
        case new
        case existing(Bookmark)
        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let bookmark): return bookmark.id.uuidString
            }
        }
    }

    let target: Target
    let folders: [String]
    let onSave: (String, URL, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var urlString = ""
    @State private var folder = ""
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Title", text: $title)
            TextField("URL", text: $urlString, prompt: Text("https://example.com"))
            HStack {
                TextField("Folder", text: $folder, prompt: Text("None (Favorites)"))
                if !folders.isEmpty {
                    Menu("Choose") {
                        Button("None") { folder = "" }
                        ForEach(folders, id: \.self) { name in Button(name) { folder = name } }
                    }
                    .fixedSize()
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .padding()
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
        }
        .onAppear {
            if case .existing(let bookmark) = target {
                title = bookmark.title
                urlString = bookmark.url
                folder = bookmark.folder ?? ""
            }
        }
    }

    private func save() {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              HistoryStore.normalizedURL(url) != nil else {
            error = "Enter an http(s) URL."
            return
        }
        let trimmedFolder = folder.trimmingCharacters(in: .whitespaces)
        onSave(title, url, trimmedFolder.isEmpty ? nil : trimmedFolder)
        dismiss()
    }
}

// MARK: - History

private struct HistoryDay: Identifiable {
    var id: Date
    var entries: [HistoryEntry]
}

private struct HistoryPane: View {
    @ObservedObject var library: ProfileLibrary
    let open: (URL) -> Void
    @State private var query = ""
    @State private var selection: String?
    @State private var confirmClearAll = false

    private var days: [HistoryDay] {
        _ = library.historyRevision // re-evaluate on every history change
        let calendar = Calendar.current
        var result: [HistoryDay] = []
        for entry in library.historyEntries(matching: query) { // newest first
            let day = calendar.startOfDay(for: entry.lastVisitedAt)
            if result.last?.id == day {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append(HistoryDay(id: day, entries: [entry]))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search history", text: $query)
                    .textFieldStyle(.roundedBorder)
                Menu("Clear") {
                    Button("Last Hour") { library.clearHistory(since: Date().addingTimeInterval(-3_600)) }
                    Button("Today") { library.clearHistory(since: Calendar.current.startOfDay(for: Date())) }
                    Button("Today and Yesterday") {
                        let today = Calendar.current.startOfDay(for: Date())
                        library.clearHistory(since: Calendar.current.date(byAdding: .day, value: -1, to: today))
                    }
                    Divider()
                    Button("All History…") { confirmClearAll = true }
                }
                .fixedSize()
            }
            .padding(8)
            if !library.recordsHistory {
                notice("History recording is turned off for this profile.")
            } else if !library.historyIsPersistent {
                notice("Ephemeral profile: history is kept in memory only and discarded when the profile stops.")
            }
            List(selection: $selection) {
                ForEach(days) { day in
                    SwiftUI.Section(day.id.formatted(date: .complete, time: .omitted)) {
                        ForEach(day.entries) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title.isEmpty ? entry.url : entry.title).lineLimit(1)
                                    Text(entry.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(entry.lastVisitedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .tag(entry.url)
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { urls in
                if let url = urls.first {
                    Button("Open in New Tab") { if let target = URL(string: url) { open(target) } }
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                    Divider()
                    Button("Delete", role: .destructive) { library.removeHistoryEntry(url: url) }
                }
            } primaryAction: { urls in
                if let url = urls.first.flatMap(URL.init(string:)) { open(url) }
            }
            .overlay {
                if days.isEmpty {
                    Text(query.isEmpty ? "No history." : "No matches.").foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Clear all history of this profile?", isPresented: $confirmClearAll) {
            Button("Clear All History", role: .destructive) { library.clearHistory(since: nil) }
        } message: {
            Text("Website data (cookies, caches) is not affected.")
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
    }
}
