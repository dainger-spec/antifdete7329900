import SwiftUI

// MARK: - Appearance

/// Settings → Appearance (the design's, new): the light at entry with a miniature of the lock
/// screen, the profile list's density, the interface's animations. Only the app's own windows:
/// pages follow macOS, as in Safari.
struct AppearanceSettings: View {
    @ObservedObject private var appearance = AppearancePreferences.shared

    var body: some View {
        SettingsPage(title: L("settings.section.appearance"), subtitle: L("settings.appearance.subtitle"), isNew: true) {
            SettingsCaption(L("settings.appearance.entry"))
            AppearanceThumbnail(lit: appearance.entryLight)
                .padding(.bottom, 18)
            SettingRow(L("settings.appearance.light"), detail: L("settings.appearance.light.detail"), effect: .now) {
                SettingSwitch(isOn: $appearance.entryLight, label: L("settings.appearance.light"))
            }
            SettingsCaption(L("settings.appearance.listAndMotion"))
            SettingRow(L("settings.appearance.density"), detail: L("settings.appearance.density.detail"), effect: .now) {
                LumenSegmented(selection: $appearance.density,
                               options: [(AppearancePreferences.Density.comfortable, L("settings.appearance.density.comfortable")),
                                         (AppearancePreferences.Density.compact, L("settings.appearance.density.compact"))])
                    .accessibilityLabel(L("settings.appearance.density"))
            }
            SettingRow(L("settings.appearance.animations"), detail: L("settings.appearance.animations.detail"), effect: .now) {
                SettingSwitch(isOn: $appearance.animations, label: L("settings.appearance.animations"))
            }
            SettingRow(L("settings.appearance.countryBackdrop"), detail: L("settings.appearance.countryBackdrop.detail"), effect: .now) {
                SettingSwitch(isOn: $appearance.countryBackdrop, label: L("settings.appearance.countryBackdrop"))
            }
            CountryBackdropSample(on: appearance.countryBackdrop)
                .padding(.top, 4)
        }
    }
}

/// Two rows of the profile list in miniature, with the country's flag behind them or without:
/// what the switch above changes, seen before choosing.
private struct CountryBackdropSample: View {
    let on: Bool

    var body: some View {
        VStack(spacing: 6) {
            row(code: "DE", name: L("settings.appearance.countryBackdrop.sample1"))
            row(code: "US", name: L("settings.appearance.countryBackdrop.sample2"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.backdrop))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .animation(Motion.toggle, value: on)
        .accessibilityHidden(true)
    }

    private func row(code: String, name: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.raisedInset).frame(width: 24, height: 24)
                .overlay(Text(verbatim: String(name.prefix(1))).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary))
            Text(verbatim: name).font(.lumenLabel).foregroundStyle(Theme.textPrimary)
                .shadow(color: on ? Color.black.opacity(0.6) : .clear, radius: 2.5, y: 1)
            Spacer(minLength: 12)
            CountryFlag(code: code, size: 14)
            Text(verbatim: CountryNames.name(for: code)).font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(alignment: .leading) {
            if on {
                CountryBackdrop(code: code)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .transition(.opacity)
            }
        }
    }
}

/// The lock screen in miniature, with its light or without (the design's thumbnail): what the
/// switch below it changes, seen before choosing.
private struct AppearanceThumbnail: View {
    let lit: Bool

    var body: some View {
        ZStack {
            Theme.backdrop
            if lit {
                EclipseLight(place: .thumbnail)
                    .transition(.opacity)
            }
            VStack(spacing: 10) {
                LumenMark(size: 30)
                Text(L("unlock.title"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.strongBorder, lineWidth: 1))
                    .frame(width: 170, height: 22)
                Text(L("unlock.action.unlock"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 170, height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
            }
        }
        .frame(height: 208)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1))
        .animation(.easeOut(duration: 0.3), value: lit)
        .accessibilityHidden(true)
    }
}

// MARK: - Security

/// Settings → Security (the design's): the master password — changed here, in its own sheet as
/// before — Lock now, and where the vault is.
struct SecuritySettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var changingPassword = false

    var body: some View {
        SettingsPage(title: L("settings.section.security"), subtitle: L("settings.security.subtitle")) {
            SettingRow(L("settings.security.password"), detail: L("settings.security.password.detail"), effect: nil) {
                Button(L("settings.security.password.change")) { changingPassword = true }
                    .buttonStyle(.lumenSecondary)
                    .disabled(model.phase != .unlocked)
            }
            SettingRow(L("settings.security.lock"), detail: L("profiles.action.lock.help"), effect: nil) {
                Button(L("profiles.action.lock")) { Task { await model.lock() } }
                    .buttonStyle(.lumenSecondary)
                    .disabled(model.phase != .unlocked)
            }
            SettingRow(L("settings.security.vault"), detail: model.vaultPathDescription, effect: nil) {
                Button(L("index.reveal")) { model.revealVaultFolder() }
                    .buttonStyle(.lumenGhost)
            }
        }
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
    }
}
