import BrowserCore
import SwiftUI

/// What the virtual machines take on this Mac's disk, part by part — the base system, what was
/// fetched for it, each machine — and the ways to give it back: the fetched image, the base, or
/// everything at once. Tens of gigabytes a person may want back are not to be looked for in the
/// Finder.
struct VMStorageView: View {
    @ObservedObject var center: VMCenter
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingBase = false
    @State private var confirmingEverything = false
    @State private var error: String?

    private var baseBytes: Int64 { center.diskUsage[VMCenter.baseID] ?? 0 }
    private var downloadBytes: Int64 { center.diskUsage[VMCenter.downloadsID] ?? 0 }
    private var machineBytes: Int64 { center.profiles.reduce(0) { $0 + (center.diskUsage[$1.id] ?? 0) } }
    private var total: Int64 { baseBytes + downloadBytes + machineBytes }
    /// Nothing may be removed while a machine runs or the setup is at work.
    private var busy: Bool { center.hasRunning || center.activity != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("vm.storage.title"), subtitle: L("vm.storage.subtitle"))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    if total > 0 { bar }
                    VStack(spacing: 0) {
                        if baseBytes > 0 {
                            row(symbol: "internaldrive", title: L("vm.storage.base"), detail: baseDetail, bytes: baseBytes) {
                                Button(L("vm.storage.delete")) { confirmingBase = true }
                                    .buttonStyle(.lumenGhost)
                                    .disabled(center.activity != nil)
                            }
                            divider
                        }
                        if downloadBytes > 0 {
                            row(symbol: "arrow.down.circle", title: L("vm.storage.download"), detail: L("vm.storage.download.detail"),
                                bytes: downloadBytes) {
                                Button(L("vm.storage.delete.now")) { center.removeDownloadedImage() }
                                    .buttonStyle(.lumenGhost)
                                    .disabled(center.activity != nil)
                            }
                            divider
                        }
                        ForEach(center.profiles) { profile in
                            row(symbol: profile.display.id.hasPrefix("macbook") ? "laptopcomputer" : "desktopcomputer",
                                title: profile.name, detail: center.isRunning(profile.id) ? L("vm.row.running") : L("vm.storage.machine.detail"),
                                bytes: center.diskUsage[profile.id] ?? 0) { EmptyView() }
                            divider
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raisedInset))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                    .opacity(total > 0 || !center.profiles.isEmpty ? 1 : 0)
                    if !center.profiles.isEmpty {
                        note(L("vm.storage.hint"))
                    }
                    if busy {
                        note(L("vm.error.busy"))
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
            .frame(minHeight: 260, maxHeight: 520)
            SheetFooter(leading: {
                Button(L("vm.storage.deleteAll")) { confirmingEverything = true }
                    .buttonStyle(.lumenDestructive)
                    .disabled(busy || (total == 0 && center.profiles.isEmpty))
            }, buttons: {
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            })
        }
        .sheetFrame(width: 560)
        .background(Theme.raised)
        .onAppear { center.measureDisk() }
        .confirmationDialog(L("vm.base.remove.title"), isPresented: $confirmingBase, titleVisibility: .visible) {
            Button(L("vm.base.remove.confirm"), role: .destructive) { center.removeBase() }
        } message: {
            Text(L("vm.base.remove.message"))
        }
        .confirmationDialog(L("vm.storage.deleteAll.title"), isPresented: $confirmingEverything, titleVisibility: .visible) {
            Button(L("vm.storage.deleteAll.confirm"), role: .destructive) { deleteEverything() }
        } message: {
            Text(String(format: L("vm.storage.deleteAll.message"), VMText.bytes(total)))
        }
    }

    // MARK: Parts

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(VMText.bytes(total))
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.75)
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text(L("vm.storage.used"))
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            Text(String(format: L("vm.storage.free"), VMText.bytes(center.freeDisk)))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
        }
    }

    /// What is taken, by part: the base, the machines, the fetched image.
    private var bar: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width
                HStack(spacing: 2) {
                    segment(baseBytes, of: width, opacity: 0.85)
                    segment(machineBytes, of: width, opacity: 0.50)
                    segment(downloadBytes, of: width, opacity: 0.24)
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            HStack(spacing: 16) {
                legend(L("vm.storage.base"), opacity: 0.85, shown: baseBytes > 0)
                legend(L("vm.storage.machines"), opacity: 0.50, shown: machineBytes > 0)
                legend(L("vm.storage.download"), opacity: 0.24, shown: downloadBytes > 0)
            }
        }
    }

    @ViewBuilder
    private func segment(_ bytes: Int64, of width: CGFloat, opacity: Double) -> some View {
        if bytes > 0, total > 0 {
            Rectangle()
                .fill(Color.white.opacity(opacity))
                .frame(width: max(3, (width - 4) * CGFloat(Double(bytes) / Double(total))))
        }
    }

    @ViewBuilder
    private func legend(_ title: String, opacity: Double, shown: Bool) -> some View {
        if shown {
            HStack(spacing: 6) {
                Circle().fill(Color.white.opacity(opacity)).frame(width: 7, height: 7)
                Text(title)
                    .font(.lumenCaption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var baseDetail: String {
        guard let info = center.library.baseInfo(), !info.version.isEmpty else { return L("vm.storage.base.detail") }
        return String(format: L("vm.storage.base.version"), info.version)
    }

    private var divider: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 50)
    }

    private func row<Action: View>(symbol: String, title: String, detail: String, bytes: Int64,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.lumenLabel)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Text(VMText.bytes(bytes))
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
            action()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.lumenSecondary)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The person's "Delete everything", confirmed: the one caller of the machines' removal of
    /// everything (scripts/check_deletion_paths.py).
    private func deleteEverything() {
        do {
            try center.deleteEverythingBecauseThePersonAsked()
            error = nil
        } catch {
            self.error = errorText(error)
        }
    }
}
