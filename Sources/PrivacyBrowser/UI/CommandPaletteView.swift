import BrowserCore
import SwiftUI

/// ⌘K (the design's palette): every profile, the proxies, the settings and the actions of the app,
/// found by typing — arrows choose, Return runs, Esc closes. Before anything is typed, in groups:
/// the actions, the profiles, the settings; typed, the best matches first.
struct CommandPaletteView: View {
    struct Command: Identifiable {
        enum Group: Int, CaseIterable { case actions, profiles, settings }

        let id: String
        let title: String
        /// Searched with the title, shown under it (a profile's tags, where it exits).
        var detail: String?
        let symbol: String
        var group: Group = .actions
        /// Its keys, at the row's end ("⌘N").
        var shortcut: String?
        let run: () -> Void
    }

    let commands: [Command]
    var onClose: () -> Void = {}
    @State private var query: String
    @State private var selected = 0
    @FocusState private var searching: Bool

    static let size = CGSize(width: 560, height: 420)

    init(commands: [Command], onClose: @escaping () -> Void = {}, query: String = "") {
        self.commands = commands
        self.onClose = onClose
        _query = State(initialValue: query)
    }

    var results: [Command] { Self.rank(commands, query: query) }

    /// The commands that match `query`, best first; for none, all of them by group, in their order.
    static func rank(_ commands: [Command], query: String) -> [Command] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            return commands.enumerated()
                .sorted { ($0.element.group.rawValue, $0.offset) < ($1.element.group.rawValue, $1.offset) }
                .map(\.element)
        }
        return commands.enumerated()
            .compactMap { index, command -> (Int, Int, Command)? in
                guard let score = CommandSearch.score(text, command.title + " " + (command.detail ?? "")) else { return nil }
                return (score, index, command)
            }
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map(\.2)
    }

    var body: some View {
        let shown = results
        let grouped = query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField(L("palette.search"), text: $query, prompt: Text(L("palette.search")))
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searching)
                    .onSubmit { run(shown) }
                    .onKeyPress(.downArrow) {
                        selected = min(selected + 1, max(shown.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selected = max(selected - 1, 0)
                        return .handled
                    }
                KeyCap(keys: "esc", small: true) // l10n: not text
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, command in
                            if grouped, index == 0 || shown[index - 1].group != command.group {
                                Text(Self.title(of: command.group))
                                    .lumenCaps()
                                    .padding(.horizontal, 10)
                                    .padding(.top, index == 0 ? 6 : 14)
                                    .padding(.bottom, 4)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            row(command, selected: index == selected)
                                .id(index)
                                .onTapGesture {
                                    selected = index
                                    run(shown)
                                }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selected) { _, index in scroller.scrollTo(index) }
                .overlay {
                    if shown.isEmpty {
                        Text(L("palette.nothing"))
                            .font(.lumenBody)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 14) {
                hint("↑↓", L("palette.hint.choose")) // l10n: not text
                hint("↵", L("palette.hint.run")) // l10n: not text
                hint("esc", L("palette.hint.close")) // l10n: not text
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("palette.hint"))
        }
        .sheetFrame(width: Self.size.width, height: Self.size.height)
        // Floating, as the selection bar: a hairline and a lit top edge. Square: the sheet's window
        // rounds its corners itself, and the presentation is pinned to the same tone so that no
        // system material shows there.
        .lumenFloatingSurface(cornerRadius: 0)
        .presentationBackground(Theme.raised)
        .onChange(of: query) { _, _ in selected = 0 }
        .onAppear { searching = true }
        .onExitCommand(perform: onClose)
    }

    static func title(of group: Command.Group) -> String {
        switch group {
        case .actions: return L("palette.group.actions")
        case .profiles: return L("palette.group.profiles")
        case .settings: return L("palette.group.settings")
        }
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            KeyCap(keys: keys, small: true)
            Text(text).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
        }
    }

    private func row(_ command: Command, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.lumenLabel)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let detail = command.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let shortcut = command.shortcut {
                KeyCap(keys: shortcut, small: true)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: command.detail?.isEmpty == false ? 44 : 34)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(selected ? Theme.rowSelected : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func run(_ shown: [Command]) {
        guard shown.indices.contains(selected) else { return }
        let command = shown[selected]
        onClose()
        // After the palette has gone: what the command opens may be a sheet of its own.
        DispatchQueue.main.async { command.run() }
    }
}
