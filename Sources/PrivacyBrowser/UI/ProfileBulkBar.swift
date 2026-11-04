import AppKit
import SwiftUI

/// Which rows of the Profiles list are selected, as in a Finder list: a click selects that row
/// alone (a click on the only selected row clears it), ⌘-click adds or removes one row, ⇧-click
/// selects everything from the row clicked last to this one, in the order the list shows them.
struct ProfileSelection: Equatable {
    enum Click: Equatable {
        case plain, toggle, extend

        /// How the click that is being handled was made (⇧ before ⌘, as Finder does).
        @MainActor
        static var current: Click {
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) { return .extend }
            if flags.contains(.command) { return .toggle }
            return .plain
        }
    }

    private(set) var ids: Set<UUID> = []
    /// The row a ⇧-click extends from.
    private(set) var anchor: UUID?

    var isEmpty: Bool { ids.isEmpty }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// `order`: the rows as the list shows them.
    mutating func click(_ id: UUID, _ click: Click, order: [UUID]) {
        switch click {
        case .plain:
            ids = ids == [id] ? [] : [id]
            anchor = ids.isEmpty ? nil : id
        case .toggle:
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        case .extend:
            guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
                ids.insert(id)
                self.anchor = id
                return
            }
            ids.formUnion(order[min(from, to)...max(from, to)])
        }
    }

    mutating func select(_ all: [UUID]) {
        ids = Set(all)
        anchor = all.first
    }

    mutating func clear() {
        ids = []
        anchor = nil
    }

    /// Profiles that are gone (deleted, or removed by sync) leave the selection.
    mutating func keep(only existing: Set<UUID>) {
        ids.formIntersection(existing)
        if let anchor, !existing.contains(anchor) { self.anchor = nil }
    }
}

/// The bar over the Profiles list while several profiles are selected: how many, and what can be
/// done to all of them at once — launch the stopped ones, stop the running ones, warm them up,
/// give them proxies of the list, delete them. Each goes out through `ProfileActions` with the
/// profiles in the order the list shows them.
struct ProfileBulkBar: View {
    /// The selected rows, in the list's order.
    let rows: [ProfileRowItem]
    /// Rows the list shows (for "Select all").
    let visibleCount: Int
    let actions: ProfileActions
    let selectAll: () -> Void
    let clear: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 44)
        .background(Theme.accentTint)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(format: L("profiles.bulk.selected"), rows.count)))
    }

    private var ids: [UUID] { rows.map(\.id) }
    private var stopped: [UUID] { rows.filter { $0.activity == .stopped }.map(\.id) }
    private var running: [UUID] { rows.filter(\.isRunning).map(\.id) }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Text(String(format: L("profiles.bulk.selected"), rows.count))
                .font(.lumenLabel)
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .fixedSize()
                .padding(.trailing, 4)
            Button { actions.launchSeveral(stopped) } label: { label(L("profiles.bulk.launch"), "play.fill", compact) }
                .buttonStyle(.lumenSecondary)
                .disabled(stopped.isEmpty)
                .help(L("profiles.bulk.launch.help"))
            Button { actions.stopSeveral(running) } label: { label(L("profiles.bulk.stop"), "stop.fill", compact) }
                .buttonStyle(.lumenSecondary)
                .disabled(running.isEmpty)
                .help(L("profiles.bulk.stop.help"))
            Button { actions.warmUpSeveral(ids) } label: { label(L("profiles.bulk.warmUp"), "flame", compact) }
                .buttonStyle(.lumenSecondary)
                .help(L("profiles.bulk.warmUp.help"))
            Button { actions.assignProxies(ids) } label: { label(L("profiles.bulk.assignProxy"), "network", compact) }
                .buttonStyle(.lumenSecondary)
                .help(L("profiles.bulk.assignProxy.help"))
            Button(role: .destructive) { actions.deleteSeveral(ids) } label: { label(L("profiles.bulk.delete"), "trash", compact) }
                .buttonStyle(.lumenDestructive)
                .help(L("profiles.bulk.delete.help"))
            Spacer(minLength: 8)
            if !compact, rows.count < visibleCount {
                Button(L("profiles.bulk.selectAll"), action: selectAll)
                    .buttonStyle(.lumenGhost)
            }
            Button(action: clear) { Image(systemName: "xmark") }
                .buttonStyle(LumenIconButtonStyle())
                .help(L("profiles.bulk.clear"))
                .accessibilityLabel(L("profiles.bulk.clear"))
        }
    }

    @ViewBuilder
    private func label(_ title: String, _ symbol: String, _ compact: Bool) -> some View {
        if compact {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: symbol)
        }
    }
}
