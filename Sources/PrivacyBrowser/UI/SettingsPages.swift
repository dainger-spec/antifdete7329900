import BrowserCore
import SwiftUI

// MARK: - Appearance

/// Settings → Appearance (the design's, new): the light at entry with a miniature of the lock
/// screen, the greeting at launch, the profile list's density, the interface's animations. Only
/// the app's own windows: pages follow macOS, as in Safari.
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
            SettingRow(L("settings.appearance.welcome"), detail: L("settings.appearance.welcome.detail"), effect: .appStart) {
                SettingSwitch(isOn: $appearance.welcome, label: L("settings.appearance.welcome"))
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
    @State private var turningTouchIDOn = false

    var body: some View {
        SettingsPage(title: L("settings.section.security"), subtitle: L("settings.security.subtitle")) {
            SettingRow(L("settings.security.password"), detail: L("settings.security.password.detail"), effect: nil) {
                Button(L("settings.security.password.change")) { changingPassword = true }
                    .buttonStyle(.lumenSecondary)
                    .disabled(model.phase != .unlocked)
            }
            if model.touchID.offered {
                // Unlocking with Touch ID: off until turned on here, with the master password typed
                // once more; what it keeps on this Mac is said under it (AppModel+TouchID).
                SettingCustomRow(L("settings.security.touchID")) {
                    Text(String(format: L("settings.security.touchID.detail"), BiometricUnlock.passwordEveryDays))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(L("settings.security.touchID.kept"), systemImage: "key")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    if let note = touchIDNote {
                        Label(note, systemImage: "exclamationmark.circle")
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                } control: {
                    SettingSwitch(isOn: Binding(get: { model.touchID.isOn },
                                                set: { on in
                                                    if on { turningTouchIDOn = true } else { model.turnTouchIDOff() }
                                                }),
                                  label: L("settings.security.touchID"))
                        .disabled(model.phase != .unlocked || (!model.touchID.isOn && model.touchID.sensor != .ready))
                }
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
        .sheet(isPresented: $turningTouchIDOn) { TouchIDTurnOnView() }
        // The sensor as it is now (a fingerprint added since, the lid opened). Not where it is not
        // offered: there is nothing to ask, and the pictures' stand-in state stays as given.
        .onAppear { if TouchIDUnlock.isOfferedHere { model.refreshTouchID() } }
    }

    /// Under the Touch ID row: what the sensor says when it does not answer, or why the master
    /// password is asked at the next unlock although it is on.
    private var touchIDNote: String? {
        if let sensor = TouchIDText.sensorNote(model.touchID.sensor) { return sensor }
        if case .password(let reason) = model.touchID.decision { return TouchIDText.passwordAsked(reason) }
        return nil
    }
}

/// Turning unlocking with Touch ID on (Settings › Security): what it keeps on this Mac and when the
/// master password is still asked, said before the choice, and the master password typed once more
/// — an unlocked Mac left alone must not be enough to add a way into the vault.
struct TouchIDTurnOnView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("touchid.on.title"))
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    fact("touchid", L("touchid.on.fact.opens"))
                    fact("key", L("touchid.on.fact.kept"))
                    fact("lock", String(format: L("touchid.on.fact.password"), BiometricUnlock.passwordEveryDays))
                }
                LockPasswordField(label: L("setup.field.password"), password: $password, error: problem != nil, onSubmit: turnOn)
                    .padding(.top, 20)
                if let problem {
                    MasterPasswordRefusalLine(text: problem)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 20)
            SheetFooter {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("touchid.on.action"), action: turnOn)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || working)
            }
        }
        .sheetFrame(width: 480)
        .background(Theme.raised)
        .onChange(of: password) { _, _ in problem = nil }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(.lumenBody)
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func turnOn() {
        // Return reaches the field's submit and the default button: one press is one try.
        guard !password.isEmpty, !working else { return }
        working = true
        let typed = password
        Task {
            problem = await model.turnTouchIDOn(password: typed)
            working = false
            if problem == nil { dismiss() }
        }
    }
}
