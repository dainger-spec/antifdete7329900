import AppKit
import UniformTypeIdentifiers

/// Open and save panels for import/export. In the App Sandbox the panel itself grants access to
/// the file the user picks (Powerbox), so nothing else is readable or writable.
@MainActor
enum FilePanels {
    static let backupType = UTType(filenameExtension: "pbbackup", conformingTo: .data) ?? .data

    static func open(titleKey: String, messageKey: String? = nil, types: [UTType]) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = L(titleKey)
        panel.message = messageKey.map(L) ?? ""
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return await run(panel) ? panel.url : nil
    }

    static func save(titleKey: String, messageKey: String? = nil, suggestedName: String, type: UTType) async -> URL? {
        let panel = NSSavePanel()
        panel.title = L(titleKey)
        panel.message = messageKey.map(L) ?? ""
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return await run(panel) ? panel.url : nil
    }

    private static func run(_ panel: NSSavePanel) async -> Bool {
        await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK) }
            } else {
                continuation.resume(returning: panel.runModal() == .OK)
            }
        }
    }

    /// "Work" → "Work", made safe as a file name.
    static func fileName(_ base: String, ext: String) -> String {
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "profile" : cleaned) + "." + ext
    }
}
