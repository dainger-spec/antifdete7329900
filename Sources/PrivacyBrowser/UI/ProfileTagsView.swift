import BrowserCore
import SwiftUI

/// Tags for several profiles at once (the selection's "Tags…", `AppModel.changeTags`): tags to
/// add to all of them, and the tags they have — each with how many of them have it — to take away
/// from all. What the change will do is said before anything is saved. One profile's tags are in
/// its editor, as before.
struct ProfileTagsView: View {
    /// The profiles the sheet opens for.
    struct Request: Identifiable {
        let id = UUID()
        var profileIDs: [UUID]
    }

    let request: Request
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // In the list's order, and only those still there.
        let wanted = Set(request.profileIDs)
        let chosen = model.profiles.filter { wanted.contains($0.id) }
        ProfileTagsPanel(profiles: chosen.map { ProfileTagsPanel.Profile(name: $0.name, tags: model.details[$0.id]?.tags ?? []) },
                         knownTags: knownTags,
                         onApply: { adding, removing in
                             model.changeTags(of: chosen.map(\.id), adding: adding, removing: removing)
                             dismiss()
                         },
                         onCancel: { dismiss() })
    }

    /// The tags of every profile, each once, for the field to offer.
    private var knownTags: [String] {
        var seen = Set<String>()
        return model.details.values.flatMap(\.tags)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

/// The sheet's body over plain values (drawn with sample profiles by `--render-ui-snapshots`).
struct ProfileTagsPanel: View {
    struct Profile {
        var name: String
        var tags: [String]
    }

    let profiles: [Profile]
    /// Every tag of the vault, offered under the field.
    var knownTags: [String] = []
    var onApply: (_ adding: [String], _ removing: [String]) -> Void = { _, _ in }
    var onCancel: () -> Void = {}
    /// The tags to add, as chips, and the tags marked to be taken away (as the sheet opens: the
    /// snapshots).
    @State var added: [String] = []
    @State var removing: [String] = []
    /// Typed and not yet made a chip: it counts all the same, so that Apply right after typing
    /// does what was typed.
    @State private var text = ""
    @Environment(\.tagColors) private var tagColors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("profiles.tags.title"), profiles.count),
                        subtitle: ProfileListView.listed(profiles.map(\.name)))
            VStack(alignment: .leading, spacing: 16) {
                EditorField(L("profiles.tags.add")) { addField }
                EditorField(L("profiles.tags.remove")) { removeList }
                summary
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            SheetFooter {
                Button(L("common.cancel"), action: onCancel)
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("profiles.tags.apply")) { onApply(adding, removing) }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.changed == 0)
            }
        }
        .sheetFrame(width: 520)
        .background(Theme.raised)
    }

    // MARK: What will be done

    /// The chips and what is typed in the field, as one list.
    private var adding: [String] {
        ProfileTags.normalized(added + ProfileTags.parse(text))
    }

    /// How many of the profiles the change changes, and how many of them have no room for every
    /// tag (`ProfileTags.maximumCount`).
    private var plan: (changed: Int, full: Int) {
        var changed = 0, full = 0
        for profile in profiles {
            let change = ProfileTags.changing(profile.tags, adding: adding, removing: removing)
            if change.tags != ProfileTags.normalized(profile.tags) { changed += 1 }
            if !change.notAdded.isEmpty { full += 1 }
        }
        return (changed, full)
    }

    /// The tags the profiles have, each once in its first spelling, by name, with how many of the
    /// profiles have it.
    private var occurring: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for profile in profiles {
            for tag in profile.tags {
                let key = tag.lowercased()
                counts[key, default: 0] += 1
                if spelling[key] == nil { spelling[key] = tag }
            }
        }
        return spelling.values
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { (tag: $0, count: counts[$0.lowercased()] ?? 0) }
    }

    // MARK: Parts

    private var addField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !added.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(added, id: \.self) { tag in
                        TagChip(text: tag, color: tagColors.color(of: tag)) { added.removeAll { $0 == tag } }
                    }
                }
            }
            TextField(L("profiles.tags.add"), text: $text, prompt: Text(verbatim: ""))
                .lumenField(L("editor.tags.placeholder"), isEmpty: text.isEmpty)
                .onSubmit(commit)
                .onChange(of: text) { _, typed in
                    if typed.contains(",") { commit() }
                }
            let offered = knownTags.filter { !ProfileTags.contains(adding, $0) }
            if !offered.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("editor.tags.suggestions"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(offered.prefix(12), id: \.self) { tag in
                            Button { added = ProfileTags.normalized(added + [tag]) } label: {
                                TagChip(text: tag, color: tagColors.color(of: tag))
                            }
                            .buttonStyle(.plain)
                            .help(String(format: L("editor.tags.addSuggested"), tag))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var removeList: some View {
        let tags = occurring
        if tags.isEmpty {
            Text(L("profiles.tags.none"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
        } else {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(tags, id: \.tag) { item in
                    RemovableTag(tag: item.tag, count: item.count, total: profiles.count, color: tagColors.color(of: item.tag),
                                 marked: ProfileTags.contains(removing, item.tag)) {
                        if ProfileTags.contains(removing, item.tag) {
                            removing.removeAll { $0.caseInsensitiveCompare(item.tag) == .orderedSame }
                        } else {
                            removing.append(item.tag)
                        }
                    }
                }
            }
        }
    }

    /// What Apply will do, or how to say what to do.
    @ViewBuilder
    private var summary: some View {
        let plan = self.plan
        VStack(alignment: .leading, spacing: 4) {
            if adding.isEmpty && removing.isEmpty {
                Text(L("profiles.tags.hint"))
                    .foregroundStyle(Theme.textTertiary)
            } else if plan.changed == 0 {
                Text(L("profiles.tags.nothing"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(String(format: L("profiles.tags.plan"), plan.changed, profiles.count))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }
            if plan.full > 0 {
                Text(String(format: L("profiles.tags.planFull"), plan.full, ProfileTags.maximumCount))
                    .foregroundStyle(Theme.warning)
                    .monospacedDigit()
            }
        }
        .font(.lumenSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What is typed, split at commas, made chips after those there are (each once).
    private func commit() {
        let typed = ProfileTags.parse(text)
        text = ""
        guard !typed.isEmpty else { return }
        added = ProfileTags.normalized(added + typed)
    }
}

/// A tag the selected profiles have, with how many of them have it: a click marks it to be taken
/// away from all of them (struck through, in red), another click leaves it.
private struct RemovableTag: View {
    let tag: String
    let count: Int
    let total: Int
    var color: Int?
    let marked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                if let color {
                    TagDot(color: color, size: 6)
                }
                Text(tag)
                    .font(.system(size: 11.5, weight: .medium))
                    .strikethrough(marked)
                    .foregroundStyle(marked ? Theme.danger : Theme.textPrimary)
                    .lineLimit(1)
                Text(verbatim: "\(count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(marked ? Theme.danger : Theme.textTertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(marked ? Theme.danger.opacity(0.12) : Color.clear))
            .overlay(Capsule().strokeBorder(marked ? Theme.danger.opacity(0.55) : Theme.strongBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(format: L(marked ? "profiles.tags.remove.marked" : "profiles.tags.remove.help"), tag, count, total))
        .accessibilityLabel(String(format: L(marked ? "profiles.tags.remove.marked" : "profiles.tags.remove.help"), tag, count, total))
        .accessibilityAddTraits(marked ? .isSelected : [])
    }
}
