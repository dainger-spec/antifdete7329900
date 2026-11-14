import BrowserCore
import SwiftUI

/// Where a running machine's macOS connects, as its network sees it: every host it asked for,
/// how many connections, how much went each way, what was blocked — and a button to block a host
/// from now on. The machine's whole traffic ends in Lumen's own network, so this is all of it:
/// its browser's, its system's, its apps'.
///
/// Names and counts only: what is said inside an encrypted connection is not seen. The list is
/// the person's browsing: it is asked of the machine only while this sheet is open, shown, and
/// kept nowhere.
struct VMNetworkView: View {
    @ObservedObject var center: VMCenter
    let profile: VMProfile
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var onlyOpen = false
    @State private var error: String?

    private var isRunning: Bool { center.running[profile.id]?.phase == .running }
    private var hosts: [VMHelperEvent.Host] { center.hosts[profile.id] ?? [] }

    private var shown: [VMHelperEvent.Host] {
        let wanted = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return hosts.filter { host in
            (!onlyOpen || host.open > 0) && (wanted.isEmpty || host.name.contains(wanted))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("vm.network.title"), profile.name), subtitle: L("vm.network.subtitle"))
            VStack(alignment: .leading, spacing: 14) {
                summary
                HStack(spacing: 10) {
                    TextField(L("vm.network.search"), text: $search, prompt: Text(verbatim: ""))
                        .lumenField(L("vm.network.search"), isEmpty: search.isEmpty)
                    Toggle(L("vm.network.onlyOpen"), isOn: $onlyOpen)
                        .toggleStyle(.checkbox)
                        .font(.lumenSecondary)
                        .fixedSize()
                }
                list
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("vm.network.note"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            SheetFooter {
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .sheetFrame(width: 640)
        .background(Theme.raised)
        .onAppear { center.watchNetwork(of: profile.id, true) }
        .onDisappear { center.watchNetwork(of: profile.id, false) }
    }

    // MARK: Parts

    private var summary: some View {
        let state = center.running[profile.id]
        return HStack(alignment: .firstTextBaseline, spacing: 18) {
            figure(String(hosts.count), L("vm.network.hosts"))
            figure(String(state?.connections ?? 0), L("vm.network.open"))
            figure("↑ " + VMText.bytes(state?.bytesUp ?? 0), L("vm.network.sent"))
            figure("↓ " + VMText.bytes(state?.bytesDown ?? 0), L("vm.network.received"))
            Spacer(minLength: 0)
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.lumenCaption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var list: some View {
        if !isRunning {
            LumenEmptyHint(symbol: "moon.zzz", text: L("vm.network.notRunning"))
                .frame(maxWidth: .infinity)
                .frame(height: 300)
        } else if shown.isEmpty {
            LumenEmptyHint(symbol: "network", text: L(hosts.isEmpty ? "vm.network.empty" : "vm.network.noMatch"))
                .frame(maxWidth: .infinity)
                .frame(height: 300)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { host in
                        row(host)
                        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14)
                    }
                }
            }
            .frame(height: 300)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raisedInset))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func row(_ host: VMHelperEvent.Host) -> some View {
        let blocked = center.isBlocked(host.name, in: profile.id)
        return HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(blocked ? Theme.danger : (host.open > 0 ? Theme.running : Theme.textTertiary.opacity(0.5)))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: host.name)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(detail(of: host, blocked: blocked))
                    .font(.lumenSecondary)
                    .foregroundStyle(blocked ? Theme.danger : Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(verbatim: "↑ \(VMText.bytes(host.bytesUp))  ↓ \(VMText.bytes(host.bytesDown))")
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
            if blocked {
                Text(L("vm.network.blocked"))
                    .font(.lumenCaption)
                    .foregroundStyle(Theme.danger)
                    .frame(width: 104, alignment: .trailing)
            } else {
                Button(L("vm.network.block")) { block(host.name) }
                    .buttonStyle(.lumenGhost)
                    .frame(width: 104, alignment: .trailing)
                    .disabled(VMProfile.blockedHost(host.name) == nil)
                    .help(L("vm.network.block.help"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// "3 connections, 1 open · 12 s ago" — or, for a blocked host, how often it was refused.
    private func detail(of host: VMHelperEvent.Host, blocked: Bool) -> String {
        var parts: [String] = []
        if host.connections > 0 {
            parts.append(String(format: L("vm.network.connections"), Int(clamping: host.connections), host.open))
        }
        if host.blocked > 0 { parts.append(String(format: L("vm.network.refused"), Int(clamping: host.blocked))) }
        if host.open == 0 {
            parts.append(host.idle < 5 ? L("vm.network.justNow") : String(format: L("vm.network.ago"), Self.age(host.idle)))
        }
        return parts.joined(separator: " · ")
    }

    /// "12 s", "4 min", "2 h".
    private static func age(_ seconds: Double) -> String {
        let whole = Int(max(seconds, 0))
        if whole < 60 { return String(format: L("vm.network.age.seconds"), whole) }
        if whole < 3600 { return String(format: L("vm.network.age.minutes"), whole / 60) }
        return String(format: L("vm.network.age.hours"), whole / 3600)
    }

    private func block(_ host: String) {
        do {
            try center.block(host, in: profile.id)
            error = nil
        } catch {
            self.error = errorText(error)
        }
    }
}
