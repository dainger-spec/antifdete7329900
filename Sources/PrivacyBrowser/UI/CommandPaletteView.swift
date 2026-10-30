import BrowserCore
import SwiftUI

/// ⌘K: every profile, the proxies, the settings and the actions of the app, found by typing —
/// arrows choose, Return runs, Esc closes.
struct CommandPaletteView: View {
    struct Command: Identifiable {
        let id: String
        let title: String
        /// Searched with the title, shown under it (a profile's tags, where it exits).
        var detail: String?
        let symbol: String
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

    /// The commands that match `query`, best first; all of them, in their order, for none.
    static func rank(_ commands: [Command], query: String) -> [Command] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return commands }
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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
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
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, command in
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
            Text(L("palette.hint"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 30)
        }
        .sheetFrame(width: Self.size.width, height: Self.size.height)
        .background(Theme.raised)
        .onChange(of: query) { _, _ in selected = 0 }
        .onAppear { searching = true }
        .onExitCommand(perform: onClose)
    }

    private func row(_ command: Command, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
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
        }
        .padding(.horizontal, 10)
        .frame(height: command.detail?.isEmpty == false ? 44 : 34)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(selected ? Color.white.opacity(0.08) : .clear))
        .contentShape(Rectangle())
    }

    private func run(_ shown: [Command]) {
        guard shown.indices.contains(selected) else { return }
        let command = shown[selected]
        onClose()
        // After the palette has gone: what the command opens may be a sheet of its own.
        DispatchQueue.main.async { command.run() }
    }
}
